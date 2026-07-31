use std::sync::Arc;

use super::SharedControlRouter;
use crate::control::{AdaptiveVideoProposal, NativeAdaptiveVideoPolicyRequest};
use crate::{
    PlatformControlEvent, PlatformRuntimeEvent, PlatformRuntimeEventCode,
    PlatformRuntimeEventDisposition, PlatformRuntimeEventSeverity, PlatformSessionControl,
};

pub(super) async fn apply_adaptive_video_policy_request(
    router: &SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
    session_epoch: u32,
    request: NativeAdaptiveVideoPolicyRequest,
) -> Result<(), String> {
    let NativeAdaptiveVideoPolicyRequest::Applied(proposal) = request else {
        return Ok(());
    };
    apply_reserved_adaptive_video_policy(router, platform, session_epoch, proposal).await
}

pub(super) async fn apply_reserved_adaptive_video_policy(
    router: &SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
    session_epoch: u32,
    proposal: AdaptiveVideoProposal,
) -> Result<(), String> {
    let mut next = Some(proposal);
    let mut publication_error = None;
    while let Some(proposal) = next.take() {
        let decision = proposal.decision;
        let transaction_platform = Arc::clone(&platform);
        let platform_worker = tokio::task::spawn_blocking(move || {
            transaction_platform.handle_control_event(
                session_epoch,
                PlatformControlEvent::SetVideoDeliveryPolicy {
                    policy_revision: proposal.platform_policy_revision,
                    bitrate_kbps: decision.encoder_bitrate_kbps,
                    admission_divisor: decision.admission_divisor,
                },
            )
        })
        .await;
        let platform_result = match platform_worker {
            Ok(result) => result,
            Err(error) => {
                router
                    .lock()
                    .map_err(|_| "native control router lock is poisoned".to_owned())?
                    .finish_native_adaptive_video_policy_apply(session_epoch, proposal, false);
                return Err(format!("adaptive video transaction worker failed: {error}"));
            }
        };
        let applied = platform_result.is_ok();
        let completion = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .finish_native_adaptive_video_policy_apply(session_epoch, proposal, applied);
        if !completion.active {
            return publication_error.map_or(Ok(()), Err);
        }
        if let Err(error) = platform_result {
            if let Err(error) =
                publish_adaptive_video_rejection(&platform, session_epoch, decision, error)
            {
                publication_error.get_or_insert(error);
            }
        } else if completion.committed {
            if let Err(error) = clear_adaptive_video_warning(&platform) {
                publication_error.get_or_insert(error);
            }
            eprintln!(
                "Lumen native media stage=adaptive-video-applied session-epoch={session_epoch} wire-budget-kbps={} encoder-bitrate-kbps={} fec-percentage={} admission-divisor={} congestion-source={:?}",
                decision.wire_budget_kbps,
                decision.encoder_bitrate_kbps,
                decision.fec_percentage,
                decision.admission_divisor,
                decision.congestion_source,
            );
        }
        next = completion.follow_up;
    }
    publication_error.map_or(Ok(()), Err)
}

fn clear_adaptive_video_warning(platform: &Arc<dyn PlatformSessionControl>) -> Result<(), String> {
    platform
        .publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Cleared,
            severity: PlatformRuntimeEventSeverity::Warning,
            code: PlatformRuntimeEventCode::NativeVideoAdaptiveControl,
            message: None,
        })
        .map_err(|error| format!("adaptive video warning clear failed: {error}"))
}

fn publish_adaptive_video_rejection(
    platform: &Arc<dyn PlatformSessionControl>,
    session_epoch: u32,
    decision: crate::control::AdaptiveVideoDecision,
    error: String,
) -> Result<(), String> {
    let message = format!("adaptive video delivery policy rejected: {error}");
    platform
        .publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Warning,
            code: PlatformRuntimeEventCode::NativeVideoAdaptiveControl,
            message: Some(message.clone()),
        })
        .map_err(|publish_error| {
            format!("{message}; runtime warning publication failed: {publish_error}")
        })?;
    eprintln!(
        "Lumen native media stage=adaptive-video-rejected session-epoch={session_epoch} encoder-bitrate-kbps={} admission-divisor={} error={error}",
        decision.encoder_bitrate_kbps,
        decision.admission_divisor,
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use lumen_engine::MediaFeedback;

    use super::*;
    use crate::control::tests::started_native_router;
    use crate::control::NativeMediaFeedbackDisposition;
    use crate::PlatformSessionPlan;

    struct PanickingAdaptivePlatform;

    impl PlatformSessionControl for PanickingAdaptivePlatform {
        fn start_session(&self, _: PlatformSessionPlan) -> Result<(), String> {
            Ok(())
        }

        fn stop_session(&self) -> Result<(), String> {
            Ok(())
        }

        fn handle_control_event(&self, _: u32, event: PlatformControlEvent) -> Result<(), String> {
            if matches!(event, PlatformControlEvent::SetVideoDeliveryPolicy { .. }) {
                panic!("adaptive policy worker panic");
            }
            Ok(())
        }
    }

    #[tokio::test]
    async fn join_failure_preserves_deferred_keyframe_floor() {
        let platform: Arc<dyn PlatformSessionControl> = Arc::new(PanickingAdaptivePlatform);
        let (_root, mut router, context, plan) = started_native_router(Arc::clone(&platform));
        let ceiling_wire_kbps = router.video_delivery_state().unwrap().wire_budget_kbps;
        let video = MediaFeedback {
            stream_id: plan.video_stream_id,
            received_datagrams: 50,
            first_datagram_sequence: 1,
            highest_datagram_sequence: 100,
            window_milliseconds: 250,
            feedback_window_id: 1,
            ..MediaFeedback::default()
        };
        let audio = MediaFeedback {
            stream_id: plan.audio_stream_id,
            received_datagrams: 1,
            first_datagram_sequence: 1,
            highest_datagram_sequence: 1,
            window_milliseconds: 250,
            feedback_window_id: 1,
            ..MediaFeedback::default()
        };
        assert!(matches!(
            router
                .observe_native_media_feedback(&video, context.session_epoch)
                .unwrap(),
            NativeMediaFeedbackDisposition::AwaitingPair { .. }
        ));
        let NativeMediaFeedbackDisposition::Applied(proposal) = router
            .observe_native_media_feedback(&audio, context.session_epoch)
            .unwrap()
        else {
            panic!("loss feedback must reserve an adaptive proposal");
        };
        assert_eq!(
            router
                .require_native_video_keyframe_wire_rate(context.session_epoch, u32::MAX)
                .unwrap(),
            NativeAdaptiveVideoPolicyRequest::Deferred
        );
        let router = Arc::new(Mutex::new(router));

        let error = apply_reserved_adaptive_video_policy(
            &router,
            platform,
            context.session_epoch,
            proposal,
        )
        .await
        .unwrap_err();
        assert!(error.contains("adaptive video transaction worker failed"));

        let mut router = router.lock().unwrap();
        let NativeAdaptiveVideoPolicyRequest::Applied(retry) = router
            .require_native_video_keyframe_wire_rate(context.session_epoch, 1)
            .unwrap()
        else {
            panic!("the deferred keyframe floor must reserve the next policy");
        };
        assert_eq!(retry.decision.wire_budget_kbps, ceiling_wire_kbps);
        assert!(
            router
                .finish_native_adaptive_video_policy_apply(context.session_epoch, retry, false,)
                .active
        );
    }
}
