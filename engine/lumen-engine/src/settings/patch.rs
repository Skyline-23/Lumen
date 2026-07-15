use super::*;

impl SettingsChanges {
    pub(super) fn field_keys(&self) -> Vec<&'static str> {
        let mut keys = Vec::new();
        if let Some(group) = &self.workspace {
            push_key(&mut keys, group.policy.is_some(), "workspace.policy");
        }
        if let Some(group) = &self.general {
            push_key(&mut keys, group.name.is_some(), "general.name");
            push_key(&mut keys, group.discovery.is_some(), "general.discovery");
            push_key(
                &mut keys,
                group.update_channel.is_some(),
                "general.updateChannel",
            );
            push_key(
                &mut keys,
                group.notify_pre_releases.is_some(),
                "general.notifyPreReleases",
            );
        }
        if let Some(group) = &self.streaming {
            push_key(
                &mut keys,
                group.adapter_selector.is_some(),
                "streaming.adapterSelector",
            );
            push_key(
                &mut keys,
                group.output_selector.is_some(),
                "streaming.outputSelector",
            );
            push_key(
                &mut keys,
                group.fallback_display_mode.is_some(),
                "streaming.fallbackDisplayMode",
            );
        }
        if let Some(group) = &self.audio {
            push_key(&mut keys, group.sink.is_some(), "audio.sink");
            push_key(&mut keys, group.stream_audio.is_some(), "audio.streamAudio");
        }
        if let Some(group) = &self.input {
            push_key(&mut keys, group.keyboard.is_some(), "input.keyboard");
            push_key(&mut keys, group.mouse.is_some(), "input.mouse");
            push_key(&mut keys, group.controller.is_some(), "input.controller");
            push_key(
                &mut keys,
                group.back_button_timeout_ms.is_some(),
                "input.backButtonTimeoutMs",
            );
            push_key(
                &mut keys,
                group.map_right_alt_to_windows_key.is_some(),
                "input.mapRightAltToWindowsKey",
            );
            push_key(
                &mut keys,
                group.high_resolution_scrolling.is_some(),
                "input.highResolutionScrolling",
            );
            push_key(
                &mut keys,
                group.native_pen_touch.is_some(),
                "input.nativePenTouch",
            );
            push_key(
                &mut keys,
                group.rumble_forwarding.is_some(),
                "input.rumbleForwarding",
            );
        }
        if let Some(group) = &self.network {
            push_key(
                &mut keys,
                group.address_family.is_some(),
                "network.addressFamily",
            );
            push_key(&mut keys, group.port.is_some(), "network.port");
            push_key(&mut keys, group.upnp.is_some(), "network.upnp");
            push_key(
                &mut keys,
                group.remote_access_scope.is_some(),
                "network.remoteAccessScope",
            );
            push_key(
                &mut keys,
                group.external_ip_mode.is_some(),
                "network.externalIpMode",
            );
            push_key(
                &mut keys,
                group.lan_encryption.is_some(),
                "network.lanEncryption",
            );
            push_key(
                &mut keys,
                group.wan_encryption.is_some(),
                "network.wanEncryption",
            );
            push_key(
                &mut keys,
                group.ping_timeout_ms.is_some(),
                "network.pingTimeoutMs",
            );
            push_key(
                &mut keys,
                group.fec_percentage.is_some(),
                "network.fecPercentage",
            );
        }
        if let Some(group) = &self.diagnostics {
            push_key(&mut keys, group.log_level.is_some(), "diagnostics.logLevel");
        }
        if let Some(group) = &self.commands {
            push_key(&mut keys, group.prep.is_some(), "commands.prep");
            push_key(&mut keys, group.state.is_some(), "commands.state");
            push_key(&mut keys, group.server.is_some(), "commands.server");
        }
        keys
    }
}

pub(super) fn push_key(keys: &mut Vec<&'static str>, present: bool, key: &'static str) {
    if present {
        keys.push(key);
    }
}

