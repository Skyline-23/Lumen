use super::*;

#[test]
fn host_capture_cursor_is_an_unconfigurable_cross_platform_invariant() {
    let macos_configuration = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../src/platform/macos/Projects/LumenMacBridge/Sources/LumenBridgeRuntime.swift"
    ));
    let macos_capture = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../src/platform/macos/Projects/LumenMacBridge/Sources/LumenScreenCaptureKitBackend.swift"
        ));
    let macos_bridge_header = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../src/platform/macos/Projects/LumenMacBridge/Headers/LumenMacBridge.h"
    ));
    let macos_facade = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../src/platform/macos/Projects/LumenMacBridge/Sources/LumenBridgeObjCFacade.swift"
    ));
    let macos_shim = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../src/platform/macos/Projects/LumenMacBridge/Sources/LumenMacBridgeShim.m"
    ));
    let source_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../src");
    let input_source = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../lumen-host/src/platform/windows/native_desktop_input.rs"
    ));
    let windows_capture = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../lumen-host/src/platform/windows/native_capture.rs"
    ));
    let native_protocol = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/protocol/lumen-streaming-v4.proto"
    ));

    assert!(!macos_configuration.contains("showCursor"));
    assert!(macos_capture.contains("configuration.showsCursor = true"));
    assert!(!macos_bridge_header.contains("show_cursor"));
    assert!(!macos_facade.contains("showCursor"));
    assert!(!macos_shim.contains("show_cursor"));
    assert!(!macos_shim.contains("showCursor"));
    assert!(!source_root.join("globals.h").exists());
    assert!(!source_root.join("globals.cpp").exists());
    assert!(!input_source.contains("0x4E /* VKEY_N */"));
    for retired_capture_source in [
        "platform/common.h",
        "platform/windows/display.h",
        "platform/windows/display_wgc.cpp",
        "platform/windows/display_vram.cpp",
        "platform/windows/display_ram.cpp",
    ] {
        assert!(!source_root.join(retired_capture_source).exists());
    }
    assert!(windows_capture.contains("GetFramePointerShape"));
    assert!(windows_capture.contains("IDXGIOutput6"));
    assert!(windows_capture.contains("DuplicateOutput1"));
    assert!(windows_capture.contains("HDR_CAPTURE_FORMATS"));
    assert!(windows_capture.contains("Advanced Color on the selected display"));
    assert!(!windows_capture.contains(".DuplicateOutput(&device)"));
    assert!(windows_capture.contains("VideoProcessorSetStreamAlpha"));
    assert!(windows_capture.contains("DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME"));
    assert!(windows_capture.contains("DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR"));
    assert!(windows_capture.contains("D3DCompile"));
    assert!(windows_capture.contains("MaxInputStreams < 2"));
    assert!(!windows_capture.contains("MapDesktopSurface"));
    assert!(!windows_capture.contains("requires XOR compositing"));
    assert!(!native_protocol.contains("cursor"));
}
use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_DIRECTORY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn complete_host_command(
    engine: &mut HostRuntimeEngine,
    expected_kind: LumenHostRuntimeCommandKind,
    succeeded: bool,
) -> LumenEngineStatus {
    let command = engine.next_command().unwrap();
    assert_eq!(command.kind, expected_kind);
    engine.complete_command(command, succeeded)
}

#[test]
fn host_runtime_start_and_stop_are_rust_planned() {
    let mut engine = HostRuntimeEngine::default();

    assert_eq!(engine.request_start(), LumenEngineStatus::Ok);
    assert_eq!(engine.state(), LumenHostRuntimeState::Starting);
    assert_eq!(
        complete_host_command(&mut engine, LumenHostRuntimeCommandKind::Start, true),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.state(), LumenHostRuntimeState::Running);

    assert_eq!(engine.request_stop(), LumenEngineStatus::Ok);
    assert_eq!(engine.state(), LumenHostRuntimeState::Stopping);
    assert_eq!(
        complete_host_command(&mut engine, LumenHostRuntimeCommandKind::Stop, true),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.state(), LumenHostRuntimeState::Stopped);
}

