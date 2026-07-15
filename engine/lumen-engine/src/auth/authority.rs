use super::support::*;
use super::*;

#[derive(Clone, Debug)]
struct PendingChallenge {
    public_key: String,
    challenge: AuthChallenge,
}

pub struct AuthAuthority {
    owner_store: OwnerStore,
    device_store: DeviceStore,
    device_enrollment_enabled: bool,
    pending_challenges: BTreeMap<String, PendingChallenge>,
    idempotent_responses: BTreeMap<(AuthHttpOperation, String), CachedAuthHttpResponse>,
    idempotent_response_order: VecDeque<(AuthHttpOperation, String)>,
    now_override: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
#[repr(u32)]
pub enum AuthHttpOperation {
    EnrollmentChallenge = 0,
    Enroll = 1,
    TokenChallenge = 2,
    Token = 3,
    Revoke = 4,
}

impl TryFrom<u32> for AuthHttpOperation {
    type Error = ();

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::EnrollmentChallenge),
            1 => Ok(Self::Enroll),
            2 => Ok(Self::TokenChallenge),
            3 => Ok(Self::Token),
            4 => Ok(Self::Revoke),
            _ => Err(()),
        }
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct AuthHttpResponse {
    pub status_code: u16,
    pub body: Value,
}

#[derive(Clone)]
struct CachedAuthHttpResponse {
    request_fingerprint: [u8; 32],
    response: AuthHttpResponse,
}

impl AuthAuthority {
    pub fn open(
        owner_file_path: PathBuf,
        device_registry_file_path: PathBuf,
    ) -> Result<Self, AuthErrorCode> {
        let owner_store = OwnerStore::open(owner_file_path).map_err(map_owner_store_error)?;
        let device_store =
            DeviceStore::open(device_registry_file_path).map_err(map_device_credential_error)?;
        Ok(Self::new(owner_store, device_store))
    }

    fn new(owner_store: OwnerStore, device_store: DeviceStore) -> Self {
        Self {
            owner_store,
            device_store,
            device_enrollment_enabled: true,
            pending_challenges: BTreeMap::new(),
            idempotent_responses: BTreeMap::new(),
            idempotent_response_order: VecDeque::new(),
            now_override: None,
        }
    }

    #[cfg(test)]
    pub(crate) fn with_now_for_testing(
        owner_store: OwnerStore,
        device_store: DeviceStore,
        now_unix_seconds: u64,
    ) -> Self {
        let mut authority = Self::new(owner_store, device_store);
        authority.now_override = Some(now_unix_seconds);
        authority
    }

    pub fn issue_enrollment_challenge(
        &mut self,
        public_key: String,
    ) -> Result<AuthChallenge, AuthErrorCode> {
        if !self.device_enrollment_enabled {
            return Err(AuthErrorCode::DeviceEnrollmentDisabled);
        }
        parse_public_key(&public_key)?;
        self.issue_challenge(public_key, AuthChallengePurpose::Enrollment, None)
    }

    pub fn set_device_enrollment_enabled(&mut self, enabled: bool) {
        if self.device_enrollment_enabled == enabled {
            return;
        }
        self.device_enrollment_enabled = enabled;
        if !enabled {
            self.pending_challenges
                .retain(|_, pending| pending.challenge.purpose != AuthChallengePurpose::Enrollment);
        }
        self.idempotent_responses.retain(|(operation, _), _| {
            !matches!(
                operation,
                AuthHttpOperation::EnrollmentChallenge | AuthHttpOperation::Enroll
            )
        });
        self.idempotent_response_order.retain(|(operation, _)| {
            !matches!(
                operation,
                AuthHttpOperation::EnrollmentChallenge | AuthHttpOperation::Enroll
            )
        });
    }

    pub fn issue_refresh_challenge(
        &mut self,
        device_id: &str,
    ) -> Result<AuthChallenge, AuthErrorCode> {
        let public_key = self
            .device_store
            .public_key_for_active_device(device_id)
            .map_err(map_device_credential_error)?;
        parse_public_key(&public_key).map_err(|_| AuthErrorCode::InvalidDeviceCredential)?;
        self.issue_challenge(
            public_key,
            AuthChallengePurpose::TokenExchange,
            Some(device_id.to_owned()),
        )
    }