pub(super) fn validate_capability_values(
    settings: &HostSettings,
    changed_fields: &[&str],
    capabilities: &SettingsCapabilities,
) -> Result<(), SettingsProtocolError> {
    for field_key in changed_fields {
        if matches!(
            *field_key,
            "commands.prep" | "commands.state" | "commands.server"
        ) {
            let capability = &capabilities.fields[*field_key];
            let privileges: Vec<&str> = match *field_key {
                "commands.prep" => settings
                    .commands
                    .prep
                    .iter()
                    .map(|command| command.privilege.as_str())
                    .collect(),
                "commands.state" => settings
                    .commands
                    .state
                    .iter()
                    .map(|command| command.privilege.as_str())
                    .collect(),
                "commands.server" => settings
                    .commands
                    .server
                    .iter()
                    .map(|command| command.privilege.as_str())
                    .collect(),
                _ => unreachable!(),
            };
            if privileges.iter().any(|privilege| {
                !capability
                    .allowed_values
                    .iter()
                    .any(|allowed| allowed == privilege)
            }) {
                return Err(SettingsProtocolError::field(
                    SettingsErrorCode::InvalidValue,
                    *field_key,
                    "command privilege is not supported by this host",
                ));
            }
            continue;
        }
        let Some(value) = enum_value(settings, field_key) else {
            continue;
        };
        let Some(capability) = capabilities.fields.get(*field_key) else {
            continue;
        };
        if !capability.allowed_values.is_empty()
            && !capability
                .allowed_values
                .iter()
                .any(|allowed| allowed == value)
        {
            return Err(SettingsProtocolError::field(
                SettingsErrorCode::InvalidValue,
                *field_key,
                "enum value is not supported by this host",
            ));
        }
    }
    Ok(())
}

pub(super) fn enum_value<'a>(settings: &'a HostSettings, field_key: &str) -> Option<&'a str> {
    match field_key {
        "workspace.policy" => Some(settings.workspace.policy.as_str()),
        "general.updateChannel" => Some(settings.general.update_channel.as_str()),
        "streaming.adapterSelector" => Some(&settings.streaming.adapter_selector),
        "streaming.outputSelector" => Some(&settings.streaming.output_selector),
        "streaming.fallbackDisplayMode" => Some(&settings.streaming.fallback_display_mode),
        "audio.sink" => Some(&settings.audio.sink),
        "network.addressFamily" => Some(settings.network.address_family.as_str()),
        "network.remoteAccessScope" => Some(settings.network.remote_access_scope.as_str()),
        "network.externalIpMode" => Some(settings.network.external_ip_mode.as_str()),
        "network.lanEncryption" => Some(settings.network.lan_encryption.as_str()),
        "network.wanEncryption" => Some(settings.network.wan_encryption.as_str()),
        "diagnostics.logLevel" => Some(settings.diagnostics.log_level.as_str()),
        _ => None,
    }
}

pub(super) fn apply_changes(
    target: &mut HostSettings,
    changes: &SettingsChanges,
    include: impl Fn(&str) -> bool,
) {
    macro_rules! assign {
        ($change:expr, $target:expr, $key:literal) => {
            if include($key) {
                if let Some(value) = &$change {
                    $target = value.clone();
                }
            }
        };
    }
    if let Some(group) = &changes.workspace {
        assign!(group.policy, target.workspace.policy, "workspace.policy");
    }
    if let Some(group) = &changes.general {
        assign!(group.name, target.general.name, "general.name");
        assign!(
            group.discovery,
            target.general.discovery,
            "general.discovery"
        );
        assign!(
            group.update_channel,
            target.general.update_channel,
            "general.updateChannel"
        );
        assign!(
            group.notify_pre_releases,
            target.general.notify_pre_releases,
            "general.notifyPreReleases"
        );
    }
    if let Some(group) = &changes.streaming {
        assign!(
            group.adapter_selector,
            target.streaming.adapter_selector,
            "streaming.adapterSelector"
        );
        assign!(
            group.output_selector,
            target.streaming.output_selector,
            "streaming.outputSelector"
        );
        assign!(
            group.fallback_display_mode,
            target.streaming.fallback_display_mode,
            "streaming.fallbackDisplayMode"
        );
    }
    if let Some(group) = &changes.audio {
        assign!(group.sink, target.audio.sink, "audio.sink");
        assign!(
            group.stream_audio,
            target.audio.stream_audio,
            "audio.streamAudio"
        );
    }
    if let Some(group) = &changes.input {
        assign!(group.keyboard, target.input.keyboard, "input.keyboard");
        assign!(group.mouse, target.input.mouse, "input.mouse");
        assign!(
            group.controller,
            target.input.controller,
            "input.controller"
        );
        assign!(
            group.back_button_timeout_ms,
            target.input.back_button_timeout_ms,
            "input.backButtonTimeoutMs"
        );
        assign!(
            group.map_right_alt_to_windows_key,
            target.input.map_right_alt_to_windows_key,
            "input.mapRightAltToWindowsKey"
        );
        assign!(
            group.high_resolution_scrolling,
            target.input.high_resolution_scrolling,
            "input.highResolutionScrolling"
        );
        assign!(
            group.native_pen_touch,
            target.input.native_pen_touch,
            "input.nativePenTouch"
        );
        assign!(
            group.rumble_forwarding,
            target.input.rumble_forwarding,
            "input.rumbleForwarding"
        );
    }
    if let Some(group) = &changes.network {
        assign!(
            group.address_family,
            target.network.address_family,
            "network.addressFamily"
        );
        assign!(group.port, target.network.port, "network.port");
        assign!(group.upnp, target.network.upnp, "network.upnp");
        assign!(
            group.remote_access_scope,
            target.network.remote_access_scope,
            "network.remoteAccessScope"
        );
        assign!(
            group.external_ip_mode,
            target.network.external_ip_mode,
            "network.externalIpMode"
        );
        assign!(
            group.lan_encryption,
            target.network.lan_encryption,
            "network.lanEncryption"
        );
        assign!(
            group.wan_encryption,
            target.network.wan_encryption,
            "network.wanEncryption"
        );
        assign!(
            group.ping_timeout_ms,
            target.network.ping_timeout_ms,
            "network.pingTimeoutMs"
        );
        assign!(
            group.fec_percentage,
            target.network.fec_percentage,
            "network.fecPercentage"
        );
    }
    if let Some(group) = &changes.diagnostics {
        assign!(
            group.log_level,
            target.diagnostics.log_level,
            "diagnostics.logLevel"
        );
    }
    if let Some(group) = &changes.commands {
        assign!(group.prep, target.commands.prep, "commands.prep");
        assign!(group.state, target.commands.state, "commands.state");
        assign!(group.server, target.commands.server, "commands.server");
    }
}

