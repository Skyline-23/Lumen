use lumen_engine::{
    client_control_envelope, host_control_envelope, minimum_video_encoder_bitrate_kbps,
    negotiate_native_session, ClientControlEnvelope, ClientSessionHello, CodecConfiguration,
    CodecConfigurationAck, DisplayReconfigurationRequest, DisplayReconfigurationResult,
    HostControlEnvelope, HostSessionCapabilities, HostSessionPlan, LumenSessionOffer,
    MediaFeedback, NativeChromaSubsampling, NativeColorRange,
    NativeDisplayReconfigurationResultCode, NativeDynamicRange, NativeNegotiationFailure,
    NativeProtocolError, NativeSessionError, NativeVideoBootstrapReason,
    NativeVideoBootstrapResultCode, NativeVideoCodec, NativeVideoKeyframeRequestReason,
    NativeVideoProfile, SessionStarted, SessionStopped, StartSessionAck, StopSession,
    VideoBootstrap, VideoBootstrapResult, VideoKeyframeRequest, NATIVE_VIDEO_STREAM_ID,
};

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
    policy_revision: u64,
    controller: AdaptiveVideoDeliveryController,
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
}

#[derive(Debug)]
struct PendingNativeSession {
    hello: ClientSessionHello,
    plan: HostSessionPlan,
    active: bool,
    session_cleanup_pending: bool,
    application_started: bool,
    codec_configuration: Option<CodecConfiguration>,
    codec_configuration_sent: bool,
    acknowledged_configuration_id: Option<u32>,
    video_bootstrap: Option<VideoBootstrap>,
    video_bootstrap_sent: bool,
    video_bootstrap_requires_encoder_resume: bool,
    acknowledged_generation_id: Option<u32>,
    video_bootstrap_failure: Option<String>,
    last_video_bootstrap_acknowledgement: Option<VideoBootstrapResult>,
    next_generation_id: u32,
    repair_keyframe: RepairKeyframeState,
    last_sent_video_frame_id: u32,
    last_display_revision: u64,
    adaptive_video: AdaptiveVideoDeliveryController,
    adaptive_policy_lane: AdaptiveVideoPolicyLane,
    next_feedback_window_id: u64,
    pending_feedback_window: Option<PendingMediaFeedbackWindow>,
}

