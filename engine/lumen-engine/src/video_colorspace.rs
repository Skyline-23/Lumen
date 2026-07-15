use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::protocol::{TRANSPORT_FRAME_GATED_HDR, TRANSPORT_FULL_FRAME_HDR};
use crate::LumenEngineStatus;

pub const COLORSPACE_REC601: u32 = 0;
pub const COLORSPACE_REC709: u32 = 1;
pub const COLORSPACE_BT2020_SDR: u32 = 2;
pub const COLORSPACE_BT2020_HDR: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenVideoColorspaceRequest {
    pub encoder_csc_mode: i32,
    pub negotiated_transport: u32,
    pub hdr_display: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenVideoColorspacePlan {
    pub colorspace: u32,
    pub full_range: bool,
    pub bit_depth: u32,
    pub recognized_csc: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LumenVideoColorMatrix {
    pub color_vec_y: [f32; 4],
    pub color_vec_u: [f32; 4],
    pub color_vec_v: [f32; 4],
    pub range_y: [f32; 2],
    pub range_uv: [f32; 2],
}

fn resolve_video_colorspace(request: LumenVideoColorspaceRequest) -> LumenVideoColorspacePlan {
    let hdr_stream = matches!(
        request.negotiated_transport,
        TRANSPORT_FULL_FRAME_HDR | TRANSPORT_FRAME_GATED_HDR
    );
    let (colorspace, recognized_csc) = if hdr_stream && request.hdr_display {
        (COLORSPACE_BT2020_HDR, true)
    } else {
        match request.encoder_csc_mode >> 1 {
            0 => (COLORSPACE_REC601, true),
            1 => (COLORSPACE_REC709, true),
            2 => (COLORSPACE_BT2020_SDR, true),
            _ => (COLORSPACE_REC709, false),
        }
    };
    LumenVideoColorspacePlan {
        colorspace,
        full_range: request.encoder_csc_mode & 1 != 0,
        bit_depth: if hdr_stream || colorspace == COLORSPACE_BT2020_SDR {
            10
        } else {
            8
        },
        recognized_csc,
    }
}

fn coefficients(colorspace: u32, legacy: bool) -> (f64, f64) {
    match colorspace {
        COLORSPACE_REC601 => (0.299, 0.114),
        COLORSPACE_REC709 => (0.2126, 0.0722),
        COLORSPACE_BT2020_SDR | COLORSPACE_BT2020_HDR => (0.2627, 0.0593),
        _ if legacy => (0.299, 0.114),
        _ => (0.2126, 0.0722),
    }
}

fn resolve_legacy_color_matrix(colorspace: u32, full_range: bool) -> LumenVideoColorMatrix {
    let (kr, kb) = coefficients(colorspace, true);
    let (kr, kb) = (kr as f32, kb as f32);
    let kg = 1.0 - kr - kb;
    let (range_y, range_uv) = if full_range {
        ([0.0, 255.0], [0.0, 255.0])
    } else {
        ([16.0, 235.0], [16.0, 240.0])
    };
    let shift_y = range_y[0] / 255.0;
    let shift_uv = range_uv[0] / 255.0;
    let scale_y = (range_y[1] - range_y[0]) / 255.0;
    let scale_uv = (range_uv[1] - range_uv[0]) / 255.0;
    LumenVideoColorMatrix {
        color_vec_y: [kr, kg, kb, 0.0],
        color_vec_u: [-(kr * 0.5 / (1.0 - kb)), -(kg * 0.5 / (1.0 - kb)), 0.5, 0.5],
        color_vec_v: [0.5, -(kg * 0.5 / (1.0 - kr)), -(kb * 0.5 / (1.0 - kr)), 0.5],
        range_y: [scale_y, shift_y],
        range_uv: [scale_uv, shift_uv],
    }
}

fn resolve_integer_color_matrix(
    colorspace: u32,
    full_range: bool,
    bit_depth: u32,
) -> LumenVideoColorMatrix {
    let (kr, kb) = coefficients(colorspace, false);
    let kg = 1.0 - kr - kb;
    let bit_depth = if bit_depth == 10 { 10 } else { 8 };
    let (y_mult, mut y_add, uv_mult, mut uv_add) = if full_range {
        let max = ((1_u32 << bit_depth) - 1) as f64;
        (max, 0.0, max, (1_u32 << (bit_depth - 1)) as f64)
    } else {
        let scale = (1_u32 << (bit_depth - 8)) as f64;
        (scale * 219.0, scale * 16.0, scale * 224.0, scale * 128.0)
    };
    y_add += 0.5;
    uv_add += 0.5;
    LumenVideoColorMatrix {
        color_vec_y: [
            (kr * y_mult) as f32,
            (kg * y_mult) as f32,
            (kb * y_mult) as f32,
            y_add as f32,
        ],
        color_vec_u: [
            (-0.5 * kr / (1.0 - kb) * uv_mult) as f32,
            (-0.5 * kg / (1.0 - kb) * uv_mult) as f32,
            (0.5 * uv_mult) as f32,
            uv_add as f32,
        ],
        color_vec_v: [
            (0.5 * uv_mult) as f32,
            (-0.5 * kg / (1.0 - kr) * uv_mult) as f32,
            (-0.5 * kb / (1.0 - kr) * uv_mult) as f32,
            uv_add as f32,
        ],
        range_y: [1.0, 0.0],
        range_uv: [1.0, 0.0],
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_video_colorspace(
    request: LumenVideoColorspaceRequest,
    plan_out: *mut LumenVideoColorspacePlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_video_colorspace(request))) {
        Ok(plan) => {
            unsafe { *plan_out.as_mut() = plan };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_video_color_matrix(
    colorspace: u32,
    full_range: bool,
    bit_depth: u32,
    integer_range: bool,
    matrix_out: *mut LumenVideoColorMatrix,
) -> LumenEngineStatus {
    let Some(mut matrix_out) = NonNull::new(matrix_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        if integer_range {
            resolve_integer_color_matrix(colorspace, full_range, bit_depth)
        } else {
            resolve_legacy_color_matrix(colorspace, full_range)
        }
    })) {
        Ok(matrix) => {
            unsafe { *matrix_out.as_mut() = matrix };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hdr_stream_on_hdr_display_uses_full_bt2020_pq_shape() {
        assert_eq!(
            resolve_video_colorspace(LumenVideoColorspaceRequest {
                encoder_csc_mode: 3,
                negotiated_transport: TRANSPORT_FULL_FRAME_HDR,
                hdr_display: true,
            }),
            LumenVideoColorspacePlan {
                colorspace: COLORSPACE_BT2020_HDR,
                full_range: true,
                bit_depth: 10,
                recognized_csc: true,
            }
        );
    }

    #[test]
    fn sdr_client_modes_preserve_range_and_bt2020_depth() {
        let rec709 = resolve_video_colorspace(LumenVideoColorspaceRequest {
            encoder_csc_mode: 3,
            negotiated_transport: 1,
            hdr_display: false,
        });
        assert_eq!(rec709.colorspace, COLORSPACE_REC709);
        assert!(rec709.full_range);
        assert_eq!(rec709.bit_depth, 8);

        let bt2020 = resolve_video_colorspace(LumenVideoColorspaceRequest {
            encoder_csc_mode: 4,
            negotiated_transport: 1,
            hdr_display: false,
        });
        assert_eq!(bt2020.colorspace, COLORSPACE_BT2020_SDR);
        assert_eq!(bt2020.bit_depth, 10);
    }

    #[test]
    fn unknown_csc_falls_back_to_rec709_without_lowering_hdr_stream_depth() {
        let plan = resolve_video_colorspace(LumenVideoColorspaceRequest {
            encoder_csc_mode: 99 << 1,
            negotiated_transport: TRANSPORT_FRAME_GATED_HDR,
            hdr_display: false,
        });
        assert_eq!(plan.colorspace, COLORSPACE_REC709);
        assert_eq!(plan.bit_depth, 10);
        assert!(!plan.recognized_csc);
    }

    #[test]
    fn legacy_matrix_preserves_range_scaling_and_primaries() {
        let matrix = resolve_legacy_color_matrix(COLORSPACE_REC601, false);
        assert!((matrix.color_vec_y[0] - 0.299).abs() < 0.000_001);
        assert!((matrix.range_y[0] - 219.0 / 255.0).abs() < 0.000_001);
        assert!((matrix.range_uv[0] - 224.0 / 255.0).abs() < 0.000_001);
        assert!((matrix.range_y[1] - 16.0 / 255.0).abs() < 0.000_001);
    }

    #[test]
    fn integer_matrix_scales_limited_ten_bit_output() {
        let matrix = resolve_integer_color_matrix(COLORSPACE_BT2020_HDR, false, 10);
        assert!((matrix.color_vec_y[0] - 0.2627 * 876.0).abs() < 0.001);
        assert_eq!(matrix.color_vec_y[3], 64.5);
        assert_eq!(matrix.color_vec_u[3], 512.5);
        assert_eq!(matrix.range_y, [1.0, 0.0]);
    }
}
