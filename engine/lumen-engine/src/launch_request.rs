use std::collections::BTreeMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::{
    parse_session_offer, resolve_audio_selection, LumenAudioSelectionPlan, LumenEngineStatus,
    LumenSessionOffer,
};

const REQUIRED_FIELDS: &[&str] = &[
    "appid",
    "mode",
    "sops",
    "rikey",
    "rikeyid",
    "localAudioPlayMode",
    "audioChannelMode",
    "enhancedAudioQuality",
    "gcmap",
    "lumenSessionOffer",
];
const OPTIONAL_FIELDS: &[&str] = &["virtualDisplay"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LaunchRequestErrorCode {
    MissingField,
    DuplicateField,
    UnknownField,
    InvalidValue,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LaunchRequestError {
    pub code: LaunchRequestErrorCode,
    pub field: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LaunchDisplayMode {
    pub width: u32,
    pub height: u32,
    pub frames_per_second: u32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LumenLaunchRequest {
    pub application_id: u32,
    pub display_mode: LaunchDisplayMode,
    pub remote_input_key: [u8; 16],
    pub remote_input_key_id: u32,
    pub play_audio_on_host: bool,
    pub audio: LumenAudioSelectionPlan,
    pub virtual_display: bool,
    pub session_offer: LumenSessionOffer,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenLaunchQueryField {
    pub name: *const u8,
    pub name_length: usize,
    pub value: *const u8,
    pub value_length: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LumenLaunchRequestPlan {
    pub application_id: u32,
    pub width: u32,
    pub height: u32,
    pub frames_per_second: u32,
    pub remote_input_key: [u8; 16],
    pub remote_input_key_id: u32,
    pub play_audio_on_host: bool,
    pub audio: LumenAudioSelectionPlan,
    pub virtual_display: bool,
    pub session_offer: LumenSessionOffer,
}

impl From<LumenLaunchRequest> for LumenLaunchRequestPlan {
    fn from(request: LumenLaunchRequest) -> Self {
        Self {
            application_id: request.application_id,
            width: request.display_mode.width,
            height: request.display_mode.height,
            frames_per_second: request.display_mode.frames_per_second,
            remote_input_key: request.remote_input_key,
            remote_input_key_id: request.remote_input_key_id,
            play_audio_on_host: request.play_audio_on_host,
            audio: request.audio,
            virtual_display: request.virtual_display,
            session_offer: request.session_offer,
        }
    }
}

pub fn parse_launch_request(
    query: &[(String, String)],
) -> Result<LumenLaunchRequest, LaunchRequestError> {
    let mut fields = BTreeMap::new();
    for (name, value) in query {
        if !REQUIRED_FIELDS.contains(&name.as_str()) && !OPTIONAL_FIELDS.contains(&name.as_str()) {
            return Err(error(LaunchRequestErrorCode::UnknownField, name));
        }
        if fields.insert(name.as_str(), value.as_str()).is_some() {
            return Err(error(LaunchRequestErrorCode::DuplicateField, name));
        }
    }
    for name in REQUIRED_FIELDS {
        if !fields.contains_key(name) {
            return Err(error(LaunchRequestErrorCode::MissingField, *name));
        }
    }

    let application_id = parse_u32(required(&fields, "appid")?, "appid")?;
    if application_id == 0 {
        return Err(error(LaunchRequestErrorCode::InvalidValue, "appid"));
    }
    let display_mode = parse_display_mode(required(&fields, "mode")?)?;
    require_fixed(&fields, "sops", "1")?;
    require_fixed(&fields, "gcmap", "1")?;
    let remote_input_key = parse_input_key(required(&fields, "rikey")?)?;
    let remote_input_key_id = parse_u32(required(&fields, "rikeyid")?, "rikeyid")?;
    let play_audio_on_host = parse_wire_bool(required(&fields, "localAudioPlayMode")?)
        .ok_or_else(|| error(LaunchRequestErrorCode::InvalidValue, "localAudioPlayMode"))?;
    let virtual_display = match fields.get("virtualDisplay") {
        None => false,
        Some(value) => parse_wire_bool(value)
            .filter(|enabled| *enabled)
            .ok_or_else(|| error(LaunchRequestErrorCode::InvalidValue, "virtualDisplay"))?,
    };
    let audio = resolve_audio_selection(
        required(&fields, "audioChannelMode")?.as_bytes(),
        parse_wire_bool(required(&fields, "enhancedAudioQuality")?)
            .ok_or_else(|| error(LaunchRequestErrorCode::InvalidValue, "enhancedAudioQuality"))?,
    )
    .map_err(|_| error(LaunchRequestErrorCode::InvalidValue, "audioChannelMode"))?;
    let session_offer = parse_session_offer(required(&fields, "lumenSessionOffer")?.as_bytes())
        .ok_or_else(|| error(LaunchRequestErrorCode::InvalidValue, "lumenSessionOffer"))?;

    Ok(LumenLaunchRequest {
        application_id,
        display_mode,
        remote_input_key,
        remote_input_key_id,
        play_audio_on_host,
        audio,
        virtual_display,
        session_offer,
    })
}

fn required<'a>(
    fields: &'a BTreeMap<&str, &str>,
    name: &str,
) -> Result<&'a str, LaunchRequestError> {
    fields
        .get(name)
        .copied()
        .ok_or_else(|| error(LaunchRequestErrorCode::MissingField, name))
}

fn require_fixed(
    fields: &BTreeMap<&str, &str>,
    name: &str,
    expected: &str,
) -> Result<(), LaunchRequestError> {
    if required(fields, name)? == expected {
        Ok(())
    } else {
        Err(error(LaunchRequestErrorCode::InvalidValue, name))
    }
}

fn parse_u32(value: &str, field: &str) -> Result<u32, LaunchRequestError> {
    value
        .parse::<u32>()
        .map_err(|_| error(LaunchRequestErrorCode::InvalidValue, field))
}

fn parse_display_mode(value: &str) -> Result<LaunchDisplayMode, LaunchRequestError> {
    let mut components = value.split('x');
    let width = components
        .next()
        .and_then(|value| value.parse::<u32>().ok());
    let height = components
        .next()
        .and_then(|value| value.parse::<u32>().ok());
    let frames_per_second = components
        .next()
        .and_then(|value| value.parse::<u32>().ok());
    if components.next().is_some()
        || width.is_none_or(|value| !(1..=16_384).contains(&value))
        || height.is_none_or(|value| !(1..=16_384).contains(&value))
        || frames_per_second.is_none_or(|value| !(1..=1_000).contains(&value))
    {
        return Err(error(LaunchRequestErrorCode::InvalidValue, "mode"));
    }
    Ok(LaunchDisplayMode {
        width: width.unwrap_or_default(),
        height: height.unwrap_or_default(),
        frames_per_second: frames_per_second.unwrap_or_default(),
    })
}

fn parse_input_key(value: &str) -> Result<[u8; 16], LaunchRequestError> {
    if value.len() != 32 {
        return Err(error(LaunchRequestErrorCode::InvalidValue, "rikey"));
    }
    let mut key = [0_u8; 16];
    for (index, byte) in key.iter_mut().enumerate() {
        let offset = index * 2;
        *byte = u8::from_str_radix(&value[offset..offset + 2], 16)
            .map_err(|_| error(LaunchRequestErrorCode::InvalidValue, "rikey"))?;
    }
    Ok(key)
}

fn parse_wire_bool(value: &str) -> Option<bool> {
    match value {
        "0" => Some(false),
        "1" => Some(true),
        _ => None,
    }
}

fn error(code: LaunchRequestErrorCode, field: impl Into<String>) -> LaunchRequestError {
    LaunchRequestError {
        code,
        field: field.into(),
    }
}

unsafe fn field_text(pointer: *const u8, length: usize) -> Result<String, LumenEngineStatus> {
    if length == 0 {
        return Ok(String::new());
    }
    let pointer = NonNull::new(pointer.cast_mut()).ok_or(LumenEngineStatus::InvalidArgument)?;
    let bytes = unsafe { std::slice::from_raw_parts(pointer.as_ptr(), length) };
    std::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| LumenEngineStatus::InvalidArgument)
}

#[no_mangle]
/// Parses one complete launch query into a fixed-layout native plan.
///
/// # Safety
///
/// `fields` must reference `field_count` readable entries whose name and value
/// pointers remain valid for their declared lengths during this call.
/// `plan_out` must reference writable storage for one `LumenLaunchRequestPlan`.
pub unsafe extern "C" fn lumen_engine_parse_launch_request(
    fields: *const LumenLaunchQueryField,
    field_count: usize,
    plan_out: *mut LumenLaunchRequestPlan,
) -> LumenEngineStatus {
    let Some(fields) = NonNull::new(fields.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    if field_count == 0 || field_count > REQUIRED_FIELDS.len() + OPTIONAL_FIELDS.len() {
        return LumenEngineStatus::InvalidArgument;
    }
    match catch_unwind(AssertUnwindSafe(|| {
        let fields = unsafe { std::slice::from_raw_parts(fields.as_ptr(), field_count) };
        let query = fields
            .iter()
            .map(|field| unsafe {
                Ok((
                    field_text(field.name, field.name_length)?,
                    field_text(field.value, field.value_length)?,
                ))
            })
            .collect::<Result<Vec<_>, LumenEngineStatus>>()?;
        parse_launch_request(&query)
            .map(LumenLaunchRequestPlan::from)
            .map_err(|_| LumenEngineStatus::InvalidArgument)
    })) {
        Ok(Ok(plan)) => {
            unsafe { *plan_out.as_mut() = plan };
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests;
