use std::ffi::c_void;
use std::mem::ManuallyDrop;
use std::ptr;
use std::slice;
use std::sync::{mpsc, Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use windows_api::core::Interface;
use windows_api::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11Texture2D};
use windows_api::Win32::Media::MediaFoundation::{
    eAVEncAV1VProfile_Main_420_10, eAVEncAV1VProfile_Main_420_8, eAVEncH264VProfile_High,
    eAVEncH265VProfile_Main_420_10, eAVEncH265VProfile_Main_420_8,
    CODECAPI_AVEncVideoForceKeyFrame, ICodecAPI, IMFActivate, IMFDXGIDeviceManager,
    IMFMediaEventGenerator, IMFMediaType, IMFSample, IMFTransform, METransformHaveOutput,
    METransformNeedInput, MFCreateAlignedMemoryBuffer, MFCreateDXGIDeviceManager,
    MFCreateDXGISurfaceBuffer, MFCreateMediaType, MFCreateSample, MFMediaType_Video,
    MFSampleExtension_CleanPoint, MFShutdown, MFStartup, MFTEnumEx, MFVideoFormat_AV1,
    MFVideoFormat_H264, MFVideoFormat_HEVC, MFVideoFormat_NV12, MFVideoFormat_P010,
    MFVideoInterlace_Progressive, MFSTARTUP_FULL, MFT_CATEGORY_VIDEO_ENCODER,
    MFT_ENUM_FLAG_HARDWARE, MFT_ENUM_FLAG_SORTANDFILTER, MFT_MESSAGE_COMMAND_FLUSH,
    MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, MFT_MESSAGE_NOTIFY_END_OF_STREAM,
    MFT_MESSAGE_NOTIFY_END_STREAMING, MFT_MESSAGE_NOTIFY_START_OF_STREAM,
    MFT_MESSAGE_SET_D3D_MANAGER, MFT_OUTPUT_DATA_BUFFER, MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES,
    MFT_OUTPUT_STREAM_INFO, MFT_OUTPUT_STREAM_PROVIDES_SAMPLES, MFT_REGISTER_TYPE_INFO,
    MF_EVENT_FLAG_NO_WAIT, MF_E_NO_EVENTS_AVAILABLE, MF_LOW_LATENCY, MF_MT_AVG_BITRATE,
    MF_MT_FRAME_RATE, MF_MT_FRAME_SIZE, MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE,
    MF_MT_MPEG2_PROFILE, MF_MT_PIXEL_ASPECT_RATIO, MF_MT_SUBTYPE, MF_TRANSFORM_ASYNC_UNLOCK,
    MF_VERSION,
};
use windows_api::Win32::System::Com::CoTaskMemFree;
use windows_api::Win32::System::Variant::VARIANT;

use super::native_capture::{NativeDesktopDuplication, NativeEncoderSurface};
use crate::{
    PlatformChromaSubsampling, PlatformDynamicRange, PlatformSessionPlan, PlatformVideoCodec,
};

const TRANSFORM_EVENT_TIMEOUT: Duration = Duration::from_secs(5);
const INITIAL_FRAME_TIMEOUT: Duration = Duration::from_secs(5);
const ACTIVE_CAPTURE_POLL_MILLISECONDS: u32 = 8;

type NativeVideoSink = Arc<dyn Fn(NativeEncodedVideoSample) -> Result<bool, String> + Send + Sync>;

