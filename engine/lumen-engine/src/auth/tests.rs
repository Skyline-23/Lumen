use super::*;
use crate::device::DeviceStore;
use crate::owner::OwnerStore;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::SigningKey;
use rand_core::OsRng;
use serde_json::Value;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct TestAuthority {
    root: std::path::PathBuf,
    authority: AuthAuthority,
    signing_key: SigningKey,
}

impl TestAuthority {
    fn new(now: u64) -> Self {
        let sequence = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "lumen-auth-authority-{}-{sequence}",
            std::process::id()
        ));
        let owner = OwnerStore::open(root.join("owner-account.json")).unwrap();
        owner
            .create_owner("owner", "correct horse battery staple")
            .unwrap();
        let devices = DeviceStore::open(root.join("devices.json")).unwrap();
        let signing_key = SigningKey::random(&mut OsRng);
        let authority = AuthAuthority::with_now_for_testing(owner, devices, now);
        Self {
            root,
            authority,
            signing_key,
        }
    }

    fn public_key(&self) -> String {
        URL_SAFE_NO_PAD.encode(
            self.signing_key
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes(),
        )
    }

    fn sign(&self, challenge: &AuthChallenge) -> String {
        let signature: p256::ecdsa::Signature = self.signing_key.sign(&challenge.signing_message());
        URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes())
    }

    fn enroll(&mut self) -> EnrollmentResult {
        let challenge = self
            .authority
            .issue_enrollment_challenge(self.public_key())
            .unwrap();
        self.authority
            .enroll(EnrollmentRequest {
                owner_username: "owner".into(),
                owner_password: "correct horse battery staple".into(),
                device_name: "Living Room Tablet".into(),
                platform: "ios".into(),
                public_key: self.public_key(),
                challenge_id: challenge.challenge_id.clone(),
                challenge_signature: self.sign(&challenge),
            })
            .unwrap()
    }

    fn exchange(
        &mut self,
        device_id: String,
        refresh_token: String,
    ) -> Result<AccessCredentialResult, AuthErrorCode> {
        let challenge = self.authority.issue_refresh_challenge(&device_id)?;
        let signature = self.sign(&challenge);
        self.authority
            .exchange_refresh_token(RefreshExchangeRequest {
                device_id,
                refresh_token,
                challenge_id: challenge.challenge_id,
                challenge_signature: signature,
            })
    }
}