    pub fn enroll(
        &mut self,
        request: EnrollmentRequest,
    ) -> Result<EnrollmentResult, AuthErrorCode> {
        if !self.device_enrollment_enabled {
            return Err(AuthErrorCode::DeviceEnrollmentDisabled);
        }
        let pending = self
            .pending_challenges
            .remove(&request.challenge_id)
            .ok_or(AuthErrorCode::InvalidChallenge)?;
        if pending.challenge.purpose != AuthChallengePurpose::Enrollment
            || pending.challenge.device_id.is_some()
        {
            return Err(AuthErrorCode::InvalidChallenge);
        }
        if self.now_unix_seconds()? >= pending.challenge.expires_at_unix_seconds {
            return Err(AuthErrorCode::ChallengeExpired);
        }
        if request.public_key != pending.public_key {
            return Err(AuthErrorCode::InvalidSignature);
        }
        verify_signature(
            &request.public_key,
            &pending.challenge.signing_message(),
            &request.challenge_signature,
        )?;
        let enrollment = self
            .device_store
            .enroll(
                &self.owner_store,
                &request.owner_username,
                &request.owner_password,
                &request.device_name,
                &request.platform,
                &request.public_key,
            )
            .map_err(map_enrollment_error)?;
        Ok(EnrollmentResult {
            device_id: enrollment.device_id,
            refresh_token: enrollment.refresh_token,
            credential_type: "lumen-device-refresh".to_owned(),
        })
    }

    pub fn exchange_refresh_token(
        &mut self,
        request: RefreshExchangeRequest,
    ) -> Result<AccessCredentialResult, AuthErrorCode> {
        let pending = self
            .pending_challenges
            .remove(&request.challenge_id)
            .ok_or(AuthErrorCode::InvalidChallenge)?;
        if pending.challenge.purpose != AuthChallengePurpose::TokenExchange
            || pending.challenge.device_id.as_deref() != Some(request.device_id.as_str())
        {
            return Err(AuthErrorCode::InvalidChallenge);
        }
        let now = self.now_unix_seconds()?;
        if now >= pending.challenge.expires_at_unix_seconds {
            return Err(AuthErrorCode::ChallengeExpired);
        }
        verify_signature(
            &pending.public_key,
            &pending.challenge.signing_message(),
            &request.challenge_signature,
        )?;
        let expires_at = now
            .checked_add(AUTH_ACCESS_TOKEN_LIFETIME_SECONDS)
            .ok_or(AuthErrorCode::StorageUnavailable)?;
        let issued = self
            .device_store
            .rotate_refresh_token_and_issue_access(
                &request.device_id,
                &request.refresh_token,
                expires_at,
            )
            .map_err(map_device_credential_error)?;
        Ok(AccessCredentialResult {
            device_id: request.device_id,
            refresh_token: issued.refresh_token,
            access_token: issued.access_token,
            token_type: "Bearer".to_owned(),
            expires_at_unix_seconds: issued.access_token_expires_at_unix_seconds,
        })
    }

    pub fn verify_access_token(
        &self,
        device_id: &str,
        access_token: &str,
    ) -> Result<(), AuthErrorCode> {
        self.device_store
            .verify_access_token(device_id, access_token, self.now_unix_seconds()?)
            .map_err(map_device_credential_error)
    }

    pub fn revoke_device(
        &self,
        owner_username: &str,
        owner_password: &str,
        device_id: &str,
    ) -> Result<(), AuthErrorCode> {
        self.owner_store
            .verify_owner(owner_username, owner_password)
            .map_err(map_owner_store_error)?;
        self.device_store
            .revoke(device_id)
            .map_err(map_device_credential_error)
    }

    pub fn dispatch_http_json(
        &mut self,
        operation: AuthHttpOperation,
        request_body: &[u8],
    ) -> AuthHttpResponse {
        match operation {
            AuthHttpOperation::EnrollmentChallenge => self.dispatch_typed(
                operation,
                request_body,
                |authority, request: EnrollmentChallengeRequest| {
                    authority.issue_enrollment_challenge(request.public_key)
                },
            ),
            AuthHttpOperation::Enroll => self.dispatch_typed(
                operation,
                request_body,
                |authority, request: EnrollmentRequest| authority.enroll(request),
            ),
            AuthHttpOperation::TokenChallenge => self.dispatch_typed(
                operation,
                request_body,
                |authority, request: RefreshChallengeRequest| {
                    authority.issue_refresh_challenge(&request.device_id)
                },
            ),
            AuthHttpOperation::Token => self.dispatch_typed(
                operation,
                request_body,
                |authority, request: RefreshExchangeRequest| {
                    authority.exchange_refresh_token(request)
                },
            ),
            AuthHttpOperation::Revoke => self.dispatch_typed(
                operation,
                request_body,
                |authority, request: DeviceRevocationRequest| {
                    authority.revoke_device(
                        &request.owner_username,
                        &request.owner_password,
                        &request.device_id,
                    )?;
                    Ok(DeviceRevocationResult { revoked: true })
                },
            ),
        }
    }

    pub fn verify_access_token_http(
        &self,
        device_id: &str,
        access_token: &str,
    ) -> AuthHttpResponse {
        match self.verify_access_token(device_id, access_token) {
            Ok(()) => match serde_json::to_value(AuthSuccessEnvelope::new(
                String::new(),
                AuthorizationResult { authorized: true },
            )) {
                Ok(body) => AuthHttpResponse {
                    status_code: 200,
                    body,
                },
                Err(_) => auth_error_response(String::new(), AuthErrorCode::StorageUnavailable),
            },
            Err(error) => auth_error_response(String::new(), error),
        }
    }

