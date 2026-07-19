use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::PathBuf;
use std::ptr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use lumen_engine::{resolve_audio_stream, LumenAudioStreamRequest};

use crate::{
    PlatformApplicationPlan, PlatformControlEvent, PlatformEncodedAudioPacket,
    PlatformEncodedVideoFrame, PlatformNativeInputEvent, PlatformRuntimeEvent,
    PlatformRuntimeEventDisposition, PlatformRuntimeEventSeverity, PlatformSessionControl,
    PlatformSessionPlan,
};

use super::macos_native_input::MacNativeInput;
use super::portable_process::PortableApplication;

const MAXIMUM_VIDEO_BYTES: usize = 32 * 1024 * 1024;
const MAXIMUM_PCM_BYTES: usize = 1024 * 1024;
const AUDIO_FRAME_COUNT: usize = 240;
const AUDIO_PACKET_DURATION: Duration = Duration::from_millis(5);
const MAXIMUM_AUDIO_CATCHUP: Duration = Duration::from_millis(100);
type BridgeController = c_void;
type MacOpusEncoder = c_void;
type SampleBuffer = *const c_void;
type FormatDescription = *const c_void;
type BlockBuffer = *const c_void;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacSinkMode {
    hidpi: bool,
    scale_explicit: bool,
    mode_is_logical: bool,
    scale_percent: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacSinkCapability {
    gamut: i32,
    transfer: i32,
    current_edr_headroom: f32,
    potential_edr_headroom: f32,
    current_peak_luminance_nits: i32,
    potential_peak_luminance_nits: i32,
    supports_frame_gated_hdr: bool,
    supports_hdr_tile_overlay: bool,
    supports_per_frame_hdr_metadata: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacSinkRequest {
    mode: MacSinkMode,
    capability: MacSinkCapability,
    dynamic_range_transport: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacHdrStaticMetadata {
    values: [i32; 13],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacEffectiveDisplayState {
    gamut: i32,
    transfer: i32,
    has_hdr_static_metadata: bool,
    hdr_static_metadata: MacHdrStaticMetadata,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacCaptureConfiguration {
    display_id: u32,
    codec: i32,
    video_profile: i32,
    chroma_subsampling: i32,
    bit_depth: u8,
    dynamic_range: i32,
    color_range: i32,
    preprocess_strategy: i32,
    queue_profile: i32,
    target_frame_rate: i32,
    target_video_bitrate_kbps: i32,
    requested_width: i32,
    requested_height: i32,
    sink_request: MacSinkRequest,
    effective_display_state: MacEffectiveDisplayState,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MacAudioCaptureConfiguration {
    source_kind: i32,
    display_id: u32,
    excludes_current_process_audio: bool,
    sample_rate: i32,
    channel_count: i32,
    frame_size: i32,
    input_id: [c_char; 256],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MacWorkspaceSessionRequest {
    display_key: *const c_char,
    display_name: *const c_char,
    width: u32,
    height: u32,
    scale_percent: u32,
    dimensions_are_logical: bool,
    refresh_rate: f64,
    hdr_enabled: bool,
    sink_gamut: i32,
    sink_transfer: i32,
    current_edr_headroom: f32,
    potential_edr_headroom: f32,
    current_peak_luminance_nits: i32,
    potential_peak_luminance_nits: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MacWorkspaceActivationResult {
    activated: bool,
    isolation_status: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacEncodedFrameRecord {
    has_value: bool,
    codec: i32,
    payload_size: usize,
    source_sequence_number: u64,
    source_display_time: u64,
    has_output_callback_latency_milliseconds: bool,
    output_callback_latency_milliseconds: f64,
    is_key_frame: bool,
    is_hdr_signaled: bool,
    is_replay: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacAudioFrameRecord {
    has_value: bool,
    sequence_number: u64,
    host_time_nanoseconds: u64,
    sample_rate: i32,
    channel_count: i32,
    frame_count: i32,
    pcm_byte_count: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct MacAudioCaptureEventRecord {
    has_value: bool,
    kind: i32,
    has_stop_status: bool,
    stop_status: i32,
    has_automatic_restart_count: bool,
    automatic_restart_count: u64,
    has_source_sequence_number: bool,
    source_sequence_number: u64,
}

type CreateController = unsafe extern "C" fn() -> *mut BridgeController;
type DestroyController = unsafe extern "C" fn(*mut BridgeController);
type MakeVideoConfiguration = unsafe extern "C" fn(u32) -> MacCaptureConfiguration;
type MakeAudioConfiguration = unsafe extern "C" fn(u32) -> MacAudioCaptureConfiguration;
type ConfigureForwarding = unsafe extern "C" fn(*mut BridgeController, usize, usize);
type StartCapturePair = unsafe extern "C" fn(
    *mut BridgeController,
    MacCaptureConfiguration,
    MacAudioCaptureConfiguration,
    *mut c_char,
    usize,
) -> i32;
type StopCapture = unsafe extern "C" fn(*mut BridgeController);
type PopVideo =
    unsafe extern "C" fn(*mut BridgeController, *mut SampleBuffer) -> MacEncodedFrameRecord;
type PopAudio = unsafe extern "C" fn(
    *mut BridgeController,
    *mut c_void,
    usize,
    *mut usize,
) -> MacAudioFrameRecord;
type PopAudioEvent =
    unsafe extern "C" fn(*mut BridgeController, *mut c_char, usize) -> MacAudioCaptureEventRecord;
type RequestKeyFrame = unsafe extern "C" fn();
type ResumeVideoEncodingAfterCodecAck = unsafe extern "C" fn() -> bool;
type PrepareWorkspace = unsafe extern "C" fn(MacWorkspaceSessionRequest, *mut c_char, usize) -> u32;
type ActivateWorkspace =
    unsafe extern "C" fn(*const c_char, *mut c_char, usize) -> MacWorkspaceActivationResult;
type StopWorkspace = unsafe extern "C" fn(*const c_char, *mut c_char, usize) -> bool;
type PublishRuntimeEvent = unsafe extern "C" fn(u32, u32, u32, *const c_char);
type CreateOpusEncoder = unsafe extern "C" fn(
    i32,
    i32,
    i32,
    i32,
    *const u8,
    i32,
    bool,
    *mut c_char,
    usize,
) -> *mut MacOpusEncoder;
type EncodeOpusFloat32 = unsafe extern "C" fn(
    *mut MacOpusEncoder,
    *const f32,
    i32,
    *mut u8,
    usize,
    *mut usize,
    *mut c_char,
    usize,
) -> bool;
type DestroyOpusEncoder = unsafe extern "C" fn(*mut MacOpusEncoder);

struct MacBridgeApi {
    handle: *mut c_void,
    create_controller: CreateController,
    destroy_controller: DestroyController,
    make_video_configuration: MakeVideoConfiguration,
    make_audio_configuration: MakeAudioConfiguration,
    configure_video_forwarding: ConfigureForwarding,
    configure_audio_forwarding: ConfigureForwarding,
    start_capture_pair: StartCapturePair,
    stop_video_capture: StopCapture,
    stop_audio_capture: StopCapture,
    pop_video: PopVideo,
    pop_audio: PopAudio,
    pop_audio_event: PopAudioEvent,
    request_key_frame: RequestKeyFrame,
    resume_video_encoding_after_codec_ack: ResumeVideoEncodingAfterCodecAck,
    prepare_workspace: PrepareWorkspace,
    activate_workspace: ActivateWorkspace,
    stop_workspace: StopWorkspace,
    publish_runtime_event: PublishRuntimeEvent,
    create_opus_encoder: CreateOpusEncoder,
    encode_opus_float32: EncodeOpusFloat32,
    destroy_opus_encoder: DestroyOpusEncoder,
}

unsafe impl Send for MacBridgeApi {}
unsafe impl Sync for MacBridgeApi {}

impl MacBridgeApi {
    fn load() -> Result<Self, String> {
        let path = framework_path()?;
        let path = CString::new(path.to_string_lossy().as_bytes())
            .map_err(|_| "macOS bridge path contains a null byte".to_owned())?;
        let handle = unsafe { dlopen(path.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
        if handle.is_null() {
            return Err(format!("could not load LumenMacBridge: {}", dl_error()));
        }
        unsafe {
            Ok(Self {
                handle,
                create_controller: load_symbol(handle, b"LumenMacBridgeControllerCreate\0")?,
                destroy_controller: load_symbol(handle, b"LumenMacBridgeControllerDestroy\0")?,
                make_video_configuration: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerMakePanelNativeConfiguration\0",
                )?,
                make_audio_configuration: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerMakeSystemOutputAudioConfiguration\0",
                )?,
                configure_video_forwarding: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerConfigureVideoForwarding\0",
                )?,
                configure_audio_forwarding: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerConfigureAudioForwarding\0",
                )?,
                start_capture_pair: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerStartCapturePair\0",
                )?,
                stop_video_capture: load_symbol(handle, b"LumenMacBridgeControllerStopCapture\0")?,
                stop_audio_capture: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerStopAudioCapture\0",
                )?,
                pop_video: load_symbol(handle, b"LumenMacBridgeControllerPopNextForwardedFrame\0")?,
                pop_audio: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerPopNextForwardedAudioFrame\0",
                )?,
                pop_audio_event: load_symbol(
                    handle,
                    b"LumenMacBridgeControllerPopNextForwardedAudioEvent\0",
                )?,
                request_key_frame: load_symbol(
                    handle,
                    b"LumenMacBridgeRequestImmediateCaptureKeyFrame\0",
                )?,
                resume_video_encoding_after_codec_ack: load_symbol(
                    handle,
                    b"LumenMacBridgeResumeVideoEncodingAfterCodecAck\0",
                )?,
                prepare_workspace: load_symbol(handle, b"LumenMacWorkspacePrepareSession\0")?,
                activate_workspace: load_symbol(handle, b"LumenMacWorkspaceActivateSession\0")?,
                stop_workspace: load_symbol(handle, b"LumenMacWorkspaceStopSession\0")?,
                publish_runtime_event: load_symbol(handle, b"LumenMacBridgePublishRuntimeEvent\0")?,
                create_opus_encoder: load_symbol(handle, b"LumenMacOpusEncoderCreate\0")?,
                encode_opus_float32: load_symbol(handle, b"LumenMacOpusEncoderEncodeFloat32\0")?,
                destroy_opus_encoder: load_symbol(handle, b"LumenMacOpusEncoderDestroy\0")?,
            })
        }
    }
}

impl Drop for MacBridgeApi {
    fn drop(&mut self) {
        unsafe { dlclose(self.handle) };
    }
}

struct MacSessionState {
    controller: *mut BridgeController,
    workspace_key: Option<CString>,
    display_id: u32,
    opus: Option<NativeOpusEncoder>,
    audio_channels: usize,
    pcm: Vec<u8>,
    audio_scratch: Vec<u8>,
    next_audio_timestamp: u32,
    next_audio_deadline: Option<Instant>,
    audio_capture_failure: Option<String>,
}

unsafe impl Send for MacSessionState {}

pub(crate) struct MacPlatformSessionControl {
    api: MacBridgeApi,
    state: Mutex<MacSessionState>,
    native_input: MacNativeInput,
    application: PortableApplication,
}

impl MacPlatformSessionControl {
    pub(crate) fn new() -> Result<Self, String> {
        let api = MacBridgeApi::load()?;
        let controller = unsafe { (api.create_controller)() };
        if controller.is_null() {
            return Err("could not create the macOS capture bridge".to_owned());
        }
        Ok(Self {
            api,
            state: Mutex::new(MacSessionState {
                controller,
                workspace_key: None,
                display_id: 0,
                opus: None,
                audio_channels: 0,
                pcm: Vec::new(),
                audio_scratch: vec![0; MAXIMUM_PCM_BYTES],
                next_audio_timestamp: 0,
                next_audio_deadline: None,
                audio_capture_failure: None,
            }),
            native_input: MacNativeInput::default(),
            application: PortableApplication::default(),
        })
    }

    fn stop_locked(&self, state: &mut MacSessionState) -> Result<(), String> {
        unsafe {
            (self.api.stop_audio_capture)(state.controller);
            (self.api.stop_video_capture)(state.controller);
        }
        let mut failure = None;
        if let Some(key) = state.workspace_key.take() {
            let mut error = [0_i8; 1024];
            if !unsafe { (self.api.stop_workspace)(key.as_ptr(), error.as_mut_ptr(), error.len()) }
            {
                failure = Some(format!("workspace stop failed: {}", error_text(&error)));
            }
        }
        state.display_id = 0;
        state.opus = None;
        state.audio_channels = 0;
        state.pcm.clear();
        state.next_audio_deadline = None;
        state.audio_capture_failure = None;
        failure.map_or(Ok(()), Err)
    }
}

impl PlatformSessionControl for MacPlatformSessionControl {
    fn start_application(&self, plan: PlatformApplicationPlan) -> Result<(), String> {
        self.application.start(plan)
    }

    fn stop_application(&self) -> Result<(), String> {
        self.application.stop()
    }

    fn start_session(&self, plan: PlatformSessionPlan) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
        self.stop_locked(&mut state)?;
        let startup = (|| -> Result<(), String> {
            let workspace_key =
                CString::new(format!("lumen-workspace-{}", monotonic_nanoseconds()))
                    .map_err(|_| "workspace key is invalid".to_owned())?;
            let display_name = CString::new("Lumen Display").expect("static display name");
            let display_id = if plan.virtual_display {
                let mut error = [0_i8; 1024];
                let request = MacWorkspaceSessionRequest {
                    display_key: workspace_key.as_ptr(),
                    display_name: display_name.as_ptr(),
                    width: plan.width,
                    height: plan.height,
                    scale_percent: u32::try_from(plan.sink_scale_percent.max(1)).unwrap_or(100),
                    dimensions_are_logical: plan.sink_mode_is_logical,
                    refresh_rate: f64::from(plan.frames_per_second),
                    hdr_enabled: matches!(
                        plan.video_format.dynamic_range,
                        crate::PlatformDynamicRange::Hdr10
                    ),
                    sink_gamut: plan.sink_gamut,
                    sink_transfer: plan.sink_transfer,
                    current_edr_headroom: plan.sink_current_edr_headroom,
                    potential_edr_headroom: plan.sink_potential_edr_headroom,
                    current_peak_luminance_nits: plan.sink_current_peak_luminance_nits,
                    potential_peak_luminance_nits: plan.sink_potential_peak_luminance_nits,
                };
                let display_id = unsafe {
                    (self.api.prepare_workspace)(request, error.as_mut_ptr(), error.len())
                };
                if display_id == 0 {
                    return Err(format!(
                        "platform display could not be created: {}",
                        error_text(&error)
                    ));
                }
                state.workspace_key = Some(workspace_key);
                display_id
            } else {
                unsafe { CGMainDisplayID() }
            };
            state.display_id = display_id;
            let stream = resolve_audio_stream(LumenAudioStreamRequest {
                channels: i32::from(plan.audio_channels),
                packet_duration_milliseconds: 5,
                enhanced_audio_quality: plan.enhanced_audio_quality,
            })
            .map_err(|status| format!("audio stream policy rejected the session: {status:?}"))?;
            state.opus = Some(NativeOpusEncoder::new(
                &self.api,
                &stream,
                plan.enhanced_audio_quality,
            )?);
            state.audio_channels = usize::from(plan.audio_channels);
            unsafe {
                (self.api.configure_video_forwarding)(state.controller, 3, 16);
                (self.api.configure_audio_forwarding)(state.controller, 8, 16);
            }
            let mut video = unsafe { (self.api.make_video_configuration)(display_id) };
            video.codec = match plan.video_format.codec {
                crate::PlatformVideoCodec::H264 => 0,
                crate::PlatformVideoCodec::Hevc => 1,
                crate::PlatformVideoCodec::Av1 => {
                    return Err("AV1 is unavailable on macOS".to_owned())
                }
            };
            video.video_profile = plan.video_format.profile as i32;
            video.chroma_subsampling = plan.video_format.chroma_subsampling as i32;
            video.bit_depth = plan.video_format.bit_depth;
            video.dynamic_range = plan.video_format.dynamic_range as i32;
            video.color_range = plan.video_format.color_range as i32;
            video.target_frame_rate = i32::try_from(plan.frames_per_second).unwrap_or(i32::MAX);
            video.target_video_bitrate_kbps = i32::try_from(plan.bitrate_kbps).unwrap_or(i32::MAX);
            video.requested_width = i32::try_from(plan.width).unwrap_or(i32::MAX);
            video.requested_height = i32::try_from(plan.height).unwrap_or(i32::MAX);
            video.sink_request.mode = MacSinkMode {
                hidpi: plan.sink_hidpi,
                scale_explicit: plan.sink_scale_explicit,
                mode_is_logical: plan.sink_mode_is_logical,
                scale_percent: plan.sink_scale_percent,
            };
            video.sink_request.capability = MacSinkCapability {
                gamut: plan.sink_gamut,
                transfer: plan.sink_transfer,
                current_edr_headroom: plan.sink_current_edr_headroom,
                potential_edr_headroom: plan.sink_potential_edr_headroom,
                current_peak_luminance_nits: plan.sink_current_peak_luminance_nits,
                potential_peak_luminance_nits: plan.sink_potential_peak_luminance_nits,
                supports_frame_gated_hdr: plan.sink_supports_frame_gated_hdr,
                supports_hdr_tile_overlay: plan.sink_supports_hdr_tile_overlay,
                supports_per_frame_hdr_metadata: plan.sink_supports_per_frame_hdr_metadata,
            };
            video.sink_request.dynamic_range_transport =
                i32::try_from(plan.negotiated_dynamic_range_transport).unwrap_or_default();
            video.effective_display_state.gamut = plan.sink_gamut;
            video.effective_display_state.transfer = plan.sink_transfer;
            let mut audio = unsafe { (self.api.make_audio_configuration)(display_id) };
            audio.sample_rate = 48_000;
            audio.channel_count = i32::from(plan.audio_channels);
            audio.frame_size = AUDIO_FRAME_COUNT as i32;
            let mut error = [0_i8; 1024];
            let capture_status = unsafe {
                (self.api.start_capture_pair)(
                    state.controller,
                    video,
                    audio,
                    error.as_mut_ptr(),
                    error.len(),
                )
            };
            state.audio_capture_failure =
                capture_pair_audio_failure(capture_status, error_text(&error))?;
            error.fill(0);
            if plan.virtual_display {
                let key = state.workspace_key.as_ref().expect("workspace key");
                let outcome = unsafe {
                    (self.api.activate_workspace)(key.as_ptr(), error.as_mut_ptr(), error.len())
                };
                if !outcome.activated {
                    return Err(format!(
                        "workspace activation failed: {}",
                        error_text(&error)
                    ));
                }
                let event = workspace_isolation_event(outcome, error_text(&error))?;
                self.publish_runtime_event(event)?;
            }
            state.next_audio_timestamp = audio_timestamp(monotonic_nanoseconds());
            state.next_audio_deadline = Some(Instant::now());
            Ok(())
        })();
        if let Err(startup_error) = startup {
            return match self.stop_locked(&mut state) {
                Ok(()) => Err(startup_error),
                Err(cleanup_error) => Err(format!(
                    "{startup_error}; platform session rollback failed: {cleanup_error}"
                )),
            };
        }
        Ok(())
    }

    fn stop_session(&self) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS platform session state is unavailable".to_owned())?;
        self.stop_locked(&mut state)
    }

    fn poll_encoded_video(&self) -> Result<Option<PlatformEncodedVideoFrame>, String> {
        let state = self
            .state
            .lock()
            .map_err(|_| "macOS video state is unavailable".to_owned())?;
        let mut sample = ptr::null();
        let record = unsafe { (self.api.pop_video)(state.controller, &mut sample) };
        if !record.has_value {
            return Ok(None);
        }
        if sample.is_null() {
            return Err("macOS video frame omitted its sample buffer".to_owned());
        }
        let result = copy_annex_b_sample(sample, record.codec, record.is_key_frame);
        unsafe { CFRelease(sample) };
        let (payload, timestamp) = result?;
        Ok(Some(PlatformEncodedVideoFrame {
            payload,
            decoder_configuration_record: None,
            presentation_time_90khz: timestamp,
            key_frame: record.is_key_frame,
        }))
    }

    fn poll_encoded_audio(&self) -> Result<Option<PlatformEncodedAudioPacket>, String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "macOS audio state is unavailable".to_owned())?;
        let mut event_message = [0_i8; 1024];
        loop {
            event_message.fill(0);
            let event = unsafe {
                (self.api.pop_audio_event)(
                    state.controller,
                    event_message.as_mut_ptr(),
                    event_message.len(),
                )
            };
            if !event.has_value {
                break;
            }
            match event.kind {
                0 => state.audio_capture_failure = None,
                3 => {
                    let message = error_text(&event_message);
                    state.audio_capture_failure = Some(if message.is_empty() {
                        "macOS audio capture failed".to_owned()
                    } else {
                        message
                    });
                }
                _ => {}
            }
        }
        if let Some(failure) = &state.audio_capture_failure {
            return Err(failure.clone());
        }
        let packet_bytes = AUDIO_FRAME_COUNT * state.audio_channels * std::mem::size_of::<f32>();
        for _ in 0..8 {
            if state.pcm.len() >= packet_bytes {
                break;
            }
            let mut copied = 0;
            let record = unsafe {
                (self.api.pop_audio)(
                    state.controller,
                    state.audio_scratch.as_mut_ptr().cast(),
                    state.audio_scratch.len(),
                    &mut copied,
                )
            };
            if !record.has_value {
                break;
            }
            if record.sample_rate != 48_000
                || usize::try_from(record.channel_count).ok() != Some(state.audio_channels)
                || copied != record.pcm_byte_count
                || copied > state.audio_scratch.len()
            {
                state.pcm.clear();
                return Err("macOS audio capture returned inconsistent PCM metadata".to_owned());
            }
            let bytes = state.audio_scratch[..copied].to_vec();
            state.pcm.extend_from_slice(&bytes);
        }
        let Some(mut deadline) = state.next_audio_deadline else {
            return Ok(None);
        };
        let now = Instant::now();
        if now < deadline {
            return Ok(None);
        }
        if now.duration_since(deadline) > MAXIMUM_AUDIO_CATCHUP {
            state.next_audio_timestamp = audio_timestamp(monotonic_nanoseconds());
            deadline = now;
        }
        if state.pcm.len() < packet_bytes {
            state.pcm.resize(packet_bytes, 0);
        }
        let samples = state.pcm[..packet_bytes]
            .chunks_exact(4)
            .map(|bytes| f32::from_le_bytes(bytes.try_into().expect("four PCM bytes")))
            .collect::<Vec<_>>();
        let packet = state
            .opus
            .as_mut()
            .ok_or_else(|| "macOS Opus encoder is unavailable".to_owned())?
            .encode(&samples, AUDIO_FRAME_COUNT as i32)?;
        state.pcm.drain(..packet_bytes);
        let timestamp = state.next_audio_timestamp;
        state.next_audio_timestamp = state
            .next_audio_timestamp
            .wrapping_add(AUDIO_FRAME_COUNT as u32);
        state.next_audio_deadline = Some(deadline + AUDIO_PACKET_DURATION);
        Ok(Some(PlatformEncodedAudioPacket {
            payload: packet,
            presentation_time_48khz: timestamp,
            duration_frames: AUDIO_FRAME_COUNT as u32,
        }))
    }

    fn handle_control_event(&self, _: u32, event: PlatformControlEvent) -> Result<(), String> {
        match event {
            PlatformControlEvent::RequestIdrFrame
            | PlatformControlEvent::InvalidateReferenceFrames { .. } => {
                unsafe { (self.api.request_key_frame)() };
                Ok(())
            }
            PlatformControlEvent::ResumeVideoEncodingAfterCodecAck => {
                unsafe { (self.api.resume_video_encoding_after_codec_ack)() }
                    .then_some(())
                    .ok_or_else(|| {
                        "macOS video encoding could not resume after codec acknowledgement"
                            .to_owned()
                    })
            }
            PlatformControlEvent::ResetInput => Ok(()),
            PlatformControlEvent::ExecuteServerCommand { index } => {
                self.application.execute_server_command(index)
            }
        }
    }

    fn handle_native_input(
        &self,
        session_epoch: u32,
        event: PlatformNativeInputEvent,
    ) -> Result<(), String> {
        self.native_input.handle(session_epoch, event)
    }

    fn handle_native_motion(
        &self,
        session_epoch: u32,
        event: crate::PlatformNativeMotionEvent,
    ) -> Result<(), String> {
        let display_id = self
            .state
            .lock()
            .map_err(|_| "macOS platform session state is unavailable".to_owned())?
            .display_id;
        if display_id == 0 {
            return Err("macOS native motion has no active display".to_owned());
        }
        self.native_input
            .handle_motion(session_epoch, display_id, event)
    }

    fn reset_native_input(&self, session_epoch: u32) -> Result<(), String> {
        self.native_input.reset(session_epoch)
    }

    fn publish_runtime_event(&self, event: PlatformRuntimeEvent) -> Result<(), String> {
        let message = event
            .message
            .map(CString::new)
            .transpose()
            .map_err(|_| "runtime event contains a null byte".to_owned())?;
        unsafe {
            (self.api.publish_runtime_event)(
                match event.disposition {
                    PlatformRuntimeEventDisposition::Raised => 0,
                    PlatformRuntimeEventDisposition::Cleared => 1,
                },
                match event.severity {
                    PlatformRuntimeEventSeverity::Warning => 0,
                    PlatformRuntimeEventSeverity::Error => 1,
                },
                event.code as u32,
                message.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
            )
        };
        Ok(())
    }
}

impl Drop for MacPlatformSessionControl {
    fn drop(&mut self) {
        if let Ok(mut state) = self.state.lock() {
            let _ = self.stop_locked(&mut state);
            unsafe { (self.api.destroy_controller)(state.controller) };
            state.controller = ptr::null_mut();
        }
    }
}

struct NativeOpusEncoder {
    encoder: *mut MacOpusEncoder,
    encode: EncodeOpusFloat32,
    destroy: DestroyOpusEncoder,
}

unsafe impl Send for NativeOpusEncoder {}

impl NativeOpusEncoder {
    fn new(
        api: &MacBridgeApi,
        stream: &lumen_engine::LumenAudioStreamPlan,
        enhanced: bool,
    ) -> Result<Self, String> {
        let mut error = [0_i8; 1024];
        let encoder = unsafe {
            (api.create_opus_encoder)(
                stream.sample_rate,
                stream.channel_count,
                stream.streams,
                stream.coupled_streams,
                stream.mapping.as_ptr(),
                stream.bitrate,
                enhanced,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if encoder.is_null() {
            return Err(error_text(&error));
        }
        Ok(Self {
            encoder,
            encode: api.encode_opus_float32,
            destroy: api.destroy_opus_encoder,
        })
    }

    fn encode(&mut self, samples: &[f32], frame_count: i32) -> Result<Vec<u8>, String> {
        let mut packet = vec![0_u8; 1_275];
        let mut packet_size = 0;
        let mut error = [0_i8; 1024];
        let encoded = unsafe {
            (self.encode)(
                self.encoder,
                samples.as_ptr(),
                frame_count,
                packet.as_mut_ptr(),
                packet.len(),
                &mut packet_size,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if !encoded {
            return Err(error_text(&error));
        }
        packet.truncate(packet_size);
        Ok(packet)
    }
}

impl Drop for NativeOpusEncoder {
    fn drop(&mut self) {
        unsafe { (self.destroy)(self.encoder) };
    }
}

fn copy_annex_b_sample(
    sample: SampleBuffer,
    codec: i32,
    key_frame: bool,
) -> Result<(Vec<u8>, u32), String> {
    let format = unsafe { CMSampleBufferGetFormatDescription(sample) };
    let block = unsafe { CMSampleBufferGetDataBuffer(sample) };
    if format.is_null() || block.is_null() {
        return Err("encoded sample omitted its format or block buffer".to_owned());
    }
    let mut count = 0;
    let mut bytes = ptr::null();
    let mut length = 0;
    let mut nal_length_size = 0;
    let status = unsafe {
        parameter_set(
            codec,
            format,
            0,
            &mut bytes,
            &mut length,
            &mut count,
            &mut nal_length_size,
        )
    };
    if status != 0 || count == 0 || !(1..=4).contains(&nal_length_size) {
        return Err("encoded sample parameter sets are unavailable".to_owned());
    }
    let nal_length_size = usize::try_from(nal_length_size)
        .map_err(|_| "encoded sample NAL length field is invalid".to_owned())?;
    let mut output = Vec::new();
    if key_frame {
        for index in 0..count {
            let status = unsafe {
                parameter_set(
                    codec,
                    format,
                    index,
                    &mut bytes,
                    &mut length,
                    ptr::null_mut(),
                    ptr::null_mut(),
                )
            };
            if status != 0 || bytes.is_null() || length == 0 {
                return Err("encoded sample parameter set is invalid".to_owned());
            }
            output.extend_from_slice(&[0, 0, 0, 1]);
            output.extend_from_slice(unsafe { std::slice::from_raw_parts(bytes, length) });
        }
    }
    let input_length = unsafe { CMBlockBufferGetDataLength(block) };
    if input_length == 0 || input_length > MAXIMUM_VIDEO_BYTES {
        return Err("encoded sample size is invalid".to_owned());
    }
    let mut input = vec![0_u8; input_length];
    if unsafe { CMBlockBufferCopyDataBytes(block, 0, input_length, input.as_mut_ptr().cast()) } != 0
    {
        return Err("could not copy the encoded sample".to_owned());
    }
    let mut offset = 0;
    while offset + nal_length_size <= input.len() {
        let mut nal_length = 0_usize;
        for byte in &input[offset..offset + nal_length_size] {
            nal_length = (nal_length << 8) | usize::from(*byte);
        }
        offset += nal_length_size;
        if nal_length == 0 || offset + nal_length > input.len() {
            return Err("encoded sample NAL length is invalid".to_owned());
        }
        output.extend_from_slice(&[0, 0, 0, 1]);
        output.extend_from_slice(&input[offset..offset + nal_length]);
        offset += nal_length;
    }
    if offset != input.len() || output.len() > MAXIMUM_VIDEO_BYTES {
        return Err("encoded sample framing is invalid".to_owned());
    }
    let time = unsafe { CMSampleBufferGetPresentationTimeStamp(sample) };
    let timestamp = if time.timescale > 0 {
        ((i128::from(time.value) * 90_000) / i128::from(time.timescale)) as u32
    } else {
        0
    };
    Ok((output, timestamp))
}

fn workspace_isolation_event(
    outcome: MacWorkspaceActivationResult,
    message: String,
) -> Result<PlatformRuntimeEvent, String> {
    let cleared = || PlatformRuntimeEvent {
        disposition: PlatformRuntimeEventDisposition::Cleared,
        severity: PlatformRuntimeEventSeverity::Warning,
        code: crate::PlatformRuntimeEventCode::PhysicalDisplayIsolation,
        message: None,
    };
    match outcome.isolation_status {
        0 | 1 | 3 => Ok(cleared()),
        2 => Ok(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Warning,
            code: crate::PlatformRuntimeEventCode::PhysicalDisplayIsolation,
            message: Some(if message.is_empty() {
                "physical display isolation is unavailable".to_owned()
            } else {
                message
            }),
        }),
        4 => Err(if message.is_empty() {
            "physical display isolation failed".to_owned()
        } else {
            message
        }),
        status => Err(format!(
            "macOS workspace returned an invalid isolation status {status}"
        )),
    }
}

fn capture_pair_audio_failure(status: i32, error: String) -> Result<Option<String>, String> {
    match status {
        0 => Ok(None),
        2 => Ok(Some(if error.is_empty() {
            "macOS audio capture could not be scheduled".to_owned()
        } else {
            error
        })),
        1 => Err(format!("video capture failed: {error}")),
        _ => Err(format!("capture pair failed: {error}")),
    }
}

unsafe fn parameter_set(
    codec: i32,
    format: FormatDescription,
    index: usize,
    bytes: *mut *const u8,
    length: *mut usize,
    count: *mut usize,
    nal_length_size: *mut c_int,
) -> i32 {
    if codec == 0 {
        unsafe {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                index,
                bytes,
                length,
                count,
                nal_length_size,
            )
        }
    } else {
        unsafe {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                index,
                bytes,
                length,
                count,
                nal_length_size,
            )
        }
    }
}

fn framework_path() -> Result<PathBuf, String> {
    let executable = std::env::current_exe()
        .map_err(|error| format!("could not locate the Rust host worker: {error}"))?;
    Ok(executable
        .parent()
        .ok_or_else(|| "Rust host worker has no parent directory".to_owned())?
        .join("../Frameworks/LumenMacBridge.framework/LumenMacBridge"))
}

unsafe fn load_symbol<T: Copy>(handle: *mut c_void, name: &[u8]) -> Result<T, String> {
    let symbol = unsafe { dlsym(handle, name.as_ptr().cast()) };
    if symbol.is_null() {
        Err(format!(
            "LumenMacBridge symbol {} is missing: {}",
            String::from_utf8_lossy(&name[..name.len().saturating_sub(1)]),
            dl_error()
        ))
    } else {
        Ok(unsafe { std::mem::transmute_copy(&symbol) })
    }
}

fn dl_error() -> String {
    let error = unsafe { dlerror() };
    if error.is_null() {
        "unknown dynamic-loader error".to_owned()
    } else {
        unsafe { CStr::from_ptr(error) }
            .to_string_lossy()
            .into_owned()
    }
}

fn error_text(buffer: &[c_char]) -> String {
    unsafe { CStr::from_ptr(buffer.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

fn monotonic_nanoseconds() -> u64 {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC_RAW, &mut time) } != 0 {
        0
    } else {
        (time.tv_sec as u64)
            .saturating_mul(1_000_000_000)
            .saturating_add(time.tv_nsec as u64)
    }
}

fn audio_timestamp(nanoseconds: u64) -> u32 {
    ((nanoseconds / 1_000_000_000) * 48_000
        + ((nanoseconds % 1_000_000_000) * 48_000) / 1_000_000_000) as u32
}

#[repr(C)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

const RTLD_LOCAL: c_int = 0x4;
const RTLD_NOW: c_int = 0x2;

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlclose(handle: *mut c_void) -> c_int;
    fn dlerror() -> *const c_char;
    fn CGMainDisplayID() -> u32;
    fn CFRelease(value: *const c_void);
    fn CMSampleBufferGetFormatDescription(sample: SampleBuffer) -> FormatDescription;
    fn CMSampleBufferGetDataBuffer(sample: SampleBuffer) -> BlockBuffer;
    fn CMSampleBufferGetPresentationTimeStamp(sample: SampleBuffer) -> CMTime;
    fn CMBlockBufferGetDataLength(buffer: BlockBuffer) -> usize;
    fn CMBlockBufferCopyDataBytes(
        buffer: BlockBuffer,
        offset: usize,
        length: usize,
        destination: *mut c_void,
    ) -> i32;
    fn CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format: FormatDescription,
        index: usize,
        bytes: *mut *const u8,
        length: *mut usize,
        count: *mut usize,
        nal_length_size: *mut c_int,
    ) -> i32;
    fn CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        format: FormatDescription,
        index: usize,
        bytes: *mut *const u8,
        length: *mut usize,
        count: *mut usize,
        nal_length_size: *mut c_int,
    ) -> i32;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PlatformRuntimeEventCode;

    #[test]
    fn pending_isolation_keeps_session_start_nonfatal_and_clears_stale_warning() {
        let event = workspace_isolation_event(
            MacWorkspaceActivationResult {
                activated: true,
                isolation_status: 3,
            },
            String::new(),
        )
        .expect("pending isolation remains a valid active session");

        assert_eq!(event.disposition, PlatformRuntimeEventDisposition::Cleared);
        assert_eq!(event.severity, PlatformRuntimeEventSeverity::Warning);
        assert_eq!(
            event.code,
            PlatformRuntimeEventCode::PhysicalDisplayIsolation
        );
    }

    #[test]
    fn unavailable_isolation_is_a_typed_nonfatal_warning() {
        let event = workspace_isolation_event(
            MacWorkspaceActivationResult {
                activated: true,
                isolation_status: 2,
            },
            "display 114 was not published".to_owned(),
        )
        .expect("unavailable isolation must not fail stream startup");

        assert_eq!(event.disposition, PlatformRuntimeEventDisposition::Raised);
        assert_eq!(event.severity, PlatformRuntimeEventSeverity::Warning);
        assert_eq!(
            event.code,
            PlatformRuntimeEventCode::PhysicalDisplayIsolation
        );
        assert_eq!(
            event.message.as_deref(),
            Some("display 114 was not published")
        );
    }

    #[test]
    fn capture_pair_keeps_audio_scheduling_failure_nonfatal() {
        assert_eq!(
            capture_pair_audio_failure(2, "audio route unavailable".to_owned()).unwrap(),
            Some("audio route unavailable".to_owned())
        );
        assert_eq!(capture_pair_audio_failure(0, String::new()).unwrap(), None);
    }

    #[test]
    fn capture_pair_preserves_video_start_failure_as_terminal() {
        assert_eq!(
            capture_pair_audio_failure(1, "capture rejected".to_owned()).unwrap_err(),
            "video capture failed: capture rejected"
        );
    }
}
