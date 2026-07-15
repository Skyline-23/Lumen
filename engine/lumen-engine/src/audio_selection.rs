use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

pub const AUDIO_PACKET_DURATION_MILLISECONDS: i32 = 5;
pub const AUDIO_QOS_TRAFFIC_TYPE: i32 = 4;
pub const AUDIO_CHANNEL_MODE_WIRE_VALUES: [&str; 3] = ["stereo", "5.1", "7.1"];
pub const ENHANCED_AUDIO_QUALITY_SUPPORTED: bool = true;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenAudioChannelMode {
    Stereo = 0,
    FivePointOne = 1,
    SevenPointOne = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenAudioSelectionRequest {
    pub channel_mode: *const u8,
    pub channel_mode_length: usize,
    pub enhanced_audio_quality: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenAudioSelectionPlan {
    pub channel_mode: LumenAudioChannelMode,
    pub enhanced_audio_quality: bool,
    pub channel_count: i32,
    pub channel_mask: u32,
    pub packet_duration_milliseconds: i32,
    pub qos_traffic_type: i32,
}

fn parse_channel_mode(value: &[u8]) -> Option<(LumenAudioChannelMode, i32, u32)> {
    match value {
        b"stereo" => Some((LumenAudioChannelMode::Stereo, 2, 0x0003)),
        b"5.1" => Some((LumenAudioChannelMode::FivePointOne, 6, 0x003f)),
        b"7.1" => Some((LumenAudioChannelMode::SevenPointOne, 8, 0x063f)),
        _ => None,
    }
}

pub fn resolve_audio_selection(
    channel_mode: &[u8],
    enhanced_audio_quality: bool,
) -> Result<LumenAudioSelectionPlan, LumenEngineStatus> {
    let (channel_mode, channel_count, channel_mask) =
        parse_channel_mode(channel_mode).ok_or(LumenEngineStatus::InvalidArgument)?;
    Ok(LumenAudioSelectionPlan {
        channel_mode,
        enhanced_audio_quality,
        channel_count,
        channel_mask,
        packet_duration_milliseconds: AUDIO_PACKET_DURATION_MILLISECONDS,
        qos_traffic_type: AUDIO_QOS_TRAFFIC_TYPE,
    })
}

unsafe fn request_slice<'a>(
    value: *const u8,
    length: usize,
) -> Result<&'a [u8], LumenEngineStatus> {
    let value = NonNull::new(value.cast_mut()).ok_or(LumenEngineStatus::InvalidArgument)?;
    if length == 0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    Ok(unsafe { std::slice::from_raw_parts(value.as_ptr(), length) })
}

#[no_mangle]
pub unsafe extern "C" fn lumen_engine_resolve_audio_selection(
    request: LumenAudioSelectionRequest,
    plan_out: *mut LumenAudioSelectionPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        let channel_mode =
            unsafe { request_slice(request.channel_mode, request.channel_mode_length) }?;
        resolve_audio_selection(channel_mode, request.enhanced_audio_quality)
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
mod tests {
    use super::*;

    #[test]
    fn derives_every_canonical_mode_independently_from_quality() {
        let expected = [
            (
                b"stereo".as_slice(),
                LumenAudioChannelMode::Stereo,
                2,
                0x0003,
            ),
            (
                b"5.1".as_slice(),
                LumenAudioChannelMode::FivePointOne,
                6,
                0x003f,
            ),
            (
                b"7.1".as_slice(),
                LumenAudioChannelMode::SevenPointOne,
                8,
                0x063f,
            ),
        ];
        for (wire, mode, channels, mask) in expected {
            for enhanced_audio_quality in [false, true] {
                let plan = resolve_audio_selection(wire, enhanced_audio_quality).unwrap();
                assert_eq!(plan.channel_mode, mode);
                assert_eq!(plan.enhanced_audio_quality, enhanced_audio_quality);
                assert_eq!(plan.channel_count, channels);
                assert_eq!(plan.channel_mask, mask);
                assert_eq!(plan.packet_duration_milliseconds, 5);
                assert_eq!(plan.qos_traffic_type, 4);
            }
        }
    }

    #[test]
    fn rejects_unknown_empty_and_numeric_aliases() {
        for mode in [
            b"".as_slice(),
            b"6",
            b"surround",
            b"surround-5.1",
            b"surround-7.1",
        ] {
            assert_eq!(
                resolve_audio_selection(mode, false),
                Err(LumenEngineStatus::InvalidArgument)
            );
        }
    }
}
