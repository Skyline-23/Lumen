use std::collections::BTreeMap;
use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::sync::Mutex;

use crate::LumenEngineStatus;

#[derive(Debug, Default)]
pub struct SessionRegistry {
    pending_launch_id: Option<u32>,
    active_by_device: BTreeMap<String, u32>,
    active_count: usize,
}

impl SessionRegistry {
    pub fn offer_pending(&mut self, launch_id: u32) -> Result<(), LumenEngineStatus> {
        if self.pending_launch_id.is_some() {
            return Err(LumenEngineStatus::AlreadyExists);
        }
        self.pending_launch_id = Some(launch_id);
        Ok(())
    }

    pub fn clear_pending(&mut self, launch_id: u32) -> Result<(), LumenEngineStatus> {
        match self.pending_launch_id {
            None => Err(LumenEngineStatus::NoCommand),
            Some(current) if current != launch_id => Err(LumenEngineStatus::CommandMismatch),
            Some(_) => {
                self.pending_launch_id = None;
                Ok(())
            }
        }
    }

    pub fn activate(&mut self, device_id: &str) -> Result<(), LumenEngineStatus> {
        if device_id.is_empty() {
            return Err(LumenEngineStatus::InvalidArgument);
        }
        *self
            .active_by_device
            .entry(device_id.to_owned())
            .or_default() += 1;
        self.active_count += 1;
        Ok(())
    }

    pub fn deactivate(&mut self, device_id: &str) -> Result<(), LumenEngineStatus> {
        let Some(count) = self.active_by_device.get_mut(device_id) else {
            return Err(LumenEngineStatus::NoCommand);
        };
        *count -= 1;
        self.active_count -= 1;
        if *count == 0 {
            self.active_by_device.remove(device_id);
        }
        Ok(())
    }

    pub fn active_count(&self) -> usize {
        self.active_count
    }

    pub fn contains(&self, device_id: &str) -> bool {
        self.active_by_device.contains_key(device_id)
    }
}

pub struct LumenSessionRegistry {
    inner: Mutex<SessionRegistry>,
}

fn required_c_string(value: *const c_char) -> Result<String, LumenEngineStatus> {
    let value = NonNull::new(value.cast_mut()).ok_or(LumenEngineStatus::InvalidArgument)?;
    unsafe { CStr::from_ptr(value.as_ptr()) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| LumenEngineStatus::InvalidArgument)
}

