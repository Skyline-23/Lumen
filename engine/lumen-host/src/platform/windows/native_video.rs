use std::ffi::c_void;
use std::mem::ManuallyDrop;
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use lumen_engine::LumenAdaptiveFrameCadenceObservation;

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
const CONTROL_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const INITIAL_FRAME_TIMEOUT: Duration = Duration::from_secs(5);
const ACTIVE_CAPTURE_POLL_MILLISECONDS: u32 = 8;
const MAXIMUM_RETIRED_MEDIA_FOUNDATION_WORKERS: usize = 2;
const MAX_CAPTURE_TIMESTAMP_STEP_90KHZ: u32 = u32::MAX / 2;
const MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS: i64 = 10_000_000 / 240;
const MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS: i64 = 10_000_000 / 15;

#[path = "native_video_cadence.rs"]
mod native_video_cadence;
#[path = "native_video_encoder.rs"]
mod native_video_encoder;
#[cfg(test)]
#[path = "native_video_tests.rs"]
mod native_video_tests;
#[path = "native_video_worker.rs"]
mod native_video_worker;

use native_video_cadence::{
    effective_target_frame_rate, ContentCadenceWakeLatch, WindowsAdaptiveFrameCadence,
    WindowsCadenceAdmission, WindowsUnchangedContentCadence,
};
use native_video_encoder::{
    capture_timestamp_hns, capture_timestamp_step_is_forward, NativeVideoEncoderCatalog,
    NativeVideoEncoderSession,
};
#[cfg(test)]
use native_video_encoder::{
    input_subtype, output_profile, take_admitted_video_timestamp, visit_variant_elements,
};
use native_video_worker::run_media_foundation_session;
#[cfg(test)]
use native_video_worker::sample_requires_bootstrap_pause;

type NativeVideoSink = Arc<
    dyn Fn(u32, NativeEncodedVideoSample) -> Result<NativeVideoSinkResult, String> + Send + Sync,
>;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct NativeVideoSinkResult {
    pub(super) request_key_frame: bool,
    pub(super) pending_drop_count: u64,
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
    content_wake_latch: Arc<ContentCadenceWakeLatch>,
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
    content_wake_latch: Arc<ContentCadenceWakeLatch>,
}

struct NativeVideoRuntimeContext {
    retirement_gate: Arc<SessionRetirementGate>,
    adaptive_event_publisher: Arc<dyn WindowsServiceEventPublisher>,
    content_wake_latch: Arc<ContentCadenceWakeLatch>,
}

#[derive(Default)]
struct NativeVideoWorkerState {
    running: bool,
    error: Option<String>,
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
    unchanged_content_cadence: WindowsUnchangedContentCadence,
    cadence_admission: WindowsCadenceAdmission,
    adaptive_target_frame_rate: u32,
    content_target_frame_rate: u32,
    effective_target_frame_rate: u32,
    source_frame_count: u64,
    output_frame_count: u64,
    pending_drop_count: u64,
    last_callback_latency_milliseconds: f64,
    last_callback_time_seconds: Option<f64>,
    observation_clock: Instant,
    content_wake_latch: Arc<ContentCadenceWakeLatch>,
    awaiting_bootstrap_result: bool,
    repair_keyframe_pending: bool,
    periodic_keyframe_pending: bool,
    admission_divisor: u8,
    retirement_gate: Arc<SessionRetirementGate>,
    adaptive_event_publisher: Arc<dyn WindowsServiceEventPublisher>,
}

enum NativeMediaFoundationCommand {
    ResetMediaEpoch {
        response: mpsc::SyncSender<Result<(), String>>,
    },
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
        let content_wake_latch = Arc::new(ContentCadenceWakeLatch::default());
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
                    content_wake_latch: Arc::clone(&content_wake_latch),
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
            content_wake_latch,
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

