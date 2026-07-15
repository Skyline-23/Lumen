use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use crate::LumenEngineStatus;

const MAX_REGIONS: usize = 6;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenRectI32 {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenHdrOverlayRegionRequest {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenHdrOverlayRegionPlan {
    pub region_count: u32,
    pub regions: [LumenRectI32; MAX_REGIONS],
}

pub fn resolve_hdr_overlay_regions(
    request: LumenHdrOverlayRegionRequest,
) -> LumenHdrOverlayRegionPlan {
    let origin_x = request.x.max(0);
    let origin_y = request.y.max(0);
    let width = request.width.max(0);
    let height = request.height.max(0);
    if width == 0 || height == 0 {
        return LumenHdrOverlayRegionPlan::default();
    }

    let mut columns = ((width + 959) / 960).clamp(1, 4);
    let mut rows = ((height + 539) / 540).clamp(1, 4);
    let area = i64::from(width) * i64::from(height);
    let max_tiles = if area <= 1280_i64 * 720 {
        2
    } else if area <= 1920_i64 * 1080 {
        4
    } else {
        6
    };
    let aspect_ratio = f64::from(width) / f64::from(height);
    if aspect_ratio >= 2.0 {
        rows = 1;
    } else if aspect_ratio >= 1.6 {
        rows = rows.min(2);
    } else if aspect_ratio <= 0.5 {
        columns = 1;
    } else if aspect_ratio <= 0.625 {
        columns = columns.min(2);
    }
    while columns * rows > max_tiles {
        if columns >= rows && columns > 1 {
            columns -= 1;
        } else if rows > 1 {
            rows -= 1;
        } else {
            break;
        }
    }

    let mut plan = LumenHdrOverlayRegionPlan::default();
    if columns == 1 || rows == 1 {
        plan.region_count = 1;
        plan.regions[0] = LumenRectI32 {
            x: origin_x,
            y: origin_y,
            width,
            height,
        };
        return plan;
    }

    let tile_width = ((width + columns - 1) / columns).max(1);
    let tile_height = ((height + rows - 1) / rows).max(1);
    for row in 0..rows {
        for column in 0..columns {
            let region = LumenRectI32 {
                x: origin_x + column * tile_width,
                y: origin_y + row * tile_height,
                width: tile_width.min(width - column * tile_width),
                height: tile_height.min(height - row * tile_height),
            };
            if region.width > 0 && region.height > 0 {
                let index = plan.region_count as usize;
                if index < MAX_REGIONS {
                    plan.regions[index] = region;
                    plan.region_count += 1;
                }
            }
        }
    }
    plan
}

#[no_mangle]
pub extern "C" fn lumen_engine_resolve_hdr_overlay_regions(
    request: LumenHdrOverlayRegionRequest,
    plan_out: *mut LumenHdrOverlayRegionPlan,
) -> LumenEngineStatus {
    let Some(mut plan_out) = NonNull::new(plan_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| resolve_hdr_overlay_regions(request))) {
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

    #[test]
    fn rust_tiles_medium_and_large_hdr_regions() {
        let medium = resolve_hdr_overlay_regions(LumenHdrOverlayRegionRequest {
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
        });
        assert_eq!(medium.region_count, 4);
        assert_eq!(
            medium.regions[0],
            LumenRectI32 {
                x: 0,
                y: 0,
                width: 960,
                height: 540
            }
        );
        assert_eq!(
            medium.regions[3],
            LumenRectI32 {
                x: 960,
                y: 540,
                width: 960,
                height: 540
            }
        );

        let large = resolve_hdr_overlay_regions(LumenHdrOverlayRegionRequest {
            x: 8,
            y: 16,
            width: 3840,
            height: 2160,
        });
        assert_eq!(large.region_count, 6);
    }

    #[test]
    fn rust_clamps_invalid_geometry_and_keeps_small_regions_whole() {
        let empty = resolve_hdr_overlay_regions(LumenHdrOverlayRegionRequest {
            x: -1,
            y: -1,
            width: -100,
            height: 720,
        });
        assert_eq!(empty.region_count, 0);

        let small = resolve_hdr_overlay_regions(LumenHdrOverlayRegionRequest {
            x: -4,
            y: 12,
            width: 1280,
            height: 720,
        });
        assert_eq!(small.region_count, 1);
        assert_eq!(
            small.regions[0],
            LumenRectI32 {
                x: 0,
                y: 12,
                width: 1280,
                height: 720
            }
        );
    }
}