pub(super) struct NativeMediaFoundation {
    commands: mpsc::SyncSender<NativeMediaFoundationCommand>,
    state: Arc<Mutex<NativeVideoWorkerState>>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

#[derive(Default)]
struct NativeVideoWorkerState {
    running: bool,
    error: Option<String>,
}

#[derive(Default)]
struct NativeVideoEncoderCatalog {
    h264: Option<IMFActivate>,
    hevc: Option<IMFActivate>,
    av1: Option<IMFActivate>,
}

struct NativeVideoEncoderSession {
    activation: IMFActivate,
    transform: IMFTransform,
    codec_api: ICodecAPI,
    events: IMFMediaEventGenerator,
    _device_manager: IMFDXGIDeviceManager,
    output_stream: MFT_OUTPUT_STREAM_INFO,
    frame_duration_hns: i64,
    pending_input_requests: usize,
    pending_output_samples: usize,
    is_shutdown: bool,
}

pub(super) struct NativeEncodedVideoSample {
    pub(super) payload: Vec<u8>,
    pub(super) presentation_time_90khz: u32,
    pub(super) key_frame: bool,
}

struct NativeVideoRuntime {
    duplication: NativeDesktopDuplication,
    encoder: NativeVideoEncoderSession,
    plan: NativeVideoEncoderPlan,
    next_timestamp_hns: i64,
}

enum NativeMediaFoundationCommand {
    Start {
        plan: NativeVideoEncoderPlan,
        adapter_name: String,
        output_name: String,
        response: mpsc::SyncSender<Result<(), String>>,
    },
    StopSession {
        response: mpsc::SyncSender<Result<(), String>>,
    },
    RequestKeyFrame {
        response: mpsc::SyncSender<Result<(), String>>,
    },
    Shutdown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct NativeVideoEncoderPlan {
    codec: PlatformVideoCodec,
    width: u32,
    height: u32,
    frames_per_second: u32,
    bitrate_bps: u32,
    ten_bit: bool,
}

impl NativeMediaFoundation {
    pub(super) fn start(sink: NativeVideoSink) -> Result<Self, String> {
        let (command_sender, command_receiver) = mpsc::sync_channel(4);
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let state = Arc::new(Mutex::new(NativeVideoWorkerState::default()));
        let worker_state = Arc::clone(&state);
        let worker = thread::Builder::new()
            .name("lumen-windows-media-foundation".to_owned())
            .spawn(move || run_media_foundation(command_receiver, ready_sender, sink, worker_state))
            .map_err(|error| format!("Windows Media Foundation worker failed to start: {error}"))?;
        match ready_receiver.recv() {
            Ok(Ok(())) => Ok(Self {
                commands: command_sender,
                state,
                worker: Mutex::new(Some(worker)),
            }),
            Ok(Err(error)) => {
                let _ = worker.join();
                Err(error)
            }
            Err(_) => {
                let _ = worker.join();
                Err("Windows Media Foundation worker exited during startup".to_owned())
            }
        }
    }

    pub(super) fn start_encoder(
        &self,
        plan: PlatformSessionPlan,
        adapter_name: &str,
        output_name: &str,
    ) -> Result<(), String> {
        let plan = NativeVideoEncoderPlan::try_from(plan)?;
        let (response, result) = mpsc::sync_channel(1);
        self.commands
            .send(NativeMediaFoundationCommand::Start {
                plan,
                adapter_name: adapter_name.to_owned(),
                output_name: output_name.to_owned(),
                response,
            })
            .map_err(|_| "Windows Media Foundation worker is unavailable".to_owned())?;
        result
            .recv()
            .map_err(|_| "Windows Media Foundation start response was lost".to_owned())?
    }

    pub(super) fn stop_encoder(&self) -> Result<(), String> {
        self.request(|response| NativeMediaFoundationCommand::StopSession { response })
    }

    pub(super) fn request_key_frame(&self) -> Result<(), String> {
        self.request(|response| NativeMediaFoundationCommand::RequestKeyFrame { response })
    }

    pub(super) fn take_error(&self) -> Result<Option<String>, String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Windows native video state is poisoned".to_owned())?;
        Ok(state.error.take())
    }

