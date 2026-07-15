use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use super::hdr_regions::{
    resolve_hdr_overlay_regions, LumenHdrOverlayRegionPlan, LumenHdrOverlayRegionRequest,
};
use super::{
    TRANSPORT_FRAME_GATED_HDR, TRANSPORT_FULL_FRAME_HDR, TRANSPORT_SDR,
    TRANSPORT_SDR_BASE_HDR_OVERLAY,
};
use crate::{LumenEngineStatus, LumenEngineStatus::InvalidArgument};

pub const HDR_FRAME_CONTENT_SDR: u32 = 0;
pub const HDR_FRAME_CONTENT_FULL: u32 = 1;
pub const HDR_FRAME_CONTENT_OVERLAY: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenHdrFrameStateRequest {
    pub transport: u32,
    pub frame_is_hdr_signaled: bool,
    pub include_overlay_regions: bool,
    pub frame_width: i32,
    pub frame_height: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenHdrFrameStatePlan {
    pub content: u32,
    pub overlay_regions: LumenHdrOverlayRegionPlan,
}

impl Default for LumenHdrFrameStatePlan {
    fn default() -> Self {
        Self {
            content: HDR_FRAME_CONTENT_SDR,
            overlay_regions: LumenHdrOverlayRegionPlan::default(),
        }
    }
}

pub fn resolve_hdr_frame_state(request: LumenHdrFrameStateRequest) -> LumenHdrFrameStatePlan {
    if !request.frame_is_hdr_signaled || request.transport == TRANSPORT_SDR {
        return LumenHdrFrameStatePlan::default();
    }

    match request.transport {
        TRANSPORT_FULL_FRAME_HDR | TRANSPORT_FRAME_GATED_HDR => LumenHdrFrameStatePlan {
            content: HDR_FRAME_CONTENT_FULL,
            ..LumenHdrFrameStatePlan::default()
        },
        TRANSPORT_SDR_BASE_HDR_OVERLAY if request.include_overlay_regions => {
            let overlay_regions = resolve_hdr_overlay_regions(LumenHdrOverlayRegionRequest {
                x: 0,
                y: 0,
                width: request.frame_width,
                height: request.frame_height,
            });
            if overlay_regions.region_count == 0 {
                LumenHdrFrameStatePlan::default()
            } else {
                LumenHdrFrameStatePlan {
                    content: HDR_FRAME_CONTENT_OVERLAY,
                    overlay_regions,
                }
            }
        }
        TRANSPORT_SDR_BASE_HDR_OVERLAY => LumenHdrFrameStatePlan::default(),
        _ => LumenHdrFrameStatePlan {
            content: HDR_FRAME_CONTENT_FULL,
            ..LumenHdrFrameStatePlan::default()
        },
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_hdr_frame_state(
    request: LumenHdrFrameStateRequest,
    plan_out: *mut LumenHdrFrameStatePlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_hdr_frame_state(request))) {
        Ok(plan) => {
            unsafe { *plan_out.as_mut() = plan };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{
        TRANSPORT_FRAME_GATED_HDR, TRANSPORT_FULL_FRAME_HDR, TRANSPORT_SDR,
        TRANSPORT_SDR_BASE_HDR_OVERLAY, TRANSPORT_UNKNOWN,
    };

    fn request(transport: u32, signaled: bool) -> LumenHdrFrameStateRequest {
        LumenHdrFrameStateRequest {
            transport,
            frame_is_hdr_signaled: signaled,
            include_overlay_regions: true,
            frame_width: 1920,
            frame_height: 1080,
        }
    }

    #[test]
    fn rust_owns_default_hdr_frame_state_selection() {
        assert_eq!(
            resolve_hdr_frame_state(request(TRANSPORT_SDR, true)).content,
            HDR_FRAME_CONTENT_SDR
        );
        assert_eq!(
            resolve_hdr_frame_state(request(TRANSPORT_FULL_FRAME_HDR, true)).content,
            HDR_FRAME_CONTENT_FULL
        );
        assert_eq!(
            resolve_hdr_frame_state(request(TRANSPORT_FRAME_GATED_HDR, false)).content,
            HDR_FRAME_CONTENT_SDR
        );
        assert_eq!(
            resolve_hdr_frame_state(request(TRANSPORT_UNKNOWN, true)).content,
            HDR_FRAME_CONTENT_FULL
        );
    }

    #[test]
    fn overlay_state_requires_signal_and_explicit_geometry_contract() {
        let overlay = resolve_hdr_frame_state(request(TRANSPORT_SDR_BASE_HDR_OVERLAY, true));
        assert_eq!(overlay.content, HDR_FRAME_CONTENT_OVERLAY);
        assert_eq!(overlay.overlay_regions.region_count, 4);

        let no_signal = resolve_hdr_frame_state(request(TRANSPORT_SDR_BASE_HDR_OVERLAY, false));
        assert_eq!(no_signal.content, HDR_FRAME_CONTENT_SDR);

        let without_regions = resolve_hdr_frame_state(LumenHdrFrameStateRequest {
            include_overlay_regions: false,
            ..request(TRANSPORT_SDR_BASE_HDR_OVERLAY, true)
        });
        assert_eq!(without_regions.content, HDR_FRAME_CONTENT_SDR);
    }
}
