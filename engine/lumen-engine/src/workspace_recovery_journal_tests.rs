use super::*;

fn topology() -> PhysicalDisplayTopology {
    PhysicalDisplayTopology {
        displays: vec![PhysicalDisplayState {
            id: "physical-1".to_owned(),
            mode: PhysicalDisplayMode {
                width: 3840,
                height: 2160,
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
        windows_adapter_luid: Some(WindowsAdapterLuid {
            high_part: 0x0102_0304,
            low_part: 0x0506_0708,
        }),
        windows_target_paths: vec!["DISPLAYCONFIG_PATH_INFO:0".to_owned()],
    }
}

fn journal(generation: u64) -> WorkspaceRecoveryJournal {
    WorkspaceRecoveryJournal::new(
        WorkspaceRecoveryMetadata {
            platform: WorkspacePlatform::Windows,
            generation,
            session_id: "session-42".to_owned(),
            timestamp_unix_ms: 1_784_000_000_000,
            capture_managed: true,
        },
        topology(),
    )
    .unwrap()
}

#[test]
fn journal_round_trip_preserves_versioned_topology_and_checksum() {
    // Given: a recovery store and a complete cross-platform topology snapshot.
    let directory = tempfile::tempdir().unwrap();
    let store = RecoveryJournalStore::new(directory.path().join("display-recovery.json"));
    let expected = journal(42);

    // When: the journal is atomically created and loaded.
    store.create(&expected).unwrap();
    let loaded = store.load().unwrap();

    // Then: a verified journal preserves all recovery-critical fields.
    assert_eq!(loaded, RecoveryJournalLoad::Verified(expected));
    let serialized = std::fs::read_to_string(store.path()).unwrap();
    assert!(serialized.contains("\"schema_version\": 2"));
    assert!(serialized.contains("\"checksum_sha256\""));
}

#[test]
fn malformed_checksum_is_quarantined_with_a_typed_warning() {
    // Given: a journal whose serialized payload no longer matches its checksum.
    let directory = tempfile::tempdir().unwrap();
    let store = RecoveryJournalStore::new(directory.path().join("display-recovery.json"));
    store.create(&journal(7)).unwrap();
    let bytes = std::fs::read(store.path()).unwrap();
    let mut envelope: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    envelope["checksum_sha256"] = serde_json::Value::String("0".repeat(64));
    std::fs::write(store.path(), serde_json::to_vec_pretty(&envelope).unwrap()).unwrap();

    // When: startup loads the corrupted journal.
    let loaded = store.load().unwrap();

    // Then: the active path is cleared and the typed checksum warning names quarantine.
    let RecoveryJournalLoad::Quarantined(warning) = loaded else {
        panic!("expected quarantined recovery journal");
    };
    assert_eq!(warning.code, RecoveryWarningCode::ChecksumMismatch);
    assert!(!store.path().exists());
    assert!(warning.quarantined_path.exists());
}

#[test]
fn truncated_journal_is_quarantined_without_panicking() {
    // Given: a truncated recovery envelope at the active path.
    let directory = tempfile::tempdir().unwrap();
    let store = RecoveryJournalStore::new(directory.path().join("display-recovery.json"));
    std::fs::write(store.path(), b"{\"schema_version\":1").unwrap();

    // When: startup attempts to parse the untrusted bytes.
    let loaded = store.load().unwrap();

    // Then: malformed data becomes a typed quarantine result.
    let RecoveryJournalLoad::Quarantined(warning) = loaded else {
        panic!("expected quarantined recovery journal");
    };
    assert_eq!(warning.code, RecoveryWarningCode::MalformedJournal);
}

#[test]
fn stale_generation_cannot_replace_a_newer_journal() {
    // Given: an active generation-seven journal.
    let directory = tempfile::tempdir().unwrap();
    let store = RecoveryJournalStore::new(directory.path().join("display-recovery.json"));
    let current = journal(7);
    store.create(&current).unwrap();

    // When: an interrupted stale generation attempts a phase update.
    let stale = journal(6).with_phase(RecoveryPhase::VirtualCreated);
    let error = store.update(&stale).unwrap_err();

    // Then: the update is rejected and the current generation remains verified.
    assert_eq!(
        error,
        RecoveryJournalError::StaleGeneration {
            expected: 7,
            actual: 6,
        }
    );
    assert_eq!(
        store.load().unwrap(),
        RecoveryJournalLoad::Verified(current)
    );
}

#[test]
fn atomic_install_uses_platform_durability_contracts() {
    // Given: the recovery store source compiled for Unix and Windows targets.
    let source = include_str!("workspace_recovery_journal.rs");

    // When: the platform-specific install boundaries are inspected.
    let windows_write_through =
        source.contains("MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH");
    let windows_flushes_installed =
        source.contains("RecoveryJournalError::Storage(\"flush-installed\")");
    let unix_syncs_parent = source.contains("sync_parent(parent)");

    // Then: Windows and Unix both preserve their strongest supported durability ordering.
    assert!(source.contains("MoveFileExW"));
    assert!(windows_write_through);
    assert!(windows_flushes_installed);
    assert!(unix_syncs_parent);
}
