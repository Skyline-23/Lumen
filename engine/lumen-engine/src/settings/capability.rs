use super::*;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FieldCapability {
    pub field_key: String,
    pub title: String,
    pub section_id: String,
    pub section_title: String,
    pub order: u32,
    pub editor: SettingsEditor,
    pub field_type: SettingsFieldType,
    pub apply_class: SettingsApplyClass,
    pub available: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allowed_values: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub allowed_value_labels: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maximum: Option<i64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub presets: Vec<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub step: Option<i64>,
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

    pub fn set_allowed_values_with_labels(&mut self, key: &str, values: &[(&str, &str)]) {
        if let Some(field) = self.fields.get_mut(key) {
            field.allowed_values = values
                .iter()
                .map(|(value, _)| (*value).to_owned())
                .collect();
            field.allowed_value_labels = values
                .iter()
                .map(|(value, label)| ((*value).to_owned(), (*label).to_owned()))
                .collect();
        }
    }
}

fn set_allowed_values(fields: &mut BTreeMap<String, FieldCapability>, key: &str, values: &[&str]) {
    if let Some(field) = fields.get_mut(key) {
        field.allowed_values = values.iter().map(|value| (*value).to_owned()).collect();
    }
}

fn capability(
    key: &str,
    title: &str,
    section_id: &str,
    section_title: &str,
    order: u32,
    editor: SettingsEditor,
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
            title: title.to_owned(),
            section_id: section_id.to_owned(),
            section_title: section_title.to_owned(),
            order,
            editor,
            field_type,
            apply_class,
            available: true,
            allowed_values: allowed_values
                .iter()
                .map(|value| (*value).to_owned())
                .collect(),
            allowed_value_labels: BTreeMap::new(),
            minimum,
            maximum,
            presets: Vec::new(),
            step: None,
            max_length: None,
            pattern: None,
            unavailable_reason: None,
        },
    )
}

pub(super) fn field_catalog() -> BTreeMap<String, FieldCapability> {
    use SettingsApplyClass::{Live, NextSession};
    use SettingsEditor::{IntegerMenu, PrepCommandList, ServerCommandList, Text};
    use SettingsFieldType::{CommandList, Integer, String as StringType};
    let mut fields: BTreeMap<String, FieldCapability> = [
        capability(
            "general.name",
            "Name",
            "general",
            "General",
            10,
            Text,
            StringType,
            Live,
            &[],
            None,
            None,
        ),
        capability(
            "network.fecPercentage",
            "Forward error correction",
            "network",
            "Network",
            20,
            IntegerMenu,
            Integer,
            NextSession,
            &[],
            Some(1),
            Some(255),
        ),
        capability(
            "commands.prep",
            "Preparation commands",
            "commands",
            "Commands",
            30,
            PrepCommandList,
            CommandList,
            NextSession,
            &["user", "administrator"],
            None,
            None,
        ),
        capability(
            "commands.state",
            "State commands",
            "commands",
            "Commands",
            40,
            PrepCommandList,
            CommandList,
            NextSession,
            &["user", "administrator"],
            None,
            None,
        ),
        capability(
            "commands.server",
            "Server commands",
            "commands",
            "Commands",
            50,
            ServerCommandList,
            CommandList,
            NextSession,
            &["user", "administrator"],
            None,
            None,
        ),
    ]
    .into_iter()
    .collect();
    set_string_constraint(&mut fields, "general.name", Some(64), None);
    set_integer_metadata(
        &mut fields,
        "network.fecPercentage",
        &[5, 10, 15, 20, 25, 30, 40, 50],
        1,
    );
    fields
}

fn set_integer_metadata(
    fields: &mut BTreeMap<String, FieldCapability>,
    key: &str,
    presets: &[i64],
    step: i64,
) {
    if let Some(field) = fields.get_mut(key) {
        field.presets = presets.to_vec();
        field.allowed_value_labels = presets
            .iter()
            .map(|value| (value.to_string(), format!("{value}%")))
            .collect();
        field.step = Some(step);
    }
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
