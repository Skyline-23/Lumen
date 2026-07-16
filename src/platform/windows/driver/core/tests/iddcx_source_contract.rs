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
fn swapchain_callback_owns_d3d12_frames_and_rolls_back_failed_assignment() {
    // Given: the IddCx swap-chain callback boundary.
    let callbacks = fs::read_to_string(driver_root().join("shim/iddcx_callbacks.cpp"))
        .expect("callback boundary must exist");

    let processor = fs::read_to_string(driver_root().join("shim/frame_processor.cpp"))
        .expect("frame processor must exist");

    // When: the assignment and frame-acquisition transaction is inspected.
    let assignment = callbacks
        .find("LumenDriverOperationAssignSwapchain")
        .expect("Rust must own assignment");
    let assigned_luid = callbacks[assignment..]
        .find("RenderAdapterLuid")
        .map(|offset| assignment + offset)
        .expect("OS-assigned LUID must cross the boundary");
    let accepted = callbacks[assigned_luid..]
        .find("return STATUS_SUCCESS")
        .map(|offset| assigned_luid + offset)
        .expect("successful assignment must stay active");
    let abandon = callbacks[assigned_luid..]
        .find("STATUS_GRAPHICS_INDIRECT_DISPLAY_ABANDON_SWAPCHAIN")
        .map(|offset| assigned_luid + offset)
        .expect("failed processor initialization must abandon safely");

    // Then: successful ownership is distinct from rollback and the D3D12 surface is acquired directly.
    assert!(assignment < assigned_luid && assigned_luid < abandon && abandon < accepted);
    assert!(callbacks.contains("LumenUnassignSwapChain"));
    assert!(processor.contains("IddCxSwapChainSetDevice2"));
    assert!(processor.contains("IddCxSwapChainReleaseAndAcquireBuffer2"));
    assert!(processor.contains("D3D11On12CreateDevice"));
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

#[test]
fn d3d12_swapchain_frames_cross_one_same_adapter_shared_surface() {
    let processor = fs::read_to_string(driver_root().join("shim/frame_processor.cpp"))
        .expect("frame processor must exist");

    let set_device = processor
        .find("IddCxSwapChainSetDevice2")
        .expect("Windows 11 26H1 must bind an IddCx D3D12 command queue");
    let acquire = processor
        .find("IddCxSwapChainReleaseAndAcquireBuffer2")
        .expect("the IDD must acquire an ID3D12Resource directly");
    let bridge = processor
        .find("D3D11On12CreateDevice")
        .expect("the D3D12 surface must bridge on the selected adapter");
    let share = processor
        .find("CreateSharedHandle")
        .expect("the host boundary must receive a named GPU resource");

    assert!(bridge < set_device);
    assert_ne!(set_device, acquire);
    assert!(processor.contains("CreateWrappedResource"));
    assert!(processor.contains("CopyResource"));
    assert!(share < processor.find("LumenDriverOperationDequeueFrame").unwrap());
    assert!(processor.contains("Global\\\\LumenFrame-"));
}

#[test]
fn native_host_uses_iddcx_frames_and_hevc_444_media_foundation_profiles() {
    let host_root = driver_root()
        .parent()
        .and_then(|path| path.parent())
        .and_then(|path| path.parent())
        .and_then(|path| path.parent())
        .expect("driver must live under src/platform/windows")
        .join("engine/lumen-host/src/platform/windows");
    let capture = fs::read_to_string(host_root.join("native_capture.rs"))
        .expect("native capture boundary must exist");
    let video = fs::read_to_string(host_root.join("native_video.rs"))
        .expect("native video boundary must exist");

    assert!(capture.contains("struct NativeIddCxCapture"));
    assert!(capture.contains("OpenSharedResourceByName"));
    assert!(capture.contains("AcquireSync(1"));
    assert!(capture.contains("ReleaseSync(0"));

    assert!(video.contains("NativeIddCxCapture"));
    assert!(!video.contains("NativeDesktopDuplication"));
    assert!(video.contains("MFVideoFormat_AYUV"));
    assert!(video.contains("MFVideoFormat_Y410"));
    assert!(video.contains("eAVEncH265VProfile_Main_444_8"));
    assert!(video.contains("eAVEncH265VProfile_Main_444_10"));
}