    fn request(
        &self,
        command: impl FnOnce(mpsc::SyncSender<Result<(), String>>) -> NativeMediaFoundationCommand,
    ) -> Result<(), String> {
        let (response, result) = mpsc::sync_channel(1);
        self.commands
            .send(command(response))
            .map_err(|_| "Windows Media Foundation worker is unavailable".to_owned())?;
        result
            .recv()
            .map_err(|_| "Windows Media Foundation command response was lost".to_owned())?
    }
}

impl Drop for NativeMediaFoundation {
    fn drop(&mut self) {
        let _ = self.commands.send(NativeMediaFoundationCommand::Shutdown);
        if let Ok(worker) = self.worker.get_mut() {
            if let Some(worker) = worker.take() {
                let _ = worker.join();
            }
        }
    }
}

fn run_media_foundation(
    commands: mpsc::Receiver<NativeMediaFoundationCommand>,
    ready: mpsc::SyncSender<Result<(), String>>,
    sink: NativeVideoSink,
    state: Arc<Mutex<NativeVideoWorkerState>>,
) {
    if let Err(error) = unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) } {
        let _ = ready.send(Err(format!(
            "Windows Media Foundation startup failed: {error}"
        )));
        return;
    }
    let catalog = match NativeVideoEncoderCatalog::discover() {
        Ok(catalog) => catalog,
        Err(error) => {
            let _ = ready.send(Err(error));
            let _ = unsafe { MFShutdown() };
            return;
        }
    };
    if ready.send(Ok(())).is_err() {
        drop(catalog);
        let _ = unsafe { MFShutdown() };
        return;
    }
    let mut runtime = None;
    'worker: loop {
        let command = if runtime.is_some() {
            match commands.try_recv() {
                Ok(command) => Some(command),
                Err(mpsc::TryRecvError::Empty) => None,
                Err(mpsc::TryRecvError::Disconnected) => break,
            }
        } else {
            match commands.recv() {
                Ok(command) => Some(command),
                Err(_) => break,
            }
        };
        if let Some(command) = command {
            match command {
                NativeMediaFoundationCommand::Start {
                    plan,
                    adapter_name,
                    output_name,
                    response,
                } => {
                    if runtime.is_some() {
                        let _ = response.send(Err(
                            "Windows native video session is already running".to_owned(),
                        ));
                        continue;
                    }
                    let result = start_runtime(&catalog, plan, &adapter_name, &output_name, &sink);
                    match result {
                        Ok(started) => {
                            runtime = Some(started);
                            set_worker_state(&state, true, None);
                            let _ = response.send(Ok(()));
                        }
                        Err(error) => {
                            set_worker_state(&state, false, Some(error.clone()));
                            let _ = response.send(Err(error));
                        }
                    }
                }
                NativeMediaFoundationCommand::StopSession { response } => {
                    let result = stop_runtime(&mut runtime);
                    set_worker_state(&state, false, None);
                    let _ = response.send(result);
                }
                NativeMediaFoundationCommand::RequestKeyFrame { response } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(|runtime| runtime.encoder.force_key_frame());
                    let _ = response.send(result);
                }
                NativeMediaFoundationCommand::Shutdown => break 'worker,
            }
            continue;
        }
        let encoded = runtime
            .as_mut()
            .expect("active Windows worker owns a video runtime")
            .encode_next(ACTIVE_CAPTURE_POLL_MILLISECONDS);
        match encoded.and_then(|sample| {
            if let Some(sample) = sample {
                let request_key_frame = sink(sample)?;
                if request_key_frame {
                    runtime
                        .as_mut()
                        .expect("encoded frame came from an active runtime")
                        .encoder
                        .force_key_frame()?;
                }
            }
            Ok(())
        }) {
            Ok(()) => {}
            Err(error) => {
                let shutdown = stop_runtime(&mut runtime).err();
                let error = shutdown
                    .map(|shutdown| format!("{error}; {shutdown}"))
                    .unwrap_or(error);
                set_worker_state(&state, false, Some(error));
            }
        }
    }
    let _ = stop_runtime(&mut runtime);
    set_worker_state(&state, false, None);
    drop(catalog);
    let _ = unsafe { MFShutdown() };
}

fn start_runtime(
    catalog: &NativeVideoEncoderCatalog,
    plan: NativeVideoEncoderPlan,
    adapter_name: &str,
    output_name: &str,
    sink: &NativeVideoSink,
) -> Result<NativeVideoRuntime, String> {
    let duplication = NativeDesktopDuplication::open(adapter_name, output_name, plan.ten_bit)?;
    let encoder = catalog.activate(plan, duplication.device())?;
    let mut runtime = NativeVideoRuntime {
        duplication,
        encoder,
        plan,
        next_timestamp_hns: 0,
    };
    runtime.encoder.force_key_frame()?;
    let deadline = Instant::now() + INITIAL_FRAME_TIMEOUT;
    loop {
        if Instant::now() >= deadline {
            return Err("Windows native video readiness timed out".to_owned());
        }
        let Some(encoded) = runtime.encode_next(200)? else {
            continue;
        };
        if encoded.presentation_time_90khz != 0 || !encoded.key_frame {
            return Err(
                "Windows hardware encoder did not start on the required timestamp-zero key frame"
                    .to_owned(),
            );
        }
        if sink(encoded)? {
            runtime.encoder.force_key_frame()?;
        }
        return Ok(runtime);
    }
}

fn stop_runtime(runtime: &mut Option<NativeVideoRuntime>) -> Result<(), String> {
    match runtime.take() {
        Some(mut runtime) => runtime.encoder.shutdown(),
        None => Ok(()),
    }
}

