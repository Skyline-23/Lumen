use std::ffi::c_void;
use std::mem::ManuallyDrop;
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use lumen_engine::{
    LumenAdaptiveFrameCadenceController, LumenAdaptiveFrameCadenceObservation,
    LumenAdaptiveFrameCadenceRequest,
};

use windows_api::core::Interface;
use windows_api::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11Texture2D};
use windows_api::Win32::Media::MediaFoundation::{
    eAVEncAV1VProfile_Main_420_10, eAVEncAV1VProfile_Main_420_8, eAVEncH264VProfile_High,
    eAVEncH265VProfile_Main_420_10, eAVEncH265VProfile_Main_420_8, eAVEncH265VProfile_Main_444_10,
    eAVEncH265VProfile_Main_444_8, CODECAPI_AVEncCommonMeanBitRate,
    CODECAPI_AVEncVideoForceKeyFrame, ICodecAPI, IMFActivate, IMFDXGIDeviceManager,
    IMFMediaEventGenerator, IMFMediaType, IMFSample, IMFTransform, METransformHaveOutput,
    METransformNeedInput, MFCreateAlignedMemoryBuffer, MFCreateDXGIDeviceManager,
    MFCreateDXGISurfaceBuffer, MFCreateMediaType, MFCreateSample, MFMediaType_Video,
    MFSampleExtension_CleanPoint, MFShutdown, MFStartup, MFTEnumEx, MFVideoFormat_AV1,
    MFVideoFormat_AYUV, MFVideoFormat_H264, MFVideoFormat_HEVC, MFVideoFormat_NV12,
    MFVideoFormat_P010, MFVideoFormat_Y410, MFVideoInterlace_Progressive, MFSTARTUP_FULL,
    MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE, MFT_ENUM_FLAG_SORTANDFILTER,
    MFT_MESSAGE_COMMAND_FLUSH, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING,
    MFT_MESSAGE_NOTIFY_END_OF_STREAM, MFT_MESSAGE_NOTIFY_END_STREAMING,
    MFT_MESSAGE_NOTIFY_START_OF_STREAM, MFT_MESSAGE_SET_D3D_MANAGER, MFT_OUTPUT_DATA_BUFFER,
    MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES, MFT_OUTPUT_STREAM_INFO,
    MFT_OUTPUT_STREAM_PROVIDES_SAMPLES, MFT_REGISTER_TYPE_INFO, MF_EVENT_FLAG_NO_WAIT,
    MF_E_NO_EVENTS_AVAILABLE, MF_LOW_LATENCY, MF_MT_AVG_BITRATE, MF_MT_FRAME_RATE,
    MF_MT_FRAME_SIZE, MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE, MF_MT_MPEG2_PROFILE,
    MF_MT_PIXEL_ASPECT_RATIO, MF_MT_SUBTYPE, MF_TRANSFORM_ASYNC_UNLOCK, MF_VERSION,
};
use windows_api::Win32::System::Com::CoTaskMemFree;
use windows_api::Win32::System::Variant::{VariantClear, VARIANT, VT_UI4};

use super::native_capture::{NativeEncoderSurface, NativeIddCxCapture};
use super::native_display_driver::DriverHandle;
use crate::platform::session_slot::{
    AbandonableSessionSlot, FrameDeliveryOwnership, RetiredWorkerRegistry, SessionRetirementGate,
};
use crate::windows_service_log::{WindowsAdaptiveVideoApplyEvent, WindowsServiceEventPublisher};
use crate::{
    PlatformChromaSubsampling, PlatformDynamicRange, PlatformSessionPlan, PlatformVideoCodec,
};

const TRANSFORM_EVENT_TIMEOUT: Duration = Duration::from_secs(5);
const INITIAL_FRAME_TIMEOUT: Duration = Duration::from_secs(5);
const ACTIVE_CAPTURE_POLL_MILLISECONDS: u32 = 8;
const MAXIMUM_RETIRED_MEDIA_FOUNDATION_WORKERS: usize = 2;
const MAX_CAPTURE_TIMESTAMP_STEP_90KHZ: u32 = u32::MAX / 2;
const MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS: i64 = 10_000_000 / 240;
const MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS: i64 = 10_000_000 / 15;

type NativeVideoSink = Arc<
    dyn Fn(u32, NativeEncodedVideoSample) -> Result<NativeVideoSinkResult, String> + Send + Sync,
>;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct NativeVideoSinkResult {
    pub(super) request_key_frame: bool,
    pub(super) pending_drop_count: u64,
}

struct WindowsAdaptiveFrameCadence {
    controller: LumenAdaptiveFrameCadenceController,
    ceiling_frame_rate: u32,
}

impl WindowsAdaptiveFrameCadence {
    fn new(ceiling_frame_rate: u32) -> Result<Self, String> {
        let controller =
            LumenAdaptiveFrameCadenceController::new(LumenAdaptiveFrameCadenceRequest {
                requested_frame_rate: ceiling_frame_rate,
            })
            .map_err(|status| format!("Windows adaptive frame cadence setup failed: {status:?}"))?;
        Ok(Self {
            controller,
            ceiling_frame_rate,
        })
    }

    fn observe(&self, observation: LumenAdaptiveFrameCadenceObservation) -> Result<u32, String> {
        let decision = self.controller.observe(observation).map_err(|status| {
            format!("Windows adaptive frame cadence observation failed: {status:?}")
        })?;
        Ok(decision.target_frame_rate.clamp(1, self.ceiling_frame_rate))
    }

    fn target(&self) -> Result<u32, String> {
        self.controller
            .target()
            .map(|target| target.clamp(1, self.ceiling_frame_rate))
            .map_err(|status| format!("Windows adaptive frame cadence target failed: {status:?}"))
    }
}

struct WindowsCadenceAdmission {
    target_frame_rate: u32,
    last_admitted_timestamp_90khz: Option<u64>,
    next_deadline_scaled: Option<u128>,
}

