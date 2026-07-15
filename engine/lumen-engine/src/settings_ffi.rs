use crate::settings::{
    HostSettings, SettingsAuthority, SettingsCapabilities, SettingsErrorCode, SettingsHostPlatform,
    SettingsProtocolError, SETTINGS_SCHEMA_VERSION,
};
use crate::LumenEngineStatus;
use serde::Serialize;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::ptr::NonNull;
use std::sync::Mutex;

const SETTINGS_ABI_VERSION: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenSettingsHostPlatform {
    Macos = 0,
    Windows = 1,
}

impl TryFrom<u32> for LumenSettingsHostPlatform {
    type Error = ();

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::Macos),
            1 => Ok(Self::Windows),
            _ => Err(()),
        }
    }
}

impl From<LumenSettingsHostPlatform> for SettingsHostPlatform {
    fn from(value: LumenSettingsHostPlatform) -> Self {
        match value {
            LumenSettingsHostPlatform::Macos => Self::Macos,
            LumenSettingsHostPlatform::Windows => Self::Windows,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SettingsOperation {
    Snapshot,
    ApplyPatch,
    EventsSince,
    MarkNextSessionStarted,
    MarkWorkerRestarted,
    ApplyLocalUpdate,
    FactoryReset,
    PreviewApplyPatch,
    PreviewNextSessionStarted,
    PreviewWorkerRestarted,
    PreviewFactoryReset,
}

impl TryFrom<u32> for SettingsOperation {
    type Error = ();

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::Snapshot),
            1 => Ok(Self::ApplyPatch),
            2 => Ok(Self::EventsSince),
            3 => Ok(Self::MarkNextSessionStarted),
            4 => Ok(Self::MarkWorkerRestarted),
            5 => Ok(Self::ApplyLocalUpdate),
            6 => Ok(Self::FactoryReset),
            7 => Ok(Self::PreviewApplyPatch),
            8 => Ok(Self::PreviewNextSessionStarted),
            9 => Ok(Self::PreviewWorkerRestarted),
            10 => Ok(Self::PreviewFactoryReset),
            _ => Err(()),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SettingsTransaction {
    ApplyPatch,
    NextSessionStarted,
    WorkerRestarted,
    FactoryReset,
}

impl TryFrom<u32> for SettingsTransaction {
    type Error = ();

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Self::ApplyPatch),
            1 => Ok(Self::NextSessionStarted),
            2 => Ok(Self::WorkerRestarted),
            3 => Ok(Self::FactoryReset),
            _ => Err(()),
        }
    }
}

pub type LumenSettingsPrepareRuntimeCallback =
    unsafe extern "C" fn(*const u8, usize, *mut c_void) -> *const c_char;
pub type LumenSettingsCommitRuntimeCallback = unsafe extern "C" fn(*mut c_void);
pub type LumenSettingsSnapshotRuntimeCallback =
    unsafe extern "C" fn(*mut *const u8, *mut usize, *mut c_void) -> *const c_char;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct LumenSettingsRuntimeTransactionCallbacks {
    pub prepare: Option<LumenSettingsPrepareRuntimeCallback>,
    pub commit: Option<LumenSettingsCommitRuntimeCallback>,
    pub context: *mut c_void,
}

pub struct LumenSettingsAuthority {
    inner: Mutex<SettingsAuthority>,
}

#[repr(C)]
pub struct LumenSettingsResponse {
    pub status_code: u16,
    pub body: *mut c_char,
    pub body_length: usize,
}