impl Drop for TestAuthority {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn auth_fixture_defines_versioned_source_neutral_envelopes() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/protocol/lumen-auth-conformance.json"
    )))
    .unwrap();

    assert_eq!(fixture["schemaVersion"], AUTH_SCHEMA_VERSION);
    assert_eq!(fixture["networkTransport"]["scheme"], "https");
    assert_eq!(
        fixture["accessRequestAuthentication"]["authorizationHeader"],
        "Authorization: Bearer <accessToken>"
    );
    assert_eq!(
        fixture["accessRequestAuthentication"]["authorizationHeaderName"]["matching"],
        "ascii-case-insensitive"
    );
    assert_eq!(
        fixture["accessRequestAuthentication"]["deviceIdHeader"]["name"],
        "Lumen-Device-ID"
    );
    assert_eq!(
        fixture["accessRequestAuthentication"]["deviceIdHeader"]["matching"],
        "ascii-case-insensitive"
    );
    assert_eq!(
        fixture["accessRequestAuthentication"]["queryParameters"],
        "forbidden"
    );
    assert_eq!(
        fixture["accessRequestAuthentication"]["cookies"],
        "forbidden"
    );
    assert_eq!(
        fixture["accessRequestAuthentication"]["basicAuthentication"],
        "forbidden"
    );
    assert_eq!(
        fixture["networkTransport"]["routes"]["enrollmentChallenge"],
        "/api/v1/auth/enrollment-challenge"
    );
    assert_eq!(
        fixture["networkTransport"]["routes"]["tokenExchange"],
        "/api/v1/auth/token"
    );
    assert_eq!(
        fixture["protectedRoutes"]["streamCancel"]["path"],
        "/cancel"
    );
    assert_eq!(
        fixture["protectedRoutes"]["streamClipboardRead"]["method"],
        "GET"
    );
    assert_eq!(
        fixture["protectedRoutes"]["streamClipboardWrite"]["method"],
        "POST"
    );
    assert_eq!(
        fixture["credentialPolicy"]["accessTokenLifetimeSeconds"],
        900
    );
    assert_eq!(
        fixture["credentialPolicy"]["refreshTokenRotation"],
        "required"
    );
    assert_eq!(
        fixture["deviceEnrollmentPolicy"]["scope"],
        "local-host-only"
    );
    assert_eq!(
        fixture["deviceEnrollmentPolicy"]["configKey"],
        "device_enrollment_enabled"
    );
    assert_eq!(
        fixture["deviceEnrollmentPolicy"]["disabledError"],
        "device-enrollment-disabled"
    );
    assert_eq!(fixture["possessionProof"]["algorithm"], "p256-ecdsa-sha256");
    assert_eq!(fixture["envelopes"]["error"]["error"]["code"], "revoked");

    let envelope = AuthRequestEnvelope {
        schema_version: AUTH_SCHEMA_VERSION,
        request_id: "request-1".to_owned(),
        request: EnrollmentChallengeRequest {
            public_key: "public-key".to_owned(),
        },
    };
    assert!(envelope.validate().is_ok());
    assert_eq!(
        serde_json::to_value(envelope).unwrap(),
        serde_json::json!({
            "schemaVersion": 1,
            "requestId": "request-1",
            "request": { "publicKey": "public-key" }
        })
    );
    assert_eq!(
        AuthRequestEnvelope {
            schema_version: 2,
            request_id: "request-2".to_owned(),
            request: (),
        }
        .validate(),
        Err(AuthErrorCode::InvalidRequest)
    );
}

#[test]
fn discovery_host_reports_ready_device_auth_without_pairing_semantics() {
    let control_router_source = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../lumen-host/src/control.rs"
    ));
    let discovery_source = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../lumen-host/src/control/discovery.rs"
    ));

    assert!(control_router_source.contains("/api/discovery/host"));
    assert!(control_router_source.contains("self.authorize(request)"));
    assert!(!discovery_source.contains("pairStatus"));
    assert!(!discovery_source.contains("notPaired"));
    assert!(discovery_source.contains("device_authentication: \"ready\""));
    assert!(discovery_source.contains("LUMEN_SERVER_FREE"));
}

#[test]
fn challenge_signing_messages_are_domain_separated_and_device_bound() {
    let raw_challenge: Vec<u8> = (0_u8..32).collect();
    let encoded_challenge = URL_SAFE_NO_PAD.encode(&raw_challenge);
    let enrollment = AuthChallenge {
        challenge_id: "challenge-1".to_owned(),
        challenge: encoded_challenge.clone(),
        algorithm: AuthSignatureAlgorithm::P256EcdsaSha256,
        purpose: AuthChallengePurpose::Enrollment,
        device_id: None,
        expires_at_unix_seconds: 300,
    };
    let token_exchange = AuthChallenge {
        challenge_id: "challenge-2".to_owned(),
        challenge: encoded_challenge,
        algorithm: AuthSignatureAlgorithm::P256EcdsaSha256,
        purpose: AuthChallengePurpose::TokenExchange,
        device_id: Some("device-1".to_owned()),
        expires_at_unix_seconds: 300,
    };

    let mut expected_enrollment = b"LUMEN-AUTH-ENROLLMENT-V1\0".to_vec();
    expected_enrollment.extend_from_slice(&raw_challenge);
    assert_eq!(enrollment.signing_message(), expected_enrollment);

    let mut expected_exchange = b"LUMEN-AUTH-TOKEN-EXCHANGE-V1\0device-1\0".to_vec();
    expected_exchange.extend_from_slice(&raw_challenge);
    assert_eq!(token_exchange.signing_message(), expected_exchange);
    assert_ne!(
        enrollment.signing_message(),
        token_exchange.signing_message()
    );
    assert_eq!(
        serde_json::to_value(token_exchange).unwrap()["algorithm"],
        "p256-ecdsa-sha256"
    );
}