impl WindowsCadenceAdmission {
    fn new() -> Self {
        Self {
            target_frame_rate: 0,
            last_admitted_timestamp_90khz: None,
            next_deadline_scaled: None,
        }
    }

    fn reset(&mut self) {
        *self = Self::new();
    }

    fn admits(
        &mut self,
        source_timestamp_90khz: u64,
        target_frame_rate: u32,
        ceiling_frame_rate: u32,
        force: bool,
    ) -> bool {
        const TICKS_PER_SECOND: u128 = 90_000;
        let target = target_frame_rate.clamp(1, ceiling_frame_rate.max(1));
        let source_scaled = u128::from(source_timestamp_90khz) * u128::from(target);

        if self.target_frame_rate != target {
            self.target_frame_rate = target;
            self.next_deadline_scaled = self
                .last_admitted_timestamp_90khz
                .map(|timestamp| u128::from(timestamp) * u128::from(target) + TICKS_PER_SECOND);
        }

        if force {
            self.last_admitted_timestamp_90khz = Some(source_timestamp_90khz);
            self.next_deadline_scaled = Some(source_scaled + TICKS_PER_SECOND);
            return true;
        }

        let Some(deadline) = self.next_deadline_scaled else {
            self.last_admitted_timestamp_90khz = Some(source_timestamp_90khz);
            self.next_deadline_scaled = Some(source_scaled + TICKS_PER_SECOND);
            return true;
        };
        if source_scaled < deadline {
            return false;
        }

        self.last_admitted_timestamp_90khz = Some(source_timestamp_90khz);
        let elapsed = source_scaled.saturating_sub(deadline);
        let intervals = elapsed / TICKS_PER_SECOND + 1;
        self.next_deadline_scaled = Some(deadline + intervals * TICKS_PER_SECOND);
        true
    }
}

fn effective_target_frame_rate(
    ceiling_frame_rate: u32,
    adaptive_target_frame_rate: u32,
    admission_divisor: u8,
) -> u32 {
    let ceiling = ceiling_frame_rate.max(1);
    let divisor = u32::from(admission_divisor.max(1));
    let client_target = ceiling.div_ceil(divisor);
    adaptive_target_frame_rate
        .clamp(1, ceiling)
        .min(client_target)
}

pub(super) struct NativeMediaFoundation {
    sink: NativeVideoSink,
    adaptive_event_publisher: Arc<dyn WindowsServiceEventPublisher>,
    sessions: AbandonableSessionSlot<NativeMediaFoundationSession>,
    retired_workers: RetiredWorkerRegistry,
    next_encoder_epoch: AtomicU64,
}

struct NativeMediaFoundationSession {
    commands: mpsc::SyncSender<NativeMediaFoundationCommand>,
    state: Arc<Mutex<NativeVideoWorkerState>>,
    capture_control: Mutex<Option<DriverHandle>>,
    worker: Mutex<Option<thread::JoinHandle<()>>>,
    frame_delivery: Arc<FrameDeliveryOwnership>,
}

struct NativeMediaFoundationWorker {
    plan: NativeVideoEncoderPlan,
    driver: DriverHandle,
    commands: mpsc::Receiver<NativeMediaFoundationCommand>,
    ready: mpsc::SyncSender<Result<(), String>>,
    sink: NativeVideoSink,
    state: Arc<Mutex<NativeVideoWorkerState>>,
    retirement_gate: Arc<SessionRetirementGate>,
    frame_delivery: Arc<FrameDeliveryOwnership>,
    adaptive_event_publisher: Arc<dyn WindowsServiceEventPublisher>,
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
    pub(super) repair_keyframe: bool,
    pub(super) periodic_keyframe: bool,
}

struct NativeVideoRuntime {
    capture: NativeIddCxCapture,
    encoder: NativeVideoEncoderSession,
    plan: NativeVideoEncoderPlan,
    last_source_timestamp_90khz: Option<u32>,
    unwrapped_source_timestamp_90khz: u64,
    last_admitted_timestamp_hns: Option<i64>,
    cadence_controller: WindowsAdaptiveFrameCadence,
    cadence_admission: WindowsCadenceAdmission,
    effective_target_frame_rate: u32,
    source_frame_count: u64,
    output_frame_count: u64,
    pending_drop_count: u64,
    last_callback_latency_milliseconds: f64,
    last_callback_time_seconds: Option<f64>,
    observation_clock: Instant,
    awaiting_bootstrap_result: bool,
    repair_keyframe_pending: bool,
    periodic_keyframe_pending: bool,
    admission_divisor: u8,
    retirement_gate: Arc<SessionRetirementGate>,
    adaptive_event_publisher: Arc<dyn WindowsServiceEventPublisher>,
}

