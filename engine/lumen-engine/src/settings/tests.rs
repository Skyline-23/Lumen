use super::*;
use tempfile::TempDir;

fn authority(platform: SettingsHostPlatform) -> (TempDir, SettingsAuthority) {
    let root = TempDir::new().unwrap();
    let authority = SettingsAuthority::open(
        root.path().join("settings.json"),
        SettingsCapabilities::for_platform(platform),
    )
    .unwrap();
    (root, authority)
}

fn patch_request(
    base_revision: u64,
    request_id: &str,
    changes: SettingsChanges,
) -> SettingsPatchRequest {
    SettingsPatchRequest {
        schema_version: SETTINGS_SCHEMA_VERSION,
        base_revision,
        request_id: request_id.to_owned(),
        changes,
    }
}

#[test]
fn patch_is_host_revisioned_and_live_values_are_effective_after_ack() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    let response = authority
        .apply_patch(SettingsPatchRequest {
            schema_version: 1,
            base_revision: 1,
            request_id: "request-live-1".to_owned(),
            changes: SettingsChanges {
                general: Some(GeneralChanges {
                    host_name: Some("Studio Host".to_owned()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        })
        .unwrap();

    assert_eq!(response.revision, 2);
    assert_eq!(response.apply_state, SettingsApplyState::Applied);
    assert_eq!(response.requires, SettingsApplyRequirement::None);
    assert_eq!(response.effective.general.host_name, "Studio Host");
}

#[test]
fn conformance_fixture_matches_runtime_field_catalog_and_constraints() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../docs/protocol/lumen-settings-conformance.json"
    ))
    .unwrap();
    assert_eq!(fixture["schemaVersion"], SETTINGS_SCHEMA_VERSION);
    assert_eq!(
        fixture["commandContract"]["execution"],
        "argv-without-shell"
    );
    assert_eq!(fixture["retention"]["events"], MAXIMUM_RETAINED_EVENTS);
    assert_eq!(
        fixture["retention"]["idempotencyRecords"],
        MAXIMUM_RETAINED_REQUESTS
    );
    assert_eq!(fixture["requestId"]["maximumLength"], 128);
    assert_eq!(fixture["networkTransport"]["scheme"], "https");
    assert_eq!(
        fixture["networkTransport"]["routes"]["snapshot"]["path"],
        "/api/v1/settings"
    );
    assert_eq!(
        fixture["networkTransport"]["routes"]["snapshot"]["method"],
        "GET"
    );
    assert_eq!(
        fixture["networkTransport"]["routes"]["patch"]["method"],
        "PATCH"
    );
    assert_eq!(
        fixture["networkTransport"]["routes"]["events"]["path"],
        "/api/v1/settings/events"
    );
    assert_eq!(
        fixture["networkTransport"]["routes"]["events"]["resumeQuery"],
        "afterRevision"
    );
    assert_eq!(
        fixture["errorCodes"],
        serde_json::json!([
            SettingsErrorCode::UnsupportedSchema.as_str(),
            SettingsErrorCode::InvalidRequest.as_str(),
            SettingsErrorCode::UnknownField.as_str(),
            SettingsErrorCode::ForbiddenField.as_str(),
            SettingsErrorCode::UnavailableField.as_str(),
            SettingsErrorCode::InvalidValue.as_str(),
            SettingsErrorCode::StaleRevision.as_str(),
            SettingsErrorCode::RequestIdConflict.as_str(),
            SettingsErrorCode::RevisionNotRetained.as_str(),
            SettingsErrorCode::StorageError.as_str(),
            SettingsErrorCode::CorruptData.as_str(),
        ])
    );
    let fields = field_catalog();
    let fixture_fields = fixture["fields"].as_array().unwrap();
    assert_eq!(fixture_fields.len(), fields.len());
    for fixture_field in fixture_fields {
        let key = fixture_field["key"].as_str().unwrap();
        let runtime = fields
            .get(key)
            .unwrap_or_else(|| panic!("missing runtime field {key}"));
        assert_eq!(fixture_field["type"], runtime.field_type.as_str());
        assert_eq!(fixture_field["applyClass"], runtime.apply_class.as_str());
        let values: Vec<_> = fixture_field["values"]
            .as_array()
            .map(|values| {
                values
                    .iter()
                    .map(|value| value.as_str().unwrap().to_owned())
                    .collect()
            })
            .unwrap_or_default();
        assert_eq!(values, runtime.allowed_values, "enum values for {key}");
        assert_eq!(
            fixture_field
                .get("minimum")
                .and_then(|value| value.as_i64()),
            runtime.minimum
        );
        assert_eq!(
            fixture_field
                .get("maximum")
                .and_then(|value| value.as_i64()),
            runtime.maximum
        );
        assert_eq!(
            fixture_field
                .get("maxLength")
                .and_then(|value| value.as_u64())
                .map(|value| value as u32),
            runtime.max_length
        );
        assert_eq!(
            fixture_field
                .get("pattern")
                .and_then(|value| value.as_str())
                .map(str::to_owned),
            runtime.pattern
        );
    }
    assert!(fields.contains_key("general.updateChannel"));
    assert!(fields.contains_key("general.notifyPreReleases"));
    let windows = SettingsCapabilities::for_platform(SettingsHostPlatform::Windows);
    assert_eq!(
        fixture["platformCapabilities"]["windows"]["workspace.policy"]["available"],
        windows.fields["workspace.policy"].available
    );
}