    fn dispatch_typed<Request, ResultValue>(
        &mut self,
        operation: AuthHttpOperation,
        request_body: &[u8],
        handler: impl FnOnce(&mut Self, Request) -> Result<ResultValue, AuthErrorCode>,
    ) -> AuthHttpResponse
    where
        Request: for<'de> Deserialize<'de>,
        ResultValue: Serialize,
    {
        let envelope: AuthRequestEnvelope<Request> = match serde_json::from_slice(request_body) {
            Ok(envelope) => envelope,
            Err(_) => {
                return auth_error_response(
                    request_id_from_invalid_envelope(request_body),
                    AuthErrorCode::InvalidRequest,
                )
            }
        };
        if let Err(error) = envelope.validate() {
            return auth_error_response(envelope.request_id, error);
        }

        let request_id = envelope.request_id;
        let cache_key = (operation, request_id.clone());
        let request_fingerprint: [u8; 32] = Sha256::digest(request_body).into();
        if let Some(cached) = self.idempotent_responses.get(&cache_key) {
            return if cached.request_fingerprint == request_fingerprint {
                cached.response.clone()
            } else {
                auth_error_response(request_id, AuthErrorCode::InvalidRequest)
            };
        }

        let response = match handler(self, envelope.request) {
            Ok(result) => {
                match serde_json::to_value(AuthSuccessEnvelope::new(request_id.clone(), result)) {
                    Ok(body) => AuthHttpResponse {
                        status_code: 200,
                        body,
                    },
                    Err(_) => {
                        auth_error_response(request_id.clone(), AuthErrorCode::StorageUnavailable)
                    }
                }
            }
            Err(error) => auth_error_response(request_id.clone(), error),
        };
        if response.status_code != 503 {
            self.cache_http_response(cache_key, request_fingerprint, response.clone());
        }
        response
    }

    fn cache_http_response(
        &mut self,
        key: (AuthHttpOperation, String),
        request_fingerprint: [u8; 32],
        response: AuthHttpResponse,
    ) {
        while self.idempotent_response_order.len() >= MAXIMUM_IDEMPOTENT_RESPONSES {
            if let Some(expired_key) = self.idempotent_response_order.pop_front() {
                self.idempotent_responses.remove(&expired_key);
            }
        }
        self.idempotent_response_order.push_back(key.clone());
        self.idempotent_responses.insert(
            key,
            CachedAuthHttpResponse {
                request_fingerprint,
                response,
            },
        );
    }

    fn now_unix_seconds(&self) -> Result<u64, AuthErrorCode> {
        if let Some(now) = self.now_override {
            return Ok(now);
        }
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .map_err(|_| AuthErrorCode::StorageUnavailable)
    }

    fn issue_challenge(
        &mut self,
        public_key: String,
        purpose: AuthChallengePurpose,
        device_id: Option<String>,
    ) -> Result<AuthChallenge, AuthErrorCode> {
        let now = self.now_unix_seconds()?;
        self.pending_challenges
            .retain(|_, pending| pending.challenge.expires_at_unix_seconds > now);
        if self.pending_challenges.len() >= MAXIMUM_PENDING_CHALLENGES {
            return Err(AuthErrorCode::InvalidRequest);
        }
        let challenge_id = random_token(CHALLENGE_BYTE_COUNT);
        let challenge = AuthChallenge {
            challenge_id: challenge_id.clone(),
            challenge: random_token(CHALLENGE_BYTE_COUNT),
            algorithm: AuthSignatureAlgorithm::P256EcdsaSha256,
            purpose,
            device_id,
            expires_at_unix_seconds: now
                .checked_add(AUTH_CHALLENGE_LIFETIME_SECONDS)
                .ok_or(AuthErrorCode::StorageUnavailable)?,
        };
        self.pending_challenges.insert(
            challenge_id,
            PendingChallenge {
                public_key,
                challenge: challenge.clone(),
            },
        );
        Ok(challenge)
    }

    #[cfg(test)]
    pub(crate) fn set_now_for_testing(&mut self, now_unix_seconds: u64) {
        self.now_override = Some(now_unix_seconds);
    }
}

fn request_id_from_invalid_envelope(request_body: &[u8]) -> String {
    serde_json::from_slice::<Value>(request_body)
        .ok()
        .and_then(|value| value.get("requestId")?.as_str().map(str::to_owned))
        .filter(|request_id| {
            !request_id.trim().is_empty()
                && request_id.len() <= 128
                && !request_id.chars().any(char::is_control)
        })
        .unwrap_or_default()
}

fn auth_error_response(request_id: String, error: AuthErrorCode) -> AuthHttpResponse {
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
    let body =
        serde_json::to_value(AuthErrorEnvelope::new(request_id, error)).unwrap_or_else(|_| {
            serde_json::json!({
                "schemaVersion": AUTH_SCHEMA_VERSION,
                "requestId": "",
                "error": AuthErrorCode::StorageUnavailable.detail()
            })
        });
    AuthHttpResponse { status_code, body }
}
