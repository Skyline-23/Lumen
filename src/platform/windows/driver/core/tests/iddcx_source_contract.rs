use std::fs;
use std::path::PathBuf;

fn driver_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("driver core must have a parent package directory")
        .to_path_buf()
}

#[test]
fn project_lets_the_wdk_own_the_umdf_loader_entrypoint() {
    // Given: the project that links the user-mode indirect-display driver.
    let project = fs::read_to_string(driver_root().join("LumenIddCx.vcxproj"))
        .expect("driver project must exist");

    // Then: the WDF stub remains linked as an export while the linker supplies
    // the normal DLL entrypoint. Making FxDriverEntryUm the PE entrypoint causes
    // WUDFHost to invoke it with DllMain arguments before DriverEntry can run.
    assert!(!project.contains("<AdditionalDependencies>IddCxStub.lib;WdfDriverStubUm.lib;"));
    assert!(!project.contains("<AdditionalLibraryDirectories>$(WindowsSdkDir)Lib"));
    assert_eq!(
        project
            .matches("<PlatformToolset>WindowsUserModeDriver10.0</PlatformToolset>")
            .count(),
        2
    );
    assert_eq!(
        project
            .matches("<IndirectDisplayDriver>true</IndirectDisplayDriver>")
            .count(),
        2
    );
    assert_eq!(project.matches("<SignMode>Off</SignMode>").count(), 2);
    assert!(project.contains("<Inf2CatUseLocalTime>true</Inf2CatUseLocalTime>"));
    assert!(!project.contains("<PlatformToolset>v143</PlatformToolset>"));
    assert!(project.contains(
        "<PackageReference Include=\"Microsoft.Windows.WDK.x64\" Version=\"10.0.28000.1839\""
    ));
    assert!(project.contains(
        "<PackageReference Include=\"Microsoft.Windows.SDK.CPP.x64\" Version=\"10.0.28000.1721\""
    ));
    assert!(project.contains("<Inf Include=\"package\\LumenIddCx.inf\""));
    assert!(project.contains("<FilesToPackage Include=\"$(TargetPath)\""));
    assert_eq!(
        project.matches("<UMDF_VERSION_MINOR_REQUIRED>25").count(),
        2
    );
    assert_eq!(project.matches("<UMDF_VERSION_MINOR>25").count(), 2);
    assert!(!project.contains("<UMDF_VERSION_MINOR>33"));
    assert!(!project.contains("<EntryPointSymbol>"));

    let driver = fs::read_to_string(driver_root().join("shim/driver.cpp"))
        .expect("driver initialization source must exist");
    assert!(!driver.contains("diagnostic_stage_failure"));
}

#[test]
fn pnp_start_completes_before_render_adapter_initialization() {
    // Given: IddCx owns the display stack's PnP start transaction.
    let driver = fs::read_to_string(driver_root().join("shim/driver.cpp"))
        .expect("driver initialization source must exist")
        .replace("\r\n", "\n");
    let header = fs::read_to_string(driver_root().join("shim/driver.h"))
        .expect("driver declarations must exist");

    // Then: DeviceAdd only creates and initializes the IddCx device. DXGI/D3D
    // probing and asynchronous adapter initialization begin after D0 entry, as
    // required by the Microsoft indirect-display lifecycle.
    assert!(header.contains("EVT_WDF_DEVICE_D0_ENTRY LumenEvtDeviceD0Entry"));
    assert!(driver.contains("EvtDeviceD0Entry = LumenEvtDeviceD0Entry"));
    assert!(driver.contains("NTSTATUS LumenEvtDeviceD0Entry("));

    let device_add = driver
        .find("NTSTATUS LumenEvtDeviceAdd(")
        .expect("DeviceAdd callback must exist");
    let d0_entry = driver
        .find("NTSTATUS LumenEvtDeviceD0Entry(")
        .expect("D0 entry callback must exist");
    let device_add_body = &driver[device_add..d0_entry];
    let initialize_iddcx = device_add_body
        .find("IddCxDeviceInitialize(device)")
        .expect("IddCx must be initialized during DeviceAdd");
    let initialize_context = device_add_body
        .find("context->core_state = lumen_driver_core_initial_state()")
        .expect("the device context must be initialized after IddCx owns the device");
    assert!(!device_add_body.contains("WdfDeviceCreateDeviceInterface(device"));
    assert!(!device_add_body.contains("create_manual_queue(device"));
    assert!(!device_add_body.contains("WdfWorkItemCreate("));
    assert!(initialize_iddcx < initialize_context);
    assert!(device_add_body[initialize_context..]
        .trim_end()
        .ends_with("return STATUS_SUCCESS;\n}"));
    assert!(!device_add_body.contains("LumenInitializeAdapter("));
    let d0_entry_body = &driver[d0_entry..];
    let initialize_control = d0_entry_body
        .find("initialize_control_plane(device, context)")
        .expect("D0 entry must initialize the user control plane");
    let initialize_adapter = d0_entry_body
        .find("LumenInitializeAdapter(device, context)")
        .expect("D0 entry must initialize the IddCx adapter");
    assert!(initialize_control < initialize_adapter);
    assert!(driver.contains("kControlPlaneInitializing"));
    assert!(driver.contains("kControlPlaneReady"));
    assert!(driver.contains("kControlPlaneFailed"));
    assert!(driver.contains("return context->control_plane_status;"));
    assert!(driver.contains("context->control_plane_status = reported;"));
}

