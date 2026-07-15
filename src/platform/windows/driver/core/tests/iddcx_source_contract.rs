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
    let monitoring = adapter[pin..]
        .find("start_adapter_monitoring")
        .map(|offset| pin + offset)
        .expect("selected render adapter must be monitored");
    let complete = adapter[monitoring..]
        .rfind("LumenDriverOperationCompleteAdapterInitialization")
        .map(|offset| monitoring + offset)
        .expect("backend rows must unlock after the pin and monitor are installed");
    let arrival = adapter
        .find("IddCxMonitorArrival")
        .expect("monitor must arrive through IddCx");

    // Then: features and LUID are fixed before monitor ownership can become visible.
    assert!(version < feature && feature < prepare && prepare < initialize);
    assert!(initialize < pin && pin < monitoring && monitoring < complete);
    assert!(complete < arrival);
}

#[test]
fn swapchain_callback_validates_then_abandons_without_claiming_ownership() {
    // Given: the IddCx swap-chain callback boundary.
    let callbacks = fs::read_to_string(driver_root().join("shim/iddcx_callbacks.cpp"))
        .expect("callback boundary must exist");

    // When: the assignment transaction is inspected.
    let validation = callbacks
        .find("LumenDriverOperationValidateAndAbandonSwapchain")
        .expect("Rust must validate assignment");
    let assigned_luid = callbacks[validation..]
        .find("RenderAdapterLuid")
        .map(|offset| validation + offset)
        .expect("OS-assigned LUID must cross the boundary");
    let abandon = callbacks[assigned_luid..]
        .find("STATUS_GRAPHICS_INDIRECT_DISPLAY_ABANDON_SWAPCHAIN")
        .map(|offset| assigned_luid + offset)
        .expect("IddCx must receive the only safe callback failure");

    // Then: validation precedes abandonment and no production assignment state is retained.
    assert!(validation < assigned_luid && assigned_luid < abandon);
    assert!(!callbacks.contains("assigned_adapter_luid"));
    assert!(!callbacks.contains("LumenDriverOperationUnassignSwapchain"));
}

#[test]
fn adapter_change_notification_dispatches_removal_and_completes_typed_event() {
    // Given: the selected-adapter monitoring and event-delivery boundaries.
    let adapter = fs::read_to_string(driver_root().join("shim/adapter.cpp"))
        .expect("adapter boundary must exist");
    let io = fs::read_to_string(driver_root().join("shim/io.cpp"))
        .expect("event I/O boundary must exist");

    // When: registration, device-loss checks, rollback, and bounded completion are located.
    let register = adapter
        .find("RegisterAdaptersChangedEvent")
        .expect("DXGI adapter changes must be registered");
    let work_item = adapter
        .find("WdfWorkItemEnqueue")
        .expect("notification must enter the serialized WDF boundary");
    let removed_reason = adapter
        .find("GetDeviceRemovedReason")
        .expect("retained probe devices must report device loss");
    let rollback = adapter
        .find("LumenDriverOperationAdapterRemoved")
        .expect("device loss must reach Rust rollback");
    let completion = adapter
        .find("LumenCompletePendingEvent")
        .expect("typed removal must complete one bounded read");
    let unregister = adapter
        .find("UnregisterAdaptersChangedEvent")
        .expect("adapter notification must have deterministic cleanup");

    // Then: event detection is serialized, typed, bounded, and cleanup-backed.
    assert!(register < work_item && work_item < removed_reason);
    assert!(removed_reason < rollback && rollback < completion);
    assert!(io.contains("LumenDriverEventAdapterRemoved"));
    assert!(unregister > register);
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
