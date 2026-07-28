use std::fs;
use std::path::PathBuf;

fn driver_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("driver core must have a parent package directory")
        .to_path_buf()
}

#[test]
fn shared_header_pins_version_and_layout() {
    // Given: the first-party device ABI header expected by both Rust and C++.
    let header_path = driver_root().join("include/lumen_driver_abi.h");

    // When: the package contract is inspected.
    let header = fs::read_to_string(header_path).expect("shared ABI header must exist");

    // Then: it pins the first major version and every boundary structure size.
    assert!(header.contains("#define LUMEN_DRIVER_ABI_MAJOR 1u"));
    assert!(header.contains("static_assert(sizeof(LumenDriverAbiHeader) == 16"));
    assert!(header.contains("static_assert(sizeof(LumenDriverCoreRequest) == 80"));
    assert!(header.contains("static_assert(sizeof(LumenDriverCoreResponse) == 48"));
}

#[test]
fn inf_is_system_only_and_process_isolated() {
    // Given: the driver INF that owns device-object access policy.
    let inf_path = driver_root().join("package/LumenIddCx.inf");

    // When: its security and UMDF host settings are inspected.
    let inf = fs::read_to_string(inf_path).expect("driver INF must exist");

    // Then: only LocalSystem can open the device and the UMDF host is not pooled.
    assert!(inf.contains("Security,,\"D:P(A;;GA;;;SY)\""));
    assert!(inf.contains("UmdfLibraryVersion = 2.25.0"));
    assert!(inf.contains("UmdfExtensions = IddCx0102"));
    assert!(inf.contains("UmdfHostProcessSharing = ProcessSharingDisabled"));
    assert!(inf.contains("UmdfKernelModeClientPolicy = AllowKernelModeClients"));
    assert!(!inf.contains("RejectKernelModeClients"));
    assert!(!inf.contains("UmdfFileObjectPolicy"));
    assert!(inf.contains("DriverCopy = 13"));
    assert!(inf.contains("%ProviderName% = Models,NTamd64.10.0...17763"));
    assert!(inf.contains("[Models.NTamd64.10.0...17763]"));
    assert!(!inf.contains("[Models.NTamd64]\n"));
    assert!(inf.contains("Include = WUDFRD.inf"));
    assert!(inf.contains("Needs = WUDFRD.NT"));
    assert!(inf.contains("Needs = WUDFRD.NT.HW"));
    assert!(inf.contains("Needs = WUDFRD.NT.Services"));
    assert!(inf.contains("ServiceBinary = %13%\\LumenIddCx.dll"));
    assert!(!inf.contains("[WUDFRdService]"));
    assert!(!inf.contains(";;;WD)"));
    assert!(!inf.contains(";;;BU)"));
    assert!(!inf.contains(";;;BA)"));
}

#[test]
fn production_driver_setup_uses_only_windows_device_install_apis() {
    // Given: the production helper shipped inside the Windows installer.
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows")
        .to_path_buf();
    let source = fs::read_to_string(repo_root.join("tools/lumen_driver_setup.cpp"))
        .expect("first-party driver setup source must exist");
    let cmake = fs::read_to_string(repo_root.join("tools/CMakeLists.txt"))
        .expect("tools CMake project must exist");
    let packaging = fs::read_to_string(repo_root.join("cmake/packaging/windows.cmake"))
        .expect("Windows packaging project must exist");

    // Then: root-device creation, update, health, and uninstall do not depend
    // on a redistributable copy of the WDK's devcon utility.
    assert!(cmake.contains("add_executable(lumen-driver-setup"));
    assert!(cmake.contains("NewDev"));
    assert!(cmake.contains("SetupAPI"));
    assert!(packaging.contains("install(TARGETS lumen-driver-setup"));
    assert!(source.contains("SetupDiCreateDeviceInfoW"));
    assert!(source.contains("SetupDiCallClassInstaller"));
    assert!(source.contains("UpdateDriverForPlugAndPlayDevicesW"));
    assert!(source.contains("DiUninstallDriverW"));
    assert!(source.contains("CM_PROB_NEED_RESTART"));
    assert!(source.contains("ERROR_SUCCESS_REBOOT_REQUIRED"));
    assert!(source.contains("std::wcscmp(result, L\"error\") == 0"));
    assert!(source.contains("(!reboot_required && remaining.count != 0)"));
    assert!(!source.contains("devcon"));
}

#[test]
fn media_io_is_direct_and_all_queues_are_fixed() {
    // Given: the shared boundary for access units, events, and overlapped reads.
    let header_path = driver_root().join("include/lumen_driver_abi.h");

    // When: its transfer method and queue limits are inspected.
    let header = fs::read_to_string(header_path).expect("shared ABI header must exist");

    // Then: media output is direct I/O and no queue has an implicit size.
    assert!(header.contains("LUMEN_METHOD_OUT_DIRECT 2u"));
    assert!(header.contains("LUMEN_FRAME_RECORD_BYTES 80u"));
    assert!(header.contains("LUMEN_FRAME_QUEUE_DEPTH 8u"));
    assert!(header.contains("LUMEN_EVENT_QUEUE_DEPTH 32u"));
    assert!(header.contains("LUMEN_PENDING_READ_DEPTH 4u"));
}

#[test]
fn iddcx_client_config_registers_complete_callback_boundary() {
    // Given: the IddCx device initialization shim.
    let driver = fs::read_to_string(driver_root().join("shim/driver.cpp"))
        .expect("driver initialization source must exist");

    // When: the client callback configuration is inspected.
    let required_callbacks = [
        "EvtIddCxParseMonitorDescription",
        "EvtIddCxAdapterInitFinished",
        "EvtIddCxAdapterCommitModes",
        "EvtIddCxMonitorGetDefaultDescriptionModes",
        "EvtIddCxMonitorQueryTargetModes",
        "EvtIddCxMonitorAssignSwapChain",
        "EvtIddCxMonitorUnassignSwapChain",
    ];

    // Then: every baseline indirect-display callback has an explicit owner.
    for callback in required_callbacks {
        assert!(driver.contains(&format!("iddcx_config.{callback}")));
    }
}

#[test]
fn rejected_file_cleanup_cannot_drain_the_active_owner() {
    // Given: a second file object whose ownership claim was rejected.
    let io = fs::read_to_string(driver_root().join("shim/io.cpp"))
        .expect("driver I/O source must exist");

    // When: WDF invokes cleanup for that rejected file object.
    let owner_guard = "if (context->core_state.owner_id != owner_id)";
    let drain = "cancel_pending_frame_reads(context)";
    let owner_guard_index = io
        .find(owner_guard)
        .expect("cleanup must verify owner identity");
    let drain_index = io
        .find(drain)
        .expect("active-owner cleanup must synchronously drain reads");

    // Then: the shim rejects the cleanup before it can drain the active owner's reads.
    assert!(owner_guard_index < drain_index);
}