fn set_worker_state(state: &Mutex<NativeVideoWorkerState>, running: bool, error: Option<String>) {
    if let Ok(mut state) = state.lock() {
        state.running = running;
        state.error = error;
    }
}

impl NativeVideoEncoderCatalog {
    fn discover() -> Result<Self, String> {
        Ok(Self {
            h264: hardware_encoder_activation(MFVideoFormat_H264)?,
            hevc: hardware_encoder_activation(MFVideoFormat_HEVC)?,
            av1: hardware_encoder_activation(MFVideoFormat_AV1)?,
        })
    }

    fn activate(
        &self,
        plan: NativeVideoEncoderPlan,
        device: &ID3D11Device,
    ) -> Result<NativeVideoEncoderSession, String> {
        let activation = match plan.codec {
            PlatformVideoCodec::H264 => self.h264.as_ref(),
            PlatformVideoCodec::Hevc => self.hevc.as_ref(),
            PlatformVideoCodec::Av1 => self.av1.as_ref(),
        }
        .ok_or_else(|| {
            format!(
                "Windows has no hardware Media Foundation encoder for {}",
                codec_name(plan.codec)
            )
        })?;
        let transform =
            unsafe { activation.ActivateObject::<IMFTransform>() }.map_err(|error| {
                format!(
                    "Windows Media Foundation could not activate the {} hardware encoder: {error}",
                    codec_name(plan.codec)
                )
            })?;
        let configured = configure_transform(&transform, plan, device).and_then(|manager| {
            unsafe {
                transform
                    .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
                    .map_err(|error| format!("encoder begin-streaming failed: {error}"))?;
                transform
                    .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
                    .map_err(|error| format!("encoder start-of-stream failed: {error}"))?;
            }
            Ok(manager)
        });
        let manager = match configured {
            Ok(manager) => manager,
            Err(error) => {
                let _ = unsafe { activation.ShutdownObject() };
                return Err(format!(
                    "Windows Media Foundation could not start the {} hardware encoder: {error}",
                    codec_name(plan.codec)
                ));
            }
        };
        let events = match transform.cast::<IMFMediaEventGenerator>() {
            Ok(events) => events,
            Err(error) => {
                let _ = unsafe { activation.ShutdownObject() };
                return Err(format!(
                    "Windows {} hardware encoder has no asynchronous event surface: {error}",
                    codec_name(plan.codec)
                ));
            }
        };
        let codec_api = match transform.cast::<ICodecAPI>() {
            Ok(codec_api) => codec_api,
            Err(error) => {
                let _ = unsafe { activation.ShutdownObject() };
                return Err(format!(
                    "Windows {} hardware encoder has no codec control surface: {error}",
                    codec_name(plan.codec)
                ));
            }
        };
        let output_stream = match unsafe { transform.GetOutputStreamInfo(0) } {
            Ok(output_stream) => output_stream,
            Err(error) => {
                let _ = unsafe { activation.ShutdownObject() };
                return Err(format!(
                    "Windows {} hardware encoder output description failed: {error}",
                    codec_name(plan.codec)
                ));
            }
        };
        Ok(NativeVideoEncoderSession {
            activation: activation.clone(),
            transform,
            codec_api,
            events,
            _device_manager: manager,
            output_stream,
            frame_duration_hns: 10_000_000_i64 / i64::from(plan.frames_per_second),
            pending_input_requests: 0,
            pending_output_samples: 0,
            is_shutdown: false,
        })
    }
}

impl NativeVideoRuntime {
    fn encode_next(
        &mut self,
        timeout_milliseconds: u32,
    ) -> Result<Option<NativeEncodedVideoSample>, String> {
        let Some(frame) = self.duplication.acquire_next_frame(timeout_milliseconds)? else {
            return Ok(None);
        };
        frame.validate()?;
        let surface = self.duplication.convert_frame(
            &frame,
            self.plan.width,
            self.plan.height,
            self.plan.frames_per_second,
            self.plan.ten_bit,
        )?;
        let timestamp = self.next_timestamp_hns;
        let encoded = self.encoder.encode(&surface, timestamp)?;
        self.next_timestamp_hns = self
            .next_timestamp_hns
            .checked_add(self.encoder.frame_duration_hns)
            .ok_or_else(|| "Windows video timestamp overflowed".to_owned())?;
        Ok(Some(encoded))
    }
}

