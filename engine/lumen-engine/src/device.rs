use crate::owner::{LumenOwnerStore, OwnerStore};
use crate::LumenEngineStatus;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::ffi::{c_char, CStr};
use std::fs;
use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr::NonNull;
use std::time::{SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;

const REGISTRY_VERSION: u32 = 1;
const DEVICE_ID_BYTE_COUNT: usize = 16;
const REFRESH_TOKEN_BYTE_COUNT: usize = 32;
const MAXIMUM_DEVICE_NAME_LENGTH: usize = 128;
const MAXIMUM_PLATFORM_LENGTH: usize = 64;
const MINIMUM_PUBLIC_KEY_LENGTH: usize = 32;
const MAXIMUM_PUBLIC_KEY_LENGTH: usize = 8 * 1024;

#[derive(Debug, Deserialize, Serialize)]
struct DeviceRegistry {
    version: u32,
    devices: Vec<DeviceRecord>,
}

impl Default for DeviceRegistry {
    fn default() -> Self {
        Self {
            version: REGISTRY_VERSION,
            devices: Vec::new(),
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct DeviceRecord {
    id: String,
    name: String,
    platform: String,
    public_key: String,
    refresh_token_hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    access_token_hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    access_token_expires_at_unix_seconds: Option<u64>,
    created_at_unix_seconds: u64,
    revoked: bool,
}

#[derive(Debug)]
pub(crate) enum DeviceStoreError {
    InvalidArgument,
    AlreadyExists,
    AuthenticationFailed,
    Revoked,
    AccessTokenExpired,
    Storage,
    Corrupt,
}

impl DeviceStoreError {
    fn status(&self) -> LumenEngineStatus {
        match self {
            Self::InvalidArgument => LumenEngineStatus::InvalidArgument,
            Self::AlreadyExists => LumenEngineStatus::AlreadyExists,
            Self::AuthenticationFailed => LumenEngineStatus::AuthenticationFailed,
            Self::Revoked | Self::AccessTokenExpired => LumenEngineStatus::AuthenticationFailed,
            Self::Storage => LumenEngineStatus::StorageError,
            Self::Corrupt => LumenEngineStatus::CorruptData,
        }
    }
}

pub(crate) struct Enrollment {
    pub(crate) device_id: String,
    pub(crate) refresh_token: String,
}

pub(crate) struct IssuedCredentials {
    pub(crate) refresh_token: String,
    pub(crate) access_token: String,
    pub(crate) access_token_expires_at_unix_seconds: u64,
}

#[derive(Debug)]
pub(crate) struct DeviceStore {
    pub(crate) file_path: PathBuf,
}

impl DeviceStore {
    pub(crate) fn open(file_path: PathBuf) -> Result<Self, DeviceStoreError> {
        if file_path.as_os_str().is_empty() || file_path.file_name().is_none() {
            return Err(DeviceStoreError::InvalidArgument);
        }
        Ok(Self { file_path })
    }

    pub(crate) fn enroll(
        &self,
        owner_store: &OwnerStore,
        owner_username: &str,
        owner_password: &str,
        device_name: &str,
        platform: &str,
        public_key: &str,
    ) -> Result<Enrollment, DeviceStoreError> {
        if !owner_store.credentials_match(owner_username, owner_password) {
            return Err(DeviceStoreError::AuthenticationFailed);
        }
        let device_name = normalized_label(device_name, MAXIMUM_DEVICE_NAME_LENGTH)?;
        let platform = normalized_label(platform, MAXIMUM_PLATFORM_LENGTH)?;
        let public_key = public_key.trim();
        if !(MINIMUM_PUBLIC_KEY_LENGTH..=MAXIMUM_PUBLIC_KEY_LENGTH).contains(&public_key.len()) {
            return Err(DeviceStoreError::InvalidArgument);
        }

        let mut registry = self.read_registry()?;
        if registry
            .devices
            .iter()
            .any(|device| !device.revoked && device.public_key == public_key)
        {
            return Err(DeviceStoreError::AlreadyExists);
        }

        let device_id = random_token(DEVICE_ID_BYTE_COUNT);
        let refresh_token = random_token(REFRESH_TOKEN_BYTE_COUNT);
        registry.devices.push(DeviceRecord {
            id: device_id.clone(),
            name: device_name,
            platform,
            public_key: public_key.to_owned(),
            refresh_token_hash: token_hash(&refresh_token),
            access_token_hash: None,
            access_token_expires_at_unix_seconds: None,
            created_at_unix_seconds: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| DeviceStoreError::Storage)?
                .as_secs(),
            revoked: false,
        });
        self.write_registry(&registry)?;
        Ok(Enrollment {
            device_id,
            refresh_token,
        })
    }

    fn verify_refresh_token(
        &self,
        device_id: &str,
        refresh_token: &str,
    ) -> Result<(), DeviceStoreError> {
        let candidate_hash = token_hash(refresh_token);
        let registry = self.read_registry()?;
        let Some(device) = registry
            .devices
            .iter()
            .find(|device| device.id == device_id && !device.revoked)
        else {
            return Err(DeviceStoreError::AuthenticationFailed);
        };
        if candidate_hash
            .as_bytes()
            .ct_eq(device.refresh_token_hash.as_bytes())
            .into()
        {
            Ok(())
        } else {
            Err(DeviceStoreError::AuthenticationFailed)
        }
    }

    pub(crate) fn rotate_refresh_token_and_issue_access(
        &self,
        device_id: &str,
        refresh_token: &str,
        access_token_expires_at_unix_seconds: u64,
    ) -> Result<IssuedCredentials, DeviceStoreError> {
        if device_id.is_empty()
            || refresh_token.is_empty()
            || access_token_expires_at_unix_seconds == 0
        {
            return Err(DeviceStoreError::InvalidArgument);
        }
        let candidate_hash = token_hash(refresh_token);
        let mut registry = self.read_registry()?;
        let Some(device) = registry
            .devices
            .iter_mut()
            .find(|device| device.id == device_id)
        else {
            return Err(DeviceStoreError::AuthenticationFailed);
        };
        if device.revoked {
            return Err(DeviceStoreError::Revoked);
        }
        if !bool::from(
            candidate_hash
                .as_bytes()
                .ct_eq(device.refresh_token_hash.as_bytes()),
        ) {
            return Err(DeviceStoreError::AuthenticationFailed);
        }

        let new_refresh_token = random_token(REFRESH_TOKEN_BYTE_COUNT);
        let access_token = random_token(REFRESH_TOKEN_BYTE_COUNT);
        device.refresh_token_hash = token_hash(&new_refresh_token);
        device.access_token_hash = Some(token_hash(&access_token));
        device.access_token_expires_at_unix_seconds = Some(access_token_expires_at_unix_seconds);
        self.write_registry(&registry)?;
        Ok(IssuedCredentials {
            refresh_token: new_refresh_token,
            access_token,
            access_token_expires_at_unix_seconds,
        })
    }

    pub(crate) fn verify_access_token(
        &self,
        device_id: &str,
        access_token: &str,
        now_unix_seconds: u64,
    ) -> Result<(), DeviceStoreError> {
        if device_id.is_empty() || access_token.is_empty() {
            return Err(DeviceStoreError::InvalidArgument);
        }
        let candidate_hash = token_hash(access_token);
        let registry = self.read_registry()?;
        let Some(device) = registry
            .devices
            .iter()
            .find(|device| device.id == device_id)
        else {
            return Err(DeviceStoreError::AuthenticationFailed);
        };
        if device.revoked {
            return Err(DeviceStoreError::Revoked);
        }
        let (Some(access_token_hash), Some(expires_at)) = (
            device.access_token_hash.as_deref(),
            device.access_token_expires_at_unix_seconds,
        ) else {
            return Err(DeviceStoreError::AuthenticationFailed);
        };
        if !bool::from(
            candidate_hash
                .as_bytes()
                .ct_eq(access_token_hash.as_bytes()),
        ) {
            return Err(DeviceStoreError::AuthenticationFailed);
        }
        if now_unix_seconds >= expires_at {
            return Err(DeviceStoreError::AccessTokenExpired);
        }
        Ok(())
    }

    pub(crate) fn revoke(&self, device_id: &str) -> Result<(), DeviceStoreError> {
        let mut registry = self.read_registry()?;
        let Some(device) = registry
            .devices
            .iter_mut()
            .find(|device| device.id == device_id && !device.revoked)
        else {
            return Err(DeviceStoreError::AuthenticationFailed);
        };
        device.revoked = true;
        device.access_token_hash = None;
        device.access_token_expires_at_unix_seconds = None;
        self.write_registry(&registry)
    }

    pub(crate) fn revoke_authorized(
        &self,
        owner_store: &OwnerStore,
        owner_username: &str,
        owner_password: &str,
        device_id: &str,
    ) -> Result<(), DeviceStoreError> {
        if !owner_store.credentials_match(owner_username, owner_password) {
            return Err(DeviceStoreError::AuthenticationFailed);
        }
        self.revoke(device_id)
    }

    fn active_count(&self) -> u32 {
        self.read_registry()
            .map(|registry| {
                registry
                    .devices
                    .iter()
                    .filter(|device| !device.revoked)
                    .count()
                    .try_into()
                    .unwrap_or(u32::MAX)
            })
            .unwrap_or(0)
    }

    pub(crate) fn public_key_for_active_device(
        &self,
        device_id: &str,
    ) -> Result<String, DeviceStoreError> {
        let registry = self.read_registry()?;
        let Some(device) = registry
            .devices
            .iter()
            .find(|device| device.id == device_id)
        else {
            return Err(DeviceStoreError::AuthenticationFailed);
        };
        if device.revoked {
            return Err(DeviceStoreError::Revoked);
        }
        Ok(device.public_key.clone())
    }

    fn read_registry(&self) -> Result<DeviceRegistry, DeviceStoreError> {
        let data = match fs::read(&self.file_path) {
            Ok(data) => data,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(DeviceRegistry::default())
            }
            Err(_) => return Err(DeviceStoreError::Storage),
        };
        let registry: DeviceRegistry =
            serde_json::from_slice(&data).map_err(|_| DeviceStoreError::Corrupt)?;
        if registry.version != REGISTRY_VERSION
            || registry.devices.iter().any(|device| {
                device.id.is_empty()
                    || device.name.is_empty()
                    || device.platform.is_empty()
                    || device.public_key.is_empty()
                    || device.refresh_token_hash.is_empty()
                    || device.access_token_hash.is_some()
                        != device.access_token_expires_at_unix_seconds.is_some()
                    || device.access_token_expires_at_unix_seconds == Some(0)
            })
        {
            return Err(DeviceStoreError::Corrupt);
        }
        Ok(registry)
    }

    fn write_registry(&self, registry: &DeviceRegistry) -> Result<(), DeviceStoreError> {
        let parent = self
            .file_path
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .ok_or(DeviceStoreError::InvalidArgument)?;
        fs::create_dir_all(parent).map_err(|_| DeviceStoreError::Storage)?;

        let serialized =
            serde_json::to_vec_pretty(registry).map_err(|_| DeviceStoreError::Storage)?;
        let mut temporary_file = tempfile::Builder::new()
            .prefix(".devices.")
            .tempfile_in(parent)
            .map_err(|_| DeviceStoreError::Storage)?;
        temporary_file
            .write_all(&serialized)
            .and_then(|_| temporary_file.as_file().sync_all())
            .map_err(|_| DeviceStoreError::Storage)?;
        temporary_file
            .persist(&self.file_path)
            .map_err(|_| DeviceStoreError::Storage)?;
        Ok(())
    }
}

fn normalized_label(value: &str, maximum_length: usize) -> Result<String, DeviceStoreError> {
    let value = value.trim();
    if value.is_empty()
        || value.chars().count() > maximum_length
        || value.chars().any(char::is_control)
    {
        return Err(DeviceStoreError::InvalidArgument);
    }
    Ok(value.to_owned())
}

fn random_token(byte_count: usize) -> String {
    let mut bytes = vec![0; byte_count];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn token_hash(token: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
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

unsafe fn copy_string(
    value: &str,
    destination: *mut c_char,
    capacity: usize,
) -> Result<(), LumenEngineStatus> {
    if destination.is_null() || value.len() >= capacity {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    unsafe {
        std::ptr::copy_nonoverlapping(value.as_ptr(), destination.cast::<u8>(), value.len());
        destination.add(value.len()).write(0);
    }
    Ok(())
}

#[repr(C)]
pub struct LumenDeviceStore {
    inner: DeviceStore,
}

#[no_mangle]
pub unsafe extern "C" fn lumen_device_store_open(
    file_path: *const c_char,
    store_out: *mut *mut LumenDeviceStore,
) -> LumenEngineStatus {
    let Some(mut store_out) = NonNull::new(store_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    unsafe { *store_out.as_mut() = std::ptr::null_mut() };
    let file_path = match unsafe { required_utf8(file_path) } {
        Ok(value) => PathBuf::from(value),
        Err(status) => return status,
    };
    match catch_unwind(AssertUnwindSafe(|| DeviceStore::open(file_path))) {
        Ok(Ok(store)) => {
            unsafe {
                *store_out.as_mut() = Box::into_raw(Box::new(LumenDeviceStore { inner: store }))
            };
            LumenEngineStatus::Ok
        }
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_device_store_destroy(store: *mut LumenDeviceStore) {
    if !store.is_null() {
        drop(unsafe { Box::from_raw(store) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_device_store_enroll(
    store: *mut LumenDeviceStore,
    owner_store: *const LumenOwnerStore,
    owner_username: *const c_char,
    owner_password: *const c_char,
    device_name: *const c_char,
    platform: *const c_char,
    public_key: *const c_char,
    device_id_destination: *mut c_char,
    device_id_capacity: usize,
    refresh_token_destination: *mut c_char,
    refresh_token_capacity: usize,
) -> LumenEngineStatus {
    let (Some(mut store), Some(owner_store)) =
        (NonNull::new(store), NonNull::new(owner_store.cast_mut()))
    else {
        return LumenEngineStatus::InvalidArgument;
    };
    if device_id_destination.is_null()
        || device_id_capacity < 32
        || refresh_token_destination.is_null()
        || refresh_token_capacity < 64
    {
        return LumenEngineStatus::InvalidArgument;
    }
    let values = [
        owner_username,
        owner_password,
        device_name,
        platform,
        public_key,
    ]
    .map(|value| unsafe { required_utf8(value) });
    let [Ok(owner_username), Ok(owner_password), Ok(device_name), Ok(platform), Ok(public_key)] =
        values
    else {
        return LumenEngineStatus::InvalidArgument;
    };

    match catch_unwind(AssertUnwindSafe(|| unsafe {
        store.as_mut().inner.enroll(
            &owner_store.as_ref().inner,
            owner_username,
            owner_password,
            device_name,
            platform,
            public_key,
        )
    })) {
        Ok(Ok(enrollment)) => {
            if unsafe {
                copy_string(
                    &enrollment.device_id,
                    device_id_destination,
                    device_id_capacity,
                )
                .and_then(|_| {
                    copy_string(
                        &enrollment.refresh_token,
                        refresh_token_destination,
                        refresh_token_capacity,
                    )
                })
            }
            .is_err()
            {
                return LumenEngineStatus::InvalidArgument;
            }
            LumenEngineStatus::Ok
        }
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_device_store_verify_refresh_token(
    store: *const LumenDeviceStore,
    device_id: *const c_char,
    refresh_token: *const c_char,
) -> LumenEngineStatus {
    let Some(store) = NonNull::new(store.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let device_id = match unsafe { required_utf8(device_id) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    let refresh_token = match unsafe { required_utf8(refresh_token) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        store
            .as_ref()
            .inner
            .verify_refresh_token(device_id, refresh_token)
    })) {
        Ok(Ok(())) => LumenEngineStatus::Ok,
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub unsafe extern "C" fn lumen_device_store_revoke(
    store: *mut LumenDeviceStore,
    owner_store: *const LumenOwnerStore,
    owner_username: *const c_char,
    owner_password: *const c_char,
    device_id: *const c_char,
) -> LumenEngineStatus {
    let (Some(mut store), Some(owner_store)) =
        (NonNull::new(store), NonNull::new(owner_store.cast_mut()))
    else {
        return LumenEngineStatus::InvalidArgument;
    };
    let owner_username = match unsafe { required_utf8(owner_username) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    let owner_password = match unsafe { required_utf8(owner_password) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    let device_id = match unsafe { required_utf8(device_id) } {
        Ok(value) => value,
        Err(status) => return status,
    };
    match catch_unwind(AssertUnwindSafe(|| unsafe {
        store.as_mut().inner.revoke_authorized(
            &owner_store.as_ref().inner,
            owner_username,
            owner_password,
            device_id,
        )
    })) {
        Ok(Ok(())) => LumenEngineStatus::Ok,
        Ok(Err(error)) => error.status(),
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_device_store_active_count(store: *const LumenDeviceStore) -> u32 {
    let Some(store) = NonNull::new(store.cast_mut()) else {
        return 0;
    };
    catch_unwind(AssertUnwindSafe(|| unsafe {
        store.as_ref().inner.active_count()
    }))
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    #[test]
    fn enrollment_hashes_refresh_tokens_and_revocation_is_immediate() {
        let sequence = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "lumen-device-store-{}-{sequence}",
            std::process::id()
        ));
        let owner_store = OwnerStore::open(root.join("owner-account.json")).unwrap();
        owner_store
            .create_owner("owner", "correct horse battery staple")
            .unwrap();
        let device_store = DeviceStore::open(root.join("devices.json")).unwrap();

        let enrollment = device_store
            .enroll(
                &owner_store,
                "owner",
                "correct horse battery staple",
                "Living Room Tablet",
                "ios",
                "MCowBQYDK2VwAyEAu2y4x9h0B5y3lQ8xY7jW4C6Q7m8n9p0a1b2c3d4e5f6=",
            )
            .unwrap();
        assert_eq!(device_store.active_count(), 1);
        assert!(device_store
            .verify_refresh_token(&enrollment.device_id, &enrollment.refresh_token)
            .is_ok());

        let persisted = fs::read_to_string(&device_store.file_path).unwrap();
        assert!(!persisted.contains(&enrollment.refresh_token));
        assert!(persisted.contains("refresh_token_hash"));

        assert!(matches!(
            device_store.revoke_authorized(
                &owner_store,
                "owner",
                "wrong password",
                &enrollment.device_id,
            ),
            Err(DeviceStoreError::AuthenticationFailed)
        ));
        assert_eq!(device_store.active_count(), 1);
        device_store
            .revoke_authorized(
                &owner_store,
                "owner",
                "correct horse battery staple",
                &enrollment.device_id,
            )
            .unwrap();
        assert_eq!(device_store.active_count(), 0);
        assert!(matches!(
            device_store.verify_refresh_token(&enrollment.device_id, &enrollment.refresh_token),
            Err(DeviceStoreError::AuthenticationFailed)
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn enrollment_requires_valid_owner_credentials() {
        let sequence = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "lumen-device-auth-{}-{sequence}",
            std::process::id()
        ));
        let owner_store = OwnerStore::open(root.join("owner-account.json")).unwrap();
        owner_store
            .create_owner("owner", "correct horse battery staple")
            .unwrap();
        let device_store = DeviceStore::open(root.join("devices.json")).unwrap();

        assert!(matches!(
            device_store.enroll(
                &owner_store,
                "owner",
                "wrong password",
                "Tablet",
                "android",
                "MCowBQYDK2VwAyEAu2y4x9h0B5y3lQ8xY7jW4C6Q7m8n9p0a1b2c3d4e5f6=",
            ),
            Err(DeviceStoreError::AuthenticationFailed)
        ));
        assert_eq!(device_store.active_count(), 0);
        fs::remove_dir_all(root).unwrap();
    }
}
