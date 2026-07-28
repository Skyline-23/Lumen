use std::ffi::CString;

use super::*;

fn request() -> LumenWorkspaceSessionRequest {
    LumenWorkspaceSessionRequest {
        policy: LumenWorkspacePolicy::IsolatedWorkspace,
        move_target_windows: false,
        manage_capture: true,
    }
}

fn complete_ffi(
    engine: *mut LumenWorkspaceEngine,
    command: LumenWorkspaceCommand,
    succeeded: bool,
) -> LumenEngineStatus {
    complete_ffi_payload(
        engine,
        command,
        LumenWorkspaceCommandPayloadKind::None,
        None,
        succeeded,
    )
}

fn complete_ffi_payload(
    engine: *mut LumenWorkspaceEngine,
    command: LumenWorkspaceCommand,
    payload_kind: LumenWorkspaceCommandPayloadKind,
    payload_json: Option<&str>,
    succeeded: bool,
) -> LumenEngineStatus {
    let payload = payload_json.map(|value| CString::new(value).unwrap());
    // SAFETY: Category 8 (FFI boundary). Test callers pass a live engine and
    // keep the optional NUL-terminated payload alive through the completion call.
    unsafe {
        lumen_workspace_engine_complete_command_with_payload(
            engine,
            command,
            LumenWorkspaceCommandCompletion {
                succeeded,
                payload_kind,
                payload_json: payload
                    .as_ref()
                    .map_or(std::ptr::null(), |value| value.as_ptr()),
            },
        )
    }
}

fn command_payload_json(
    engine: *mut LumenWorkspaceEngine,
    command: LumenWorkspaceCommand,
) -> String {
    let size = lumen_workspace_engine_command_payload_json_size(engine, command);
    assert!(size > 1);
    let mut bytes = vec![0_u8; size];
    assert_eq!(
        lumen_workspace_engine_copy_command_payload_json(
            engine,
            command,
            bytes.as_mut_ptr().cast(),
            bytes.len(),
        ),
        LumenEngineStatus::Ok
    );
    bytes.pop();
    String::from_utf8(bytes).unwrap()
}

fn complete_startup(engine: &mut WorkspaceEngine) {
    assert_eq!(engine.begin_session(request()), LumenEngineStatus::Ok);
    while let Ok(command) = engine.next_command() {
        assert_eq!(
            engine.complete_command(command, true),
            LumenEngineStatus::Ok
        );
    }
}

fn pending_journal(generation: u64) -> WorkspaceRecoveryJournal {
    WorkspaceRecoveryJournal::new(
        WorkspaceRecoveryMetadata {
            platform: WorkspacePlatform::Macos,
            generation,
            session_id: "ffi-recovery".to_owned(),
            timestamp_unix_ms: 1_784_000_000_000,
            capture_managed: true,
        },
        PhysicalDisplayTopology {
            displays: vec![PhysicalDisplayState {
                id: "physical-1".to_owned(),
                vendor_id: None,
                product_id: None,
                serial_number: None,
                builtin: None,
                mode: PhysicalDisplayMode {
                    width: 2560,
                    height: 1440,
                    refresh_millihz: 120_000,
                    bit_depth: 10,
                },
                origin_x: 0,
                origin_y: 0,
                mirror_master_id: None,
                enabled: true,
                active: true,
                online: true,
            }],
            mac_windows: Vec::new(),
            windows_adapter_luid: None,
            windows_target_paths: Vec::new(),
        },
    )
    .unwrap()
    .with_virtual_display(VirtualDisplayIdentity {
        id: "virtual-1".to_owned(),
    })
    .with_physical_mutation_applied(true)
    .with_phase(RecoveryPhase::IsolationStarted)
}

