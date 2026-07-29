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
    let windows_header = source.find("#include <windows.h>").unwrap();
    let setupapi_header = source.find("#include <setupapi.h>").unwrap();

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
    assert!(source.contains("LoadLibraryW(L\"newdev.dll\")"));
    assert!(source.contains("GetProcAddress(newdev, \"DiUninstallDriverW\")"));
    assert!(source.contains("CM_PROB_NEED_RESTART"));
    assert!(source.contains("ERROR_SUCCESS_REBOOT_REQUIRED"));
    assert!(windows_header < setupapi_header);
    assert!(source.contains("std::wcscmp(result, L\"error\") == 0"));
    assert!(source.contains("(!reboot_required && remaining.count != 0)"));
    let uninstall = source
        .split("int uninstall_driver")
        .nth(1)
        .expect("driver uninstall implementation must exist");
    let remove_devices = uninstall
        .find("remove_root_devices")
        .expect("uninstall must remove every root device");
    let remove_package = uninstall
        .find("uninstall_driver_package")
        .expect("uninstall must remove the driver-store package");
    assert!(
        remove_devices < remove_package,
        "the root device must be removed before its driver-store package"
    );
    assert!(!source.contains("devcon"));
}

#[test]
fn windows_service_launches_into_the_active_interactive_session_without_polling() {
    // Given: the SCM service owns the lifetime of the user-session host.
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows")
        .to_path_buf();
    let service = fs::read_to_string(repo_root.join("engine/lumen-host/src/windows_service.rs"))
        .expect("Windows service implementation must exist");

    // Then: an active RDP or console session is selected from the WTS
    // inventory, and session availability wakes the service without a fixed
    // startup polling delay.
    assert!(service.contains("WTSEnumerateSessionsW"));
    assert!(service.contains("WTSActive"));
    assert!(service.contains("WTSDisconnected"));
    assert!(service.contains("WTSUserName"));
    assert!(service.contains("session_has_user"));
    assert!(service.contains("WTS_SESSION_LOGON"));
    assert!(service.contains("WTS_SESSION_UNLOCK"));
    assert!(service.contains("WTS_REMOTE_CONNECT"));
    assert!(service.contains("wait_for_session_or_stop"));
    assert!(service.contains("join(\"LumenSessionAgent.exe\")"));
    assert!(service.contains("CreateProcessAsUserW"));
    assert!(!service.contains("let application = wide(\"Lumen.exe\")"));
    assert!(!service.contains("WaitForSingleObject(stop_event.get(), 3_000)"));
}

#[test]
fn windows_management_is_local_and_bound_to_the_active_session() {
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows")
        .to_path_buf();
    let pipe = fs::read_to_string(
        repo_root.join("engine/lumen-host/src/platform/windows/native_management_pipe.rs"),
    )
    .expect("Windows management pipe implementation must exist");
    let package = fs::read_to_string(repo_root.join("packaging/windows/Package.wxs"))
        .expect("Windows package definition must exist");

    assert!(pipe.contains("PIPE_REJECT_REMOTE_CLIENTS"));
    assert!(pipe.contains("GetNamedPipeClientProcessId"));
    assert!(pipe.contains("ProcessIdToSessionId"));
    assert!(pipe.contains("client_session_id == agent_session_id"));
    assert!(package.contains("LumenSessionAgent.exe"));
    assert!(package.contains("Target=\"[INSTALLFOLDER]Lumen.exe\""));
    assert!(package.contains("<File Id=\"LumenSessionAgentExecutable\""));
}

#[test]
fn windows_service_preserves_launch_errors_and_reaps_suspended_children() {
    // Given: SCM must report the Win32 boundary that actually failed, and a
    // partially launched host must never survive outside the service job.
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows")
        .to_path_buf();
    let service = fs::read_to_string(repo_root.join("engine/lumen-host/src/windows_service.rs"))
        .expect("Windows service implementation must exist");

    // Then: the error code is captured at the failing call and propagated to
    // SCM, while assignment/resume failures terminate the suspended process.
    assert!(service.contains("struct ServiceError"));
    assert!(service.contains("error.code"));
    assert!(!service.contains("let error = if result.is_ok()"));
    assert!(service.contains("service-error.log"));
    assert!(service.contains("clear_service_error();"));
    assert!(service.contains("terminate_suspended_session_agent"));
    assert!(service.contains("TerminateProcess(process.process.get(), ERROR_PROCESS_ABORTED)"));

    let entry = fs::read_to_string(repo_root.join("engine/lumen-host/src/entry.rs"))
        .expect("native host entrypoint must exist");
    assert!(entry.contains("host-startup-error.log"));
    assert!(entry.contains("clear_windows_startup_error();"));
    assert!(entry.contains("record_windows_startup_error(&error)"));
}