    pub(super) fn reset_media_epoch(&self, session_epoch: u32) -> Result<(), String> {
        self.request(Some(session_epoch), |response| {
            NativeMediaFoundationCommand::ResetMediaEpoch { response }
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

    pub(super) fn reserve_unchanged_content_cadence_wake(
        &self,
        session_epoch: u32,
    ) -> Result<(), String> {
        let session = self
            .sessions
            .snapshot(session_epoch)
            .map_err(str::to_owned)?;
        // Multiple validated input events may arrive before the worker gets a
        // chance to consume the first wake.  Coalesce those events rather than
        // turning a harmless duplicate reservation into an input failure.
        let _ = session.value().content_wake_latch.reserve();
        Ok(())
    }

    pub(super) fn commit_unchanged_content_cadence_wake(
        &self,
        session_epoch: u32,
    ) -> Result<(), String> {
        let session = self
            .sessions
            .snapshot(session_epoch)
            .map_err(str::to_owned)?;
        if !session.value().content_wake_latch.commit() {
            // A committed wake is already being delivered (or a concurrent
            // reservation owns the transition).  The source pacer only needs
            // one wake, so this call is intentionally idempotent.
            return Ok(());
        }
        // Do not STOP/START the IDD driver on the input hot path. A wake that
        // arrives while dequeue is blocked is consumed immediately after the
        // input-driven frame returns and before cadence admission.
        Ok(())
    }

    pub(super) fn cancel_unchanged_content_cadence_wake(
        &self,
        session_epoch: u32,
    ) -> Result<(), String> {
        let session = self
            .sessions
            .snapshot(session_epoch)
            .map_err(str::to_owned)?;
        let _ = session.value().content_wake_latch.cancel();
        Ok(())
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
        // Pause first, then enqueue. This ordering guarantees the worker cannot
        // consume the command and resume before the interrupt lands, which would
        // leave the capture owner paused after the caller returns.
        let interrupted = self.interrupt_frame_delivery(&session)?;
        session
            .value()
            .commands
            .try_send(command(response))
            .map_err(|error| {
                if interrupted {
                    let _ = self.restore_frame_delivery(&session);
                }
                format!("Windows Media Foundation session command was not queued: {error}")
            })?;
        let command_result = match result.recv_timeout(CONTROL_COMMAND_TIMEOUT) {
            Ok(result) => result,
            Err(error) => Err(format!(
                "Windows Media Foundation session command response was not received: {error}"
            )),
        };
        if !interrupted {
            return command_result;
        }

        // The worker normally resumes in `finish_control_command`. Restore
        // again from the request owner because start_with is idempotent and an
        // error response can also mean the worker had no runtime to resume.
        let restore_result = self.restore_frame_delivery(&session);
        match (command_result, restore_result) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(error), Ok(())) => Err(error),
            (Ok(()), Err(restore_error)) => Err(format!(
                "Windows frame delivery resume failed after command: {restore_error}"
            )),
            (Err(error), Err(restore_error)) => Err(format!(
                "{error}; Windows frame delivery resume failed: {restore_error}"
            )),
        }
    }

    fn interrupt_frame_delivery(
        &self,
        session: &Arc<
            crate::platform::session_slot::AbandonableSession<NativeMediaFoundationSession>,
        >,
    ) -> Result<bool, String> {
        let control = session
            .value()
            .capture_control
            .lock()
            .map_err(|_| "Windows native capture control is poisoned".to_owned())?;
        let driver = control
            .as_ref()
            .ok_or_else(|| "Windows native capture control is unavailable".to_owned())?;
        session
            .value()
            .frame_delivery
            .pause_with_state(|| driver.stop_frame_delivery())
    }

    fn restore_frame_delivery(
        &self,
        session: &Arc<
            crate::platform::session_slot::AbandonableSession<NativeMediaFoundationSession>,
        >,
    ) -> Result<(), String> {
        let control = session
            .value()
            .capture_control
            .lock()
            .map_err(|_| "Windows native capture control is poisoned".to_owned())?;
        let driver = control
            .as_ref()
            .ok_or_else(|| "Windows native capture control is unavailable".to_owned())?;
        session
            .value()
            .frame_delivery
            .start_with(|| driver.start_frame_delivery())
    }
}

impl Drop for NativeMediaFoundation {
    fn drop(&mut self) {
        let _ = self.stop_encoder();
    }
}

impl NativeVideoRuntime {
    fn reset_media_epoch(&mut self) -> Result<(), String> {
        // A park boundary retires any decoder-bootstrap pause owner. Capture
        // and encoding remain alive; the next controlled IDR owns a fresh
        // reliable bootstrap acknowledgement.
        if self.awaiting_bootstrap_result {
            self.capture.resume_frame_delivery()?;
        }
        self.awaiting_bootstrap_result = false;
        self.repair_keyframe_pending = false;
        self.periodic_keyframe_pending = false;
        self.cadence_admission.reset();
        self.last_source_timestamp_90khz = None;
        self.unwrapped_source_timestamp_90khz = 0;
        self.last_admitted_timestamp_hns = None;
        self.content_wake_latch.clear();
        self.content_target_frame_rate = self
            .unchanged_content_cadence
            .wake(self.observation_clock.elapsed().as_secs_f64())?;
        self.recompute_effective_target_frame_rate();
        Ok(())
    }