#[test]
fn iddcx_device_uses_framework_default_synchronization() {
    // Given: IddCx owns an internal device-control queue while Lumen also owns
    // file create/cleanup callbacks and asynchronous frame work.
    let driver = fs::read_to_string(driver_root().join("shim/driver.cpp"))
        .expect("driver initialization source must exist");

    // Then: the WDF device follows the Microsoft IDD lifecycle and does not
    // force a device-wide lock over IddCx's class-extension objects. File
    // callbacks remain passive and independent, and the work item does not
    // request automatic serialization without a compatible queue scope.
    let device_attributes = driver
        .split("WDF_OBJECT_ATTRIBUTES attributes;")
        .nth(1)
        .and_then(|body| body.split("WDFDEVICE device").next())
        .expect("device object attributes must precede device creation");
    assert!(!device_attributes.contains("SynchronizationScope"));
    assert!(!device_attributes.contains("ExecutionLevel"));
    assert!(driver.contains("WDF_OBJECT_ATTRIBUTES file_attributes;"));
    assert!(driver.contains("WDF_OBJECT_ATTRIBUTES_INIT(&file_attributes);"));
    assert!(driver.contains("file_attributes.SynchronizationScope = WdfSynchronizationScopeNone;"));
    assert!(driver.contains("file_attributes.ExecutionLevel = WdfExecutionLevelPassive;"));
    assert!(driver.contains("frame_work_item_config.AutomaticSerialization = FALSE;"));
    let adapter = fs::read_to_string(driver_root().join("shim/adapter.cpp"))
        .expect("adapter initialization source must exist");
    assert!(adapter.contains("work_item_config.AutomaticSerialization = FALSE;"));
    assert!(adapter.contains("LumenReportInitializationFailure("));
    assert!(adapter.contains("L\"start_adapter_monitoring\""));
    assert!(driver.contains(
        "WdfDeviceInitSetFileObjectConfig(device_init, &file_config, &file_attributes);"
    ));
    assert!(!driver.contains(
        "WdfDeviceInitSetFileObjectConfig(device_init, &file_config, WDF_NO_OBJECT_ATTRIBUTES);"
    ));
}