#[test]
fn enrollment_requires_a_valid_single_use_key_possession_proof() {
    let mut test = TestAuthority::new(1_000);
    let challenge = test
        .authority
        .issue_enrollment_challenge(test.public_key())
        .unwrap();
    let mut signature = test.sign(&challenge);
    signature.replace_range(0..1, if signature.starts_with('A') { "B" } else { "A" });

    let request = EnrollmentRequest {
        owner_username: "owner".into(),
        owner_password: "correct horse battery staple".into(),
        device_name: "Living Room Tablet".into(),
        platform: "ios".into(),
        public_key: test.public_key(),
        challenge_id: challenge.challenge_id,
        challenge_signature: signature,
    };
    assert!(matches!(
        test.authority.enroll(request.clone()),
        Err(AuthErrorCode::InvalidSignature)
    ));
    assert!(matches!(
        test.authority.enroll(request),
        Err(AuthErrorCode::InvalidChallenge)
    ));
}

#[test]
fn disabled_device_enrollment_rejects_new_devices_without_affecting_existing_auth() {
    let mut test = TestAuthority::new(2_000);
    let enrollment = test.enroll();
    let access = test
        .exchange(enrollment.device_id.clone(), enrollment.refresh_token)
        .unwrap();
    let pending_enrollment = test
        .authority
        .issue_enrollment_challenge(test.public_key())
        .unwrap();
    let pending_enrollment_signature = test.sign(&pending_enrollment);

    test.authority.set_device_enrollment_enabled(false);

    assert_eq!(
        test.authority.issue_enrollment_challenge(test.public_key()),
        Err(AuthErrorCode::DeviceEnrollmentDisabled)
    );
    let enrollment_request = serde_json::to_vec(&AuthRequestEnvelope {
        schema_version: AUTH_SCHEMA_VERSION,
        request_id: "disabled-enrollment".to_owned(),
        request: EnrollmentRequest {
            owner_username: "owner".into(),
            owner_password: "correct horse battery staple".into(),
            device_name: "New Tablet".into(),
            platform: "ios".into(),
            public_key: test.public_key(),
            challenge_id: pending_enrollment.challenge_id,
            challenge_signature: pending_enrollment_signature,
        },
    })
    .unwrap();
    let rejected = test
        .authority
        .dispatch_http_json(AuthHttpOperation::Enroll, &enrollment_request);
    assert_eq!(rejected.status_code, 403);
    assert_eq!(rejected.body["requestId"], "disabled-enrollment");
    assert_eq!(rejected.body["error"]["code"], "device-enrollment-disabled");
    assert_eq!(rejected.body["error"]["retryable"], true);

    assert!(test
        .authority
        .verify_access_token(&enrollment.device_id, &access.access_token)
        .is_ok());
    let rotated = test
        .exchange(enrollment.device_id.clone(), access.refresh_token)
        .unwrap();
    assert!(test
        .authority
        .verify_access_token(&enrollment.device_id, &rotated.access_token)
        .is_ok());

    test.authority.set_device_enrollment_enabled(true);
    let retry_after_reenable = test
        .authority
        .dispatch_http_json(AuthHttpOperation::Enroll, &enrollment_request);
    assert_eq!(retry_after_reenable.status_code, 409);
    assert_eq!(
        retry_after_reenable.body["error"]["code"],
        "invalid-challenge"
    );
    assert!(test
        .authority
        .issue_enrollment_challenge(test.public_key())
        .is_ok());
}

