const DISPLAY: &str = include_str!("../src/platform/windows/native_display.rs");
const INPUT: &str = include_str!("../src/platform/windows/native_input.rs");
const TOPOLOGY: &str = include_str!("../src/platform/windows/native_display_topology.rs");

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