pub(super) fn copy_settings_by_class(
    source: &HostSettings,
    target: &mut HostSettings,
    capabilities: &SettingsCapabilities,
    include: impl Fn(SettingsApplyClass) -> bool,
) {
    let changes = full_changes(source);
    apply_changes(target, &changes, |field_key| {
        capabilities
            .fields
            .get(field_key)
            .is_some_and(|capability| include(capability.apply_class))
    });
}

pub(super) fn full_changes(settings: &HostSettings) -> SettingsChanges {
    SettingsChanges {
        workspace: None,
        general: Some(GeneralChanges {
            name: Some(settings.general.name.clone()),
            discovery: Some(settings.general.discovery),
            update_channel: Some(settings.general.update_channel),
            notify_pre_releases: Some(settings.general.notify_pre_releases),
        }),
        streaming: Some(StreamingChanges {
            adapter_selector: Some(settings.streaming.adapter_selector.clone()),
            output_selector: Some(settings.streaming.output_selector.clone()),
            fallback_display_mode: Some(settings.streaming.fallback_display_mode.clone()),
        }),
        audio: Some(AudioChanges {
            sink: Some(settings.audio.sink.clone()),
            stream_audio: Some(settings.audio.stream_audio),
        }),
        input: Some(InputChanges {
            keyboard: Some(settings.input.keyboard),
            mouse: Some(settings.input.mouse),
            controller: Some(settings.input.controller),
            back_button_timeout_ms: Some(settings.input.back_button_timeout_ms),
            map_right_alt_to_windows_key: Some(settings.input.map_right_alt_to_windows_key),
            high_resolution_scrolling: Some(settings.input.high_resolution_scrolling),
            native_pen_touch: Some(settings.input.native_pen_touch),
            rumble_forwarding: Some(settings.input.rumble_forwarding),
        }),
        network: Some(NetworkChanges {
            address_family: Some(settings.network.address_family),
            port: Some(settings.network.port),
            upnp: Some(settings.network.upnp),
            remote_access_scope: Some(settings.network.remote_access_scope),
            external_ip_mode: Some(settings.network.external_ip_mode),
            lan_encryption: Some(settings.network.lan_encryption),
            wan_encryption: Some(settings.network.wan_encryption),
            ping_timeout_ms: Some(settings.network.ping_timeout_ms),
            fec_percentage: Some(settings.network.fec_percentage),
        }),
        diagnostics: Some(DiagnosticsChanges {
            log_level: Some(settings.diagnostics.log_level),
        }),
        commands: Some(CommandsChanges {
            prep: Some(settings.commands.prep.clone()),
            state: Some(settings.commands.state.clone()),
            server: Some(settings.commands.server.clone()),
        }),
    }
}

