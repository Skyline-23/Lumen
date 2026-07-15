use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

pub const AUDIO_STREAM_PROFILE_COUNT: usize = 6;
pub const AUDIO_SAMPLE_RATE: i32 = 48_000;
pub const AUDIO_OPUS_APPLICATION: &str = "restricted-low-delay";
pub const AUDIO_VARIABLE_BITRATE: bool = false;
const PACKET_QUEUE_BYTE_BUDGET: usize = 32 * 1_024;
const PACKET_QUEUE_LATENCY_BUDGET_MILLISECONDS: usize = 40;
const MINIMUM_PACKET_QUEUE_PACKETS: usize = 2;
const MAXIMUM_PACKET_QUEUE_PACKETS: usize = 8;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAudioStreamRequest {
    pub channels: i32,
    pub packet_duration_milliseconds: i32,
    pub enhanced_audio_quality: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAudioStreamPlan {
    pub sample_rate: i32,
    pub channel_count: i32,
    pub streams: i32,
    pub coupled_streams: i32,
    pub mapping: [u8; 8],
    pub bitrate: i32,
    pub frame_count: i32,
    pub sample_count: usize,
    pub pcm_byte_count: usize,
    pub packet_queue_capacity: u32,
}

const PROFILES: [LumenAudioStreamPlan; AUDIO_STREAM_PROFILE_COUNT] = [
    LumenAudioStreamPlan {
        sample_rate: AUDIO_SAMPLE_RATE,
        channel_count: 2,
        streams: 1,
        coupled_streams: 1,
        mapping: [0, 1, 0, 0, 0, 0, 0, 0],
        bitrate: 96_000,
        frame_count: 0,
        sample_count: 0,
        pcm_byte_count: 0,
        packet_queue_capacity: 0,
    },
    LumenAudioStreamPlan {
        sample_rate: AUDIO_SAMPLE_RATE,
        channel_count: 2,
        streams: 1,
        coupled_streams: 1,
        mapping: [0, 1, 0, 0, 0, 0, 0, 0],
        bitrate: 512_000,
        frame_count: 0,
        sample_count: 0,
        pcm_byte_count: 0,
        packet_queue_capacity: 0,
    },
    LumenAudioStreamPlan {
        sample_rate: AUDIO_SAMPLE_RATE,
        channel_count: 6,
        streams: 4,
        coupled_streams: 2,
        mapping: [0, 1, 2, 3, 4, 5, 0, 0],
        bitrate: 256_000,
        frame_count: 0,
        sample_count: 0,
        pcm_byte_count: 0,
        packet_queue_capacity: 0,
    },
    LumenAudioStreamPlan {
        sample_rate: AUDIO_SAMPLE_RATE,
        channel_count: 6,
        streams: 6,
        coupled_streams: 0,
        mapping: [0, 1, 2, 3, 4, 5, 0, 0],
        bitrate: 1_536_000,
        frame_count: 0,
        sample_count: 0,
        pcm_byte_count: 0,
        packet_queue_capacity: 0,
    },
    LumenAudioStreamPlan {
        sample_rate: AUDIO_SAMPLE_RATE,
        channel_count: 8,
        streams: 5,
        coupled_streams: 3,
        mapping: [0, 1, 2, 3, 4, 5, 6, 7],
        bitrate: 450_000,
        frame_count: 0,
        sample_count: 0,
        pcm_byte_count: 0,
        packet_queue_capacity: 0,
    },
    LumenAudioStreamPlan {
        sample_rate: AUDIO_SAMPLE_RATE,
        channel_count: 8,
        streams: 8,
        coupled_streams: 0,
        mapping: [0, 1, 2, 3, 4, 5, 6, 7],
        bitrate: 2_048_000,
        frame_count: 0,
        sample_count: 0,
        pcm_byte_count: 0,
        packet_queue_capacity: 0,
    },
];

fn profile_index(channels: i32, enhanced_audio_quality: bool) -> usize {
    let quality_offset = usize::from(enhanced_audio_quality);
    match channels {
        2 => quality_offset,
        6 => 2 + quality_offset,
        8 => 4 + quality_offset,
        _ => 0,
    }
}

pub fn resolve_audio_stream(
    request: LumenAudioStreamRequest,
) -> Result<LumenAudioStreamPlan, LumenEngineStatus> {
    let mut plan = PROFILES[profile_index(request.channels, request.enhanced_audio_quality)];
    if request.packet_duration_milliseconds <= 0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    let frame_count = i64::from(request.packet_duration_milliseconds)
        .checked_mul(i64::from(plan.sample_rate))
        .ok_or(LumenEngineStatus::InvalidArgument)?
        / 1_000;
    plan.frame_count = i32::try_from(frame_count)
        .ok()
        .filter(|count| *count > 0)
        .ok_or(LumenEngineStatus::InvalidArgument)?;
    plan.sample_count = usize::try_from(plan.frame_count)
        .ok()
        .and_then(|frames| {
            usize::try_from(plan.channel_count)
                .ok()
                .and_then(|channels| frames.checked_mul(channels))
        })
        .ok_or(LumenEngineStatus::InvalidArgument)?;
    plan.pcm_byte_count = plan
        .sample_count
        .checked_mul(std::mem::size_of::<f32>())
        .ok_or(LumenEngineStatus::InvalidArgument)?;
    let duration = usize::try_from(request.packet_duration_milliseconds)
        .map_err(|_| LumenEngineStatus::InvalidArgument)?;
    let memory_packets = PACKET_QUEUE_BYTE_BUDGET / plan.pcm_byte_count;
    let latency_packets = PACKET_QUEUE_LATENCY_BUDGET_MILLISECONDS.div_ceil(duration);
    plan.packet_queue_capacity = u32::try_from(
        memory_packets
            .min(latency_packets)
            .clamp(MINIMUM_PACKET_QUEUE_PACKETS, MAXIMUM_PACKET_QUEUE_PACKETS),
    )
    .map_err(|_| LumenEngineStatus::InvalidArgument)?;
    Ok(plan)
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_audio_stream(
    request: LumenAudioStreamRequest,
    plan_out: *mut LumenAudioStreamPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_audio_stream(request))) {
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
    fn standard_profiles_preserve_channels_enhanced_quality_and_bitrate_contracts() {
        let expected = [
            (2, false, 96_000),
            (2, true, 512_000),
            (6, false, 256_000),
            (6, true, 1_536_000),
            (8, false, 450_000),
            (8, true, 2_048_000),
        ];
        for (channels, enhanced_audio_quality, bitrate) in expected {
            let plan = resolve_audio_stream(LumenAudioStreamRequest {
                channels,
                packet_duration_milliseconds: 5,
                enhanced_audio_quality,
            })
            .unwrap();
            assert_eq!(plan.sample_rate, AUDIO_SAMPLE_RATE);
            assert_eq!(plan.channel_count, channels);
            assert_eq!(plan.bitrate, bitrate);
        }
    }

    #[test]
    fn packet_queue_capacity_is_bounded_by_channels_and_packet_duration() {
        let expected = [(2, 8), (6, 5), (8, 4)];
        for (channels, packet_budget) in expected {
            for enhanced_audio_quality in [false, true] {
                let plan = resolve_audio_stream(LumenAudioStreamRequest {
                    channels,
                    packet_duration_milliseconds: 5,
                    enhanced_audio_quality,
                })
                .unwrap();
                assert_eq!(plan.packet_queue_capacity, packet_budget);
            }
        }

        let ten_millisecond = resolve_audio_stream(LumenAudioStreamRequest {
            channels: 8,
            packet_duration_milliseconds: 10,
            ..Default::default()
        })
        .unwrap();
        assert_eq!(ten_millisecond.packet_queue_capacity, 2);
    }

    #[test]
    fn native_contract_owns_encoder_budgets_without_changing_latency() {
        assert_eq!(
            crate::AUDIO_CHANNEL_MODE_WIRE_VALUES,
            ["stereo", "5.1", "7.1"]
        );
        const { assert!(crate::ENHANCED_AUDIO_QUALITY_SUPPORTED) };
        assert_eq!(crate::AUDIO_PACKET_DURATION_MILLISECONDS, 5);
        assert_eq!(AUDIO_SAMPLE_RATE, 48_000);
        assert_eq!(AUDIO_OPUS_APPLICATION, "restricted-low-delay");
        const { assert!(!AUDIO_VARIABLE_BITRATE) };

        let profiles = [
            (2, 96_000, 512_000),
            (6, 256_000, 1_536_000),
            (8, 450_000, 2_048_000),
        ];
        for (channels, standard_bitrate, enhanced_bitrate) in profiles {
            let mut packet_budget = None;
            for (enhanced_audio_quality, expected_bitrate) in
                [(false, standard_bitrate), (true, enhanced_bitrate)]
            {
                let plan = resolve_audio_stream(LumenAudioStreamRequest {
                    channels,
                    packet_duration_milliseconds: 5,
                    enhanced_audio_quality,
                })
                .unwrap();
                assert_eq!(plan.bitrate, expected_bitrate);
                assert_eq!(plan.frame_count, 240);
                if let Some(packet_budget) = packet_budget {
                    assert_eq!(plan.packet_queue_capacity, packet_budget);
                } else {
                    packet_budget = Some(plan.packet_queue_capacity);
                }
            }
        }
    }
}