#[derive(Debug, Default)]
struct AdaptiveVideoPolicyLane {
    revision: u64,
    applying_revision: Option<u64>,
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
        let Some(pending) = self.native.pending.as_ref() else {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "native session has not been negotiated",
            )];
        };
        if !pending.active
            || request.session_epoch != pending.plan.session_epoch
            || context.session_epoch != pending.plan.session_epoch
            || request.revision == 0
        {
            return vec![native_error(
                request_id,
                ERROR_SESSION_STATE,
                "display reconfiguration does not belong to the active session",
            )];
        }
        if request.revision <= pending.last_display_revision {
            return vec![display_reconfiguration_result(
                request_id,
                request.session_epoch,
                request.revision,
                NativeDisplayReconfigurationResultCode::Superseded,
                pending.plan.clone(),
                "a newer display reconfiguration revision is already active".to_owned(),
            )];
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
                return vec![display_reconfiguration_result(
                    request_id,
                    request.session_epoch,
                    request.revision,
                    NativeDisplayReconfigurationResultCode::Rejected,
                    pending.plan.clone(),
                    error.message().to_owned(),
                )]
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
                return vec![display_reconfiguration_result(
                    request_id,
                    request.session_epoch,
                    request.revision,
                    NativeDisplayReconfigurationResultCode::Rejected,
                    pending.plan.clone(),
                    format!("dynamic platform session plan is invalid: {error}"),
                )]
            }
        };
        if let Err(error) = self.platform.reconfigure_session(platform_plan) {
            return vec![display_reconfiguration_result(
                request_id,
                request.session_epoch,
                request.revision,
                NativeDisplayReconfigurationResultCode::Rejected,
                pending.plan.clone(),
                error,
            )];
        }
        let pending = self
            .native
            .pending
            .as_mut()
            .expect("validated pending native session");
        pending.hello = hello;
        pending.plan = plan.clone();
        pending.codec_configuration = None;
        pending.codec_configuration_sent = false;
        pending.acknowledged_configuration_id = None;
        pending.video_bootstrap = None;
        pending.video_bootstrap_sent = false;
        pending.video_bootstrap_requires_encoder_resume = false;
        pending.acknowledged_generation_id = None;
        pending.repair_keyframe = RepairKeyframeState::Idle;
        pending.adaptive_video = adaptive_video;
        pending.adaptive_policy_lane.revision =
            pending.adaptive_policy_lane.revision.wrapping_add(1);
        pending.last_display_revision = request.revision;
        vec![display_reconfiguration_result(
            request_id,
            request.session_epoch,
            request.revision,
            NativeDisplayReconfigurationResultCode::Applied,
            plan,
            String::new(),
        )]
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
        let base = pending.adaptive_video.snapshot();
        let mut controller = pending.adaptive_video.clone();
        let decision = controller.observe_window(video, audio, clean_window_units);
        Ok(if decision.changed {
            NativeMediaFeedbackDisposition::Applied(AdaptiveVideoProposal {
                base,
                decision,
                policy_revision: pending.adaptive_policy_lane.revision,
                controller,
            })
        } else {
            NativeMediaFeedbackDisposition::Unchanged
        })
    }

    #[cfg(test)]
    pub(crate) fn commit_native_adaptive_video(
        &mut self,
        session_epoch: u32,
        proposal: AdaptiveVideoProposal,
    ) -> bool {
        let Some(pending) = self.native.pending.as_mut() else {
            return false;
        };
        if !pending.active
            || pending.plan.session_epoch != session_epoch
            || pending.adaptive_policy_lane.applying_revision.is_some()
            || pending.adaptive_policy_lane.revision != proposal.policy_revision
            || pending.adaptive_video.snapshot() != proposal.base
        {
            return false;
        }
        pending.adaptive_video = proposal.controller;
        pending.adaptive_policy_lane.revision =
            pending.adaptive_policy_lane.revision.wrapping_add(1);
        true
    }

    pub(crate) fn begin_native_adaptive_video_policy_apply(
        &mut self,
        session_epoch: u32,
        proposal: &AdaptiveVideoProposal,
    ) -> bool {
        let Some(pending) = self.native.pending.as_mut() else {
            return false;
        };
        if !pending.active
            || pending.plan.session_epoch != session_epoch
            || pending.adaptive_policy_lane.applying_revision.is_some()
            || pending.adaptive_policy_lane.revision != proposal.policy_revision
            || pending.adaptive_video.snapshot() != proposal.base
        {
            return false;
        }
        pending.adaptive_policy_lane.applying_revision = Some(proposal.policy_revision);
        true
    }

    pub(crate) fn finish_native_adaptive_video_policy_apply(
        &mut self,
        session_epoch: u32,
        proposal: AdaptiveVideoProposal,
        applied: bool,
    ) -> bool {
        let Some(pending) = self.native.pending.as_mut() else {
            return false;
        };
        if !pending.active
            || pending.plan.session_epoch != session_epoch
            || pending.adaptive_policy_lane.applying_revision != Some(proposal.policy_revision)
        {
            return false;
        }
        pending.adaptive_policy_lane.applying_revision = None;
        if pending.adaptive_policy_lane.revision != proposal.policy_revision
            || pending.adaptive_video.snapshot() != proposal.base
        {
            return false;
        }
        if applied {
            pending.adaptive_video = proposal.controller;
            pending.adaptive_policy_lane.revision =
                pending.adaptive_policy_lane.revision.wrapping_add(1);
        }
        true
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
        if pending.repair_keyframe.is_active() || pending.video_bootstrap.is_some() {
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
        let encoder_bitrate_kbps = pending.adaptive_video.snapshot().encoder_bitrate_kbps;
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
        let session_plan = match native_platform_session_plan(&hello, &plan, encoder_bitrate_kbps) {
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
            if let Some(pending) = self.native.pending.as_mut() {
                pending.application_started = true;
            }
        }
        if let Some(pending) = self.native.pending.as_mut() {
            pending.session_cleanup_pending = true;
        }
        if let Err(error) = self.platform.start_session(session_plan) {
            let message = format!("platform stream session could not be started: {error}");
            return vec![native_error(
                request_id,
                ERROR_PLATFORM,
                self.rollback_native_start(message),
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

    fn rollback_native_start(&mut self, message: String) -> String {
        let session_epoch = self
            .native
            .pending
            .as_ref()
            .map(|pending| pending.plan.session_epoch);
        let message = match session_epoch
            .map(|session_epoch| self.cleanup_native_session(session_epoch))
            .transpose()
        {
            Ok(_) => message,
            Err(error) => format!("{message}; platform session rollback failed: {error}"),
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
        let session_cleanup_pending = pending.session_cleanup_pending;
        let application_started = pending.application_started;
        if let Some(pending) = self.native.pending.as_mut() {
            pending.active = false;
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
            session_cleanup_pending: false,
            application_started: false,
            codec_configuration: None,
            codec_configuration_sent: false,
            acknowledged_configuration_id: None,
            video_bootstrap: None,
            video_bootstrap_sent: false,
            video_bootstrap_requires_encoder_resume: false,
            acknowledged_generation_id: None,
            video_bootstrap_failure: None,
            last_video_bootstrap_acknowledgement: None,
            next_generation_id: 1,
            repair_keyframe: RepairKeyframeState::Idle,
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
        requires_encoder_resume: bool,
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
        if reason == NativeVideoBootstrapReason::Repair
            && (!requires_encoder_resume
                || matches!(
                    pending.repair_keyframe,
                    RepairKeyframeState::AwaitingDecodedBootstrap { .. }
                ))
        {
            return None;
        }
        let generation_id = pending.next_generation_id;
        pending.next_generation_id = generation_id.checked_add(1)?;
        pending.acknowledged_generation_id = None;
        pending.video_bootstrap_failure = None;
        pending.video_bootstrap_requires_encoder_resume = requires_encoder_resume;
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
