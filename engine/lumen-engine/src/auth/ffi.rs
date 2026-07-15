use super::*;

pub struct LumenAuthAuthority {
    inner: Mutex<AuthAuthority>,
}

#[repr(C)]
pub struct LumenAuthHttpResponse {
    pub status_code: u16,
    pub body: *mut c_char,
    pub body_length: usize,
}

impl Default for LumenAuthHttpResponse {
    fn default() -> Self {
        Self {
            status_code: 500,
            body: std::ptr::null_mut(),
            body_length: 0,
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_auth_authority_open(
    owner_file_path: *const c_char,
    device_registry_file_path: *const c_char,
    authority_out: *mut *mut LumenAuthAuthority,
) -> crate::LumenEngineStatus {
    let Some(mut authority_out) = NonNull::new(authority_out) else {
        return crate::LumenEngineStatus::InvalidArgument;
    };
    *authority_out.as_mut() = std::ptr::null_mut();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let owner_file_path = path_from_c_string(owner_file_path)?;
        let device_registry_file_path = path_from_c_string(device_registry_file_path)?;
        let authority = AuthAuthority::open(owner_file_path, device_registry_file_path)
            .map_err(auth_error_to_engine_status)?;
        Ok::<_, crate::LumenEngineStatus>(Box::new(LumenAuthAuthority {
            inner: Mutex::new(authority),
        }))
    }));
    match result {
        Ok(Ok(authority)) => {
            *authority_out.as_mut() = Box::into_raw(authority);
            crate::LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => crate::LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_auth_authority_destroy(authority: *mut LumenAuthAuthority) {
    if !authority.is_null() {
        drop(Box::from_raw(authority));
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_auth_authority_set_device_enrollment_enabled(
    authority: *mut LumenAuthAuthority,
    enabled: u8,
) -> crate::LumenEngineStatus {
    let Some(authority) = authority.as_ref() else {
        return crate::LumenEngineStatus::InvalidArgument;
    };
    let enabled = match enabled {
        0 => false,
        1 => true,
        _ => return crate::LumenEngineStatus::InvalidArgument,
    };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut authority = authority
            .inner
            .lock()
            .map_err(|_| crate::LumenEngineStatus::InvalidState)?;
        authority.set_device_enrollment_enabled(enabled);
        Ok::<_, crate::LumenEngineStatus>(())
    }));
    match result {
        Ok(Ok(())) => crate::LumenEngineStatus::Ok,
        Ok(Err(status)) => status,
        Err(_) => crate::LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_auth_authority_dispatch_json(
    authority: *mut LumenAuthAuthority,
    operation: u32,
    request_body: *const u8,
    request_body_length: usize,
    response_out: *mut LumenAuthHttpResponse,
) -> crate::LumenEngineStatus {
    let Some(authority) = authority.as_ref() else {
        return crate::LumenEngineStatus::InvalidArgument;
    };
    let Some(mut response_out) = NonNull::new(response_out) else {
        return crate::LumenEngineStatus::InvalidArgument;
    };
    *response_out.as_mut() = LumenAuthHttpResponse::default();
    if request_body.is_null() && request_body_length != 0 {
        return crate::LumenEngineStatus::InvalidArgument;
    }
    let Ok(operation) = AuthHttpOperation::try_from(operation) else {
        return crate::LumenEngineStatus::InvalidArgument;
    };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let request_body = if request_body_length == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(request_body, request_body_length)
        };
        let mut authority = authority
            .inner
            .lock()
            .map_err(|_| crate::LumenEngineStatus::InvalidState)?;
        let response = authority.dispatch_http_json(operation, request_body);
        serialize_http_response(response)
    }));
    match result {
        Ok(Ok(response)) => {
            *response_out.as_mut() = response;
            crate::LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => crate::LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_auth_authority_verify_access_token(
    authority: *mut LumenAuthAuthority,
    device_id: *const c_char,
    access_token: *const c_char,
    response_out: *mut LumenAuthHttpResponse,
) -> crate::LumenEngineStatus {
    let Some(authority) = authority.as_ref() else {
        return crate::LumenEngineStatus::InvalidArgument;
    };
    let Some(mut response_out) = NonNull::new(response_out) else {
        return crate::LumenEngineStatus::InvalidArgument;
    };
    *response_out.as_mut() = LumenAuthHttpResponse::default();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let device_id = required_utf8(device_id)?;
        let access_token = required_utf8(access_token)?;
        let authority = authority
            .inner
            .lock()
            .map_err(|_| crate::LumenEngineStatus::InvalidState)?;
        let response = authority.verify_access_token_http(device_id, access_token);
        serialize_http_response(response)
    }));
    match result {
        Ok(Ok(response)) => {
            *response_out.as_mut() = response;
            crate::LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => crate::LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_auth_http_response_destroy(response: *mut LumenAuthHttpResponse) {
    let Some(response) = response.as_mut() else {
        return;
    };
    if !response.body.is_null() {
        drop(CString::from_raw(response.body));
    }
    *response = LumenAuthHttpResponse::default();
}

unsafe fn path_from_c_string(value: *const c_char) -> Result<PathBuf, crate::LumenEngineStatus> {
    if value.is_null() {
        return Err(crate::LumenEngineStatus::InvalidArgument);
    }
    let value = CStr::from_ptr(value)
        .to_str()
        .map_err(|_| crate::LumenEngineStatus::InvalidArgument)?;
    if value.trim().is_empty() {
        return Err(crate::LumenEngineStatus::InvalidArgument);
    }
    Ok(PathBuf::from(value))
}

unsafe fn required_utf8<'a>(value: *const c_char) -> Result<&'a str, crate::LumenEngineStatus> {
    if value.is_null() {
        return Err(crate::LumenEngineStatus::InvalidArgument);
    }
    let value = CStr::from_ptr(value)
        .to_str()
        .map_err(|_| crate::LumenEngineStatus::InvalidArgument)?;
    if value.is_empty() {
        Err(crate::LumenEngineStatus::InvalidArgument)
    } else {
        Ok(value)
    }
}

fn serialize_http_response(
    response: AuthHttpResponse,
) -> Result<LumenAuthHttpResponse, crate::LumenEngineStatus> {
    let serialized = serde_json::to_string(&response.body)
        .map_err(|_| crate::LumenEngineStatus::StorageError)?;
    let body_length = serialized.len();
    let body = CString::new(serialized)
        .map_err(|_| crate::LumenEngineStatus::StorageError)?
        .into_raw();
    Ok(LumenAuthHttpResponse {
        status_code: response.status_code,
        body,
        body_length,
    })
}

fn auth_error_to_engine_status(error: AuthErrorCode) -> crate::LumenEngineStatus {
    match error {
        AuthErrorCode::InvalidRequest => crate::LumenEngineStatus::InvalidArgument,
        AuthErrorCode::DeviceEnrollmentDisabled => crate::LumenEngineStatus::InvalidState,
        AuthErrorCode::InvalidOwnerCredentials
        | AuthErrorCode::InvalidSignature
        | AuthErrorCode::InvalidDeviceCredential
        | AuthErrorCode::AccessTokenExpired
        | AuthErrorCode::Revoked => crate::LumenEngineStatus::AuthenticationFailed,
        AuthErrorCode::InvalidChallenge | AuthErrorCode::ChallengeExpired => {
            crate::LumenEngineStatus::InvalidState
        }
        AuthErrorCode::StorageUnavailable => crate::LumenEngineStatus::StorageError,
        AuthErrorCode::CorruptAuthority => crate::LumenEngineStatus::CorruptData,
    }
}
