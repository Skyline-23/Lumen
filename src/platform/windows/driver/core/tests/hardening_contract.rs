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
fn device_security_is_installed_from_hardware_section() {
    // Given: the UMDF package INF and its device security registration.
    let inf = fs::read_to_string(driver_root().join("package/LumenIddCx.inf"))
        .expect("driver INF must exist");

    // When: the DDInstall and DDInstall.HW sections are resolved independently.
    let install = inf_section(&inf, "DriverInstall.NT");
    let hardware = inf_section(&inf, "DriverInstall.NT.HW");

    // Then: DEVPKEY_Device_Security is owned only by the hardware section.
    assert!(hardware.contains("AddReg = DriverSecurity"));
    assert!(!install.contains("DriverSecurity"));
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
        .find("cancel_pending_access_unit_reads(context)")
        .map(|offset| stop_gate + offset)
        .expect("stop must drain pending access-unit reads");
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
    assert!(driver.contains("WdfSynchronizationScopeDevice"));
    assert!(driver.contains("WdfIoQueueDispatchSequential"));
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
    assert!(test_script.contains("if (-not $qaSucceeded -or -not $KeepInstalled)"));
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
    assert!(install_script.contains("$installSucceeded = $false"));
    assert!(install_script.contains("finally {"));
    assert!(install_script.contains("uninstall_windows_driver.ps1"));
}
