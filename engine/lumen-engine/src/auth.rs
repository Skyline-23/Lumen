use crate::device::{DeviceStore, DeviceStoreError};
use crate::owner::{OwnerStore, OwnerStoreError};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr::NonNull;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

pub const AUTH_SCHEMA_VERSION: u32 = 1;
pub const AUTH_ACCESS_TOKEN_LIFETIME_SECONDS: u64 = 15 * 60;
pub const AUTH_CHALLENGE_LIFETIME_SECONDS: u64 = 5 * 60;

const CHALLENGE_BYTE_COUNT: usize = 32;
const P256_X963_PUBLIC_KEY_BYTE_COUNT: usize = 65;
const MAXIMUM_PENDING_CHALLENGES: usize = 256;
const MAXIMUM_IDEMPOTENT_RESPONSES: usize = 256;
const ENROLLMENT_SIGNATURE_DOMAIN: &[u8] = b"LUMEN-AUTH-ENROLLMENT-V1\0";
const TOKEN_EXCHANGE_SIGNATURE_DOMAIN: &[u8] = b"LUMEN-AUTH-TOKEN-EXCHANGE-V1\0";

mod authority;
mod ffi;
mod model;
mod support;

pub use authority::*;
pub use ffi::*;
pub use model::*;

#[cfg(test)]
mod tests;