impl NativeVideoEncoderSession {
    fn force_key_frame(&self) -> Result<(), String> {
        let enabled = VARIANT::from(true);
        unsafe {
            self.codec_api
                .SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &enabled)
        }
        .map_err(|error| format!("Windows hardware encoder rejected a key-frame request: {error}"))
    }

    fn encode(
        &mut self,
        surface: &NativeEncoderSurface,
        presentation_time_hns: i64,
    ) -> Result<NativeEncodedVideoSample, String> {
        self.wait_for_input_request()?;
        let sample = create_input_sample(surface, presentation_time_hns, self.frame_duration_hns)?;
        unsafe { self.transform.ProcessInput(0, &sample, 0) }
            .map_err(|error| format!("Windows hardware encoder rejected a GPU frame: {error}"))?;
        self.wait_for_output_sample()?;
        let sample = self.process_output()?;
        encoded_video_sample(&sample)
    }

    fn wait_for_input_request(&mut self) -> Result<(), String> {
        if self.pending_input_requests != 0 {
            self.pending_input_requests -= 1;
            return Ok(());
        }
        self.wait_for_transform_credit(true)
    }

    fn wait_for_output_sample(&mut self) -> Result<(), String> {
        if self.pending_output_samples != 0 {
            self.pending_output_samples -= 1;
            return Ok(());
        }
        self.wait_for_transform_credit(false)
    }

    fn wait_for_transform_credit(&mut self, needs_input: bool) -> Result<(), String> {
        let input_event = u32::try_from(METransformNeedInput.0)
            .map_err(|_| "Windows input event identifier is invalid".to_owned())?;
        let output_event = u32::try_from(METransformHaveOutput.0)
            .map_err(|_| "Windows output event identifier is invalid".to_owned())?;
        let deadline = Instant::now() + TRANSFORM_EVENT_TIMEOUT;
        loop {
            if Instant::now() >= deadline {
                return Err(format!(
                    "Windows hardware encoder timed out waiting for {}",
                    if needs_input { "input" } else { "output" }
                ));
            }
            match unsafe { self.events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                Ok(event) => {
                    let status = unsafe { event.GetStatus() }.map_err(|error| {
                        format!("Windows hardware encoder event status failed: {error}")
                    })?;
                    status.ok().map_err(|error| {
                        format!("Windows hardware encoder reported an event failure: {error}")
                    })?;
                    let event_type = unsafe { event.GetType() }.map_err(|error| {
                        format!("Windows hardware encoder event type failed: {error}")
                    })?;
                    if event_type == input_event {
                        if needs_input {
                            return Ok(());
                        }
                        self.pending_input_requests = self
                            .pending_input_requests
                            .checked_add(1)
                            .ok_or_else(|| "Windows encoder input credit overflowed".to_owned())?;
                        continue;
                    }
                    if event_type == output_event {
                        if !needs_input {
                            return Ok(());
                        }
                        self.pending_output_samples = self
                            .pending_output_samples
                            .checked_add(1)
                            .ok_or_else(|| "Windows encoder output credit overflowed".to_owned())?;
                        continue;
                    }
                    return Err(format!(
                        "Windows hardware encoder produced unsupported event {event_type}"
                    ));
                }
                Err(error) if error.code() == MF_E_NO_EVENTS_AVAILABLE => {
                    thread::sleep(Duration::from_millis(1));
                }
                Err(error) => {
                    return Err(format!(
                        "Windows hardware encoder event retrieval failed: {error}"
                    ));
                }
            }
        }
    }

    fn process_output(&self) -> Result<IMFSample, String> {
        let supplied_sample = if output_stream_provides_samples(self.output_stream.dwFlags)? {
            None
        } else {
            Some(create_output_sample(
                self.output_stream.cbSize,
                self.output_stream.cbAlignment,
            )?)
        };
        let mut output = MFT_OUTPUT_DATA_BUFFER {
            dwStreamID: 0,
            pSample: ManuallyDrop::new(supplied_sample),
            dwStatus: 0,
            pEvents: ManuallyDrop::new(None),
        };
        let mut status = 0_u32;
        let result = unsafe {
            self.transform
                .ProcessOutput(0, slice::from_mut(&mut output), &mut status)
        };
        let sample = unsafe { ManuallyDrop::take(&mut output.pSample) };
        let events = unsafe { ManuallyDrop::take(&mut output.pEvents) };
        drop(events);
        result.map_err(|error| {
            format!("Windows hardware encoder output processing failed: {error}")
        })?;
        sample.ok_or_else(|| "Windows hardware encoder produced no output sample".to_owned())
    }

    fn shutdown(&mut self) -> Result<(), String> {
        if self.is_shutdown {
            return Ok(());
        }
        self.is_shutdown = true;
        let end_of_stream = unsafe {
            self.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0)
        }
        .map_err(|error| format!("Windows encoder end-of-stream failed: {error}"));
        let end_streaming = unsafe {
            self.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0)
        }
        .map_err(|error| format!("Windows encoder end-streaming failed: {error}"));
        let flush = unsafe { self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0) }
            .map_err(|error| format!("Windows encoder flush failed: {error}"));
        let shutdown = unsafe { self.activation.ShutdownObject() }
            .map_err(|error| format!("Windows hardware encoder shutdown failed: {error}"));
        combine_results([end_of_stream, end_streaming, flush, shutdown])
    }
}

