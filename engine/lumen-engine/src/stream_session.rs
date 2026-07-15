use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::LumenEngineStatus;

pub const STREAM_SESSION_STOPPED: u32 = 0;
#[allow(dead_code)]
pub const STREAM_SESSION_STARTING: u32 = 1;
pub const STREAM_SESSION_RUNNING: u32 = 2;
pub const STREAM_SESSION_STOPPING: u32 = 3;

#[derive(Debug, Default)]
pub struct StreamSessionState {
    value: AtomicU32,
}

impl StreamSessionState {
    pub fn load(&self) -> u32 {
        self.value.load(Ordering::Acquire)
    }

    pub fn mark_running(&self) -> Result<(), LumenEngineStatus> {
        self.value
            .compare_exchange(
                STREAM_SESSION_STOPPED,
                STREAM_SESSION_RUNNING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map(|_| ())
            .map_err(|_| LumenEngineStatus::InvalidState)
    }

    pub fn request_stop(&self) -> Result<(), LumenEngineStatus> {
        self.value
            .compare_exchange(
                STREAM_SESSION_RUNNING,
                STREAM_SESSION_STOPPING,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .map(|_| ())
            .map_err(|_| LumenEngineStatus::NoCommand)
    }

    pub fn mark_stopped(&self) {
        self.value.store(STREAM_SESSION_STOPPED, Ordering::Release);
    }
}

pub struct LumenStreamSessionState {
    inner: StreamSessionState,
}

fn with_state(
    state: *const LumenStreamSessionState,
    operation: impl FnOnce(&StreamSessionState) -> LumenEngineStatus,
) -> LumenEngineStatus {
    let Some(state) = NonNull::new(state.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        operation(&unsafe { state.as_ref() }.inner)
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_state_create(
    state_out: *mut *mut LumenStreamSessionState,
) -> LumenEngineStatus {
    let Some(mut state_out) = NonNull::new(state_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(|| {
        Box::into_raw(Box::new(LumenStreamSessionState {
            inner: StreamSessionState::default(),
        }))
    }) {
        Ok(state) => {
            unsafe { *state_out.as_mut() = state };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_state_destroy(state: *mut LumenStreamSessionState) {
    if !state.is_null() {
        unsafe { drop(Box::from_raw(state)) };
    }
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_state_load(
    state: *const LumenStreamSessionState,
    value_out: *mut u32,
) -> LumenEngineStatus {
    let Some(mut value_out) = NonNull::new(value_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_state(state, |inner| {
        unsafe { *value_out.as_mut() = inner.load() };
        LumenEngineStatus::Ok
    })
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_state_mark_running(
    state: *const LumenStreamSessionState,
) -> LumenEngineStatus {
    with_state(state, |inner| {
        inner
            .mark_running()
            .map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_state_request_stop(
    state: *const LumenStreamSessionState,
) -> LumenEngineStatus {
    with_state(state, |inner| {
        inner
            .request_stop()
            .map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_state_mark_stopped(
    state: *const LumenStreamSessionState,
) -> LumenEngineStatus {
    with_state(state, |inner| {
        inner.mark_stopped();
        LumenEngineStatus::Ok
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_session_state_allows_one_stop_request() {
        let state = StreamSessionState::default();
        assert_eq!(state.load(), STREAM_SESSION_STOPPED);
        assert_eq!(state.mark_running(), Ok(()));
        assert_eq!(state.load(), STREAM_SESSION_RUNNING);
        assert_eq!(state.request_stop(), Ok(()));
        assert_eq!(state.load(), STREAM_SESSION_STOPPING);
        assert_eq!(state.request_stop(), Err(LumenEngineStatus::NoCommand));
        state.mark_stopped();
        assert_eq!(state.load(), STREAM_SESSION_STOPPED);
    }

    #[test]
    fn stopped_or_stopping_sessions_cannot_restart_without_reset() {
        let state = StreamSessionState::default();
        state.mark_running().unwrap();
        state.request_stop().unwrap();
        assert_eq!(state.mark_running(), Err(LumenEngineStatus::InvalidState));
    }

    #[test]
    fn stream_session_state_ffi_round_trip() {
        let mut state = std::ptr::null_mut();
        assert_eq!(
            lumen_stream_session_state_create(&mut state),
            LumenEngineStatus::Ok
        );
        assert!(!state.is_null());

        let mut value = u32::MAX;
        assert_eq!(
            lumen_stream_session_state_load(state, &mut value),
            LumenEngineStatus::Ok
        );
        assert_eq!(value, STREAM_SESSION_STOPPED);
        assert_eq!(
            lumen_stream_session_state_mark_running(state),
            LumenEngineStatus::Ok
        );
        assert_eq!(
            lumen_stream_session_state_request_stop(state),
            LumenEngineStatus::Ok
        );
        assert_eq!(
            lumen_stream_session_state_mark_stopped(state),
            LumenEngineStatus::Ok
        );
        assert_eq!(
            lumen_stream_session_state_load(state, &mut value),
            LumenEngineStatus::Ok
        );
        assert_eq!(value, STREAM_SESSION_STOPPED);

        lumen_stream_session_state_destroy(state);
    }
}