enum NativeMediaFoundationCommand {
    RequestKeyFrame {
        response: mpsc::SyncSender<Result<(), String>>,
    },
    RequestPeriodicKeyFrame {
        response: mpsc::SyncSender<Result<(), String>>,
    },
    ResumeAfterBootstrap {
        response: mpsc::SyncSender<Result<(), String>>,
    },
    SetBitrate {
        session_epoch: u32,
        bitrate_bps: u32,
        admission_divisor: u8,
        response: mpsc::SyncSender<Result<(), String>>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct NativeVideoEncoderPlan {
    session_epoch: u32,
    encoder_epoch: u64,
    codec: PlatformVideoCodec,
    width: u32,
    height: u32,
    frames_per_second: u32,
    bitrate_bps: u32,
    ten_bit: bool,
    chroma_subsampling: PlatformChromaSubsampling,
}

impl NativeMediaFoundation {
    pub(super) fn start(
        sink: NativeVideoSink,
        adaptive_event_publisher: Arc<dyn WindowsServiceEventPublisher>,
    ) -> Self {
        Self {
            sink,
            adaptive_event_publisher,
            sessions: AbandonableSessionSlot::default(),
            retired_workers: RetiredWorkerRegistry::new(MAXIMUM_RETIRED_MEDIA_FOUNDATION_WORKERS),
            next_encoder_epoch: AtomicU64::new(1),
        }
    }

    pub(super) fn start_encoder(
        &self,
        plan: PlatformSessionPlan,
        driver: DriverHandle,
    ) -> Result<(), String> {
        let mut plan = NativeVideoEncoderPlan::try_from(plan)?;
        if self.sessions.current().map_err(str::to_owned)?.is_some() {
            return Err("Windows native video session is already running".to_owned());
        }
        self.retired_workers.ensure_capacity().map_err(|error| {
            format!("Windows Media Foundation session start is fail-closed: {error}")
        })?;
        plan.encoder_epoch = self
            .next_encoder_epoch
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |epoch| {
                epoch.checked_add(1)
            })
            .map_err(|_| "Windows Media Foundation encoder epoch overflowed".to_owned())?;
        let capture_control = driver.duplicate()?;
        let (commands, command_receiver) = mpsc::sync_channel(4);
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let state = Arc::new(Mutex::new(NativeVideoWorkerState::default()));
        let frame_delivery = Arc::new(FrameDeliveryOwnership::default());
        let session = self
            .sessions
            .install(
                plan.session_epoch,
                NativeMediaFoundationSession {
                    commands,
                    state: Arc::clone(&state),
                    capture_control: Mutex::new(Some(capture_control)),
                    worker: Mutex::new(None),
                    frame_delivery: Arc::clone(&frame_delivery),
                },
            )
            .map_err(str::to_owned)?;
        let retirement_gate = session.retirement_gate();
        let sink = Arc::clone(&self.sink);
        let adaptive_event_publisher = Arc::clone(&self.adaptive_event_publisher);
        let session_epoch = plan.session_epoch;
        let worker_context = NativeMediaFoundationWorker {
            plan,
            driver,
            commands: command_receiver,
            ready: ready_sender,
            sink,
            state,
            retirement_gate,
            frame_delivery,
            adaptive_event_publisher,
        };
        let spawn = thread::Builder::new()
            .name(format!("lumen-windows-media-foundation-{session_epoch}"))
            .spawn(move || run_media_foundation_session(worker_context));
        let worker = match spawn {
            Ok(worker) => worker,
            Err(error) => {
                let cleanup = self.stop_encoder().err();
                let error =
                    format!("Windows Media Foundation session worker failed to start: {error}");
                return Err(cleanup.map_or(error.clone(), |cleanup| format!("{error}; {cleanup}")));
            }
        };
        *session
            .value()
            .worker
            .lock()
            .map_err(|_| "Windows Media Foundation worker ownership is poisoned".to_owned())? =
            Some(worker);
        match ready_receiver.recv() {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) => {
                let cleanup = self.stop_encoder().err();
                Err(cleanup.map_or(error.clone(), |cleanup| format!("{error}; {cleanup}")))
            }
            Err(_) => {
                let error =
                    "Windows Media Foundation session worker exited during startup".to_owned();
                let cleanup = self.stop_encoder().err();
                Err(cleanup.map_or(error.clone(), |cleanup| format!("{error}; {cleanup}")))
            }
        }
    }

    pub(super) fn stop_encoder(&self) -> Result<(), String> {
        self.sessions.try_retire(|session| {
            let mut control = session
                .value()
                .capture_control
                .lock()
                .map_err(|_| "Windows native capture control is poisoned".to_owned())?;
            if let Some(driver) = control.as_ref() {
                session
                    .value()
                    .frame_delivery
                    .retire_with(|| driver.stop_frame_delivery())?;
                control.take();
            }
            drop(control);

            let mut worker =
                session.value().worker.lock().map_err(|_| {
                    "Windows Media Foundation worker ownership is poisoned".to_owned()
                })?;
            if let Some(retired_worker) = worker.take() {
                if let Err((error, retired_worker)) = self.retired_workers.insert(retired_worker) {
                    *worker = Some(retired_worker);
                    return Err(format!(
                        "Windows Media Foundation cleanup is fail-closed: {error}"
                    ));
                }
            }
            Ok(())
        })
    }

    pub(super) fn request_key_frame(&self) -> Result<(), String> {
        self.request(None, |response| {
            NativeMediaFoundationCommand::RequestKeyFrame { response }
        })
    }

    pub(super) fn request_periodic_key_frame(&self) -> Result<(), String> {
        self.request(None, |response| {
            NativeMediaFoundationCommand::RequestPeriodicKeyFrame { response }
        })
    }

    pub(super) fn resume_after_bootstrap(&self) -> Result<(), String> {
        self.request(None, |response| {
            NativeMediaFoundationCommand::ResumeAfterBootstrap { response }
        })
    }

    pub(super) fn set_video_delivery_policy(
        &self,
        session_epoch: u32,
        bitrate_kbps: u32,
        admission_divisor: u8,
    ) -> Result<(), String> {
        let bitrate_bps = bitrate_kbps.checked_mul(1_000).ok_or_else(|| {
            "Windows adaptive video bitrate exceeds Media Foundation range".to_owned()
        })?;
        self.request(Some(session_epoch), |response| {
            NativeMediaFoundationCommand::SetBitrate {
                session_epoch,
                bitrate_bps,
                admission_divisor,
                response,
            }
        })
    }

    pub(super) fn take_error(&self) -> Result<Option<String>, String> {
        let Some(session) = self.sessions.current().map_err(str::to_owned)? else {
            return Ok(None);
        };
        let mut state = session
            .value()
            .state
            .lock()
            .map_err(|_| "Windows native video state is poisoned".to_owned())?;
        Ok(state.error.take())
    }

    fn request(
        &self,
        expected_epoch: Option<u32>,
        command: impl FnOnce(mpsc::SyncSender<Result<(), String>>) -> NativeMediaFoundationCommand,
    ) -> Result<(), String> {
        let session = match expected_epoch {
            Some(epoch) => self.sessions.snapshot(epoch).map_err(str::to_owned)?,
            None => self
                .sessions
                .current()
                .map_err(str::to_owned)?
                .filter(|session| !session.is_retired())
                .ok_or_else(|| "Windows native video session is not running".to_owned())?,
        };
        let (response, result) = mpsc::sync_channel(1);
        session
            .value()
            .commands
            .send(command(response))
            .map_err(|_| "Windows Media Foundation session worker is unavailable".to_owned())?;
        result
            .recv()
            .map_err(|_| "Windows Media Foundation session command response was lost".to_owned())?
    }
}