#[test]
fn failed_restore_preserves_the_journal_but_still_destroys_the_virtual_display() {
    // Given: cleanup has stopped capture and is restoring an isolated workspace.
    let mut engine = WorkspaceEngine::default();
    complete_startup(&mut engine);
    assert_eq!(engine.end_session(), LumenEngineStatus::Ok);
    let stop = engine.next_command().unwrap();
    assert_eq!(stop.kind, LumenWorkspaceCommandKind::StopCapture);
    assert_eq!(engine.complete_command(stop, true), LumenEngineStatus::Ok);
    let restore = engine.next_command().unwrap();
    assert_eq!(restore.kind, LumenWorkspaceCommandKind::RestoreWorkspace);

    // When: restore and verification fail.
    assert_eq!(
        engine.complete_command(restore, false),
        LumenEngineStatus::CommandFailed
    );

    // Then: physical recovery remains pending, but owned virtual display cleanup
    // is independent so a reconnect cannot be poisoned by an orphan display.
    let destroy = engine.next_command().expect("virtual display destroy");
    assert_eq!(
        destroy.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    assert_eq!(
        engine.complete_command(destroy, true),
        LumenEngineStatus::Ok
    );
    assert_eq!(engine.next_command(), Err(LumenEngineStatus::NoCommand));
    assert_eq!(engine.state, LumenWorkspaceState::Stopping);
}

#[test]
fn ffi_recovers_durable_journal_before_emitting_new_session_commands() {
    // Given: the production FFI constructor opens an interrupted isolation journal.
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("display-recovery.json");
    let store = RecoveryJournalStore::new(path.clone());
    store.create(&pending_journal(41)).unwrap();
    let journal_path = path.clone();
    let path = CString::new(path.to_string_lossy().as_bytes()).unwrap();
    // SAFETY: `path` owns a live NUL-terminated buffer for the duration of the call.
    let engine = unsafe {
        lumen_workspace_engine_create_recoverable(path.as_ptr(), WorkspacePlatform::Macos)
    };
    assert!(!engine.is_null());

    // When: a new session requests admission.
    let status = lumen_workspace_engine_begin_session(engine, request());

    // Then: recovery is required and no new-session snapshot can be emitted first.
    assert_eq!(status, LumenEngineStatus::RecoveryRequired);
    let mut command = LumenWorkspaceCommand::placeholder();
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(command.kind, LumenWorkspaceCommandKind::StopCapture);
    assert_eq!(complete_ffi(engine, command, true), LumenEngineStatus::Ok);
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(command.kind, LumenWorkspaceCommandKind::RestoreWorkspace);
    assert!(journal_path.exists());
    assert_eq!(complete_ffi(engine, command, true), LumenEngineStatus::Ok);
    assert!(journal_path.exists());
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        command.kind,
        LumenWorkspaceCommandKind::VerifyPhysicalDisplays
    );
    assert_eq!(complete_ffi(engine, command, true), LumenEngineStatus::Ok);
    assert!(journal_path.exists());
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        command.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    assert_eq!(complete_ffi(engine, command, true), LumenEngineStatus::Ok);
    assert!(!journal_path.exists());
    assert_eq!(
        lumen_workspace_engine_begin_session(engine, request()),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(command.kind, LumenWorkspaceCommandKind::SnapshotWorkspace);
    // SAFETY: this non-null engine was created above and has not been destroyed yet.
    unsafe { lumen_workspace_engine_destroy(engine) };
}

#[test]
fn ffi_restore_failure_preserves_journal_and_allows_owned_display_destroy() {
    // Given: production recovery reaches the restore command with a durable journal.
    let directory = tempfile::tempdir().unwrap();
    let journal_path = directory.path().join("display-recovery.json");
    let store = RecoveryJournalStore::new(journal_path.clone());
    store.create(&pending_journal(52)).unwrap();
    let path = CString::new(journal_path.to_string_lossy().as_bytes()).unwrap();
    // SAFETY: `path` owns a live NUL-terminated buffer for the duration of the call.
    let engine = unsafe {
        lumen_workspace_engine_create_recoverable(path.as_ptr(), WorkspacePlatform::Macos)
    };
    assert_eq!(
        lumen_workspace_engine_begin_session(engine, request()),
        LumenEngineStatus::RecoveryRequired
    );
    let mut command = LumenWorkspaceCommand::placeholder();
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(complete_ffi(engine, command, true), LumenEngineStatus::Ok);
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(command.kind, LumenWorkspaceCommandKind::RestoreWorkspace);

    // When: the platform reports that restore or verification failed.
    assert_eq!(
        complete_ffi(engine, command, false),
        LumenEngineStatus::CommandFailed
    );

    // Then: the journal survives for typed physical recovery, while the owned
    // virtual display still receives its independent destroy command.
    assert!(journal_path.exists());
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        command.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    assert_eq!(complete_ffi(engine, command, true), LumenEngineStatus::Ok);
    assert!(journal_path.exists());
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::NoCommand
    );
    assert_eq!(
        lumen_workspace_engine_state(engine),
        LumenWorkspaceState::Stopping
    );
    // SAFETY: this non-null engine was created above and has not been destroyed yet.
    unsafe { lumen_workspace_engine_destroy(engine) };
}

