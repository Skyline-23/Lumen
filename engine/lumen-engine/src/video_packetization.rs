use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

const MAX_REED_SOLOMON_SHARDS: u64 = 255;
const MAX_FEC_BLOCKS: u32 = 4;
const MAX_FEC_PERCENTAGE: u32 = 255;
const MAX_FEC_PACKET_INDEX: u64 = 1024;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenVideoFecBlockPlan {
    pub requested_block_count: u64,
    pub block_count: u32,
    pub effective_fec_percentage: u32,
    pub aligned_block_size: u64,
    pub packet_index_overflow: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenVideoFecShardPlan {
    pub data_shards: u64,
    pub parity_shards: u64,
    pub total_shards: u64,
    pub effective_fec_percentage: u32,
    pub parity_limited: bool,
}

fn checked_div_ceil(value: u64, divisor: u64) -> Option<u64> {
    value
        .checked_add(divisor.checked_sub(1)?)?
        .checked_div(divisor)
}

pub fn plan_fec_blocks(
    payload_size: u64,
    block_size: u64,
    fec_percentage: u32,
) -> Result<LumenVideoFecBlockPlan, LumenEngineStatus> {
    if payload_size == 0 || block_size == 0 || fec_percentage > MAX_FEC_PERCENTAGE {
        return Err(LumenEngineStatus::InvalidArgument);
    }

    let max_data_shards = MAX_REED_SOLOMON_SHARDS
        .checked_mul(100)
        .and_then(|scaled| scaled.checked_div(100 + u64::from(fec_percentage)))
        .filter(|shards| *shards > 0)
        .ok_or(LumenEngineStatus::InvalidState)?;
    let max_data_per_block = max_data_shards
        .checked_mul(block_size)
        .ok_or(LumenEngineStatus::InvalidState)?;
    let requested_block_count = checked_div_ceil(payload_size, max_data_per_block)
        .ok_or(LumenEngineStatus::InvalidState)?;
    let block_count = requested_block_count.min(u64::from(MAX_FEC_BLOCKS)) as u32;
    let effective_fec_percentage = if requested_block_count > u64::from(MAX_FEC_BLOCKS) {
        0
    } else {
        fec_percentage
    };

    let unaligned_block_size = payload_size / u64::from(block_count);
    let aligned_block_size = checked_div_ceil(unaligned_block_size, block_size)
        .and_then(|blocks| blocks.checked_mul(block_size))
        .ok_or(LumenEngineStatus::InvalidState)?;

    Ok(LumenVideoFecBlockPlan {
        requested_block_count,
        block_count,
        effective_fec_percentage,
        aligned_block_size,
        packet_index_overflow: aligned_block_size / block_size >= MAX_FEC_PACKET_INDEX,
    })
}

pub fn plan_fec_shards(
    payload_size: u64,
    block_size: u64,
    fec_percentage: u32,
    minimum_parity_shards: u32,
) -> Result<LumenVideoFecShardPlan, LumenEngineStatus> {
    if payload_size == 0
        || block_size == 0
        || fec_percentage > MAX_FEC_PERCENTAGE
        || minimum_parity_shards > MAX_REED_SOLOMON_SHARDS as u32
    {
        return Err(LumenEngineStatus::InvalidArgument);
    }

    let data_shards =
        checked_div_ceil(payload_size, block_size).ok_or(LumenEngineStatus::InvalidState)?;
    if fec_percentage == 0 {
        return Ok(LumenVideoFecShardPlan {
            data_shards,
            parity_shards: 0,
            total_shards: data_shards,
            effective_fec_percentage: 0,
            parity_limited: false,
        });
    }

    let nominal_parity = checked_div_ceil(
        data_shards
            .checked_mul(u64::from(fec_percentage))
            .ok_or(LumenEngineStatus::InvalidState)?,
        100,
    )
    .ok_or(LumenEngineStatus::InvalidState)?;
    let requested_parity = nominal_parity.max(u64::from(minimum_parity_shards));
    let available_parity = MAX_REED_SOLOMON_SHARDS
        .checked_sub(data_shards)
        .ok_or(LumenEngineStatus::InvalidState)?;
    let parity_shards = requested_parity.min(available_parity);
    if parity_shards == 0 {
        return Err(LumenEngineStatus::InvalidState);
    }
    let parity_limited = parity_shards < requested_parity;
    let effective_fec_percentage = if parity_limited || requested_parity > nominal_parity {
        parity_shards
            .checked_mul(100)
            .and_then(|scaled| scaled.checked_div(data_shards))
            .and_then(|percentage| u32::try_from(percentage).ok())
            .ok_or(LumenEngineStatus::InvalidState)?
            .min(MAX_FEC_PERCENTAGE)
    } else {
        fec_percentage
    };

    Ok(LumenVideoFecShardPlan {
        data_shards,
        parity_shards,
        total_shards: data_shards + parity_shards,
        effective_fec_percentage,
        parity_limited,
    })
}

#[no_mangle]
pub extern "C" fn lumen_engine_plan_video_fec_blocks(
    payload_size: u64,
    block_size: u64,
    fec_percentage: u32,
    plan_out: *mut LumenVideoFecBlockPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        match plan_fec_blocks(payload_size, block_size, fec_percentage) {
            Ok(plan) => {
                unsafe { *plan_out.as_mut() = plan };
                LumenEngineStatus::Ok
            }
            Err(status) => status,
        }
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

#[no_mangle]
pub extern "C" fn lumen_engine_plan_video_fec_shards(
    payload_size: u64,
    block_size: u64,
    fec_percentage: u32,
    minimum_parity_shards: u32,
    plan_out: *mut LumenVideoFecShardPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        match plan_fec_shards(
            payload_size,
            block_size,
            fec_percentage,
            minimum_parity_shards,
        ) {
            Ok(plan) => {
                unsafe { *plan_out.as_mut() = plan };
                LumenEngineStatus::Ok
            }
            Err(status) => status,
        }
    }))
    .unwrap_or(LumenEngineStatus::Panic)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_plan_preserves_protocol_block_and_packet_index_limits() {
        let block_size = 1_000;
        let max_data_per_block = 212 * block_size;
        let plan = plan_fec_blocks(max_data_per_block * 2 + 1, block_size, 20).unwrap();
        assert_eq!(plan.requested_block_count, 3);
        assert_eq!(plan.block_count, 3);
        assert_eq!(plan.effective_fec_percentage, 20);
        assert_eq!(plan.aligned_block_size % block_size, 0);
        assert!(!plan.packet_index_overflow);

        let oversized = plan_fec_blocks(5_000_000, block_size, 20).unwrap();
        assert!(oversized.requested_block_count > u64::from(MAX_FEC_BLOCKS));
        assert_eq!(oversized.block_count, MAX_FEC_BLOCKS);
        assert_eq!(oversized.effective_fec_percentage, 0);
        assert!(oversized.packet_index_overflow);
    }

    #[test]
    fn shard_plan_applies_minimum_parity_and_bounds_reed_solomon_shards() {
        let nominal = plan_fec_shards(1_001, 1_000, 20, 0).unwrap();
        assert_eq!(nominal.parity_shards, 1);
        assert_eq!(nominal.effective_fec_percentage, 20);

        let plan = plan_fec_shards(1_001, 1_000, 20, 2).unwrap();
        assert_eq!(plan.data_shards, 2);
        assert_eq!(plan.parity_shards, 2);
        assert_eq!(plan.total_shards, 4);
        assert_eq!(plan.effective_fec_percentage, 100);
        assert!(!plan.parity_limited);

        let bounded = plan_fec_shards(200_000, 1_000, 20, 255).unwrap();
        assert_eq!(bounded.data_shards, 200);
        assert_eq!(bounded.parity_shards, 55);
        assert_eq!(bounded.total_shards, MAX_REED_SOLOMON_SHARDS);
        assert!(bounded.effective_fec_percentage <= MAX_FEC_PERCENTAGE);
        assert!(bounded.parity_limited);
    }

    #[test]
    fn disabled_fec_keeps_data_shards_without_allocating_parity() {
        let plan = plan_fec_shards(5_000_000, 1_000, 0, 255).unwrap();
        assert_eq!(plan.data_shards, 5_000);
        assert_eq!(plan.parity_shards, 0);
        assert_eq!(plan.total_shards, 5_000);
        assert_eq!(plan.effective_fec_percentage, 0);
    }

    #[test]
    fn video_fec_plan_ffi_round_trip() {
        let mut block_plan = LumenVideoFecBlockPlan::default();
        assert_eq!(
            lumen_engine_plan_video_fec_blocks(1_001, 1_000, 20, &mut block_plan),
            LumenEngineStatus::Ok
        );
        assert_eq!(block_plan.block_count, 1);

        let mut shard_plan = LumenVideoFecShardPlan::default();
        assert_eq!(
            lumen_engine_plan_video_fec_shards(1_001, 1_000, 20, 2, &mut shard_plan),
            LumenEngineStatus::Ok
        );
        assert_eq!(shard_plan.total_shards, 4);
    }
}
