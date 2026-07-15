use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr::NonNull;

use crate::LumenEngineStatus;

use super::{ApplicationCatalog, CatalogError};

#[repr(C)]
pub struct LumenApplicationCatalog {
    inner: ApplicationCatalog,
}

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

#[no_mangle]
pub unsafe extern "C" fn lumen_application_catalog_open(
    file_path: *const c_char,
    catalog_out: *mut *mut LumenApplicationCatalog,
) -> LumenEngineStatus {
    let Some(mut catalog_out) = NonNull::new(catalog_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    unsafe { *catalog_out.as_mut() = std::ptr::null_mut() };
    let file_path = match unsafe { required_string(file_path) } {
        Ok(value) => PathBuf::from(value),
        Err(status) => return status,
    };
    match catch_unwind(AssertUnwindSafe(|| ApplicationCatalog::open(file_path))) {
        Ok(Ok(catalog)) => {
            unsafe {
                *catalog_out.as_mut() =
                    Box::into_raw(Box::new(LumenApplicationCatalog { inner: catalog }))
            };
            LumenEngineStatus::Ok
        }
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_application_catalog_destroy(catalog: *mut LumenApplicationCatalog) {
    if !catalog.is_null() {
        drop(unsafe { Box::from_raw(catalog) });
    }
}

#[no_mangle]
pub extern "C" fn lumen_application_catalog_json_size(
    catalog: *const LumenApplicationCatalog,
) -> usize {
    let Some(catalog) = NonNull::new(catalog.cast_mut()) else {
        return 0;
    };
    catch_unwind(AssertUnwindSafe(|| unsafe {
        catalog.as_ref().inner.json()
    }))
    .ok()
    .and_then(Result::ok)
    .map(|json| json.len().saturating_add(1))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn lumen_application_catalog_copy_json(
    catalog: *const LumenApplicationCatalog,
    destination: *mut c_char,
    capacity: usize,
) -> LumenEngineStatus {
    let Some(catalog) = NonNull::new(catalog.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(destination) = NonNull::new(destination.cast::<u8>()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        catalog.as_ref().inner.json()
    })) {
        Ok(Ok(json)) if capacity > json.len() => {
            unsafe {
                std::ptr::copy_nonoverlapping(json.as_ptr(), destination.as_ptr(), json.len());
                *destination.as_ptr().add(json.len()) = 0;
            }
            LumenEngineStatus::Ok
        }
        Ok(Ok(_)) => LumenEngineStatus::InvalidArgument,
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_application_catalog_upsert_json(
    catalog: *mut LumenApplicationCatalog,
    application_json: *const c_char,
) -> LumenEngineStatus {
    unsafe { with_catalog_mut(catalog, application_json, ApplicationCatalog::upsert) }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_application_catalog_delete(
    catalog: *mut LumenApplicationCatalog,
    application_id: *const c_char,
) -> LumenEngineStatus {
    unsafe { with_catalog_mut(catalog, application_id, ApplicationCatalog::delete) }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_application_catalog_reorder_json(
    catalog: *mut LumenApplicationCatalog,
    application_ids_json: *const c_char,
) -> LumenEngineStatus {
    unsafe { with_catalog_mut(catalog, application_ids_json, ApplicationCatalog::reorder) }
}

unsafe fn with_catalog_mut(
    catalog: *mut LumenApplicationCatalog,
    value: *const c_char,
    operation: impl FnOnce(&ApplicationCatalog, &str) -> Result<(), CatalogError>,
) -> LumenEngineStatus {
    let Some(mut catalog) = NonNull::new(catalog) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let value = match unsafe { required_string(value) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        operation(&catalog.as_mut().inner, &value)
    })) {
        Ok(Ok(())) => LumenEngineStatus::Ok,
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}
