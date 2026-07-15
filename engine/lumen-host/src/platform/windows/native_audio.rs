use std::ffi::{c_char, c_int, c_uchar, CStr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::SyncSender;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use lumen_engine::{
    resolve_audio_sink, resolve_audio_stream, LumenAudioSinkRequest, LumenAudioStreamPlan,
    LumenAudioStreamRequest, AUDIO_SINK_CONFIGURED, AUDIO_SINK_HOST, AUDIO_SINK_UNAVAILABLE,
};

use crate::{HostArguments, PlatformSessionPlan};

use super::native_media::PacketQueueContext;
use super::native_wasapi::{WasapiCapture, WasapiEndpointCatalog, WasapiSampleResult};

const PACKET_DURATION_MILLISECONDS: i32 = 5;
const MAXIMUM_OPUS_PACKET_BYTES: usize = 1_275;
const OPUS_APPLICATION_RESTRICTED_LOWDELAY: c_int = 2_051;
const OPUS_SET_BITRATE_REQUEST: c_int = 4_002;
const OPUS_SET_VBR_REQUEST: c_int = 4_006;
const OPUS_SET_COMPLEXITY_REQUEST: c_int = 4_010;
const OPUS_OK: c_int = 0;

#[repr(C)]
struct OpusMSEncoder {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn opus_multistream_encoder_create(
        sample_rate: c_int,
        channels: c_int,
        streams: c_int,
        coupled_streams: c_int,
        mapping: *const c_uchar,
        application: c_int,
        error: *mut c_int,
    ) -> *mut OpusMSEncoder;
    fn opus_multistream_encoder_destroy(encoder: *mut OpusMSEncoder);
    fn opus_multistream_encoder_ctl(encoder: *mut OpusMSEncoder, request: c_int, ...) -> c_int;
    fn opus_multistream_encode_float(
        encoder: *mut OpusMSEncoder,
        pcm: *const f32,
        frame_size: c_int,
        data: *mut u8,
        maximum_bytes: c_int,
    ) -> c_int;
    fn opus_strerror(error: c_int) -> *const c_char;
}

#[derive(Clone)]
pub(super) struct NativeAudioConfiguration {
    enabled: bool,
    configured_sink: String,
}

impl NativeAudioConfiguration {
    pub(super) fn from_arguments(arguments: &HostArguments) -> Result<Self, String> {
        let enabled = match arguments.get("stream_audio") {
            Some("true") => true,
            Some("false") => false,
            _ => return Err("Windows audio configuration stream_audio is invalid".to_owned()),
        };
        Ok(Self {
            enabled,
            configured_sink: arguments.get("audio_sink").unwrap_or_default().to_owned(),
        })
    }

    pub(super) fn enabled(&self) -> bool {
        self.enabled
    }
}

pub(super) fn run(
    stop_requested: Arc<AtomicBool>,
    packets: Arc<PacketQueueContext>,
    configuration: NativeAudioConfiguration,
    plan: PlatformSessionPlan,
    ready: SyncSender<Result<(), String>>,
) -> i32 {
    let mut ready = Some(ready);
    match run_session(stop_requested, &packets, &configuration, plan, &mut ready) {
        Ok(()) => 0,
        Err(error) => {
            if let Some(ready) = ready.take() {
                let _ = ready.send(Err(error.clone()));
            }
            eprintln!("Windows Rust audio worker failed: {error}");
            -1
        }
    }
}

fn run_session(
    stop_requested: Arc<AtomicBool>,
    packets: &PacketQueueContext,
    configuration: &NativeAudioConfiguration,
    plan: PlatformSessionPlan,
    ready: &mut Option<SyncSender<Result<(), String>>>,
) -> Result<(), String> {
    let stream = resolve_audio_stream(LumenAudioStreamRequest {
        channels: i32::from(plan.audio_channels),
        packet_duration_milliseconds: PACKET_DURATION_MILLISECONDS,
        enhanced_audio_quality: plan.enhanced_audio_quality,
    })
    .map_err(|status| format!("audio stream policy rejected the session: {status:?}"))?;
    packets.configure_audio_capacity(
        usize::try_from(stream.packet_queue_capacity)
            .map_err(|_| "audio packet queue capacity is invalid".to_owned())?,
    )?;
    if stop_requested.load(Ordering::Acquire) {
        return Ok(());
    }
    let mut capture = match NativeAudioCapture::open(
        Arc::clone(&stop_requested),
        configuration,
        &stream,
        plan.play_audio_on_host,
    ) {
        Ok(capture) => capture,
        Err(_) if stop_requested.load(Ordering::Acquire) => return Ok(()),
        Err(error) => return Err(error),
    };
    let mut encoder = NativeOpusEncoder::new(&stream, plan.enhanced_audio_quality)?;
    let mut samples = vec![0.0_f32; stream.sample_count];
    ready
        .take()
        .ok_or_else(|| "Windows audio readiness was already reported".to_owned())?
        .send(Ok(()))
        .map_err(|_| "Windows audio readiness receiver was dropped".to_owned())?;

    loop {
        match capture.sample(&mut samples)? {
            WasapiSampleResult::Ready => {
                let packet = encoder.encode(&samples, stream.frame_count)?;
                packets.push_audio(packet)?;
            }
            WasapiSampleResult::Timeout => {}
            WasapiSampleResult::Reinitialize => {
                while !capture.stop_requested() {
                    if capture.reopen(&stream).is_ok() {
                        break;
                    }
                    thread::sleep(Duration::from_millis(250));
                }
            }
        }
        if capture.stop_requested() {
            return Ok(());
        }
    }
}

struct NativeAudioCapture {
    stop_requested: Arc<AtomicBool>,
    selected_sink: String,
    capture: WasapiCapture,
}

impl NativeAudioCapture {
    fn open(
        stop_requested: Arc<AtomicBool>,
        configuration: &NativeAudioConfiguration,
        stream: &LumenAudioStreamPlan,
        host_audio_enabled: bool,
    ) -> Result<Self, String> {
        let catalog = WasapiEndpointCatalog::open()?;
        let host_sink = catalog.host_sink()?;
        let configured_sink_available = !configuration.configured_sink.is_empty()
            && catalog.endpoint_available(&configuration.configured_sink)?;
        let sink_plan = resolve_audio_sink(LumenAudioSinkRequest {
            host_audio_enabled,
            host_sink_available: host_sink.is_some(),
            configured_sink_available,
        });
        let selected_sink = match sink_plan.kind {
            AUDIO_SINK_HOST => host_sink,
            AUDIO_SINK_CONFIGURED => Some(configuration.configured_sink.clone()),
            AUDIO_SINK_UNAVAILABLE => {
                return Err(
                    "host audio playback is disabled and no configured audio sink is available"
                        .to_owned(),
                )
            }
            kind => return Err(format!("audio sink policy returned unknown kind {kind}")),
        }
        .ok_or_else(|| "audio sink policy selected an unavailable sink".to_owned())?;
        let channel_count = u16::try_from(stream.channel_count)
            .map_err(|_| "audio channel count is invalid".to_owned())?;
        let frame_count = usize::try_from(stream.frame_count)
            .map_err(|_| "audio frame count is invalid".to_owned())?;
        let capture = catalog.start_capture(&selected_sink, channel_count, frame_count)?;
        Ok(Self {
            stop_requested,
            selected_sink,
            capture,
        })
    }

    fn reopen(&mut self, stream: &LumenAudioStreamPlan) -> Result<(), String> {
        let channel_count = u16::try_from(stream.channel_count)
            .map_err(|_| "audio channel count is invalid".to_owned())?;
        let frame_count = usize::try_from(stream.frame_count)
            .map_err(|_| "audio frame count is invalid".to_owned())?;
        self.capture = WasapiEndpointCatalog::open()?.start_capture(
            &self.selected_sink,
            channel_count,
            frame_count,
        )?;
        Ok(())
    }

    fn sample(&mut self, samples: &mut [f32]) -> Result<WasapiSampleResult, String> {
        self.capture.sample(samples)
    }

    fn stop_requested(&self) -> bool {
        self.stop_requested.load(Ordering::Acquire)
    }
}

struct NativeOpusEncoder {
    encoder: *mut OpusMSEncoder,
}

impl NativeOpusEncoder {
    fn new(stream: &LumenAudioStreamPlan, enhanced_quality: bool) -> Result<Self, String> {
        let mut error = OPUS_OK;
        let encoder = unsafe {
            opus_multistream_encoder_create(
                stream.sample_rate,
                stream.channel_count,
                stream.streams,
                stream.coupled_streams,
                stream.mapping.as_ptr(),
                OPUS_APPLICATION_RESTRICTED_LOWDELAY,
                &mut error,
            )
        };
        if encoder.is_null() || error != OPUS_OK {
            return Err(format!(
                "Opus multistream creation failed: {}",
                opus_error(error)
            ));
        }
        let result = Self { encoder };
        result.configure(OPUS_SET_BITRATE_REQUEST, stream.bitrate)?;
        result.configure(
            OPUS_SET_COMPLEXITY_REQUEST,
            if enhanced_quality { 10 } else { 5 },
        )?;
        result.configure(OPUS_SET_VBR_REQUEST, 0)?;
        Ok(result)
    }

    fn configure(&self, request: c_int, value: c_int) -> Result<(), String> {
        let status = unsafe { opus_multistream_encoder_ctl(self.encoder, request, value) };
        (status == OPUS_OK)
            .then_some(())
            .ok_or_else(|| format!("Opus configuration failed: {}", opus_error(status)))
    }

    fn encode(&mut self, samples: &[f32], frame_count: i32) -> Result<Vec<u8>, String> {
        let mut packet = vec![0_u8; MAXIMUM_OPUS_PACKET_BYTES];
        let bytes = unsafe {
            opus_multistream_encode_float(
                self.encoder,
                samples.as_ptr(),
                frame_count,
                packet.as_mut_ptr(),
                c_int::try_from(packet.len()).expect("Opus packet limit fits c_int"),
            )
        };
        if bytes < 0 {
            return Err(format!("Opus encoding failed: {}", opus_error(bytes)));
        }
        packet.truncate(usize::try_from(bytes).expect("Opus byte count is nonnegative"));
        Ok(packet)
    }
}

impl Drop for NativeOpusEncoder {
    fn drop(&mut self) {
        unsafe { opus_multistream_encoder_destroy(self.encoder) };
    }
}

fn opus_error(error: c_int) -> String {
    let message = unsafe { opus_strerror(error) };
    if message.is_null() {
        format!("error {error}")
    } else {
        unsafe { CStr::from_ptr(message) }
            .to_string_lossy()
            .into_owned()
    }
}