    fn wake_unchanged_content_cadence(&mut self, session_epoch: u32) -> Result<(), String> {
        if session_epoch != self.plan.session_epoch {
            return Err(format!(
                "Windows unchanged-content cadence wake received session epoch {session_epoch}, active session epoch is {}",
                self.plan.session_epoch
            ));
        }
        self.content_target_frame_rate = self
            .unchanged_content_cadence
            .wake(self.observation_clock.elapsed().as_secs_f64())?;
        self.recompute_effective_target_frame_rate();
        Ok(())
    }

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
        self.recompute_effective_target_frame_rate();
        Ok(())
    }

    fn record_sink_result(&mut self, result: NativeVideoSinkResult) {
        self.pending_drop_count = self
            .pending_drop_count
            .saturating_add(result.pending_drop_count);
    }

    fn recompute_effective_target_frame_rate(&mut self) {
        self.effective_target_frame_rate = effective_target_frame_rate(
            self.plan.frames_per_second,
            self.adaptive_target_frame_rate,
            self.content_target_frame_rate,
            self.admission_divisor,
        );
    }

    fn observe_adaptive_cadence(&mut self) -> Result<(), String> {
        let elapsed = self.observation_clock.elapsed().as_secs_f64();
        let callback_latency_milliseconds = self
            .last_callback_time_seconds
            .filter(|callback_time| elapsed - callback_time <= 0.20)
            .map_or(0.0, |_| self.last_callback_latency_milliseconds);
        self.adaptive_target_frame_rate =
            self.cadence_controller
                .observe(LumenAdaptiveFrameCadenceObservation {
                    monotonic_time_seconds: elapsed,
                    source_frame_count: self.source_frame_count,
                    output_frame_count: self.output_frame_count,
                    pending_drop_count: self.pending_drop_count,
                    pipeline_stable: !self.awaiting_bootstrap_result
                        && !self.repair_keyframe_pending
                        && !self.periodic_keyframe_pending,
                    callback_latency_milliseconds,
                })?;
        self.recompute_effective_target_frame_rate();
        Ok(())
    }

    fn observe_unchanged_content_cadence(&mut self, signal: u32) -> Result<(), String> {
        let elapsed = self.observation_clock.elapsed().as_secs_f64();
        let pipeline_stable = !self.awaiting_bootstrap_result
            && !self.repair_keyframe_pending
            && !self.periodic_keyframe_pending;
        if pipeline_stable
            && signal == super::driver_abi::DRIVER_CONTENT_SIGNAL_UNCHANGED
            && self.content_target_frame_rate <= 2
        {
            return Ok(());
        }
        self.content_target_frame_rate =
            self.unchanged_content_cadence
                .observe(elapsed, signal, pipeline_stable)?;
        self.recompute_effective_target_frame_rate();
        Ok(())
    }

    fn apply_pending_content_cadence_wake(&mut self) -> Result<(), String> {
        if self.content_wake_latch.take_for_frame() {
            self.wake_unchanged_content_cadence(self.plan.session_epoch)?;
        }
        Ok(())
    }

    fn resume_after_control_interrupt(&mut self) -> Result<(), String> {
        // A control request pauses shared frame delivery to cancel a pending
        // synchronous dequeue. Preserve an intentional decoder-bootstrap pause;
        // otherwise restore the running ownership before replying to the caller.
        if !self.awaiting_bootstrap_result {
            self.capture.resume_frame_delivery()?;
        }
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
        // A wake may arrive after the pre-dequeue check while IDD is blocked.
        // Apply it before classifying/admitting the returned frame so the first
        // visible response is not dropped by the parked 2 fps gate.
        self.apply_pending_content_cadence_wake()?;
        frame.validate()?;
        self.source_frame_count = self.source_frame_count.saturating_add(1);
        let source_timestamp_hns = self.source_timestamp_hns(frame.presentation_time_90khz)?;
        self.observe_unchanged_content_cadence(frame.content_signal)?;
        let content_cadence_is_parked = self.content_target_frame_rate <= 2;
        if !content_cadence_is_parked {
            self.observe_adaptive_cadence()?;
        }
        if !self.cadence_admission.admits(
            self.unwrapped_source_timestamp_90khz,
            self.effective_target_frame_rate,
            self.plan.frames_per_second,
            self.repair_keyframe_pending || self.periodic_keyframe_pending,
        ) {
            return Ok(None);
        }
        if content_cadence_is_parked {
            // Source counters still include every IDD frame. Sampling adaptive
            // pressure only on the admitted 2 fps path avoids a controller
            // mutex on redundant static reencode frames without hiding source
            // progress from the next observation window.
            self.observe_adaptive_cadence()?;
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
            .unwrap_or(self.encoder.frame_duration_hns())
            .clamp(
                MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
                MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
            );
        self.last_admitted_timestamp_hns = Some(timestamp_hns);
        (timestamp_hns, duration)
    }
}