#[test]
fn enrollment_reports_owner_failure_and_expired_challenge_as_typed_errors() {
    let mut test = TestAuthority::new(5_000);
    let expired_challenge = test
        .authority
        .issue_enrollment_challenge(test.public_key())
        .unwrap();
    test.authority.set_now_for_testing(5_301);
    let expired_signature = test.sign(&expired_challenge);
    assert!(matches!(
        test.authority.enroll(EnrollmentRequest {
            owner_username: "owner".into(),
            owner_password: "correct horse battery staple".into(),
            device_name: "Tablet".into(),
            platform: "ios".into(),
            public_key: test.public_key(),
            challenge_id: expired_challenge.challenge_id,
            challenge_signature: expired_signature,
        }),
        Err(AuthErrorCode::ChallengeExpired)
    ));

    let challenge = test
        .authority
        .issue_enrollment_challenge(test.public_key())
        .unwrap();
    let signature = test.sign(&challenge);
    assert!(matches!(
        test.authority.enroll(EnrollmentRequest {
            owner_username: "owner".into(),
            owner_password: "wrong password".into(),
            device_name: "Tablet".into(),
            platform: "ios".into(),
            public_key: test.public_key(),
            challenge_id: challenge.challenge_id,
            challenge_signature: signature,
        }),
        Err(AuthErrorCode::InvalidOwnerCredentials)
    ));
}

#[test]
fn refresh_exchange_rotates_refresh_and_issues_expiring_access_token() {
    let mut test = TestAuthority::new(10_000);
    let enrollment = test.enroll();
    let exchange = test
        .exchange(
            enrollment.device_id.clone(),
            enrollment.refresh_token.clone(),
        )
        .unwrap();

    assert_eq!(exchange.expires_at_unix_seconds, 10_900);
    let persisted = fs::read_to_string(test.root.join("devices.json")).unwrap();
    assert!(!persisted.contains(&exchange.refresh_token));
    assert!(!persisted.contains(&exchange.access_token));
    assert!(persisted.contains("refresh_token_hash"));
    assert!(persisted.contains("access_token_hash"));
    assert!(test
        .authority
        .verify_access_token(&enrollment.device_id, &exchange.access_token)
        .is_ok());
    let authorized = test
        .authority
        .verify_access_token_http(&enrollment.device_id, &exchange.access_token);
    assert_eq!(authorized.status_code, 200);
    assert_eq!(authorized.body["requestId"], "");
    assert_eq!(authorized.body["result"]["authorized"], true);
    assert!(matches!(
        test.exchange(enrollment.device_id.clone(), enrollment.refresh_token),
        Err(AuthErrorCode::InvalidDeviceCredential)
    ));

    let replacement = test
        .exchange(enrollment.device_id.clone(), exchange.refresh_token.clone())
        .unwrap();
    assert_eq!(
        test.authority
            .verify_access_token(&enrollment.device_id, &exchange.access_token),
        Err(AuthErrorCode::InvalidDeviceCredential)
    );
    assert!(test
        .authority
        .verify_access_token(&enrollment.device_id, &replacement.access_token)
        .is_ok());

    test.authority.set_now_for_testing(10_901);
    assert_eq!(
        test.authority
            .verify_access_token(&enrollment.device_id, &replacement.access_token),
        Err(AuthErrorCode::AccessTokenExpired)
    );
    let expired = test
        .authority
        .verify_access_token_http(&enrollment.device_id, &replacement.access_token);
    assert_eq!(expired.status_code, 401);
    assert_eq!(expired.body["error"]["code"], "access-token-expired");
}

#[test]
fn refresh_exchange_rejects_bad_signature_and_challenge_replay() {
    let mut test = TestAuthority::new(15_000);
    let enrollment = test.enroll();
    let challenge = test
        .authority
        .issue_refresh_challenge(&enrollment.device_id)
        .unwrap();
    let mut signature = test.sign(&challenge);
    signature.replace_range(0..1, if signature.starts_with('A') { "B" } else { "A" });
    let request = RefreshExchangeRequest {
        device_id: enrollment.device_id.clone(),
        refresh_token: enrollment.refresh_token.clone(),
        challenge_id: challenge.challenge_id,
        challenge_signature: signature,
    };

    assert!(matches!(
        test.authority.exchange_refresh_token(request.clone()),
        Err(AuthErrorCode::InvalidSignature)
    ));
    assert!(matches!(
        test.authority.exchange_refresh_token(request),
        Err(AuthErrorCode::InvalidChallenge)
    ));
    assert!(test
        .exchange(enrollment.device_id, enrollment.refresh_token)
        .is_ok());
}

