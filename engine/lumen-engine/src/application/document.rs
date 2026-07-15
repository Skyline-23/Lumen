use std::collections::{BTreeMap, HashSet};

use rand_core::{OsRng, RngCore};
use serde_json::Value;

use super::model::{
    ApplicationCommandPlan, ApplicationDescriptor, ApplicationLaunchPlan, CatalogError,
};

const MAXIMUM_NAME_LENGTH: usize = 256;

pub(super) fn default_document() -> Value {
    serde_json::json!({
        "env": {},
        "apps": []
    })
}

pub(super) fn normalize_document(document: &mut Value) -> Result<bool, CatalogError> {
    let root = document.as_object_mut().ok_or(CatalogError::Corrupt)?;
    root.entry("env")
        .or_insert_with(|| Value::Object(serde_json::Map::new()));
    let applications = root
        .entry("apps")
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .ok_or(CatalogError::Corrupt)?;
    let mut changed = false;
    for application in applications.iter_mut() {
        changed |= normalize_application(application)?;
    }
    changed |= normalize_application_ids(applications)?;
    Ok(changed)
}

pub(super) fn normalize_application(application: &mut Value) -> Result<bool, CatalogError> {
    let application = application
        .as_object_mut()
        .ok_or(CatalogError::InvalidArgument)?;
    let name = application
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty() && value.len() <= MAXIMUM_NAME_LENGTH)
        .ok_or(CatalogError::InvalidArgument)?
        .to_owned();
    application.insert("name".to_owned(), Value::String(name));

    let mut changed = false;
    let id = application
        .get("uuid")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            changed = true;
            random_uuid()
        });
    application.insert("uuid".to_owned(), Value::String(id));
    changed |= application.remove("index").is_some();
    changed |= application.remove("launching").is_some();
    for key in ["prep-cmd", "detached"] {
        if application.get(key).is_some_and(empty_array) {
            application.remove(key);
            changed = true;
        }
    }
    Ok(changed)
}

fn normalize_application_ids(applications: &mut [Value]) -> Result<bool, CatalogError> {
    let mut changed = false;
    let mut assigned = HashSet::with_capacity(applications.len());
    let application_count = applications.len();
    for (index, application) in applications.iter_mut().enumerate() {
        let object = application
            .as_object_mut()
            .ok_or(CatalogError::InvalidArgument)?;
        let uuid = object
            .get("uuid")
            .and_then(Value::as_str)
            .ok_or(CatalogError::Corrupt)?;
        let mut salt = 0_u32;
        let id = loop {
            let candidate = stable_application_id(uuid, salt);
            if assigned.insert(candidate) {
                break candidate;
            }
            salt = salt.checked_add(1).ok_or(CatalogError::Corrupt)?;
            if salt as usize > application_count.saturating_add(index) {
                return Err(CatalogError::Corrupt);
            }
        };
        if object.get("id").and_then(Value::as_u64) != Some(u64::from(id)) {
            object.insert("id".to_owned(), Value::from(id));
            changed = true;
        }
    }
    Ok(changed)
}

fn stable_application_id(uuid: &str, salt: u32) -> u32 {
    let mut hash = 2_166_136_261_u32;
    for byte in uuid.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(16_777_619);
    }
    if salt != 0 {
        for byte in std::iter::once(b'#').chain(salt.to_string().bytes()) {
            hash ^= u32::from(byte);
            hash = hash.wrapping_mul(16_777_619);
        }
    }
    (hash & 0x7fff_ffff).max(1)
}

pub(super) fn application_descriptor(
    application: &Value,
) -> Result<ApplicationDescriptor, CatalogError> {
    let application = application.as_object().ok_or(CatalogError::Corrupt)?;
    let id = application
        .get("id")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .filter(|value| *value > 0)
        .ok_or(CatalogError::Corrupt)?;
    let uuid = application
        .get("uuid")
        .and_then(Value::as_str)
        .ok_or(CatalogError::Corrupt)?
        .to_owned();
    let name = application
        .get("name")
        .and_then(Value::as_str)
        .ok_or(CatalogError::Corrupt)?
        .to_owned();
    Ok(ApplicationDescriptor {
        id,
        uuid,
        title: name.clone(),
        name,
        hdr_supported: true,
        is_app_collector_game: false,
    })
}