#[test]
fn iddcx_device_allows_stack_wide_io_negotiation() {
    // Given: Lumen shares the UMDF device stack with the IddCx class extension,
    // while its control plane contains both buffered and direct-transfer IOCTLs.
    let driver = fs::read_to_string(driver_root().join("shim/driver.cpp"))
        .expect("driver initialization source must exist");

    // Then: Lumen must not force every driver in the stack into direct I/O.
    // BufferedOrDirect lets UMDF select one compatible stack-wide access mode.
    assert!(driver.contains("io_config.ReadWriteIoType = WdfDeviceIoBufferedOrDirect;"));
    assert!(driver.contains("io_config.DeviceControlIoType = WdfDeviceIoBufferedOrDirect;"));
    assert!(!driver.contains("io_config.ReadWriteIoType = WdfDeviceIoDirect;"));
    assert!(!driver.contains("io_config.DeviceControlIoType = WdfDeviceIoDirect;"));
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
fn monitor_creation_supplies_default_and_target_modes() {
    // Given: an IDD monitor with a Rust-owned EDID and a session-specific container identity.
    let adapter = fs::read_to_string(driver_root().join("shim/adapter.cpp"))
        .expect("adapter boundary must exist");
    let callbacks = fs::read_to_string(driver_root().join("shim/iddcx_callbacks.cpp"))
        .expect("monitor callback boundary must exist");

    // Then: monitor creation follows the working IDD sample shape and both
    // mode callbacks return one concrete mode instead of STATUS_NOT_SUPPORTED.
    assert!(adapter.contains("DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI"));
    assert!(adapter.contains("unpack_monitor_container_id"));
    assert!(adapter.contains("request.arguments[3]"));
    assert!(adapter.contains("request.arguments[4]"));
    assert!(!adapter.contains("kLumenMonitorContainer"));
    assert!(adapter.contains("LumenReportInitializationFailure(L\"IddCxMonitorCreate\""));
    assert!(adapter.contains("LumenReportInitializationFailure(L\"IddCxMonitorArrival\""));
    assert!(adapter.contains("lumen_driver_core_build_monitor_edid"));
    assert!(!adapter.contains("kFallbackMonitorEdid"));
    assert!(callbacks.contains("IDDCX_MONITOR_MODE"));
    assert!(callbacks.contains("IDDCX_TARGET_MODE"));
    assert!(callbacks.contains("lumen_driver_core_build_video_signal_mode"));
    assert_eq!(
        callbacks
            .matches("lumen_driver_core_build_video_signal_mode")
            .count(),
        1
    );
    assert!(callbacks.contains("LumenDriverVideoSignalMode make_signal_mode("));
    assert_eq!(
        callbacks
            .matches("const auto signal = make_signal_mode(")
            .count(),
        4
    );
    assert!(callbacks.contains("refresh_millihertz,\n    1\n  );"));
    assert!(!callbacks.contains("refresh_millihertz,\n    0\n  );"));
    assert!(callbacks.contains("lumen_driver_core_parse_monitor_edid"));
    assert!(!callbacks.contains("refresh_millihertz * height"));
    assert!(!callbacks.contains("refresh_millihertz) * width"));
    assert!(callbacks.contains("DefaultMonitorModeBufferOutputCount = kLumenModeCount"));
    assert!(callbacks.contains("TargetModeBufferOutputCount = kLumenModeCount"));
    assert!(callbacks.contains("input->pDefaultMonitorModes[0] = make_monitor_mode"));
    assert!(callbacks.contains("input->pTargetModes[0] = make_target_mode"));
}

#[test]
fn monitor_arrival_identity_crosses_the_create_monitor_response() {
    // Given: IddCx assigns the OS adapter and target identity at monitor arrival.
    let adapter = fs::read_to_string(driver_root().join("shim/adapter.cpp"))
        .expect("adapter boundary must exist");
    let io = fs::read_to_string(driver_root().join("shim/io.cpp"))
        .expect("device-control boundary must exist");
    let header = fs::read_to_string(driver_root().join("include/lumen_driver_abi.h"))
        .expect("driver ABI header must exist");

    // Then: the identity returned by IddCx is preserved for the interactive
    // companion host instead of being replaced with ConnectorIndex.
    assert!(adapter.contains("context->monitor_os_adapter_luid = arrival.OsAdapterLuid"));
    assert!(adapter.contains("context->monitor_os_target_id = arrival.OsTargetId"));
    assert!(io.contains("LumenPackLuid(context->monitor_os_adapter_luid)"));
    assert!(io.contains("context->monitor_os_target_id"));
    assert!(header.contains("IDARG_OUT_MONITORARRIVAL::OsAdapterLuid"));
    assert!(header.contains("IDARG_OUT_MONITORARRIVAL::OsTargetId"));
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
        .find("void LumenEvtIddCxDeviceIoControl")
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
fn adapter_caps_include_required_endpoint_diagnostics() {
    // Given: IddCx validates static adapter capabilities before it accepts the
    // asynchronous adapter initialization request.
    let adapter = fs::read_to_string(driver_root().join("shim/adapter.cpp"))
        .expect("adapter initialization source must exist");

    // Then: required endpoint diagnostics and version records are populated.
    assert!(adapter.contains("caps.EndPointDiagnostics.Size = sizeof(caps.EndPointDiagnostics);"));
    assert!(adapter.contains("caps.EndPointDiagnostics.GammaSupport ="));
    assert!(adapter.contains("IDDCX_FEATURE_IMPLEMENTATION_NONE;"));
    assert!(adapter.contains("caps.EndPointDiagnostics.TransmissionType ="));
    assert!(adapter.contains("IDDCX_TRANSMISSION_TYPE_WIRED_OTHER;"));
    assert!(adapter.contains("caps.EndPointDiagnostics.pEndPointFriendlyName"));
    assert!(adapter.contains("caps.EndPointDiagnostics.pEndPointManufacturerName"));
    assert!(adapter.contains("caps.EndPointDiagnostics.pEndPointModelName"));
    assert!(adapter.contains("static IDDCX_ENDPOINT_VERSION endpoint_version = []"));
    assert!(adapter.contains("version.Size = sizeof(version);"));
    assert!(adapter.contains("caps.EndPointDiagnostics.pFirmwareVersion = &endpoint_version;"));
    assert!(adapter.contains("caps.EndPointDiagnostics.pHardwareVersion = &endpoint_version;"));
    assert!(!adapter.contains("IDDCX_ENDPOINT_VERSION endpoint_version {};"));
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
    assert!(capture.contains("conversion_pipeline: Option<NativeVideoConversionPipeline>"));
    assert!(capture.contains("pipeline.key != key"));
    assert!(capture.contains("texture: pipeline.output_texture.clone()"));

    assert!(video.contains("NativeIddCxCapture"));
    assert!(!video.contains("NativeDesktopDuplication"));
    assert!(video.contains("MFVideoFormat_AYUV"));
    assert!(video.contains("MFVideoFormat_Y410"));
    assert!(video.contains("eAVEncH265VProfile_Main_444_8"));
    assert!(video.contains("eAVEncH265VProfile_Main_444_10"));
}
