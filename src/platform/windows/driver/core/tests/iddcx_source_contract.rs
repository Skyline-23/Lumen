use std::fs;
use std::path::PathBuf;

fn driver_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("driver core must have a parent package directory")
        .to_path_buf()
}

#[test]
fn feature_probe_and_luid_pin_precede_adapter_and_monitor_creation() {
    // Given: the platform adapter boundary.
    let adapter = fs::read_to_string(driver_root().join("shim/adapter.cpp"))
        .expect("adapter boundary must exist");

    // When: initialization calls are inspected in execution order.
    let version = adapter
        .find("IddCxGetVersion")
        .expect("IddCx version must be queried");
    let feature = adapter
        .find("IddCxCheckOsFeatureSupport")
        .expect("IddCx features must be queried");
    let prepare = adapter
        .find("LumenDriverOperationPrepareAdapter")
        .expect("Rust must approve the runtime probe");
    let initialize = adapter
        .find("IddCxAdapterInitAsync")
        .expect("adapter must be initialized");
    let pin = adapter
        .find("IddCxAdapterSetRenderAdapter")
        .expect("selected render adapter must be pinned");
    let arrival = adapter
        .find("IddCxMonitorArrival")
        .expect("monitor must arrive through IddCx");

    // Then: features and LUID are fixed before monitor ownership can become visible.
    assert!(version < feature && feature < prepare && prepare < initialize);
    assert!(initialize < pin && pin < arrival);
}

#[test]
fn swapchain_callback_revalidates_os_assigned_luid_and_rolls_back() {
    // Given: the IddCx swap-chain callback boundary.
    let callbacks = fs::read_to_string(driver_root().join("shim/iddcx_callbacks.cpp"))
        .expect("callback boundary must exist");

    // When: the assignment transaction is inspected.
    let validation = callbacks
        .find("const auto assigned = lumen_driver_core_dispatch")
        .expect("Rust must validate assignment");
    let assigned_luid = callbacks[..validation]
        .rfind("RenderAdapterLuid")
        .expect("OS-assigned LUID must cross the boundary");
    let rejected_state = callbacks[validation..]
        .find("context->core_state = assigned.state")
        .map(|offset| validation + offset)
        .expect("rejected assignment must commit Rust rollback state");
    let abandon = callbacks[rejected_state..]
        .find("STATUS_GRAPHICS_INDIRECT_DISPLAY_ABANDON_SWAPCHAIN")
        .map(|offset| rejected_state + offset)
        .expect("IddCx must receive the only safe callback failure");
    let accepted_rollback = callbacks[abandon..]
        .find("LumenDriverOperationUnassignSwapchain")
        .map(|offset| abandon + offset)
        .expect("accepted assignment must be released until a processor owns it");

    // Then: no swap chain can be accepted or retried with an unvalidated LUID.
    assert!(assigned_luid < validation && validation < rejected_state && rejected_state < abandon);
    assert!(abandon < accepted_rollback);
}

#[test]
fn secure_ioctl_commits_monitor_state_only_after_iddcx_succeeds() {
    // Given: the single-owner device-control boundary.
    let io = fs::read_to_string(driver_root().join("shim/io.cpp"))
        .expect("device-control boundary must exist");
    let boundary = io
        .find("void LumenEvtIoDeviceControl")
        .expect("device-control callback must exist");
    let device_control = &io[boundary..];

    // When: monitor create, remove, and state commit are located.
    let create = device_control
        .find("status = LumenCreateMonitor(context, core_request)")
        .expect("secure create IOCTL must create the IddCx monitor");
    let remove = device_control
        .find("status = LumenRemoveMonitor(context)")
        .expect("secure remove IOCTL must depart the IddCx monitor");
    let commit = device_control[remove..]
        .find("context->core_state = transition.state")
        .map(|offset| remove + offset)
        .expect("Rust state must commit after platform success");

    // Then: neither tentative Rust transition can become authoritative after IddCx failure.
    assert!(create < remove && remove < commit);
}
