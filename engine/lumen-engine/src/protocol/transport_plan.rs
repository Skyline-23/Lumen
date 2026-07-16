use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use super::{
    normalize_transport, TRANSPORT_FRAME_GATED_HDR, TRANSPORT_FULL_FRAME_HDR, TRANSPORT_SDR,
    TRANSPORT_SDR_BASE_HDR_OVERLAY,
};
use crate::video_codec::resolve_video_codec;
use crate::LumenEngineStatus;

const TRANSFER_PQ: i32 = 2;
const TRANSFER_HLG: i32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenSinkTransportRequest {
    pub requested_transport: u32,
    pub sink_transfer: i32,
    pub supports_frame_gated_hdr: bool,
    pub supports_hdr_tile_overlay: bool,
    pub supports_per_frame_hdr_metadata: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenSinkTransportPlan {
    pub requested_transport: u32,
    pub negotiated_transport: u32,
    pub sink_prefers_hdr: bool,
    pub uses_hdr_stream: bool,
    pub uses_hdr_frame_state: bool,
    pub requires_hdr_display: bool,
}

pub fn resolve_sink_transport(request: LumenSinkTransportRequest) -> LumenSinkTransportPlan {
    let requested_transport = normalize_transport(request.requested_transport);
    let sink_prefers_hdr = matches!(request.sink_transfer, TRANSFER_PQ | TRANSFER_HLG);
    let negotiated_transport = if !sink_prefers_hdr {
        TRANSPORT_SDR
    } else {
        match requested_transport {
            TRANSPORT_FULL_FRAME_HDR => TRANSPORT_FULL_FRAME_HDR,
            TRANSPORT_FRAME_GATED_HDR if request.supports_frame_gated_hdr => {
                TRANSPORT_FRAME_GATED_HDR
            }
            TRANSPORT_SDR_BASE_HDR_OVERLAY
                if request.supports_hdr_tile_overlay && request.supports_per_frame_hdr_metadata =>
            {
                TRANSPORT_SDR_BASE_HDR_OVERLAY
            }
            TRANSPORT_SDR_BASE_HDR_OVERLAY if request.supports_frame_gated_hdr => {
                TRANSPORT_FRAME_GATED_HDR
            }
            _ => TRANSPORT_SDR,
        }
    };
    let uses_hdr_stream = matches!(
        negotiated_transport,
        TRANSPORT_FULL_FRAME_HDR | TRANSPORT_FRAME_GATED_HDR
    );
    let uses_hdr_frame_state =
        uses_hdr_stream || negotiated_transport == TRANSPORT_SDR_BASE_HDR_OVERLAY;

    LumenSinkTransportPlan {
        requested_transport,
        negotiated_transport,
        sink_prefers_hdr,
        uses_hdr_stream,
        uses_hdr_frame_state,
        requires_hdr_display: uses_hdr_frame_state,
    }
}

pub fn resolve_video_transport(
    video_format: i32,
    request: LumenSinkTransportRequest,
) -> Option<LumenSinkTransportPlan> {
    let codec = resolve_video_codec(video_format)?;
    if codec.supports_hdr_transport {
        return Some(resolve_sink_transport(request));
    }
    Some(resolve_sink_transport(LumenSinkTransportRequest {
        requested_transport: TRANSPORT_SDR,
        sink_transfer: TRANSFER_PQ,
        supports_frame_gated_hdr: false,
        supports_hdr_tile_overlay: false,
        supports_per_frame_hdr_metadata: false,
    }))
}

pub fn normalize_capture_frame_rate(requested_frame_rate: i32, millihz: bool) -> i32 {
    if !millihz {
        return if requested_frame_rate > 0 {
            requested_frame_rate
        } else {
            60
        };
    }

    let requested_millihz = if requested_frame_rate > 0 {
        i64::from(requested_frame_rate)
    } else {
        60_000
    };
    let rounded_hz = (requested_millihz + 999) / 1_000;
    (rounded_hz * 1_000).min(i64::from(i32::MAX)) as i32
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_sink_transport(
    request: LumenSinkTransportRequest,
    plan_out: *mut LumenSinkTransportPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_sink_transport(request))) {
        Ok(plan) => {
            unsafe { *plan_out.as_mut() = plan };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_video_transport(
    video_format: i32,
    request: LumenSinkTransportRequest,
    plan_out: *mut LumenSinkTransportPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        resolve_video_transport(video_format, request)
    })) {
        Ok(Some(plan)) => {
            unsafe { *plan_out.as_mut() = plan };
            LumenEngineStatus::Ok
        }
        Ok(None) => LumenEngineStatus::InvalidArgument,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_normalize_capture_frame_rate(
    requested_frame_rate: i32,
    millihz: bool,
    frame_rate_out: *mut i32,
) -> LumenEngineStatus {
    let Some(mut frame_rate_out) = NonNull::new(frame_rate_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        normalize_capture_frame_rate(requested_frame_rate, millihz)
    })) {
        Ok(frame_rate) => {
            unsafe { *frame_rate_out.as_mut() = frame_rate };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{
        TRANSPORT_FRAME_GATED_HDR, TRANSPORT_SDR, TRANSPORT_SDR_BASE_HDR_OVERLAY,
    };

    fn hdr_overlay_request() -> LumenSinkTransportRequest {
        LumenSinkTransportRequest {
            requested_transport: TRANSPORT_SDR_BASE_HDR_OVERLAY,
            sink_transfer: 2,
            supports_frame_gated_hdr: true,
            supports_hdr_tile_overlay: true,
            supports_per_frame_hdr_metadata: true,
        }
    }

    #[test]
    fn rust_resolves_sink_transport_and_traits() {
        let plan = resolve_sink_transport(hdr_overlay_request());

        assert_eq!(plan.requested_transport, TRANSPORT_SDR_BASE_HDR_OVERLAY);
        assert_eq!(plan.negotiated_transport, TRANSPORT_SDR_BASE_HDR_OVERLAY);
        assert!(plan.sink_prefers_hdr);
        assert!(!plan.uses_hdr_stream);
        assert!(plan.uses_hdr_frame_state);
        assert!(plan.requires_hdr_display);
    }

    #[test]
    fn rust_applies_capability_and_transfer_fallbacks() {
        let without_overlay = resolve_sink_transport(LumenSinkTransportRequest {
            supports_hdr_tile_overlay: false,
            ..hdr_overlay_request()
        });
        assert_eq!(
            without_overlay.negotiated_transport,
            TRANSPORT_FRAME_GATED_HDR
        );
        assert!(without_overlay.uses_hdr_stream);

        let sdr_sink = resolve_sink_transport(LumenSinkTransportRequest {
            sink_transfer: 1,
            ..hdr_overlay_request()
        });
        assert_eq!(sdr_sink.negotiated_transport, TRANSPORT_SDR);
        assert!(!sdr_sink.uses_hdr_frame_state);
    }

    #[test]
    fn rust_normalizes_capture_frame_rates_without_quality_reduction() {
        assert_eq!(normalize_capture_frame_rate(0, false), 60);
        assert_eq!(normalize_capture_frame_rate(120, false), 120);
        assert_eq!(normalize_capture_frame_rate(0, true), 60_000);
        assert_eq!(normalize_capture_frame_rate(119_500, true), 120_000);
    }

    #[test]
    fn video_codec_policy_keeps_h264_sdr_and_hdr_capable_codecs_negotiated() {
        assert_eq!(
            resolve_video_transport(0, hdr_overlay_request())
                .unwrap()
                .negotiated_transport,
            TRANSPORT_SDR
        );
        assert_eq!(
            resolve_video_transport(1, hdr_overlay_request())
                .unwrap()
                .negotiated_transport,
            TRANSPORT_SDR_BASE_HDR_OVERLAY
        );
        assert_eq!(
            resolve_video_transport(2, hdr_overlay_request())
                .unwrap()
                .negotiated_transport,
            TRANSPORT_SDR_BASE_HDR_OVERLAY
        );
        assert_eq!(resolve_video_transport(99, hdr_overlay_request()), None);
    }
}
