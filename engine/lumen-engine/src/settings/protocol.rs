use super::*;

macro_rules! patch_group {
    ($name:ident { $($field:ident : $type:ty),+ $(,)? }) => {
        #[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        pub struct $name { $(#[serde(default, skip_serializing_if = "Option::is_none")] pub $field: Option<$type>),+ }
    };
}

patch_group!(WorkspaceChanges {
    policy: WorkspacePolicy
});
patch_group!(GeneralChanges {
    name: String,
    discovery: bool,
    update_channel: UpdateChannel,
    notify_pre_releases: bool,
});
patch_group!(StreamingChanges {
    adapter_selector: String,
    output_selector: String,
    fallback_display_mode: String,
});
patch_group!(AudioChanges {
    sink: String,
    stream_audio: bool
});
patch_group!(InputChanges {
    keyboard: bool,
    mouse: bool,
    controller: bool,
    back_button_timeout_ms: i32,
    map_right_alt_to_windows_key: bool,
    high_resolution_scrolling: bool,
    native_pen_touch: bool,
    rumble_forwarding: bool,
});
patch_group!(NetworkChanges {
    address_family: AddressFamily,
    port: u16,
    upnp: bool,
    remote_access_scope: RemoteAccessScope,
    external_ip_mode: ExternalIpMode,
    lan_encryption: EncryptionMode,
    wan_encryption: EncryptionMode,
    ping_timeout_ms: u32,
    fec_percentage: u16,
});
patch_group!(DiagnosticsChanges {
    log_level: LogLevel
});
patch_group!(CommandsChanges {
    prep: Vec<PrepCommand>,
    state: Vec<PrepCommand>,
    server: Vec<ServerCommand>,
});

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsChanges {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<WorkspaceChanges>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub general: Option<GeneralChanges>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub streaming: Option<StreamingChanges>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio: Option<AudioChanges>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<InputChanges>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network: Option<NetworkChanges>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diagnostics: Option<DiagnosticsChanges>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commands: Option<CommandsChanges>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsPatchRequest {
    pub schema_version: u32,
    pub base_revision: u64,
    pub request_id: String,
    pub changes: SettingsChanges,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsPatchResponse {
    pub schema_version: u32,
    pub revision: u64,
    pub accepted: bool,
    pub effective: HostSettings,
    pub apply_state: SettingsApplyState,
    pub requires: SettingsApplyRequirement,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsSnapshot {
    pub schema_version: u32,
    pub revision: u64,
    pub settings: HostSettings,
    pub effective: HostSettings,
    pub apply_state: SettingsApplyState,
    pub capabilities: SettingsCapabilities,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsEvent {
    pub schema_version: u32,
    pub revision: u64,
    pub settings: HostSettings,
    pub effective: HostSettings,
    pub apply_state: SettingsApplyState,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsProtocolError {
    pub code: SettingsErrorCode,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub field: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_revision: Option<u64>,
}

impl SettingsProtocolError {
    pub(super) fn new(code: SettingsErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            field: None,
            current_revision: None,
        }
    }

    pub(super) fn field(
        code: SettingsErrorCode,
        field: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            code,
            message: message.into(),
            field: Some(field.into()),
            current_revision: None,
        }
    }
}
