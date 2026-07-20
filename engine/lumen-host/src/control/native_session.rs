use lumen_engine::{
    client_control_envelope, host_control_envelope, negotiate_native_session,
    ClientControlEnvelope, ClientSessionHello, CodecConfiguration, CodecConfigurationAck,
    HostControlEnvelope, HostSessionCapabilities, HostSessionPlan, LumenSessionOffer,
    MediaFeedback, NativeChromaSubsampling, NativeColorRange, NativeDynamicRange,
    NativeNegotiationFailure, NativeProtocolError, NativeSessionError, NativeVideoBootstrapReason,
    NativeVideoBootstrapResultCode, NativeVideoCodec, NativeVideoKeyframeRequestReason,
    NativeVideoProfile, SessionStarted, SessionStopped, StartSessionAck, StopSession,
    VideoBootstrap, VideoBootstrapResult, VideoKeyframeRequest, NATIVE_VIDEO_STREAM_ID,
};

use super::{AudioDeliveryState, ControlRouter, InputMotionDeliveryState, VideoDeliveryState};
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NativeConnectionContext {
    pub(crate) session_epoch: u32,
    pub(crate) host_capabilities: HostSessionCapabilities,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeMediaFeedbackDisposition {
    AppliedVideo,
    AcceptedAudio,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeMediaFeedbackRejection {
    SessionUnavailable,
    SessionInactive,
    SessionEpochMismatch,
    StreamMismatch,
    WindowDurationMismatch,
    InvalidSequenceRange,
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
        }
    }
}

#[derive(Debug, Default)]
pub(super) struct NativeSessionState {
    pending: Option<PendingNativeSession>,
}