impl Drop for NativeVideoEncoderSession {
    fn drop(&mut self) {
        let _ = self.shutdown();
    }
}

fn create_input_sample(
    surface: &NativeEncoderSurface,
    presentation_time_hns: i64,
    duration_hns: i64,
) -> Result<IMFSample, String> {
    let buffer =
        unsafe { MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, surface.texture(), 0, false) }
            .map_err(|error| format!("Windows DXGI media buffer creation failed: {error}"))?;
    let sample = unsafe { MFCreateSample() }
        .map_err(|error| format!("Windows input media sample creation failed: {error}"))?;
    unsafe { sample.AddBuffer(&buffer) }
        .map_err(|error| format!("Windows input sample rejected its DXGI buffer: {error}"))?;
    unsafe { sample.SetSampleTime(presentation_time_hns) }
        .map_err(|error| format!("Windows input sample rejected its timestamp: {error}"))?;
    unsafe { sample.SetSampleDuration(duration_hns) }
        .map_err(|error| format!("Windows input sample rejected its duration: {error}"))?;
    Ok(sample)
}

fn create_output_sample(capacity: u32, alignment: u32) -> Result<IMFSample, String> {
    if capacity == 0 {
        return Err("Windows hardware encoder reported zero output capacity".to_owned());
    }
    if alignment != 0 && !alignment.is_power_of_two() {
        return Err(format!(
            "Windows hardware encoder requested invalid output alignment {alignment}"
        ));
    }
    let alignment_mask = alignment.saturating_sub(1);
    let buffer = unsafe { MFCreateAlignedMemoryBuffer(capacity, alignment_mask) }
        .map_err(|error| format!("Windows output media buffer creation failed: {error}"))?;
    let sample = unsafe { MFCreateSample() }
        .map_err(|error| format!("Windows output media sample creation failed: {error}"))?;
    unsafe { sample.AddBuffer(&buffer) }
        .map_err(|error| format!("Windows output sample rejected its buffer: {error}"))?;
    Ok(sample)
}

fn output_stream_provides_samples(flags: u32) -> Result<bool, String> {
    let provides = u32::try_from(MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0)
        .map_err(|_| "Windows output sample-provider flag is invalid".to_owned())?;
    let can_provide = u32::try_from(MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0)
        .map_err(|_| "Windows optional sample-provider flag is invalid".to_owned())?;
    Ok(flags & (provides | can_provide) != 0)
}

fn encoded_video_sample(sample: &IMFSample) -> Result<NativeEncodedVideoSample, String> {
    let buffer = unsafe { sample.ConvertToContiguousBuffer() }
        .map_err(|error| format!("Windows encoded sample could not be made contiguous: {error}"))?;
    let mut bytes = ptr::null_mut();
    let mut length = 0_u32;
    unsafe { buffer.Lock(&mut bytes, None, Some(&mut length)) }
        .map_err(|error| format!("Windows encoded sample lock failed: {error}"))?;
    let payload_result = if bytes.is_null() || length == 0 {
        Err("Windows hardware encoder returned an empty media buffer".to_owned())
    } else {
        Ok(unsafe { slice::from_raw_parts(bytes, length as usize) }.to_vec())
    };
    unsafe { buffer.Unlock() }
        .map_err(|error| format!("Windows encoded sample unlock failed: {error}"))?;
    let payload = payload_result?;
    let presentation_time_hns = unsafe { sample.GetSampleTime() }
        .map_err(|error| format!("Windows encoded sample has no presentation time: {error}"))?;
    let presentation_time_90khz = timestamp_90khz(presentation_time_hns)?;
    let key_frame = unsafe { sample.GetUINT32(&MFSampleExtension_CleanPoint) }.unwrap_or(0) != 0;
    Ok(NativeEncodedVideoSample {
        payload,
        presentation_time_90khz,
        key_frame,
    })
}