impl Drop for NativeMediaFoundation {
    fn drop(&mut self) {
        let _ = self.stop_encoder();
    }
}

fn run_media_foundation_session(worker: NativeMediaFoundationWorker) {
    let NativeMediaFoundationWorker {
        plan,
        driver,
        commands,
        ready,
        sink,
        state,
        retirement_gate,
        frame_delivery,
        adaptive_event_publisher,
    } = worker;
    let session_epoch = plan.session_epoch;
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
    let mut runtime = match start_runtime(
        &catalog,
        plan,
        driver,
        &sink,
        frame_delivery,
        Arc::clone(&retirement_gate),
        adaptive_event_publisher,
    ) {
        Ok(runtime) => Some(runtime),
        Err(error) => {
            set_worker_state(&state, false, Some(error.clone()));
            let _ = ready.send(Err(error));
            drop(catalog);
            let _ = unsafe { MFShutdown() };
            return;
        }
    };
    set_worker_state(&state, true, None);
    if ready.send(Ok(())).is_err() {
        let _ = stop_runtime(&mut runtime);
        drop(catalog);
        let _ = unsafe { MFShutdown() };
        return;
    }
    while !retirement_gate.is_retired() {
        let command = match commands.try_recv() {
            Ok(command) => Some(command),
            Err(mpsc::TryRecvError::Empty) => None,
            Err(mpsc::TryRecvError::Disconnected) => break,
        };
        if let Some(command) = command {
            match command {
                NativeMediaFoundationCommand::RequestKeyFrame { response } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(|runtime| {
                            if runtime.awaiting_bootstrap_result {
                                Ok(())
                            } else {
                                runtime.request_repair_key_frame()
                            }
                        });
                    let _ = response.send(result);
                }
                NativeMediaFoundationCommand::RequestPeriodicKeyFrame { response } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(|runtime| {
                            if runtime.awaiting_bootstrap_result
                                || runtime.repair_keyframe_pending
                            {
                                Err(
                                    "Windows periodic IDR cannot arm while another bootstrap or repair is pending"
                                        .to_owned(),
                                )
                            } else {
                                runtime.request_periodic_key_frame()
                            }
                        });
                    let _ = response.send(result);
                }
                NativeMediaFoundationCommand::ResumeAfterBootstrap { response } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(NativeVideoRuntime::resume_after_bootstrap);
                    let _ = response.send(result);
                }
                NativeMediaFoundationCommand::SetBitrate {
                    session_epoch,
                    bitrate_bps,
                    admission_divisor,
                    response,
                } => {
                    let result = runtime
                        .as_mut()
                        .ok_or_else(|| "Windows native video session is not running".to_owned())
                        .and_then(|runtime| {
                            runtime.set_video_delivery_policy(
                                session_epoch,
                                bitrate_bps,
                                admission_divisor,
                            )
                        });
                    let _ = response.send(result);
                }
            }
            continue;
        }
        if runtime
            .as_ref()
            .expect("active Windows worker owns a video runtime")
            .awaiting_bootstrap_result
        {
            thread::sleep(Duration::from_millis(1));
            continue;
        }
        let encoded = runtime
            .as_mut()
            .expect("active Windows worker owns a video runtime")
            .encode_next(ACTIVE_CAPTURE_POLL_MILLISECONDS);
        match encoded.and_then(|sample| {
            if let Some(sample) = sample {
                let pause_for_bootstrap = sample_requires_bootstrap_pause(&sample, false);
                if retirement_gate.is_retired() {
                    return Ok(());
                }
                let sink_result = sink(session_epoch, sample)?;
                let runtime = runtime
                    .as_mut()
                    .expect("encoded frame came from an active runtime");
                runtime.record_sink_result(sink_result);
                if pause_for_bootstrap {
                    runtime.pause_after_bootstrap()?;
                }
                if sink_result.request_key_frame {
                    runtime.request_repair_key_frame()?;
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
                break;
            }
        }
    }
    while let Ok(command) = commands.try_recv() {
        reject_retired_command(command);
    }
    let _ = stop_runtime(&mut runtime);
    set_worker_running(&state, false);
    drop(catalog);
    let _ = unsafe { MFShutdown() };
}

fn reject_retired_command(command: NativeMediaFoundationCommand) {
    let response = match command {
        NativeMediaFoundationCommand::RequestKeyFrame { response }
        | NativeMediaFoundationCommand::RequestPeriodicKeyFrame { response }
        | NativeMediaFoundationCommand::ResumeAfterBootstrap { response }
        | NativeMediaFoundationCommand::SetBitrate { response, .. } => response,
    };
    let _ = response.send(Err(
        "Windows Media Foundation session was retired before command execution".to_owned(),
    ));
}

