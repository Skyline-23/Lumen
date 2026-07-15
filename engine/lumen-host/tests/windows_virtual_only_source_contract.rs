const DISPLAY: &str = include_str!("../src/platform/windows/native_display.rs");
const INPUT: &str = include_str!("../src/platform/windows/native_input.rs");
const TOPOLOGY: &str = include_str!("../src/platform/windows/native_display_topology.rs");
const DRIVER_ABI: &str = include_str!("../src/platform/windows/driver_abi.rs");
const DRIVER_HEADER: &str =
    include_str!("../../../src/platform/windows/driver/include/lumen_driver_abi.h");
const DRIVER_IO: &str = include_str!("../../../src/platform/windows/driver/shim/io.cpp");

#[test]
fn false_or_omitted_policy_has_no_success_without_idd_creation() {
    // Given: the production Windows display owner source.
    let legacy_skip = "if !plan.virtual_display && !plan.application.virtual_display";

    // When: launch policy and output selection are inspected.
    let mandatory = DISPLAY.contains("monitor_required(Some(plan.virtual_display)");

    // Then: the legacy success skip and physical output fallback are absent.
    assert!(!DISPLAY.contains(legacy_skip));
    assert!(mandatory);
    assert!(!DISPLAY.contains("base_output_name"));
    assert!(DISPLAY.contains("Windows IDD output is not active"));
}

#[test]
fn encoded_frame_readiness_precedes_virtual_only_set_display_config() {
    // Given: the production media polling and display isolation sources.
    let poll = INPUT
        .split("fn poll_encoded_video")
        .nth(1)
        .expect("poll_encoded_video implementation");
    let isolate = DISPLAY
        .split("pub(super) fn first_frame_ready")
        .nth(1)
        .expect("first_frame_ready implementation");

    // When: the first encoded frame path is followed into topology application.
    let frame = poll.find("Ok(Some(frame))").expect("encoded frame branch");
    let readiness = poll
        .find("self.display.first_frame_ready()")
        .expect("display readiness barrier");
    let journal = isolate
        .find("RecoveryPhase::FirstFrameReady")
        .expect("first-frame journal phase");
    let set_config = isolate
        .find("apply_topology(&isolated)")
        .expect("virtual-only topology application");

    // Then: media readiness and its durable phase both precede isolation.
    assert!(frame < readiness);
    assert!(journal < set_config);
}

#[test]
fn exact_supplied_topology_is_applied_without_physical_fallback_flags() {
    // Given: the Win32 SetDisplayConfig adapter source.
    let set_config = TOPOLOGY
        .split("pub(super) fn apply_topology")
        .nth(1)
        .expect("apply_topology implementation");

    // When: the supplied topology flags are inspected.
    let exact = [
        "SDC_APPLY",
        "SDC_USE_SUPPLIED_DISPLAY_CONFIG",
        "SDC_SAVE_TO_DATABASE",
        "SDC_NO_OPTIMIZATION",
    ]
    .iter()
    .all(|flag| set_config.contains(flag));

    // Then: Windows receives the exact array and cannot alter or select physical paths.
    assert!(exact);
    assert!(!set_config.contains("SDC_ALLOW_CHANGES"));
    assert!(!set_config.contains("SDC_TOPOLOGY_EXTEND"));
}

#[test]
fn startup_and_normal_cleanup_verify_restore_before_monitor_removal() {
    // Given: durable startup recovery and normal stop implementations.
    let constructor = DISPLAY
        .split("pub(super) fn new")
        .nth(1)
        .expect("display constructor");
    let stop = DISPLAY
        .split("pub(super) fn stop")
        .nth(1)
        .expect("display stop");

    // When: recovery and teardown ordering is inspected.
    let restore = stop
        .find("display.restore_and_verify")
        .expect("physical restore");
    let remove = stop.find("display.remove()?").expect("IDD removal");

    // Then: startup recovers first, while normal teardown restores before removal.
    assert!(constructor.contains("recover_persisted_topology"));
    assert!(restore < remove);
}

