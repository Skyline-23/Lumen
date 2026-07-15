use super::*;

pub(super) fn parse_public_key(public_key: &str) -> Result<VerifyingKey, AuthErrorCode> {
    let bytes = URL_SAFE_NO_PAD
        .decode(public_key)
        .map_err(|_| AuthErrorCode::InvalidRequest)?;
    if bytes.len() != P256_X963_PUBLIC_KEY_BYTE_COUNT || bytes.first() != Some(&0x04) {
        return Err(AuthErrorCode::InvalidRequest);
    }
    VerifyingKey::from_sec1_bytes(&bytes).map_err(|_| AuthErrorCode::InvalidRequest)
}

pub(super) fn verify_signature(
    public_key: &str,
    message: &[u8],
    signature: &str,
) -> Result<(), AuthErrorCode> {
    let public_key = parse_public_key(public_key)?;
    let signature = URL_SAFE_NO_PAD
        .decode(signature)
        .map_err(|_| AuthErrorCode::InvalidSignature)?;
    let signature = Signature::from_der(&signature).map_err(|_| AuthErrorCode::InvalidSignature)?;
    public_key
        .verify(message, &signature)
        .map_err(|_| AuthErrorCode::InvalidSignature)
}

pub(super) fn random_token(byte_count: usize) -> String {
    let mut bytes = vec![0; byte_count];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub(super) fn map_enrollment_error(error: DeviceStoreError) -> AuthErrorCode {
    match error {
        DeviceStoreError::InvalidArgument | DeviceStoreError::AlreadyExists => {
            AuthErrorCode::InvalidRequest
        }
        DeviceStoreError::AuthenticationFailed => AuthErrorCode::InvalidOwnerCredentials,
        DeviceStoreError::Revoked => AuthErrorCode::Revoked,
        DeviceStoreError::AccessTokenExpired => AuthErrorCode::AccessTokenExpired,
        DeviceStoreError::Storage => AuthErrorCode::StorageUnavailable,
        DeviceStoreError::Corrupt => AuthErrorCode::CorruptAuthority,
    }
}

pub(super) fn map_owner_store_error(error: OwnerStoreError) -> AuthErrorCode {
    match error {
        OwnerStoreError::InvalidArgument | OwnerStoreError::AlreadyExists => {
            AuthErrorCode::InvalidRequest
        }
        OwnerStoreError::Missing | OwnerStoreError::AuthenticationFailed => {
            AuthErrorCode::InvalidOwnerCredentials
        }
        OwnerStoreError::Storage => AuthErrorCode::StorageUnavailable,
        OwnerStoreError::Corrupt => AuthErrorCode::CorruptAuthority,
    }
}

pub(super) fn map_device_credential_error(error: DeviceStoreError) -> AuthErrorCode {
    match error {
        DeviceStoreError::InvalidArgument
        | DeviceStoreError::AlreadyExists
        | DeviceStoreError::AuthenticationFailed => AuthErrorCode::InvalidDeviceCredential,
        DeviceStoreError::Revoked => AuthErrorCode::Revoked,
        DeviceStoreError::AccessTokenExpired => AuthErrorCode::AccessTokenExpired,
        DeviceStoreError::Storage => AuthErrorCode::StorageUnavailable,
        DeviceStoreError::Corrupt => AuthErrorCode::CorruptAuthority,
    }
}
