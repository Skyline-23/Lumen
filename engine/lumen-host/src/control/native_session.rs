use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use lumen_engine::{
    client_control_envelope, host_control_envelope, minimum_video_encoder_bitrate_kbps,
    negotiate_native_session, ClientControlEnvelope, ClientSessionHello, CodecConfiguration,
    CodecConfigurationAck, DisplayReconfigurationRequest, DisplayReconfigurationResult,
    HostControlEnvelope, HostSessionCapabilities, HostSessionPlan, LumenSessionOffer,
    MediaFeedback, MediaParkRequest, MediaParkResult, NativeChromaSubsampling, NativeColorRange,
    NativeDisplayReconfigurationResultCode, NativeDynamicRange, NativeMediaParkResultCode,
    NativeMediaParkState, NativeNegotiationFailure, NativeProtocolError, NativeSessionError,
    NativeVideoBootstrapReason, NativeVideoBootstrapResultCode, NativeVideoCodec,
    NativeVideoKeyframeRequestReason, NativeVideoProfile, SessionStarted, SessionStopped,
    StartSessionAck, StopSession, VideoBootstrap, VideoBootstrapResult, VideoKeyframeRequest,
    NATIVE_MEDIA_CAPABILITY_MEDIA_PARK_RESUME, NATIVE_VIDEO_STREAM_ID,
};
use tokio::sync::Notify;

use super::{
    AdaptiveVideoDecision, AdaptiveVideoDeliveryController, AudioDeliveryState, ControlRouter,
    FeedbackStream, InputMotionDeliveryState, MediaFeedbackSample, VideoDeliveryState,
};
use crate::{
    PlatformApplicationPlan, PlatformChromaSubsampling, PlatformColorRange, PlatformDynamicRange,
    PlatformRuntimeEvent, PlatformRuntimeEventCode, PlatformRuntimeEventDisposition,
    PlatformRuntimeEventSeverity, PlatformSessionPlan, PlatformVideoCodec, PlatformVideoFormat,
    PlatformVideoProfile,
};

