use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::LumenEngineStatus;

#[derive(Debug, Default)]
pub struct StreamSessionFleet {
    active_sessions: AtomicU32,
}

impl StreamSessionFleet {
    pub fn enter(&self) -> Result<bool, LumenEngineStatus> {
        self.active_sessions
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                active.checked_add(1)
            })
            .map(|previous| previous == 0)
            .map_err(|_| LumenEngineStatus::InvalidState)
    }

    pub fn leave(&self) -> Result<bool, LumenEngineStatus> {
        self.active_sessions
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                active.checked_sub(1)
            })
            .map(|previous| previous == 1)
            .map_err(|_| LumenEngineStatus::InvalidState)
    }

    #[cfg(test)]
    fn active_sessions(&self) -> u32 {
        self.active_sessions.load(Ordering::Acquire)
    }
}

pub struct LumenStreamSessionFleet {
    inner: StreamSessionFleet,
}

fn with_fleet(
    fleet: *const LumenStreamSessionFleet,
    operation: impl FnOnce(&StreamSessionFleet) -> LumenEngineStatus,
) -> LumenEngineStatus {
    let Some(fleet) = NonNull::new(fleet.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        operation(&unsafe { fleet.as_ref() }.inner)
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_fleet_create(
    fleet_out: *mut *mut LumenStreamSessionFleet,
) -> LumenEngineStatus {
    let Some(mut fleet_out) = NonNull::new(fleet_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(|| {
        Box::into_raw(Box::new(LumenStreamSessionFleet {
            inner: StreamSessionFleet::default(),
        }))
    }) {
        Ok(fleet) => {
            unsafe { *fleet_out.as_mut() = fleet };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_fleet_destroy(fleet: *mut LumenStreamSessionFleet) {
    if !fleet.is_null() {
        unsafe { drop(Box::from_raw(fleet)) };
    }
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_fleet_enter(
    fleet: *const LumenStreamSessionFleet,
    is_first_out: *mut bool,
) -> LumenEngineStatus {
    let Some(mut is_first_out) = NonNull::new(is_first_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_fleet(fleet, |inner| match inner.enter() {
        Ok(is_first) => {
            unsafe { *is_first_out.as_mut() = is_first };
            LumenEngineStatus::Ok
        }
        Err(status) => status,
    })
}

#[no_mangle]
pub extern "C" fn lumen_stream_session_fleet_leave(
    fleet: *const LumenStreamSessionFleet,
    is_last_out: *mut bool,
) -> LumenEngineStatus {
    let Some(mut is_last_out) = NonNull::new(is_last_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_fleet(fleet, |inner| match inner.leave() {
        Ok(is_last) => {
            unsafe { *is_last_out.as_mut() = is_last };
            LumenEngineStatus::Ok
        }
        Err(status) => status,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fleet_identifies_exactly_one_first_and_last_session() {
        let fleet = StreamSessionFleet::default();
        assert_eq!(fleet.enter(), Ok(true));
        assert_eq!(fleet.enter(), Ok(false));
        assert_eq!(fleet.active_sessions(), 2);
        assert_eq!(fleet.leave(), Ok(false));
        assert_eq!(fleet.leave(), Ok(true));
        assert_eq!(fleet.active_sessions(), 0);
        assert_eq!(fleet.leave(), Err(LumenEngineStatus::InvalidState));
    }

    #[test]
    fn stream_session_fleet_ffi_round_trip() {
        let mut fleet = std::ptr::null_mut();
        assert_eq!(
            lumen_stream_session_fleet_create(&mut fleet),
            LumenEngineStatus::Ok
        );
        assert!(!fleet.is_null());

        let mut boundary = false;
        assert_eq!(
            lumen_stream_session_fleet_enter(fleet, &mut boundary),
            LumenEngineStatus::Ok
        );
        assert!(boundary);
        assert_eq!(
            lumen_stream_session_fleet_leave(fleet, &mut boundary),
            LumenEngineStatus::Ok
        );
        assert!(boundary);

        lumen_stream_session_fleet_destroy(fleet);
    }
}
