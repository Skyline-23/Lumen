use crate::LumenEngineStatus;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use std::ffi::{c_char, CStr};
use std::fs;
use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr::NonNull;

const OWNER_RECORD_VERSION: u32 = 1;
const MINIMUM_PASSWORD_LENGTH: usize = 12;
const MAXIMUM_PASSWORD_LENGTH: usize = 1024;
const MAXIMUM_USERNAME_LENGTH: usize = 64;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenOwnerState {
    Uninitialized = 0,
    Ready = 1,
    Corrupt = 2,
    Unavailable = 3,
}

#[derive(Debug, Deserialize, Serialize)]
struct OwnerRecord {
    version: u32,
    username: String,
    password_hash: String,
}

#[derive(Debug)]
pub(crate) enum OwnerStoreError {
    Missing,
    InvalidArgument,
    AlreadyExists,
    AuthenticationFailed,
    Storage,
    Corrupt,
}

impl OwnerStoreError {
    fn status(&self) -> LumenEngineStatus {
        match self {
            Self::Missing => LumenEngineStatus::InvalidState,
            Self::InvalidArgument => LumenEngineStatus::InvalidArgument,
            Self::AlreadyExists => LumenEngineStatus::AlreadyExists,
            Self::AuthenticationFailed => LumenEngineStatus::AuthenticationFailed,
            Self::Storage => LumenEngineStatus::StorageError,
            Self::Corrupt => LumenEngineStatus::CorruptData,
        }
    }
}

#[derive(Debug)]
pub(crate) struct OwnerStore {
    file_path: PathBuf,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OwnerAccountError {
    InvalidArgument,
    AlreadyExists,
    AuthenticationFailed,
    Storage,
    Corrupt,
}

impl From<OwnerStoreError> for OwnerAccountError {
    fn from(error: OwnerStoreError) -> Self {
        match error {
            OwnerStoreError::Missing | OwnerStoreError::Storage => Self::Storage,
            OwnerStoreError::InvalidArgument => Self::InvalidArgument,
            OwnerStoreError::AlreadyExists => Self::AlreadyExists,
            OwnerStoreError::AuthenticationFailed => Self::AuthenticationFailed,
            OwnerStoreError::Corrupt => Self::Corrupt,
        }
    }
}

#[derive(Debug)]
pub struct OwnerAccountStore {
    inner: OwnerStore,
}

impl OwnerAccountStore {
    pub fn open(file_path: PathBuf) -> Result<Self, OwnerAccountError> {
        OwnerStore::open(file_path)
            .map(|inner| Self { inner })
            .map_err(OwnerAccountError::from)
    }

    pub fn state(&self) -> LumenOwnerState {
        self.inner.state()
    }

    pub fn create_owner(&self, username: &str, password: &str) -> Result<(), OwnerAccountError> {
        self.inner
            .create_owner(username, password)
            .map_err(OwnerAccountError::from)
    }

    pub fn verify_owner(&self, username: &str, password: &str) -> Result<(), OwnerAccountError> {
        self.inner
            .verify_owner(username, password)
            .map_err(OwnerAccountError::from)
    }

    pub fn username(&self) -> Result<String, OwnerAccountError> {
        self.inner.username().map_err(OwnerAccountError::from)
    }
}

impl OwnerStore {
    pub(crate) fn open(file_path: PathBuf) -> Result<Self, OwnerStoreError> {
        if file_path.as_os_str().is_empty() || file_path.file_name().is_none() {
            return Err(OwnerStoreError::InvalidArgument);
        }
        Ok(Self { file_path })
    }

    fn state(&self) -> LumenOwnerState {
        match self.read_record() {
            Ok(_) => LumenOwnerState::Ready,
            Err(OwnerStoreError::Missing) => LumenOwnerState::Uninitialized,
            Err(OwnerStoreError::Storage) => LumenOwnerState::Unavailable,
            Err(_) => LumenOwnerState::Corrupt,
        }
    }

    pub(crate) fn create_owner(
        &self,
        username: &str,
        password: &str,
    ) -> Result<(), OwnerStoreError> {
        if self.file_path.exists() {
            return Err(OwnerStoreError::AlreadyExists);
        }
        let username = normalize_username(username)?;
        validate_password(password)?;

        let salt = SaltString::generate(&mut OsRng);
        let password_hash = Argon2::default()
            .hash_password(password.as_bytes(), &salt)
            .map_err(|_| OwnerStoreError::Storage)?
            .to_string();
        self.write_record(&OwnerRecord {
            version: OWNER_RECORD_VERSION,
            username,
            password_hash,
        })
    }