const ERROR_INVALID_OPERATION: u32 = 1;
const ERROR_AUTHENTICATION: u32 = 2;
const ERROR_APPLICATION: u32 = 3;
const ERROR_NEGOTIATION: u32 = 4;
const ERROR_SESSION_CONFLICT: u32 = 5;
const ERROR_PLATFORM: u32 = 7;
const ERROR_SESSION_STATE: u32 = 8;
const NATIVE_MEDIA_FEEDBACK_WINDOW_MILLISECONDS: u32 = 250;
const MAX_RETIRED_VIDEO_BOOTSTRAPS: usize = 8;
pub(crate) const MAX_VIDEO_BOOTSTRAP_RETRY_ATTEMPTS: u8 = 2;
const PERIODIC_IDR_INTERVAL: Duration = Duration::from_secs(1);
const MEDIA_RESUME_BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_MEDIA_RESUME_IDR_RETRIES: u8 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NativeConnectionContext {
    pub(crate) session_epoch: u32,
    pub(crate) host_capabilities: HostSessionCapabilities,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum NativeMediaFeedbackDisposition {
    Applied(AdaptiveVideoProposal),
    AwaitingPair { window_milliseconds: u32 },
    Unchanged,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct AdaptiveVideoProposal {
    pub(crate) base: AdaptiveVideoDecision,
    pub(crate) decision: AdaptiveVideoDecision,
    pub(crate) platform_policy_revision: u32,
    lane_revision: u64,
    controller: AdaptiveVideoDeliveryController,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum NativeAdaptiveVideoPolicyRequest {
    Applied(AdaptiveVideoProposal),
    Deferred,
    Unchanged,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct AdaptiveVideoPolicyCompletion {
    pub(crate) active: bool,
    pub(crate) committed: bool,
    pub(crate) follow_up: Option<AdaptiveVideoProposal>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeVideoRepairSource {
    PostBootstrapDrain,
    StaleDelta,
    IncompleteTransport,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeMediaFeedbackRejection {
    SessionUnavailable,
    SessionInactive,
    SessionEpochMismatch,
    StreamMismatch,
    WindowDurationMismatch,
    InvalidSequenceRange,
    FeedbackWindowMismatch,
    DuplicateFeedbackStream,
    IncompleteFeedbackWindow,
}

impl NativeMediaFeedbackRejection {
    pub(crate) const fn code(self) -> &'static str {
        match self {
            Self::SessionUnavailable => "session-unavailable",
            Self::SessionInactive => "session-inactive",
            Self::SessionEpochMismatch => "session-epoch-mismatch",
            Self::StreamMismatch => "stream-mismatch",
            Self::WindowDurationMismatch => "window-duration-mismatch",
            Self::InvalidSequenceRange => "invalid-sequence-range",
            Self::FeedbackWindowMismatch => "feedback-window-mismatch",
            Self::DuplicateFeedbackStream => "duplicate-feedback-stream",
            Self::IncompleteFeedbackWindow => "incomplete-feedback-window",
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct NativeSessionState {
    pending: Option<PendingNativeSession>,
    next_start_token: u64,
    next_display_reconfiguration_token: u64,
}

#[derive(Debug)]
struct PendingNativeSession {
    hello: ClientSessionHello,
    plan: HostSessionPlan,
    active: bool,
    start_reservation: Option<NativeStartReservationState>,
    display_reconfiguration: Option<NativeDisplayReconfigurationState>,
    session_cleanup_pending: bool,
    application_started: bool,
    codec_configuration: Option<CodecConfiguration>,
    codec_configuration_sent: bool,
    acknowledged_configuration_id: Option<u32>,
    video_bootstrap: Option<VideoBootstrap>,
    video_bootstrap_sent: bool,
    video_bootstrap_requires_encoder_resume: bool,
    video_bootstrap_retry_attempt: u8,
    acknowledged_generation_id: Option<u32>,
    retired_video_bootstraps: VecDeque<NativeVideoBootstrapIdentity>,
    retired_video_bootstrap_generation_watermark: u32,
    video_bootstrap_failure: Option<String>,
    last_video_bootstrap_acknowledgement: Option<VideoBootstrapResult>,
    next_generation_id: u32,
    repair_keyframe: RepairKeyframeState,
    periodic_idr: PeriodicIdrGate,
    last_sent_video_frame_id: u32,
    last_display_revision: u64,
    adaptive_video: AdaptiveVideoDeliveryController,
    adaptive_policy_lane: AdaptiveVideoPolicyLane,
    next_feedback_window_id: u64,
    pending_feedback_window: Option<PendingMediaFeedbackWindow>,
    media_park_state: NativeMediaParkState,
    media_park_revision: u64,
    media_delivery_generation: u64,
    resume_bootstrap_revision: Option<u64>,
    resume_bootstrap_generation: Option<u32>,
    resume_bootstrap_deadline: Option<Instant>,
    resume_idr_retry_attempt: u8,
}

#[derive(Debug)]
struct NativeDisplayReconfigurationState {
    token: u64,
    revision: u64,
    cancelled: Arc<AtomicBool>,
    completed: Arc<AtomicBool>,
    completed_notify: Arc<Notify>,
}

#[derive(Clone, Debug)]
pub(crate) struct NativeDisplayReconfigurationReservation {
    request_id: u64,
    session_epoch: u32,
    revision: u64,
    token: u64,
    hello: ClientSessionHello,
    plan: HostSessionPlan,
    adaptive_video: AdaptiveVideoDeliveryController,
    platform_plan: PlatformSessionPlan,
    cancelled: Arc<AtomicBool>,
    completed: Arc<AtomicBool>,
    completed_notify: Arc<Notify>,
}

impl NativeDisplayReconfigurationReservation {
    pub(crate) fn execute(
        &self,
        platform: &dyn crate::PlatformSessionControl,
    ) -> Result<(), String> {
        let result = catch_unwind(AssertUnwindSafe(|| {
            platform.reconfigure_session(self.platform_plan)
        }))
        .map_err(|_| "platform display reconfiguration panicked".to_owned())
        .and_then(|result| result);
        self.completed.store(true, Ordering::Release);
        self.completed_notify.notify_waiters();
        result
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct NativeVideoBootstrapIdentity {
    session_epoch: u32,
    stream_id: u32,
    configuration_id: u32,
    generation_id: u32,
    frame_id: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum NativeVideoBootstrapRetryDisposition {
    Retried {
        generation_id: u32,
        attempt: u8,
    },
    Exhausted {
        generation_id: u32,
        attempts: u8,
        message: String,
    },
    Obsolete,
}

impl NativeVideoBootstrapIdentity {
    fn from_bootstrap(bootstrap: &VideoBootstrap) -> Self {
        Self {
            session_epoch: bootstrap.session_epoch,
            stream_id: bootstrap.stream_id,
            configuration_id: bootstrap.configuration_id,
            generation_id: bootstrap.generation_id,
            frame_id: bootstrap.frame_id,
        }
    }

    fn matches_result(self, result: &VideoBootstrapResult) -> bool {
        self.session_epoch == result.session_epoch
            && self.stream_id == result.stream_id
            && self.configuration_id == result.configuration_id
            && self.generation_id == result.generation_id
            && self.frame_id == result.frame_id
    }
}

impl PendingNativeSession {
    fn retire_video_bootstrap(&mut self, bootstrap: VideoBootstrap) {
        let identity = NativeVideoBootstrapIdentity::from_bootstrap(&bootstrap);
        if self.retired_video_bootstraps.contains(&identity) {
            return;
        }
        self.retired_video_bootstraps.push_back(identity);
        self.retired_video_bootstrap_generation_watermark = self
            .retired_video_bootstrap_generation_watermark
            .max(identity.generation_id);
        while self.retired_video_bootstraps.len() > MAX_RETIRED_VIDEO_BOOTSTRAPS {
            self.retired_video_bootstraps.pop_front();
        }
    }

    fn retry_video_bootstrap(
        &mut self,
        generation_id: u32,
        failure: &str,
    ) -> NativeVideoBootstrapRetryDisposition {
        let Some(current) = self.video_bootstrap.as_ref() else {
            return NativeVideoBootstrapRetryDisposition::Obsolete;
        };
        if current.generation_id != generation_id {
            return NativeVideoBootstrapRetryDisposition::Obsolete;
        }
        if self.video_bootstrap_retry_attempt >= MAX_VIDEO_BOOTSTRAP_RETRY_ATTEMPTS {
            self.retire_video_bootstrap(current.clone());
            let message = format!(
                "video bootstrap recovery exhausted after {} retries for generation {generation_id}: {failure}",
                MAX_VIDEO_BOOTSTRAP_RETRY_ATTEMPTS
            );
            self.video_bootstrap_failure = Some(message.clone());
            return NativeVideoBootstrapRetryDisposition::Exhausted {
                generation_id,
                attempts: self.video_bootstrap_retry_attempt,
                message,
            };
        }

        let mut retry = current.clone();
        self.retire_video_bootstrap(current.clone());
        let next_generation_id = self.next_generation_id;
        let Some(next_after_generation_id) = next_generation_id.checked_add(1) else {
            let message = format!(
                "video bootstrap recovery could not allocate a fresh generation after {generation_id}: generation id exhausted"
            );
            self.video_bootstrap_failure = Some(message.clone());
            return NativeVideoBootstrapRetryDisposition::Exhausted {
                generation_id,
                attempts: self.video_bootstrap_retry_attempt,
                message,
            };
        };
        self.next_generation_id = next_after_generation_id;
        retry.generation_id = next_generation_id;
        self.video_bootstrap_retry_attempt += 1;
        self.video_bootstrap_failure = None;
        self.video_bootstrap_sent = false;
        let repair_state = std::mem::replace(&mut self.repair_keyframe, RepairKeyframeState::Idle);
        self.repair_keyframe = match repair_state {
            RepairKeyframeState::AwaitingDecodedBootstrap {
                request,
                generation_id: pending_generation_id,
                frame_id,
            } if pending_generation_id == generation_id => {
                RepairKeyframeState::AwaitingDecodedBootstrap {
                    request,
                    generation_id: next_generation_id,
                    frame_id,
                }
            }
            other => other,
        };
        self.periodic_idr
            .update_retry_generation(generation_id, next_generation_id);
        self.video_bootstrap = Some(retry);
        NativeVideoBootstrapRetryDisposition::Retried {
            generation_id: next_generation_id,
            attempt: self.video_bootstrap_retry_attempt,
        }
    }
}

#[derive(Debug)]
struct NativeStartReservationState {
    token: u64,
    cancelled: Arc<AtomicBool>,
}

#[derive(Clone, Debug)]
pub(crate) struct NativeStartReservation {
    request_id: u64,
    session_epoch: u32,
    token: u64,
    application_id: u32,
    application_uuid: String,
    application_plan: PlatformApplicationPlan,
    session_plan: PlatformSessionPlan,
    starts_application: bool,
    cancelled: Arc<AtomicBool>,
}

#[derive(Debug)]
pub(crate) struct NativeStartExecution {
    started: bool,
    session_cleanup_pending: bool,
    application_started: bool,
    error: Option<String>,
}

#[derive(Debug)]
pub(crate) enum NativeStartCompletion {
    Finalized(NativeStartFinalization),
    Rollback(NativeStartRollback),
}

#[derive(Debug)]
pub(crate) struct NativeStartFinalization {
    pub(crate) responses: Vec<HostControlEnvelope>,
    pub(crate) platform_error: Option<String>,
    pub(crate) started: bool,
}

#[derive(Clone, Debug)]
pub(crate) struct NativeStartRollback {
    request_id: u64,
    session_epoch: u32,
    token: u64,
    session_cleanup_pending: bool,
    application_started: bool,
    error_code: u32,
    message: String,
    publish_platform_error: bool,
}

#[derive(Debug)]
pub(crate) struct NativeStartRollbackResult {
    session_cleanup_pending: bool,
    application_started: bool,
    error: Option<String>,
}

impl NativeStartReservation {
    pub(crate) fn execute(
        &self,
        platform: &dyn crate::PlatformSessionControl,
    ) -> NativeStartExecution {
        if self.cancelled.load(Ordering::Acquire) {
            return NativeStartExecution {
                started: false,
                session_cleanup_pending: false,
                application_started: false,
                error: None,
            };
        }
        let mut application_started = false;
        if self.starts_application {
            if let Err(error) = platform.start_application(self.application_plan.clone()) {
                return NativeStartExecution {
                    started: false,
                    session_cleanup_pending: false,
                    application_started: false,
                    error: Some(format!(
                        "platform application could not be started: {error}"
                    )),
                };
            }
            application_started = true;
        }
        if self.cancelled.load(Ordering::Acquire) {
            return NativeStartExecution {
                started: false,
                session_cleanup_pending: false,
                application_started,
                error: None,
            };
        }
        match platform.start_session(self.session_plan) {
            Ok(()) => NativeStartExecution {
                started: true,
                session_cleanup_pending: true,
                application_started,
                error: None,
            },
            Err(error) => NativeStartExecution {
                started: false,
                session_cleanup_pending: true,
                application_started,
                error: Some(format!(
                    "platform stream session could not be started: {error}"
                )),
            },
        }
    }

    pub(crate) fn worker_failed(&self, error: impl std::fmt::Display) -> NativeStartExecution {
        NativeStartExecution {
            started: false,
            session_cleanup_pending: true,
            application_started: self.starts_application,
            error: Some(format!("platform session start worker failed: {error}")),
        }
    }
}

impl NativeStartRollback {
    pub(crate) fn execute(
        &self,
        platform: &dyn crate::PlatformSessionControl,
    ) -> NativeStartRollbackResult {
        let session_error = self
            .session_cleanup_pending
            .then(|| platform.stop_session())
            .and_then(Result::err);
        let application_error = self
            .application_started
            .then(|| platform.stop_application())
            .and_then(Result::err);
        let session_cleanup_pending = self.session_cleanup_pending && session_error.is_some();
        let application_started = self.application_started && application_error.is_some();
        let error = match (session_error, application_error) {
            (None, None) => None,
            (Some(session), None) => Some(session),
            (None, Some(application)) => Some(application),
            (Some(session), Some(application)) => Some(format!(
                "{session}; application stop also failed: {application}"
            )),
        };
        NativeStartRollbackResult {
            session_cleanup_pending,
            application_started,
            error,
        }
    }

    pub(crate) fn worker_failed(&self, error: impl std::fmt::Display) -> NativeStartRollbackResult {
        NativeStartRollbackResult {
            session_cleanup_pending: self.session_cleanup_pending,
            application_started: self.application_started,
            error: Some(format!("platform session rollback worker failed: {error}")),
        }
    }
}

#[derive(Debug, Default)]
struct AdaptiveVideoPolicyLane {
    revision: u64,
    applying_revision: Option<u64>,
    pending_keyframe_wire_rate_kbps: Option<u32>,
}

#[derive(Debug, Default)]
enum RepairKeyframeState {
    #[default]
    Idle,
    Requested {
        request: Option<VideoKeyframeRequest>,
    },
    AwaitingDecodedBootstrap {
        request: Option<VideoKeyframeRequest>,
        generation_id: u32,
        frame_id: u32,
    },
}

impl RepairKeyframeState {
    fn request(&self) -> Option<&VideoKeyframeRequest> {
        match self {
            Self::Idle => None,
            Self::Requested {
                request: Some(request),
            }
            | Self::AwaitingDecodedBootstrap {
                request: Some(request),
                ..
            } => Some(request),
            Self::Requested { request: None }
            | Self::AwaitingDecodedBootstrap { request: None, .. } => None,
        }
    }

    fn is_active(&self) -> bool {
        !matches!(self, Self::Idle)
    }
}

/// Host-owned single-flight state for controlled periodic refreshes.  The
/// deadline is intentionally not advanced when the platform event is sent:
/// it advances only after the corresponding bootstrap generation is decoded.
/// This keeps an unproductive/idle capture from creating a timer storm while
/// still allowing the next real source frame to consume the due intent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PeriodicIdrState {
    Idle,
    Requested,
    AwaitingDecodedBootstrap { generation_id: u32, frame_id: u32 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PeriodicIdrGate {
    state: PeriodicIdrState,
    next_deadline: Option<Instant>,
}

impl Default for PeriodicIdrGate {
    fn default() -> Self {
        Self {
            state: PeriodicIdrState::Idle,
            next_deadline: None,
        }
    }
}

impl PeriodicIdrGate {
    fn reset(&mut self) {
        *self = Self::default();
    }

    fn is_outstanding(self) -> bool {
        !matches!(self.state, PeriodicIdrState::Idle)
    }

    fn is_due(self, now: Instant) -> bool {
        matches!(self.state, PeriodicIdrState::Idle)
            && self.next_deadline.is_some_and(|deadline| now >= deadline)
    }

    fn mark_requested(&mut self, now: Instant) -> bool {
        guard_due(self, now)
    }

    fn mark_generation(&mut self, generation_id: u32, frame_id: u32) {
        if matches!(self.state, PeriodicIdrState::Requested) {
            self.state = PeriodicIdrState::AwaitingDecodedBootstrap {
                generation_id,
                frame_id,
            };
        }
    }

    fn update_retry_generation(&mut self, old_generation_id: u32, new_generation_id: u32) {
        if let PeriodicIdrState::AwaitingDecodedBootstrap {
            generation_id,
            frame_id,
        } = self.state
        {
            if generation_id == old_generation_id {
                self.state = PeriodicIdrState::AwaitingDecodedBootstrap {
                    generation_id: new_generation_id,
                    frame_id,
                };
            }
        }
    }

    fn acknowledge(&mut self, now: Instant) {
        self.state = PeriodicIdrState::Idle;
        self.next_deadline = Some(now + PERIODIC_IDR_INTERVAL);
    }

    fn schedule_after_generation_ack(&mut self, now: Instant) {
        // Initial/configuration/repair ACKs establish a clean baseline for
        // periodic scheduling. A periodic ACK follows the same path, but is
        // kept explicit at the call site for the ownership invariant.
        self.state = PeriodicIdrState::Idle;
        self.next_deadline = Some(now + PERIODIC_IDR_INTERVAL);
    }

    fn cancel_request(&mut self) {
        if matches!(self.state, PeriodicIdrState::Requested) {
            self.state = PeriodicIdrState::Idle;
        }
    }
}

fn guard_due(gate: &mut PeriodicIdrGate, now: Instant) -> bool {
    if !gate.is_due(now) {
        return false;
    }
    gate.state = PeriodicIdrState::Requested;
    true
}

#[derive(Debug)]
struct PendingMediaFeedbackWindow {
    id: u64,
    window_milliseconds: u32,
    video: Option<MediaFeedbackSample>,
    audio: Option<MediaFeedbackSample>,
}

impl ControlRouter {
    pub(crate) fn dispatch_native_control(
        &mut self,
        envelope: ClientControlEnvelope,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let request_id = envelope.request_id;
        match envelope.payload {
            Some(client_control_envelope::Payload::Hello(hello)) => {
                self.dispatch_native_hello(request_id, hello, context)
            }
            Some(client_control_envelope::Payload::StartSession(start)) => {
                self.dispatch_native_start(request_id, start, context)
            }
            Some(client_control_envelope::Payload::StopSession(stop)) => {
                self.dispatch_native_stop(request_id, stop, context)
            }
            Some(client_control_envelope::Payload::CodecConfigurationAck(ack)) => {
                self.dispatch_native_codec_configuration_ack(request_id, ack, context)
            }
            Some(client_control_envelope::Payload::VideoKeyframeRequest(request)) => {
                self.dispatch_native_video_keyframe_request(request_id, request, context)
            }
            Some(client_control_envelope::Payload::VideoBootstrapResult(result)) => {
                self.dispatch_native_video_bootstrap_result(request_id, result, context)
            }
            Some(client_control_envelope::Payload::DisplayReconfiguration(request)) => {
                self.dispatch_native_display_reconfiguration(request_id, request, context)
            }
            Some(client_control_envelope::Payload::MediaPark(request)) => {
                self.dispatch_native_media_park(request_id, request, context)
            }
            None => vec![native_error(
                request_id,
                ERROR_INVALID_OPERATION,
                "native session operation is not valid in the current state",
            )],
        }
    }

    fn dispatch_native_display_reconfiguration(
        &mut self,
        request_id: u64,
        request: DisplayReconfigurationRequest,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let reservation =
            match self.reserve_native_display_reconfiguration(request_id, request, context) {
                Ok(reservation) => reservation,
                Err(responses) => return responses,
            };
        let result = self.platform.reconfigure_session(reservation.platform_plan);
        self.complete_native_display_reconfiguration(reservation, result)
    }

    fn dispatch_native_media_park(
        &mut self,
        request_id: u64,
        request: MediaParkRequest,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_ref() else {
            return vec![media_park_result(
                request_id,
                request.session_epoch,
                request.revision,
                NativeMediaParkState::Unspecified,
                NativeMediaParkResultCode::Rejected,
                "native session has not been negotiated",
            )];
        };
        let current_state = pending.media_park_state;
        let current_revision = pending.media_park_revision;
        let session_epoch = pending.plan.session_epoch;
        if context.session_epoch != session_epoch || request.session_epoch != session_epoch {
            return vec![media_park_result(
                request_id,
                session_epoch,
                request.revision,
                current_state,
                NativeMediaParkResultCode::Rejected,
                "media park request does not belong to the active session",
            )];
        }
        if pending.plan.media_capabilities & NATIVE_MEDIA_CAPABILITY_MEDIA_PARK_RESUME == 0 {
            return vec![media_park_result(
                request_id,
                session_epoch,
                request.revision,
                current_state,
                NativeMediaParkResultCode::Rejected,
                "media park/resume was not negotiated",
            )];
        }
        if request.revision == 0 {
            return vec![media_park_result(
                request_id,
                session_epoch,
                request.revision,
                current_state,
                NativeMediaParkResultCode::Rejected,
                "media park revision must be nonzero",
            )];
        }
        let current_target_parked = matches!(
            current_state,
            NativeMediaParkState::Parking | NativeMediaParkState::Parked
        );
        let current_target_known = matches!(
            current_state,
            NativeMediaParkState::Active
                | NativeMediaParkState::Parking
                | NativeMediaParkState::Parked
                | NativeMediaParkState::Resuming
        );
        if !current_target_known {
            return vec![media_park_result(
                request_id,
                session_epoch,
                request.revision,
                current_state,
                NativeMediaParkResultCode::Rejected,
                "media park state is invalid",
            )];
        }
        if request.revision < current_revision {
            return vec![media_park_result(
                request_id,
                session_epoch,
                request.revision,
                current_state,
                NativeMediaParkResultCode::Superseded,
                "media park revision is older than the committed revision",
            )];
        }
        if request.revision == current_revision {
            let result = if request.park == current_target_parked {
                NativeMediaParkResultCode::Idempotent
            } else {
                NativeMediaParkResultCode::Superseded
            };
            return vec![media_park_result(
                request_id,
                session_epoch,
                current_revision,
                current_state,
                result,
                if result == NativeMediaParkResultCode::Idempotent {
                    "media park request was already applied"
                } else {
                    "media park revision already committed for the opposite state"
                },
            )];
        }

        let result = match (request.park, current_state) {
            (true, NativeMediaParkState::Parked | NativeMediaParkState::Parking)
            | (false, NativeMediaParkState::Active) => {
                let pending = self
                    .native
                    .pending
                    .as_mut()
                    .expect("validated pending native session");
                pending.media_park_revision = request.revision;
                return vec![media_park_result(
                    request_id,
                    session_epoch,
                    request.revision,
                    current_state,
                    NativeMediaParkResultCode::Applied,
                    "media park state already matched the requested target",
                )];
            }
            (true, NativeMediaParkState::Active | NativeMediaParkState::Resuming) => self
                .enter_media_park(session_epoch, request.revision)
                .map(|state| (state, "media output parked".to_owned()))
                .map_err(|message| (current_state, message)),
            (false, NativeMediaParkState::Parked | NativeMediaParkState::Parking)
            | (false, NativeMediaParkState::Resuming) => self
                .resume_media_from_park(session_epoch, request.revision)
                .map(|state| {
                    (
                        state,
                        "media output is resuming with a fresh bootstrap".to_owned(),
                    )
                })
                .map_err(|message| {
                    (
                        self.native_media_park_state(session_epoch)
                            .unwrap_or(current_state),
                        message,
                    )
                }),
            (_, NativeMediaParkState::Unspecified) => {
                Err((current_state, "media park state is invalid".to_owned()))
            }
        };
        vec![match result {
            Ok((state, message)) => media_park_result(
                request_id,
                session_epoch,
                request.revision,
                state,
                NativeMediaParkResultCode::Applied,
                message,
            ),
            Err((state, message)) => media_park_result(
                request_id,
                session_epoch,
                current_revision,
                state,
                NativeMediaParkResultCode::Rejected,
                message,
            ),
        }]
    }

    fn enter_media_park(
        &mut self,
        session_epoch: u32,
        revision: u64,
    ) -> Result<NativeMediaParkState, String> {
        let pending = self
            .native
            .pending
            .as_ref()
            .ok_or_else(|| "native session has not been negotiated".to_owned())?;
        if !pending.active || pending.plan.session_epoch != session_epoch {
            return Err("native session is not active".to_owned());
        }
        pending
            .next_generation_id
            .checked_add(1)
            .ok_or_else(|| "media park generation exhausted".to_owned())?;
        pending
            .media_delivery_generation
            .checked_add(1)
            .ok_or_else(|| "media delivery generation exhausted".to_owned())?;
        // The platform reset is the external boundary. Do it before publishing
        // PARKING or advancing the revision so a failure can be retried with
        // the same request without consuming the monotonic revision.
        self.platform
            .reset_native_input(session_epoch)
            .map_err(|error| {
                format!("native input reset at media park boundary failed: {error}")
            })?;
        self.platform
            .reset_media_queue(session_epoch)
            .map_err(|error| format!("media queue reset at park boundary failed: {error}"))?;
        let pending = self
            .native
            .pending
            .as_mut()
            .expect("validated pending native session");
        pending.media_park_state = NativeMediaParkState::Parking;
        pending.media_park_revision = revision;
        reset_media_delivery(pending)?;
        pending.media_park_state = NativeMediaParkState::Parked;
        Ok(pending.media_park_state)
    }

    fn resume_media_from_park(
        &mut self,
        session_epoch: u32,
        revision: u64,
    ) -> Result<NativeMediaParkState, String> {
        let pending = self
            .native
            .pending
            .as_ref()
            .ok_or_else(|| "native session has not been negotiated".to_owned())?;
        if !pending.active || pending.plan.session_epoch != session_epoch {
            return Err("native session is not active".to_owned());
        }
        pending
            .next_generation_id
            .checked_add(1)
            .ok_or_else(|| "media park generation exhausted".to_owned())?;
        pending
            .media_delivery_generation
            .checked_add(1)
            .ok_or_else(|| "media delivery generation exhausted".to_owned())?;
        self.platform
            .reset_media_queue(session_epoch)
            .map_err(|error| format!("media queue reset before resume failed: {error}"))?;
        self.platform
            .handle_control_event(session_epoch, crate::PlatformControlEvent::RequestIdrFrame)
            .map_err(|error| format!("fresh media bootstrap could not be requested: {error}"))?;
        let pending = self
            .native
            .pending
            .as_mut()
            .expect("validated pending native session");
        pending.media_park_state = NativeMediaParkState::Resuming;
        pending.media_park_revision = revision;
        reset_media_delivery(pending)?;
        pending.resume_bootstrap_revision = Some(revision);
        pending.resume_bootstrap_deadline =
            Instant::now().checked_add(MEDIA_RESUME_BOOTSTRAP_TIMEOUT);
        self.codec_configuration_notify.notify_one();
        self.video_bootstrap_notify.notify_one();
        Ok(NativeMediaParkState::Resuming)
    }

    pub(crate) fn reserve_native_display_reconfiguration(
        &mut self,
        request_id: u64,
        request: DisplayReconfigurationRequest,
        context: &NativeConnectionContext,
    ) -> Result<NativeDisplayReconfigurationReservation, Vec<HostControlEnvelope>> {
        let Some(pending) = self.native.pending.as_ref() else {
            return Err(vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )]);
        };
        if !pending.active
            || request.session_epoch != pending.plan.session_epoch
            || context.session_epoch != pending.plan.session_epoch
            || request.revision == 0
        {
            return Err(vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "display reconfiguration does not belong to the active session",
            )]);
        }
        if pending.display_reconfiguration.is_some()
            || request.revision <= pending.last_display_revision
        {
            return Err(vec![display_reconfiguration_result(
                request_id,
                request.session_epoch,
                request.revision,
                NativeDisplayReconfigurationResultCode::Superseded,
                pending.plan.clone(),
                "a newer display reconfiguration revision is already active".to_owned(),
            )]);
        }

        let mut hello = pending.hello.clone();
        hello.width = request.width;
        hello.height = request.height;
        hello.refresh_millihz = request.refresh_millihz;
        hello.sink_hidpi = request.sink_hidpi;
        hello.sink_scale_explicit = request.sink_scale_explicit;
        hello.sink_mode_is_logical = request.sink_mode_is_logical;
        hello.sink_scale_percent = request.sink_scale_percent;
        if let Some(requested_format) = hello.requested_video_format.clone() {
            for capability in &mut hello.video_capabilities {
                if capability.format.as_ref() == Some(&requested_format)
                    && capability.hardware_accelerated == Some(true)
                {
                    capability.max_width = request.width;
                    capability.max_height = request.height;
                    capability.max_refresh_millihz = request.refresh_millihz;
                }
            }
        }
        let mut plan = match negotiate_native_session(
            &hello,
            &context.host_capabilities,
            pending.plan.session_epoch,
        ) {
            Ok(plan) => plan,
            Err(error) => {
                return Err(vec![display_reconfiguration_result(
                    request_id,
                    request.session_epoch,
                    request.revision,
                    NativeDisplayReconfigurationResultCode::Rejected,
                    pending.plan.clone(),
                    error.message().to_owned(),
                )])
            }
        };
        plan.policy_revision = pending.plan.policy_revision.saturating_add(1);
        plan.video_configuration_id = pending
            .codec_configuration
            .as_ref()
            .map_or(pending.plan.video_configuration_id, |configuration| {
                configuration.configuration_id
            })
            .saturating_add(1);
        let fec_percentage = self
            .authorities
            .settings()
            .snapshot()
            .effective
            .network
            .fec_percentage;
        let adaptive_video = adaptive_video_controller(&plan, fec_percentage)
            .expect("negotiated display reconfiguration has a valid video quality floor");
        let platform_plan = match native_platform_session_plan(
            &hello,
            &plan,
            adaptive_video.snapshot().encoder_bitrate_kbps,
        ) {
            Ok(plan) => plan,
            Err(error) => {
                return Err(vec![display_reconfiguration_result(
                    request_id,
                    request.session_epoch,
                    request.revision,
                    NativeDisplayReconfigurationResultCode::Rejected,
                    pending.plan.clone(),
                    format!("dynamic platform session plan is invalid: {error}"),
                )])
            }
        };
        self.native.next_display_reconfiguration_token = self
            .native
            .next_display_reconfiguration_token
            .wrapping_add(1)
            .max(1);
        let token = self.native.next_display_reconfiguration_token;
        let cancelled = Arc::new(AtomicBool::new(false));
        let completed = Arc::new(AtomicBool::new(false));
        let completed_notify = Arc::new(Notify::new());
        let pending = self
            .native
            .pending
            .as_mut()
            .expect("validated pending native session");
        pending.display_reconfiguration = Some(NativeDisplayReconfigurationState {
            token,
            revision: request.revision,
            cancelled: Arc::clone(&cancelled),
            completed: Arc::clone(&completed),
            completed_notify: Arc::clone(&completed_notify),
        });
        Ok(NativeDisplayReconfigurationReservation {
            request_id,
            session_epoch: plan.session_epoch,
            revision: request.revision,
            token,
            hello,
            plan,
            adaptive_video,
            platform_plan,
            cancelled,
            completed,
            completed_notify,
        })
    }

    pub(crate) fn complete_native_display_reconfiguration(
        &mut self,
        reservation: NativeDisplayReconfigurationReservation,
        result: Result<(), String>,
    ) -> Vec<HostControlEnvelope> {
        let owns_reservation = self.native.pending.as_ref().is_some_and(|pending| {
            pending.plan.session_epoch == reservation.session_epoch
                && pending
                    .display_reconfiguration
                    .as_ref()
                    .is_some_and(|state| {
                        state.token == reservation.token && state.revision == reservation.revision
                    })
        });
        if !owns_reservation {
            return Vec::new();
        }
        let pending = self
            .native
            .pending
            .as_mut()
            .expect("validated pending native session");
        pending.display_reconfiguration = None;
        if reservation.cancelled.load(Ordering::Acquire) || !pending.active {
            return Vec::new();
        }
        if let Err(error) = result {
            return vec![display_reconfiguration_result(
                reservation.request_id,
                reservation.session_epoch,
                reservation.revision,
                NativeDisplayReconfigurationResultCode::Rejected,
                pending.plan.clone(),
                error,
            )];
        }
        pending.hello = reservation.hello;
        pending.plan = reservation.plan.clone();
        pending.codec_configuration = None;
        pending.codec_configuration_sent = false;
        pending.acknowledged_configuration_id = None;
        if let Some(bootstrap) = pending.video_bootstrap.take() {
            pending.retire_video_bootstrap(bootstrap);
        }
        pending.video_bootstrap_sent = false;
        pending.video_bootstrap_requires_encoder_resume = false;
        pending.video_bootstrap_retry_attempt = 0;
        pending.acknowledged_generation_id = None;
        pending.repair_keyframe = RepairKeyframeState::Idle;
        pending.periodic_idr.reset();
        pending.adaptive_video = reservation.adaptive_video;
        pending.adaptive_policy_lane = AdaptiveVideoPolicyLane {
            revision: pending.adaptive_policy_lane.revision.wrapping_add(1),
            ..AdaptiveVideoPolicyLane::default()
        };
        pending.last_display_revision = reservation.revision;
        vec![display_reconfiguration_result(
            reservation.request_id,
            reservation.session_epoch,
            reservation.revision,
            NativeDisplayReconfigurationResultCode::Applied,
            reservation.plan,
            String::new(),
        )]
    }

    pub(crate) fn native_display_reconfiguration_waiter(
        &self,
        session_epoch: u32,
    ) -> Option<(Arc<Notify>, bool)> {
        self.native.pending.as_ref().and_then(|pending| {
            (pending.plan.session_epoch == session_epoch)
                .then_some(pending.display_reconfiguration.as_ref())
                .flatten()
                .map(|state| {
                    (
                        Arc::clone(&state.completed_notify),
                        state.completed.load(Ordering::Acquire),
                    )
                })
        })
    }

    fn dispatch_native_video_keyframe_request(
        &mut self,
        request_id: u64,
        request: VideoKeyframeRequest,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let reason = NativeVideoKeyframeRequestReason::try_from(request.reason).ok();
        let Some(pending) = self.native.pending.as_ref() else {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )];
        };
        if !pending.active
            || pending.acknowledged_configuration_id.is_none()
            || context.session_epoch != pending.plan.session_epoch
            || request.session_epoch != pending.plan.session_epoch
            || request.stream_id != pending.plan.video_stream_id
            || request.stream_id != u32::from(NATIVE_VIDEO_STREAM_ID)
            || request.after_frame_id > pending.last_sent_video_frame_id
            || request.generation_id == 0
            || reason.is_none_or(|reason| reason == NativeVideoKeyframeRequestReason::Unspecified)
        {
            eprintln!(
                "Lumen native media stage=video-keyframe-request-rejected request-id={request_id} context-session-epoch={} received-session-epoch={} received-stream-id={} received-after-frame-id={} received-reason={} active={} acknowledged-configuration-id={} expected-session-epoch={} expected-stream-id={} last-sent-frame-id={}",
                context.session_epoch,
                request.session_epoch,
                request.stream_id,
                request.after_frame_id,
                request.reason,
                pending.active,
                pending.acknowledged_configuration_id.unwrap_or_default(),
                pending.plan.session_epoch,
                pending.plan.video_stream_id,
                pending.last_sent_video_frame_id,
            );
            return vec![native_error(
                request_id,
                ERROR_INVALID_OPERATION,
                "video keyframe request was rejected",
            )];
        }
        if pending.acknowledged_generation_id != Some(request.generation_id) {
            eprintln!(
                "Lumen native media stage=video-keyframe-request-ignored reason=stale-generation session-epoch={} request-id={request_id} received-generation-id={} acknowledged-generation-id={}",
                request.session_epoch,
                request.generation_id,
                pending.acknowledged_generation_id.unwrap_or_default()
            );
            return Vec::new();
        }
        if pending.repair_keyframe.is_active() {
            let outstanding = pending.repair_keyframe.request();
            eprintln!(
                "Lumen native media stage=video-keyframe-request-coalesced session-epoch={} request-id={request_id} after-frame-id={} outstanding-after-frame-id={} reason={} outstanding-reason={}",
                request.session_epoch,
                request.after_frame_id,
                outstanding.map_or(0, |request| request.after_frame_id),
                request.reason,
                outstanding.map_or(0, |request| request.reason),
            );
            return Vec::new();
        }
        let configuration_id = pending.acknowledged_configuration_id.unwrap_or_default();
        if let Err(error) = self.platform.handle_control_event(
            context.session_epoch,
            crate::PlatformControlEvent::RequestIdrFrame,
        ) {
            return vec![native_error(
                request_id,
                ERROR_PLATFORM,
                format!("video keyframe could not be requested: {error}"),
            )];
        }
        self.native
            .pending
            .as_mut()
            .expect("validated pending native session")
            .repair_keyframe = RepairKeyframeState::Requested {
            request: Some(request.clone()),
        };
        eprintln!(
            "Lumen native media stage=video-keyframe-request-accepted session-epoch={} request-id={request_id} after-frame-id={} reason={} configuration-id={}",
            request.session_epoch,
            request.after_frame_id,
            request.reason,
            configuration_id,
        );
        Vec::new()
    }

    fn dispatch_native_codec_configuration_ack(
        &mut self,
        request_id: u64,
        ack: CodecConfigurationAck,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_mut() else {
            eprintln!(
                "Lumen native QUIC stage=codec-configuration-ack-rejected reason=no-pending-session request-id={request_id} received-session-epoch={} received-stream-id={} received-configuration-id={}",
                ack.session_epoch, ack.stream_id, ack.configuration_id
            );
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )];
        };
        let accepted = pending
            .codec_configuration
            .as_ref()
            .is_some_and(|configuration| {
                pending.codec_configuration_sent
                    && context.session_epoch == configuration.session_epoch
                    && ack.session_epoch == configuration.session_epoch
                    && ack.stream_id == configuration.stream_id
                    && ack.configuration_id == configuration.configuration_id
            });
        if !accepted {
            let expected = pending.codec_configuration.as_ref();
            eprintln!(
                "Lumen native QUIC stage=codec-configuration-ack-rejected reason=contract-mismatch request-id={request_id} active={} sent={} context-session-epoch={} received-session-epoch={} received-stream-id={} received-configuration-id={} expected-session-epoch={} expected-stream-id={} expected-configuration-id={}",
                pending.active,
                pending.codec_configuration_sent,
                context.session_epoch,
                ack.session_epoch,
                ack.stream_id,
                ack.configuration_id,
                expected.map_or(0, |configuration| configuration.session_epoch),
                expected.map_or(0, |configuration| configuration.stream_id),
                expected.map_or(0, |configuration| configuration.configuration_id)
            );
            return vec![native_error(
                request_id,
                ERROR_INVALID_OPERATION,
                "codec configuration acknowledgement was rejected",
            )];
        }
        pending.acknowledged_configuration_id = Some(ack.configuration_id);
        eprintln!(
            "Lumen native QUIC stage=codec-configuration-acknowledged session-epoch={} configuration-id={} request-id={request_id}",
            ack.session_epoch, ack.configuration_id
        );
        Vec::new()
    }

    fn dispatch_native_video_bootstrap_result(
        &mut self,
        request_id: u64,
        result: VideoBootstrapResult,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_mut() else {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )];
        };
        if pending.last_video_bootstrap_acknowledgement.as_ref() == Some(&result) {
            eprintln!(
                "Lumen native media stage=video-bootstrap-result-ignored reason=duplicate-acknowledgement session-epoch={} generation-id={} request-id={request_id}",
                result.session_epoch, result.generation_id
            );
            return Vec::new();
        }
        if pending
            .retired_video_bootstraps
            .iter()
            .copied()
            .any(|identity| identity.matches_result(&result))
            || (result.session_epoch == pending.plan.session_epoch
                && result.stream_id == pending.plan.video_stream_id
                && result.generation_id <= pending.retired_video_bootstrap_generation_watermark)
        {
            eprintln!(
                "Lumen native media stage=video-bootstrap-result-ignored reason=retired-bootstrap session-epoch={} configuration-id={} generation-id={} frame-id={} request-id={request_id}",
                result.session_epoch,
                result.configuration_id,
                result.generation_id,
                result.frame_id,
            );
            return Vec::new();
        }
        if pending.video_bootstrap.as_ref().is_some_and(|bootstrap| {
            result.session_epoch == bootstrap.session_epoch
                && result.stream_id == bootstrap.stream_id
                && result.configuration_id == bootstrap.configuration_id
                && result.generation_id < bootstrap.generation_id
        }) {
            eprintln!(
                "Lumen native media stage=video-bootstrap-result-ignored reason=stale-generation session-epoch={} received-generation-id={} current-generation-id={}",
                result.session_epoch,
                result.generation_id,
                pending
                    .video_bootstrap
                    .as_ref()
                    .map_or(0, |bootstrap| bootstrap.generation_id)
            );
            return Vec::new();
        }
        let accepted = pending.video_bootstrap.as_ref().is_some_and(|bootstrap| {
            pending.video_bootstrap_sent
                && context.session_epoch == bootstrap.session_epoch
                && result.session_epoch == bootstrap.session_epoch
                && result.stream_id == bootstrap.stream_id
                && result.configuration_id == bootstrap.configuration_id
                && result.generation_id == bootstrap.generation_id
                && result.frame_id == bootstrap.frame_id
        });
        if pending.media_park_state == NativeMediaParkState::Resuming
            && (pending.resume_bootstrap_revision != Some(pending.media_park_revision)
                || pending.resume_bootstrap_generation != Some(result.generation_id))
        {
            eprintln!(
                "Lumen native media stage=video-bootstrap-result-ignored reason=resume-revision-mismatch session-epoch={} generation-id={} expected-generation-id={} revision={} expected-revision={}",
                result.session_epoch,
                result.generation_id,
                pending.resume_bootstrap_generation.unwrap_or_default(),
                pending.media_park_revision,
                pending.resume_bootstrap_revision.unwrap_or_default(),
            );
            return Vec::new();
        }
        if !accepted {
            return vec![native_error(
                request_id,
                ERROR_INVALID_OPERATION,
                "video bootstrap acknowledgement was rejected",
            )];
        }
        let result_code = NativeVideoBootstrapResultCode::try_from(result.result).ok();
        if result_code != Some(NativeVideoBootstrapResultCode::Decoded) {
            let message = if result.message.is_empty() {
                format!("video bootstrap was not decoded: {:?}", result_code)
            } else {
                result.message.clone()
            };
            if matches!(
                result_code,
                Some(
                    NativeVideoBootstrapResultCode::DecoderRejected
                        | NativeVideoBootstrapResultCode::Stale
                )
            ) {
                let retry = pending.retry_video_bootstrap(result.generation_id, &message);
                return match retry {
                    NativeVideoBootstrapRetryDisposition::Retried {
                        generation_id,
                        attempt,
                    } => {
                        self.video_bootstrap_notify.notify_one();
                        eprintln!(
                            "Lumen native media stage=video-bootstrap-retry-scheduled session-epoch={} retired-generation-id={} generation-id={generation_id} attempt={attempt} reason={message}",
                            result.session_epoch,
                            result.generation_id,
                        );
                        Vec::new()
                    }
                    NativeVideoBootstrapRetryDisposition::Exhausted { message, .. } => {
                        eprintln!(
                            "Lumen native media stage=video-bootstrap-retry-exhausted session-epoch={} generation-id={} error={message}",
                            result.session_epoch, result.generation_id
                        );
                        vec![native_error(request_id, ERROR_PLATFORM, message)]
                    }
                    NativeVideoBootstrapRetryDisposition::Obsolete => Vec::new(),
                };
            }
            pending.video_bootstrap_failure = Some(message.clone());
            return vec![native_error(request_id, ERROR_PLATFORM, message)];
        }
        let bootstrap_reason = pending
            .video_bootstrap
            .as_ref()
            .and_then(|bootstrap| NativeVideoBootstrapReason::try_from(bootstrap.reason).ok());
        let requires_encoder_resume = pending.video_bootstrap_requires_encoder_resume;
        if requires_encoder_resume {
            if let Err(error) = self.platform.handle_control_event(
                context.session_epoch,
                crate::PlatformControlEvent::ResumeVideoEncodingAfterCodecAck,
            ) {
                pending.video_bootstrap_failure = Some(error.clone());
                return vec![native_error(
                    request_id,
                    ERROR_PLATFORM,
                    format!("video encoding could not resume after bootstrap: {error}"),
                )];
            }
        }
        pending.acknowledged_generation_id = Some(result.generation_id);
        pending.last_video_bootstrap_acknowledgement = Some(result.clone());
        pending.video_bootstrap = None;
        pending.video_bootstrap_sent = false;
        pending.video_bootstrap_requires_encoder_resume = false;
        pending.video_bootstrap_retry_attempt = 0;
        if pending.media_park_state == NativeMediaParkState::Resuming {
            pending.media_park_state = NativeMediaParkState::Active;
            pending.resume_bootstrap_revision = None;
            pending.resume_bootstrap_generation = None;
            pending.resume_bootstrap_deadline = None;
            pending.resume_idr_retry_attempt = 0;
        }
        let now = Instant::now();
        if bootstrap_reason == Some(NativeVideoBootstrapReason::Periodic) {
            pending.periodic_idr.acknowledge(now);
        } else {
            pending.periodic_idr.schedule_after_generation_ack(now);
        }
        if matches!(
            pending.repair_keyframe,
            RepairKeyframeState::AwaitingDecodedBootstrap {
                generation_id,
                frame_id,
                ..
            } if generation_id == result.generation_id && frame_id == result.frame_id
        ) {
            pending.repair_keyframe = RepairKeyframeState::Idle;
        }
        eprintln!(
            "Lumen native media stage=video-bootstrap-acknowledged session-epoch={} configuration-id={} generation-id={} frame-id={} requires-encoder-resume={} request-id={request_id}",
            result.session_epoch,
            result.configuration_id,
            result.generation_id,
            result.frame_id,
            requires_encoder_resume,
        );
        Vec::new()
    }

    pub(crate) fn observe_native_media_feedback(
        &mut self,
        feedback: &MediaFeedback,
        session_epoch: u32,
    ) -> Result<NativeMediaFeedbackDisposition, NativeMediaFeedbackRejection> {
        let Some(pending) = self.native.pending.as_mut() else {
            return Err(NativeMediaFeedbackRejection::SessionUnavailable);
        };
        if session_epoch != pending.plan.session_epoch {
            return Err(NativeMediaFeedbackRejection::SessionEpochMismatch);
        }
        if feedback.stream_id != pending.plan.video_stream_id
            && feedback.stream_id != pending.plan.audio_stream_id
        {
            return Err(NativeMediaFeedbackRejection::StreamMismatch);
        }
        if !pending.active {
            return Err(NativeMediaFeedbackRejection::SessionInactive);
        }
        if feedback.window_milliseconds < NATIVE_MEDIA_FEEDBACK_WINDOW_MILLISECONDS
            || !feedback
                .window_milliseconds
                .is_multiple_of(NATIVE_MEDIA_FEEDBACK_WINDOW_MILLISECONDS)
        {
            return Err(NativeMediaFeedbackRejection::WindowDurationMismatch);
        }
        if feedback.first_datagram_sequence > feedback.highest_datagram_sequence {
            return Err(NativeMediaFeedbackRejection::InvalidSequenceRange);
        }
        if feedback.feedback_window_id != pending.next_feedback_window_id {
            return Err(NativeMediaFeedbackRejection::FeedbackWindowMismatch);
        }
        let expected_datagrams = native_media_feedback_expected_datagrams(feedback);
        let sample = MediaFeedbackSample {
            stream: if feedback.stream_id == pending.plan.audio_stream_id {
                FeedbackStream::Audio
            } else {
                FeedbackStream::Video
            },
            expected_datagrams,
            received_datagrams: feedback.received_datagrams,
            unrecoverable_objects: feedback.unrecoverable_objects,
            late_objects: feedback.late_objects,
            estimated_jitter_us: feedback.estimated_jitter_us,
            decoder_queue_depth: feedback.decoder_queue_depth,
            presentation_drops: feedback.presentation_drops,
            decoder_submissions: feedback.decoder_submissions,
            decoded_frames: feedback.decoded_frames,
            presented_frames: feedback.presented_frames,
            decoder_drops: feedback.decoder_drops,
        };
        let feedback_window =
            pending
                .pending_feedback_window
                .get_or_insert(PendingMediaFeedbackWindow {
                    id: feedback.feedback_window_id,
                    window_milliseconds: feedback.window_milliseconds,
                    video: None,
                    audio: None,
                });
        if feedback_window.id != feedback.feedback_window_id {
            return Err(NativeMediaFeedbackRejection::FeedbackWindowMismatch);
        }
        if feedback_window.window_milliseconds != feedback.window_milliseconds {
            return Err(NativeMediaFeedbackRejection::WindowDurationMismatch);
        }
        let slot = match sample.stream {
            FeedbackStream::Video => &mut feedback_window.video,
            FeedbackStream::Audio => &mut feedback_window.audio,
        };
        if slot.is_some() {
            return Err(NativeMediaFeedbackRejection::DuplicateFeedbackStream);
        }
        *slot = Some(sample);
        let (Some(video), Some(audio)) = (feedback_window.video, feedback_window.audio) else {
            return Ok(NativeMediaFeedbackDisposition::AwaitingPair {
                window_milliseconds: feedback.window_milliseconds,
            });
        };
        pending.pending_feedback_window = None;
        pending.next_feedback_window_id = pending
            .next_feedback_window_id
            .checked_add(1)
            .ok_or(NativeMediaFeedbackRejection::FeedbackWindowMismatch)?;
        let clean_window_units =
            feedback.window_milliseconds / NATIVE_MEDIA_FEEDBACK_WINDOW_MILLISECONDS;
        let retrying_deferred_floor = pending
            .adaptive_policy_lane
            .pending_keyframe_wire_rate_kbps
            .is_some();
        let base = pending.adaptive_video.snapshot();
        let mut controller = pending.adaptive_video.clone();
        if let Some(required_wire_kbps) =
            pending.adaptive_policy_lane.pending_keyframe_wire_rate_kbps
        {
            controller.require_keyframe_wire_rate_kbps(required_wire_kbps);
        }
        let mut decision = controller.observe_window(video, audio, clean_window_units);
        Ok(
            if (decision.changed || retrying_deferred_floor)
                && pending.adaptive_policy_lane.applying_revision.is_none()
            {
                decision.changed = true;
                let proposal = AdaptiveVideoProposal {
                    base,
                    decision,
                    platform_policy_revision: pending.plan.policy_revision,
                    lane_revision: pending.adaptive_policy_lane.revision,
                    controller,
                };
                pending.adaptive_policy_lane.applying_revision = Some(proposal.lane_revision);
                NativeMediaFeedbackDisposition::Applied(proposal)
            } else {
                if controller != pending.adaptive_video
                    && pending.adaptive_policy_lane.applying_revision.is_none()
                {
                    pending.adaptive_video = controller;
                    pending.adaptive_policy_lane.pending_keyframe_wire_rate_kbps = None;
                    pending.adaptive_policy_lane.revision =
                        pending.adaptive_policy_lane.revision.wrapping_add(1);
                } else if pending.adaptive_policy_lane.applying_revision.is_none() {
                    pending.adaptive_policy_lane.pending_keyframe_wire_rate_kbps = None;
                }
                NativeMediaFeedbackDisposition::Unchanged
            },
        )
    }

    #[cfg(test)]
    pub(crate) fn commit_native_adaptive_video(
        &mut self,
        session_epoch: u32,
        proposal: AdaptiveVideoProposal,
    ) -> bool {
        let completion =
            self.finish_native_adaptive_video_policy_apply(session_epoch, proposal, true);
        completion.committed && completion.follow_up.is_none()
    }

    pub(crate) fn finish_native_adaptive_video_policy_apply(
        &mut self,
        session_epoch: u32,
        proposal: AdaptiveVideoProposal,
        applied: bool,
    ) -> AdaptiveVideoPolicyCompletion {
        let Some(pending) = self.native.pending.as_mut() else {
            return AdaptiveVideoPolicyCompletion::default();
        };
        if !pending.active
            || pending.plan.session_epoch != session_epoch
            || pending.adaptive_policy_lane.applying_revision != Some(proposal.lane_revision)
        {
            return AdaptiveVideoPolicyCompletion::default();
        }
        pending.adaptive_policy_lane.applying_revision = None;
        let proposal_is_current = pending.adaptive_policy_lane.revision == proposal.lane_revision
            && pending.adaptive_video.snapshot() == proposal.base;
        let committed = applied && proposal_is_current;
        if !committed {
            return AdaptiveVideoPolicyCompletion {
                active: true,
                committed: false,
                follow_up: None,
            };
        }
        pending.adaptive_video = proposal.controller;
        pending.adaptive_policy_lane.revision =
            pending.adaptive_policy_lane.revision.wrapping_add(1);

        let mut controller = pending.adaptive_video.clone();
        if let Some(required_wire_kbps) = pending
            .adaptive_policy_lane
            .pending_keyframe_wire_rate_kbps
            .take()
        {
            controller.require_keyframe_wire_rate_kbps(required_wire_kbps);
        }
        let base = pending.adaptive_video.snapshot();
        let desired = controller.snapshot();
        let follow_up = if desired != base {
            let mut decision = desired;
            decision.changed = true;
            let proposal = AdaptiveVideoProposal {
                base,
                decision,
                platform_policy_revision: pending.plan.policy_revision,
                lane_revision: pending.adaptive_policy_lane.revision,
                controller,
            };
            pending.adaptive_policy_lane.applying_revision = Some(proposal.lane_revision);
            Some(proposal)
        } else {
            if controller != pending.adaptive_video {
                pending.adaptive_video = controller;
                pending.adaptive_policy_lane.revision =
                    pending.adaptive_policy_lane.revision.wrapping_add(1);
            }
            None
        };
        AdaptiveVideoPolicyCompletion {
            active: true,
            committed,
            follow_up,
        }
    }

    /// Raises the adaptive floor for the active session. Stale epochs are ignored.
    pub(crate) fn require_native_video_keyframe_wire_rate(
        &mut self,
        session_epoch: u32,
        required_wire_kbps: u32,
    ) -> Result<NativeAdaptiveVideoPolicyRequest, String> {
        let Some(pending) = self.native.pending.as_mut() else {
            return Err("native session has not been negotiated".to_owned());
        };
        if !pending.active || pending.plan.session_epoch != session_epoch {
            return Ok(NativeAdaptiveVideoPolicyRequest::Unchanged);
        }
        if pending.adaptive_policy_lane.applying_revision.is_some() {
            pending.adaptive_policy_lane.pending_keyframe_wire_rate_kbps = Some(
                pending
                    .adaptive_policy_lane
                    .pending_keyframe_wire_rate_kbps
                    .map_or(required_wire_kbps, |current| {
                        current.max(required_wire_kbps)
                    }),
            );
            return Ok(NativeAdaptiveVideoPolicyRequest::Deferred);
        }
        let retrying_deferred_floor = pending
            .adaptive_policy_lane
            .pending_keyframe_wire_rate_kbps
            .is_some();
        let required_wire_kbps = pending
            .adaptive_policy_lane
            .pending_keyframe_wire_rate_kbps
            .map_or(required_wire_kbps, |current| {
                current.max(required_wire_kbps)
            });
        pending.adaptive_policy_lane.pending_keyframe_wire_rate_kbps = Some(required_wire_kbps);
        let before = pending.adaptive_video.clone();
        let mut controller = before.clone();
        controller.require_keyframe_wire_rate_kbps(required_wire_kbps);
        if controller == before && !retrying_deferred_floor {
            pending.adaptive_policy_lane.pending_keyframe_wire_rate_kbps = None;
            return Ok(NativeAdaptiveVideoPolicyRequest::Unchanged);
        }
        let base = before.snapshot();
        let mut decision = controller.snapshot();
        if decision == base && !retrying_deferred_floor {
            pending.adaptive_video = controller;
            pending.adaptive_policy_lane.pending_keyframe_wire_rate_kbps = None;
            pending.adaptive_policy_lane.revision =
                pending.adaptive_policy_lane.revision.wrapping_add(1);
            return Ok(NativeAdaptiveVideoPolicyRequest::Unchanged);
        }
        decision.changed = true;
        let proposal = AdaptiveVideoProposal {
            base,
            decision,
            platform_policy_revision: pending.plan.policy_revision,
            lane_revision: pending.adaptive_policy_lane.revision,
            controller,
        };
        pending.adaptive_policy_lane.applying_revision = Some(proposal.lane_revision);
        Ok(NativeAdaptiveVideoPolicyRequest::Applied(proposal))
    }

    pub(crate) fn request_native_video_repair(
        &mut self,
        session_epoch: u32,
        source: NativeVideoRepairSource,
    ) -> Result<bool, String> {
        let Some(pending) = self.native.pending.as_mut() else {
            return Err("native session has not been negotiated".to_owned());
        };
        if !pending.active
            || pending.plan.session_epoch != session_epoch
            || pending.acknowledged_configuration_id.is_none()
        {
            return Err("native video repair does not belong to the active session".to_owned());
        }
        if pending.repair_keyframe.is_active()
            || pending.video_bootstrap.is_some()
            || pending.periodic_idr.is_outstanding()
        {
            return Ok(false);
        }
        self.platform
            .handle_control_event(session_epoch, crate::PlatformControlEvent::RequestIdrFrame)?;
        self.native
            .pending
            .as_mut()
            .expect("validated pending native session")
            .repair_keyframe = RepairKeyframeState::Requested { request: None };
        eprintln!(
            "Lumen native media stage=video-repair-requested session-epoch={session_epoch} source={source:?}"
        );
        Ok(true)
    }

    /// Consumes a due periodic intent only when a real encoded source result
    /// is available. A naturally produced keyframe is accepted as the safe
    /// fallback without sending a second force request; otherwise the
    /// platform event arms its periodic gate for the next source frame.
    pub(crate) fn maybe_request_native_video_periodic(
        &mut self,
        session_epoch: u32,
        frame_is_keyframe: bool,
    ) -> Result<bool, String> {
        let now = Instant::now();
        let Some(pending) = self.native.pending.as_ref() else {
            return Err("native session has not been negotiated".to_owned());
        };
        if !pending.active
            || pending.plan.session_epoch != session_epoch
            || pending.acknowledged_configuration_id.is_none()
            || pending.acknowledged_generation_id.is_none()
            || pending.video_bootstrap.is_some()
            || pending.repair_keyframe.is_active()
            || pending.periodic_idr.is_outstanding()
            || !pending.periodic_idr.is_due(now)
        {
            return Ok(false);
        }

        let pending = self
            .native
            .pending
            .as_mut()
            .expect("validated pending native session");
        if !pending.periodic_idr.mark_requested(now) {
            return Ok(false);
        }
        // Any key frame already produced for this capture instant satisfies
        // the due refresh. Its own metadata decides whether publication is a
        // controlled periodic generation or a bounded repair fallback. Never
        // send a second force request after the key frame already exists.
        if frame_is_keyframe {
            return Ok(false);
        }
        if let Err(error) = self.platform.handle_control_event(
            session_epoch,
            crate::PlatformControlEvent::RequestPeriodicIdrFrame,
        ) {
            self.native
                .pending
                .as_mut()
                .expect("validated pending native session")
                .periodic_idr
                .cancel_request();
            return Err(error);
        }
        eprintln!(
            "Lumen native media stage=video-periodic-idr-requested session-epoch={session_epoch}"
        );
        Ok(true)
    }

    pub(crate) fn finish_native_media_feedback(
        &self,
        session_epoch: u32,
    ) -> Result<(), NativeMediaFeedbackRejection> {
        let Some(pending) = self.native.pending.as_ref() else {
            return Err(NativeMediaFeedbackRejection::SessionUnavailable);
        };
        if session_epoch != pending.plan.session_epoch {
            return Err(NativeMediaFeedbackRejection::SessionEpochMismatch);
        }
        if pending.pending_feedback_window.is_some() {
            return Err(NativeMediaFeedbackRejection::IncompleteFeedbackWindow);
        }
        Ok(())
    }

    pub(crate) fn native_media_capabilities(&self, session_epoch: u32) -> Option<u64> {
        self.native
            .pending
            .as_ref()
            .filter(|pending| pending.plan.session_epoch == session_epoch)
            .map(|pending| pending.plan.media_capabilities)
    }

    pub(crate) fn native_media_park_state(
        &self,
        session_epoch: u32,
    ) -> Option<NativeMediaParkState> {
        self.native.pending.as_ref().and_then(|pending| {
            (pending.plan.session_epoch == session_epoch).then_some(pending.media_park_state)
        })
    }

    #[allow(dead_code)]
    pub(crate) fn native_media_park_revision(&self, session_epoch: u32) -> Option<u64> {
        self.native.pending.as_ref().and_then(|pending| {
            (pending.plan.session_epoch == session_epoch).then_some(pending.media_park_revision)
        })
    }

    pub(crate) fn native_media_delivery_generation(&self, session_epoch: u32) -> Option<u64> {
        self.native.pending.as_ref().and_then(|pending| {
            (pending.plan.session_epoch == session_epoch)
                .then_some(pending.media_delivery_generation)
        })
    }

    /// Advances a stalled RESUMING transition without requiring a separate
    /// host task. The media poll loop calls this watchdog at its bounded
    /// cadence; one fresh IDR request is retried, then the session fails closed
    /// back to PARKED while all control/input/telemetry lanes remain alive.
    pub(crate) fn service_native_media_resume_watchdog(
        &mut self,
        session_epoch: u32,
    ) -> Result<Option<NativeMediaParkState>, String> {
        let Some(pending) = self.native.pending.as_ref() else {
            return Ok(None);
        };
        if pending.plan.session_epoch != session_epoch
            || pending.media_park_state != NativeMediaParkState::Resuming
            || pending
                .resume_bootstrap_deadline
                .is_none_or(|deadline| deadline > Instant::now())
        {
            return Ok(None);
        }
        let revision = pending.media_park_revision;
        let retry_attempt = pending.resume_idr_retry_attempt;
        let can_retry = retry_attempt < MAX_MEDIA_RESUME_IDR_RETRIES;
        if can_retry
            && self.platform.reset_media_queue(session_epoch).is_ok()
            && self
                .platform
                .handle_control_event(session_epoch, crate::PlatformControlEvent::RequestIdrFrame)
                .is_ok()
        {
            let pending = self
                .native
                .pending
                .as_mut()
                .expect("validated pending native session");
            reset_media_delivery(pending)?;
            pending.media_park_state = NativeMediaParkState::Resuming;
            pending.media_park_revision = revision;
            pending.resume_bootstrap_revision = Some(revision);
            pending.resume_bootstrap_deadline =
                Instant::now().checked_add(MEDIA_RESUME_BOOTSTRAP_TIMEOUT);
            pending.resume_idr_retry_attempt = retry_attempt.saturating_add(1);
            return Ok(Some(NativeMediaParkState::Resuming));
        }
        let pending = self
            .native
            .pending
            .as_mut()
            .expect("validated pending native session");
        reset_media_delivery(pending)?;
        pending.media_park_state = NativeMediaParkState::Parked;
        pending.media_park_revision = revision;
        Ok(Some(NativeMediaParkState::Parked))
    }

    #[cfg(test)]
    pub(crate) fn expire_native_media_resume_watchdog_for_test(&mut self, session_epoch: u32) {
        if let Some(pending) = self.native.pending.as_mut() {
            if pending.plan.session_epoch == session_epoch
                && pending.media_park_state == NativeMediaParkState::Resuming
            {
                pending.resume_bootstrap_deadline = Some(Instant::now() - Duration::from_millis(1));
            }
        }
    }

    pub(crate) fn reserve_native_start(
        &mut self,
        request_id: u64,
        start: StartSessionAck,
        context: &NativeConnectionContext,
    ) -> Result<NativeStartReservation, Vec<HostControlEnvelope>> {
        let Some(pending) = self.native.pending.as_ref() else {
            return Err(vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )]);
        };
        if start.session_epoch != pending.plan.session_epoch
            || context.session_epoch != pending.plan.session_epoch
            || pending.active
            || pending.start_reservation.is_some()
        {
            return Err(vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session cannot start in the current state",
            )]);
        }
        let hello = pending.hello.clone();
        let plan = pending.plan.clone();
        let encoder_bitrate_kbps = pending.adaptive_video.snapshot().encoder_bitrate_kbps;
        let current_application_id = self.discovery.current_application_id();
        if (hello.resume && current_application_id != hello.application_id)
            || (!hello.resume && current_application_id != 0)
        {
            return Err(vec![native_error(
                request_id,
                ERROR_SESSION_CONFLICT,
                "application state conflicts with the native session request",
            )]);
        }
        let application = match self
            .authorities
            .applications()
            .launch_plan(hello.application_id)
        {
            Ok(application) => application,
            Err(_) => {
                return Err(vec![native_error(
                    request_id,
                    ERROR_APPLICATION,
                    "application launch plan is unavailable",
                )])
            }
        };
        if self
            .authorities
            .settings_mut()
            .mark_next_session_started()
            .is_err()
        {
            return Err(vec![native_error(
                request_id,
                ERROR_APPLICATION,
                "next-session settings could not be applied",
            )]);
        }
        let application_plan =
            match self.native_application_plan(&hello, &plan, application.clone()) {
                Ok(plan) => plan,
                Err(_) => {
                    return Err(vec![native_error(
                        request_id,
                        ERROR_NEGOTIATION,
                        "native application plan is invalid",
                    )])
                }
            };
        let session_plan = match native_platform_session_plan(&hello, &plan, encoder_bitrate_kbps) {
            Ok(plan) => plan,
            Err(_) => {
                return Err(vec![native_error(
                    request_id,
                    ERROR_NEGOTIATION,
                    "native platform session plan is invalid",
                )])
            }
        };
        self.native.next_start_token = self.native.next_start_token.wrapping_add(1).max(1);
        let token = self.native.next_start_token;
        let cancelled = Arc::new(AtomicBool::new(false));
        self.native
            .pending
            .as_mut()
            .expect("validated pending native session")
            .start_reservation = Some(NativeStartReservationState {
            token,
            cancelled: Arc::clone(&cancelled),
        });
        Ok(NativeStartReservation {
            request_id,
            session_epoch: plan.session_epoch,
            token,
            application_id: application.id,
            application_uuid: application.uuid.clone(),
            application_plan,
            session_plan,
            starts_application: !hello.resume,
            cancelled,
        })
    }

    pub(crate) fn complete_native_start(
        &mut self,
        reservation: &NativeStartReservation,
        execution: NativeStartExecution,
    ) -> NativeStartCompletion {
        let owns_reservation = self.native.pending.as_ref().is_some_and(|pending| {
            pending.plan.session_epoch == reservation.session_epoch
                && pending
                    .start_reservation
                    .as_ref()
                    .is_some_and(|state| state.token == reservation.token)
        });
        let cancelled = reservation.cancelled.load(Ordering::Acquire);
        if owns_reservation && execution.started && !cancelled && execution.error.is_none() {
            let pending = self
                .native
                .pending
                .as_mut()
                .expect("validated pending native session");
            pending.active = true;
            pending.session_cleanup_pending = execution.session_cleanup_pending;
            pending.application_started = execution.application_started;
            pending.start_reservation = None;
            self.discovery.set_running_application(
                reservation.application_id,
                reservation.application_uuid.clone(),
            );
            return NativeStartCompletion::Finalized(NativeStartFinalization {
                responses: vec![HostControlEnvelope {
                    request_id: reservation.request_id,
                    payload: Some(host_control_envelope::Payload::SessionStarted(
                        SessionStarted {
                            session_epoch: reservation.session_epoch,
                        },
                    )),
                }],
                platform_error: None,
                started: true,
            });
        }
        let publish_platform_error = execution.error.is_some();
        let message = execution.error.unwrap_or_else(|| {
            if cancelled {
                "native session start was cancelled".to_owned()
            } else {
                "native session start no longer owns the pending session".to_owned()
            }
        });
        NativeStartCompletion::Rollback(NativeStartRollback {
            request_id: reservation.request_id,
            session_epoch: reservation.session_epoch,
            token: reservation.token,
            session_cleanup_pending: execution.session_cleanup_pending,
            application_started: execution.application_started,
            error_code: if publish_platform_error {
                ERROR_PLATFORM
            } else {
                ERROR_SESSION_STATE
            },
            message,
            publish_platform_error,
        })
    }

    pub(crate) fn finish_native_start_rollback(
        &mut self,
        rollback: NativeStartRollback,
        result: NativeStartRollbackResult,
    ) -> NativeStartFinalization {
        let message = match result.error {
            Some(error) => format!(
                "{}; platform session rollback failed: {error}",
                rollback.message
            ),
            None => rollback.message,
        };
        let owns_reservation = self.native.pending.as_ref().is_some_and(|pending| {
            pending.plan.session_epoch == rollback.session_epoch
                && pending
                    .start_reservation
                    .as_ref()
                    .is_some_and(|state| state.token == rollback.token)
        });
        if owns_reservation {
            let pending = self
                .native
                .pending
                .as_mut()
                .expect("validated pending native session");
            pending.start_reservation = None;
            pending.session_cleanup_pending = result.session_cleanup_pending;
            pending.application_started = result.application_started;
            if !pending.session_cleanup_pending && !pending.application_started {
                self.native.pending = None;
            }
        }
        NativeStartFinalization {
            responses: vec![native_error(
                rollback.request_id,
                rollback.error_code,
                &message,
            )],
            platform_error: rollback.publish_platform_error.then_some(message),
            started: false,
        }
    }

    fn dispatch_native_start(
        &mut self,
        request_id: u64,
        start: StartSessionAck,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let reservation = match self.reserve_native_start(request_id, start, context) {
            Ok(reservation) => reservation,
            Err(responses) => return responses,
        };
        let platform = Arc::clone(&self.platform);
        let execution = reservation.execute(platform.as_ref());
        let finalization = match self.complete_native_start(&reservation, execution) {
            NativeStartCompletion::Finalized(finalization) => finalization,
            NativeStartCompletion::Rollback(rollback) => {
                let result = rollback.execute(platform.as_ref());
                self.finish_native_start_rollback(rollback, result)
            }
        };
        if finalization.started {
            let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
                disposition: PlatformRuntimeEventDisposition::Cleared,
                severity: PlatformRuntimeEventSeverity::Error,
                code: PlatformRuntimeEventCode::NativeSessionPlatform,
                message: None,
            });
        }
        if let Some(message) = finalization.platform_error {
            self.publish_native_platform_error(message);
        }
        finalization.responses
    }

    pub(crate) fn terminate_native_connection(&mut self, session_epoch: u32) -> Result<(), String> {
        let Some(pending) = self.native.pending.as_ref() else {
            return Ok(());
        };
        if pending.plan.session_epoch != session_epoch {
            return Ok(());
        }
        self.cleanup_native_session(session_epoch)
            .map_err(|error| format!("native connection cleanup failed: {error}"))
    }

    fn publish_native_platform_error(&self, message: String) {
        eprintln!("Lumen native session platform error: {message}");
        let _ = self.platform.publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Error,
            code: PlatformRuntimeEventCode::NativeSessionPlatform,
            message: Some(message),
        });
    }

    fn dispatch_native_stop(
        &mut self,
        request_id: u64,
        stop: StopSession,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_ref() else {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session is not running",
            )];
        };
        if stop.session_epoch != pending.plan.session_epoch
            || context.session_epoch != pending.plan.session_epoch
        {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session stop does not match the active session",
            )];
        }
        let session_epoch = pending.plan.session_epoch;
        if self.cleanup_native_session(session_epoch).is_err() {
            return vec![native_error(
                request_id,
                ERROR_PLATFORM,
                "platform session cleanup failed",
            )];
        }
        vec![HostControlEnvelope {
            request_id,
            payload: Some(host_control_envelope::Payload::SessionStopped(
                SessionStopped { session_epoch },
            )),
        }]
    }

    fn cleanup_native_session(&mut self, session_epoch: u32) -> Result<(), String> {
        let Some(pending) = self.native.pending.as_ref() else {
            return Ok(());
        };
        if pending.plan.session_epoch != session_epoch {
            return Ok(());
        }
        if let Some(start) = pending.start_reservation.as_ref() {
            start.cancelled.store(true, Ordering::Release);
            return Ok(());
        }
        if let Some(reconfiguration) = pending.display_reconfiguration.as_ref() {
            // The control task may be aborted while its spawn_blocking worker is still inside
            // the platform bridge. Do not race stop_session against that worker; the next
            // bounded cleanup attempt finalizes the session after the worker publishes done.
            reconfiguration.cancelled.store(true, Ordering::Release);
            if !reconfiguration.completed.load(Ordering::Acquire) {
                return Err(
                    "native display reconfiguration cancellation is still pending".to_owned(),
                );
            }
        }
        let clear_reconfiguration = pending.display_reconfiguration.is_some();
        let session_cleanup_pending = pending.session_cleanup_pending;
        let application_started = pending.application_started;
        if let Some(pending) = self.native.pending.as_mut() {
            if clear_reconfiguration {
                pending.display_reconfiguration = None;
            }
            pending.active = false;
            pending.adaptive_policy_lane = AdaptiveVideoPolicyLane {
                revision: pending.adaptive_policy_lane.revision.wrapping_add(1),
                ..AdaptiveVideoPolicyLane::default()
            };
        }
        let session_error = session_cleanup_pending
            .then(|| self.platform.stop_session())
            .and_then(Result::err);
        if session_cleanup_pending && session_error.is_none() {
            if let Some(pending) = self.native.pending.as_mut() {
                pending.session_cleanup_pending = false;
            }
        }
        let application_error = application_started
            .then(|| self.platform.stop_application())
            .and_then(Result::err);
        if application_started && application_error.is_none() {
            if let Some(pending) = self.native.pending.as_mut() {
                pending.application_started = false;
            }
            self.discovery.clear_running_application();
        }
        let cleanup_complete =
            self.native.pending.as_ref().is_none_or(|pending| {
                !pending.session_cleanup_pending && !pending.application_started
            });
        if cleanup_complete {
            self.native.pending = None;
            return Ok(());
        }
        match (session_error, application_error) {
            (Some(session), None) => Err(session),
            (None, Some(application)) => Err(application),
            (Some(session), Some(application)) => Err(format!(
                "{session}; application stop also failed: {application}"
            )),
            (None, None) => unreachable!("incomplete cleanup must retain a failure"),
        }
    }

    fn dispatch_native_hello(
        &mut self,
        request_id: u64,
        hello: ClientSessionHello,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        if self
            .authorities
            .authentication()
            .verify_access_token(&hello.device_id, &hello.access_token)
            .is_err()
        {
            return vec![native_error(
                request_id,
                ERROR_AUTHENTICATION,
                "device credential was rejected",
            )];
        }
        let application_exists =
            self.authorities
                .applications()
                .applications()
                .is_ok_and(|applications| {
                    applications
                        .iter()
                        .any(|application| application.id == hello.application_id)
                });
        if !application_exists {
            return vec![native_error(
                request_id,
                ERROR_APPLICATION,
                "application is unavailable",
            )];
        }
        if let Some(pending) = self.native.pending.as_ref() {
            if hello.device_id != pending.hello.device_id
                || hello.application_id != pending.hello.application_id
            {
                return vec![native_error(
                    request_id,
                    ERROR_SESSION_CONFLICT,
                    "native session cleanup belongs to another owner",
                )];
            }
            let cleanup_epoch = (!pending.active
                && (pending.session_cleanup_pending || pending.application_started))
                .then_some(pending.plan.session_epoch);
            let Some(cleanup_epoch) = cleanup_epoch else {
                return vec![native_error(
                    request_id,
                    ERROR_SESSION_CONFLICT,
                    "a native session is already pending",
                )];
            };
            if let Err(error) = self.cleanup_native_session(cleanup_epoch) {
                let message = format!("previous native session cleanup remains pending: {error}");
                self.publish_native_platform_error(message.clone());
                return vec![native_error(request_id, ERROR_PLATFORM, message)];
            }
        }
        let plan = match negotiate_native_session(
            &hello,
            &context.host_capabilities,
            context.session_epoch,
        ) {
            Ok(plan) => plan,
            Err(error) => return vec![native_negotiation_error(request_id, error)],
        };
        self.native.pending = Some(PendingNativeSession {
            hello,
            plan: plan.clone(),
            active: false,
            start_reservation: None,
            display_reconfiguration: None,
            session_cleanup_pending: false,
            application_started: false,
            codec_configuration: None,
            codec_configuration_sent: false,
            acknowledged_configuration_id: None,
            video_bootstrap: None,
            video_bootstrap_sent: false,
            video_bootstrap_requires_encoder_resume: false,
            video_bootstrap_retry_attempt: 0,
            acknowledged_generation_id: None,
            retired_video_bootstraps: VecDeque::new(),
            retired_video_bootstrap_generation_watermark: 0,
            video_bootstrap_failure: None,
            last_video_bootstrap_acknowledgement: None,
            next_generation_id: 1,
            repair_keyframe: RepairKeyframeState::Idle,
            periodic_idr: PeriodicIdrGate::default(),
            last_sent_video_frame_id: 0,
            last_display_revision: 0,
            adaptive_video: adaptive_video_controller(
                &plan,
                self.authorities
                    .settings()
                    .snapshot()
                    .effective
                    .network
                    .fec_percentage,
            )
            .expect("negotiated native session has a valid video quality floor"),
            adaptive_policy_lane: AdaptiveVideoPolicyLane::default(),
            next_feedback_window_id: 1,
            pending_feedback_window: None,
            media_park_state: NativeMediaParkState::Active,
            media_park_revision: 0,
            media_delivery_generation: 0,
            resume_bootstrap_revision: None,
            resume_bootstrap_generation: None,
            resume_bootstrap_deadline: None,
            resume_idr_retry_attempt: 0,
        });
        vec![HostControlEnvelope {
            request_id,
            payload: Some(host_control_envelope::Payload::SessionPlan(plan)),
        }]
    }

    pub(crate) fn native_input_is_active(&self, session_epoch: u32) -> bool {
        self.native
            .pending
            .as_ref()
            .is_some_and(|pending| pending.active && pending.plan.session_epoch == session_epoch)
    }

    #[allow(dead_code)]
    pub(crate) fn publish_native_codec_configuration(
        &mut self,
        configuration: CodecConfiguration,
    ) -> bool {
        self.publish_native_codec_configuration_for_revision(configuration, None)
    }

    pub(crate) fn publish_native_codec_configuration_for_revision(
        &mut self,
        configuration: CodecConfiguration,
        expected_media_park_revision: Option<u64>,
    ) -> bool {
        self.publish_native_codec_configuration_for_revision_and_generation(
            configuration,
            expected_media_park_revision,
            None,
        )
    }

    pub(crate) fn publish_native_codec_configuration_for_revision_and_generation(
        &mut self,
        configuration: CodecConfiguration,
        expected_media_park_revision: Option<u64>,
        expected_media_delivery_generation: Option<u64>,
    ) -> bool {
        {
            let Some(pending) = self.native.pending.as_mut() else {
                return false;
            };
            if !pending.active
                || matches!(
                    pending.media_park_state,
                    NativeMediaParkState::Parking | NativeMediaParkState::Parked
                )
                || expected_media_park_revision
                    .is_some_and(|revision| revision != pending.media_park_revision)
                || expected_media_delivery_generation
                    .is_some_and(|generation| generation != pending.media_delivery_generation)
                || configuration.session_epoch != pending.plan.session_epoch
                || configuration.stream_id != u32::from(NATIVE_VIDEO_STREAM_ID)
                || configuration.stream_id != pending.plan.video_stream_id
                || configuration.configuration_id == 0
                || configuration.decoder_configuration_record.is_empty()
                || pending
                    .plan
                    .selected_video_codec()
                    .map(|codec| codec as i32)
                    != Some(configuration.codec)
                || pending.codec_configuration.as_ref().is_some_and(|current| {
                    current.configuration_id >= configuration.configuration_id
                })
            {
                return false;
            }
            pending.codec_configuration = Some(configuration);
            pending.codec_configuration_sent = false;
            pending.acknowledged_configuration_id = None;
            pending.periodic_idr.reset();
        }
        self.codec_configuration_notify.notify_one();
        true
    }

    pub(crate) fn take_native_codec_configuration(
        &mut self,
        session_epoch: u32,
    ) -> Option<CodecConfiguration> {
        let pending = self.native.pending.as_mut()?;
        if pending.plan.session_epoch != session_epoch
            || pending.codec_configuration_sent
            || matches!(
                pending.media_park_state,
                NativeMediaParkState::Parking | NativeMediaParkState::Parked
            )
        {
            return None;
        }
        let configuration = pending.codec_configuration.clone()?;
        pending.codec_configuration_sent = true;
        Some(configuration)
    }

    pub(crate) fn native_codec_configuration_is_acknowledged(
        &self,
        session_epoch: u32,
        configuration_id: u32,
    ) -> bool {
        self.native.pending.as_ref().is_some_and(|pending| {
            pending.active
                && pending.plan.session_epoch == session_epoch
                && pending.acknowledged_configuration_id == Some(configuration_id)
        })
    }

    pub(crate) fn native_codec_configuration_send_is_current(
        &self,
        session_epoch: u32,
        configuration_id: u32,
        media_delivery_generation: u64,
    ) -> bool {
        self.native.pending.as_ref().is_some_and(|pending| {
            pending.active
                && pending.plan.session_epoch == session_epoch
                && !matches!(
                    pending.media_park_state,
                    NativeMediaParkState::Parking | NativeMediaParkState::Parked
                )
                && pending.media_delivery_generation == media_delivery_generation
                && pending.codec_configuration_sent
                && pending
                    .codec_configuration
                    .as_ref()
                    .is_some_and(|configuration| configuration.configuration_id == configuration_id)
        })
    }

    #[allow(dead_code)]
    pub(crate) fn publish_native_video_bootstrap(
        &mut self,
        configuration_id: u32,
        frame_id: u32,
        capture_timestamp_us: u32,
        reason: NativeVideoBootstrapReason,
        requires_encoder_resume: bool,
        access_unit: Vec<u8>,
    ) -> Option<u32> {
        self.publish_native_video_bootstrap_for_revision(
            configuration_id,
            frame_id,
            capture_timestamp_us,
            reason,
            requires_encoder_resume,
            access_unit,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn publish_native_video_bootstrap_for_revision(
        &mut self,
        configuration_id: u32,
        frame_id: u32,
        capture_timestamp_us: u32,
        reason: NativeVideoBootstrapReason,
        requires_encoder_resume: bool,
        access_unit: Vec<u8>,
        expected_media_park_revision: Option<u64>,
    ) -> Option<u32> {
        self.publish_native_video_bootstrap_for_revision_and_generation(
            configuration_id,
            frame_id,
            capture_timestamp_us,
            reason,
            requires_encoder_resume,
            access_unit,
            expected_media_park_revision,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn publish_native_video_bootstrap_for_revision_and_generation(
        &mut self,
        configuration_id: u32,
        frame_id: u32,
        capture_timestamp_us: u32,
        reason: NativeVideoBootstrapReason,
        requires_encoder_resume: bool,
        access_unit: Vec<u8>,
        expected_media_park_revision: Option<u64>,
        expected_media_delivery_generation: Option<u64>,
    ) -> Option<u32> {
        let pending = self.native.pending.as_mut()?;
        if !pending.active
            || matches!(
                pending.media_park_state,
                NativeMediaParkState::Parking | NativeMediaParkState::Parked
            )
            || expected_media_park_revision
                .is_some_and(|revision| revision != pending.media_park_revision)
            || expected_media_delivery_generation
                .is_some_and(|generation| generation != pending.media_delivery_generation)
            || pending.acknowledged_configuration_id != Some(configuration_id)
            || frame_id == 0
            || access_unit.is_empty()
            || reason == NativeVideoBootstrapReason::Unspecified
        {
            return None;
        }
        if reason == NativeVideoBootstrapReason::Repair
            && (!requires_encoder_resume
                || matches!(
                    pending.repair_keyframe,
                    RepairKeyframeState::AwaitingDecodedBootstrap { .. }
                ))
        {
            return None;
        }
        if let Some(bootstrap) = pending.video_bootstrap.take() {
            pending.retire_video_bootstrap(bootstrap);
        }
        let generation_id = pending.next_generation_id;
        pending.next_generation_id = generation_id.checked_add(1)?;
        pending.acknowledged_generation_id = None;
        pending.video_bootstrap_failure = None;
        pending.video_bootstrap_requires_encoder_resume = requires_encoder_resume;
        pending.video_bootstrap_retry_attempt = 0;
        if reason == NativeVideoBootstrapReason::Periodic {
            pending
                .periodic_idr
                .mark_generation(generation_id, frame_id);
        }
        if reason == NativeVideoBootstrapReason::Repair {
            let request = match std::mem::take(&mut pending.repair_keyframe) {
                RepairKeyframeState::Idle => None,
                RepairKeyframeState::Requested { request } => request,
                RepairKeyframeState::AwaitingDecodedBootstrap { .. } => unreachable!(
                    "repair bootstrap single-flight was validated before generation allocation"
                ),
            };
            pending.repair_keyframe = RepairKeyframeState::AwaitingDecodedBootstrap {
                request,
                generation_id,
                frame_id,
            };
        }
        pending.video_bootstrap = Some(VideoBootstrap {
            session_epoch: pending.plan.session_epoch,
            stream_id: u32::from(NATIVE_VIDEO_STREAM_ID),
            configuration_id,
            generation_id,
            frame_id,
            capture_timestamp_us,
            reason: reason as i32,
            access_unit,
        });
        if pending.media_park_state == NativeMediaParkState::Resuming {
            pending.resume_bootstrap_revision = Some(pending.media_park_revision);
            pending.resume_bootstrap_generation = Some(generation_id);
        }
        pending.video_bootstrap_sent = false;
        self.video_bootstrap_notify.notify_one();
        Some(generation_id)
    }

    pub(crate) fn take_native_video_bootstrap(
        &mut self,
        session_epoch: u32,
    ) -> Option<VideoBootstrap> {
        let pending = self.native.pending.as_mut()?;
        if pending.plan.session_epoch != session_epoch
            || pending.video_bootstrap_sent
            || matches!(
                pending.media_park_state,
                NativeMediaParkState::Parking | NativeMediaParkState::Parked
            )
        {
            return None;
        }
        let bootstrap = pending.video_bootstrap.clone()?;
        pending.video_bootstrap_sent = true;
        Some(bootstrap)
    }

    pub(crate) fn native_video_bootstrap_send_is_current(
        &self,
        session_epoch: u32,
        generation_id: u32,
        media_delivery_generation: u64,
    ) -> bool {
        self.native.pending.as_ref().is_some_and(|pending| {
            pending.active
                && pending.plan.session_epoch == session_epoch
                && !matches!(
                    pending.media_park_state,
                    NativeMediaParkState::Parking | NativeMediaParkState::Parked
                )
                && pending.media_delivery_generation == media_delivery_generation
                && pending.video_bootstrap_sent
                && pending
                    .video_bootstrap
                    .as_ref()
                    .is_some_and(|bootstrap| bootstrap.generation_id == generation_id)
        })
    }

    pub(crate) fn native_media_datagram_send_is_current(
        &self,
        session_epoch: u32,
        media_park_revision: u64,
        media_delivery_generation: u64,
        generation_id: Option<u32>,
    ) -> bool {
        self.native.pending.as_ref().is_some_and(|pending| {
            pending.active
                && pending.plan.session_epoch == session_epoch
                && pending.media_park_revision == media_park_revision
                && pending.media_delivery_generation == media_delivery_generation
                && !matches!(
                    pending.media_park_state,
                    NativeMediaParkState::Parking | NativeMediaParkState::Parked
                )
                && generation_id
                    .is_none_or(|generation| pending.acknowledged_generation_id == Some(generation))
        })
    }

    pub(crate) fn retry_native_video_bootstrap(
        &mut self,
        session_epoch: u32,
        generation_id: u32,
        failure: &str,
    ) -> NativeVideoBootstrapRetryDisposition {
        let Some(pending) = self.native.pending.as_mut() else {
            return NativeVideoBootstrapRetryDisposition::Obsolete;
        };
        if pending.plan.session_epoch != session_epoch || !pending.active {
            return NativeVideoBootstrapRetryDisposition::Obsolete;
        }
        let retry = pending.retry_video_bootstrap(generation_id, failure);
        if matches!(retry, NativeVideoBootstrapRetryDisposition::Retried { .. }) {
            self.video_bootstrap_notify.notify_one();
        }
        retry
    }

    pub(crate) fn native_video_bootstrap_retry_attempt(&self, session_epoch: u32) -> Option<u8> {
        self.native.pending.as_ref().and_then(|pending| {
            (pending.active
                && pending.plan.session_epoch == session_epoch
                && pending.video_bootstrap_retry_attempt > 0)
                .then_some(pending.video_bootstrap_retry_attempt)
        })
    }

    pub(crate) fn native_video_bootstrap_is_acknowledged(
        &self,
        session_epoch: u32,
        generation_id: u32,
    ) -> bool {
        self.native.pending.as_ref().is_some_and(|pending| {
            pending.active
                && pending.plan.session_epoch == session_epoch
                && (pending.acknowledged_generation_id == Some(generation_id)
                    || pending
                        .last_video_bootstrap_acknowledgement
                        .as_ref()
                        .is_some_and(|result| {
                            result.session_epoch == session_epoch
                                && result.generation_id == generation_id
                        }))
        })
    }

    pub(crate) fn native_video_bootstrap_is_obsolete(
        &self,
        session_epoch: u32,
        generation_id: u32,
    ) -> bool {
        self.native.pending.as_ref().is_some_and(|pending| {
            pending.plan.session_epoch == session_epoch
                && (pending.retired_video_bootstrap_generation_watermark != 0
                    && generation_id <= pending.retired_video_bootstrap_generation_watermark
                    || pending.retired_video_bootstraps.iter().any(|identity| {
                        identity.session_epoch == session_epoch
                            && identity.generation_id == generation_id
                    }))
        })
    }

    pub(crate) fn native_video_bootstrap_generation(&self, session_epoch: u32) -> Option<u32> {
        self.native.pending.as_ref().and_then(|pending| {
            (pending.plan.session_epoch == session_epoch)
                .then(|| {
                    pending
                        .video_bootstrap
                        .as_ref()
                        .map(|bootstrap| bootstrap.generation_id)
                })
                .flatten()
        })
    }

    pub(crate) fn native_video_bootstrap_failure(
        &self,
        session_epoch: u32,
        generation_id: u32,
    ) -> Option<String> {
        self.native.pending.as_ref().and_then(|pending| {
            (pending.plan.session_epoch == session_epoch
                && pending
                    .video_bootstrap
                    .as_ref()
                    .is_some_and(|bootstrap| bootstrap.generation_id == generation_id))
            .then(|| pending.video_bootstrap_failure.clone())
            .flatten()
        })
    }

    pub(crate) fn observe_native_video_frame_sent(
        &mut self,
        session_epoch: u32,
        frame_id: u32,
    ) -> bool {
        let Some(pending) = self.native.pending.as_mut() else {
            return false;
        };
        if !pending.active
            || pending.plan.session_epoch != session_epoch
            || frame_id == 0
            || frame_id <= pending.last_sent_video_frame_id
        {
            return false;
        }
        pending.last_sent_video_frame_id = frame_id;
        true
    }

    #[cfg(test)]
    pub(crate) fn native_video_keyframe_request_is_outstanding(&self) -> bool {
        self.native
            .pending
            .as_ref()
            .is_some_and(|pending| pending.repair_keyframe.is_active())
    }

    pub(crate) fn video_delivery_state(&self) -> Option<VideoDeliveryState> {
        self.native_video_delivery_state()
    }

    pub(crate) fn audio_delivery_state(&self) -> Option<AudioDeliveryState> {
        self.native_audio_delivery_state()
    }

    pub(crate) fn input_motion_delivery_state(&self) -> Option<InputMotionDeliveryState> {
        let pending = self.native.pending.as_ref()?;
        if !pending.active {
            return None;
        }
        Some(InputMotionDeliveryState {
            session_epoch: pending.plan.session_epoch,
            policy_revision: u16::try_from(pending.plan.policy_revision).ok()?,
        })
    }

    fn native_video_delivery_state(&self) -> Option<VideoDeliveryState> {
        let pending = self.native.pending.as_ref()?;
        if !pending.active {
            return None;
        }
        let adaptive = pending.adaptive_video.snapshot();
        Some(VideoDeliveryState {
            video_format: platform_video_format(&pending.plan)?,
            acknowledged_configuration_id: pending.acknowledged_configuration_id,
            acknowledged_generation_id: pending.acknowledged_generation_id,
            bootstrap_pending: pending.video_bootstrap.is_some(),
            bootstrap_reason: pending
                .video_bootstrap
                .as_ref()
                .and_then(|bootstrap| NativeVideoBootstrapReason::try_from(bootstrap.reason).ok()),
            bootstrap_requires_encoder_resume: pending
                .video_bootstrap
                .as_ref()
                .is_some_and(|_| pending.video_bootstrap_requires_encoder_resume),
            repair_keyframe_requested: pending.repair_keyframe.is_active(),
            session_epoch: pending.plan.session_epoch,
            policy_revision: u16::try_from(pending.plan.policy_revision).ok()?,
            maximum_datagram_payload: usize::try_from(pending.plan.maximum_datagram_payload)
                .ok()?,
            maximum_object_delay_us: pending.plan.maximum_object_delay_us,
            refresh_millihz: pending
                .plan
                .selected_video_capability
                .as_ref()?
                .max_refresh_millihz,
            fec_percentage: adaptive.fec_percentage,
            wire_budget_kbps: adaptive.wire_budget_kbps,
            target_bitrate_kbps: adaptive.encoder_bitrate_kbps,
            admission_divisor: adaptive.admission_divisor,
            media_park_revision: pending.media_park_revision,
            media_delivery_generation: pending.media_delivery_generation,
            parked: matches!(
                pending.media_park_state,
                NativeMediaParkState::Parking | NativeMediaParkState::Parked
            ),
        })
    }

    fn native_audio_delivery_state(&self) -> Option<AudioDeliveryState> {
        let pending = self.native.pending.as_ref()?;
        if !pending.active {
            return None;
        }
        Some(AudioDeliveryState {
            session_epoch: pending.plan.session_epoch,
            policy_revision: u16::try_from(pending.plan.policy_revision).ok()?,
            maximum_datagram_payload: usize::try_from(pending.plan.maximum_datagram_payload)
                .ok()?,
            media_park_revision: pending.media_park_revision,
            media_delivery_generation: pending.media_delivery_generation,
            parked: matches!(
                pending.media_park_state,
                NativeMediaParkState::Parking | NativeMediaParkState::Parked
            ),
        })
    }

    pub(super) fn cleanup_current_native_session(&mut self) -> Result<(), String> {
        let Some(session_epoch) = self
            .native
            .pending
            .as_ref()
            .map(|pending| pending.plan.session_epoch)
        else {
            return Ok(());
        };
        self.cleanup_native_session(session_epoch)
    }

    fn native_application_plan(
        &self,
        hello: &ClientSessionHello,
        plan: &HostSessionPlan,
        application: lumen_engine::ApplicationLaunchPlan,
    ) -> Result<PlatformApplicationPlan, String> {
        let settings = self.authorities.settings().snapshot().effective;
        let global_prep_commands = if application.exclude_global_prep_commands {
            Vec::new()
        } else {
            settings.commands.prep
        };
        let global_state_commands = if application.exclude_global_state_commands {
            Vec::new()
        } else {
            settings.commands.state
        };
        Ok(PlatformApplicationPlan {
            application,
            global_prep_commands,
            global_state_commands,
            server_commands: settings.commands.server,
            width: plan.encoded_width,
            height: plan.encoded_height,
            frames_per_second: refresh_millihz_to_frames_per_second(plan.refresh_millihz)?,
            virtual_display: hello.virtual_display,
            session_offer: native_session_offer(plan)?,
        })
    }
}

pub(super) fn native_media_feedback_expected_datagrams(feedback: &MediaFeedback) -> u32 {
    if feedback.received_datagrams == 0
        && feedback.first_datagram_sequence == 0
        && feedback.highest_datagram_sequence == 0
    {
        return 0;
    }
    feedback
        .highest_datagram_sequence
        .saturating_sub(feedback.first_datagram_sequence)
        .saturating_add(1)
}

fn native_platform_session_plan(
    hello: &ClientSessionHello,
    plan: &HostSessionPlan,
    encoder_bitrate_kbps: u32,
) -> Result<PlatformSessionPlan, String> {
    let video_format =
        platform_video_format(plan).ok_or_else(|| "native video format is invalid".to_owned())?;
    Ok(PlatformSessionPlan {
        session_epoch: plan.session_epoch,
        policy_revision: plan.policy_revision,
        width: plan.encoded_width,
        height: plan.encoded_height,
        frames_per_second: refresh_millihz_to_frames_per_second(plan.refresh_millihz)?,
        bitrate_kbps: encoder_bitrate_kbps,
        video_format,
        audio_channels: u8::try_from(plan.opus_channel_count)
            .map_err(|_| "native audio channel count is invalid".to_owned())?,
        enhanced_audio_quality: plan.enhanced_audio_quality,
        play_audio_on_host: hello.play_audio_on_host,
        virtual_display: hello.virtual_display,
        encoder_csc_mode: 2,
        sink_hidpi: plan.sink_hidpi,
        sink_scale_explicit: plan.sink_scale_explicit,
        sink_mode_is_logical: plan.sink_mode_is_logical,
        sink_scale_percent: i32::try_from(plan.sink_scale_percent)
            .map_err(|_| "native display scale is invalid".to_owned())?,
        sink_gamut: plan.sink_gamut,
        sink_transfer: plan.sink_transfer,
        sink_current_edr_headroom: plan.sink_current_edr_headroom,
        sink_potential_edr_headroom: plan.sink_potential_edr_headroom,
        sink_current_peak_luminance_nits: i32::try_from(plan.sink_current_peak_luminance_nits)
            .map_err(|_| "native current display luminance is invalid".to_owned())?,
        sink_potential_peak_luminance_nits: i32::try_from(plan.sink_potential_peak_luminance_nits)
            .map_err(|_| "native potential display luminance is invalid".to_owned())?,
        sink_supports_frame_gated_hdr: plan.sink_supports_frame_gated_hdr,
        sink_supports_hdr_tile_overlay: plan.sink_supports_hdr_tile_overlay,
        sink_supports_per_frame_hdr_metadata: plan.sink_supports_per_frame_hdr_metadata,
        negotiated_dynamic_range_transport: plan.dynamic_range_transport,
    })
}

fn platform_video_format(plan: &HostSessionPlan) -> Option<PlatformVideoFormat> {
    let selected = plan.selected_video_format()?;
    Some(PlatformVideoFormat {
        codec: match NativeVideoCodec::try_from(selected.codec).ok()? {
            NativeVideoCodec::H264 => PlatformVideoCodec::H264,
            NativeVideoCodec::Hevc => PlatformVideoCodec::Hevc,
            NativeVideoCodec::Av1 => PlatformVideoCodec::Av1,
            NativeVideoCodec::Unspecified => return None,
        },
        profile: match NativeVideoProfile::try_from(selected.profile).ok()? {
            NativeVideoProfile::H264Main => PlatformVideoProfile::H264Main,
            NativeVideoProfile::H264High => PlatformVideoProfile::H264High,
            NativeVideoProfile::H264High444Predictive => {
                PlatformVideoProfile::H264High444Predictive
            }
            NativeVideoProfile::HevcMain => PlatformVideoProfile::HevcMain,
            NativeVideoProfile::HevcMain10 => PlatformVideoProfile::HevcMain10,
            NativeVideoProfile::HevcMain444 => PlatformVideoProfile::HevcMain444,
            NativeVideoProfile::HevcMain44410 => PlatformVideoProfile::HevcMain44410,
            NativeVideoProfile::Av1Main => PlatformVideoProfile::Av1Main,
            NativeVideoProfile::Unspecified => return None,
        },
        chroma_subsampling: match NativeChromaSubsampling::try_from(selected.chroma_subsampling)
            .ok()?
        {
            NativeChromaSubsampling::Yuv420 => PlatformChromaSubsampling::Yuv420,
            NativeChromaSubsampling::Yuv444 => PlatformChromaSubsampling::Yuv444,
            NativeChromaSubsampling::Unspecified => return None,
        },
        bit_depth: u8::try_from(selected.bit_depth).ok()?,
        dynamic_range: match NativeDynamicRange::try_from(selected.dynamic_range).ok()? {
            NativeDynamicRange::Sdr => PlatformDynamicRange::Sdr,
            NativeDynamicRange::Hdr10 => PlatformDynamicRange::Hdr10,
            NativeDynamicRange::Unspecified => return None,
        },
        color_range: match NativeColorRange::try_from(selected.color_range).ok()? {
            NativeColorRange::Limited => PlatformColorRange::Limited,
            NativeColorRange::Full => PlatformColorRange::Full,
            NativeColorRange::Unspecified => return None,
        },
    })
}

fn native_session_offer(plan: &HostSessionPlan) -> Result<LumenSessionOffer, String> {
    Ok(LumenSessionOffer {
        version: 3,
        hidpi: plan.sink_hidpi,
        scale_explicit: plan.sink_scale_explicit,
        mode_is_logical: plan.sink_mode_is_logical,
        scale_percent: i32::try_from(plan.sink_scale_percent)
            .map_err(|_| "native display scale is invalid".to_owned())?,
        gamut: plan.sink_gamut,
        transfer: plan.sink_transfer,
        current_edr_headroom: plan.sink_current_edr_headroom,
        potential_edr_headroom: plan.sink_potential_edr_headroom,
        current_peak_luminance_nits: i32::try_from(plan.sink_current_peak_luminance_nits)
            .map_err(|_| "native current display luminance is invalid".to_owned())?,
        potential_peak_luminance_nits: i32::try_from(plan.sink_potential_peak_luminance_nits)
            .map_err(|_| "native potential display luminance is invalid".to_owned())?,
        supports_frame_gated_hdr: plan.sink_supports_frame_gated_hdr,
        supports_hdr_tile_overlay: plan.sink_supports_hdr_tile_overlay,
        supports_per_frame_hdr_metadata: plan.sink_supports_per_frame_hdr_metadata,
        requested_transport: plan.dynamic_range_transport,
    })
}

fn refresh_millihz_to_frames_per_second(refresh_millihz: u32) -> Result<u32, String> {
    let frames_per_second = refresh_millihz.saturating_add(500) / 1_000;
    (frames_per_second > 0)
        .then_some(frames_per_second)
        .ok_or_else(|| "native refresh rate is invalid".to_owned())
}

fn adaptive_video_controller(
    plan: &HostSessionPlan,
    initial_fec_percentage: u16,
) -> Option<AdaptiveVideoDeliveryController> {
    let dynamic_range = plan
        .selected_video_format()
        .and_then(|format| NativeDynamicRange::try_from(format.dynamic_range).ok())?;
    let selected_format = plan.selected_video_format()?;
    let quality_floor_encoder_kbps = minimum_video_encoder_bitrate_kbps(
        plan.encoded_width,
        plan.encoded_height,
        plan.refresh_millihz,
        NativeVideoCodec::try_from(selected_format.codec).ok()?,
        NativeChromaSubsampling::try_from(selected_format.chroma_subsampling).ok()?,
        selected_format.bit_depth,
        dynamic_range,
    )?;
    Some(AdaptiveVideoDeliveryController::new_with_quality_floor(
        plan.bitrate_kbps,
        plan.bitrate_kbps,
        initial_fec_percentage,
        plan.maximum_presentable_frames,
        quality_floor_encoder_kbps,
        plan.refresh_millihz,
        plan.maximum_datagram_payload,
    ))
}

fn native_error(request_id: u64, code: u32, message: impl Into<String>) -> HostControlEnvelope {
    HostControlEnvelope {
        request_id,
        payload: Some(host_control_envelope::Payload::Error(NativeProtocolError {
            code,
            message: message.into(),
            negotiation_failure: NativeNegotiationFailure::Unspecified as i32,
        })),
    }
}

fn display_reconfiguration_result(
    request_id: u64,
    session_epoch: u32,
    revision: u64,
    result: NativeDisplayReconfigurationResultCode,
    plan: HostSessionPlan,
    message: String,
) -> HostControlEnvelope {
    HostControlEnvelope {
        request_id,
        payload: Some(host_control_envelope::Payload::DisplayReconfiguration(
            DisplayReconfigurationResult {
                session_epoch,
                revision,
                result: result as i32,
                plan: Some(plan),
                message,
            },
        )),
    }
}

fn media_park_result(
    request_id: u64,
    session_epoch: u32,
    revision: u64,
    state: NativeMediaParkState,
    result: NativeMediaParkResultCode,
    message: impl Into<String>,
) -> HostControlEnvelope {
    HostControlEnvelope {
        request_id,
        payload: Some(host_control_envelope::Payload::MediaPark(MediaParkResult {
            session_epoch,
            revision,
            state: state as i32,
            result: result as i32,
            message: message.into(),
        })),
    }
}

fn reset_media_delivery(pending: &mut PendingNativeSession) -> Result<(), String> {
    let next_media_delivery_generation = pending
        .media_delivery_generation
        .checked_add(1)
        .ok_or_else(|| "media delivery generation exhausted".to_owned())?;
    if let Some(generation_id) = pending.acknowledged_generation_id {
        pending.retired_video_bootstrap_generation_watermark = pending
            .retired_video_bootstrap_generation_watermark
            .max(generation_id);
    }
    if let Some(bootstrap) = pending.video_bootstrap.take() {
        pending.retire_video_bootstrap(bootstrap);
    }
    pending.video_bootstrap_sent = false;
    pending.video_bootstrap_requires_encoder_resume = false;
    pending.video_bootstrap_retry_attempt = 0;
    pending.acknowledged_generation_id = None;
    pending.last_video_bootstrap_acknowledgement = None;
    pending.video_bootstrap_failure = None;
    pending.resume_bootstrap_revision = None;
    pending.resume_bootstrap_generation = None;
    pending.resume_bootstrap_deadline = None;
    pending.resume_idr_retry_attempt = 0;
    pending.repair_keyframe = RepairKeyframeState::Idle;
    pending.periodic_idr.reset();
    pending.last_sent_video_frame_id = 0;
    pending.pending_feedback_window = None;
    pending.media_delivery_generation = next_media_delivery_generation;
    pending.next_generation_id = pending
        .next_generation_id
        .checked_add(1)
        .ok_or_else(|| "media park generation exhausted".to_owned())?;
    if pending.acknowledged_configuration_id.is_none() {
        // A configuration that was sent but not acknowledged may be safely
        // retried after resume. An acknowledged record remains valid across a
        // park boundary and avoids a quality-changing renegotiation.
        pending.codec_configuration_sent = false;
    }
    Ok(())
}

fn native_negotiation_error(request_id: u64, error: NativeSessionError) -> HostControlEnvelope {
    HostControlEnvelope {
        request_id,
        payload: Some(host_control_envelope::Payload::Error(NativeProtocolError {
            code: ERROR_NEGOTIATION,
            message: error.message().to_owned(),
            negotiation_failure: NativeNegotiationFailure::from(error) as i32,
        })),
    }
}

#[cfg(test)]
mod periodic_idr_tests {
    use super::*;

    #[test]
    fn periodic_deadline_has_exact_999ms_and_1000ms_boundary() {
        let origin = Instant::now();
        let mut gate = PeriodicIdrGate::default();
        gate.schedule_after_generation_ack(origin);

        assert!(!gate.is_due(origin + Duration::from_millis(999)));
        assert!(gate.is_due(origin + Duration::from_secs(1)));
        assert!(gate.mark_requested(origin + Duration::from_secs(1)));
        assert!(!gate.mark_requested(origin + Duration::from_secs(1)));
    }

    #[test]
    fn periodic_ack_resets_deadline_and_retry_keeps_single_flight() {
        let origin = Instant::now();
        let mut gate = PeriodicIdrGate::default();
        gate.schedule_after_generation_ack(origin);
        let request_time = origin + PERIODIC_IDR_INTERVAL;
        assert!(gate.mark_requested(request_time));
        gate.mark_generation(7, 11);
        gate.update_retry_generation(7, 8);
        assert_eq!(
            gate.state,
            PeriodicIdrState::AwaitingDecodedBootstrap {
                generation_id: 8,
                frame_id: 11,
            }
        );
        gate.acknowledge(request_time + Duration::from_millis(3));
        assert!(!gate.is_due(request_time + Duration::from_millis(999)));
        assert!(gate.is_due(request_time + Duration::from_millis(1_003)));
    }

    #[test]
    fn natural_keyframe_fallback_does_not_rearm_or_duplicate_request() {
        let origin = Instant::now();
        let mut gate = PeriodicIdrGate::default();
        gate.schedule_after_generation_ack(origin);
        let due = origin + PERIODIC_IDR_INTERVAL;
        assert!(gate.mark_requested(due));
        assert!(!gate.mark_requested(due + Duration::from_millis(1)));
        gate.mark_generation(9, 17);
        assert!(gate.is_outstanding());
    }
}