#[test]
fn revocation_and_factory_reset_invalidate_every_credential_immediately() {
    let mut test = TestAuthority::new(20_000);
    let first = test.enroll();
    let first_exchange = test
        .exchange(first.device_id.clone(), first.refresh_token)
        .unwrap();
    let mut independent_verifier = AuthAuthority::open(
        test.root.join("owner-account.json"),
        test.root.join("devices.json"),
    )
    .unwrap();
    independent_verifier.set_now_for_testing(20_000);
    assert!(independent_verifier
        .verify_access_token(&first.device_id, &first_exchange.access_token)
        .is_ok());
    test.authority
        .revoke_device("owner", "correct horse battery staple", &first.device_id)
        .unwrap();
    assert_eq!(
        test.authority
            .verify_access_token(&first.device_id, &first_exchange.access_token),
        Err(AuthErrorCode::Revoked)
    );
    let revoked = independent_verifier
        .verify_access_token_http(&first.device_id, &first_exchange.access_token);
    assert_eq!(revoked.status_code, 401);
    assert_eq!(revoked.body["error"]["code"], "revoked");

    let second = test.enroll();
    let second_exchange = test
        .exchange(second.device_id.clone(), second.refresh_token)
        .unwrap();
    fs::remove_file(test.root.join("devices.json")).unwrap();
    assert_eq!(
        test.authority
            .verify_access_token(&second.device_id, &second_exchange.access_token),
        Err(AuthErrorCode::InvalidDeviceCredential)
    );
}

#[test]
fn http_dispatch_rejects_malformed_and_unknown_envelope_fields_with_typed_errors() {
    let mut test = TestAuthority::new(25_000);

    let malformed = test.authority.dispatch_http_json(
        AuthHttpOperation::EnrollmentChallenge,
        br#"{"schemaVersion":1,"requestId":"bad-json""#,
    );
    assert_eq!(malformed.status_code, 400);
    assert_eq!(malformed.body["schemaVersion"], 1);
    assert_eq!(malformed.body["requestId"], "");
    assert_eq!(malformed.body["error"]["code"], "invalid-request");

    let unknown = test.authority.dispatch_http_json(
        AuthHttpOperation::EnrollmentChallenge,
        serde_json::to_string(&serde_json::json!({
            "schemaVersion": 1,
            "requestId": "unknown-field",
            "request": { "publicKey": test.public_key() },
            "ownerPassword": "must-not-be-accepted"
        }))
        .unwrap()
        .as_bytes(),
    );
    assert_eq!(unknown.status_code, 400);
    assert_eq!(unknown.body["requestId"], "unknown-field");
    assert_eq!(unknown.body["error"]["code"], "invalid-request");
    assert!(!unknown.body.to_string().contains("must-not-be-accepted"));
}

