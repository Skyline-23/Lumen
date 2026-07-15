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
            inner: WorkspaceEngine::with_recovery_store(RecoveryJournalStore::new(PathBuf::from(
                path,
            ))),
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
pub extern "C" fn lumen_workspace_engine_complete_command(
    engine: *mut LumenWorkspaceEngine,
    command: LumenWorkspaceCommand,
    succeeded: bool,
) -> LumenEngineStatus {
    with_engine_mut(engine, |engine| engine.complete_command(command, succeeded))
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
