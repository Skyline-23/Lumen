use std::ffi::{c_char, c_void, CStr};
use std::path::PathBuf;
use std::ptr;

use crate::{
    path_from_c_string, HostResetStoragePaths, LumenEngineStatus, LumenHostResetStorageRequest,
    LumenHostResetStorageResult, LumenHostRuntimeState,
};

use super::supervisor::{LumenHostRuntimeSupervisor, RuntimeStatusCallback, StatusCallback};

unsafe fn required_string(value: *const c_char) -> Result<String, LumenEngineStatus> {
    if value.is_null() {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    let value = unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| LumenEngineStatus::InvalidArgument)?;
    if value.is_empty() {
        Err(LumenEngineStatus::InvalidArgument)
    } else {
        Ok(value.to_owned())
    }
}

unsafe fn string_array(
    values: *const *const c_char,
    count: usize,
) -> Result<Vec<String>, LumenEngineStatus> {
    if count == 0 {
        return Ok(Vec::new());
    }
    if values.is_null() {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    (0..count)
        .map(|index| unsafe { required_string(*values.add(index)) })
        .collect()
}

fn supervisor<'a>(
    value: *const LumenHostRuntimeSupervisor,
) -> Result<&'a LumenHostRuntimeSupervisor, LumenEngineStatus> {
    unsafe { value.as_ref() }.ok_or(LumenEngineStatus::InvalidArgument)
}

#[no_mangle]
pub(crate) extern "C" fn lumen_host_runtime_supervisor_create() -> *mut LumenHostRuntimeSupervisor {
    Box::into_raw(Box::new(LumenHostRuntimeSupervisor::default()))
}

#[no_mangle]
pub(crate) unsafe extern "C" fn lumen_host_runtime_supervisor_destroy(
    supervisor: *mut LumenHostRuntimeSupervisor,
) {
    if !supervisor.is_null() {
        drop(unsafe { Box::from_raw(supervisor) });
    }
}

#[no_mangle]
pub(crate) unsafe extern "C" fn lumen_host_runtime_supervisor_start(
    supervisor_pointer: *mut LumenHostRuntimeSupervisor,
    worker_path: *const c_char,
    arguments: *const *const c_char,
    argument_count: usize,
    log_path: *const c_char,
    callback: Option<RuntimeStatusCallback>,
    callback_context: *mut c_void,
) -> LumenEngineStatus {
    let Ok(supervisor) = supervisor(supervisor_pointer) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let worker_path = match unsafe { required_string(worker_path) } {
        Ok(value) => PathBuf::from(value),
        Err(status) => return status,
    };
    let arguments = match unsafe { string_array(arguments, argument_count) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    let log_path = match unsafe { required_string(log_path) } {
        Ok(value) => PathBuf::from(value),
        Err(status) => return status,
    };
    let callback = callback.map(|function| StatusCallback::new(function, callback_context));
    supervisor.start(worker_path, arguments, log_path, callback)
}

#[no_mangle]
pub(crate) extern "C" fn lumen_host_runtime_supervisor_stop(
    supervisor_pointer: *mut LumenHostRuntimeSupervisor,
) -> LumenEngineStatus {
    supervisor(supervisor_pointer)
        .map(LumenHostRuntimeSupervisor::stop)
        .unwrap_or(LumenEngineStatus::InvalidArgument)
}

#[no_mangle]
pub(crate) extern "C" fn lumen_host_runtime_supervisor_state(
    supervisor_pointer: *const LumenHostRuntimeSupervisor,
) -> LumenHostRuntimeState {
    supervisor(supervisor_pointer)
        .map(LumenHostRuntimeSupervisor::state)
        .unwrap_or(LumenHostRuntimeState::Stopped)
}

#[no_mangle]
pub(crate) extern "C" fn lumen_host_runtime_supervisor_last_exit_code(
    supervisor_pointer: *const LumenHostRuntimeSupervisor,
) -> i32 {
    supervisor(supervisor_pointer)
        .map(LumenHostRuntimeSupervisor::last_exit_code)
        .unwrap_or_default()
}

#[no_mangle]
pub(crate) extern "C" fn lumen_host_runtime_supervisor_last_failure(
    supervisor_pointer: *const LumenHostRuntimeSupervisor,
) -> LumenEngineStatus {
    supervisor(supervisor_pointer)
        .map(LumenHostRuntimeSupervisor::last_failure)
        .unwrap_or(LumenEngineStatus::InvalidArgument)
}

#[no_mangle]
pub(crate) extern "C" fn lumen_host_runtime_supervisor_force_stop_stream(
    supervisor_pointer: *mut LumenHostRuntimeSupervisor,
) -> LumenEngineStatus {
    supervisor(supervisor_pointer)
        .map(LumenHostRuntimeSupervisor::force_stop_stream)
        .unwrap_or(LumenEngineStatus::InvalidArgument)
}

#[no_mangle]
pub(crate) extern "C" fn lumen_host_runtime_supervisor_reload_applications(
    supervisor_pointer: *mut LumenHostRuntimeSupervisor,
) -> LumenEngineStatus {
    supervisor(supervisor_pointer)
        .map(LumenHostRuntimeSupervisor::reload_applications)
        .unwrap_or(LumenEngineStatus::InvalidArgument)
}

#[no_mangle]
pub(crate) unsafe extern "C" fn lumen_host_runtime_supervisor_reset_storage(
    supervisor_pointer: *mut LumenHostRuntimeSupervisor,
    request: LumenHostResetStorageRequest,
    result_out: *mut LumenHostResetStorageResult,
) -> LumenEngineStatus {
    let Ok(supervisor) = supervisor(supervisor_pointer) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(result_out) = (unsafe { result_out.as_mut() }) else {
        return LumenEngineStatus::InvalidArgument;
    };
    *result_out = LumenHostResetStorageResult::default();
    let app_data = match unsafe { path_from_c_string(request.app_data_path) } {
        Ok(Some(path)) => path,
        Ok(None) | Err(_) => return LumenEngineStatus::InvalidArgument,
    };
    let explicit_paths = [
        request.config_file_path,
        request.app_catalog_file_path,
        request.state_file_path,
        request.credential_file_path,
    ]
    .into_iter()
    .map(|value| unsafe { path_from_c_string(value) })
    .collect::<Result<Vec<_>, _>>();
    let explicit_paths = match explicit_paths {
        Ok(paths) => paths.into_iter().flatten().collect(),
        Err(status) => return status,
    };
    supervisor.reset_storage(
        HostResetStoragePaths {
            app_data,
            explicit_paths,
        },
        result_out,
    )
}

#[no_mangle]
pub(crate) unsafe extern "C" fn lumen_host_runtime_supervisor_copy_last_error(
    supervisor_pointer: *const LumenHostRuntimeSupervisor,
    destination: *mut c_char,
    capacity: usize,
) -> usize {
    if destination.is_null() || capacity == 0 {
        return 0;
    }
    let message = supervisor(supervisor_pointer)
        .map(LumenHostRuntimeSupervisor::last_error)
        .unwrap_or_else(|_| "Rust host runtime supervisor is unavailable.".to_owned());
    let bytes = message.as_bytes();
    let length = bytes.len().min(capacity.saturating_sub(1));
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), destination.cast::<u8>(), length);
        *destination.add(length) = 0;
    }
    length
}