#[test]
fn host_uses_the_first_party_driver_abi_exactly() {
    // Given: the host ABI module and the driver-owned public C header.
    let rust_contract = [
        "f04b8b5a",
        "a603",
        "4d32",
        "ABI_REQUEST_SIZE: u32 = 80",
        "IOCTL_QUERY_CAPABILITIES",
        "IOCTL_CREATE_MONITOR",
        "IOCTL_REMOVE_MONITOR",
        "IOCTL_QUERY_HEALTH",
        "IOCTL_QUERY_MONITOR",
        "IOCTL_ADOPT_MONITOR",
    ];
    let header_contract = [
        "f04b8b5a",
        "a603",
        "4d32",
        "sizeof(LumenDriverCoreRequest) == 80",
        "LUMEN_IOCTL_QUERY_CAPABILITIES",
        "LUMEN_IOCTL_CREATE_MONITOR",
        "LUMEN_IOCTL_REMOVE_MONITOR",
        "LUMEN_IOCTL_QUERY_HEALTH",
        "LUMEN_IOCTL_QUERY_MONITOR",
        "LUMEN_IOCTL_ADOPT_MONITOR",
    ];

    // When: retired and first-party protocol markers are compared.
    let exact = rust_contract
        .iter()
        .all(|marker| DRIVER_ABI.contains(marker))
        && header_contract
            .iter()
            .all(|marker| DRIVER_HEADER.contains(marker));

    // Then: only the first-party GUID, request shape, and IOCTL family remain.
    assert!(exact);
    assert!(!DISPLAY.contains("e5bcc234"));
    assert!(!DISPLAY.contains("VirtualDisplayAddParameters"));
    assert!(!DISPLAY.contains("IOCTL_ADD_VIRTUAL_DISPLAY"));
}

#[test]
fn cleanup_never_removes_an_unverified_orphan_monitor() {
    // Given: host and driver cleanup sources.
    let display_drop = DISPLAY
        .split("impl Drop for NativeWindowsDisplay")
        .nth(1)
        .expect("native display drop");
    let file_cleanup = DRIVER_IO
        .split("void LumenEvtFileCleanup")
        .nth(1)
        .expect("driver file cleanup")
        .split("void LumenEvtIoDeviceControl")
        .next()
        .expect("bounded driver file cleanup");

    // When: implicit cleanup paths are inspected.
    let driver_removes = file_cleanup.contains("LumenRemoveMonitor");

    // Then: handle loss preserves the orphan for the next recovery owner.
    assert!(display_drop.contains("self.stop()"));
    assert!(!DISPLAY.contains("impl Drop for ActiveDisplay"));
    assert!(!driver_removes);
    assert!(file_cleanup.contains("LumenDriverOperationReleaseOwner"));
}

#[test]
fn hotplug_is_polled_before_and_after_isolation() {
    // Given: the first-frame and already-isolated production paths.
    let readiness = DISPLAY
        .split("pub(super) fn first_frame_ready")
        .nth(1)
        .expect("first frame readiness");

    // When: topology refresh and isolated validation calls are inspected.
    let refresh = readiness
        .find("refresh_physical_snapshot")
        .expect("snapshot refresh");
    let isolate = readiness
        .find("apply_topology(&isolated)")
        .expect("isolation apply");

    // Then: refresh precedes isolation and later frames validate exact isolation.
    assert!(refresh < isolate);
    assert!(readiness.contains("validate_isolated_topology"));
}

#[test]
fn create_and_configuration_failures_cross_the_recovery_barrier() {
    // Given: production monitor creation, configuration, and cleanup paths.
    let start = DISPLAY
        .split("pub(super) fn start")
        .nth(1)
        .expect("display start")
        .split("pub(super) fn current_output_name")
        .next()
        .expect("bounded display start");
    let cleanup = DISPLAY
        .split("fn cleanup_display")
        .nth(1)
        .expect("cleanup barrier")
        .split("fn wait_for_new_display")
        .next()
        .expect("bounded cleanup barrier");

    // When: failure handling and explicit monitor removal are ordered.
    let restore = cleanup
        .find("display.restore_and_verify")
        .expect("cleanup restore");
    let remove = cleanup.find("display.remove()").expect("cleanup removal");

    // Then: creation recovery and configuration cleanup restore before any removal.
    assert!(start.contains("recover_persisted_topology"));
    assert!(start.contains("cleanup_display"));
    assert!(!start.contains("remove_monitor"));
    assert!(restore < remove);
}