#[test]
fn ffi_destroy_failure_retains_journal_for_exact_display_retry() {
    // Given: a live coexist session owns a virtual display without mutating physical topology.
    let directory = tempfile::tempdir().unwrap();
    let journal_path = directory.path().join("display-recovery.json");
    let path = CString::new(journal_path.to_string_lossy().as_bytes()).unwrap();
    // SAFETY: `path` owns a live NUL-terminated buffer for the duration of the call.
    let engine = unsafe {
        lumen_workspace_engine_create_recoverable(path.as_ptr(), WorkspacePlatform::Macos)
    };
    assert_eq!(
        lumen_workspace_engine_begin_session(
            engine,
            LumenWorkspaceSessionRequest {
                policy: LumenWorkspacePolicy::Coexist,
                move_target_windows: false,
                manage_capture: false,
            },
        ),
        LumenEngineStatus::Ok
    );
    let mut command = LumenWorkspaceCommand::placeholder();
    let snapshot_topology = pending_journal(63).physical_topology;
    let snapshot_json = serde_json::to_string(&snapshot_topology).unwrap();
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(command.kind, LumenWorkspaceCommandKind::SnapshotWorkspace);
    assert_eq!(
        complete_ffi_payload(
            engine,
            command,
            LumenWorkspaceCommandPayloadKind::PhysicalTopology,
            Some(&snapshot_json),
            true,
        ),
        LumenEngineStatus::Ok
    );
    assert!(journal_path.exists());
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        command.kind,
        LumenWorkspaceCommandKind::CreateVirtualDisplay
    );
    let identity_json = command_payload_json(engine, command);
    assert_eq!(
        complete_ffi_payload(
            engine,
            command,
            LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity,
            Some(&identity_json),
            true,
        ),
        LumenEngineStatus::Ok
    );
    for expected in [
        LumenWorkspaceCommandKind::ConfigureVirtualDisplay,
        LumenWorkspaceCommandKind::AwaitExternalFirstEncodedFrame,
    ] {
        assert_eq!(
            lumen_workspace_engine_next_command(engine, &mut command),
            LumenEngineStatus::Ok
        );
        assert_eq!(command.kind, expected);
        assert_eq!(complete_ffi(engine, command, true), LumenEngineStatus::Ok);
    }
    assert_eq!(
        lumen_workspace_engine_end_session(engine),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        command.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    assert!(journal_path.exists());

    // When: exact topology release or display destruction fails.
    assert_eq!(
        complete_ffi(engine, command, false),
        LumenEngineStatus::CommandFailed
    );

    // Then: no implicit retry loops, but the durable identity remains for a new recovery owner.
    assert!(journal_path.exists());
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::NoCommand
    );
    // SAFETY: this non-null engine was created above and has not been destroyed yet.
    unsafe { lumen_workspace_engine_destroy(engine) };

    // When: a fresh recovery owner retries the exact retained display.
    let retry_engine = unsafe {
        lumen_workspace_engine_create_recoverable(path.as_ptr(), WorkspacePlatform::Macos)
    };
    assert_eq!(
        lumen_workspace_engine_begin_session(retry_engine, request()),
        LumenEngineStatus::RecoveryRequired
    );
    assert_eq!(
        lumen_workspace_engine_next_command(retry_engine, &mut command),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        command.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    assert_eq!(
        complete_ffi(retry_engine, command, true),
        LumenEngineStatus::Ok
    );
    assert!(!journal_path.exists());
    // SAFETY: this non-null engine was created above and has not been destroyed yet.
    unsafe { lumen_workspace_engine_destroy(retry_engine) };
}
