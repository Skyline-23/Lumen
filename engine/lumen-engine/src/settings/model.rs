use super::*;

macro_rules! string_enum {
    ($name:ident { $($variant:ident => $value:literal),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
        pub enum $name {
            $(#[serde(rename = $value)] $variant),+
        }

        impl $name {
            pub const fn as_str(self) -> &'static str {
                match self { $(Self::$variant => $value),+ }
            }
        }
    };
}

string_enum!(SettingsHostPlatform {
    Macos => "macos",
    Windows => "windows",
});
string_enum!(WorkspacePolicy {
    Coexist => "coexist",
    PromoteVirtualMain => "promote-virtual-main",
    FocusedWorkspace => "focused-workspace",
    IsolatedWorkspace => "isolated-workspace",
});
string_enum!(UpdateChannel { Stable => "stable", PreRelease => "pre-release" });
string_enum!(AddressFamily { Ipv4 => "ipv4", Both => "both" });
string_enum!(RemoteAccessScope { Pc => "pc", Lan => "lan", Wan => "wan" });
string_enum!(ExternalIpMode { Automatic => "automatic", Disabled => "disabled" });
string_enum!(EncryptionMode { Disabled => "disabled", Opportunistic => "opportunistic", Required => "required" });
string_enum!(LogLevel { Verbose => "verbose", Debug => "debug", Info => "info", Warning => "warning", Error => "error", Fatal => "fatal", None => "none" });
string_enum!(CommandPrivilege { User => "user", Administrator => "administrator" });
string_enum!(SettingsApplyClass { Live => "live", NextSession => "next-session", WorkerRestart => "worker-restart" });
string_enum!(SettingsApplyState { Applied => "applied", PendingNextSession => "pending-next-session", PendingWorkerRestart => "pending-worker-restart" });
string_enum!(SettingsApplyRequirement { None => "none", NextSession => "next-session", WorkerRestart => "worker-restart" });
string_enum!(SettingsFieldType { Boolean => "boolean", Integer => "integer", String => "string", Enum => "enum", CommandList => "command-list" });
string_enum!(SettingsErrorCode {
    UnsupportedSchema => "unsupported-schema",
    InvalidRequest => "invalid-request",
    UnknownField => "unknown-field",
    ForbiddenField => "forbidden-field",
    UnavailableField => "unavailable-field",
    InvalidValue => "invalid-value",
    StaleRevision => "stale-revision",
    RequestIdConflict => "request-id-conflict",
    RevisionNotRetained => "revision-not-retained",
    StorageError => "storage-error",
    CorruptData => "corrupt-data",
});

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommandInvocation {
    pub program: String,
    #[serde(default)]
    pub arguments: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PrepCommand {
    pub run: CommandInvocation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub undo: Option<CommandInvocation>,
    pub privilege: CommandPrivilege,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServerCommand {
    pub name: String,
    pub invocation: CommandInvocation,
    pub privilege: CommandPrivilege,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceSettings {
    pub policy: WorkspacePolicy,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GeneralSettings {
    pub name: String,
    pub discovery: bool,
    pub update_channel: UpdateChannel,
    pub notify_pre_releases: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StreamingSettings {
    pub adapter_selector: String,
    pub output_selector: String,
    pub fallback_display_mode: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AudioSettings {
    pub sink: String,
    pub stream_audio: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InputSettings {
    pub keyboard: bool,
    pub mouse: bool,
    pub controller: bool,
    pub back_button_timeout_ms: i32,
    pub map_right_alt_to_windows_key: bool,
    pub high_resolution_scrolling: bool,
    pub native_pen_touch: bool,
    pub rumble_forwarding: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NetworkSettings {
    pub address_family: AddressFamily,
    pub port: u16,
    pub upnp: bool,
    pub remote_access_scope: RemoteAccessScope,
    pub external_ip_mode: ExternalIpMode,
    pub lan_encryption: EncryptionMode,
    pub wan_encryption: EncryptionMode,
    pub ping_timeout_ms: u32,
    pub fec_percentage: u16,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticsSettings {
    pub log_level: LogLevel,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommandsSettings {
    pub prep: Vec<PrepCommand>,
    pub state: Vec<PrepCommand>,
    pub server: Vec<ServerCommand>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HostSettings {
    pub workspace: WorkspaceSettings,
    pub general: GeneralSettings,
    pub streaming: StreamingSettings,
    pub audio: AudioSettings,
    pub input: InputSettings,
    pub network: NetworkSettings,
    pub diagnostics: DiagnosticsSettings,
    pub commands: CommandsSettings,
}

impl Default for HostSettings {
    fn default() -> Self {
        Self {
            workspace: WorkspaceSettings {
                policy: WorkspacePolicy::Coexist,
            },
            general: GeneralSettings {
                name: "Lumen".to_owned(),
                discovery: true,
                update_channel: UpdateChannel::Stable,
                notify_pre_releases: false,
            },
            streaming: StreamingSettings {
                adapter_selector: "automatic".to_owned(),
                output_selector: "automatic".to_owned(),
                fallback_display_mode: "1920x1080x60".to_owned(),
            },
            audio: AudioSettings {
                sink: "system-default".to_owned(),
                stream_audio: true,
            },
            input: InputSettings {
                keyboard: true,
                mouse: true,
                controller: true,
                back_button_timeout_ms: -1,
                map_right_alt_to_windows_key: false,
                high_resolution_scrolling: true,
                native_pen_touch: true,
                rumble_forwarding: true,
            },
            network: NetworkSettings {
                address_family: AddressFamily::Ipv4,
                port: 47_989,
                upnp: false,
                remote_access_scope: RemoteAccessScope::Lan,
                external_ip_mode: ExternalIpMode::Automatic,
                lan_encryption: EncryptionMode::Disabled,
                wan_encryption: EncryptionMode::Opportunistic,
                ping_timeout_ms: 10_000,
                fec_percentage: 20,
            },
            diagnostics: DiagnosticsSettings {
                log_level: LogLevel::Info,
            },
            commands: CommandsSettings {
                prep: Vec::new(),
                state: Vec::new(),
                server: Vec::new(),
            },
        }
    }
}