fn timestamp_90khz(timestamp_hns: i64) -> Result<u32, String> {
    let timestamp = u64::try_from(timestamp_hns)
        .map_err(|_| "Windows encoded sample timestamp is negative".to_owned())?;
    let timestamp = u128::from(timestamp)
        .checked_mul(9)
        .and_then(|value| value.checked_div(1_000))
        .ok_or_else(|| "Windows encoded sample timestamp overflowed".to_owned())?;
    let modulus = u128::from(u32::MAX) + 1;
    u32::try_from(timestamp % modulus)
        .map_err(|_| "Windows encoded sample timestamp modulo conversion failed".to_owned())
}

fn combine_results<const N: usize>(results: [Result<(), String>; N]) -> Result<(), String> {
    let errors = results
        .into_iter()
        .filter_map(Result::err)
        .collect::<Vec<_>>();
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

impl TryFrom<PlatformSessionPlan> for NativeVideoEncoderPlan {
    type Error = String;

    fn try_from(plan: PlatformSessionPlan) -> Result<Self, Self::Error> {
        if plan.width == 0 || plan.height == 0 || plan.frames_per_second == 0 {
            return Err("Windows Media Foundation encoder geometry is invalid".to_owned());
        }
        if plan.video_format.chroma_subsampling != PlatformChromaSubsampling::Yuv420 {
            return Err("Windows Media Foundation native encoder requires 4:2:0 input".to_owned());
        }
        let ten_bit = plan.video_format.bit_depth == 10;
        if plan.video_format.dynamic_range == PlatformDynamicRange::Hdr10
            && plan.video_format.codec == PlatformVideoCodec::H264
        {
            return Err("H.264 cannot carry the negotiated HDR stream".to_owned());
        }
        let bitrate_bps = plan
            .bitrate_kbps
            .checked_mul(1_000)
            .filter(|bitrate| *bitrate != 0)
            .ok_or_else(|| "Windows Media Foundation encoder bitrate is invalid".to_owned())?;
        Ok(Self {
            codec: plan.video_format.codec,
            width: plan.width,
            height: plan.height,
            frames_per_second: plan.frames_per_second,
            bitrate_bps,
            ten_bit,
        })
    }
}

fn configure_transform(
    transform: &IMFTransform,
    plan: NativeVideoEncoderPlan,
    device: &ID3D11Device,
) -> Result<IMFDXGIDeviceManager, String> {
    let mut reset_token = 0_u32;
    let mut manager = None;
    unsafe { MFCreateDXGIDeviceManager(&mut reset_token, &mut manager) }
        .map_err(|error| format!("Windows DXGI device manager creation failed: {error}"))?;
    let manager = manager.ok_or_else(|| "Windows DXGI device manager is unavailable".to_owned())?;
    unsafe { manager.ResetDevice(device, reset_token) }.map_err(|error| {
        format!("Windows DXGI device manager rejected the encoder device: {error}")
    })?;
    unsafe {
        transform.ProcessMessage(
            MFT_MESSAGE_SET_D3D_MANAGER,
            Interface::as_raw(&manager) as usize,
        )
    }
    .map_err(|error| {
        format!(
            "Windows {} encoder rejected the D3D11 device manager: {error}",
            codec_name(plan.codec)
        )
    })?;
    let attributes = unsafe { transform.GetAttributes() }.map_err(|error| {
        format!(
            "Windows Media Foundation could not expose {} encoder attributes: {error}",
            codec_name(plan.codec)
        )
    })?;
    let low_latency = (|| -> windows_api::core::Result<()> {
        unsafe {
            attributes.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1)?;
            attributes.SetUINT32(&MF_LOW_LATENCY, 1)?;
        }
        Ok(())
    })();
    low_latency.map_err(|error| {
        format!(
            "Windows Media Foundation rejected the {} low-latency contract: {error}",
            codec_name(plan.codec)
        )
    })?;
    let output = video_media_type(plan, output_subtype(plan.codec), true)?;
    let input = video_media_type(
        plan,
        if plan.ten_bit {
            MFVideoFormat_P010
        } else {
            MFVideoFormat_NV12
        },
        false,
    )?;
    unsafe { transform.SetOutputType(0, &output, 0) }.map_err(|error| {
        format!(
            "Windows Media Foundation rejected the {} output contract: {error}",
            codec_name(plan.codec)
        )
    })?;
    unsafe { transform.SetInputType(0, &input, 0) }.map_err(|error| {
        format!(
            "Windows Media Foundation rejected the {} input contract: {error}",
            codec_name(plan.codec)
        )
    })?;
    Ok(manager)
}

