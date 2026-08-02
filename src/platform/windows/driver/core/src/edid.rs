use core::cmp::{max, min};

pub const MONITOR_EDID_BYTES: usize = 128;
pub const EDID_STATUS_OK: u32 = 0;
pub const EDID_STATUS_INVALID: u32 = 1;
pub const EDID_STATUS_BUFFER_TOO_SMALL: u32 = 2;
pub const EDID_STATUS_UNREPRESENTABLE: u32 = 3;

const MONITOR_MODE_MIN_LONG_EDGE: u32 = 320;
const MONITOR_MODE_MIN_SHORT_EDGE: u32 = 200;
const MONITOR_MODE_MAX_LONG_EDGE: u32 = 7_680;
const MONITOR_MODE_MAX_SHORT_EDGE: u32 = 4_320;
const MONITOR_MODE_MAX_REFRESH_MILLIHERTZ: u32 = 240_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MonitorEdidBuildError {
    InvalidMode,
    Unrepresentable,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MonitorEdidMode {
    pub width: u32,
    pub height: u32,
    pub refresh_millihertz: u32,
}

pub fn monitor_mode_is_supported(width: u32, height: u32, refresh_millihertz: u32) -> bool {
    let long_edge = max(width, height);
    let short_edge = min(width, height);
    (MONITOR_MODE_MIN_LONG_EDGE..=MONITOR_MODE_MAX_LONG_EDGE).contains(&long_edge)
        && (MONITOR_MODE_MIN_SHORT_EDGE..=MONITOR_MODE_MAX_SHORT_EDGE).contains(&short_edge)
        && (1_000..=MONITOR_MODE_MAX_REFRESH_MILLIHERTZ).contains(&refresh_millihertz)
}

pub fn build_monitor_edid(
    width: u32,
    height: u32,
    refresh_millihertz: u32,
) -> Result<[u8; MONITOR_EDID_BYTES], MonitorEdidBuildError> {
    if !monitor_mode_is_supported(width, height, refresh_millihertz) {
        return Err(MonitorEdidBuildError::InvalidMode);
    }
    // A base EDID detailed timing descriptor has 12-bit active dimensions and
    // a 16-bit pixel clock in 10 kHz units. IddCx also supports monitors with
    // no description, so a valid negotiated mode must not be rejected merely
    // because this legacy descriptor cannot encode it.
    if width > 4095 || height > 4095 {
        return Err(MonitorEdidBuildError::Unrepresentable);
    }

    let horizontal_blanking = max(160, width / 8);
    let vertical_blanking = max(45, height / 24);
    let horizontal_front_porch = max(8, horizontal_blanking / 3);
    let horizontal_sync_width = max(4, horizontal_blanking / 6);
    let vertical_front_porch = 3;
    let vertical_sync_width = 5;
    let horizontal_total = width + horizontal_blanking;
    let vertical_total = height + vertical_blanking;
    let pixel_clock_10khz =
        ((u64::from(horizontal_total) * u64::from(vertical_total) * u64::from(refresh_millihertz))
            + 5_000_000)
            / 10_000_000;
    if pixel_clock_10khz == 0 || pixel_clock_10khz > u64::from(u16::MAX) {
        return Err(MonitorEdidBuildError::Unrepresentable);
    }

    let mut edid = [0u8; MONITOR_EDID_BYTES];
    edid[0..8].copy_from_slice(&[0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]);
    let manufacturer = (5u16 << 10) | (21u16 << 5) | 13u16; // LUM
    edid[8] = (manufacturer >> 8) as u8;
    edid[9] = manufacturer as u8;
    edid[10..12].copy_from_slice(&1u16.to_le_bytes());
    edid[12..16].copy_from_slice(&0x4c_55_4d_4e_u32.to_le_bytes());
    edid[16] = 1;
    edid[17] = 36;
    edid[18] = 1;
    edid[19] = 4;
    edid[20] = 0xa5;
    edid[21] = 53;
    edid[22] = 30;
    edid[23] = 120;
    edid[24] = 0x0a;
    edid[35..38].copy_from_slice(&[0, 0, 0]);
    for byte in &mut edid[38..54] {
        *byte = 0x01;
    }

    let timing = 54;
    let pixel_clock = pixel_clock_10khz as u16;
    edid[timing..timing + 2].copy_from_slice(&pixel_clock.to_le_bytes());
    edid[timing + 2] = width as u8;
    edid[timing + 3] = horizontal_blanking as u8;
    edid[timing + 4] = (((width >> 8) & 0x0f) << 4 | ((horizontal_blanking >> 8) & 0x0f)) as u8;
    edid[timing + 5] = height as u8;
    edid[timing + 6] = vertical_blanking as u8;
    edid[timing + 7] = (((height >> 8) & 0x0f) << 4 | ((vertical_blanking >> 8) & 0x0f)) as u8;
    edid[timing + 8] = horizontal_front_porch as u8;
    edid[timing + 9] = horizontal_sync_width as u8;
    edid[timing + 10] = (vertical_front_porch << 4 | vertical_sync_width) as u8;
    edid[timing + 11] = ((((horizontal_front_porch >> 8) & 0x03) << 6)
        | (((horizontal_sync_width >> 8) & 0x03) << 4)
        | (((vertical_front_porch >> 4) & 0x03) << 2)
        | ((vertical_sync_width >> 4) & 0x03)) as u8;
    edid[timing + 12..timing + 14].copy_from_slice(&530u16.to_le_bytes());
    edid[timing + 14..timing + 16].copy_from_slice(&300u16.to_le_bytes());
    edid[timing + 17] = 0x1a;

    let name = b"LUMEN DISPLAY";
    let name_offset = 72;
    edid[name_offset + 3] = 0xfc;
    edid[name_offset + 4] = 0;
    edid[name_offset + 5..name_offset + 5 + name.len()].copy_from_slice(name);
    edid[name_offset + 17] = 0x0a;

    edid[126] = 0;
    edid[127] = (0u8).wrapping_sub(
        edid[..127]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
    );
    Ok(edid)
}

pub fn parse_monitor_edid(edid: &[u8]) -> Option<MonitorEdidMode> {
    if edid.len() < MONITOR_EDID_BYTES
        || edid[0..8] != [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]
        || edid[..MONITOR_EDID_BYTES]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte))
            != 0
    {
        return None;
    }

    let timing = 54;
    let pixel_clock_10khz = u16::from_le_bytes([edid[timing], edid[timing + 1]]);
    let width = u32::from(edid[timing + 2]) | (u32::from(edid[timing + 4] >> 4) << 8);
    let horizontal_blanking =
        u32::from(edid[timing + 3]) | (u32::from(edid[timing + 4] & 0x0f) << 8);
    let height = u32::from(edid[timing + 5]) | (u32::from(edid[timing + 7] >> 4) << 8);
    let vertical_blanking = u32::from(edid[timing + 6]) | (u32::from(edid[timing + 7] & 0x0f) << 8);
    let horizontal_total = width.checked_add(horizontal_blanking)?;
    let vertical_total = height.checked_add(vertical_blanking)?;
    let total_pixels = u64::from(horizontal_total).checked_mul(u64::from(vertical_total))?;
    if pixel_clock_10khz == 0 || width == 0 || height == 0 || total_pixels == 0 {
        return None;
    }
    let refresh_millihertz = min(
        u64::from(u32::MAX),
        (u64::from(pixel_clock_10khz) * 10_000_000 + total_pixels / 2) / total_pixels,
    ) as u32;
    Some(MonitorEdidMode {
        width,
        height,
        refresh_millihertz,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_edid_round_trips_the_fallback_mode() {
        let edid = build_monitor_edid(1920, 1080, 60_000).unwrap();
        assert_eq!(
            edid.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
            0
        );
        assert_eq!(
            parse_monitor_edid(&edid),
            Some(MonitorEdidMode {
                width: 1920,
                height: 1080,
                refresh_millihertz: 60_000,
            })
        );
    }

    #[test]
    fn invalid_edid_is_rejected() {
        let mut edid = build_monitor_edid(1920, 1080, 60_000).unwrap();
        edid[127] = edid[127].wrapping_add(1);
        assert_eq!(parse_monitor_edid(&edid), None);
    }

    #[test]
    fn native_ipad_120hz_mode_uses_descriptionless_monitor_fallback() {
        assert!(monitor_mode_is_supported(2752, 2064, 120_000));
        assert_eq!(
            build_monitor_edid(2752, 2064, 120_000),
            Err(MonitorEdidBuildError::Unrepresentable)
        );
        assert!(monitor_mode_is_supported(2064, 2752, 120_000));
        assert_eq!(
            build_monitor_edid(2064, 2752, 120_000),
            Err(MonitorEdidBuildError::Unrepresentable)
        );
    }

    #[test]
    fn modes_outside_the_negotiated_host_capability_remain_invalid() {
        assert_eq!(
            build_monitor_edid(7681, 4320, 60_000),
            Err(MonitorEdidBuildError::InvalidMode)
        );
        assert_eq!(
            build_monitor_edid(5000, 5000, 60_000),
            Err(MonitorEdidBuildError::InvalidMode)
        );
        assert_eq!(
            build_monitor_edid(1920, 1080, 0),
            Err(MonitorEdidBuildError::InvalidMode)
        );
    }
}
