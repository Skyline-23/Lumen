use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenVideoRateRequest {
    pub requested_frame_rate: i32,
    pub session_frame_rate_millihertz: i32,
    pub configured_bitrate_kbps: i64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenVideoRatePlan {
    pub normalized_frame_rate: i32,
    pub warp_factor: u32,
    pub restored_bitrate_kbps: i64,
}

fn resolve_video_rate(
    request: LumenVideoRateRequest,
) -> Result<LumenVideoRatePlan, LumenEngineStatus> {
    if request.session_frame_rate_millihertz <= 0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    let normalized_frame_rate = if request.requested_frame_rate > 4_000 {
        (request.requested_frame_rate as f32 / 1_000.0).round() as i32
    } else {
        request.requested_frame_rate
    };
    if normalized_frame_rate < 0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }

    let warp_factor = ((normalized_frame_rate as f32 * 1_000.0)
        / request.session_frame_rate_millihertz as f32)
        .round() as u32;
    let restored_bitrate_kbps = if warp_factor >= 2 {
        request
            .configured_bitrate_kbps
            .checked_mul(i64::from(warp_factor))
            .ok_or(LumenEngineStatus::InvalidArgument)?
    } else {
        request.configured_bitrate_kbps
    };

    Ok(LumenVideoRatePlan {
        normalized_frame_rate,
        warp_factor,
        restored_bitrate_kbps,
    })
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_video_rate(
    request: LumenVideoRateRequest,
    plan_out: *mut LumenVideoRatePlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_video_rate(request))) {
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
    fn normalizes_millihertz_requests_before_deriving_warp() {
        assert_eq!(
            resolve_video_rate(LumenVideoRateRequest {
                requested_frame_rate: 60_000,
                session_frame_rate_millihertz: 60_000,
                configured_bitrate_kbps: 10_000,
            }),
            Ok(LumenVideoRatePlan {
                normalized_frame_rate: 60,
                warp_factor: 1,
                restored_bitrate_kbps: 10_000,
            })
        );
        assert_eq!(
            resolve_video_rate(LumenVideoRateRequest {
                requested_frame_rate: 240_000,
                session_frame_rate_millihertz: 60_000,
                configured_bitrate_kbps: 10_000,
            }),
            Ok(LumenVideoRatePlan {
                normalized_frame_rate: 240,
                warp_factor: 4,
                restored_bitrate_kbps: 40_000,
            })
        );
    }

    #[test]
    fn preserves_the_legacy_fractional_threshold_and_rounding() {
        let boundary = resolve_video_rate(LumenVideoRateRequest {
            requested_frame_rate: 4_000,
            session_frame_rate_millihertz: 60_000,
            configured_bitrate_kbps: 1_000,
        })
        .unwrap();
        assert_eq!(boundary.normalized_frame_rate, 4_000);
        assert_eq!(boundary.warp_factor, 67);
        assert_eq!(boundary.restored_bitrate_kbps, 67_000);

        let above_boundary = resolve_video_rate(LumenVideoRateRequest {
            requested_frame_rate: 4_001,
            session_frame_rate_millihertz: 60_000,
            configured_bitrate_kbps: 1_000,
        })
        .unwrap();
        assert_eq!(above_boundary.normalized_frame_rate, 4);
        assert_eq!(above_boundary.warp_factor, 0);
        assert_eq!(above_boundary.restored_bitrate_kbps, 1_000);
    }

    #[test]
    fn rejects_invalid_session_rates_and_bitrate_overflow() {
        assert_eq!(
            resolve_video_rate(LumenVideoRateRequest {
                requested_frame_rate: 120,
                session_frame_rate_millihertz: 0,
                configured_bitrate_kbps: 10_000,
            }),
            Err(LumenEngineStatus::InvalidArgument)
        );
        assert_eq!(
            resolve_video_rate(LumenVideoRateRequest {
                requested_frame_rate: 120,
                session_frame_rate_millihertz: 60_000,
                configured_bitrate_kbps: i64::MAX,
            }),
            Err(LumenEngineStatus::InvalidArgument)
        );
    }
}
