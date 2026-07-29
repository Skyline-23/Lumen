const INPUT: &str = include_str!("../src/platform/windows/native_input.rs");
const MEDIA: &str = include_str!("../src/platform/windows/native_media.rs");
const VIDEO: &str = include_str!("../src/platform/windows/native_video.rs");

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
}