#[test]
fn http_dispatch_replays_enrollment_response_for_matching_request_id_only() {
    let mut test = TestAuthority::new(30_000);
    let challenge_response = test.authority.dispatch_http_json(
        AuthHttpOperation::EnrollmentChallenge,
        serde_json::to_string(&AuthRequestEnvelope {
            schema_version: AUTH_SCHEMA_VERSION,
            request_id: "challenge-request".to_owned(),
            request: EnrollmentChallengeRequest {
                public_key: test.public_key(),
            },
        })
        .unwrap()
        .as_bytes(),
    );
    assert_eq!(challenge_response.status_code, 200);
    let challenge: AuthChallenge =
        serde_json::from_value(challenge_response.body["result"].clone()).unwrap();

    let request = AuthRequestEnvelope {
        schema_version: AUTH_SCHEMA_VERSION,
        request_id: "enroll-request".to_owned(),
        request: EnrollmentRequest {
            owner_username: "owner".into(),
            owner_password: "correct horse battery staple".into(),
            device_name: "Living Room Tablet".into(),
            platform: "ios".into(),
            public_key: test.public_key(),
            challenge_id: challenge.challenge_id.clone(),
            challenge_signature: test.sign(&challenge),
        },
    };
    let request_json = serde_json::to_vec(&request).unwrap();
    let first = test
        .authority
        .dispatch_http_json(AuthHttpOperation::Enroll, &request_json);
    let retry = test
        .authority
        .dispatch_http_json(AuthHttpOperation::Enroll, &request_json);
    assert_eq!(first.status_code, 200);
    assert!(retry == first);

    let mut collision: serde_json::Value = serde_json::from_slice(&request_json).unwrap();
    collision["request"]["deviceName"] = "Different Device".into();
    let collision = test.authority.dispatch_http_json(
        AuthHttpOperation::Enroll,
        &serde_json::to_vec(&collision).unwrap(),
    );
    assert_eq!(collision.status_code, 400);
    assert_eq!(collision.body["error"]["code"], "invalid-request");
}

#[test]
fn http_dispatch_replays_token_rotation_without_invalidating_the_returned_credential() {
    let mut test = TestAuthority::new(35_000);
    let enrollment = test.enroll();
    let challenge = test
        .authority
        .issue_refresh_challenge(&enrollment.device_id)
        .unwrap();
    let request = AuthRequestEnvelope {
        schema_version: AUTH_SCHEMA_VERSION,
        request_id: "rotate-request".to_owned(),
        request: RefreshExchangeRequest {
            device_id: enrollment.device_id.clone(),
            refresh_token: enrollment.refresh_token,
            challenge_id: challenge.challenge_id.clone(),
            challenge_signature: test.sign(&challenge),
        },
    };
    let request_json = serde_json::to_vec(&request).unwrap();
    let first = test
        .authority
        .dispatch_http_json(AuthHttpOperation::Token, &request_json);
    let retry = test
        .authority
        .dispatch_http_json(AuthHttpOperation::Token, &request_json);
    assert_eq!(first.status_code, 200);
    assert!(retry == first);
    assert!(test
        .authority
        .verify_access_token(
            &enrollment.device_id,
            first.body["result"]["accessToken"].as_str().unwrap()
        )
        .is_ok());
}

#[test]
fn http_dispatch_maps_revocation_failures_to_typed_authentication_status() {
    let mut test = TestAuthority::new(40_000);
    let enrollment = test.enroll();
    let response = test.authority.dispatch_http_json(
        AuthHttpOperation::Revoke,
        &serde_json::to_vec(&AuthRequestEnvelope {
            schema_version: AUTH_SCHEMA_VERSION,
            request_id: "revoke-request".to_owned(),
            request: DeviceRevocationRequest {
                owner_username: "owner".into(),
                owner_password: "wrong password".into(),
                device_id: enrollment.device_id,
            },
        })
        .unwrap(),
    );
    assert_eq!(response.status_code, 401);
    assert_eq!(response.body["error"]["code"], "invalid-owner-credentials");
    assert!(!response.body.to_string().contains("wrong password"));
}