    pub(crate) fn verify_owner(
        &self,
        username: &str,
        password: &str,
    ) -> Result<(), OwnerStoreError> {
        let record = self.read_record()?;
        let username = normalize_username(username)?;
        let password_hash =
            PasswordHash::new(&record.password_hash).map_err(|_| OwnerStoreError::Corrupt)?;
        let password_matches = Argon2::default()
            .verify_password(password.as_bytes(), &password_hash)
            .is_ok();
        if username == record.username && password_matches {
            Ok(())
        } else {
            Err(OwnerStoreError::AuthenticationFailed)
        }
    }

    pub(crate) fn credentials_match(&self, username: &str, password: &str) -> bool {
        self.verify_owner(username, password).is_ok()
    }

    fn username(&self) -> Result<String, OwnerStoreError> {
        Ok(self.read_record()?.username)
    }

    fn read_record(&self) -> Result<OwnerRecord, OwnerStoreError> {
        let data = match fs::read(&self.file_path) {
            Ok(data) => data,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(OwnerStoreError::Missing)
            }
            Err(_) => return Err(OwnerStoreError::Storage),
        };
        let record: OwnerRecord =
            serde_json::from_slice(&data).map_err(|_| OwnerStoreError::Corrupt)?;
        let normalized_username =
            normalize_username(&record.username).map_err(|_| OwnerStoreError::Corrupt)?;
        if record.version != OWNER_RECORD_VERSION
            || normalized_username != record.username
            || PasswordHash::new(&record.password_hash).is_err()
        {
            return Err(OwnerStoreError::Corrupt);
        }
        Ok(record)
    }

    fn write_record(&self, record: &OwnerRecord) -> Result<(), OwnerStoreError> {
        let parent = self
            .file_path
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .ok_or(OwnerStoreError::InvalidArgument)?;
        fs::create_dir_all(parent).map_err(|_| OwnerStoreError::Storage)?;

        let serialized = serde_json::to_vec_pretty(record).map_err(|_| OwnerStoreError::Storage)?;
        let mut temporary_file = tempfile::Builder::new()
            .prefix(".owner-account.")
            .tempfile_in(parent)
            .map_err(|_| OwnerStoreError::Storage)?;
        temporary_file
            .write_all(&serialized)
            .and_then(|_| temporary_file.as_file().sync_all())
            .map_err(|_| OwnerStoreError::Storage)?;
        temporary_file
            .persist(&self.file_path)
            .map_err(|_| OwnerStoreError::Storage)?;
        Ok(())
    }
}

fn normalize_username(username: &str) -> Result<String, OwnerStoreError> {
    let username = username.trim();
    if username.is_empty()
        || username.chars().count() > MAXIMUM_USERNAME_LENGTH
        || username.chars().any(char::is_control)
    {
        return Err(OwnerStoreError::InvalidArgument);
    }
    Ok(username.to_owned())
}

fn validate_password(password: &str) -> Result<(), OwnerStoreError> {
    if !(MINIMUM_PASSWORD_LENGTH..=MAXIMUM_PASSWORD_LENGTH).contains(&password.len()) {
        return Err(OwnerStoreError::InvalidArgument);
    }
    Ok(())
}

unsafe fn required_utf8<'a>(value: *const c_char) -> Result<&'a str, LumenEngineStatus> {
    if value.is_null() {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    let value = unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| LumenEngineStatus::InvalidArgument)?;
    if value.is_empty() {
        Err(LumenEngineStatus::InvalidArgument)
    } else {
        Ok(value)
    }
}

#[repr(C)]
pub struct LumenOwnerStore {
    pub(crate) inner: OwnerStore,
}

