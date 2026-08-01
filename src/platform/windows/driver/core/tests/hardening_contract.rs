use std::fs;
use std::path::PathBuf;

fn driver_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("driver core must have a parent package directory")
        .to_path_buf()
}

fn inf_section<'a>(inf: &'a str, name: &str) -> &'a str {
    let marker = format!("[{name}]");
    let (_, tail) = inf
        .split_once(&marker)
        .unwrap_or_else(|| panic!("missing INF section {name}"));
    tail.split("\n[").next().unwrap_or(tail)
}

#[test]
fn device_security_and_isolation_are_installed_from_hardware_section() {
    // Given: the UMDF package INF and its device-specific registrations.
    let inf = fs::read_to_string(driver_root().join("package/LumenIddCx.inf"))
        .expect("driver INF must exist");

    // When: the DDInstall and DDInstall.HW sections are resolved independently.
    let install = inf_section(&inf, "DriverInstall.NT");
    let hardware = inf_section(&inf, "DriverInstall.NT.HW");
    let isolation = inf_section(&inf, "DriverIsolation");

    // Then: security, the non-pooled host group, and IndirectKmd are all written
    // to the devnode hardware key rather than the package software key.
    assert!(hardware.contains("AddReg = DriverSecurity"));
    assert!(hardware.contains("DriverIsolation"));
    assert!(!install.contains("DriverSecurity"));
    assert!(!install.contains("DriverIsolation"));
    assert!(isolation.contains("\"WUDF\",\"DeviceGroupId\""));
    assert!(isolation.contains("\"UpperFilters\""));
    assert!(isolation.contains("\"IndirectKmd\""));
}

#[test]
fn stop_encoder_synchronously_drains_wdf_access_unit_reads() {
    // Given: the WDF device-control implementation for encoder stop.
    let io = fs::read_to_string(driver_root().join("shim/io.cpp"))
        .expect("driver I/O source must exist");

    // When: the stop boundary and manual queue drain are inspected.
    let stop_gate = io
        .find("operation == LumenDriverOperationStopEncoder")
        .expect("stop operation gate must exist");
    let drain = io[stop_gate..]
        .find("cancel_pending_frame_reads(context)")
        .map(|offset| stop_gate + offset)
        .expect("stop must drain pending frame reads");
    let state_commit = io[stop_gate..]
        .find("context->core_state = transition.state")
        .map(|offset| stop_gate + offset)
        .expect("stop must commit the Rust transition");

    // Then: every WDF request is reconciled and cancelled before the stopped state commits.
    let retrieve = io
        .find("WdfIoQueueRetrieveNextRequest")
        .expect("manual queue must transfer each request");
    let reconcile = io
        .find("cancel_core_read(context, pending_request, kind)")
        .expect("manual queue must reconcile the Rust ledger");
    let complete = io
        .find("WdfRequestComplete(pending_request, STATUS_CANCELLED)")
        .expect("manual queue must cancel-complete each request");
    assert!(retrieve < reconcile && reconcile < complete);
    assert!(io.contains("pending->generation"));
    assert!(stop_gate < drain && drain < state_commit);
    let driver = fs::read_to_string(driver_root().join("shim/driver.cpp"))
        .expect("driver initialization source must exist");
    assert!(driver.contains("iddcx_config.EvtIddCxDeviceIoControl"));
    assert!(!driver.contains("WdfSynchronizationScopeDevice"));
    assert!(!driver.contains("WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE"));
}

#[test]
fn windows_qa_preserves_stop_restart_probe_receipts() {
    // Given: the Windows device QA executable source.
    let qa = fs::read_to_string(driver_root().join("tests/windows_device_probes.cpp"))
        .expect("Windows device QA source must exist");

    // When: its machine-readable probe surface is inspected.
    let required_probes = [
        "unauthorized_open",
        "first_owner",
        "second_owner",
        "stop_cancels_access_unit",
        "restart_accepts_access_unit",
        "cancel_event",
    ];

    // Then: each security and stop/restart outcome has an independent receipt.
    assert!(qa.contains("write_probe"));
    for probe in required_probes {
        assert!(qa.contains(probe), "missing receipt for {probe}");
    }
}

