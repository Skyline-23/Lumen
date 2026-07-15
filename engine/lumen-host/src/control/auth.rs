use lumen_engine::{
    AuthErrorCode, AuthErrorEnvelope, AuthHttpOperation, AuthHttpResponse, AUTH_SCHEMA_VERSION,
};

use super::{
    has_json_content_type, header_values, ControlMethod, ControlRequest, ControlResponse,
    ControlRouter, MAXIMUM_JSON_REQUEST_BYTES,
};

pub(super) fn operation(method: ControlMethod, path: &str) -> Option<AuthHttpOperation> {
    if method != ControlMethod::Post {
        return None;
    }
    match path {
        "/api/v1/auth/enrollment-challenge" => Some(AuthHttpOperation::EnrollmentChallenge),
        "/api/v1/auth/enroll" => Some(AuthHttpOperation::Enroll),
        "/api/v1/auth/token-challenge" => Some(AuthHttpOperation::TokenChallenge),
        "/api/v1/auth/token" => Some(AuthHttpOperation::Token),
        "/api/v1/auth/revoke" => Some(AuthHttpOperation::Revoke),
        _ => None,
    }
}

impl ControlRouter {
    pub(super) fn dispatch_auth(
        &mut self,
        operation: AuthHttpOperation,
        request: &ControlRequest,
    ) -> ControlResponse {
        if request.body.len() > MAXIMUM_JSON_REQUEST_BYTES
            || !request.query.is_empty()
            || !has_json_content_type(&request.headers)
        {
            return authentication_error(AuthErrorCode::InvalidRequest);
        }
        let response = self
            .authorities
            .authentication_mut()
            .dispatch_http_json(operation, &request.body);
        auth_response(response)
    }

    pub(super) fn authorize(&self, request: &ControlRequest) -> Option<ControlResponse> {
        self.authorize_device(request).err()
    }

    pub(super) fn authorize_device(
        &self,
        request: &ControlRequest,
    ) -> Result<String, ControlResponse> {
        let authorization = header_values(&request.headers, "authorization");
        let device_id = header_values(&request.headers, "lumen-device-id");
        if !header_values(&request.headers, "cookie").is_empty()
            || contains_authentication_query(&request.query)
            || authorization.len() > 1
            || device_id.len() > 1
        {
            return Err(authentication_error(AuthErrorCode::InvalidRequest));
        }
        if authorization.len() != 1 || device_id.len() != 1 {
            return Err(authentication_error(AuthErrorCode::InvalidDeviceCredential));
        }
        let Some(access_token) = bearer_token(authorization[0]) else {
            return Err(authentication_error(AuthErrorCode::InvalidDeviceCredential));
        };
        if !valid_opaque_header_value(access_token) || !valid_opaque_header_value(device_id[0]) {
            return Err(authentication_error(AuthErrorCode::InvalidDeviceCredential));
        }
        match self
            .authorities
            .authentication()
            .verify_access_token(device_id[0], access_token)
        {
            Ok(()) => Ok(device_id[0].to_owned()),
            Err(error) => Err(authentication_error(error)),
        }
    }
}

fn auth_response(response: AuthHttpResponse) -> ControlResponse {
    ControlResponse::json(response.status_code, &response.body)
}

fn authentication_error(error: AuthErrorCode) -> ControlResponse {
    let status_code = match error {
        AuthErrorCode::InvalidRequest => 400,
        AuthErrorCode::DeviceEnrollmentDisabled => 403,
        AuthErrorCode::InvalidOwnerCredentials
        | AuthErrorCode::InvalidSignature
        | AuthErrorCode::InvalidDeviceCredential
        | AuthErrorCode::AccessTokenExpired
        | AuthErrorCode::Revoked => 401,
        AuthErrorCode::InvalidChallenge | AuthErrorCode::ChallengeExpired => 409,
        AuthErrorCode::StorageUnavailable => 503,
        AuthErrorCode::CorruptAuthority => 500,
    };
    let envelope = AuthErrorEnvelope {
        schema_version: AUTH_SCHEMA_VERSION,
        request_id: String::new(),
        error: error.detail(),
    };
    ControlResponse::json(status_code, &envelope)
}

fn contains_authentication_query(query: &[(String, String)]) -> bool {
    const FORBIDDEN: &[&str] = &[
        "authorization",
        "accesstoken",
        "access_token",
        "bearer",
        "token",
        "lumen-device-id",
        "deviceid",
        "device_id",
    ];
    query.iter().any(|(name, _)| {
        FORBIDDEN
            .iter()
            .any(|value| name.eq_ignore_ascii_case(value))
    })
}

fn bearer_token(value: &str) -> Option<&str> {
    let (scheme, token) = value.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") || token.contains(' ') {
        return None;
    }
    Some(token)
}

fn valid_opaque_header_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 4096
        && !value
            .chars()
            .any(|character| character.is_ascii_control() || character.is_ascii_whitespace())
}
