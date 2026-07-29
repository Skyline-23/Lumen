const LIB: &str = include_str!("../src/lib.rs");
const ENTRY: &str = include_str!("../src/entry.rs");
const SERVICE: &str = include_str!("../src/windows_service.rs");
const SERVICE_LOG: &str = include_str!("../src/windows_service_log.rs");
const SESSION_SLOT: &str = include_str!("../src/platform/session_slot.rs");
const MEDIA: &str = include_str!("../src/platform/windows/native_media.rs");
const VIDEO: &str = include_str!("../src/platform/windows/native_video.rs");
const WINDOWS_PACKAGE: &str = include_str!("../../../packaging/windows/Package.wxs");

#[test]
fn windows_adaptive_apply_uses_the_persistent_service_event_log() {
    assert!(LIB.contains("mod windows_service_log;"));
    assert!(ENTRY.contains("windows_service_log::program_data_lumen_path"));
    assert!(SERVICE.contains("windows_service_log::program_data_lumen_path"));
    assert!(MEDIA.contains("WindowsServiceEventLane::from_program_data()?"));
    assert!(MEDIA.contains("adaptive_event_lane.publisher()"));
    assert!(MEDIA.contains("adaptive_event_lane.shutdown()"));
    assert!(VIDEO.contains("WindowsAdaptiveVideoApplyEvent"));
    assert!(VIDEO.contains("WindowsServiceEventPublisher"));
    assert!(SERVICE_LOG.contains("OpenOptions::new()"));
    assert!(SERVICE_LOG.contains(".append(true)"));
    assert!(SERVICE_LOG.contains("file.sync_data()"));
    assert!(SERVICE_LOG.contains("share_mode(FILE_SHARE_READ)"));
    assert!(SERVICE_LOG.contains("sync_channel(SERVICE_EVENT_LANE_CAPACITY)"));
    assert!(SERVICE_LOG.contains("ArrayQueue::new(SERVICE_EVENT_LANE_CAPACITY)"));
    assert!(SERVICE_LOG.contains("force_push"));
    assert!(SERVICE_LOG.contains("try_send"));
    assert!(SERVICE_LOG.contains("lumen-windows-service-event-log"));
    assert!(SERVICE_LOG.contains("MAXIMUM_SERVICE_EVENT_LOG_BYTES"));
    assert!(SERVICE_LOG.contains("rotate"));
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
    let publish = policy.find("publish_adaptive_video_apply").unwrap();
    let converge = policy
        .find("self.admission_divisor = admission_divisor")
        .unwrap();
    assert!(apply < commit);
    assert!(commit < publish);
    assert!(publish < converge);
    assert!(policy.contains("WindowsAdaptiveVideoApplyEvent::new"));
    assert!(policy.contains("bitrate_bps"));
    assert!(policy.contains("applied_bitrate_bps"));
    assert!(!policy[publish..converge].contains('?'));
    assert!(!policy.contains("record_adaptive_video_apply"));
    assert!(!policy.contains("OpenOptions"));
    assert!(!policy.contains("sync_data"));

    assert!(SESSION_SLOT.contains("struct SessionRetirementGate"));
    assert!(SESSION_SLOT.contains("fn commit_if_active"));
    assert!(SESSION_SLOT.contains("fn retire"));
}

#[test]
fn windows_service_prepares_program_data_without_weakening_permissions() {
    let prepare = SERVICE
        .find("prepare_program_data_lumen_directory")
        .expect("service-owned ProgramData preparation");
    let launch = SERVICE
        .find("launch_session_agent(&token, &job)")
        .expect("session-agent launch");
    assert!(prepare < launch);
    assert!(!SERVICE_LOG.contains("SetNamedSecurityInfo"));
    assert!(!SERVICE_LOG.contains("SetFileSecurity"));
    assert!(SERVICE_LOG.contains("FILE_ATTRIBUTE_REPARSE_POINT"));
    assert!(SERVICE_LOG.contains("GetNamedSecurityInfoW"));
    assert!(SERVICE_LOG.contains("EqualSid"));
    assert!(SERVICE_LOG.contains("SE_DACL_PROTECTED"));
    assert!(!SERVICE_LOG.contains("SetNamedSecurityInfo"));
    assert!(!SERVICE_LOG.contains("std::fs::create_dir_all(directory)"));
    assert!(WINDOWS_PACKAGE.contains("Id=\"LUMENPROGRAMDATAFOLDER\" Name=\"Lumen\""));
    assert!(WINDOWS_PACKAGE.contains("<ComponentRef Id=\"LumenProgramData\" />"));
    assert!(WINDOWS_PACKAGE.contains("<PermissionEx Id=\"LumenProgramDataPermissions\""));
    assert!(WINDOWS_PACKAGE.contains("Sddl=\"O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)\""));
}
