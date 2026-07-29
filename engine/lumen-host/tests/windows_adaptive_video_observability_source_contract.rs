const LIB: &str = include_str!("../src/lib.rs");
const ENTRY: &str = include_str!("../src/entry.rs");
const SERVICE: &str = include_str!("../src/windows_service.rs");
const SERVICE_LOG: &str = include_str!("../src/windows_service_log.rs");
const SESSION_SLOT: &str = include_str!("../src/platform/session_slot.rs");
const MEDIA: &str = include_str!("../src/platform/windows/native_media.rs");
const VIDEO: &str = include_str!("../src/platform/windows/native_video.rs");

#[test]
fn windows_adaptive_apply_uses_the_persistent_service_event_log() {
    assert!(LIB.contains("mod windows_service_log;"));
    assert!(ENTRY.contains("windows_service_log::program_data_lumen_path"));
    assert!(SERVICE.contains("windows_service_log::program_data_lumen_path"));
    assert!(MEDIA.contains("WindowsServiceEventLog::from_program_data()?"));
    assert!(VIDEO.contains("WindowsAdaptiveVideoApplyEvent"));
    assert!(SERVICE_LOG.contains("OpenOptions::new()"));
    assert!(SERVICE_LOG.contains(".append(true)"));
    assert!(SERVICE_LOG.contains("file.sync_data()"));
    assert!(SERVICE_LOG.contains("requested_bitrate_bps"));
    assert!(SERVICE_LOG.contains("applied_bitrate_bps"));
    assert!(SERVICE_LOG.contains("encoder_epoch"));
    assert!(!SERVICE_LOG.contains("client_address"));
}

#[test]
fn windows_adaptive_apply_is_committed_after_readback_and_before_retirement() {
    let encoder_apply = VIDEO
        .split("fn set_bitrate")
        .nth(1)
        .expect("Media Foundation bitrate apply");
    let encoder_apply = encoder_apply
        .split("fn validate_bitrate_parameter")
        .next()
        .unwrap();
    assert!(encoder_apply.contains("IsSupported"));
    assert!(encoder_apply.contains("IsModifiable"));
    assert!(encoder_apply.contains("SetValue"));
    assert!(encoder_apply.contains("GetValue"));
    assert!(encoder_apply.contains("Ok(applied)"));

    let runtime = VIDEO
        .split("impl NativeVideoRuntime")
        .nth(1)
        .expect("native video runtime implementation");
    let policy = runtime
        .split("fn set_video_delivery_policy")
        .nth(1)
        .expect("active runtime adaptive policy");
    let policy = policy.split("fn request_repair_key_frame").next().unwrap();
    let apply = policy.find("self.encoder.set_bitrate").unwrap();
    let commit = policy.find("commit_if_active").unwrap();
    assert!(apply < commit);
    assert!(policy.contains("WindowsAdaptiveVideoApplyEvent::now"));
    assert!(policy.contains("bitrate_bps"));
    assert!(policy.contains("applied_bitrate_bps"));

    assert!(SESSION_SLOT.contains("struct SessionRetirementGate"));
    assert!(SESSION_SLOT.contains("fn commit_if_active"));
    assert!(SESSION_SLOT.contains("fn retire"));
}