#[test]
fn ffi_json_dispatch_owns_and_releases_one_serialized_authority_response() {
    let sequence = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let root =
        std::env::temp_dir().join(format!("lumen-auth-ffi-{}-{sequence}", std::process::id()));
    let owner_path =
        CString::new(root.join("owner-account.json").to_string_lossy().as_bytes()).unwrap();
    let device_path = CString::new(root.join("devices.json").to_string_lossy().as_bytes()).unwrap();
    let mut authority = std::ptr::null_mut();
    assert_eq!(
        unsafe {
            lumen_auth_authority_open(owner_path.as_ptr(), device_path.as_ptr(), &mut authority)
        },
        crate::LumenEngineStatus::Ok
    );
    assert!(!authority.is_null());
    assert_eq!(
        unsafe { lumen_auth_authority_set_device_enrollment_enabled(authority, 2) },
        crate::LumenEngineStatus::InvalidArgument
    );
    assert_eq!(
        unsafe { lumen_auth_authority_set_device_enrollment_enabled(authority, 0) },
        crate::LumenEngineStatus::Ok
    );

    let disabled_body =
        br#"{"schemaVersion":1,"requestId":"ffi-disabled","request":{"publicKey":"invalid"}}"#;
    let mut disabled_response = LumenAuthHttpResponse::default();
    assert_eq!(
        unsafe {
            lumen_auth_authority_dispatch_json(
                authority,
                AuthHttpOperation::EnrollmentChallenge as u32,
                disabled_body.as_ptr(),
                disabled_body.len(),
                &mut disabled_response,
            )
        },
        crate::LumenEngineStatus::Ok
    );
    assert_eq!(disabled_response.status_code, 403);
    let disabled_serialized = unsafe {
        std::slice::from_raw_parts(
            disabled_response.body.cast::<u8>(),
            disabled_response.body_length,
        )
    };
    let disabled_parsed: Value = serde_json::from_slice(disabled_serialized).unwrap();
    assert_eq!(
        disabled_parsed["error"]["code"],
        "device-enrollment-disabled"
    );
    unsafe {
        lumen_auth_http_response_destroy(&mut disabled_response);
    }
    assert_eq!(
        unsafe { lumen_auth_authority_set_device_enrollment_enabled(authority, 1) },
        crate::LumenEngineStatus::Ok
    );

    let device_id = CString::new("unknown-device").unwrap();
    let access_token = CString::new("unknown-token").unwrap();
    let mut verification_response = LumenAuthHttpResponse::default();
    assert_eq!(
        unsafe {
            lumen_auth_authority_verify_access_token(
                authority,
                device_id.as_ptr(),
                access_token.as_ptr(),
                &mut verification_response,
            )
        },
        crate::LumenEngineStatus::Ok
    );
    assert_eq!(verification_response.status_code, 401);
    let verification_body = unsafe {
        std::slice::from_raw_parts(
            verification_response.body.cast::<u8>(),
            verification_response.body_length,
        )
    };
    let verification_body: Value = serde_json::from_slice(verification_body).unwrap();
    assert_eq!(
        verification_body["error"]["code"],
        "invalid-device-credential"
    );
    unsafe {
        lumen_auth_http_response_destroy(&mut verification_response);
    }

    let body =
        br#"{"schemaVersion":1,"requestId":"ffi-request","request":{"publicKey":"invalid"}}"#;
    let mut response = LumenAuthHttpResponse::default();
    assert_eq!(
        unsafe {
            lumen_auth_authority_dispatch_json(
                authority,
                AuthHttpOperation::EnrollmentChallenge as u32,
                body.as_ptr(),
                body.len(),
                &mut response,
            )
        },
        crate::LumenEngineStatus::Ok
    );
    assert_eq!(response.status_code, 400);
    let serialized =
        unsafe { std::slice::from_raw_parts(response.body.cast::<u8>(), response.body_length) };
    let parsed: Value = serde_json::from_slice(serialized).unwrap();
    assert_eq!(parsed["requestId"], "ffi-request");
    assert_eq!(parsed["error"]["code"], "invalid-request");

    unsafe {
        lumen_auth_http_response_destroy(&mut response);
    }
    assert!(response.body.is_null());
    assert_eq!(response.body_length, 0);
    assert_eq!(
        unsafe {
            lumen_auth_authority_dispatch_json(
                authority,
                99,
                body.as_ptr(),
                body.len(),
                &mut response,
            )
        },
        crate::LumenEngineStatus::InvalidArgument
    );
    assert!(response.body.is_null());
    unsafe {
        lumen_auth_authority_destroy(authority);
    }
    let _ = fs::remove_dir_all(root);
}
