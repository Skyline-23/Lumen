use std::ffi::{c_char, CStr};
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

#[repr(C)]
#[derive(Debug)]
pub struct LumenOwnedBytes {
    pub data: *mut u8,
    pub length: usize,
}

impl Default for LumenOwnedBytes {
    fn default() -> Self {
        Self {
            data: std::ptr::null_mut(),
            length: 0,
        }
    }
}

fn owned_bytes(bytes: Vec<u8>) -> LumenOwnedBytes {
    if bytes.is_empty() {
        return LumenOwnedBytes::default();
    }
    let boxed = bytes.into_boxed_slice();
    let length = boxed.len();
    let data = Box::into_raw(boxed).cast::<u8>();
    LumenOwnedBytes { data, length }
}

unsafe fn required_path(value: *const c_char) -> Result<PathBuf, LumenEngineStatus> {
    let Some(value) = NonNull::new(value.cast_mut()) else {
        return Err(LumenEngineStatus::InvalidArgument);
    };
    let value = unsafe { CStr::from_ptr(value.as_ptr()) }
        .to_str()
        .map_err(|_| LumenEngineStatus::InvalidArgument)?;
    if value.is_empty() {
        Err(LumenEngineStatus::InvalidArgument)
    } else {
        Ok(PathBuf::from(value))
    }
}

fn parent_directory(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    Path::new(trimmed)
        .parent()
        .map(|parent| parent.to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[no_mangle]
pub extern "C" fn lumen_engine_owned_bytes_destroy(value: LumenOwnedBytes) {
    if value.data.is_null() || value.length == 0 {
        return;
    }
    unsafe {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            value.data,
            value.length,
        )));
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_engine_file_parent_directory(
    path: *const c_char,
    value_out: *mut LumenOwnedBytes,
) -> LumenEngineStatus {
    let Some(value_out) = (unsafe { value_out.as_mut() }) else {
        return LumenEngineStatus::InvalidArgument;
    };
    *value_out = LumenOwnedBytes::default();
    match catch_unwind(AssertUnwindSafe(|| {
        let Some(path) = NonNull::new(path.cast_mut()) else {
            return Err(LumenEngineStatus::InvalidArgument);
        };
        let path = unsafe { CStr::from_ptr(path.as_ptr()) }
            .to_str()
            .map_err(|_| LumenEngineStatus::InvalidArgument)?;
        Ok::<_, LumenEngineStatus>(owned_bytes(parent_directory(path).into_bytes()))
    })) {
        Ok(Ok(value)) => {
            *value_out = value;
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_engine_directory_create(
    path: *const c_char,
    available_out: *mut bool,
) -> LumenEngineStatus {
    let Some(available_out) = (unsafe { available_out.as_mut() }) else {
        return LumenEngineStatus::InvalidArgument;
    };
    *available_out = false;
    match catch_unwind(AssertUnwindSafe(|| {
        let path = unsafe { required_path(path) }?;
        if path.exists() {
            Ok(true)
        } else {
            fs::create_dir_all(path)
                .map(|_| true)
                .map_err(|_| LumenEngineStatus::StorageError)
        }
    })) {
        Ok(Ok(available)) => {
            *available_out = available;
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_engine_file_read(
    path: *const c_char,
    found_out: *mut bool,
    value_out: *mut LumenOwnedBytes,
) -> LumenEngineStatus {
    let Some(found_out) = (unsafe { found_out.as_mut() }) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(value_out) = (unsafe { value_out.as_mut() }) else {
        return LumenEngineStatus::InvalidArgument;
    };
    *found_out = false;
    *value_out = LumenOwnedBytes::default();
    match catch_unwind(AssertUnwindSafe(|| {
        let path = unsafe { required_path(path) }?;
        match fs::read(path) {
            Ok(bytes) => Ok((true, owned_bytes(bytes))),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok((false, LumenOwnedBytes::default()))
            }
            Err(_) => Err(LumenEngineStatus::StorageError),
        }
    })) {
        Ok(Ok((found, value))) => {
            *found_out = found;
            *value_out = value;
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_engine_file_write(
    path: *const c_char,
    data: *const u8,
    length: usize,
) -> LumenEngineStatus {
    if data.is_null() && length != 0 {
        return LumenEngineStatus::InvalidArgument;
    }
    match catch_unwind(AssertUnwindSafe(|| {
        let path = unsafe { required_path(path) }?;
        let bytes = if length == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(data, length) }
        };
        fs::write(path, bytes).map_err(|_| LumenEngineStatus::StorageError)
    })) {
        Ok(Ok(())) => LumenEngineStatus::Ok,
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parent_directory_preserves_legacy_trailing_separator_behavior() {
        assert_eq!(parent_directory("/path/to/file.txt"), "/path/to");
        assert_eq!(parent_directory("/path/to/directory"), "/path/to");
        assert_eq!(parent_directory("/path/to/directory/"), "/path/to");
    }

    #[test]
    fn directory_and_binary_file_operations_round_trip() {
        let root = tempfile::tempdir().unwrap();
        let nested = root.path().join("nested/path");
        fs::create_dir_all(&nested).unwrap();
        assert!(nested.exists());

        let file = nested.join("value.bin");
        let expected = b"Lumen\0Rust";
        fs::write(&file, expected).unwrap();
        assert_eq!(fs::read(&file).unwrap(), expected);
    }
}
