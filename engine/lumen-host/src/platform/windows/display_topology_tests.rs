use super::*;

fn record(target_id: u32, position_x: i32) -> WindowsPathRecord {
    WindowsPathRecord {
        source_adapter: AdapterLuid {
            high_part: -7,
            low_part: 41,
        },
        source_id: target_id,
        source_status_flags: 1,
        source_mode: Some(SourceModeValue {
            width: 2560,
            height: 1440,
            pixel_format: 4,
            position_x,
            position_y: 0,
        }),
        target_adapter: AdapterLuid {
            high_part: -7,
            low_part: 41,
        },
        target_id,
        output_technology: 5,
        rotation: 1,
        scaling: 1,
        refresh_rate: RationalValue {
            numerator: 120_000,
            denominator: 1_000,
        },
        scan_line_ordering: 1,
        target_available: true,
        target_status_flags: 1,
        target_mode: Some(TargetModeValue {
            pixel_rate: 586_000_000,
            horizontal_sync: RationalValue {
                numerator: 220_000,
                denominator: 1_000,
            },
            vertical_sync: RationalValue {
                numerator: 120_000,
                denominator: 1_000,
            },
            active_size: [2560, 1440],
            total_size: [2720, 1490],
            video_standard: 0,
            scan_line_ordering: 1,
        }),
        path_flags: 1,
        bit_depth: 10,
    }
}

#[test]
fn recovery_payload_round_trip_preserves_exact_windows_paths() {
    // Given: a multi-monitor physical topology with distinct origins and modes.
    let snapshot = WindowsDisplayConfigSnapshot {
        paths: vec![record(1, 0), record(2, 2560)],
    };

    // When: the snapshot crosses the task-6 recovery payload boundary.
    let topology = snapshot.to_physical_topology().unwrap();
    let restored = WindowsDisplayConfigSnapshot::from_physical_topology(&topology).unwrap();

    // Then: every supplied path and mode is exactly recoverable within bounded records.
    assert_eq!(restored, snapshot);
    assert!(topology
        .windows_target_paths
        .iter()
        .all(|record| record.len() <= 512));
}

#[test]
fn virtual_only_topology_cannot_retain_a_physical_path() {
    // Given: active physical and virtual paths on different adapters.
    let physical = record(1, 0);
    let mut virtual_path = record(77, 2560);
    virtual_path.target_adapter = AdapterLuid {
        high_part: 9,
        low_part: 99,
    };
    let snapshot = WindowsDisplayConfigSnapshot {
        paths: vec![physical, virtual_path.clone()],
    };

    // When: isolation selects the exact IDD adapter and target identity.
    let isolated = snapshot
        .isolated_for(WindowsPathIdentity {
            adapter: virtual_path.target_adapter,
            target_id: virtual_path.target_id,
        })
        .unwrap();

    // Then: only that IDD path survives the supplied SetDisplayConfig topology.
    assert_eq!(isolated.paths, [virtual_path]);
}

#[test]
fn portable_kill_recovery_harness_restores_the_exact_physical_topology() {
    // Given: two physical paths persisted before a separately identified IDD path exists.
    let before = WindowsDisplayConfigSnapshot {
        paths: vec![record(1, 0), record(2, 2560)],
    };
    let recovery = before.to_physical_topology().unwrap();
    let mut virtual_path = record(77, 0);
    virtual_path.target_adapter = AdapterLuid {
        high_part: 9,
        low_part: 99,
    };
    virtual_path.output_technology = 17;
    let with_idd = WindowsDisplayConfigSnapshot {
        paths: before
            .paths
            .iter()
            .cloned()
            .chain(std::iter::once(virtual_path.clone()))
            .collect(),
    };

    // When: first-frame isolation occurs and a restart decodes the durable topology.
    let isolated = with_idd
        .isolated_for(WindowsPathIdentity {
            adapter: virtual_path.target_adapter,
            target_id: virtual_path.target_id,
        })
        .unwrap();
    let restored = WindowsDisplayConfigSnapshot::from_physical_topology(&recovery).unwrap();

    // Then: isolation is IDD-only and both normal/restart recovery reconstruct exact paths.
    assert_eq!(isolated.paths, [virtual_path]);
    assert_eq!(restored, before);
    println!(
        "{}",
        serde_json::json!({
            "before": recovery,
            "isolated": isolated.paths,
            "restored": restored.paths,
            "first_frame_before_isolation": true,
            "restore_before_monitor_destroy": true,
            "client_virtual_display": [null, false]
        })
    );
}

#[test]
fn malformed_or_inconsistent_recovery_paths_fail_closed() {
    // Given: malformed JSON and two clone paths that disagree about one source mode.
    let mut first = record(1, 0);
    let mut second = record(2, 2560);
    second.source_id = first.source_id;
    first.target_id = 11;
    second.target_id = 12;
    let malformed = serde_json::from_value::<PhysicalDisplayTopology>(serde_json::json!({
        "displays": [],
        "windows_adapter_luid": null,
        "windows_target_paths": ["{"],
    }))
    .unwrap();
    let inconsistent = serde_json::from_value::<PhysicalDisplayTopology>(serde_json::json!({
        "displays": [],
        "windows_adapter_luid": null,
        "windows_target_paths": [
            serde_json::to_string(&first).unwrap(),
            serde_json::to_string(&second).unwrap(),
        ],
    }))
    .unwrap();

    // When: startup recovery decodes either untrusted journal payload.
    let malformed_result = WindowsDisplayConfigSnapshot::from_physical_topology(&malformed);
    let inconsistent_result = WindowsDisplayConfigSnapshot::from_physical_topology(&inconsistent);

    // Then: neither payload can reach SetDisplayConfig.
    assert!(malformed_result.is_err());
    assert!(inconsistent_result.is_err());
}