#[test]
fn windows_scripts_cleanup_every_failed_install_attempt() {
    // Given: the Windows install-test and uninstall orchestration scripts.
    let test_script = fs::read_to_string(driver_root().join("scripts/test_windows_driver.ps1"))
        .expect("Windows QA script must exist");
    let build_script = fs::read_to_string(driver_root().join("scripts/build_windows_driver.ps1"))
        .expect("Windows build script must exist");
    let install_script =
        fs::read_to_string(driver_root().join("scripts/install_windows_driver.ps1"))
            .expect("Windows install script must exist");
    let uninstall = fs::read_to_string(driver_root().join("scripts/uninstall_windows_driver.ps1"))
        .expect("Windows uninstall script must exist");

    // When: cleanup, command-status, receipt, and certificate handling are inspected.
    let try_index = test_script.find("try {").expect("QA must use try/finally");
    let install_index = test_script
        .find("install_windows_driver.ps1")
        .expect("QA must install the package");
    let finally_index = test_script
        .rfind("finally {")
        .expect("QA must always enter cleanup");
    let uninstall_index = test_script
        .rfind("uninstall_windows_driver.ps1")
        .expect("QA cleanup must uninstall the package");

    // Then: partial installs are cleaned, probes stay distinct, tools are checked, and trust is removed.
    assert!(try_index < install_index && install_index < finally_index);
    assert!(finally_index < uninstall_index);
    assert!(test_script.contains("authorized-probes.jsonl"));
    assert!(test_script.contains("unauthorized-probes.jsonl"));
    assert!(test_script.contains("$qaSucceeded = $false"));
    assert!(test_script.contains("Get-PfxCertificate -FilePath $certificate"));
    assert!(test_script.contains("ConvertFrom-Json"));
    assert!(test_script.contains("pnputil device query failed"));
    assert!(uninstall.contains("CertificateThumbprint"));
    assert!(uninstall.contains("@(\"Root\", \"TrustedPublisher\")"));
    assert!(uninstall.contains("Cert:\\LocalMachine\\$store\\$CertificateThumbprint"));
    assert!(uninstall.contains("devcon failed to remove"));
    assert!(uninstall.contains("remainingDevices"));
    assert!(uninstall.contains("remainingPackages"));
    let build_try = build_script
        .find("try {")
        .expect("test certificate lifetime must use try/finally");
    let build_certificate = build_script
        .find("New-SelfSignedCertificate")
        .expect("test-sign build must create a certificate");
    let build_finally = build_script
        .rfind("finally {")
        .expect("test certificate lifetime must always clean up");
    assert!(build_try < build_certificate && build_certificate < build_finally);
    assert!(build_script.contains("Cert:\\CurrentUser\\My\\$($certificate.Thumbprint)"));
    assert!(build_script.contains("Microsoft Enhanced RSA and AES Cryptographic Provider"));
    assert!(build_script.contains("Component.Microsoft.Windows.DriverKit.BuildTools"));
    assert!(build_script.contains("Visual Studio Build Tools with Desktop C++ and WDK"));
    assert!(build_script.contains("$msbuild $project /t:Restore"));
    assert!(build_script.contains("Bin\\amd64\\MSBuild.exe"));
    assert!(build_script.contains("$wdkNuGetTools"));
    assert!(build_script.contains("stampinf.exe"));
    assert!(build_script.contains("build\\bin\\x64\\$Configuration\\LumenIddCx.inf"));
    assert!(build_script.contains("/p:InfToolArchitecture=Native64Bit"));
    assert!(build_script.contains("$msbuild $project /m /t:Build"));
    assert!(build_script.contains("\"/uselocaltime\""));
    assert!(build_script
        .contains("MSBuild with the Windows Driver Kit Build Tools component was not found."));
    assert!(install_script.contains("$installSucceeded = $false"));
    assert!(install_script.contains("$installMutated = $false"));
    assert!(install_script.contains("HardwareID -Contains \"ROOT\\LumenIddCx\""));
    assert!(install_script.contains("$installMutated = $true"));
    assert!(install_script.contains("& pnputil.exe /add-driver $inf | Out-Host"));
    assert!(install_script.contains("& pnputil.exe /add-driver $inf /install | Out-Host"));
    assert!(install_script.contains("$pnputilExitCode -notin @(0, 259, 3010)"));
    let stage_missing_device = install_script
        .find("& pnputil.exe /add-driver $inf | Out-Host")
        .expect("a missing device must have its package staged");
    let stage_existing_device = install_script
        .find("& pnputil.exe /add-driver $inf /install | Out-Host")
        .expect("an existing device must have its package applied");
    let devcon_install = install_script
        .find("& $devcon install $inf \"Root\\LumenIddCx\" | Out-Host")
        .expect("a missing root device must be created with devcon");
    assert!(stage_missing_device < devcon_install);
    assert!(stage_existing_device < devcon_install);
    assert!(install_script.contains("$devconExitCode -notin @(0, 1)"));
    assert!(install_script.contains("DEVPKEY_Device_ProblemCode"));
    assert!(install_script.contains("[int]$problem.Data -eq 14"));
    assert!(install_script.contains("RestartRequired = $true"));
    assert!(install_script.contains("RestartRequired = $false"));
    assert!(install_script.contains("$devices[0].Status -ne \"OK\""));
    assert!(test_script.contains("$installResult.RestartRequired"));
    assert!(test_script.contains("$installCompleted = $true"));
    assert!(test_script.contains("$restartRequired = [bool]$installResult.RestartRequired"));
    assert!(test_script.contains("$KeepInstalled -and $installCompleted -and $restartRequired"));
    assert!(install_script.contains("finally {"));
    assert!(install_script.contains("if (-not $installSucceeded -and $installMutated)"));
    assert!(install_script.contains("uninstall_windows_driver.ps1"));
    assert!(uninstall.contains("HardwareID -Contains \"ROOT\\LumenIddCx\""));
}
