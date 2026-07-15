use super::*;

#[repr(C)]
pub struct LumenHostRuntimeEngine {
    inner: HostRuntimeEngine,
}

fn with_host_engine_mut(
    engine: *mut LumenHostRuntimeEngine,
    operation: impl FnOnce(&mut HostRuntimeEngine) -> LumenEngineStatus,
) -> LumenEngineStatus {
    let Some(mut engine) = NonNull::new(engine) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        operation(unsafe { &mut engine.as_mut().inner })
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

fn with_host_engine(
    engine: *const LumenHostRuntimeEngine,
    operation: impl FnOnce(&HostRuntimeEngine) -> LumenEngineStatus,
) -> LumenEngineStatus {
    let Some(engine) = NonNull::new(engine.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        operation(unsafe { &engine.as_ref().inner })
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

#[no_mangle]
pub extern "C" fn lumen_engine_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_display_geometry(
    request: LumenDisplayModeRequest,
    geometry_out: *mut LumenDisplayGeometry,
) -> LumenEngineStatus {
    let Some(mut geometry_out) = NonNull::new(geometry_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_display_geometry(request))) {
        Ok(Ok(geometry)) => {
            unsafe { *geometry_out.as_mut() = geometry };
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_virtual_display_plan(
    request: LumenVirtualDisplayRequest,
    plan_out: *mut LumenVirtualDisplayPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_virtual_display_plan(request))) {
        Ok(Ok(plan)) => {
            unsafe { *plan_out.as_mut() = plan };
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_display_color(
    request: LumenDisplayColorRequest,
    profile_out: *mut LumenDisplayColorProfile,
) -> LumenEngineStatus {
    let Some(mut profile_out) = NonNull::new(profile_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_display_color(request))) {
        Ok(profile) => {
            unsafe { *profile_out.as_mut() = profile };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_create() -> *mut LumenHostRuntimeEngine {
    Box::into_raw(Box::new(LumenHostRuntimeEngine {
        inner: HostRuntimeEngine::default(),
    }))
}

#[no_mangle]
/// # Safety
///
/// `engine` must be null or a live pointer returned by
/// [`lumen_host_runtime_engine_create`] that has not already been destroyed.
pub unsafe extern "C" fn lumen_host_runtime_engine_destroy(engine: *mut LumenHostRuntimeEngine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_request_start(
    engine: *mut LumenHostRuntimeEngine,
) -> LumenEngineStatus {
    with_host_engine_mut(engine, HostRuntimeEngine::request_start)
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_request_stop(
    engine: *mut LumenHostRuntimeEngine,
) -> LumenEngineStatus {
    with_host_engine_mut(engine, HostRuntimeEngine::request_stop)
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_request_reset(
    engine: *mut LumenHostRuntimeEngine,
) -> LumenEngineStatus {
    with_host_engine_mut(engine, HostRuntimeEngine::request_reset)
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_request_force_stop_stream(
    engine: *mut LumenHostRuntimeEngine,
) -> LumenEngineStatus {
    with_host_engine_mut(engine, HostRuntimeEngine::request_force_stop_stream)
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_next_command(
    engine: *mut LumenHostRuntimeEngine,
    command_out: *mut LumenHostRuntimeCommand,
) -> LumenEngineStatus {
    let Some(mut command_out) = NonNull::new(command_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_host_engine_mut(engine, |engine| match engine.next_command() {
        Ok(command) => {
            unsafe { *command_out.as_mut() = command };
            LumenEngineStatus::Ok
        }
        Err(status) => status,
    })
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_complete_command(
    engine: *mut LumenHostRuntimeEngine,
    command: LumenHostRuntimeCommand,
    succeeded: bool,
) -> LumenEngineStatus {
    with_host_engine_mut(engine, |engine| engine.complete_command(command, succeeded))
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_report_exit(
    engine: *mut LumenHostRuntimeEngine,
    exit_code: i32,
) -> LumenEngineStatus {
    with_host_engine_mut(engine, |engine| engine.report_exit(exit_code))
}

#[no_mangle]
/// # Safety
///
/// Every non-null path pointer must reference a valid null-terminated UTF-8
/// string for the duration of this call. `result_out` must reference writable
/// storage for one [`LumenHostResetStorageResult`].
pub unsafe extern "C" fn lumen_host_runtime_engine_reset_storage(
    engine: *mut LumenHostRuntimeEngine,
    request: LumenHostResetStorageRequest,
    result_out: *mut LumenHostResetStorageResult,
) -> LumenEngineStatus {
    let Some(mut result_out) = NonNull::new(result_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    unsafe { *result_out.as_mut() = LumenHostResetStorageResult::default() };

    let paths = match catch_unwind(AssertUnwindSafe(|| {
        let app_data = unsafe { path_from_c_string(request.app_data_path) }?
            .ok_or(LumenEngineStatus::InvalidArgument)?;
        let explicit_paths = [
            request.config_file_path,
            request.app_catalog_file_path,
            request.state_file_path,
            request.credential_file_path,
        ]
        .into_iter()
        .map(|value| unsafe { path_from_c_string(value) })
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .flatten()
        .collect();
        Ok::<_, LumenEngineStatus>(HostResetStoragePaths {
            app_data,
            explicit_paths,
        })
    })) {
        Ok(Ok(paths)) => paths,
        Ok(Err(status)) => return status,
        Err(_) => return LumenEngineStatus::Panic,
    };

    let request_status = lumen_host_runtime_engine_request_reset(engine);
    if request_status != LumenEngineStatus::Ok {
        return request_status;
    }
    let mut command = LumenHostRuntimeCommand {
        kind: LumenHostRuntimeCommandKind::Reset,
        generation: 0,
        sequence: 0,
    };
    let command_status = lumen_host_runtime_engine_next_command(engine, &mut command);
    if command_status != LumenEngineStatus::Ok || command.kind != LumenHostRuntimeCommandKind::Reset
    {
        return command_status;
    }

    let result = catch_unwind(AssertUnwindSafe(|| reset_host_storage(&paths))).unwrap_or(
        LumenHostResetStorageResult {
            attempted_path_count: 0,
            removed_path_count: 0,
            failed_path_count: 1,
        },
    );
    unsafe { *result_out.as_mut() = result };
    let succeeded = result.failed_path_count == 0;
    let completion_status = lumen_host_runtime_engine_complete_command(engine, command, succeeded);
    if succeeded {
        completion_status
    } else {
        LumenEngineStatus::CommandFailed
    }
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_state(
    engine: *const LumenHostRuntimeEngine,
) -> LumenHostRuntimeState {
    let Some(engine) = NonNull::new(engine.cast_mut()) else {
        return LumenHostRuntimeState::Stopped;
    };
    catch_unwind(AssertUnwindSafe(|| unsafe {
        engine.as_ref().inner.state()
    }))
    .unwrap_or(LumenHostRuntimeState::Failed)
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_last_exit_code(
    engine: *const LumenHostRuntimeEngine,
) -> i32 {
    let Some(engine) = NonNull::new(engine.cast_mut()) else {
        return 0;
    };
    catch_unwind(AssertUnwindSafe(|| unsafe {
        engine.as_ref().inner.last_exit_code()
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn lumen_host_runtime_engine_last_failure(
    engine: *const LumenHostRuntimeEngine,
) -> LumenEngineStatus {
    with_host_engine(engine, HostRuntimeEngine::last_failure)
}
