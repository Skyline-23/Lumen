use super::*;

#[repr(C)]
pub struct LumenWorkspaceEngine {
    inner: WorkspaceEngine,
}

fn with_engine_mut(
    engine: *mut LumenWorkspaceEngine,
    operation: impl FnOnce(&mut WorkspaceEngine) -> LumenEngineStatus,
) -> LumenEngineStatus {
    let Some(mut engine) = NonNull::new(engine) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: Category 3 (dangling pointer). The C ABI caller guarantees this
        // pointer came from a live workspace constructor and retains unique access.
        operation(unsafe { &mut engine.as_mut().inner })
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

fn with_engine(
    engine: *const LumenWorkspaceEngine,
    operation: impl FnOnce(&WorkspaceEngine) -> LumenEngineStatus,
) -> LumenEngineStatus {
    let Some(engine) = NonNull::new(engine.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: Category 3 (dangling pointer). The C ABI caller guarantees the
        // engine remains live and is not concurrently destroyed during this call.
        operation(unsafe { &engine.as_ref().inner })
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_create() -> *mut LumenWorkspaceEngine {
    Box::into_raw(Box::new(LumenWorkspaceEngine {
        inner: WorkspaceEngine::default(),
    }))
}

#[no_mangle]
/// # Safety
///
/// `journal_path` must point to a valid null-terminated UTF-8 string for the
/// duration of this call.
pub unsafe extern "C" fn lumen_workspace_engine_create_recoverable(
    journal_path: *const c_char,
    platform: WorkspacePlatform,
) -> *mut LumenWorkspaceEngine {
    if journal_path.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: Category 8 (FFI boundary). The function contract requires a
        // live NUL-terminated C string, and null was rejected above.
        let path = unsafe { CStr::from_ptr(journal_path) };
        let Ok(path) = path.to_str() else {
            return std::ptr::null_mut();
        };
        if path.trim().is_empty() {
            return std::ptr::null_mut();
        }
        Box::into_raw(Box::new(LumenWorkspaceEngine {
            inner: WorkspaceEngine::with_recovery_store(
                RecoveryJournalStore::new(PathBuf::from(path)),
                platform,
            ),
        }))
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
/// # Safety
///
/// `engine` must be null or a live pointer returned by either workspace engine
/// constructor that has not already been destroyed.
pub unsafe extern "C" fn lumen_workspace_engine_destroy(engine: *mut LumenWorkspaceEngine) {
    if !engine.is_null() {
        // SAFETY: Category 12 (double free). The caller contract permits exactly
        // one destroy for a pointer returned by either workspace constructor.
        drop(unsafe { Box::from_raw(engine) });
    }
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_begin_session(
    engine: *mut LumenWorkspaceEngine,
    request: LumenWorkspaceSessionRequest,
) -> LumenEngineStatus {
    with_engine_mut(engine, |engine| engine.begin_session(request))
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_next_command(
    engine: *mut LumenWorkspaceEngine,
    command_out: *mut LumenWorkspaceCommand,
) -> LumenEngineStatus {
    let Some(mut command_out) = NonNull::new(command_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_engine_mut(engine, |engine| match engine.next_command() {
        Ok(command) => {
            // SAFETY: Category 8 (FFI boundary). The caller supplies a live,
            // writable command slot; null was rejected before this write.
            unsafe { *command_out.as_mut() = command };
            LumenEngineStatus::Ok
        }
        Err(status) => status,
    })
}

#[no_mangle]
/// # Safety
///
/// A non-null `completion.payload_json` must point to a valid NUL-terminated
/// JSON string for the duration of this call.
pub unsafe extern "C" fn lumen_workspace_engine_complete_command_with_payload(
    engine: *mut LumenWorkspaceEngine,
    command: LumenWorkspaceCommand,
    completion: LumenWorkspaceCommandCompletion,
) -> LumenEngineStatus {
    // SAFETY: Category 8 (FFI boundary). The function contract requires any
    // non-null payload pointer to remain a live NUL-terminated string here.
    let completion = match unsafe { decode_ffi_completion(command, completion) } {
        Ok(completion) => completion,
        Err(status) => return status,
    };
    with_engine_mut(engine, |engine| {
        engine.complete_command_with_payload(command, completion)
    })
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_record_desktop_mirror_applied(
    engine: *mut LumenWorkspaceEngine,
) -> LumenEngineStatus {
    with_engine_mut(engine, WorkspaceEngine::record_desktop_mirror_applied)
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_command_payload_json_size(
    engine: *const LumenWorkspaceEngine,
    command: LumenWorkspaceCommand,
) -> usize {
    let Some(engine) = NonNull::new(engine.cast_mut()) else {
        return 0;
    };
    // SAFETY: Category 3 (dangling pointer). The caller keeps the engine live
    // for this read, and no mutable reference is created by the query.
    catch_unwind(AssertUnwindSafe(|| unsafe {
        engine.as_ref().inner.command_payload(command)
    }))
    .ok()
    .and_then(Result::ok)
    .and_then(|payload| payload.json().ok().flatten())
    .map_or(0, |json| json.len().saturating_add(1))
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_copy_command_payload_json(
    engine: *const LumenWorkspaceEngine,
    command: LumenWorkspaceCommand,
    destination: *mut c_char,
    capacity: usize,
) -> LumenEngineStatus {
    let Some(engine) = NonNull::new(engine.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(destination) = NonNull::new(destination.cast::<u8>()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    // SAFETY: Category 3 (dangling pointer). The caller keeps the engine live
    // for this read-only payload query.
    let payload = match catch_unwind(AssertUnwindSafe(|| unsafe {
        engine.as_ref().inner.command_payload(command)
    })) {
        Ok(Ok(payload)) => payload,
        Ok(Err(status)) => return status,
        Err(_) => return LumenEngineStatus::Panic,
    };
    let json = match payload.json() {
        Ok(Some(json)) => json,
        Ok(None) => return LumenEngineStatus::InvalidArgument,
        Err(status) => return status,
    };
    if capacity <= json.len() {
        return LumenEngineStatus::InvalidArgument;
    }
    // SAFETY: Category 8 (FFI boundary). The caller provides `capacity`
    // writable bytes, and the guard above proves JSON plus NUL fits.
    unsafe {
        std::ptr::copy_nonoverlapping(json.as_ptr(), destination.as_ptr(), json.len());
        *destination.as_ptr().add(json.len()) = 0;
    }
    LumenEngineStatus::Ok
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_end_session(
    engine: *mut LumenWorkspaceEngine,
) -> LumenEngineStatus {
    with_engine_mut(engine, WorkspaceEngine::end_session)
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_state(
    engine: *const LumenWorkspaceEngine,
) -> LumenWorkspaceState {
    let Some(engine) = NonNull::new(engine.cast_mut()) else {
        return LumenWorkspaceState::Idle;
    };
    // SAFETY: Category 3 (dangling pointer). The C ABI caller keeps the engine
    // alive for the duration of this read-only state query.
    catch_unwind(AssertUnwindSafe(|| unsafe { engine.as_ref().inner.state }))
        .unwrap_or(LumenWorkspaceState::Idle)
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_generation(engine: *const LumenWorkspaceEngine) -> u64 {
    let Some(engine) = NonNull::new(engine.cast_mut()) else {
        return 0;
    };
    // SAFETY: Category 3 (dangling pointer). The C ABI caller keeps the engine
    // alive for the duration of this read-only generation query.
    catch_unwind(AssertUnwindSafe(|| unsafe {
        engine.as_ref().inner.generation
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn lumen_workspace_engine_last_failure(
    engine: *const LumenWorkspaceEngine,
) -> LumenEngineStatus {
    with_engine(engine, |engine| engine.last_failure)
}