fn video_media_type(
    plan: NativeVideoEncoderPlan,
    subtype: windows_api::core::GUID,
    encoded: bool,
) -> Result<IMFMediaType, String> {
    let media_type = unsafe { MFCreateMediaType() }
        .map_err(|error| format!("Windows Media Foundation media type creation failed: {error}"))?;
    let progressive = u32::try_from(MFVideoInterlace_Progressive.0)
        .map_err(|_| "Windows Media Foundation progressive mode is invalid".to_owned())?;
    let configured = (|| -> windows_api::core::Result<()> {
        unsafe {
            media_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            media_type.SetGUID(&MF_MT_SUBTYPE, &subtype)?;
            media_type.SetUINT64(&MF_MT_FRAME_SIZE, pack_ratio(plan.width, plan.height))?;
            media_type.SetUINT64(&MF_MT_FRAME_RATE, pack_ratio(plan.frames_per_second, 1))?;
            media_type.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack_ratio(1, 1))?;
            media_type.SetUINT32(&MF_MT_INTERLACE_MODE, progressive)?;
            if encoded {
                media_type.SetUINT32(&MF_MT_AVG_BITRATE, plan.bitrate_bps)?;
                media_type.SetUINT32(&MF_MT_MPEG2_PROFILE, output_profile(plan))?;
            }
        }
        Ok(())
    })();
    configured.map_err(|error| {
        format!("Windows Media Foundation media type configuration failed: {error}")
    })?;
    Ok(media_type)
}

fn pack_ratio(numerator: u32, denominator: u32) -> u64 {
    (u64::from(numerator) << 32) | u64::from(denominator)
}

fn output_subtype(codec: PlatformVideoCodec) -> windows_api::core::GUID {
    match codec {
        PlatformVideoCodec::H264 => MFVideoFormat_H264,
        PlatformVideoCodec::Hevc => MFVideoFormat_HEVC,
        PlatformVideoCodec::Av1 => MFVideoFormat_AV1,
    }
}

fn output_profile(plan: NativeVideoEncoderPlan) -> u32 {
    let profile = match (plan.codec, plan.ten_bit) {
        (PlatformVideoCodec::H264, _) => eAVEncH264VProfile_High.0,
        (PlatformVideoCodec::Hevc, false) => eAVEncH265VProfile_Main_420_8.0,
        (PlatformVideoCodec::Hevc, true) => eAVEncH265VProfile_Main_420_10.0,
        (PlatformVideoCodec::Av1, false) => eAVEncAV1VProfile_Main_420_8.0,
        (PlatformVideoCodec::Av1, true) => eAVEncAV1VProfile_Main_420_10.0,
    };
    u32::try_from(profile).unwrap_or_default()
}

fn hardware_encoder_activation(
    subtype: windows_api::core::GUID,
) -> Result<Option<IMFActivate>, String> {
    let output = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: subtype,
    };
    let mut activations: *mut Option<IMFActivate> = ptr::null_mut();
    let mut activation_count = 0_u32;
    let result = unsafe {
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
            None,
            Some(&output),
            &mut activations,
            &mut activation_count,
        )
    };
    if let Err(error) = result {
        drop(take_first_activation(activations, activation_count));
        return Err(format!(
            "Media Foundation hardware encoder discovery failed: {error}"
        ));
    }
    Ok(take_first_activation(activations, activation_count))
}

fn take_first_activation(activations: *mut Option<IMFActivate>, count: u32) -> Option<IMFActivate> {
    if activations.is_null() {
        return None;
    }
    let mut first = None;
    for index in 0..count as usize {
        let activation = unsafe { ptr::read(activations.add(index)) };
        if first.is_none() {
            first = activation;
        }
    }
    unsafe { CoTaskMemFree(Some(activations.cast::<c_void>())) };
    first
}

fn codec_name(codec: PlatformVideoCodec) -> &'static str {
    match codec {
        PlatformVideoCodec::H264 => "H.264",
        PlatformVideoCodec::Hevc => "HEVC",
        PlatformVideoCodec::Av1 => "AV1",
    }
}