#[test]
fn host_runtime_early_exit_cannot_be_reported_as_running() {
    let mut engine = HostRuntimeEngine::default();

    assert_eq!(engine.request_start(), LumenEngineStatus::Ok);
    let start = engine.next_command().unwrap();
    assert_eq!(engine.report_exit(71), LumenEngineStatus::Ok);
    assert_eq!(engine.complete_command(start, true), LumenEngineStatus::Ok);

    assert_eq!(engine.state(), LumenHostRuntimeState::Failed);
    assert_eq!(engine.last_exit_code(), 71);
    assert_eq!(engine.last_failure(), LumenEngineStatus::CommandFailed);
}

#[test]
fn host_runtime_reset_requires_an_inactive_runtime() {
    let mut engine = HostRuntimeEngine::default();

    assert_eq!(engine.request_reset(), LumenEngineStatus::Ok);
    assert_eq!(engine.state(), LumenHostRuntimeState::Resetting);
    assert_eq!(engine.request_start(), LumenEngineStatus::InvalidState);
    assert_eq!(
        complete_host_command(&mut engine, LumenHostRuntimeCommandKind::Reset, true),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.state(), LumenHostRuntimeState::Stopped);
}

#[test]
fn host_runtime_force_stop_does_not_tear_down_the_host() {
    let mut engine = HostRuntimeEngine::default();
    assert_eq!(engine.request_start(), LumenEngineStatus::Ok);
    assert_eq!(
        complete_host_command(&mut engine, LumenHostRuntimeCommandKind::Start, true),
        LumenEngineStatus::Ok
    );

    assert_eq!(engine.request_force_stop_stream(), LumenEngineStatus::Ok);
    assert_eq!(
        complete_host_command(
            &mut engine,
            LumenHostRuntimeCommandKind::ForceStopStream,
            true,
        ),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.state(), LumenHostRuntimeState::Running);
}