impl Default for LumenSettingsResponse {
    fn default() -> Self {
        Self {
            status_code: 500,
            body: std::ptr::null_mut(),
            body_length: 0,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsEventsResponse<T> {
    schema_version: u32,
    after_revision: u64,
    revision: u64,
    events: Vec<T>,
}

#[no_mangle]
pub extern "C" fn lumen_settings_abi_version() -> u32 {
    SETTINGS_ABI_VERSION
}

#[no_mangle]
pub unsafe extern "C" fn lumen_settings_authority_open(
    file_path: *const c_char,
    platform: u32,
    authority_out: *mut *mut LumenSettingsAuthority,
) -> LumenEngineStatus {
    let Some(mut authority_out) = NonNull::new(authority_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    *authority_out.as_mut() = std::ptr::null_mut();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let file_path = path_from_c_string(file_path)?;
        let platform = LumenSettingsHostPlatform::try_from(platform)
            .map_err(|_| LumenEngineStatus::InvalidArgument)?;
        let capabilities = SettingsCapabilities::for_platform(platform.into());
        let authority = SettingsAuthority::open(file_path, capabilities)
            .map_err(settings_error_to_engine_status)?;
        Ok::<_, LumenEngineStatus>(Box::new(LumenSettingsAuthority {
            inner: Mutex::new(authority),
        }))
    }));
    match result {
        Ok(Ok(authority)) => {
            *authority_out.as_mut() = Box::into_raw(authority);
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_settings_authority_destroy(authority: *mut LumenSettingsAuthority) {
    if !authority.is_null() {
        drop(Box::from_raw(authority));
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_settings_authority_dispatch_json(
    authority: *mut LumenSettingsAuthority,
    operation: u32,
    request_body: *const u8,
    request_body_length: usize,
    after_revision: u64,
    response_out: *mut LumenSettingsResponse,
) -> LumenEngineStatus {
    let Some(authority) = authority.as_ref() else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut response_out) = NonNull::new(response_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    *response_out.as_mut() = LumenSettingsResponse::default();
    if request_body.is_null() && request_body_length != 0 {
        return LumenEngineStatus::InvalidArgument;
    }
    let Ok(operation) = SettingsOperation::try_from(operation) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let request_body = if request_body_length == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(request_body, request_body_length)
        };
        let request_body =
            std::str::from_utf8(request_body).map_err(|_| LumenEngineStatus::InvalidArgument)?;
        let mut authority = authority
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        dispatch(&mut authority, operation, request_body, after_revision)
    }));
    match result {
        Ok(Ok(response)) => {
            *response_out.as_mut() = response;
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_settings_authority_transact_json(
    authority: *mut LumenSettingsAuthority,
    transaction: u32,
    request_body: *const u8,
    request_body_length: usize,
    commit_runtime_when_revision_unchanged: bool,
    callbacks: LumenSettingsRuntimeTransactionCallbacks,
    response_out: *mut LumenSettingsResponse,
) -> LumenEngineStatus {
    let Some(authority) = authority.as_ref() else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut response_out) = NonNull::new(response_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    *response_out.as_mut() = LumenSettingsResponse::default();
    if request_body.is_null() && request_body_length != 0 {
        return LumenEngineStatus::InvalidArgument;
    }
    let Ok(transaction) = SettingsTransaction::try_from(transaction) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let (Some(prepare), Some(commit)) = (callbacks.prepare, callbacks.commit) else {
        return LumenEngineStatus::InvalidArgument;
    };

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let request_body = if request_body_length == 0 {
            ""
        } else {
            let bytes = std::slice::from_raw_parts(request_body, request_body_length);
            std::str::from_utf8(bytes).map_err(|_| LumenEngineStatus::InvalidArgument)?
        };
        let mut authority = authority
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        transact(
            &mut authority,
            transaction,
            request_body,
            commit_runtime_when_revision_unchanged,
            prepare,
            commit,
            callbacks.context,
        )
    }));
    match result {
        Ok(Ok(response)) => {
            *response_out.as_mut() = response;
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_settings_authority_reconcile_local_json(
    authority: *mut LumenSettingsAuthority,
    snapshot: Option<LumenSettingsSnapshotRuntimeCallback>,
    context: *mut c_void,
    response_out: *mut LumenSettingsResponse,
) -> LumenEngineStatus {
    let Some(authority) = authority.as_ref() else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(snapshot) = snapshot else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut response_out) = NonNull::new(response_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    *response_out.as_mut() = LumenSettingsResponse::default();

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut authority = authority
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        let mut settings_json = std::ptr::null();
        let mut settings_json_length = 0;
        let snapshot_error = snapshot(&mut settings_json, &mut settings_json_length, context);
        if !snapshot_error.is_null() {
            let message = CStr::from_ptr(snapshot_error)
                .to_str()
                .unwrap_or("runtime settings snapshot is unavailable");
            return Ok(internal_error_response_with_message(message));
        }
        if settings_json.is_null() && settings_json_length != 0 {
            return Err(LumenEngineStatus::InvalidArgument);
        }
        let bytes = if settings_json_length == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(settings_json, settings_json_length)
        };
        let settings_json =
            std::str::from_utf8(bytes).map_err(|_| LumenEngineStatus::InvalidArgument)?;
        dispatch(
            &mut authority,
            SettingsOperation::ApplyLocalUpdate,
            settings_json,
            0,
        )
    }));
    match result {
        Ok(Ok(response)) => {
            *response_out.as_mut() = response;
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_settings_response_destroy(response: *mut LumenSettingsResponse) {
    let Some(response) = response.as_mut() else {
        return;
    };
    if !response.body.is_null() {
        drop(CString::from_raw(response.body));
    }
    *response = LumenSettingsResponse::default();
}

fn dispatch(
    authority: &mut SettingsAuthority,
    operation: SettingsOperation,
    request_body: &str,
    after_revision: u64,
) -> Result<LumenSettingsResponse, LumenEngineStatus> {
    let result = match operation {
        SettingsOperation::Snapshot => serialize_success(&authority.snapshot()),
        SettingsOperation::ApplyPatch => authority
            .apply_patch_json(request_body)
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::EventsSince => authority
            .events_since(after_revision)
            .map(|events| SettingsEventsResponse {
                schema_version: SETTINGS_SCHEMA_VERSION,
                after_revision,
                revision: authority.snapshot().revision,
                events,
            })
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::MarkNextSessionStarted => authority
            .mark_next_session_started()
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::MarkWorkerRestarted => authority
            .mark_worker_restarted()
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::ApplyLocalUpdate => serde_json::from_str::<HostSettings>(request_body)
            .map_err(|_| SettingsProtocolError {
                code: SettingsErrorCode::InvalidRequest,
                message: "local settings do not match schema version 1".to_owned(),
                field: None,
                current_revision: Some(authority.snapshot().revision),
            })
            .and_then(|settings| authority.apply_local_update(settings))
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::FactoryReset => authority
            .factory_reset()
            .map(|()| authority.snapshot())
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::PreviewApplyPatch => authority
            .preview_patch_json(request_body)
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::PreviewNextSessionStarted => authority
            .preview_next_session_started()
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::PreviewWorkerRestarted => authority
            .preview_worker_restarted()
            .map_err(serialize_protocol_error)
            .and_then(|value| serialize_success(&value)),
        SettingsOperation::PreviewFactoryReset => {
            serialize_success(&authority.preview_factory_reset())
        }
    };
    match result {
        Ok(response) => Ok(response),
        Err(response) => Ok(response),
    }
}

fn transact(
    authority: &mut SettingsAuthority,
    transaction: SettingsTransaction,
    request_body: &str,
    commit_runtime_when_revision_unchanged: bool,
    prepare: LumenSettingsPrepareRuntimeCallback,
    commit: LumenSettingsCommitRuntimeCallback,
    context: *mut c_void,
) -> Result<LumenSettingsResponse, LumenEngineStatus> {
    let previous_revision = authority.snapshot().revision;
    let (preview_operation, commit_operation) = match transaction {
        SettingsTransaction::ApplyPatch => (
            SettingsOperation::PreviewApplyPatch,
            SettingsOperation::ApplyPatch,
        ),
        SettingsTransaction::NextSessionStarted => (
            SettingsOperation::PreviewNextSessionStarted,
            SettingsOperation::MarkNextSessionStarted,
        ),
        SettingsTransaction::WorkerRestarted => (
            SettingsOperation::PreviewWorkerRestarted,
            SettingsOperation::MarkWorkerRestarted,
        ),
        SettingsTransaction::FactoryReset => (
            SettingsOperation::PreviewFactoryReset,
            SettingsOperation::FactoryReset,
        ),
    };

    let preview = dispatch(authority, preview_operation, request_body, 0)?;
    if !(200..300).contains(&preview.status_code) {
        return Ok(preview);
    }
    let preview_json = match response_value(&preview) {
        Ok(value) => value,
        Err(status) => {
            destroy_owned_response(preview);
            return Err(status);
        }
    };
    let Some(effective) = preview_json.get("effective") else {
        destroy_owned_response(preview);
        return Err(LumenEngineStatus::CorruptData);
    };
    let effective_json = match serde_json::to_vec(effective) {
        Ok(value) => value,
        Err(_) => {
            destroy_owned_response(preview);
            return Err(LumenEngineStatus::StorageError);
        }
    };
    let preparation_error =
        unsafe { prepare(effective_json.as_ptr(), effective_json.len(), context) };
    if !preparation_error.is_null() {
        let message = unsafe { CStr::from_ptr(preparation_error) }
            .to_str()
            .unwrap_or("runtime settings update could not be prepared");
        destroy_owned_response(preview);
        return Ok(internal_error_response_with_message(message));
    }

    let committed = match dispatch(authority, commit_operation, request_body, 0) {
        Ok(response) => response,
        Err(status) => {
            destroy_owned_response(preview);
            return Err(status);
        }
    };
    if !(200..300).contains(&committed.status_code) {
        destroy_owned_response(preview);
        return Ok(committed);
    }
    let committed_json = match response_value(&committed) {
        Ok(value) => value,
        Err(status) => {
            destroy_owned_response(preview);
            destroy_owned_response(committed);
            return Err(status);
        }
    };
    if committed_json != preview_json {
        destroy_owned_response(preview);
        destroy_owned_response(committed);
        return Ok(internal_error_response_with_message(
            "settings authority changed between preview and commit",
        ));
    }
    let Some(committed_revision) = committed_json
        .get("revision")
        .and_then(serde_json::Value::as_u64)
    else {
        destroy_owned_response(preview);
        destroy_owned_response(committed);
        return Err(LumenEngineStatus::CorruptData);
    };
    if commit_runtime_when_revision_unchanged || committed_revision != previous_revision {
        unsafe { commit(context) };
    }
    destroy_owned_response(preview);
    Ok(committed)
}

fn response_value(
    response: &LumenSettingsResponse,
) -> Result<serde_json::Value, LumenEngineStatus> {
    if response.body.is_null() {
        return Err(LumenEngineStatus::CorruptData);
    }
    let bytes = unsafe { std::slice::from_raw_parts(response.body.cast(), response.body_length) };
    serde_json::from_slice(bytes).map_err(|_| LumenEngineStatus::CorruptData)
}

fn destroy_owned_response(response: LumenSettingsResponse) {
    if !response.body.is_null() {
        unsafe { drop(CString::from_raw(response.body)) };
    }
}

fn serialize_success(
    value: &impl Serialize,
) -> Result<LumenSettingsResponse, LumenSettingsResponse> {
    serialize_response(200, value).map_err(|_| internal_error_response())
}

fn serialize_protocol_error(error: SettingsProtocolError) -> LumenSettingsResponse {
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
    serialize_response(status_code, &error).unwrap_or_else(|_| internal_error_response())
}

fn serialize_response(
    status_code: u16,
    value: &impl Serialize,
) -> Result<LumenSettingsResponse, LumenEngineStatus> {
    let serialized = serde_json::to_string(value).map_err(|_| LumenEngineStatus::StorageError)?;
    let body_length = serialized.len();
    let body = CString::new(serialized)
        .map_err(|_| LumenEngineStatus::StorageError)?
        .into_raw();
    Ok(LumenSettingsResponse {
        status_code,
        body,
        body_length,
    })
}

fn internal_error_response() -> LumenSettingsResponse {
    internal_error_response_with_message("settings response could not be serialized")
}

fn internal_error_response_with_message(message: &str) -> LumenSettingsResponse {
    serialize_response(
        500,
        &SettingsProtocolError {
            code: SettingsErrorCode::StorageError,
            message: message.to_owned(),
            field: None,
            current_revision: None,
        },
    )
    .unwrap_or_default()
}

unsafe fn path_from_c_string(value: *const c_char) -> Result<PathBuf, LumenEngineStatus> {
    if value.is_null() {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    let value = CStr::from_ptr(value)
        .to_str()
        .map_err(|_| LumenEngineStatus::InvalidArgument)?;
    if value.trim().is_empty() {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    Ok(PathBuf::from(value))
}

fn settings_error_to_engine_status(error: SettingsProtocolError) -> LumenEngineStatus {
    match error.code {
        SettingsErrorCode::StorageError => LumenEngineStatus::StorageError,
        SettingsErrorCode::CorruptData => LumenEngineStatus::CorruptData,
        _ => LumenEngineStatus::InvalidArgument,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::ffi::CString;
    use tempfile::TempDir;

    unsafe fn open(root: &TempDir, platform: u32) -> *mut LumenSettingsAuthority {
        let path = CString::new(
            root.path()
                .join("settings.json")
                .to_string_lossy()
                .as_bytes(),
        )
        .unwrap();
        let mut authority = std::ptr::null_mut();
        assert_eq!(
            lumen_settings_authority_open(path.as_ptr(), platform, &mut authority),
            LumenEngineStatus::Ok
        );
        assert!(!authority.is_null());
        authority
    }

    unsafe fn dispatch_json(
        authority: *mut LumenSettingsAuthority,
        operation: u32,
        body: &str,
        after_revision: u64,
    ) -> (u16, Value) {
        let mut response = LumenSettingsResponse::default();
        assert_eq!(
            lumen_settings_authority_dispatch_json(
                authority,
                operation,
                body.as_ptr(),
                body.len(),
                after_revision,
                &mut response,
            ),
            LumenEngineStatus::Ok
        );
        let bytes = std::slice::from_raw_parts(response.body.cast::<u8>(), response.body_length);
        let value = serde_json::from_slice(bytes).unwrap();
        let status = response.status_code;
        lumen_settings_response_destroy(&mut response);
        (status, value)
    }

    #[test]
    fn abi_dispatches_snapshot_patch_transitions_events_and_reset() {
        assert_eq!(lumen_settings_abi_version(), SETTINGS_ABI_VERSION);
        let root = TempDir::new().unwrap();
        unsafe {
            let authority = open(&root, 0);
            let (status, snapshot) = dispatch_json(authority, 0, "", 0);
            assert_eq!(status, 200);
            assert_eq!(snapshot["revision"], 1);
            let patch = r#"{
              "schemaVersion":1,"baseRevision":1,"requestId":"ffi-1",
              "changes":{"general":{"name":"Remote"},"streaming":{"fallbackDisplayMode":"2560x1440x120"},"network":{"port":48000}}
            }"#;
            let (status, response) = dispatch_json(authority, 1, patch, 0);
            assert_eq!(status, 200);
            assert_eq!(response["applyState"], "pending-worker-restart");
            let (_, next) = dispatch_json(authority, 3, "", 0);
            assert_eq!(
                next["effective"]["streaming"]["fallbackDisplayMode"],
                "2560x1440x120"
            );
            assert_eq!(next["effective"]["network"]["port"], 47_989);
            let (_, restarted) = dispatch_json(authority, 4, "", 0);
            assert_eq!(restarted["effective"]["network"]["port"], 48_000);
            let (_, events) = dispatch_json(authority, 2, "", 1);
            assert_eq!(events["events"].as_array().unwrap().len(), 3);
            let (_, reset) = dispatch_json(authority, 6, "", 0);
            assert_eq!(reset["revision"], 1);
            assert_eq!(reset["settings"]["general"]["name"], "Lumen");
            lumen_settings_authority_destroy(authority);
        }
    }

    #[test]
    fn abi_returns_typed_atomic_errors_and_platform_capabilities() {
        let root = TempDir::new().unwrap();
        unsafe {
            let authority = open(&root, 1);
            let (_, snapshot) = dispatch_json(authority, 0, "", 0);
            assert_eq!(snapshot["capabilities"]["hostPlatform"], "windows");
            assert!(snapshot["capabilities"]["fields"]
                .get("workspace.policy")
                .is_none());
            for field in ["commands.prep", "commands.state", "commands.server"] {
                assert_eq!(snapshot["capabilities"]["fields"][field]["available"], true);
                assert_eq!(
                    snapshot["capabilities"]["fields"][field]["allowedValues"],
                    serde_json::json!(["user", "administrator"])
                );
            }
            let patch = r#"{
              "schemaVersion":1,"baseRevision":1,"requestId":"ffi-windows-1",
              "changes":{"workspace":{"policy":"focused-workspace"},"general":{"name":"Must not apply"}}
            }"#;
            let (status, error) = dispatch_json(authority, 1, patch, 0);
            assert_eq!(status, 400);
            assert_eq!(error["code"], "unknown-field");
            let (_, unchanged) = dispatch_json(authority, 0, "", 0);
            assert_eq!(unchanged["revision"], 1);
            assert_eq!(unchanged["settings"]["general"]["name"], "Lumen");
            lumen_settings_authority_destroy(authority);
        }
    }

    #[test]
    fn abi_local_update_never_adds_paths_or_secrets() {
        let root = TempDir::new().unwrap();
        unsafe {
            let authority = open(&root, 0);
            let settings = serde_json::to_string(&HostSettings::default()).unwrap();
            let (status, snapshot) = dispatch_json(authority, 5, &settings, 0);
            assert_eq!(status, 200);
            let serialized = snapshot.to_string();
            for forbidden in [
                "credentialsFilePath",
                "ownerPassword",
                "privateKeyPath",
                "remoteSettingsAllowed",
            ] {
                assert!(!serialized.contains(forbidden));
            }
            lumen_settings_authority_destroy(authority);
        }
    }

    #[derive(Default)]
    struct RuntimeTransactionProbe {
        prepare_count: usize,
        commit_count: usize,
        reject: bool,
        effective_host_name: String,
    }

    unsafe extern "C" fn prepare_runtime_probe(
        effective_json: *const u8,
        effective_json_length: usize,
        context: *mut c_void,
    ) -> *const c_char {
        let probe = &mut *context.cast::<RuntimeTransactionProbe>();
        probe.prepare_count += 1;
        let bytes = std::slice::from_raw_parts(effective_json, effective_json_length);
        let effective: Value = serde_json::from_slice(bytes).unwrap();
        probe.effective_host_name = effective["general"]["name"].as_str().unwrap().to_owned();
        if probe.reject {
            static ERROR: &[u8] = b"injected runtime preparation failure\0";
            ERROR.as_ptr().cast()
        } else {
            std::ptr::null()
        }
    }

    unsafe extern "C" fn commit_runtime_probe(context: *mut c_void) {
        let probe = &mut *context.cast::<RuntimeTransactionProbe>();
        probe.commit_count += 1;
    }

    unsafe extern "C" fn snapshot_runtime_probe(
        settings_json_out: *mut *const u8,
        settings_json_length_out: *mut usize,
        context: *mut c_void,
    ) -> *const c_char {
        let settings = &*context.cast::<String>();
        *settings_json_out = settings.as_ptr();
        *settings_json_length_out = settings.len();
        std::ptr::null()
    }

    unsafe fn transact_json(
        authority: *mut LumenSettingsAuthority,
        transaction: u32,
        body: &str,
        probe: &mut RuntimeTransactionProbe,
    ) -> (u16, Value) {
        let mut response = LumenSettingsResponse::default();
        assert_eq!(
            lumen_settings_authority_transact_json(
                authority,
                transaction,
                body.as_ptr(),
                body.len(),
                false,
                LumenSettingsRuntimeTransactionCallbacks {
                    prepare: Some(prepare_runtime_probe),
                    commit: Some(commit_runtime_probe),
                    context: std::ptr::from_mut(probe).cast(),
                },
                &mut response,
            ),
            LumenEngineStatus::Ok
        );
        let bytes = std::slice::from_raw_parts(response.body.cast::<u8>(), response.body_length);
        let value = serde_json::from_slice(bytes).unwrap();
        let status = response.status_code;
        lumen_settings_response_destroy(&mut response);
        (status, value)
    }

    #[test]
    fn rust_transaction_prepares_before_commit_and_keeps_failures_atomic() {
        let root = TempDir::new().unwrap();
        unsafe {
            let authority = open(&root, 0);
            let patch = r#"{
              "schemaVersion":1,"baseRevision":1,"requestId":"ffi-transaction-1",
              "changes":{"general":{"name":"Rust Transaction"}}
            }"#;
            let mut probe = RuntimeTransactionProbe {
                reject: true,
                ..RuntimeTransactionProbe::default()
            };

            let (status, error) = transact_json(authority, 0, patch, &mut probe);
            assert_eq!(status, 500);
            assert_eq!(error["message"], "injected runtime preparation failure");
            assert_eq!(probe.prepare_count, 1);
            assert_eq!(probe.commit_count, 0);
            let (_, unchanged) = dispatch_json(authority, 0, "", 0);
            assert_eq!(unchanged["revision"], 1);
            assert_eq!(unchanged["settings"]["general"]["name"], "Lumen");

            probe.reject = false;
            let (status, committed) = transact_json(authority, 0, patch, &mut probe);
            assert_eq!(status, 200);
            assert_eq!(committed["revision"], 2);
            assert_eq!(probe.effective_host_name, "Rust Transaction");
            assert_eq!(probe.prepare_count, 2);
            assert_eq!(probe.commit_count, 1);
            lumen_settings_authority_destroy(authority);
        }
    }

    #[test]
    fn rust_reconciliation_snapshots_native_runtime_under_the_authority_lock() {
        let root = TempDir::new().unwrap();
        unsafe {
            let authority = open(&root, 0);
            let mut local = HostSettings::default();
            local.general.name = "Native Runtime".to_owned();
            let settings = serde_json::to_string(&local).unwrap();
            let mut response = LumenSettingsResponse::default();

            assert_eq!(
                lumen_settings_authority_reconcile_local_json(
                    authority,
                    Some(snapshot_runtime_probe),
                    std::ptr::from_ref(&settings).cast_mut().cast(),
                    &mut response,
                ),
                LumenEngineStatus::Ok
            );
            let bytes =
                std::slice::from_raw_parts(response.body.cast::<u8>(), response.body_length);
            let snapshot: Value = serde_json::from_slice(bytes).unwrap();
            assert_eq!(snapshot["effective"]["general"]["name"], "Native Runtime");
            lumen_settings_response_destroy(&mut response);
            lumen_settings_authority_destroy(authority);
        }
    }
}
