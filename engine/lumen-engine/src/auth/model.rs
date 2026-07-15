use super::*;

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthRequestEnvelope<T> {
    pub schema_version: u32,
    pub request_id: String,
    pub request: T,
}

impl<T> AuthRequestEnvelope<T> {
    pub fn validate(&self) -> Result<(), AuthErrorCode> {
        if self.schema_version != AUTH_SCHEMA_VERSION
            || self.request_id.trim().is_empty()
            || self.request_id.chars().any(char::is_control)
            || self.request_id.len() > 128
        {
            Err(AuthErrorCode::InvalidRequest)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthSuccessEnvelope<T> {
    pub schema_version: u32,
    pub request_id: String,
    pub result: T,
}

impl<T> AuthSuccessEnvelope<T> {
    pub fn new(request_id: String, result: T) -> Self {
        Self {
            schema_version: AUTH_SCHEMA_VERSION,
            request_id,
            result,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthErrorEnvelope {
    pub schema_version: u32,
    pub request_id: String,
    pub error: AuthErrorDetail,
}

impl AuthErrorEnvelope {
    pub fn new(request_id: String, code: AuthErrorCode) -> Self {
        Self {
            schema_version: AUTH_SCHEMA_VERSION,
            request_id,
            error: code.detail(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthErrorDetail {
    pub code: AuthErrorCode,
    pub message: String,
    pub retryable: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AuthErrorCode {
    InvalidRequest,
    DeviceEnrollmentDisabled,
    InvalidOwnerCredentials,
    InvalidChallenge,
    ChallengeExpired,
    InvalidSignature,
    InvalidDeviceCredential,
    AccessTokenExpired,
    Revoked,
    StorageUnavailable,
    CorruptAuthority,
}

impl AuthErrorCode {
    pub fn detail(self) -> AuthErrorDetail {
        let (message, retryable) = match self {
            Self::InvalidRequest => ("The authentication request is invalid.", false),
            Self::DeviceEnrollmentDisabled => {
                ("New device enrollment is disabled by host policy.", true)
            }
            Self::InvalidOwnerCredentials => ("The owner credentials are invalid.", false),
            Self::InvalidChallenge => {
                ("The possession challenge is invalid or already used.", true)
            }
            Self::ChallengeExpired => ("The possession challenge has expired.", true),
            Self::InvalidSignature => ("The device possession signature is invalid.", false),
            Self::InvalidDeviceCredential => ("The device credential is invalid.", false),
            Self::AccessTokenExpired => ("The access token has expired.", true),
            Self::Revoked => ("The device credential has been revoked.", false),
            Self::StorageUnavailable => ("The authentication authority is unavailable.", true),
            Self::CorruptAuthority => ("The authentication authority data is corrupt.", false),
        };
        AuthErrorDetail {
            code: self,
            message: message.to_owned(),
            retryable,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentChallengeRequest {
    pub public_key: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RefreshChallengeRequest {
    pub device_id: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthChallenge {
    pub challenge_id: String,
    pub challenge: String,
    pub algorithm: AuthSignatureAlgorithm,
    pub purpose: AuthChallengePurpose,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    pub expires_at_unix_seconds: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AuthSignatureAlgorithm {
    P256EcdsaSha256,
}

impl AuthChallenge {
    pub fn signing_message(&self) -> Vec<u8> {
        let challenge = URL_SAFE_NO_PAD.decode(&self.challenge).unwrap_or_default();
        let domain = match self.purpose {
            AuthChallengePurpose::Enrollment => ENROLLMENT_SIGNATURE_DOMAIN,
            AuthChallengePurpose::TokenExchange => TOKEN_EXCHANGE_SIGNATURE_DOMAIN,
        };
        let device_id_length = self.device_id.as_ref().map_or(0, String::len);
        let mut message = Vec::with_capacity(domain.len() + device_id_length + 1 + challenge.len());
        message.extend_from_slice(domain);
        if let Some(device_id) = &self.device_id {
            message.extend_from_slice(device_id.as_bytes());
            message.push(0);
        }
        message.extend_from_slice(&challenge);
        message
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AuthChallengePurpose {
    Enrollment,
    TokenExchange,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentRequest {
    pub owner_username: String,
    pub owner_password: String,
    pub device_name: String,
    pub platform: String,
    pub public_key: String,
    pub challenge_id: String,
    pub challenge_signature: String,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentResult {
    pub device_id: String,
    pub refresh_token: String,
    pub credential_type: String,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RefreshExchangeRequest {
    pub device_id: String,
    pub refresh_token: String,
    pub challenge_id: String,
    pub challenge_signature: String,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AccessCredentialResult {
    pub device_id: String,
    pub refresh_token: String,
    pub access_token: String,
    pub token_type: String,
    pub expires_at_unix_seconds: u64,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AccessTokenVerificationRequest {
    pub device_id: String,
    pub access_token: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthorizationResult {
    pub authorized: bool,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceRevocationRequest {
    pub owner_username: String,
    pub owner_password: String,
    pub device_id: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceRevocationResult {
    pub revoked: bool,
}