fn resolve_windows_file_version(
    repo_root: &std::path::Path,
    product_version: (u32, u32, u32),
    build_number: Option<&str>,
    github_run_number: Option<&str>,
) -> std::process::Output {
    let mut command = std::process::Command::new("cmake");
    command
        .current_dir(repo_root)
        .arg(format!("-DPROJECT_VERSION_MAJOR={}", product_version.0))
        .arg(format!("-DPROJECT_VERSION_MINOR={}", product_version.1))
        .arg(format!("-DPROJECT_VERSION_PATCH={}", product_version.2))
        .env_remove("GITHUB_RUN_NUMBER");
    if let Some(build_number) = build_number {
        command.arg(format!("-DLUMEN_WINDOWS_BUILD_NUMBER={build_number}"));
    }
    if let Some(github_run_number) = github_run_number {
        command.env("GITHUB_RUN_NUMBER", github_run_number);
    }
    command
        .arg("-P")
        .arg(repo_root.join("cmake/prep/windows_file_version.cmake"))
        .output()
        .expect("CMake must execute the Windows FileVersion resolver")
}

fn cmake_output(output: &std::process::Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[test]
fn windows_file_version_is_monotonic_and_keeps_product_version_semantic() {
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows");

    let explicit = resolve_windows_file_version(repo_root, (0, 0, 45), Some("346"), None);
    assert!(explicit.status.success(), "{}", cmake_output(&explicit));
    let explicit_log = cmake_output(&explicit);
    assert!(explicit_log.contains("Windows FileVersion: 2.0.45.346"));
    assert!(explicit_log.contains("ProductVersion: 0.0.45"));

    let next_commit = resolve_windows_file_version(repo_root, (0, 0, 45), Some("347"), None);
    assert!(
        next_commit.status.success(),
        "{}",
        cmake_output(&next_commit)
    );
    assert!(cmake_output(&next_commit).contains("Windows FileVersion: 2.0.45.347"));

    let shallow_ci = resolve_windows_file_version(repo_root, (0, 0, 45), None, Some("348"));
    assert!(shallow_ci.status.success(), "{}", cmake_output(&shallow_ci));
    let shallow_ci_log = cmake_output(&shallow_ci);
    assert!(shallow_ci_log.contains("Windows FileVersion: 2.0.45.348"));
    assert!(shallow_ci_log.contains("(GITHUB_RUN_NUMBER)"));
}

#[test]
fn windows_file_version_rejects_parts_outside_the_pe_16_bit_range() {
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows");

    for (product_version, build_number) in [
        ((65_534, 0, 0), "1"),
        ((0, 65_536, 0), "1"),
        ((0, 0, 65_536), "1"),
        ((0, 0, 45), "65536"),
    ] {
        let output =
            resolve_windows_file_version(repo_root, product_version, Some(build_number), None);
        assert!(!output.status.success(), "{}", cmake_output(&output));
        assert!(cmake_output(&output).contains("0..65535"));
    }
}

#[test]
fn windows_msi_owns_service_firewall_upgrade_and_removal() {
    // Given: the public Windows package definition and CI build entrypoint.
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows")
        .to_path_buf();
    let package = fs::read_to_string(repo_root.join("packaging/windows/Package.wxs"))
        .expect("WiX package definition must exist");
    let project = fs::read_to_string(repo_root.join("packaging/windows/Lumen.wixproj"))
        .expect("WiX project must exist");
    let build = fs::read_to_string(repo_root.join("scripts/ci/build_windows_package.sh"))
        .expect("Windows package build script must exist");
    let common_targets = fs::read_to_string(repo_root.join("cmake/targets/common.cmake"))
        .expect("common target definitions must exist");
    let version_resolver =
        fs::read_to_string(repo_root.join("cmake/prep/windows_file_version.cmake"))
            .expect("Windows FileVersion resolver must exist");
    let version_resource = fs::read_to_string(repo_root.join("src/platform/windows/windows.rc"))
        .expect("Windows version resource must exist");
    let windows_definitions =
        fs::read_to_string(repo_root.join("cmake/compile_definitions/windows.cmake"))
            .expect("Windows resource compile definitions must exist");
    let tools = fs::read_to_string(repo_root.join("tools/CMakeLists.txt"))
        .expect("Windows service target definitions must exist");

    // Then: MSI owns the machine-wide service and distinct transactional
    // firewall rules, and NSIS is no longer the release artifact.
    assert!(package.contains("Scope=\"perMachine\""));
    assert!(package.contains("<MajorUpgrade"));
    assert!(package.contains("<ServiceInstall"));
    assert!(package.contains("<ServiceControl"));
    let service_control = package
        .split("<ServiceControl")
        .nth(1)
        .and_then(|source| source.split("/>").next())
        .expect("Lumen service control must be declared");
    assert!(service_control.contains("Stop=\"both\""));
    assert!(service_control.contains("Wait=\"yes\""));
    assert!(!service_control.contains("Wait=\"no\""));
    assert!(package.contains("Name=\"Lumen TCP\""));
    assert!(package.contains("Name=\"Lumen UDP\""));
    assert!(package.contains("Id=\"LumenDriverPackage\""));
    assert!(package.contains("Id=\"LumenDriverInf\""));
    assert!(package.contains("Id=\"InstallLumenDriver\""));
    assert!(package.contains("Id=\"RollbackLumenDriver\""));
    assert!(package.contains("Id=\"UninstallLumenDriver\""));
    assert!(package.contains("FileRef=\"LumenDriverSetupExecutable\""));
    assert!(package.contains("Impersonate=\"no\""));
    assert!(!package.contains("Return=\"ignore\""));
    assert!(package.contains(
        "Condition=\"NOT REMOVE~=&quot;ALL&quot; AND NOT WIX_UPGRADE_DETECTED AND NOT Installed\""
    ));
    assert_eq!(
        package
            .matches("Condition=\"NOT REMOVE~=&quot;ALL&quot;\"")
            .count(),
        1,
        "driver installation must run for fresh installs, upgrades, and repairs"
    );
    assert!(package.contains("Id=\"DesktopShortcutFeature\""));
    assert!(package.contains("Id=\"LumenDesktopShortcut\""));
    assert!(package.contains("<StandardDirectory Id=\"DesktopFolder\""));
    assert!(package.contains("Directory=\"DesktopFolder\""));
    assert!(package.contains("<RegistryValue Root=\"HKCU\""));
    assert!(package.contains("Id=\"WixUI_FeatureTree\""));
    assert!(project.contains("WixToolset.Firewall.wixext"));
    assert!(project.contains("WixToolset.UI.wixext"));
    assert!(project.contains("WixUILicenseRtf"));
    assert!(project.contains("<SuppressIces>ICE61</SuppressIces>"));
    assert!(package.contains("Version=\"$(var.ProductVersion)\""));
    let windows_service =
        fs::read_to_string(repo_root.join("engine/lumen-host/src/windows_service.rs"))
            .expect("Windows service source must exist");
    assert!(windows_service.contains("WaitForSingleObject(process.process.get(), 20_000)"));
    assert!(build.contains("LUMEN_WINDOWS_DRIVER_PACKAGE_DIR"));
    assert!(build.contains("LumenIddCx.dll"));
    assert!(build.contains("LumenIddCx.inf"));
    assert!(build.contains("lumeniddcx.cat"));
    assert!(build.contains("Lumen-${ARTIFACT_VERSION}-Windows-x86_64.msi"));
    assert!(build.contains("-DBUILD_WERROR=ON"));
    assert!(build.contains("-D warnings"));
    assert!(build.contains("--no-incremental"));
    assert!(build.contains("BaseIntermediateOutputPath"));
    assert!(build.contains("--property:ProductVersion=\"${VERSION}\""));
    assert!(common_targets.contains("\"${CMAKE_SOURCE_DIR}/tools\""));
    let windows_targets = fs::read_to_string(repo_root.join("cmake/targets/windows.cmake"))
        .expect("Windows target definitions must exist");
    let locale_pruning =
        fs::read_to_string(repo_root.join("cmake/scripts/prune_windows_ui_locales.cmake"))
            .expect("Windows UI locale pruning must exist");
    assert!(windows_targets.contains("prune_windows_ui_locales.cmake"));
    assert!(windows_targets.contains(
        "--property:Version=${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}"
    ));
    assert!(windows_targets.contains(
        "--property:InformationalVersion=${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}"
    ));
    assert!(
        windows_targets.contains("--property:IncludeSourceRevisionInInformationalVersion=false")
    );
    assert!(windows_targets.contains("--property:FileVersion=${LUMEN_WINDOWS_FILE_VERSION}"));
    assert!(version_resolver.contains("set(LUMEN_WINDOWS_FILE_VERSION_EPOCH 2)"));
    assert!(version_resolver.contains("$ENV{GITHUB_RUN_NUMBER}"));
    assert!(version_resolver.contains("rev-parse --is-shallow-repository"));
    assert!(version_resolver.contains("rev-list --count HEAD"));
    assert!(version_resolver.contains("0..65535"));
    assert!(version_resource.contains(
        "FILEVERSION     LUMEN_WINDOWS_FILE_VERSION_MAJOR,LUMEN_WINDOWS_FILE_VERSION_MINOR,LUMEN_WINDOWS_FILE_VERSION_PATCH,LUMEN_WINDOWS_FILE_VERSION_BUILD"
    ));
    assert!(version_resource.contains(
        "PRODUCTVERSION  PROJECT_VERSION_MAJOR,PROJECT_VERSION_MINOR,PROJECT_VERSION_PATCH,0"
    ));
    for version_part in [
        "LUMEN_WINDOWS_FILE_VERSION_MAJOR",
        "LUMEN_WINDOWS_FILE_VERSION_MINOR",
        "LUMEN_WINDOWS_FILE_VERSION_PATCH",
        "LUMEN_WINDOWS_FILE_VERSION_BUILD",
    ] {
        assert!(windows_definitions.contains(version_part));
    }
    assert!(common_targets.contains("target_link_libraries(lumen ${LUMEN_EXTERNAL_LIBRARIES}"));
    assert!(tools.contains("target_link_libraries(lumen-service"));
    assert!(tools.contains("${LUMEN_EXTERNAL_LIBRARIES}"));
    assert!(locale_pruning.contains("en-us;ja-JP;ko-KR"));
    assert!(locale_pruning.contains("Microsoft.ui.xaml.dll.mui"));
    assert!(!build.contains("cpack --config"));
    assert!(!build.contains("-G NSIS"));

    let smoke = fs::read_to_string(repo_root.join("scripts/ci/test_windows_installation.ps1"))
        .expect("Windows installation smoke test must exist");
    assert!(smoke.contains("ReadinessTimeoutSeconds"));
    assert!(smoke.contains("[int]$BasePort = 47989"));
    assert!(smoke.contains("Get-CimInstance Win32_PnPEntity"));
    assert!(smoke.contains("Root\\LumenIddCx"));
    assert!(!smoke.contains("SudoMaker Virtual Display"));

    let host_config = fs::read_to_string(repo_root.join("engine/lumen-host/src/config.rs"))
        .expect("Windows host defaults must exist");
    let windows_defaults = host_config
        .split("fn windows_defaults")
        .nth(1)
        .and_then(|source| source.split("#[cfg(test)]").next())
        .expect("Windows host defaults implementation must be bounded");
    assert!(windows_defaults.contains("\"port=47989\".to_owned()"));
    assert!(!windows_defaults.contains("\"port=48989\".to_owned()"));

    let release = fs::read_to_string(repo_root.join(".github/workflows/release.yml"))
        .expect("release workflow must exist");
    assert!(release.contains("windows-driver:"));
    assert!(release.contains("runs-on: windows-2025-vs2026"));
    assert!(release.contains("lumen-windows-idd-unsigned-${{ github.sha }}"));
    assert!(release.contains("needs: [prepare, windows-driver]"));
    assert!(release.contains("LUMEN_WINDOWS_DRIVER_PACKAGE_DIR: build/windows-driver-package"));
    assert!(release.contains("signpath/github-action-submit-signing-request@v2"));
    assert!(release.contains("Start-Process msiexec.exe"));
    assert!(release.contains("verify /pa /v /c $catalog.FullName $driver.FullName"));

    let signpath = fs::read_to_string(repo_root.join("packaging/windows/SignPath.xml"))
        .expect("SignPath deep-signing configuration must exist");
    assert!(signpath.contains("<msi-file path=\"Lumen-*-Windows-x86_64.msi\">"));
    assert!(signpath.contains("<pe-file path=\"Lumen.exe\">"));
    assert!(signpath.contains("<pe-file path=\"tools/LumenService.exe\">"));
    assert!(signpath.contains("<pe-file path=\"tools/LumenDriverSetup.exe\">"));
    assert!(signpath.contains("<catalog-file path=\"driver/lumeniddcx.cat\">"));
    assert!(signpath.contains("<pe-file path=\"scripts/vigembus_installer.exe\">"));
    assert!(signpath.contains("<authenticode-verify />"));
    assert!(
        !signpath.contains("<pe-file path=\"driver/LumenIddCx.dll\">"),
        "the catalog-covered IDD binary must not be mutated after catalog generation"
    );
}

#[test]
fn windows_development_build_reuses_incremental_outputs_without_packaging() {
    // Given: the development entrypoint and the release-only package entrypoint.
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows")
        .to_path_buf();
    let development =
        fs::read_to_string(repo_root.join("scripts/windows/build_windows_development.sh"))
            .expect("Windows development build entrypoint must exist");
    let development_test =
        fs::read_to_string(repo_root.join("scripts/ci/test_windows_development_build.sh"))
            .expect("Windows development build contract test must exist");
    let windows_targets = fs::read_to_string(repo_root.join("cmake/targets/windows.cmake"))
        .expect("Windows target definitions must exist");
    let common_packaging = fs::read_to_string(repo_root.join("cmake/packaging/common.cmake"))
        .expect("common packaging definitions must exist");
    let release = fs::read_to_string(repo_root.join("scripts/ci/build_windows_package.sh"))
        .expect("Windows package build script must exist");

    // Then: development selects only incremental native/UI targets and never
    // enters the installer path, while the release path retains that contract.
    assert!(development.contains("-DLUMEN_WINDOWS_DEVELOPER_BUILD=ON"));
    assert!(development.contains("lumen_host_rust_build"));
    assert!(development.contains("lumen-service"));
    assert!(development.contains("lumen-windows-ui"));
    assert!(development.contains("dotnet restore"));
    assert!(development.contains("--component"));
    assert!(!development.contains("cmake --install"));
    assert!(!development.contains("Lumen.wixproj"));
    assert!(!development.contains("msi-stage"));
    assert!(windows_targets.contains("if(LUMEN_WINDOWS_DEVELOPER_BUILD)"));
    assert!(windows_targets.contains("LUMEN_WINDOWS_UI_CONFIGURATION \"Debug\""));
    assert!(windows_targets.contains("LUMEN_WINDOWS_UI_CONFIGURATION \"Release\""));
    assert!(windows_targets.contains("--configuration \"${LUMEN_WINDOWS_UI_CONFIGURATION}\""));
    assert!(windows_targets.contains("--property:SelfContained=false"));
    assert!(windows_targets.contains("--property:WindowsAppSDKSelfContained=false"));
    let development_targets = windows_targets
        .split("if(LUMEN_WINDOWS_DEVELOPER_BUILD)")
        .nth(1)
        .and_then(|source| source.split("else()").next())
        .expect("development target branch must exist");
    assert!(!development_targets.contains("\"${LUMEN_DOTNET_EXECUTABLE}\" publish"));
    assert!(common_packaging.contains("if(NOT (WIN32 AND LUMEN_WINDOWS_DEVELOPER_BUILD))"));
    assert!(development_test.contains("--dry-run"));
    assert!(development_test.contains("cmake --install"));
    assert!(release.contains("cmake --install"));
    assert!(release.contains("Lumen.wixproj"));
    assert!(release.contains("msi-stage"));
    assert!(release.contains("-DLUMEN_WINDOWS_DEVELOPER_BUILD=OFF"));
}

#[test]
fn windows_winui_resources_and_generated_outputs_are_localized_and_hygienic() {
    // Given: the WinUI resource loader, locale resources, and the documented
    // incremental development build contract.
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows")
        .to_path_buf();
    let project =
        fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/Lumen.App.csproj"))
            .expect("WinUI project must exist");
    let strings =
        fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/AppStrings.cs"))
            .expect("WinUI resource loader must exist");
    let window =
        fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/MainWindow.xaml.cs"))
            .expect("WinUI window source must exist");
    let client =
        fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/LumenControlClient.cs"))
            .expect("WinUI control client source must exist");
    let english = fs::read_to_string(
        repo_root.join("src/platform/windows/Lumen.App/Strings/en-US/Resources.resw"),
    )
    .expect("English WinUI resources must exist");
    let korean = fs::read_to_string(
        repo_root.join("src/platform/windows/Lumen.App/Strings/ko-KR/Resources.resw"),
    )
    .expect("Korean WinUI resources must exist");
    let japanese = fs::read_to_string(
        repo_root.join("src/platform/windows/Lumen.App/Strings/ja-JP/Resources.resw"),
    )
    .expect("Japanese WinUI resources must exist");
    let gitignore = fs::read_to_string(repo_root.join(".gitignore"))
        .expect("repository ignore rules must exist");
    let development_test =
        fs::read_to_string(repo_root.join("scripts/ci/test_windows_development_build.sh"))
            .expect("Windows development build contract test must exist");

    // Then: Windows resolves strings through its resource system, English is
    // the fallback, and Korean/Japanese UI terms continue the prior UI copy.
    assert!(project.contains("<PRIResource Include=\"Strings\\**\\*.resw\" />"));
    assert!(project.contains("<EnableDefaultPriItems>false</EnableDefaultPriItems>"));
    assert!(strings.contains("Path.Combine(AppContext.BaseDirectory, \"Lumen.pri\")"));
    assert!(strings.contains("Manager.MainResourceMap.GetSubtree(\"Resources\")"));
    assert!(strings.contains("Manager.CreateResourceContext()"));
    assert!(strings.contains("Resources.TryGetValue(key, Context)"));
    assert!(strings.contains("key.Replace('.', '/')"));
    assert!(strings.contains("throw new InvalidOperationException"));
    assert!(!strings.contains("GetForViewIndependentUse"));
    assert!(!strings.contains("CurrentUICulture"));
    for resource in [&english, &korean, &japanese] {
        assert!(resource.contains("name=\"Navigation.Overview\""));
        assert!(resource.contains("name=\"Navigation.Applications\""));
        assert!(resource.contains("name=\"Navigation.Settings\""));
        assert!(resource.contains("name=\"Overview.ReloadApplications\""));
        assert!(resource.contains("name=\"Input.HighResolutionScrolling\""));
        assert!(resource.contains("name=\"Error.ManagementConnectionClosed\""));
    }
    assert!(english.contains("<value>Overview</value>"));
    assert!(korean.contains("<value>개요</value>"));
    assert!(korean.contains("<value>고해상도 스크롤</value>"));
    assert!(japanese.contains("<value>概要</value>"));
    assert!(japanese.contains("<value>高解像度スクロール</value>"));
    assert!(window.contains("T(\"Navigation.Overview\")"));
    assert!(window.contains("F(\"Overview.ControlEndpoint\", snapshot.ControlPort)"));
    assert!(!window.contains("Text = \"Connecting"));
    assert!(!window.contains("AddPageHeader(\"Overview\""));
    assert!(client.contains("AppStrings.Get(\"Error.ManagementConnectionClosed\")"));

    // Generated development outputs stay ignored without re-ignoring the
    // tracked project, source, or locale resources.
    assert!(gitignore.contains("!src/platform/windows/Lumen.App/**"));
    assert!(gitignore.contains("src/platform/windows/Lumen.App/bin/"));
    assert!(gitignore.contains("src/platform/windows/Lumen.App/obj/"));
    assert!(development_test.contains("git -C \"${REPO_ROOT}\" check-ignore"));
    assert!(development_test.contains("Lumen.App/bin/Debug"));
    assert!(development_test.contains("Strings/en-US/Resources.resw"));
}

#[test]
fn windows_winui_matches_the_native_lumen_visual_contract() {
    // Given: the WinUI theme, reusable component factory, window shell, and
    // every supported locale shipped by the native management app.
    let driver = driver_root();
    let repo_root = driver
        .ancestors()
        .nth(4)
        .expect("driver must live under src/platform/windows")
        .to_path_buf();
    let app_xaml = fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/App.xaml"))
        .expect("WinUI app resources must exist");
    let theme = fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/LumenTheme.cs"))
        .expect("WinUI component theme helper must exist");
    let asset_icons =
        fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/LumenAssetIcon.cs"))
            .expect("WinUI shared asset icon adapter must exist");
    let project =
        fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/Lumen.App.csproj"))
            .expect("WinUI project must exist");
    let window =
        fs::read_to_string(repo_root.join("src/platform/windows/Lumen.App/MainWindow.xaml.cs"))
            .expect("WinUI window source must exist");
    let locales = ["en-US", "ko-KR", "ja-JP"].map(|locale| {
        fs::read_to_string(repo_root.join(format!(
            "src/platform/windows/Lumen.App/Strings/{locale}/Resources.resw"
        )))
        .expect("WinUI locale resources must exist")
    });

    // Then: Windows uses the same dark Lumen hierarchy as macOS rather than
    // falling back to the default light NavigationView/control appearance.
    for required_token in [
        "RequestedTheme=\"Dark\"",
        "LumenWindowGradientBrush",
        "LumenAuthenticationHeroBrush",
        "LumenAmberGlowBrush",
        "LumenCoralGlowBrush",
        "LumenMintGlowBrush",
        "LumenCardBrush",
        "LumenCardBorderBrush",
        "LumenPrimaryButtonStyle",
        "LumenTextBoxStyle",
        "LumenPasswordBoxStyle",
        "#FFFF6B33",
        "#FF13120F",
        "#FF0E0F12",
        "#F0FFFFFF",
        "#A8FFFFFF",
        "#6EFFFFFF",
    ] {
        assert!(
            app_xaml.contains(required_token),
            "missing {required_token}"
        );
    }
    assert!(theme.contains("internal static Border Card"));
    assert!(theme.contains("internal static Button PrimaryButton"));
    assert!(theme.contains("NavigationIconSlotWidth = 22"));
    assert!(asset_icons.contains("internal static class LumenAssetIconView"));
    assert!(asset_icons.contains("private static SvgImageSource Svg"));
    assert!(asset_icons.contains("ms-appx:///Assets/icons/ui/"));
    assert!(asset_icons.contains("ms-appx:///Assets/brand/icon.svg"));
    assert!(project.contains("Link=\"Assets\\brand\\icon.svg\""));
    assert!(project.contains("Link=\"Assets\\icons\\ui\\%(Filename)%(Extension)\""));
    assert!(window.contains("BuildAuthenticationSurface()"));
    assert!(window.contains("ShowAuthenticationSurface(true)"));
    assert!(window.contains("AuthenticationGlowCanvas()"));
    assert!(window.contains("LumenAssetIcon.LocalCredentials"));
    assert!(window.contains("LumenAssetIcon.CreateOwner"));
    assert!(window.contains("AppWindow.Resize(new Windows.Graphics.SizeInt32(960, 620))"));
    assert!(window.contains("PasswordRevealMode = PasswordRevealMode.Peek"));
    assert!(!window.contains("ApplicationPageBackgroundThemeBrush"));
    assert!(!window.contains("Colors.Gray"));
    assert!(!window.contains("FontIcon"));
    assert!(!window.contains("SymbolIcon"));

    for asset in [
        "icon.svg",
        "src_assets/common/assets/icons/ui/local-credentials.svg",
        "src_assets/common/assets/icons/ui/host-controls.svg",
        "src_assets/common/assets/icons/ui/remote-access.svg",
        "src_assets/common/assets/icons/ui/create-owner.svg",
        "src_assets/common/assets/icons/ui/unlock.svg",
        "src_assets/common/assets/icons/ui/overview.svg",
        "src_assets/common/assets/icons/ui/applications.svg",
        "src_assets/common/assets/icons/ui/settings.svg",
        "src_assets/common/assets/icons/ui/diagnostics.svg",
    ] {
        assert!(
            repo_root.join(asset).is_file(),
            "missing shared Lumen asset {asset}"
        );
    }

    for locale in locales {
        for localized_key in [
            "Authentication.HeroTitle",
            "Authentication.HeroDescription",
            "Authentication.FeatureLocal",
            "Authentication.FeatureControls",
            "Authentication.FeatureRemote",
            "Authentication.CredentialsNotice",
        ] {
            assert!(
                locale.contains(&format!("name=\"{localized_key}\"")),
                "missing localized WinUI hero key {localized_key}"
            );
        }
    }
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
        "EvtIddCxDeviceIoControl",
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
    assert!(!driver.contains("WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE"));
    assert!(!driver.contains("WdfIoQueueCreate.Default"));
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