pub(super) fn pending_requirement(
    settings: &HostSettings,
    effective: &HostSettings,
    capabilities: &SettingsCapabilities,
) -> SettingsApplyRequirement {
    let differing = differing_field_keys(settings, effective);
    let mut requirement = SettingsApplyRequirement::None;
    for key in differing {
        match capabilities.fields.get(key).map(|field| field.apply_class) {
            Some(SettingsApplyClass::WorkerRestart) => {
                return SettingsApplyRequirement::WorkerRestart
            }
            Some(SettingsApplyClass::NextSession) => {
                requirement = SettingsApplyRequirement::NextSession
            }
            _ => {}
        }
    }
    requirement
}

pub(super) fn differing_field_keys(left: &HostSettings, right: &HostSettings) -> Vec<&'static str> {
    let mut keys = Vec::new();
    macro_rules! differs {
        ($l:expr, $r:expr, $key:literal) => {
            push_key(&mut keys, $l != $r, $key);
        };
    }
    differs!(
        left.workspace.policy,
        right.workspace.policy,
        "workspace.policy"
    );
    differs!(left.general.name, right.general.name, "general.name");
    differs!(
        left.general.discovery,
        right.general.discovery,
        "general.discovery"
    );
    differs!(
        left.general.update_channel,
        right.general.update_channel,
        "general.updateChannel"
    );
    differs!(
        left.general.notify_pre_releases,
        right.general.notify_pre_releases,
        "general.notifyPreReleases"
    );
    differs!(
        left.streaming.adapter_selector,
        right.streaming.adapter_selector,
        "streaming.adapterSelector"
    );
    differs!(
        left.streaming.output_selector,
        right.streaming.output_selector,
        "streaming.outputSelector"
    );
    differs!(
        left.streaming.fallback_display_mode,
        right.streaming.fallback_display_mode,
        "streaming.fallbackDisplayMode"
    );
    differs!(left.audio.sink, right.audio.sink, "audio.sink");
    differs!(
        left.audio.stream_audio,
        right.audio.stream_audio,
        "audio.streamAudio"
    );
    differs!(left.input.keyboard, right.input.keyboard, "input.keyboard");
    differs!(left.input.mouse, right.input.mouse, "input.mouse");
    differs!(
        left.input.controller,
        right.input.controller,
        "input.controller"
    );
    differs!(
        left.input.back_button_timeout_ms,
        right.input.back_button_timeout_ms,
        "input.backButtonTimeoutMs"
    );
    differs!(
        left.input.map_right_alt_to_windows_key,
        right.input.map_right_alt_to_windows_key,
        "input.mapRightAltToWindowsKey"
    );
    differs!(
        left.input.high_resolution_scrolling,
        right.input.high_resolution_scrolling,
        "input.highResolutionScrolling"
    );
    differs!(
        left.input.native_pen_touch,
        right.input.native_pen_touch,
        "input.nativePenTouch"
    );
    differs!(
        left.input.rumble_forwarding,
        right.input.rumble_forwarding,
        "input.rumbleForwarding"
    );
    differs!(
        left.network.address_family,
        right.network.address_family,
        "network.addressFamily"
    );
    differs!(left.network.port, right.network.port, "network.port");
    differs!(left.network.upnp, right.network.upnp, "network.upnp");
    differs!(
        left.network.remote_access_scope,
        right.network.remote_access_scope,
        "network.remoteAccessScope"
    );
    differs!(
        left.network.external_ip_mode,
        right.network.external_ip_mode,
        "network.externalIpMode"
    );
    differs!(
        left.network.lan_encryption,
        right.network.lan_encryption,
        "network.lanEncryption"
    );
    differs!(
        left.network.wan_encryption,
        right.network.wan_encryption,
        "network.wanEncryption"
    );
    differs!(
        left.network.ping_timeout_ms,
        right.network.ping_timeout_ms,
        "network.pingTimeoutMs"
    );
    differs!(
        left.network.fec_percentage,
        right.network.fec_percentage,
        "network.fecPercentage"
    );
    differs!(
        left.diagnostics.log_level,
        right.diagnostics.log_level,
        "diagnostics.logLevel"
    );
    differs!(left.commands.prep, right.commands.prep, "commands.prep");
    differs!(left.commands.state, right.commands.state, "commands.state");
    differs!(
        left.commands.server,
        right.commands.server,
        "commands.server"
    );
    keys
}

pub(super) fn apply_state_for_requirement(
    requirement: SettingsApplyRequirement,
) -> SettingsApplyState {
    match requirement {
        SettingsApplyRequirement::None => SettingsApplyState::Applied,
        SettingsApplyRequirement::NextSession => SettingsApplyState::PendingNextSession,
        SettingsApplyRequirement::WorkerRestart => SettingsApplyState::PendingWorkerRestart,
    }
}