#[derive(Debug)]
struct PendingNativeSession {
    hello: ClientSessionHello,
    plan: HostSessionPlan,
    active: bool,
    application_started: bool,
    codec_configuration: Option<CodecConfiguration>,
    codec_configuration_sent: bool,
    acknowledged_configuration_id: Option<u32>,
    video_bootstrap: Option<VideoBootstrap>,
    video_bootstrap_sent: bool,
    acknowledged_generation_id: Option<u32>,
    video_bootstrap_failure: Option<String>,
    next_generation_id: u32,
    video_keyframe_request: Option<VideoKeyframeRequest>,
    last_sent_video_frame_id: u32,
    feedback_loss_ewma: f32,
    adaptive_fec_percentage: u16,
    target_bitrate_kbps: u32,
    admission_divisor: u8,
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
            None => vec![native_error(
                request_id,
                ERROR_INVALID_OPERATION,
                "native session operation is not valid in the current state",
            )],
        }
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
        if let Some(outstanding) = pending.video_keyframe_request.as_ref() {
            eprintln!(
                "Lumen native media stage=video-keyframe-request-coalesced session-epoch={} request-id={request_id} after-frame-id={} outstanding-after-frame-id={} reason={} outstanding-reason={}",
                request.session_epoch,
                request.after_frame_id,
                outstanding.after_frame_id,
                request.reason,
                outstanding.reason,
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
            .video_keyframe_request = Some(request.clone());
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
            pending.video_bootstrap_failure = Some(message.clone());
            return vec![native_error(request_id, ERROR_PLATFORM, message)];
        }
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
        pending.acknowledged_generation_id = Some(result.generation_id);
        pending.video_bootstrap = None;
        pending.video_bootstrap_sent = false;
        pending.video_keyframe_request = None;
        eprintln!(
            "Lumen native media stage=video-bootstrap-acknowledged session-epoch={} configuration-id={} generation-id={} frame-id={} request-id={request_id}",
            result.session_epoch, result.configuration_id, result.generation_id, result.frame_id
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
        if feedback.window_milliseconds != NATIVE_MEDIA_FEEDBACK_WINDOW_MILLISECONDS {
            return Err(NativeMediaFeedbackRejection::WindowDurationMismatch);
        }
        if feedback.first_datagram_sequence > feedback.highest_datagram_sequence {
            return Err(NativeMediaFeedbackRejection::InvalidSequenceRange);
        }
        if feedback.stream_id == pending.plan.audio_stream_id {
            return Ok(NativeMediaFeedbackDisposition::AcceptedAudio);
        }
        let total = feedback
            .received_datagrams
            .saturating_add(feedback.unrecoverable_objects)
            .saturating_add(feedback.late_objects);
        let loss = if total == 0 {
            0.0
        } else {
            (feedback
                .unrecoverable_objects
                .saturating_add(feedback.late_objects)) as f32
                / total as f32
        };
        pending.feedback_loss_ewma = pending.feedback_loss_ewma * 0.8 + loss * 0.2;
        let target = if pending.feedback_loss_ewma >= 0.10 {
            pending.adaptive_fec_percentage.saturating_add(5)
        } else if pending.feedback_loss_ewma <= 0.02 {
            pending.adaptive_fec_percentage.saturating_sub(5)
        } else {
            pending.adaptive_fec_percentage
        };
        pending.adaptive_fec_percentage = target.clamp(5, 50);
        let congested = pending.feedback_loss_ewma >= 0.10
            || feedback.late_objects > 0
            || feedback.decoder_queue_depth > pending.plan.maximum_presentable_frames
            || feedback.presentation_drops > 0;
        if congested {
            let floor = pending.plan.bitrate_kbps.div_ceil(4);
            pending.target_bitrate_kbps = pending
                .target_bitrate_kbps
                .saturating_mul(90)
                .div_ceil(100)
                .max(floor);
            pending.admission_divisor = 2;
        } else if pending.feedback_loss_ewma <= 0.02
            && feedback.decoder_queue_depth <= 1
            && feedback.presentation_drops == 0
        {
            let step = pending.plan.bitrate_kbps.div_ceil(20).max(1);
            pending.target_bitrate_kbps = pending
                .target_bitrate_kbps
                .saturating_add(step)
                .min(pending.plan.bitrate_kbps);
            pending.admission_divisor = 1;
        }
        Ok(NativeMediaFeedbackDisposition::AppliedVideo)
    }

    fn dispatch_native_start(
        &mut self,
        request_id: u64,
        start: StartSessionAck,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        let Some(pending) = self.native.pending.as_ref() else {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )];
        };
        if start.session_epoch != pending.plan.session_epoch
            || context.session_epoch != pending.plan.session_epoch
            || pending.active
        {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session cannot start in the current state",
            )];
        }
        let hello = pending.hello.clone();
        let plan = pending.plan.clone();
        let current_application_id = self.discovery.current_application_id();
        if (hello.resume && current_application_id != hello.application_id)
            || (!hello.resume && current_application_id != 0)
        {
            return vec![native_error(
                request_id,
                ERROR_SESSION_CONFLICT,
                "application state conflicts with the native session request",
            )];
        }
        let application = match self
            .authorities
            .applications()
            .launch_plan(hello.application_id)
        {
            Ok(application) => application,
            Err(_) => {
                return vec![native_error(
                    request_id,
                    ERROR_APPLICATION,
                    "application launch plan is unavailable",
                )]
            }
        };
        if self
            .authorities
            .settings_mut()
            .mark_next_session_started()
            .is_err()
        {
            return vec![native_error(
                request_id,
                ERROR_APPLICATION,
                "next-session settings could not be applied",
            )];
        }
        let application_plan =
            match self.native_application_plan(&hello, &plan, application.clone()) {
                Ok(plan) => plan,
                Err(_) => {
                    return vec![native_error(
                        request_id,
                        ERROR_NEGOTIATION,
                        "native application plan is invalid",
                    )]
                }
            };
        let session_plan = match native_platform_session_plan(&hello, &plan) {
            Ok(plan) => plan,
            Err(_) => {
                return vec![native_error(
                    request_id,
                    ERROR_NEGOTIATION,
                    "native platform session plan is invalid",
                )]
            }
        };
        let application_started = !hello.resume;
        if application_started {
            if let Err(error) = self.platform.start_application(application_plan) {
                let message = format!("platform application could not be started: {error}");
                self.publish_native_platform_error(message.clone());
                return vec![native_error(request_id, ERROR_PLATFORM, message)];
            }
        }
        if let Err(error) = self.platform.start_session(session_plan) {
            let message = format!("platform stream session could not be started: {error}");
            return vec![native_error(
                request_id,
                ERROR_PLATFORM,
                self.rollback_native_start(application_started, message),
            )];
        }
        let _ = self.platform.publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Cleared,
            severity: PlatformRuntimeEventSeverity::Error,
            code: PlatformRuntimeEventCode::NativeSessionPlatform,
            message: None,
        });
        self.discovery
            .set_running_application(application.id, application.uuid);
        if let Some(pending) = self.native.pending.as_mut() {
            pending.active = true;
            pending.application_started = application_started;
        }
        vec![HostControlEnvelope {
            request_id,
            payload: Some(host_control_envelope::Payload::SessionStarted(
                SessionStarted {
                    session_epoch: plan.session_epoch,
                },
            )),
        }]
    }

    fn rollback_native_start(&mut self, application_started: bool, message: String) -> String {
        let session_error = self.platform.stop_session().err();
        if application_started {
            let _ = self.platform.stop_application();
        }
        self.native.pending = None;
        let message = match session_error {
            Some(error) => format!("{message}; platform session rollback failed: {error}"),
            None => message,
        };
        self.publish_native_platform_error(message.clone());
        message
    }

    pub(crate) fn terminate_native_connection(&mut self, session_epoch: u32) -> Result<(), String> {
        let Some(pending) = self.native.pending.as_ref() else {
            return Ok(());
        };
        if pending.plan.session_epoch != session_epoch {
            return Ok(());
        }
        let active = pending.active;
        let application_started = pending.application_started;
        let session_error = active
            .then(|| self.platform.stop_session())
            .and_then(Result::err);
        let application_error = application_started
            .then(|| self.platform.stop_application())
            .and_then(Result::err);
        if application_started {
            self.discovery.clear_running_application();
        }
        self.native.pending = None;
        match (session_error, application_error) {
            (None, None) => Ok(()),
            (session, application) => Err(format!(
                "native connection cleanup failed: session={} application={}",
                session.as_deref().unwrap_or("ok"),
                application.as_deref().unwrap_or("ok")
            )),
        }
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
        let active = pending.active;
        let application_started = pending.application_started;
        let session_error = active
            .then(|| self.platform.stop_session())
            .and_then(Result::err);
        let application_error = application_started
            .then(|| self.platform.stop_application())
            .and_then(Result::err);
        if application_started {
            self.discovery.clear_running_application();
        }
        self.native.pending = None;
        if session_error.is_some() || application_error.is_some() {
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

    fn dispatch_native_hello(
        &mut self,
        request_id: u64,
        hello: ClientSessionHello,
        context: &NativeConnectionContext,
    ) -> Vec<HostControlEnvelope> {
        if self.native.pending.is_some() {
            return vec![native_error(
                request_id,
                ERROR_SESSION_CONFLICT,
                "a native session is already pending",
            )];
        }
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
            application_started: false,
            codec_configuration: None,
            codec_configuration_sent: false,
            acknowledged_configuration_id: None,
            video_bootstrap: None,
            video_bootstrap_sent: false,
            acknowledged_generation_id: None,
            video_bootstrap_failure: None,
            next_generation_id: 1,
            video_keyframe_request: None,
            last_sent_video_frame_id: 0,
            feedback_loss_ewma: 0.0,
            adaptive_fec_percentage: self
                .authorities
                .settings()
                .snapshot()
                .effective
                .network
                .fec_percentage
                .clamp(5, 50),
            target_bitrate_kbps: plan.bitrate_kbps,
            admission_divisor: 1,
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

    pub(crate) fn publish_native_codec_configuration(
        &mut self,
        configuration: CodecConfiguration,
    ) -> bool {
        {
            let Some(pending) = self.native.pending.as_mut() else {
                return false;
            };
            if !pending.active
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
        }
        self.codec_configuration_notify.notify_one();
        true
    }

    pub(crate) fn take_native_codec_configuration(
        &mut self,
        session_epoch: u32,
    ) -> Option<CodecConfiguration> {
        let pending = self.native.pending.as_mut()?;
        if pending.plan.session_epoch != session_epoch || pending.codec_configuration_sent {
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

    pub(crate) fn publish_native_video_bootstrap(
        &mut self,
        configuration_id: u32,
        frame_id: u32,
        capture_timestamp_us: u32,
        reason: NativeVideoBootstrapReason,
        access_unit: Vec<u8>,
    ) -> Option<u32> {
        let pending = self.native.pending.as_mut()?;
        if !pending.active
            || pending.acknowledged_configuration_id != Some(configuration_id)
            || frame_id == 0
            || access_unit.is_empty()
            || reason == NativeVideoBootstrapReason::Unspecified
        {
            return None;
        }
        let generation_id = pending.next_generation_id;
        pending.next_generation_id = generation_id.checked_add(1)?;
        pending.acknowledged_generation_id = None;
        pending.video_bootstrap_failure = None;
        let reason = if pending.video_keyframe_request.is_some() {
            NativeVideoBootstrapReason::Repair
        } else {
            reason
        };
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
        pending.video_bootstrap_sent = false;
        self.video_bootstrap_notify.notify_one();
        Some(generation_id)
    }

    pub(crate) fn take_native_video_bootstrap(
        &mut self,
        session_epoch: u32,
    ) -> Option<VideoBootstrap> {
        let pending = self.native.pending.as_mut()?;
        if pending.plan.session_epoch != session_epoch || pending.video_bootstrap_sent {
            return None;
        }
        let bootstrap = pending.video_bootstrap.clone()?;
        pending.video_bootstrap_sent = true;
        Some(bootstrap)
    }

    pub(crate) fn native_video_bootstrap_is_acknowledged(
        &self,
        session_epoch: u32,
        generation_id: u32,
    ) -> bool {
        self.native.pending.as_ref().is_some_and(|pending| {
            pending.active
                && pending.plan.session_epoch == session_epoch
                && pending.acknowledged_generation_id == Some(generation_id)
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
            .is_some_and(|pending| pending.video_keyframe_request.is_some())
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
        Some(VideoDeliveryState {
            video_format: platform_video_format(&pending.plan)?,
            acknowledged_configuration_id: pending.acknowledged_configuration_id,
            acknowledged_generation_id: pending.acknowledged_generation_id,
            session_epoch: pending.plan.session_epoch,
            policy_revision: u16::try_from(pending.plan.policy_revision).ok()?,
            maximum_datagram_payload: usize::try_from(pending.plan.maximum_datagram_payload)
                .ok()?,
            maximum_object_delay_us: pending.plan.maximum_object_delay_us,
            fec_percentage: pending.adaptive_fec_percentage,
            target_bitrate_kbps: pending.target_bitrate_kbps,
            admission_divisor: pending.admission_divisor,
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
        })
    }

    pub(super) fn take_native_cleanup_state(&mut self) -> (bool, bool) {
        self.native
            .pending
            .take()
            .map(|pending| (pending.active, pending.application_started))
            .unwrap_or_default()
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

fn native_platform_session_plan(
    hello: &ClientSessionHello,
    plan: &HostSessionPlan,
) -> Result<PlatformSessionPlan, String> {
    let video_format =
        platform_video_format(plan).ok_or_else(|| "native video format is invalid".to_owned())?;
    Ok(PlatformSessionPlan {
        width: plan.encoded_width,
        height: plan.encoded_height,
        frames_per_second: refresh_millihz_to_frames_per_second(plan.refresh_millihz)?,
        bitrate_kbps: plan.bitrate_kbps,
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
