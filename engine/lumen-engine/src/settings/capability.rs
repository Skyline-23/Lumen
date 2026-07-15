use super::*;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FieldCapability {
    pub field_key: String,
    pub field_type: SettingsFieldType,
    pub apply_class: SettingsApplyClass,
    pub available: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allowed_values: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maximum: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_length: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pattern: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unavailable_reason: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsCapabilities {
    pub host_platform: SettingsHostPlatform,
    pub fields: BTreeMap<String, FieldCapability>,
}

impl SettingsCapabilities {
    pub fn for_platform(platform: SettingsHostPlatform) -> Self {
        let mut fields = field_catalog();
        if platform != SettingsHostPlatform::Macos {
            set_unavailable(
                &mut fields,
                "workspace.policy",
                "macOS workspace policy is unavailable on this host",
            );
        }
        let command_privileges = if platform == SettingsHostPlatform::Windows {
            &["user", "administrator"][..]
        } else {
            &["user"][..]
        };
        for key in ["commands.prep", "commands.state", "commands.server"] {
            set_allowed_values(&mut fields, key, command_privileges);
        }
        Self {
            host_platform: platform,
            fields,
        }
    }

    pub fn set_available(&mut self, key: &str, available: bool, reason: Option<String>) {
        if let Some(field) = self.fields.get_mut(key) {
            field.available = available;
            field.unavailable_reason = if available { None } else { reason };
        }
    }

    pub fn set_allowed_values(&mut self, key: &str, values: &[&str]) {
        set_allowed_values(&mut self.fields, key, values);
    }
}

fn set_unavailable(fields: &mut BTreeMap<String, FieldCapability>, key: &str, reason: &str) {
    if let Some(field) = fields.get_mut(key) {
        field.available = false;
        field.unavailable_reason = Some(reason.to_owned());
    }
}

fn set_allowed_values(fields: &mut BTreeMap<String, FieldCapability>, key: &str, values: &[&str]) {
    if let Some(field) = fields.get_mut(key) {
        field.allowed_values = values.iter().map(|value| (*value).to_owned()).collect();
    }
}

fn capability(
    key: &str,
    field_type: SettingsFieldType,
    apply_class: SettingsApplyClass,
    allowed_values: &[&str],
    minimum: Option<i64>,
    maximum: Option<i64>,
) -> (String, FieldCapability) {
    let field_key = key.to_owned();
    (
        field_key.clone(),
        FieldCapability {
            field_key,
            field_type,
            apply_class,
            available: true,
            allowed_values: allowed_values
                .iter()
                .map(|value| (*value).to_owned())
                .collect(),
            minimum,
            maximum,
            max_length: None,
            pattern: None,
            unavailable_reason: None,
        },
    )
}

pub(super) fn field_catalog() -> BTreeMap<String, FieldCapability> {
    use SettingsApplyClass::{Live, NextSession, WorkerRestart};
    use SettingsFieldType::{Boolean, CommandList, Enum, Integer, String as StringType};
    let mut fields: BTreeMap<String, FieldCapability> = [
        capability(
            "workspace.policy",
            Enum,
            NextSession,
            &[
                "coexist",
                "promote-virtual-main",
                "focused-workspace",
                "isolated-workspace",
            ],
            None,
            None,
        ),
        capability("general.locale", StringType, WorkerRestart, &[], None, None),
        capability("general.hostName", StringType, Live, &[], None, None),
        capability("general.discovery", Boolean, Live, &[], None, None),
        capability(
            "general.updateChannel",
            Enum,
            Live,
            &["stable", "pre-release"],
            None,
            None,
        ),
        capability("general.notifyPreReleases", Boolean, Live, &[], None, None),
        capability(
            "streaming.adapterSelector",
            StringType,
            WorkerRestart,
            &[],
            None,
            None,
        ),
        capability(
            "streaming.outputSelector",
            StringType,
            WorkerRestart,
            &[],
            None,
            None,
        ),
        capability(
            "streaming.fallbackDisplayMode",
            StringType,
            NextSession,
            &[],
            None,
            None,
        ),
        capability("audio.sink", StringType, NextSession, &[], None, None),
        capability("audio.streamAudio", Boolean, NextSession, &[], None, None),
        capability("input.keyboard", Boolean, Live, &[], None, None),
        capability("input.mouse", Boolean, Live, &[], None, None),
        capability("input.controller", Boolean, Live, &[], None, None),
        capability(
            "input.backButtonTimeoutMs",
            Integer,
            Live,
            &[],
            Some(-1),
            Some(60_000),
        ),
        capability(
            "input.mapRightAltToWindowsKey",
            Boolean,
            Live,
            &[],
            None,
            None,
        ),
        capability(
            "input.highResolutionScrolling",
            Boolean,
            Live,
            &[],
            None,
            None,
        ),
        capability("input.nativePenTouch", Boolean, Live, &[], None, None),
        capability("input.rumbleForwarding", Boolean, Live, &[], None, None),
        capability(
            "network.addressFamily",
            Enum,
            WorkerRestart,
            &["ipv4", "both"],
            None,
            None,
        ),
        capability(
            "network.port",
            Integer,
            WorkerRestart,
            &[],
            Some(1_029),
            Some(65_515),
        ),
        capability("network.upnp", Boolean, WorkerRestart, &[], None, None),
        capability(
            "network.remoteAccessScope",
            Enum,
            WorkerRestart,
            &["pc", "lan", "wan"],
            None,
            None,
        ),
        capability(
            "network.externalIp",
            StringType,
            WorkerRestart,
            &[],
            None,
            None,
        ),
        capability(
            "network.lanEncryption",
            Enum,
            NextSession,
            &["disabled", "opportunistic", "required"],
            None,
            None,
        ),
        capability(
            "network.wanEncryption",
            Enum,
            NextSession,
            &["disabled", "opportunistic", "required"],
            None,
            None,
        ),
        capability(
            "network.pingTimeoutMs",
            Integer,
            NextSession,
            &[],
            Some(1_000),
            Some(120_000),
        ),
        capability(
            "network.fecPercentage",
            Integer,
            NextSession,
            &[],
            Some(1),
            Some(255),
        ),
        capability(
            "diagnostics.logLevel",
            Enum,
            Live,
            &[
                "verbose", "debug", "info", "warning", "error", "fatal", "none",
            ],
            None,
            None,
        ),
        capability(
            "commands.prep",
            CommandList,
            WorkerRestart,
            &["user", "administrator"],
            None,
            None,
        ),
        capability(
            "commands.state",
            CommandList,
            WorkerRestart,
            &["user", "administrator"],
            None,
            None,
        ),
        capability(
            "commands.server",
            CommandList,
            WorkerRestart,
            &["user", "administrator"],
            None,
            None,
        ),
    ]
    .into_iter()
    .collect();
    set_string_constraint(&mut fields, "general.locale", Some(32), None);
    set_string_constraint(&mut fields, "general.hostName", Some(64), None);
    set_string_constraint(&mut fields, "streaming.adapterSelector", Some(256), None);
    set_string_constraint(&mut fields, "streaming.outputSelector", Some(256), None);
    set_string_constraint(
        &mut fields,
        "streaming.fallbackDisplayMode",
        None,
        Some(r"^\d+x\d+x\d+(\.\d+)?$"),
    );
    set_string_constraint(&mut fields, "audio.sink", Some(256), None);
    set_string_constraint(&mut fields, "network.externalIp", Some(255), None);
    fields
}

fn set_string_constraint(
    fields: &mut BTreeMap<String, FieldCapability>,
    key: &str,
    max_length: Option<u32>,
    pattern: Option<&str>,
) {
    if let Some(field) = fields.get_mut(key) {
        field.max_length = max_length;
        field.pattern = pattern.map(str::to_owned);
    }
}
