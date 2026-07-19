use std::ffi::{c_char, CString};

use super::*;

fn topology() -> PhysicalDisplayTopology {
    PhysicalDisplayTopology {
        displays: vec![PhysicalDisplayState {
            id: "physical-41".to_owned(),
            vendor_id: None,
            product_id: None,
            serial_number: None,
            builtin: None,
            mode: PhysicalDisplayMode {
                width: 3024,
                height: 1964,
                refresh_millihz: 120_000,
                bit_depth: 10,
            },
            origin_x: -1512,
            origin_y: 0,
            mirror_master_id: Some("physical-7".to_owned()),
            enabled: true,
            active: true,
            online: true,
        }],
        mac_windows: Vec::new(),
        windows_adapter_luid: None,
        windows_target_paths: Vec::new(),
    }
}

fn request() -> LumenWorkspaceSessionRequest {
    LumenWorkspaceSessionRequest {
        policy: LumenWorkspacePolicy::IsolatedWorkspace,
        move_target_windows: false,
        manage_capture: false,
    }
}

fn next(engine: *mut LumenWorkspaceEngine) -> LumenWorkspaceCommand {
    let mut command = LumenWorkspaceCommand::placeholder();
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut command),
        LumenEngineStatus::Ok
    );
    command
}

fn payload_json(engine: *mut LumenWorkspaceEngine, command: LumenWorkspaceCommand) -> String {
    let size = lumen_workspace_engine_command_payload_json_size(engine, command);
    assert!(size > 1);
    let mut bytes = vec![0_u8; size];
    assert_eq!(
        lumen_workspace_engine_copy_command_payload_json(
            engine,
            command,
            bytes.as_mut_ptr().cast::<c_char>(),
            bytes.len(),
        ),
        LumenEngineStatus::Ok
    );
    bytes.pop();
    String::from_utf8(bytes).unwrap()
}

fn complete(
    engine: *mut LumenWorkspaceEngine,
    command: LumenWorkspaceCommand,
    payload_kind: LumenWorkspaceCommandPayloadKind,
    payload_json: Option<&str>,
    succeeded: bool,
) -> LumenEngineStatus {
    let payload = payload_json.map(|json| CString::new(json).unwrap());
    let completion = LumenWorkspaceCommandCompletion {
        succeeded,
        payload_kind,
        payload_json: payload
            .as_ref()
            .map_or(std::ptr::null(), |json| json.as_ptr()),
    };
    // SAFETY: the optional CString remains live through the call and the engine is live.
    unsafe { lumen_workspace_engine_complete_command_with_payload(engine, command, completion) }
}

#[test]
fn production_ffi_persists_every_isolated_session_boundary() {
    // Given: the production FFI owns an empty durable recovery store.
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("display-recovery.json");
    let path_string = CString::new(path.to_string_lossy().as_bytes()).unwrap();
    // SAFETY: the path is a live NUL-terminated string for this constructor call.
    let engine = unsafe {
        lumen_workspace_engine_create_recoverable(path_string.as_ptr(), WorkspacePlatform::Macos)
    };
    assert!(!engine.is_null());
    assert_eq!(
        lumen_workspace_engine_begin_session(engine, request()),
        LumenEngineStatus::Ok
    );

    // When: the real FFI command stream completes an isolated session startup.
    let snapshot = next(engine);
    assert!(!path.exists());
    let topology_json = serde_json::to_string(&topology()).unwrap();
    assert_eq!(
        complete(
            engine,
            snapshot,
            LumenWorkspaceCommandPayloadKind::PhysicalTopology,
            Some(&topology_json),
            true,
        ),
        LumenEngineStatus::Ok
    );
    let persisted = RecoveryJournalStore::new(path.clone()).load().unwrap();
    let RecoveryJournalLoad::Verified(persisted) = persisted else {
        panic!("expected a verified production recovery journal");
    };
    assert_eq!(persisted.phase, RecoveryPhase::SnapshotPersisted);
    assert_eq!(persisted.physical_topology, topology());
    assert!(persisted.virtual_display.is_some());

    let create = next(engine);
    assert_eq!(create.kind, LumenWorkspaceCommandKind::CreateVirtualDisplay);
    let identity_json = payload_json(engine, create);
    assert_eq!(
        complete(
            engine,
            create,
            LumenWorkspaceCommandPayloadKind::VirtualDisplayIdentity,
            Some(&identity_json),
            true,
        ),
        LumenEngineStatus::Ok
    );
    for (kind, phase) in [
        (
            LumenWorkspaceCommandKind::ConfigureVirtualDisplay,
            RecoveryPhase::VirtualConfigured,
        ),
        (
            LumenWorkspaceCommandKind::ApplyIsolation,
            RecoveryPhase::Isolated,
        ),
        (
            LumenWorkspaceCommandKind::AwaitExternalFirstEncodedFrame,
            RecoveryPhase::FirstFrameReady,
        ),
    ] {
        let command = next(engine);
        assert_eq!(command.kind, kind);
        if kind == LumenWorkspaceCommandKind::ApplyIsolation {
            let RecoveryJournalLoad::Verified(started) =
                RecoveryJournalStore::new(path.clone()).load().unwrap()
            else {
                panic!("expected isolation intent to be durable");
            };
            assert_eq!(started.phase, RecoveryPhase::IsolationStarted);
        }
        assert_eq!(
            complete(
                engine,
                command,
                LumenWorkspaceCommandPayloadKind::None,
                None,
                true,
            ),
            LumenEngineStatus::Ok
        );
        let RecoveryJournalLoad::Verified(journal) =
            RecoveryJournalStore::new(path.clone()).load().unwrap()
        else {
            panic!("expected a verified production recovery journal");
        };
        assert_eq!(journal.phase, phase);
    }

    // Then: the journal remains present and identifies the active isolated session.
    let RecoveryJournalLoad::Verified(active) = RecoveryJournalStore::new(path).load().unwrap()
    else {
        panic!("expected active isolated journal");
    };
    assert_eq!(active.phase, RecoveryPhase::FirstFrameReady);
    assert_eq!(
        lumen_workspace_engine_state(engine),
        LumenWorkspaceState::Active
    );
    // SAFETY: this engine was created above and has not been destroyed.
    unsafe { lumen_workspace_engine_destroy(engine) };
}

