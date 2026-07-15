use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

pub const SETTINGS_SCHEMA_VERSION: u32 = 1;
const SETTINGS_STORAGE_VERSION: u32 = 2;
const RETIRED_SETTINGS_STORAGE_VERSION: u32 = 1;
const MAXIMUM_RETAINED_EVENTS: usize = 128;
const MAXIMUM_RETAINED_REQUESTS: usize = 256;
const MAXIMUM_COMMANDS_PER_LIST: usize = 64;
const MAXIMUM_ARGUMENTS_PER_INVOCATION: usize = 64;
const MAXIMUM_ARGUMENT_LENGTH: usize = 1_024;

mod capability;
mod model;
mod patch;
mod protocol;
mod validation;

pub use capability::*;
pub use model::*;
pub use protocol::*;

use patch::*;
use validation::*;

#[cfg(test)]
use capability::field_catalog;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedRequest {
    request_id: String,
    fingerprint: String,
    response: SettingsPatchResponse,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedSettingsState {
    storage_version: u32,
    revision: u64,
    settings: HostSettings,
    effective: HostSettings,
    apply_state: SettingsApplyState,
    #[serde(default)]
    requests: VecDeque<PersistedRequest>,
    #[serde(default)]
    events: VecDeque<SettingsEvent>,
}

impl Default for PersistedSettingsState {
    fn default() -> Self {
        let settings = HostSettings::default();
        Self {
            storage_version: SETTINGS_STORAGE_VERSION,
            revision: 1,
            effective: settings.clone(),
            settings,
            apply_state: SettingsApplyState::Applied,
            requests: VecDeque::new(),
            events: VecDeque::new(),
        }
    }
}

#[derive(Debug)]
pub struct SettingsAuthority {
    file_path: PathBuf,
    capabilities: SettingsCapabilities,
    state: PersistedSettingsState,
}

impl SettingsAuthority {
    pub fn open(
        file_path: impl Into<PathBuf>,
        capabilities: SettingsCapabilities,
    ) -> Result<Self, SettingsProtocolError> {
        let file_path = file_path.into();
        if file_path.as_os_str().is_empty() || file_path.file_name().is_none() {
            return Err(SettingsProtocolError::new(
                SettingsErrorCode::InvalidRequest,
                "settings storage path must name a file",
            ));
        }
        let state = match fs::read(&file_path) {
            Ok(data) => {
                let document: serde_json::Value = serde_json::from_slice(&data).map_err(|_| {
                    SettingsProtocolError::new(
                        SettingsErrorCode::CorruptData,
                        "settings storage is not valid schema version 1 data",
                    )
                })?;
                if document["storageVersion"].as_u64()
                    == Some(u64::from(RETIRED_SETTINGS_STORAGE_VERSION))
                {
                    let state = PersistedSettingsState::default();
                    write_state_atomically(&file_path, &state)?;
                    state
                } else {
                    serde_json::from_value::<PersistedSettingsState>(document).map_err(|_| {
                        SettingsProtocolError::new(
                            SettingsErrorCode::CorruptData,
                            "settings storage is not valid schema version 1 data",
                        )
                    })?
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                PersistedSettingsState::default()
            }
            Err(_) => {
                return Err(SettingsProtocolError::new(
                    SettingsErrorCode::StorageError,
                    "settings storage could not be read",
                ))
            }
        };
        if state.storage_version != SETTINGS_STORAGE_VERSION {
            return Err(SettingsProtocolError::new(
                SettingsErrorCode::CorruptData,
                "settings storage version is unsupported",
            ));
        }
        validate_settings(&state.settings)?;
        validate_settings(&state.effective)?;
        validate_persisted_state(&state, &capabilities)?;
        Ok(Self {
            file_path,
            capabilities,
            state,
        })
    }

    pub fn snapshot(&self) -> SettingsSnapshot {
        SettingsSnapshot {
            schema_version: SETTINGS_SCHEMA_VERSION,
            revision: self.state.revision,
            settings: self.state.settings.clone(),
            effective: self.state.effective.clone(),
            apply_state: self.state.apply_state,
            capabilities: self.capabilities.clone(),
        }
    }

    pub fn decode_patch_request(json: &str) -> Result<SettingsPatchRequest, SettingsProtocolError> {
        let value: serde_json::Value = serde_json::from_str(json).map_err(|_| {
            SettingsProtocolError::new(
                SettingsErrorCode::InvalidRequest,
                "patch request must be valid JSON",
            )
        })?;
        if let Some(field) = find_forbidden_key(&value, "") {
            return Err(SettingsProtocolError::field(
                SettingsErrorCode::ForbiddenField,
                field,
                "secrets, host paths, and control-location policy are not remote settings",
            ));
        }
        serde_json::from_value(value).map_err(|error| {
            let message = error.to_string();
            let code = if message.contains("unknown field") {
                SettingsErrorCode::UnknownField
            } else if message.contains("unknown variant") || message.contains("invalid value") {
                SettingsErrorCode::InvalidValue
            } else {
                SettingsErrorCode::InvalidRequest
            };
            SettingsProtocolError::new(
                code,
                "patch request does not match the version 1 settings schema",
            )
        })
    }

    pub fn apply_patch_json(
        &mut self,
        json: &str,
    ) -> Result<SettingsPatchResponse, SettingsProtocolError> {
        let request = Self::decode_patch_request(json)?;
        self.apply_patch(request)
    }

    pub fn preview_patch_json(
        &self,
        json: &str,
    ) -> Result<SettingsPatchResponse, SettingsProtocolError> {
        let request = Self::decode_patch_request(json)?;
        let mut preview = self.preview_clone();
        preview.apply_patch_in_memory(request)
    }

    pub fn apply_patch(
        &mut self,
        request: SettingsPatchRequest,
    ) -> Result<SettingsPatchResponse, SettingsProtocolError> {
        self.apply_patch_with_commit(request, true)
    }

    fn apply_patch_in_memory(
        &mut self,
        request: SettingsPatchRequest,
    ) -> Result<SettingsPatchResponse, SettingsProtocolError> {
        self.apply_patch_with_commit(request, false)
    }

    fn apply_patch_with_commit(
        &mut self,
        request: SettingsPatchRequest,
        persist: bool,
    ) -> Result<SettingsPatchResponse, SettingsProtocolError> {
        if request.schema_version != SETTINGS_SCHEMA_VERSION {
            return Err(SettingsProtocolError::new(
                SettingsErrorCode::UnsupportedSchema,
                "settings schema version must be 1",
            ));
        }
        validate_request_id(&request.request_id)?;
        let fingerprint = request_fingerprint(&request)?;
        if let Some(previous) = self
            .state
            .requests
            .iter()
            .find(|previous| previous.request_id == request.request_id)
        {
            if previous.fingerprint == fingerprint {
                return Ok(previous.response.clone());
            }
            return Err(SettingsProtocolError::field(
                SettingsErrorCode::RequestIdConflict,
                "requestId",
                "requestId was already used for a different patch",
            ));
        }
        if request.base_revision != self.state.revision {
            let mut error = SettingsProtocolError::new(
                SettingsErrorCode::StaleRevision,
                "baseRevision does not match the host revision",
            );
            error.current_revision = Some(self.state.revision);
            return Err(error);
        }

        let field_keys = request.changes.field_keys();
        if field_keys.is_empty() {
            return Err(SettingsProtocolError::field(
                SettingsErrorCode::InvalidRequest,
                "changes",
                "settings patch must contain at least one field",
            ));
        }
        for field_key in &field_keys {
            let capability = self.capabilities.fields.get(*field_key).ok_or_else(|| {
                SettingsProtocolError::field(
                    SettingsErrorCode::UnknownField,
                    *field_key,
                    "field is not part of settings schema version 1",
                )
            })?;
            if !capability.available {
                return Err(SettingsProtocolError::field(
                    SettingsErrorCode::UnavailableField,
                    *field_key,
                    capability
                        .unavailable_reason
                        .clone()
                        .unwrap_or_else(|| "field is unavailable on this host".to_owned()),
                ));
            }
        }

        let mut candidate = self.state.clone();
        apply_changes(&mut candidate.settings, &request.changes, |_| true);
        validate_settings(&candidate.settings)?;
        validate_capability_values(&candidate.settings, &field_keys, &self.capabilities)?;
        apply_changes(&mut candidate.effective, &request.changes, |field_key| {
            self.capabilities
                .fields
                .get(field_key)
                .is_some_and(|capability| capability.apply_class == SettingsApplyClass::Live)
        });
        candidate.revision = next_revision(candidate.revision)?;
        let requires = pending_requirement(
            &candidate.settings,
            &candidate.effective,
            &self.capabilities,
        );
        candidate.apply_state = apply_state_for_requirement(requires);
        let response = SettingsPatchResponse {
            schema_version: SETTINGS_SCHEMA_VERSION,
            revision: candidate.revision,
            accepted: true,
            effective: candidate.effective.clone(),
            apply_state: candidate.apply_state,
            requires,
        };
        candidate.requests.push_back(PersistedRequest {
            request_id: request.request_id,
            fingerprint,
            response: response.clone(),
        });
        while candidate.requests.len() > MAXIMUM_RETAINED_REQUESTS {
            candidate.requests.pop_front();
        }
        append_event(&mut candidate);
        if persist {
            self.commit(candidate)?;
        } else {
            self.state = candidate;
        }
        Ok(response)
    }

    pub fn mark_next_session_started(&mut self) -> Result<SettingsSnapshot, SettingsProtocolError> {
        self.mark_next_session_started_with_commit(true)
    }

    pub fn preview_next_session_started(&self) -> Result<SettingsSnapshot, SettingsProtocolError> {
        let mut preview = self.preview_clone();
        preview.mark_next_session_started_with_commit(false)
    }

    fn mark_next_session_started_with_commit(
        &mut self,
        persist: bool,
    ) -> Result<SettingsSnapshot, SettingsProtocolError> {
        let mut candidate = self.state.clone();
        let before = candidate.effective.clone();
        copy_settings_by_class(
            &candidate.settings,
            &mut candidate.effective,
            &self.capabilities,
            |apply_class| apply_class != SettingsApplyClass::WorkerRestart,
        );
        if candidate.effective != before {
            candidate.revision = next_revision(candidate.revision)?;
            let requires = pending_requirement(
                &candidate.settings,
                &candidate.effective,
                &self.capabilities,
            );
            candidate.apply_state = apply_state_for_requirement(requires);
            append_event(&mut candidate);
            if persist {
                self.commit(candidate)?;
            } else {
                self.state = candidate;
            }
        }
        Ok(self.snapshot())
    }

    pub fn mark_worker_restarted(&mut self) -> Result<SettingsSnapshot, SettingsProtocolError> {
        self.mark_worker_restarted_with_commit(true)
    }

    pub fn preview_worker_restarted(&self) -> Result<SettingsSnapshot, SettingsProtocolError> {
        let mut preview = self.preview_clone();
        preview.mark_worker_restarted_with_commit(false)
    }

    fn mark_worker_restarted_with_commit(
        &mut self,
        persist: bool,
    ) -> Result<SettingsSnapshot, SettingsProtocolError> {
        if self.state.settings != self.state.effective {
            let mut candidate = self.state.clone();
            candidate.effective = candidate.settings.clone();
            candidate.apply_state = SettingsApplyState::Applied;
            candidate.revision = next_revision(candidate.revision)?;
            append_event(&mut candidate);
            if persist {
                self.commit(candidate)?;
            } else {
                self.state = candidate;
            }
        }
        Ok(self.snapshot())
    }

    pub fn apply_local_update(
        &mut self,
        settings: HostSettings,
    ) -> Result<SettingsSnapshot, SettingsProtocolError> {
        validate_settings(&settings)?;
        let changed_fields = differing_field_keys(&settings, &self.state.effective);
        validate_capability_values(&settings, &changed_fields, &self.capabilities)?;
        if !changed_fields.is_empty() {
            let mut candidate = self.state.clone();
            let changes = full_changes(&settings);
            apply_changes(&mut candidate.settings, &changes, |field_key| {
                changed_fields.contains(&field_key)
            });
            candidate.effective = settings;
            candidate.apply_state = apply_state_for_requirement(pending_requirement(
                &candidate.settings,
                &candidate.effective,
                &self.capabilities,
            ));
            candidate.revision = next_revision(candidate.revision)?;
            append_event(&mut candidate);
            self.commit(candidate)?;
        }
        Ok(self.snapshot())
    }

    pub fn factory_reset(&mut self) -> Result<(), SettingsProtocolError> {
        match fs::remove_file(&self.file_path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => {
                return Err(SettingsProtocolError::new(
                    SettingsErrorCode::StorageError,
                    "settings storage could not be removed",
                ))
            }
        }
        self.state = PersistedSettingsState::default();
        Ok(())
    }

    pub fn preview_factory_reset(&self) -> SettingsSnapshot {
        let mut preview = self.preview_clone();
        preview.state = PersistedSettingsState::default();
        preview.snapshot()
    }

    pub fn events_since(
        &self,
        after_revision: u64,
    ) -> Result<Vec<SettingsEvent>, SettingsProtocolError> {
        if after_revision > self.state.revision {
            let mut error = SettingsProtocolError::new(
                SettingsErrorCode::StaleRevision,
                "resume revision is newer than the host revision",
            );
            error.current_revision = Some(self.state.revision);
            return Err(error);
        }
        if after_revision == self.state.revision {
            return Ok(Vec::new());
        }
        let oldest = self
            .state
            .events
            .front()
            .map(|event| event.revision)
            .unwrap_or(self.state.revision);
        if after_revision.saturating_add(1) < oldest {
            let mut error = SettingsProtocolError::new(
                SettingsErrorCode::RevisionNotRetained,
                "requested settings events are no longer retained",
            );
            error.current_revision = Some(self.state.revision);
            return Err(error);
        }
        Ok(self
            .state
            .events
            .iter()
            .filter(|event| event.revision > after_revision)
            .cloned()
            .collect())
    }

    fn commit(&mut self, candidate: PersistedSettingsState) -> Result<(), SettingsProtocolError> {
        write_state_atomically(&self.file_path, &candidate)?;
        self.state = candidate;
        Ok(())
    }

    fn preview_clone(&self) -> Self {
        Self {
            file_path: self.file_path.clone(),
            capabilities: self.capabilities.clone(),
            state: self.state.clone(),
        }
    }
}

fn validate_persisted_state(
    state: &PersistedSettingsState,
    capabilities: &SettingsCapabilities,
) -> Result<(), SettingsProtocolError> {
    let corrupt = || {
        SettingsProtocolError::new(
            SettingsErrorCode::CorruptData,
            "settings storage violates the version 1 authority invariants",
        )
    };
    let field_keys = capabilities
        .fields
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    validate_capability_values(&state.settings, &field_keys, capabilities)
        .map_err(|_| corrupt())?;
    validate_capability_values(&state.effective, &field_keys, capabilities)
        .map_err(|_| corrupt())?;
    if state.revision == 0
        || state.events.len() > MAXIMUM_RETAINED_EVENTS
        || state.requests.len() > MAXIMUM_RETAINED_REQUESTS
    {
        return Err(corrupt());
    }
    let differing = differing_field_keys(&state.settings, &state.effective);
    if differing.iter().any(|key| {
        capabilities
            .fields
            .get(*key)
            .is_some_and(|field| field.apply_class == SettingsApplyClass::Live)
    }) || state.apply_state
        != apply_state_for_requirement(pending_requirement(
            &state.settings,
            &state.effective,
            capabilities,
        ))
    {
        return Err(corrupt());
    }

    let mut previous_revision = 0;
    for event in &state.events {
        if event.schema_version != SETTINGS_SCHEMA_VERSION
            || event.revision <= previous_revision
            || event.revision > state.revision
        {
            return Err(corrupt());
        }
        validate_settings(&event.settings).map_err(|_| corrupt())?;
        validate_settings(&event.effective).map_err(|_| corrupt())?;
        let event_requirement =
            pending_requirement(&event.settings, &event.effective, capabilities);
        if event.apply_state != apply_state_for_requirement(event_requirement)
            || differing_field_keys(&event.settings, &event.effective)
                .iter()
                .any(|key| {
                    capabilities
                        .fields
                        .get(*key)
                        .is_some_and(|field| field.apply_class == SettingsApplyClass::Live)
                })
        {
            return Err(corrupt());
        }
        previous_revision = event.revision;
    }
    if state
        .events
        .back()
        .is_some_and(|event| event.revision != state.revision)
    {
        return Err(corrupt());
    }

    let mut request_ids = std::collections::BTreeSet::new();
    for request in &state.requests {
        if !request_ids.insert(&request.request_id)
            || validate_request_id(&request.request_id).is_err()
            || request.fingerprint.len() != 64
            || !request
                .fingerprint
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
            || request.response.schema_version != SETTINGS_SCHEMA_VERSION
            || !request.response.accepted
            || request.response.revision > state.revision
            || request.response.apply_state
                != apply_state_for_requirement(request.response.requires)
        {
            return Err(corrupt());
        }
        validate_settings(&request.response.effective).map_err(|_| corrupt())?;
    }
    Ok(())
}

fn next_revision(revision: u64) -> Result<u64, SettingsProtocolError> {
    revision.checked_add(1).ok_or_else(|| {
        SettingsProtocolError::new(
            SettingsErrorCode::StorageError,
            "settings revision is exhausted",
        )
    })
}

fn append_event(state: &mut PersistedSettingsState) {
    state.events.push_back(SettingsEvent {
        schema_version: SETTINGS_SCHEMA_VERSION,
        revision: state.revision,
        settings: state.settings.clone(),
        effective: state.effective.clone(),
        apply_state: state.apply_state,
    });
    while state.events.len() > MAXIMUM_RETAINED_EVENTS {
        state.events.pop_front();
    }
}

fn validate_request_id(request_id: &str) -> Result<(), SettingsProtocolError> {
    if request_id.is_empty()
        || request_id.len() > 128
        || !request_id.is_ascii()
        || request_id
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        return Err(SettingsProtocolError::field(
            SettingsErrorCode::InvalidValue,
            "requestId",
            "requestId must be 1 to 128 non-whitespace ASCII characters",
        ));
    }
    Ok(())
}

fn write_state_atomically(
    path: &Path,
    state: &PersistedSettingsState,
) -> Result<(), SettingsProtocolError> {
    let parent = path.parent().ok_or_else(|| {
        SettingsProtocolError::new(
            SettingsErrorCode::StorageError,
            "settings storage has no parent directory",
        )
    })?;
    fs::create_dir_all(parent).map_err(|_| {
        SettingsProtocolError::new(
            SettingsErrorCode::StorageError,
            "settings storage directory could not be created",
        )
    })?;
    let serialized = serde_json::to_vec_pretty(state).map_err(|_| {
        SettingsProtocolError::new(
            SettingsErrorCode::StorageError,
            "settings state could not be serialized",
        )
    })?;
    let mut temporary_file = tempfile::Builder::new()
        .prefix(".lumen-settings-")
        .tempfile_in(parent)
        .map_err(|_| {
            SettingsProtocolError::new(
                SettingsErrorCode::StorageError,
                "temporary settings storage could not be created",
            )
        })?;
    temporary_file
        .write_all(&serialized)
        .and_then(|_| temporary_file.flush())
        .and_then(|_| temporary_file.as_file().sync_all())
        .map_err(|_| {
            SettingsProtocolError::new(
                SettingsErrorCode::StorageError,
                "temporary settings storage could not be written",
            )
        })?;
    temporary_file.persist(path).map_err(|_| {
        SettingsProtocolError::new(
            SettingsErrorCode::StorageError,
            "settings storage could not be replaced",
        )
    })?;
    Ok(())
}

fn find_forbidden_key(value: &serde_json::Value, prefix: &str) -> Option<String> {
    match value {
        serde_json::Value::Object(object) => {
            for (key, child) in object {
                let path = if prefix.is_empty() {
                    key.clone()
                } else {
                    format!("{prefix}.{key}")
                };
                let normalized = key.to_ascii_lowercase().replace(['-', '_'], "");
                if normalized.ends_with("path")
                    || normalized.contains("password")
                    || normalized.contains("token")
                    || normalized.contains("privatekey")
                    || normalized.contains("credential")
                    || normalized.contains("certificate")
                    || normalized == "secret"
                    || normalized == "controllocation"
                    || normalized == "remotesettingsallowed"
                    || normalized == "systemauthenticationenabled"
                    || normalized == "deviceenrollmentenabled"
                {
                    return Some(path);
                }
                if let Some(forbidden) = find_forbidden_key(child, &path) {
                    return Some(forbidden);
                }
            }
        }
        serde_json::Value::Array(values) => {
            for (index, child) in values.iter().enumerate() {
                let path = format!("{prefix}[{index}]");
                if let Some(forbidden) = find_forbidden_key(child, &path) {
                    return Some(forbidden);
                }
            }
        }
        _ => {}
    }
    None
}

#[cfg(test)]
mod tests;