#[no_mangle]
/// # Safety
///
/// `file_path` must reference a valid null-terminated UTF-8 string and
/// `store_out` must reference writable pointer storage.
pub unsafe extern "C" fn lumen_owner_store_open(
    file_path: *const c_char,
    store_out: *mut *mut LumenOwnerStore,
) -> LumenEngineStatus {
    let Some(mut store_out) = NonNull::new(store_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    unsafe { *store_out.as_mut() = std::ptr::null_mut() };
    let file_path = match unsafe { required_utf8(file_path) } {
        Ok(value) => PathBuf::from(value),
        Err(status) => return status,
    };
    match catch_unwind(AssertUnwindSafe(|| OwnerStore::open(file_path))) {
        Ok(Ok(store)) => {
            unsafe {
                *store_out.as_mut() = Box::into_raw(Box::new(LumenOwnerStore { inner: store }))
            };
            LumenEngineStatus::Ok
        }
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
/// # Safety
///
/// `store` must be null or a live pointer returned by
/// [`lumen_owner_store_open`] that has not already been destroyed.
pub unsafe extern "C" fn lumen_owner_store_destroy(store: *mut LumenOwnerStore) {
    if !store.is_null() {
        drop(unsafe { Box::from_raw(store) });
    }
}

#[no_mangle]
pub extern "C" fn lumen_owner_store_state(store: *const LumenOwnerStore) -> LumenOwnerState {
    let Some(store) = NonNull::new(store.cast_mut()) else {
        return LumenOwnerState::Unavailable;
    };
    catch_unwind(AssertUnwindSafe(|| unsafe { store.as_ref().inner.state() }))
        .unwrap_or(LumenOwnerState::Unavailable)
}

#[no_mangle]
/// # Safety
///
/// `username` and `password` must reference valid null-terminated UTF-8
/// strings for the duration of this call.
pub unsafe extern "C" fn lumen_owner_store_create_owner(
    store: *mut LumenOwnerStore,
    username: *const c_char,
    password: *const c_char,
) -> LumenEngineStatus {
    let Some(mut store) = NonNull::new(store) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let username = match unsafe { required_utf8(username) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    let password = match unsafe { required_utf8(password) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        store.as_mut().inner.create_owner(username, password)
    })) {
        Ok(Ok(())) => LumenEngineStatus::Ok,
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
/// # Safety
///
/// `username` and `password` must reference valid null-terminated UTF-8
/// strings for the duration of this call.
pub unsafe extern "C" fn lumen_owner_store_verify_owner(
    store: *const LumenOwnerStore,
    username: *const c_char,
    password: *const c_char,
) -> LumenEngineStatus {
    let Some(store) = NonNull::new(store.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let username = match unsafe { required_utf8(username) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    let password = match unsafe { required_utf8(password) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        store.as_ref().inner.verify_owner(username, password)
    })) {
        Ok(Ok(())) => LumenEngineStatus::Ok,
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
/// # Safety
///
/// `destination` must reference `capacity` writable bytes.
pub unsafe extern "C" fn lumen_owner_store_copy_username(
    store: *const LumenOwnerStore,
    destination: *mut c_char,
    capacity: usize,
) -> LumenEngineStatus {
    let Some(store) = NonNull::new(store.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    if destination.is_null() || capacity == 0 {
        return LumenEngineStatus::InvalidArgument;
    }
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        let username = store.as_ref().inner.username()?;
        if username.len() >= capacity {
            return Err(OwnerStoreError::InvalidArgument);
        }
        std::ptr::copy_nonoverlapping(username.as_ptr(), destination.cast(), username.len());
        destination.add(username.len()).write(0);
        Ok::<(), OwnerStoreError>(())
    })) {
        Ok(Ok(())) => LumenEngineStatus::Ok,
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn test_store() -> (PathBuf, OwnerStore) {
        let sequence = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "lumen-owner-store-{}-{sequence}",
            std::process::id()
        ));
        let store = OwnerStore::open(root.join("owner-account.json")).unwrap();
        (root, store)
    }

    #[test]
    fn owner_account_uses_argon2id_and_verifies_credentials() {
        let (root, store) = test_store();
        assert_eq!(store.state(), LumenOwnerState::Uninitialized);

        store
            .create_owner(" owner ", "correct horse battery staple")
            .unwrap();
        assert_eq!(store.state(), LumenOwnerState::Ready);
        assert!(store
            .verify_owner("owner", "correct horse battery staple")
            .is_ok());
        assert!(matches!(
            store.verify_owner("owner", "incorrect password"),
            Err(OwnerStoreError::AuthenticationFailed)
        ));
        assert!(matches!(
            store.create_owner("owner", "another secure password"),
            Err(OwnerStoreError::AlreadyExists)
        ));

        let persisted = fs::read_to_string(&store.file_path).unwrap();
        assert!(persisted.contains("$argon2id$"));
        assert!(!persisted.contains("correct horse battery staple"));
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(&store.file_path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn owner_account_rejects_short_passwords() {
        let (root, store) = test_store();
        assert!(matches!(
            store.create_owner("owner", "short"),
            Err(OwnerStoreError::InvalidArgument)
        ));
        assert_eq!(store.state(), LumenOwnerState::Uninitialized);
        let _ = fs::remove_dir_all(root);
    }
}
