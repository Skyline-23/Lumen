use crate::LumenEngineStatus;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenDisplayModeRequest {
    pub width: u32,
    pub height: u32,
    pub scale_percent: u32,
    pub dimensions_are_logical: bool,
    pub high_density: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenDisplayGeometry {
    pub stream_width: u32,
    pub stream_height: u32,
    pub logical_width: u32,
    pub logical_height: u32,
    pub backing_width: u32,
    pub backing_height: u32,
}

pub const VIRTUAL_DISPLAY_REASON_SESSION_REQUESTED: u32 = 1 << 0;
pub const VIRTUAL_DISPLAY_REASON_APP_REQUESTED: u32 = 1 << 1;
pub const VIRTUAL_DISPLAY_REASON_HDR_DISPLAY_REQUIRED: u32 = 1 << 2;
pub const VIRTUAL_DISPLAY_REASON_HIDPI_REQUESTED: u32 = 1 << 3;
pub const VIRTUAL_DISPLAY_REASON_LOGICAL_DIMENSIONS: u32 = 1 << 4;
pub const VIRTUAL_DISPLAY_REASON_SCALED_DESKTOP: u32 = 1 << 5;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenVirtualDisplayRequest {
    pub session_requested: bool,
    pub app_requested: bool,
    pub hdr_display_required: bool,
    pub hidpi_requested: bool,
    pub dimensions_are_logical: bool,
    pub scale_percent: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenVirtualDisplayPlan {
    pub required: bool,
    pub reason_flags: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenDisplayGamut {
    Srgb = 0,
    DisplayP3 = 1,
    Rec2020 = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenDisplayTransfer {
    Sdr = 0,
    Pq = 1,
    Hlg = 2,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct LumenDisplayColorRequest {
    pub hdr_enabled: bool,
    pub client_gamut: i32,
    pub client_transfer: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LumenDisplayColorProfile {
    pub gamut: LumenDisplayGamut,
    pub transfer: LumenDisplayTransfer,
    pub red_x: f64,
    pub red_y: f64,
    pub green_x: f64,
    pub green_y: f64,
    pub blue_x: f64,
    pub blue_y: f64,
    pub white_x: f64,
    pub white_y: f64,
    pub hdr_capable: bool,
}

const fn even_dimension(value: u32) -> u32 {
    let bounded = if value < 2 { 2 } else { value };
    bounded & !1
}

fn rounded_ratio(value: u32, numerator: u32, denominator: u32) -> Result<u32, LumenEngineStatus> {
    let denominator = u64::from(denominator);
    let scaled = u64::from(value)
        .checked_mul(u64::from(numerator))
        .and_then(|value| value.checked_add(denominator / 2))
        .ok_or(LumenEngineStatus::InvalidArgument)?;
    u32::try_from(scaled / denominator).map_err(|_| LumenEngineStatus::InvalidArgument)
}

fn backing_dimension(logical_dimension: u32, high_density: bool) -> Result<u32, LumenEngineStatus> {
    logical_dimension
        .checked_mul(if high_density { 2 } else { 1 })
        .ok_or(LumenEngineStatus::InvalidArgument)
}

pub fn resolve_display_geometry(
    request: LumenDisplayModeRequest,
) -> Result<LumenDisplayGeometry, LumenEngineStatus> {
    if request.width == 0 || request.height == 0 || !(1..=800).contains(&request.scale_percent) {
        return Err(LumenEngineStatus::InvalidArgument);
    }

    if request.dimensions_are_logical {
        let stream_width =
            even_dimension(rounded_ratio(request.width, request.scale_percent, 100)?);
        let stream_height =
            even_dimension(rounded_ratio(request.height, request.scale_percent, 100)?);
        return Ok(LumenDisplayGeometry {
            stream_width,
            stream_height,
            logical_width: request.width,
            logical_height: request.height,
            backing_width: backing_dimension(request.width, request.high_density)?,
            backing_height: backing_dimension(request.height, request.high_density)?,
        });
    }

    let stream_width = even_dimension(request.width);
    let stream_height = even_dimension(request.height);
    let logical_width = rounded_ratio(stream_width, 100, request.scale_percent)?;
    let logical_height = rounded_ratio(stream_height, 100, request.scale_percent)?;
    if logical_width == 0 || logical_height == 0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    Ok(LumenDisplayGeometry {
        stream_width,
        stream_height,
        logical_width,
        logical_height,
        backing_width: backing_dimension(logical_width, request.high_density)?,
        backing_height: backing_dimension(logical_height, request.high_density)?,
    })
}

pub fn resolve_virtual_display_plan(
    request: LumenVirtualDisplayRequest,
) -> Result<LumenVirtualDisplayPlan, LumenEngineStatus> {
    if request.scale_percent == 0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }

    let mut reason_flags = 0;
    if request.session_requested {
        reason_flags |= VIRTUAL_DISPLAY_REASON_SESSION_REQUESTED;
    }
    if request.app_requested {
        reason_flags |= VIRTUAL_DISPLAY_REASON_APP_REQUESTED;
    }
    if request.hdr_display_required {
        reason_flags |= VIRTUAL_DISPLAY_REASON_HDR_DISPLAY_REQUIRED;
    }
    if request.hidpi_requested {
        reason_flags |= VIRTUAL_DISPLAY_REASON_HIDPI_REQUESTED;
    }
    if request.dimensions_are_logical {
        reason_flags |= VIRTUAL_DISPLAY_REASON_LOGICAL_DIMENSIONS;
    }
    if request.scale_percent != 100 {
        reason_flags |= VIRTUAL_DISPLAY_REASON_SCALED_DESKTOP;
    }

    Ok(LumenVirtualDisplayPlan {
        required: reason_flags != 0,
        reason_flags,
    })
}

pub fn resolve_display_color(request: LumenDisplayColorRequest) -> LumenDisplayColorProfile {
    let transfer = match request.client_transfer {
        2 => LumenDisplayTransfer::Pq,
        3 => LumenDisplayTransfer::Hlg,
        _ => LumenDisplayTransfer::Sdr,
    };
    let hdr_capable = request.hdr_enabled || transfer != LumenDisplayTransfer::Sdr;
    let gamut = match request.client_gamut {
        1 => LumenDisplayGamut::Srgb,
        2 => LumenDisplayGamut::DisplayP3,
        3 => LumenDisplayGamut::Rec2020,
        _ if hdr_capable => LumenDisplayGamut::DisplayP3,
        _ => LumenDisplayGamut::Srgb,
    };
    let (red_x, red_y, green_x, green_y, blue_x, blue_y) = match gamut {
        LumenDisplayGamut::Srgb => (0.6400, 0.3300, 0.3000, 0.6000, 0.1500, 0.0600),
        LumenDisplayGamut::DisplayP3 => (0.6800, 0.3200, 0.2650, 0.6900, 0.1500, 0.0600),
        LumenDisplayGamut::Rec2020 => (0.7080, 0.2920, 0.1700, 0.7970, 0.1310, 0.0460),
    };
    LumenDisplayColorProfile {
        gamut,
        transfer,
        red_x,
        red_y,
        green_x,
        green_y,
        blue_x,
        blue_y,
        white_x: 0.3127,
        white_y: 0.3290,
        hdr_capable,
    }
}