fn start_runtime(
    catalog: &NativeVideoEncoderCatalog,
    plan: NativeVideoEncoderPlan,
    driver: DriverHandle,
    sink: &NativeVideoSink,
    frame_delivery: Arc<FrameDeliveryOwnership>,
    retirement_gate: Arc<SessionRetirementGate>,
    adaptive_event_publisher: Arc<dyn WindowsServiceEventPublisher>,
) -> Result<NativeVideoRuntime, String> {
    let capture = NativeIddCxCapture::open(driver, plan.ten_bit, frame_delivery)?;
    let encoder = catalog.activate(plan, capture.device())?;
    let cadence_controller = WindowsAdaptiveFrameCadence::new(plan.frames_per_second)?;
    let effective_target_frame_rate = cadence_controller.target()?;
    let mut runtime = NativeVideoRuntime {
        capture,
        encoder,
        plan,
        last_source_timestamp_90khz: None,
        unwrapped_source_timestamp_90khz: 0,
        last_admitted_timestamp_hns: None,
        cadence_controller,
        cadence_admission: WindowsCadenceAdmission::new(),
        effective_target_frame_rate,
        source_frame_count: 0,
        output_frame_count: 0,
        pending_drop_count: 0,
        last_callback_latency_milliseconds: 0.0,
        last_callback_time_seconds: None,
        observation_clock: Instant::now(),
        awaiting_bootstrap_result: false,
        repair_keyframe_pending: false,
        periodic_keyframe_pending: false,
        admission_divisor: 1,
        retirement_gate,
        adaptive_event_publisher,
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
        let pause_for_bootstrap = sample_requires_bootstrap_pause(&encoded, true);
        let sink_result = sink(plan.session_epoch, encoded)?;
        runtime.record_sink_result(sink_result);
        if pause_for_bootstrap {
            runtime.pause_after_bootstrap()?;
        }
        if sink_result.request_key_frame {
            runtime.request_repair_key_frame()?;
        }
        return Ok(runtime);
    }
}