fn with_registry_mut(
    registry: *mut LumenSessionRegistry,
    operation: impl FnOnce(&mut SessionRegistry) -> Result<(), LumenEngineStatus>,
) -> LumenEngineStatus {
    let Some(registry) = NonNull::new(registry) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(mut inner) = unsafe { registry.as_ref() }.inner.lock() else {
            return LumenEngineStatus::Panic;
        };
        operation(&mut inner).map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

fn with_registry(
    registry: *const LumenSessionRegistry,
    operation: impl FnOnce(&SessionRegistry) -> LumenEngineStatus,
) -> LumenEngineStatus {
    let Some(registry) = NonNull::new(registry.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(inner) = unsafe { registry.as_ref() }.inner.lock() else {
            return LumenEngineStatus::Panic;
        };
        operation(&inner)
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

#[no_mangle]
pub extern "C" fn lumen_session_registry_create(
    registry_out: *mut *mut LumenSessionRegistry,
) -> LumenEngineStatus {
    let Some(mut registry_out) = NonNull::new(registry_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(|| {
        Box::into_raw(Box::new(LumenSessionRegistry {
            inner: Mutex::new(SessionRegistry::default()),
        }))
    }) {
        Ok(registry) => {
            unsafe { *registry_out.as_mut() = registry };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_session_registry_destroy(registry: *mut LumenSessionRegistry) {
    if !registry.is_null() {
        unsafe { drop(Box::from_raw(registry)) };
    }
}

#[no_mangle]
pub extern "C" fn lumen_session_registry_offer_pending(
    registry: *mut LumenSessionRegistry,
    launch_id: u32,
) -> LumenEngineStatus {
    with_registry_mut(registry, |inner| inner.offer_pending(launch_id))
}

#[no_mangle]
pub extern "C" fn lumen_session_registry_clear_pending(
    registry: *mut LumenSessionRegistry,
    launch_id: u32,
) -> LumenEngineStatus {
    with_registry_mut(registry, |inner| inner.clear_pending(launch_id))
}

#[no_mangle]
pub extern "C" fn lumen_session_registry_activate(
    registry: *mut LumenSessionRegistry,
    device_id: *const c_char,
) -> LumenEngineStatus {
    let Ok(device_id) = required_c_string(device_id) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_registry_mut(registry, |inner| inner.activate(&device_id))
}

#[no_mangle]
pub extern "C" fn lumen_session_registry_deactivate(
    registry: *mut LumenSessionRegistry,
    device_id: *const c_char,
) -> LumenEngineStatus {
    let Ok(device_id) = required_c_string(device_id) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_registry_mut(registry, |inner| inner.deactivate(&device_id))
}

#[no_mangle]
pub extern "C" fn lumen_session_registry_active_count(
    registry: *const LumenSessionRegistry,
    count_out: *mut usize,
) -> LumenEngineStatus {
    let Some(mut count_out) = NonNull::new(count_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_registry(registry, |inner| {
        unsafe { *count_out.as_mut() = inner.active_count() };
        LumenEngineStatus::Ok
    })
}

#[no_mangle]
pub extern "C" fn lumen_session_registry_contains(
    registry: *const LumenSessionRegistry,
    device_id: *const c_char,
    contains_out: *mut bool,
) -> LumenEngineStatus {
    let Ok(device_id) = required_c_string(device_id) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut contains_out) = NonNull::new(contains_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    with_registry(registry, |inner| {
        unsafe { *contains_out.as_mut() = inner.contains(&device_id) };
        LumenEngineStatus::Ok
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn pending_launch_admission_is_single_and_id_checked() {
        let mut registry = SessionRegistry::default();

        assert_eq!(registry.offer_pending(7), Ok(()));
        assert_eq!(
            registry.offer_pending(8),
            Err(LumenEngineStatus::AlreadyExists)
        );
        assert_eq!(
            registry.clear_pending(8),
            Err(LumenEngineStatus::CommandMismatch)
        );
        assert_eq!(registry.clear_pending(7), Ok(()));
        assert_eq!(registry.clear_pending(7), Err(LumenEngineStatus::NoCommand));
    }

    #[test]
    fn active_registry_counts_repeated_device_sessions() {
        let mut registry = SessionRegistry::default();

        registry.activate("device-a").unwrap();
        registry.activate("device-a").unwrap();
        registry.activate("device-b").unwrap();
        assert_eq!(registry.active_count(), 3);
        assert!(registry.contains("device-a"));

        registry.deactivate("device-a").unwrap();
        assert_eq!(registry.active_count(), 2);
        assert!(registry.contains("device-a"));
        registry.deactivate("device-a").unwrap();
        assert!(!registry.contains("device-a"));
    }

    #[test]
    fn ffi_registry_round_trips_pending_and_active_state() {
        let mut registry = std::ptr::null_mut();
        assert_eq!(
            lumen_session_registry_create(&mut registry),
            LumenEngineStatus::Ok
        );
        assert_eq!(
            lumen_session_registry_offer_pending(registry, 42),
            LumenEngineStatus::Ok
        );
        assert_eq!(
            lumen_session_registry_clear_pending(registry, 42),
            LumenEngineStatus::Ok
        );

        let device = CString::new("device-a").unwrap();
        assert_eq!(
            lumen_session_registry_activate(registry, device.as_ptr()),
            LumenEngineStatus::Ok
        );
        let mut count = 0;
        assert_eq!(
            lumen_session_registry_active_count(registry, &mut count),
            LumenEngineStatus::Ok
        );
        assert_eq!(count, 1);
        lumen_session_registry_destroy(registry);
    }
}