#[test]
fn local_reconciliation_preserves_unapplied_desired_values() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    authority
        .apply_patch(patch_request(
            1,
            "pending-before-local-1",
            SettingsChanges {
                general: Some(GeneralChanges {
                    host_name: Some("Remote Host".to_owned()),
                    ..Default::default()
                }),
                streaming: Some(StreamingChanges {
                    fallback_display_mode: Some("2560x1440x120".to_owned()),
                    ..Default::default()
                }),
                network: Some(NetworkChanges {
                    port: Some(48_200),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap();
    let pending = authority.snapshot();
    assert_eq!(pending.settings.streaming.fallback_display_mode, "2560x1440x120");
    assert_ne!(pending.effective.streaming.fallback_display_mode, "2560x1440x120");
    assert_eq!(pending.settings.network.port, 48_200);
    assert_ne!(pending.effective.network.port, 48_200);

    let mut local_runtime = pending.effective.clone();
    local_runtime.input.mouse = false;
    let reconciled = authority.apply_local_update(local_runtime).unwrap();

    assert_eq!(reconciled.settings.general.host_name, "Remote Host");
    assert!(!reconciled.settings.input.mouse);
    assert!(!reconciled.effective.input.mouse);
    assert_eq!(reconciled.settings.streaming.fallback_display_mode, "2560x1440x120");
    assert_ne!(reconciled.effective.streaming.fallback_display_mode, "2560x1440x120");
    assert_eq!(reconciled.settings.network.port, 48_200);
    assert_ne!(reconciled.effective.network.port, 48_200);
    assert_eq!(
        reconciled.apply_state,
        SettingsApplyState::PendingWorkerRestart
    );
}

#[test]
fn invalid_field_rejects_the_entire_patch_without_revision_or_partial_write() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    let error = authority
        .apply_patch(patch_request(
            1,
            "atomic-invalid-1",
            SettingsChanges {
                general: Some(GeneralChanges {
                    host_name: Some("Must Not Persist".to_owned()),
                    ..Default::default()
                }),
                network: Some(NetworkChanges {
                    port: Some(1_028),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap_err();

    assert_eq!(error.code, SettingsErrorCode::InvalidValue);
    assert_eq!(error.field.as_deref(), Some("network.port"));
    assert_eq!(authority.snapshot().revision, 1);
    assert_eq!(authority.snapshot().settings.general.host_name, "Lumen");
}

#[test]
fn stale_revision_is_typed_and_accepted_retry_is_durable_and_idempotent() {
    let root = TempDir::new().unwrap();
    let path = root.path().join("settings.json");
    let mut authority = SettingsAuthority::open(
        &path,
        SettingsCapabilities::for_platform(SettingsHostPlatform::Macos),
    )
    .unwrap();
    let request = patch_request(
        1,
        "durable-idempotency-1",
        SettingsChanges {
            general: Some(GeneralChanges {
                discovery: Some(false),
                ..Default::default()
            }),
            ..Default::default()
        },
    );
    let accepted = authority.apply_patch(request.clone()).unwrap();
    assert_eq!(accepted.revision, 2);

    let stale = authority
        .apply_patch(patch_request(
            1,
            "stale-2",
            SettingsChanges {
                general: Some(GeneralChanges {
                    host_name: Some("Stale".to_owned()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap_err();
    assert_eq!(stale.code, SettingsErrorCode::StaleRevision);
    assert_eq!(stale.current_revision, Some(2));

    drop(authority);
    let mut reopened = SettingsAuthority::open(
        &path,
        SettingsCapabilities::for_platform(SettingsHostPlatform::Macos),
    )
    .unwrap();
    assert_eq!(reopened.apply_patch(request.clone()).unwrap(), accepted);
    let conflict = reopened
        .apply_patch(SettingsPatchRequest {
            changes: SettingsChanges {
                general: Some(GeneralChanges {
                    discovery: Some(true),
                    ..Default::default()
                }),
                ..Default::default()
            },
            ..request
        })
        .unwrap_err();
    assert_eq!(conflict.code, SettingsErrorCode::RequestIdConflict);
    assert_eq!(reopened.snapshot().revision, 2);
}

#[test]
fn next_session_and_worker_restart_values_remain_pending_until_reported_applied() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    let response = authority
        .apply_patch(patch_request(
            1,
            "apply-classes-1",
            SettingsChanges {
                streaming: Some(StreamingChanges {
                    fallback_display_mode: Some("2560x1440x120".to_owned()),
                    ..Default::default()
                }),
                network: Some(NetworkChanges {
                    port: Some(48_000),
                    ..Default::default()
                }),
                diagnostics: Some(DiagnosticsChanges {
                    log_level: Some(LogLevel::Debug),
                }),
                ..Default::default()
            },
        ))
        .unwrap();
    assert_eq!(
        response.apply_state,
        SettingsApplyState::PendingWorkerRestart
    );
    assert_eq!(response.requires, SettingsApplyRequirement::WorkerRestart);
    assert_eq!(response.effective.diagnostics.log_level, LogLevel::Debug);
    assert_eq!(response.effective.streaming.fallback_display_mode, "1920x1080x60");
    assert_eq!(response.effective.network.port, 47_989);

    let next_session = authority.mark_next_session_started().unwrap();
    assert_eq!(next_session.revision, 3);
    assert_eq!(next_session.effective.streaming.fallback_display_mode, "2560x1440x120");
    assert_eq!(next_session.effective.network.port, 47_989);
    assert_eq!(
        next_session.apply_state,
        SettingsApplyState::PendingWorkerRestart
    );

    let restarted = authority.mark_worker_restarted().unwrap();
    assert_eq!(restarted.revision, 4);
    assert_eq!(restarted.effective.network.port, 48_000);
    assert_eq!(restarted.apply_state, SettingsApplyState::Applied);
}

#[test]
fn pushed_updates_are_revisioned_and_resumable() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    authority
        .apply_patch(patch_request(
            1,
            "event-1",
            SettingsChanges {
                input: Some(InputChanges {
                    mouse: Some(false),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap();
    let mut locally_edited = authority.snapshot().settings;
    locally_edited.general.notify_pre_releases = true;
    let local = authority.apply_local_update(locally_edited).unwrap();
    assert_eq!(local.revision, 3);

    let events = authority.events_since(1).unwrap();
    assert_eq!(
        events
            .iter()
            .map(|event| event.revision)
            .collect::<Vec<_>>(),
        vec![2, 3]
    );
    assert!(!events[0].settings.input.mouse);
    assert!(events[1].settings.general.notify_pre_releases);
    assert!(authority.events_since(3).unwrap().is_empty());
    let future = authority.events_since(4).unwrap_err();
    assert_eq!(future.code, SettingsErrorCode::StaleRevision);
    assert_eq!(future.current_revision, Some(3));
    assert_eq!(
        authority.events_since(0).unwrap_err().code,
        SettingsErrorCode::RevisionNotRetained
    );
}

#[test]
fn bounded_event_history_requires_snapshot_only_after_resume_point_expires() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    for index in 0..130_u64 {
        let revision = authority.snapshot().revision;
        authority
            .apply_patch(patch_request(
                revision,
                &format!("retention-{index}"),
                SettingsChanges {
                    general: Some(GeneralChanges {
                        discovery: Some(index % 2 == 0),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ))
            .unwrap();
    }
    assert_eq!(authority.snapshot().revision, 131);
    let expired = authority.events_since(2).unwrap_err();
    assert_eq!(expired.code, SettingsErrorCode::RevisionNotRetained);
    assert_eq!(expired.current_revision, Some(131));
    let retained = authority.events_since(3).unwrap();
    assert_eq!(retained.len(), MAXIMUM_RETAINED_EVENTS);
    assert_eq!(retained.first().unwrap().revision, 4);
    assert_eq!(retained.last().unwrap().revision, 131);
}

#[test]
fn unknown_secret_path_and_control_location_fields_are_rejected_before_decode() {
    let unknown = SettingsAuthority::decode_patch_request(
        r#"{
          "schemaVersion":1,"baseRevision":1,"requestId":"unknown-1",
          "changes":{"general":{"notASetting":true}}
        }"#,
    )
    .unwrap_err();
    assert_eq!(unknown.code, SettingsErrorCode::UnknownField);

    for (key, value) in [
        ("credentialsFilePath", r#""/tmp/credentials""#),
        ("ownerPassword", r#""secret""#),
        ("refreshToken", r#""token""#),
        ("controlLocation", r#""client""#),
        ("remoteSettingsAllowed", "true"),
        ("deviceEnrollmentEnabled", "false"),
    ] {
        let json = format!(
            r#"{{"schemaVersion":1,"baseRevision":1,"requestId":"forbidden-{key}","changes":{{"general":{{"{key}":{value}}}}}}}"#
        );
        let error = SettingsAuthority::decode_patch_request(&json).unwrap_err();
        assert_eq!(error.code, SettingsErrorCode::ForbiddenField, "{key}");
    }
}

#[test]
fn host_capabilities_hide_and_reject_unsupported_workspace_policy() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Windows);
    let capability = &authority.snapshot().capabilities.fields["workspace.policy"];
    assert!(!capability.available);
    assert!(capability
        .unavailable_reason
        .as_deref()
        .unwrap()
        .contains("macOS"));
    let error = authority
        .apply_patch(patch_request(
            1,
            "windows-workspace-1",
            SettingsChanges {
                workspace: Some(WorkspaceChanges {
                    policy: Some(WorkspacePolicy::FocusedWorkspace),
                }),
                ..Default::default()
            },
        ))
        .unwrap_err();
    assert_eq!(error.code, SettingsErrorCode::UnavailableField);
    assert_eq!(authority.snapshot().revision, 1);
}

#[test]
fn commands_require_explicit_privilege_and_use_injection_safe_argv_shape() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Windows);
    let command = ServerCommand {
        name: "Prepare stream".to_owned(),
        invocation: CommandInvocation {
            program: "lumen-tool".to_owned(),
            arguments: vec!["prepare".to_owned(), "literal;argument".to_owned()],
        },
        privilege: CommandPrivilege::Administrator,
    };
    let response = authority
        .apply_patch(patch_request(
            1,
            "commands-safe-1",
            SettingsChanges {
                commands: Some(CommandsChanges {
                    server: Some(vec![command]),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap();
    assert_eq!(
        response.apply_state,
        SettingsApplyState::PendingWorkerRestart
    );

    let missing_privilege = SettingsAuthority::decode_patch_request(r#"{
          "schemaVersion":1,"baseRevision":2,"requestId":"commands-missing-privilege",
          "changes":{"commands":{"server":[{"name":"bad","invocation":{"program":"tool","arguments":[]}}]}}
        }"#).unwrap_err();
    assert_eq!(missing_privilege.code, SettingsErrorCode::InvalidRequest);

    let error = authority
        .apply_patch(patch_request(
            2,
            "commands-shell-2",
            SettingsChanges {
                commands: Some(CommandsChanges {
                    server: Some(vec![ServerCommand {
                        name: "unsafe".to_owned(),
                        invocation: CommandInvocation {
                            program: "sh".to_owned(),
                            arguments: vec!["-c".to_owned(), "echo injected".to_owned()],
                        },
                        privilege: CommandPrivilege::User,
                    }]),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap_err();
    assert_eq!(error.code, SettingsErrorCode::InvalidValue);
    assert_eq!(error.field.as_deref(), Some("commands.program"));
}

#[test]
fn command_privilege_is_host_capability_driven() {
    let macos = SettingsCapabilities::for_platform(SettingsHostPlatform::Macos);
    let windows = SettingsCapabilities::for_platform(SettingsHostPlatform::Windows);
    for field in ["commands.prep", "commands.state", "commands.server"] {
        assert!(macos.fields[field].available);
        assert_eq!(macos.fields[field].allowed_values, ["user"]);
        assert_eq!(
            windows.fields[field].allowed_values,
            ["user", "administrator"]
        );
    }

    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    let error = authority
        .apply_patch(patch_request(
            1,
            "macos-admin-command-1",
            SettingsChanges {
                commands: Some(CommandsChanges {
                    prep: Some(vec![PrepCommand {
                        run: CommandInvocation {
                            program: "lumen-prep".to_owned(),
                            arguments: vec!["literal;argument".to_owned()],
                        },
                        undo: None,
                        privilege: CommandPrivilege::Administrator,
                    }]),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap_err();
    assert_eq!(error.code, SettingsErrorCode::InvalidValue);
    assert_eq!(error.field.as_deref(), Some("commands.prep"));
    assert_eq!(authority.snapshot().revision, 1);
}

#[test]
fn factory_reset_removes_durable_settings_and_request_history() {
    let root = TempDir::new().unwrap();
    let path = root.path().join("settings.json");
    let mut authority = SettingsAuthority::open(
        &path,
        SettingsCapabilities::for_platform(SettingsHostPlatform::Macos),
    )
    .unwrap();
    authority
        .apply_patch(patch_request(
            1,
            "reset-me-1",
            SettingsChanges {
                general: Some(GeneralChanges {
                    host_name: Some("Before Reset".to_owned()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap();
    assert!(path.exists());
    authority.factory_reset().unwrap();
    assert!(!path.exists());
    assert_eq!(authority.snapshot().revision, 1);
    assert_eq!(authority.snapshot().settings, HostSettings::default());

    let retry_after_reset = authority
        .apply_patch(patch_request(
            1,
            "reset-me-1",
            SettingsChanges {
                general: Some(GeneralChanges {
                    host_name: Some("After Reset".to_owned()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap();
    assert_eq!(retry_after_reset.revision, 2);
    assert_eq!(retry_after_reset.effective.general.host_name, "After Reset");
}

#[test]
fn corrupt_or_internally_inconsistent_persisted_authority_is_rejected() {
    let root = TempDir::new().unwrap();
    let path = root.path().join("settings.json");
    let mut authority = SettingsAuthority::open(
        &path,
        SettingsCapabilities::for_platform(SettingsHostPlatform::Macos),
    )
    .unwrap();
    authority
        .apply_patch(patch_request(
            1,
            "persisted-corruption-1",
            SettingsChanges {
                streaming: Some(StreamingChanges {
                    fallback_display_mode: Some("2560x1440x120".to_owned()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        ))
        .unwrap();
    drop(authority);

    let mut persisted: serde_json::Value =
        serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    persisted["applyState"] = serde_json::json!("applied");
    fs::write(&path, serde_json::to_vec_pretty(&persisted).unwrap()).unwrap();
    let error = SettingsAuthority::open(
        &path,
        SettingsCapabilities::for_platform(SettingsHostPlatform::Macos),
    )
    .unwrap_err();
    assert_eq!(error.code, SettingsErrorCode::CorruptData);
}

#[test]
fn unsupported_schema_empty_patch_and_invalid_enums_are_typed_errors() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    let unsupported = authority
        .apply_patch(SettingsPatchRequest {
            schema_version: 2,
            base_revision: 1,
            request_id: "schema-2".to_owned(),
            changes: SettingsChanges {
                general: Some(GeneralChanges {
                    discovery: Some(false),
                    ..Default::default()
                }),
                ..Default::default()
            },
        })
        .unwrap_err();
    assert_eq!(unsupported.code, SettingsErrorCode::UnsupportedSchema);

    let empty = authority
        .apply_patch(patch_request(1, "empty-1", SettingsChanges::default()))
        .unwrap_err();
    assert_eq!(empty.code, SettingsErrorCode::InvalidRequest);
    let invalid_enum = SettingsAuthority::decode_patch_request(
        r#"{
          "schemaVersion":1,"baseRevision":1,"requestId":"enum-1",
          "changes":{"network":{"addressFamily":"ipx"}}
        }"#,
    )
    .unwrap_err();
    assert_eq!(invalid_enum.code, SettingsErrorCode::InvalidValue);
}

#[test]
fn protocol_snapshots_never_contain_internal_paths_secrets_or_control_selector() {
    let (_root, authority) = authority(SettingsHostPlatform::Macos);
    let json = serde_json::to_string(&authority.snapshot()).unwrap();
    for forbidden in [
        "applicationsFilePath",
        "credentialsFilePath",
        "certificatePath",
        "privateKeyPath",
        "logFilePath",
        "stateFilePath",
        "ownerPassword",
        "refreshToken",
        "remoteSettingsAllowed",
        "controlLocation",
        "deviceEnrollmentEnabled",
        "systemAuthenticationEnabled",
    ] {
        assert!(!json.contains(forbidden), "snapshot exposed {forbidden}");
    }
}

#[test]
fn complete_portable_patch_round_trips_every_supported_non_file_setting() {
    let (_root, mut authority) = authority(SettingsHostPlatform::Macos);
    let mut expected = HostSettings::default();
    expected.workspace.policy = WorkspacePolicy::FocusedWorkspace;
    expected.general.locale = "ko-KR".to_owned();
    expected.general.host_name = "Studio Lumen".to_owned();
    expected.general.discovery = false;
    expected.general.update_channel = UpdateChannel::PreRelease;
    expected.general.notify_pre_releases = true;
    expected.streaming.adapter_selector = "adapter-0".to_owned();
    expected.streaming.output_selector = "output-1".to_owned();
    expected.streaming.fallback_display_mode = "2560x1440x119.88".to_owned();
    expected.audio.sink = "sink-main".to_owned();
    expected.audio.stream_audio = false;
    expected.input.keyboard = false;
    expected.input.mouse = false;
    expected.input.controller = false;
    expected.input.back_button_timeout_ms = 2_500;
    expected.input.map_right_alt_to_windows_key = true;
    expected.input.high_resolution_scrolling = false;
    expected.input.native_pen_touch = false;
    expected.input.rumble_forwarding = false;
    expected.network.address_family = AddressFamily::Both;
    expected.network.port = 48_000;
    expected.network.upnp = true;
    expected.network.remote_access_scope = RemoteAccessScope::Wan;
    expected.network.external_ip = "203.0.113.10".to_owned();
    expected.network.lan_encryption = EncryptionMode::Required;
    expected.network.wan_encryption = EncryptionMode::Required;
    expected.network.ping_timeout_ms = 20_000;
    expected.network.fec_percentage = 30;
    expected.diagnostics.log_level = LogLevel::Warning;
    expected.commands.prep = vec![PrepCommand {
        run: CommandInvocation {
            program: "lumen-prep".to_owned(),
            arguments: vec!["start".to_owned()],
        },
        undo: Some(CommandInvocation {
            program: "lumen-prep".to_owned(),
            arguments: vec!["stop".to_owned()],
        }),
        privilege: CommandPrivilege::User,
    }];
    expected.commands.state = vec![PrepCommand {
        run: CommandInvocation {
            program: "lumen-state".to_owned(),
            arguments: vec!["active".to_owned()],
        },
        undo: None,
        privilege: CommandPrivilege::User,
    }];
    expected.commands.server = vec![ServerCommand {
        name: "Open overlay".to_owned(),
        invocation: CommandInvocation {
            program: "lumen-control".to_owned(),
            arguments: vec!["overlay".to_owned()],
        },
        privilege: CommandPrivilege::User,
    }];

    let response = authority
        .apply_patch(patch_request(
            1,
            "complete-portable-1",
            full_changes(&expected),
        ))
        .unwrap();
    assert_eq!(response.requires, SettingsApplyRequirement::WorkerRestart);
    assert_eq!(authority.snapshot().settings, expected);
    assert_ne!(authority.snapshot().effective, expected);
    assert_eq!(
        authority.mark_worker_restarted().unwrap().effective,
        expected
    );
}