#[test]
fn host_factory_reset_removes_settings_but_preserves_diagnostics() {
    let sequence = TEMP_DIRECTORY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!(
        "lumen-engine-reset-{}-{sequence}",
        std::process::id()
    ));
    fs::create_dir_all(root.join("credentials")).unwrap();
    fs::create_dir_all(root.join("covers")).unwrap();
    fs::create_dir_all(root.join("logs")).unwrap();

    let config = root.join("lumen.conf");
    let catalog = root.join("apps.json");
    let state = root.join("lumen_state.json");
    let credentials = root.join("owner-credentials.json");
    for path in [
        &config,
        &catalog,
        &state,
        &credentials,
        &root.join("shadow_state.json"),
        &root.join("lumen_state.json.backup"),
        &root.join("devices.json"),
        &root.join("settings.json"),
        &root.join(".lumen-settings-stale"),
    ] {
        fs::write(path, b"state").unwrap();
    }
    fs::write(root.join("credentials/device.key"), b"secret").unwrap();
    fs::write(root.join("covers/cover.png"), b"image").unwrap();
    let diagnostic_log = root.join("logs/lumen.log");
    fs::write(&diagnostic_log, b"diagnostics").unwrap();

    let result = reset_host_storage(&HostResetStoragePaths {
        app_data: root.clone(),
        explicit_paths: vec![
            config.clone(),
            catalog.clone(),
            state.clone(),
            credentials.clone(),
        ],
    });

    assert_eq!(result.failed_path_count, 0);
    assert!(result.removed_path_count >= 10);
    assert!(!config.exists());
    assert!(!catalog.exists());
    assert!(!state.exists());
    assert!(!credentials.exists());
    assert!(!root.join("credentials").exists());
    assert!(!root.join("covers").exists());
    assert!(!root.join("devices.json").exists());
    assert!(!root.join("settings.json").exists());
    assert!(!root.join(".lumen-settings-stale").exists());
    assert!(diagnostic_log.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn display_geometry_preserves_backing_pixels_and_applies_desktop_scale() {
    let geometry = resolve_display_geometry(LumenDisplayModeRequest {
        width: 2388,
        height: 1668,
        scale_percent: 150,
        dimensions_are_logical: false,
    })
    .unwrap();

    assert_eq!(
        geometry,
        LumenDisplayGeometry {
            stream_width: 2388,
            stream_height: 1668,
            logical_width: 1592,
            logical_height: 1112,
            backing_width: 2388,
            backing_height: 1668,
        }
    );
}

#[test]
fn display_geometry_preserves_explicit_logical_dimensions() {
    let geometry = resolve_display_geometry(LumenDisplayModeRequest {
        width: 1194,
        height: 834,
        scale_percent: 200,
        dimensions_are_logical: true,
    })
    .unwrap();

    assert_eq!(geometry.stream_width, 1194);
    assert_eq!(geometry.logical_width, 1194);
    assert_eq!(geometry.backing_width, 1194);
}

#[test]
fn virtual_display_plan_keeps_plain_sdr_desktop_on_the_existing_display() {
    let plan = resolve_virtual_display_plan(LumenVirtualDisplayRequest {
        session_requested: false,
        app_requested: false,
        hdr_display_required: false,
        hidpi_requested: false,
        dimensions_are_logical: false,
        scale_percent: 100,
    })
    .unwrap();

    assert_eq!(plan, LumenVirtualDisplayPlan::default());
}

#[test]
fn virtual_display_plan_reports_every_admission_reason() {
    let plan = resolve_virtual_display_plan(LumenVirtualDisplayRequest {
        session_requested: true,
        app_requested: true,
        hdr_display_required: true,
        hidpi_requested: true,
        dimensions_are_logical: true,
        scale_percent: 200,
    })
    .unwrap();

    assert!(plan.required);
    assert_eq!(
        plan.reason_flags,
        VIRTUAL_DISPLAY_REASON_SESSION_REQUESTED
            | VIRTUAL_DISPLAY_REASON_APP_REQUESTED
            | VIRTUAL_DISPLAY_REASON_HDR_DISPLAY_REQUIRED
            | VIRTUAL_DISPLAY_REASON_HIDPI_REQUESTED
            | VIRTUAL_DISPLAY_REASON_LOGICAL_DIMENSIONS
            | VIRTUAL_DISPLAY_REASON_SCALED_DESKTOP
    );
}

#[test]
fn virtual_display_plan_rejects_an_invalid_scale() {
    assert_eq!(
        resolve_virtual_display_plan(LumenVirtualDisplayRequest {
            session_requested: false,
            app_requested: false,
            hdr_display_required: false,
            hidpi_requested: false,
            dimensions_are_logical: false,
            scale_percent: 0,
        }),
        Err(LumenEngineStatus::InvalidArgument)
    );
}

#[test]
fn display_color_uses_client_p3_pq_contract_without_forcing_rec2020() {
    let profile = resolve_display_color(LumenDisplayColorRequest {
        hdr_enabled: true,
        client_gamut: 2,
        client_transfer: 2,
    });

    assert_eq!(profile.gamut, LumenDisplayGamut::DisplayP3);
    assert_eq!(profile.transfer, LumenDisplayTransfer::Pq);
    assert_eq!(profile.red_x, 0.6800);
    assert!(profile.hdr_capable);
}

#[test]
fn unknown_sdr_display_color_defaults_to_srgb() {
    let profile = resolve_display_color(LumenDisplayColorRequest {
        hdr_enabled: false,
        client_gamut: 0,
        client_transfer: 0,
    });

    assert_eq!(profile.gamut, LumenDisplayGamut::Srgb);
    assert_eq!(profile.transfer, LumenDisplayTransfer::Sdr);
    assert!(!profile.hdr_capable);
}
