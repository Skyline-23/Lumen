const INPUT: &str = include_str!("../src/platform/windows/native_input.rs");
const MEDIA: &str = include_str!("../src/platform/windows/native_media.rs");
const VIDEO: &str = concat!(
    include_str!("../src/platform/windows/native_video.rs"),
    include_str!("../src/platform/windows/native_video_cadence.rs"),
    include_str!("../src/platform/windows/native_video_encoder.rs"),
    include_str!("../src/platform/windows/native_video_worker.rs"),
);
const CAPTURE: &str = include_str!("../src/platform/windows/native_capture.rs");

#[test]
fn windows_adaptive_delivery_policy_reaches_the_active_media_foundation_encoder() {
    let dispatch = INPUT
        .split("fn handle_control_event")
        .nth(1)
        .expect("Windows platform control dispatcher");

    assert!(!dispatch.contains("PlatformControlEvent::SetVideoDeliveryPolicy { .. } => Ok(())"));
    assert!(dispatch.contains("set_video_delivery_policy"));
    assert!(MEDIA.contains("pub(super) fn set_video_delivery_policy"));
    let policy = MEDIA
        .split("pub(super) fn set_video_delivery_policy")
        .nth(1)
        .unwrap();
    let policy = policy.split("pub(super) fn").next().unwrap();
    assert!(policy.contains("require_running_session_epoch(session_epoch)?"));
    assert!(!policy.contains("let lifecycle = self.running_session()?"));
    assert!(
        policy.find("require_running_session_epoch").unwrap()
            < policy
                .find("media_foundation.set_video_delivery_policy")
                .unwrap()
    );
    assert!(VIDEO.contains("NativeMediaFoundationCommand::SetBitrate"));
    assert!(VIDEO.contains("CODECAPI_AVEncCommonMeanBitRate"));
    assert!(VIDEO.contains("VariantClear(value)"));
    assert!(VIDEO.contains("CoTaskVariantArray"));
    let clear = VIDEO.find("VariantClear(value)").unwrap();
    let free = VIDEO
        .find("CoTaskMemFree(Some(self.values.cast()))")
        .unwrap();
    assert!(
        clear < free,
        "every COM VARIANT must be cleared before array storage is freed"
    );
    assert!(VIDEO.contains("admission_divisor"));
    assert!(VIDEO.contains("admissions_until_next"));
    assert!(VIDEO.contains("take_video_timestamp"));
}

#[test]
fn windows_bitrate_updates_are_fenced_by_the_active_session_epoch() {
    assert!(VIDEO.contains("session_epoch"));
    assert!(VIDEO.contains("received session epoch"));
    assert!(VIDEO.contains("active session epoch"));
    assert!(VIDEO.contains("AbandonableSessionSlot<NativeMediaFoundationSession>"));
    assert!(VIDEO.contains("run_media_foundation_session"));
    assert!(!VIDEO.contains("NativeMediaFoundationCommand::StopSession"));

    let stop = VIDEO
        .split("pub(super) fn stop_encoder")
        .nth(1)
        .unwrap()
        .split("pub(super) fn")
        .next()
        .unwrap();
    assert!(stop.contains("self.sessions.try_retire(|session|"));
    assert!(!stop.contains("self.request("));
    let verified_stop = ".retire_with(|| driver.stop_frame_delivery())?";
    assert!(stop.contains(verified_stop));
    assert!(stop.contains("control.take()"));
    assert!(stop.find(verified_stop).unwrap() < stop.find("control.take()").unwrap());
    assert!(VIDEO.contains("RetiredWorkerRegistry"));
    assert!(VIDEO.contains("MAXIMUM_RETIRED_MEDIA_FOUNDATION_WORKERS"));
    assert!(VIDEO.contains("self.retired_workers.ensure_capacity()"));
    assert!(VIDEO.contains("FrameDeliveryOwnership"));
    assert!(CAPTURE.contains(".start_with(|| driver.start_frame_delivery())?"));
    assert!(CAPTURE.contains(".pause_with(|| self.driver.stop_frame_delivery())"));
    assert!(!CAPTURE.contains("let _ = self.driver.stop_frame_delivery()"));
    let capture_drop = CAPTURE
        .split("impl Drop for NativeIddCxCapture")
        .nth(1)
        .unwrap()
        .split("impl NativeEncoderSurface")
        .next()
        .unwrap();
    assert!(capture_drop.contains(".frame_delivery"));
    assert!(capture_drop.contains(".pause_with(|| self.driver.stop_frame_delivery())"));
    assert!(MEDIA.contains("video_session_epoch"));
    assert!(MEDIA.contains("state.video_session_epoch != Some(session_epoch)"));
    assert!(!MEDIA.contains("let session_epoch = lifecycle.session_epoch.take()"));
}

#[test]
fn windows_capture_uses_shared_cadence_policy_and_vfr_capture_timestamps() {
    assert!(VIDEO.contains("LumenAdaptiveFrameCadenceController"));
    assert!(VIDEO.contains("LumenAdaptiveFrameCadenceObservation"));
    assert!(VIDEO.contains("effective_target_frame_rate"));
    assert!(VIDEO.contains("capture_timestamp_hns"));
    assert!(VIDEO.contains("capture_timestamp_step_is_forward"));
    assert!(VIDEO.contains("last_source_timestamp_90khz"));
    assert!(VIDEO.contains("unwrapped_source_timestamp_90khz"));
    assert!(VIDEO.contains("MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS"));
    assert!(VIDEO.contains("admitted_timestamp_and_duration"));
    assert!(VIDEO.contains("pending_drop_count"));
    assert!(VIDEO.contains("record_sink_result"));

    let encode = VIDEO
        .split("fn encode_next(")
        .nth(1)
        .expect("Windows adaptive encode loop")
        .split("fn source_timestamp_hns")
        .next()
        .unwrap();
    assert!(encode.contains("cadence_admission.admits"));
    assert!(encode.contains("observe_unchanged_content_cadence"));
    assert!(encode.contains("content_signal"));
    assert!(
        encode.find("cadence_admission.admits").unwrap()
            < encode.find("self.capture.convert_frame").unwrap()
    );
    assert!(!encode.contains("take_admitted_video_timestamp"));

    assert!(CAPTURE.contains("presentation_time_90khz: record.presentation_time_90khz"));
    assert!(MEDIA.contains("pending_drop_count: result.dropped_frames"));
}