fn sample_requires_bootstrap_pause(sample: &NativeEncodedVideoSample, initial: bool) -> bool {
    sample.key_frame && (initial || sample.repair_keyframe || sample.periodic_keyframe)
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

fn set_worker_running(state: &Mutex<NativeVideoWorkerState>, running: bool) {
    if let Ok(mut state) = state.lock() {
        state.running = running;
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
    fn set_video_delivery_policy(
        &mut self,
        session_epoch: u32,
        bitrate_bps: u32,
        admission_divisor: u8,
    ) -> Result<(), String> {
        if session_epoch != self.plan.session_epoch {
            return Err(format!(
                "Windows adaptive bitrate received session epoch {session_epoch}, active session epoch is {}",
                self.plan.session_epoch
            ));
        }
        if !(1..=4).contains(&admission_divisor) {
            return Err("Windows video admission divisor is outside 1...4".to_owned());
        }
        let applied_bitrate_bps = self.encoder.set_bitrate(bitrate_bps)?;
        let _ = self.retirement_gate.commit_if_active(|| {
            let event = WindowsAdaptiveVideoApplyEvent::new(
                self.plan.session_epoch,
                self.plan.encoder_epoch,
                bitrate_bps,
                applied_bitrate_bps,
            );
            let _ = self
                .adaptive_event_publisher
                .publish_adaptive_video_apply(event);
        });
        self.admission_divisor = admission_divisor;
        self.effective_target_frame_rate = effective_target_frame_rate(
            self.plan.frames_per_second,
            self.cadence_controller.target()?,
            self.admission_divisor,
        );
        Ok(())
    }

    fn record_sink_result(&mut self, result: NativeVideoSinkResult) {
        self.pending_drop_count = self
            .pending_drop_count
            .saturating_add(result.pending_drop_count);
    }

    fn observe_adaptive_cadence(&mut self) -> Result<(), String> {
        let elapsed = self.observation_clock.elapsed().as_secs_f64();
        let callback_latency_milliseconds = self
            .last_callback_time_seconds
            .filter(|callback_time| elapsed - callback_time <= 0.20)
            .map_or(0.0, |_| self.last_callback_latency_milliseconds);
        let target = self
            .cadence_controller
            .observe(LumenAdaptiveFrameCadenceObservation {
                monotonic_time_seconds: elapsed,
                source_frame_count: self.source_frame_count,
                output_frame_count: self.output_frame_count,
                pending_drop_count: self.pending_drop_count,
                callback_latency_milliseconds,
            })?;
        self.effective_target_frame_rate = effective_target_frame_rate(
            self.plan.frames_per_second,
            target,
            self.admission_divisor,
        );
        Ok(())
    }

    fn request_repair_key_frame(&mut self) -> Result<(), String> {
        if self.repair_keyframe_pending {
            return Ok(());
        }
        self.encoder.force_key_frame()?;
        self.repair_keyframe_pending = true;
        Ok(())
    }

    fn request_periodic_key_frame(&mut self) -> Result<(), String> {
        if self.periodic_keyframe_pending || self.repair_keyframe_pending {
            return Ok(());
        }
        self.encoder.force_key_frame()?;
        self.periodic_keyframe_pending = true;
        Ok(())
    }

    fn pause_after_bootstrap(&mut self) -> Result<(), String> {
        if self.awaiting_bootstrap_result {
            return Ok(());
        }
        self.capture.pause_frame_delivery()?;
        self.awaiting_bootstrap_result = true;
        Ok(())
    }

    fn resume_after_bootstrap(&mut self) -> Result<(), String> {
        if !self.awaiting_bootstrap_result {
            return Err("Windows video bootstrap is not awaiting a decoder result".to_owned());
        }
        self.capture.resume_frame_delivery()?;
        self.awaiting_bootstrap_result = false;
        Ok(())
    }

    fn encode_next(
        &mut self,
        timeout_milliseconds: u32,
    ) -> Result<Option<NativeEncodedVideoSample>, String> {
        let Some(frame) = self.capture.acquire_next_frame(timeout_milliseconds)? else {
            return Ok(None);
        };
        frame.validate()?;
        self.source_frame_count = self.source_frame_count.saturating_add(1);
        let source_timestamp_hns = self.source_timestamp_hns(frame.presentation_time_90khz)?;
        self.observe_adaptive_cadence()?;
        if !self.cadence_admission.admits(
            self.unwrapped_source_timestamp_90khz,
            self.effective_target_frame_rate,
            self.plan.frames_per_second,
            self.repair_keyframe_pending || self.periodic_keyframe_pending,
        ) {
            return Ok(None);
        }
        let (timestamp, duration_hns) = self.admitted_timestamp_and_duration(source_timestamp_hns);
        let surface = self.capture.convert_frame(
            &frame,
            self.plan.width,
            self.plan.height,
            self.plan.frames_per_second,
            self.plan.ten_bit,
            self.plan.chroma_subsampling,
        )?;
        let encode_started = Instant::now();
        let mut encoded = self.encoder.encode(&surface, timestamp, duration_hns)?;
        self.last_callback_latency_milliseconds = encode_started.elapsed().as_secs_f64() * 1_000.0;
        self.last_callback_time_seconds = Some(self.observation_clock.elapsed().as_secs_f64());
        self.output_frame_count = self.output_frame_count.saturating_add(1);
        self.observe_adaptive_cadence()?;
        if encoded.key_frame {
            encoded.repair_keyframe = self.repair_keyframe_pending;
            encoded.periodic_keyframe = self.periodic_keyframe_pending;
            self.repair_keyframe_pending = false;
            self.periodic_keyframe_pending = false;
        }
        Ok(Some(encoded))
    }

    fn source_timestamp_hns(&mut self, source_timestamp_90khz: u32) -> Result<i64, String> {
        if let Some(previous) = self.last_source_timestamp_90khz {
            if !capture_timestamp_step_is_forward(previous, source_timestamp_90khz) {
                // A stale/reset capture timestamp must not turn into a multi-hour
                // positive duration through wrapping arithmetic. Re-anchor the
                // capture timeline and force one repair key frame at timestamp zero.
                self.last_source_timestamp_90khz = Some(source_timestamp_90khz);
                self.unwrapped_source_timestamp_90khz = 0;
                self.last_admitted_timestamp_hns = None;
                self.cadence_admission.reset();
                self.encoder.force_key_frame()?;
                self.repair_keyframe_pending = true;
                return Ok(0);
            }
            self.unwrapped_source_timestamp_90khz = self
                .unwrapped_source_timestamp_90khz
                .checked_add(u64::from(source_timestamp_90khz.wrapping_sub(previous)))
                .ok_or_else(|| "Windows capture timestamp accumulator overflowed".to_owned())?;
        }
        self.last_source_timestamp_90khz = Some(source_timestamp_90khz);
        capture_timestamp_hns(self.unwrapped_source_timestamp_90khz)
    }

    fn admitted_timestamp_and_duration(&mut self, timestamp_hns: i64) -> (i64, i64) {
        let duration = self
            .last_admitted_timestamp_hns
            .and_then(|previous| timestamp_hns.checked_sub(previous))
            .filter(|duration| *duration > 0)
            .unwrap_or(self.encoder.frame_duration_hns)
            .clamp(
                MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
                MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
            );
        self.last_admitted_timestamp_hns = Some(timestamp_hns);
        (timestamp_hns, duration)
    }
}

fn capture_timestamp_hns(unwrapped_timestamp_90khz: u64) -> Result<i64, String> {
    let timestamp_hns = u128::from(unwrapped_timestamp_90khz)
        .checked_mul(10_000_000)
        .and_then(|value| value.checked_div(90_000))
        .ok_or_else(|| "Windows capture timestamp conversion overflowed".to_owned())?;
    i64::try_from(timestamp_hns)
        .map_err(|_| "Windows capture timestamp exceeds Media Foundation range".to_owned())
}

fn capture_timestamp_step_is_forward(previous_90khz: u32, current_90khz: u32) -> bool {
    let step = current_90khz.wrapping_sub(previous_90khz);
    step > 0 && step <= MAX_CAPTURE_TIMESTAMP_STEP_90KHZ
}

#[cfg(test)]
fn take_admitted_video_timestamp(
    next: &mut i64,
    frame_duration_hns: i64,
    admissions_until_next: &mut u8,
    admission_divisor: u8,
    repair_keyframe_pending: bool,
) -> Result<Option<i64>, String> {
    let timestamp = take_video_timestamp(next, frame_duration_hns)?;
    if !repair_keyframe_pending && *admissions_until_next > 0 {
        *admissions_until_next -= 1;
        return Ok(None);
    }
    *admissions_until_next = admission_divisor.saturating_sub(1);
    Ok(Some(timestamp))
}

#[cfg(test)]
fn take_video_timestamp(next: &mut i64, frame_duration_hns: i64) -> Result<i64, String> {
    let timestamp = *next;
    *next = next
        .checked_add(frame_duration_hns)
        .ok_or_else(|| "Windows video timestamp overflowed".to_owned())?;
    Ok(timestamp)
}

impl NativeVideoEncoderSession {
    fn set_bitrate(&self, bitrate_bps: u32) -> Result<u32, String> {
        if bitrate_bps == 0 {
            return Err("Windows adaptive video bitrate must be nonzero".to_owned());
        }
        let api = &CODECAPI_AVEncCommonMeanBitRate;
        let raw = Interface::as_raw(&self.codec_api);
        let vtable = Interface::vtable(&self.codec_api);
        let supported = unsafe { (vtable.IsSupported)(raw, api) };
        if supported.0 != 0 {
            return Err(format!(
                "Windows encoder does not support runtime mean bitrate control: {supported:?}"
            ));
        }
        let modifiable = unsafe { (vtable.IsModifiable)(raw, api) };
        if modifiable.0 != 0 {
            return Err(format!(
                "Windows encoder mean bitrate is not runtime-modifiable: {modifiable:?}"
            ));
        }
        self.validate_bitrate_parameter(bitrate_bps)?;

        let requested = variant_from_ui4(bitrate_bps);
        let set = unsafe { (vtable.SetValue)(raw, api, &requested) };
        if set.0 != 0 {
            return Err(format!(
                "Windows encoder rejected runtime mean bitrate {bitrate_bps} bps: {set:?}"
            ));
        }
        let mut applied = VARIANT::default();
        let read = unsafe { (vtable.GetValue)(raw, api, &mut applied) };
        if read.0 != 0 {
            return Err(format!(
                "Windows encoder did not expose runtime mean bitrate readback: {read:?}"
            ));
        }
        let applied = variant_ui4(&applied)
            .ok_or_else(|| "Windows encoder mean bitrate readback was not VT_UI4".to_owned())?;
        if applied != bitrate_bps {
            return Err(format!(
                "Windows encoder mean bitrate readback mismatch requested={bitrate_bps} applied={applied}"
            ));
        }
        Ok(applied)
    }

    fn validate_bitrate_parameter(&self, bitrate_bps: u32) -> Result<(), String> {
        let api = &CODECAPI_AVEncCommonMeanBitRate;
        let raw = Interface::as_raw(&self.codec_api);
        let vtable = Interface::vtable(&self.codec_api);
        let mut values = ptr::null_mut::<VARIANT>();
        let mut values_count = 0_u32;
        let discrete =
            unsafe { (vtable.GetParameterValues)(raw, api, &mut values, &mut values_count) };
        if discrete.0 == 0 {
            let values = CoTaskVariantArray::new(values, values_count);
            let admitted = values
                .as_slice()
                .iter()
                .filter_map(variant_ui4)
                .any(|value| value == bitrate_bps);
            return admitted.then_some(()).ok_or_else(|| {
                format!("Windows encoder does not admit mean bitrate {bitrate_bps} bps")
            });
        }

        let mut minimum = VARIANT::default();
        let mut maximum = VARIANT::default();
        let mut step = VARIANT::default();
        let range =
            unsafe { (vtable.GetParameterRange)(raw, api, &mut minimum, &mut maximum, &mut step) };
        if range.0 != 0 {
            return Ok(());
        }
        let minimum = variant_ui4(&minimum)
            .ok_or_else(|| "Windows encoder mean bitrate minimum was not VT_UI4".to_owned())?;
        let maximum = variant_ui4(&maximum)
            .ok_or_else(|| "Windows encoder mean bitrate maximum was not VT_UI4".to_owned())?;
        let step = variant_ui4(&step)
            .ok_or_else(|| "Windows encoder mean bitrate step was not VT_UI4".to_owned())?;
        let in_range = (minimum..=maximum).contains(&bitrate_bps);
        let on_step = step == 0 || bitrate_bps.saturating_sub(minimum).is_multiple_of(step);
        (in_range && on_step).then_some(()).ok_or_else(|| {
            format!(
                "Windows encoder mean bitrate {bitrate_bps} bps is outside range {minimum}...{maximum} step={step}"
            )
        })
    }

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
        duration_hns: i64,
    ) -> Result<NativeEncodedVideoSample, String> {
        self.wait_for_input_request()?;
        let sample = create_input_sample(surface, presentation_time_hns, duration_hns)?;
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

fn variant_from_ui4(value: u32) -> VARIANT {
    VARIANT::from(value)
}

fn variant_ui4(value: &VARIANT) -> Option<u32> {
    (value.vt() == VT_UI4)
        .then(|| u32::try_from(value).ok())
        .flatten()
}

struct CoTaskVariantArray {
    values: *mut VARIANT,
    count: usize,
}

impl CoTaskVariantArray {
    fn new(values: *mut VARIANT, count: u32) -> Self {
        Self {
            values,
            count: count as usize,
        }
    }

    fn as_slice(&self) -> &[VARIANT] {
        if self.values.is_null() || self.count == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(self.values, self.count) }
        }
    }
}

impl Drop for CoTaskVariantArray {
    fn drop(&mut self) {
        if self.values.is_null() {
            return;
        }
        unsafe {
            visit_variant_elements(self.values, self.count, |value| {
                let _ = VariantClear(value);
            });
            CoTaskMemFree(Some(self.values.cast()));
        }
    }
}

unsafe fn visit_variant_elements(
    values: *mut VARIANT,
    count: usize,
    mut visit: impl FnMut(*mut VARIANT),
) {
    for index in 0..count {
        visit(unsafe { values.add(index) });
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
        repair_keyframe: false,
        periodic_keyframe: false,
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
        if plan.video_format.codec != PlatformVideoCodec::Hevc
            && plan.video_format.chroma_subsampling == PlatformChromaSubsampling::Yuv444
        {
            return Err("Windows native 4:4:4 encoding requires HEVC".to_owned());
        }
        if !matches!(plan.video_format.bit_depth, 8 | 10) {
            return Err("Windows native encoder requires 8-bit or 10-bit video".to_owned());
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
            session_epoch: plan.session_epoch,
            encoder_epoch: 0,
            codec: plan.video_format.codec,
            width: plan.width,
            height: plan.height,
            frames_per_second: plan.frames_per_second,
            bitrate_bps,
            ten_bit,
            chroma_subsampling: plan.video_format.chroma_subsampling,
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
    let input = video_media_type(plan, input_subtype(plan), false)?;
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

fn input_subtype(plan: NativeVideoEncoderPlan) -> windows_api::core::GUID {
    match (plan.chroma_subsampling, plan.ten_bit) {
        (PlatformChromaSubsampling::Yuv420, false) => MFVideoFormat_NV12,
        (PlatformChromaSubsampling::Yuv420, true) => MFVideoFormat_P010,
        (PlatformChromaSubsampling::Yuv444, false) => MFVideoFormat_AYUV,
        (PlatformChromaSubsampling::Yuv444, true) => MFVideoFormat_Y410,
    }
}

fn output_profile(plan: NativeVideoEncoderPlan) -> u32 {
    let profile = match (plan.codec, plan.chroma_subsampling, plan.ten_bit) {
        (PlatformVideoCodec::H264, _, _) => eAVEncH264VProfile_High.0,
        (PlatformVideoCodec::Hevc, PlatformChromaSubsampling::Yuv420, false) => {
            eAVEncH265VProfile_Main_420_8.0
        }
        (PlatformVideoCodec::Hevc, PlatformChromaSubsampling::Yuv420, true) => {
            eAVEncH265VProfile_Main_420_10.0
        }
        (PlatformVideoCodec::Hevc, PlatformChromaSubsampling::Yuv444, false) => {
            eAVEncH265VProfile_Main_444_8.0
        }
        (PlatformVideoCodec::Hevc, PlatformChromaSubsampling::Yuv444, true) => {
            eAVEncH265VProfile_Main_444_10.0
        }
        (PlatformVideoCodec::Av1, _, false) => eAVEncAV1VProfile_Main_420_8.0,
        (PlatformVideoCodec::Av1, _, true) => eAVEncAV1VProfile_Main_420_10.0,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(ten_bit: bool) -> NativeVideoEncoderPlan {
        NativeVideoEncoderPlan {
            session_epoch: 1,
            encoder_epoch: 1,
            codec: PlatformVideoCodec::Hevc,
            width: 3_840,
            height: 2_160,
            frames_per_second: 120,
            bitrate_bps: 80_000_000,
            ten_bit,
            chroma_subsampling: PlatformChromaSubsampling::Yuv444,
        }
    }

    #[test]
    fn selects_media_foundation_hevc_444_contracts() {
        let eight_bit = plan(false);
        assert_eq!(input_subtype(eight_bit), MFVideoFormat_AYUV);
        assert_eq!(
            output_profile(eight_bit),
            u32::try_from(eAVEncH265VProfile_Main_444_8.0).unwrap()
        );

        let ten_bit = plan(true);
        assert_eq!(input_subtype(ten_bit), MFVideoFormat_Y410);
        assert_eq!(
            output_profile(ten_bit),
            u32::try_from(eAVEncH265VProfile_Main_444_10.0).unwrap()
        );
    }

    #[test]
    fn initial_periodic_and_repair_keyframes_pause_for_bootstrap_acknowledgement() {
        let sample = |key_frame, repair_keyframe, periodic_keyframe| NativeEncodedVideoSample {
            payload: vec![1],
            presentation_time_90khz: 0,
            key_frame,
            repair_keyframe,
            periodic_keyframe,
        };

        assert!(sample_requires_bootstrap_pause(
            &sample(true, false, false),
            true
        ));
        assert!(sample_requires_bootstrap_pause(
            &sample(true, true, false),
            false
        ));
        assert!(sample_requires_bootstrap_pause(
            &sample(true, false, true),
            false
        ));
        assert!(!sample_requires_bootstrap_pause(
            &sample(true, false, false),
            false
        ));
        assert!(!sample_requires_bootstrap_pause(
            &sample(false, false, true),
            false
        ));
    }

    #[test]
    fn divisor_two_admission_preserves_capture_timeline_gaps() {
        let mut next = 0;
        let mut admissions_until_next = 0;
        let duration = 166_666;
        let admitted_timestamps = (0..4)
            .map(|_| {
                take_admitted_video_timestamp(
                    &mut next,
                    duration,
                    &mut admissions_until_next,
                    2,
                    false,
                )
                .unwrap()
            })
            .collect::<Vec<_>>();

        assert_eq!(
            admitted_timestamps,
            vec![Some(0), None, Some(333_332), None]
        );
        assert_eq!(next, 666_664);
    }

    #[test]
    fn adaptive_target_and_client_divisor_share_one_admission_budget() {
        assert_eq!(effective_target_frame_rate(120, 120, 1), 120);
        assert_eq!(effective_target_frame_rate(120, 120, 2), 60);
        assert_eq!(effective_target_frame_rate(120, 60, 1), 60);
        assert_eq!(effective_target_frame_rate(120, 60, 2), 60);
        assert_eq!(effective_target_frame_rate(120, 40, 2), 40);
        assert_eq!(effective_target_frame_rate(120, 30, 4), 30);
    }

    #[test]
    fn cadence_admission_preserves_fractional_variable_rate_without_double_decimation() {
        let mut admission = WindowsCadenceAdmission::new();
        let admitted = (0..120)
            .filter(|index| admission.admits(index * 750, 60, 120, false))
            .count();
        assert_eq!(admitted, 60);

        let mut admission = WindowsCadenceAdmission::new();
        let admitted = (0..120)
            .filter(|index| admission.admits(index * 750, 58, 120, false))
            .count();
        assert_eq!(admitted, 58, "fractional deadlines must preserve 58 fps");

        let mut admission = WindowsCadenceAdmission::new();
        let admitted = (0..80)
            .filter(|index| admission.admits(index * 1_125, 58, 120, false))
            .count();
        assert_eq!(
            admitted, 58,
            "an 80 fps source must not be scaled by the negotiated 120 fps ceiling"
        );
    }

    #[test]
    fn capture_timestamps_wrap_and_duration_stays_vfr_safe() {
        let previous = u32::MAX - 450;
        let current: u32 = 450;
        let step = u64::from(current.wrapping_sub(previous));
        let first = capture_timestamp_hns(0).unwrap();
        let second = capture_timestamp_hns(step).unwrap();
        assert_eq!(first, 0);
        assert_eq!(second, 100_111);

        let duration = second - first;
        assert!(duration > 0);
        assert!(duration < 200_000);

        assert!(capture_timestamp_step_is_forward(previous, current));
        assert!(!capture_timestamp_step_is_forward(500, 500));
        assert!(!capture_timestamp_step_is_forward(10_000, 9_000));
        assert!(!capture_timestamp_step_is_forward(
            500,
            500_u32.wrapping_sub(MAX_CAPTURE_TIMESTAMP_STEP_90KHZ + 1),
        ));
    }

    #[test]
    fn media_foundation_duration_clamps_long_capture_gaps_but_keeps_vfr_timestamps() {
        let long_gap = MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS * 3;
        let duration = long_gap.clamp(
            MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
            MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
        );
        assert_eq!(duration, MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS);
        assert_eq!(
            1_i64.clamp(
                MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
                MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
            ),
            MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS
        );
    }

    #[test]
    fn variant_array_cleanup_visits_every_value_including_unexpected_types() {
        let mut values = [
            VARIANT::from(1_u32),
            VARIANT::from(true),
            VARIANT::default(),
        ];
        let base = values.as_mut_ptr();
        let mut visited = Vec::new();

        unsafe {
            visit_variant_elements(base, values.len(), |value| {
                visited.push(value.offset_from(base));
            });
        }

        assert_eq!(visited, vec![0, 1, 2]);
    }
}