pub(super) fn application_launch_plan(
    application: &Value,
    environment: BTreeMap<String, String>,
) -> Result<ApplicationLaunchPlan, CatalogError> {
    let descriptor = application_descriptor(application)?;
    let application = application.as_object().ok_or(CatalogError::Corrupt)?;
    Ok(ApplicationLaunchPlan {
        id: descriptor.id,
        uuid: descriptor.uuid,
        name: descriptor.name,
        command: optional_string(application, "cmd")?,
        working_directory: optional_string(application, "working-dir")?,
        output: optional_string(application, "output")?,
        image_path: optional_string(application, "image-path")?,
        environment,
        prep_commands: command_plans(application, "prep-cmd")?,
        state_commands: command_plans(application, "state-cmd")?,
        detached_commands: string_array(application, "detached")?,
        exclude_global_prep_commands: optional_bool(application, "exclude-global-prep-cmd", false)?,
        exclude_global_state_commands: optional_bool(
            application,
            "exclude-global-state-cmd",
            false,
        )?,
        elevated: optional_bool(application, "elevated", false)?,
        auto_detach: optional_bool(application, "auto-detach", true)?,
        wait_all: optional_bool(application, "wait-all", true)?,
        exit_timeout_seconds: optional_u32(application, "exit-timeout", 5, 0, 300)?,
        virtual_display: optional_bool(application, "virtual-display", false)?,
        scale_percent: optional_u32(application, "scale-factor", 100, 25, 400)?,
        use_app_identity: optional_bool(application, "use-app-identity", false)?,
        per_client_app_identity: optional_bool(application, "per-client-app-identity", false)?,
        terminate_on_pause: optional_bool(application, "terminate-on-pause", false)?,
        gamepad: optional_string(application, "gamepad")?,
    })
}

fn optional_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<String, CatalogError> {
    match object.get(key) {
        None => Ok(String::new()),
        Some(value) => value
            .as_str()
            .filter(|value| value.len() <= 32_768 && !value.contains('\0'))
            .map(str::to_owned)
            .ok_or(CatalogError::Corrupt),
    }
}

fn optional_bool(
    object: &serde_json::Map<String, Value>,
    key: &str,
    default: bool,
) -> Result<bool, CatalogError> {
    match object.get(key) {
        None => Ok(default),
        Some(value) => value.as_bool().ok_or(CatalogError::Corrupt),
    }
}

fn optional_u32(
    object: &serde_json::Map<String, Value>,
    key: &str,
    default: u32,
    minimum: u32,
    maximum: u32,
) -> Result<u32, CatalogError> {
    match object.get(key) {
        None => Ok(default),
        Some(value) => value
            .as_u64()
            .and_then(|value| u32::try_from(value).ok())
            .filter(|value| (minimum..=maximum).contains(value))
            .ok_or(CatalogError::Corrupt),
    }
}

fn command_plans(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Vec<ApplicationCommandPlan>, CatalogError> {
    let Some(value) = object.get(key) else {
        return Ok(Vec::new());
    };
    value
        .as_array()
        .ok_or(CatalogError::Corrupt)?
        .iter()
        .map(|command| {
            let command = command.as_object().ok_or(CatalogError::Corrupt)?;
            Ok(ApplicationCommandPlan {
                run: optional_string(command, "do")?,
                undo: optional_string(command, "undo")?,
                elevated: optional_bool(command, "elevated", false)?,
            })
        })
        .collect()
}

fn string_array(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<Vec<String>, CatalogError> {
    let Some(value) = object.get(key) else {
        return Ok(Vec::new());
    };
    value
        .as_array()
        .ok_or(CatalogError::Corrupt)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .filter(|value| !value.is_empty() && value.len() <= 32_768 && !value.contains('\0'))
                .map(str::to_owned)
                .ok_or(CatalogError::Corrupt)
        })
        .collect()
}

fn string_map(value: &Value) -> Result<BTreeMap<String, String>, CatalogError> {
    value
        .as_object()
        .ok_or(CatalogError::Corrupt)?
        .iter()
        .map(|(key, value)| {
            if key.is_empty() || key.contains('=') || key.contains('\0') || key.len() > 256 {
                return Err(CatalogError::Corrupt);
            }
            let value = value
                .as_str()
                .filter(|value| value.len() <= 32_768 && !value.contains('\0'))
                .ok_or(CatalogError::Corrupt)?;
            Ok((key.clone(), value.to_owned()))
        })
        .collect()
}

pub(super) fn document_environment(
    document: &Value,
) -> Result<BTreeMap<String, String>, CatalogError> {
    string_map(
        document
            .as_object()
            .and_then(|root| root.get("env"))
            .ok_or(CatalogError::Corrupt)?,
    )
}

fn empty_array(value: &Value) -> bool {
    value.as_array().is_some_and(Vec::is_empty)
}

pub(super) fn applications_mut(document: &mut Value) -> Result<&mut Vec<Value>, CatalogError> {
    document
        .as_object_mut()
        .and_then(|root| root.get_mut("apps"))
        .and_then(Value::as_array_mut)
        .ok_or(CatalogError::Corrupt)
}

pub(super) fn entry_id(application: &Value) -> Result<&str, CatalogError> {
    application
        .as_object()
        .and_then(|value| value.get("uuid"))
        .and_then(Value::as_str)
        .ok_or(CatalogError::Corrupt)
}

pub(super) fn normalized_id(value: &str) -> Result<String, CatalogError> {
    let value = value.trim();
    if value.is_empty() || value.len() > 128 {
        Err(CatalogError::InvalidArgument)
    } else {
        Ok(value.to_owned())
    }
}

pub(crate) fn random_uuid() -> String {
    let mut bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}
