use lumen_engine::settings::{
    SettingsErrorCode, SettingsEvent, SettingsProtocolError, SETTINGS_SCHEMA_VERSION,
};
use serde::Serialize;

use super::{
    has_json_content_type, ControlRequest, ControlResponse, ControlRouter,
    MAXIMUM_JSON_REQUEST_BYTES,
};

impl ControlRouter {
    pub(super) fn dispatch_settings_snapshot(&self, request: &ControlRequest) -> ControlResponse {
        if !request.body.is_empty() || !request.query.is_empty() {
            return settings_error(invalid_request(
                "settings snapshot does not accept a body or query",
            ));
        }
        ControlResponse::json(200, &self.authorities.settings().snapshot())
    }

    pub(super) fn dispatch_settings_patch(&mut self, request: &ControlRequest) -> ControlResponse {
        if request.body.len() > MAXIMUM_JSON_REQUEST_BYTES {
            return settings_error(invalid_request("settings request exceeds 32768 bytes"));
        }
        if !request.query.is_empty() || !has_json_content_type(&request.headers) {
            return settings_error(invalid_request(
                "settings patch requires application/json and no query",
            ));
        }
        let Ok(body) = std::str::from_utf8(&request.body) else {
            return settings_error(invalid_request("settings patch body must be UTF-8 JSON"));
        };
        match self.authorities.settings_mut().apply_patch_json(body) {
            Ok(response) => ControlResponse::json(200, &response),
            Err(error) => settings_error(error),
        }
    }

    pub(super) fn dispatch_settings_events(&self, request: &ControlRequest) -> ControlResponse {
        if !request.body.is_empty() {
            return settings_error(invalid_request(
                "settings events does not accept a request body",
            ));
        }
        let after_revision = query_values(&request.query, "afterrevision");
        if request.query.len() != 1 || after_revision.len() != 1 {
            return settings_error(invalid_request(
                "settings events requires exactly one afterRevision query",
            ));
        }
        let Ok(after_revision) = after_revision[0].parse::<u64>() else {
            return settings_error(invalid_request("afterRevision must be an unsigned integer"));
        };
        match self.authorities.settings().events_since(after_revision) {
            Ok(events) => ControlResponse::json(
                200,
                &SettingsEventsResponse {
                    schema_version: SETTINGS_SCHEMA_VERSION,
                    after_revision,
                    events,
                },
            ),
            Err(error) => settings_error(error),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsEventsResponse {
    schema_version: u32,
    after_revision: u64,
    events: Vec<SettingsEvent>,
}

fn query_values<'a>(query: &'a [(String, String)], name: &str) -> Vec<&'a str> {
    query
        .iter()
        .filter(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
        .collect()
}

fn invalid_request(message: impl Into<String>) -> SettingsProtocolError {
    SettingsProtocolError {
        code: SettingsErrorCode::InvalidRequest,
        message: message.into(),
        field: None,
        current_revision: None,
    }
}

fn settings_error(error: SettingsProtocolError) -> ControlResponse {
    let status_code = match error.code {
        SettingsErrorCode::UnsupportedSchema
        | SettingsErrorCode::InvalidRequest
        | SettingsErrorCode::UnknownField
        | SettingsErrorCode::ForbiddenField
        | SettingsErrorCode::UnavailableField
        | SettingsErrorCode::InvalidValue => 400,
        SettingsErrorCode::StaleRevision
        | SettingsErrorCode::RequestIdConflict
        | SettingsErrorCode::RevisionNotRetained => 409,
        SettingsErrorCode::StorageError => 503,
        SettingsErrorCode::CorruptData => 500,
    };
    ControlResponse::json(status_code, &error)
}