#[test]
fn production_ffi_recovery_verifies_before_deleting_or_destroying() {
    // Given: a production journal contains the topology and virtual identity from a killed session.
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("display-recovery.json");
    let store = RecoveryJournalStore::new(path.clone());
    let journal = WorkspaceRecoveryJournal::new(
        WorkspaceRecoveryMetadata {
            platform: WorkspacePlatform::Macos,
            generation: 9,
            session_id: "killed-production-session".to_owned(),
            timestamp_unix_ms: 1_784_000_000_000,
            capture_managed: true,
        },
        topology(),
    )
    .unwrap()
    .with_virtual_display(VirtualDisplayIdentity {
        id: "lumen-killed-production-session".to_owned(),
    })
    .with_phase(RecoveryPhase::Isolated);
    store.create(&journal).unwrap();
    let path_string = CString::new(path.to_string_lossy().as_bytes()).unwrap();
    // SAFETY: the path is a live NUL-terminated string for this constructor call.
    let engine = unsafe {
        lumen_workspace_engine_create_recoverable(path_string.as_ptr(), WorkspacePlatform::Macos)
    };
    assert_eq!(
        lumen_workspace_engine_begin_session(engine, request()),
        LumenEngineStatus::RecoveryRequired
    );

    // When: restore succeeds but the independent physical readback fails.
    let stop = next(engine);
    assert_eq!(
        complete(
            engine,
            stop,
            LumenWorkspaceCommandPayloadKind::None,
            None,
            true
        ),
        LumenEngineStatus::Ok
    );
    let restore = next(engine);
    assert_eq!(restore.kind, LumenWorkspaceCommandKind::RestoreWorkspace);
    let restored_topology: PhysicalDisplayTopology =
        serde_json::from_str(&payload_json(engine, restore)).unwrap();
    assert_eq!(restored_topology, topology());
    assert_eq!(
        complete(
            engine,
            restore,
            LumenWorkspaceCommandPayloadKind::None,
            None,
            true
        ),
        LumenEngineStatus::Ok
    );
    let verify = next(engine);
    assert_eq!(
        verify.kind,
        LumenWorkspaceCommandKind::VerifyPhysicalDisplays
    );
    assert_eq!(
        complete(
            engine,
            verify,
            LumenWorkspaceCommandPayloadKind::None,
            None,
            false
        ),
        LumenEngineStatus::CommandFailed
    );

    // Then: verification failure preserves the journal but independently destroys
    // the registry-owned virtual display exactly once.
    assert!(path.exists());
    let destroy = next(engine);
    assert_eq!(
        destroy.kind,
        LumenWorkspaceCommandKind::DestroyVirtualDisplay
    );
    let destroy_identity = payload_json(engine, destroy);
    assert!(!destroy_identity.is_empty());
    assert_eq!(
        complete(
            engine,
            destroy,
            LumenWorkspaceCommandPayloadKind::None,
            None,
            true
        ),
        LumenEngineStatus::Ok
    );
    assert_eq!(
        lumen_workspace_engine_next_command(engine, &mut LumenWorkspaceCommand::placeholder()),
        LumenEngineStatus::NoCommand
    );
    let RecoveryJournalLoad::Verified(preserved) = store.load().unwrap() else {
        panic!("expected preserved journal after failed verification");
    };
    assert_eq!(preserved.phase, RecoveryPhase::PhysicalRestored);
    // SAFETY: this engine was created above and has not been destroyed.
    unsafe { lumen_workspace_engine_destroy(engine) };
}
