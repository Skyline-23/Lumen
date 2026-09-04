use core::cmp::{max, min};

pub const MONITOR_EDID_BYTES: usize = 384;
pub const EDID_STATUS_OK: u32 = 0;
pub const EDID_STATUS_INVALID: u32 = 1;
pub const EDID_STATUS_BUFFER_TOO_SMALL: u32 = 2;

const MONITOR_MODE_MIN_LONG_EDGE: u32 = 320;
const MONITOR_MODE_MIN_SHORT_EDGE: u32 = 200;
const MONITOR_MODE_MAX_LONG_EDGE: u32 = 7_680;
const MONITOR_MODE_MAX_SHORT_EDGE: u32 = 4_320;
const MONITOR_MODE_MAX_REFRESH_MILLIHERTZ: u32 = 240_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MonitorEdidBuildError {
    InvalidMode,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DetailedTiming {
    horizontal_blanking: u32,
    vertical_blanking: u32,
    horizontal_front_porch: u32,
    horizontal_sync_width: u32,
    vertical_front_porch: u32,
    vertical_sync_width: u32,
    pixel_clock_10khz: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MonitorEdidMode {
    pub width: u32,
    pub height: u32,
    pub refresh_millihertz: u32,
    pub hdr_capable: u32,
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
    hdr_capable: bool,
) -> Result<[u8; MONITOR_EDID_BYTES], MonitorEdidBuildError> {
    if !monitor_mode_is_supported(width, height, refresh_millihertz) {
        return Err(MonitorEdidBuildError::InvalidMode);
    }
    let requested_timing = detailed_timing(width, height, refresh_millihertz)
        .ok_or(MonitorEdidBuildError::InvalidMode)?;

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
    edid[20] = if hdr_capable { 0xb5 } else { 0xa5 };
    edid[21] = 53;
    edid[22] = 30;
    edid[23] = 120;
    edid[24] = 0x0a;
    edid[35..38].copy_from_slice(&[0, 0, 0]);
    for byte in &mut edid[38..54] {
        *byte = 0x01;
    }

    // EDID 1.4's base DTD is limited to a 16-bit clock and 12-bit dimensions.
    // Keep a conservative same-panel timing there when possible, while the
    // preferred DisplayID Type-I timing below carries the exact high-clock
    // native mode used by the IddCx callbacks.
    let (base_width, base_height, base_timing) = base_detailed_timing(width, height);
    write_base_detailed_timing(&mut edid, 54, base_width, base_height, base_timing);
    let timing = 54;
    let horizontal_size_mm = 530u16;
    let vertical_size_mm = 300u16;
    edid[timing + 12] = horizontal_size_mm as u8;
    edid[timing + 13] = vertical_size_mm as u8;
    edid[timing + 14] = (((horizontal_size_mm >> 8) << 4) | (vertical_size_mm >> 8)) as u8;

    let name = b"LUMEN DISPLAY";
    let name_offset = 72;
    edid[name_offset + 3] = 0xfc;
    edid[name_offset + 4] = 0;
    edid[name_offset + 5..name_offset + 5 + name.len()].copy_from_slice(name);

    edid[126] = 2;
    edid[127] = (0u8).wrapping_sub(
        edid[..127]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
    );

    let extension = 128;
    edid[extension] = 0x02; // CTA-861 extension
    edid[extension + 1] = 0x03;
    let mut data_offset = extension + 4;
    if hdr_capable {
        // Extended HDR Static Metadata block: traditional SDR + ST 2084 PQ,
        // static metadata type 1, and a transport-class 10,000-nit ceiling.
        edid[data_offset..data_offset + 7].copy_from_slice(&[0xe6, 0x06, 0x05, 0x01, 245, 245, 0]);
        data_offset += 7;
        // Extended Colorimetry block: BT.2020 RGB container.
        edid[data_offset..data_offset + 4].copy_from_slice(&[0xe3, 0x05, 0x80, 0]);
        data_offset += 4;
    }
    edid[extension + 2] = u8::try_from(data_offset - extension).unwrap_or(4);
    edid[extension + 127] = (0u8).wrapping_sub(
        edid[extension..extension + 127]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
    );

    write_displayid_extension(&mut edid, 256, width, height, requested_timing);
    Ok(edid)
}

fn detailed_timing(width: u32, height: u32, refresh_millihertz: u32) -> Option<DetailedTiming> {
    let horizontal_blanking = max(160, width / 8);
    let vertical_blanking = max(45, height / 24);
    let horizontal_front_porch = max(8, horizontal_blanking / 3);
    let horizontal_sync_width = max(4, horizontal_blanking / 6);
    let vertical_front_porch = 3;
    let vertical_sync_width = 5;
    let horizontal_total = width.checked_add(horizontal_blanking)?;
    let vertical_total = height.checked_add(vertical_blanking)?;
    let pixel_clock_10khz = (u64::from(horizontal_total)
        .checked_mul(u64::from(vertical_total))?
        .checked_mul(u64::from(refresh_millihertz))?
        + 5_000_000)
        / 10_000_000;
    let pixel_clock_10khz = u32::try_from(pixel_clock_10khz).ok()?;
    (pixel_clock_10khz != 0).then_some(DetailedTiming {
        horizontal_blanking,
        vertical_blanking,
        horizontal_front_porch,
        horizontal_sync_width,
        vertical_front_porch,
        vertical_sync_width,
        pixel_clock_10khz,
    })
}

fn base_detailed_timing(width: u32, height: u32) -> (u32, u32, DetailedTiming) {
    if width <= 4095 && height <= 4095 {
        let timing =
            detailed_timing(width, height, 60_000).expect("validated mode has a base timing");
        if timing.pixel_clock_10khz <= u32::from(u16::MAX)
            && timing.horizontal_blanking <= 4095
            && timing.vertical_blanking <= 4095
        {
            return (width, height, timing);
        }
    }
    (
        1920,
        1080,
        detailed_timing(1920, 1080, 60_000).expect("fallback timing is representable"),
    )
}

fn write_base_detailed_timing(
    edid: &mut [u8; MONITOR_EDID_BYTES],
    offset: usize,
    width: u32,
    height: u32,
    timing: DetailedTiming,
) {
    let pixel_clock = timing.pixel_clock_10khz as u16;
    edid[offset..offset + 2].copy_from_slice(&pixel_clock.to_le_bytes());
    edid[offset + 2] = width as u8;
    edid[offset + 3] = timing.horizontal_blanking as u8;
    edid[offset + 4] =
        (((width >> 8) & 0x0f) << 4 | ((timing.horizontal_blanking >> 8) & 0x0f)) as u8;
    edid[offset + 5] = height as u8;
    edid[offset + 6] = timing.vertical_blanking as u8;
    edid[offset + 7] =
        (((height >> 8) & 0x0f) << 4 | ((timing.vertical_blanking >> 8) & 0x0f)) as u8;
    edid[offset + 8] = timing.horizontal_front_porch as u8;
    edid[offset + 9] = timing.horizontal_sync_width as u8;
    edid[offset + 10] = (timing.vertical_front_porch << 4 | timing.vertical_sync_width) as u8;
    edid[offset + 11] = ((((timing.horizontal_front_porch >> 8) & 0x03) << 6)
        | (((timing.horizontal_sync_width >> 8) & 0x03) << 4)
        | (((timing.vertical_front_porch >> 4) & 0x03) << 2)
        | ((timing.vertical_sync_width >> 4) & 0x03)) as u8;
    edid[offset + 17] = 0x1a;
}

fn write_displayid_extension(
    edid: &mut [u8; MONITOR_EDID_BYTES],
    extension: usize,
    width: u32,
    height: u32,
    timing: DetailedTiming,
) {
    const DISPLAYID_PAYLOAD_BYTES: u8 = 23;
    edid[extension] = 0x70;
    edid[extension + 1] = 0x13;
    edid[extension + 2] = DISPLAYID_PAYLOAD_BYTES;
    edid[extension + 3] = 3; // monitor product type
    edid[extension + 4] = 0;
    edid[extension + 5..extension + 8].copy_from_slice(&[0x03, 0x01, 20]);

    let descriptor = extension + 8;
    let pixel_clock = timing.pixel_clock_10khz - 1;
    edid[descriptor] = pixel_clock as u8;
    edid[descriptor + 1] = (pixel_clock >> 8) as u8;
    edid[descriptor + 2] = (pixel_clock >> 16) as u8;
    edid[descriptor + 3] = 0x80 | displayid_aspect_ratio(width, height); // preferred, progressive
    for (offset, value) in [
        (4, width - 1),
        (6, timing.horizontal_blanking - 1),
        (8, timing.horizontal_front_porch - 1),
        (10, timing.horizontal_sync_width - 1),
        (12, height - 1),
        (14, timing.vertical_blanking - 1),
        (16, timing.vertical_front_porch - 1),
        (18, timing.vertical_sync_width - 1),
    ] {
        edid[descriptor + offset..descriptor + offset + 2]
            .copy_from_slice(&(value as u16).to_le_bytes());
    }

    let displayid_checksum = extension + 1 + 4 + usize::from(DISPLAYID_PAYLOAD_BYTES);
    edid[displayid_checksum] = (0u8).wrapping_sub(
        edid[extension + 1..displayid_checksum]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
    );
    edid[extension + 127] = (0u8).wrapping_sub(
        edid[extension..extension + 127]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
    );
}

fn displayid_aspect_ratio(width: u32, height: u32) -> u8 {
    let divisor = greatest_common_divisor(width, height);
    match (width / divisor, height / divisor) {
        (1, 1) => 0,
        (5, 4) => 1,
        (4, 3) => 2,
        (15, 9) => 3,
        (16, 9) => 4,
        (16, 10) => 5,
        (64, 27) => 6,
        (256, 135) => 7,
        _ => 8,
    }
}

fn greatest_common_divisor(mut left: u32, mut right: u32) -> u32 {
    while right != 0 {
        (left, right) = (right, left % right);
    }
    left
}

pub fn parse_monitor_edid(edid: &[u8]) -> Option<MonitorEdidMode> {
    if edid.len() < MONITOR_EDID_BYTES
        || edid[0..8] != [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]
        || edid[..128]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte))
            != 0
        || edid[126] != 2
        || edid[..MONITOR_EDID_BYTES]
            .chunks_exact(128)
            .any(|block| block.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)) != 0)
    {
        return None;
    }

    let (width, height, refresh_millihertz) = parse_displayid_preferred_timing(edid)?;

    Some(MonitorEdidMode {
        width,
        height,
        refresh_millihertz,
        hdr_capable: u32::from(edid_supports_pq_hdr(edid)),
    })
}

fn parse_displayid_preferred_timing(edid: &[u8]) -> Option<(u32, u32, u32)> {
    let extension_count = usize::from(edid[126]);
    let extension = (1..=extension_count)
        .map(|index| index * 128)
        .find(|offset| edid.get(*offset) == Some(&0x70))?;
    if edid.get(extension + 1) != Some(&0x13) {
        return None;
    }
    let payload_bytes = usize::from(edid[extension + 2]);
    let payload_end = extension.checked_add(5)?.checked_add(payload_bytes)?;
    let checksum = payload_end;
    if checksum >= extension + 127
        || edid[extension + 1..=checksum]
            .iter()
            .fold(0u8, |sum, byte| sum.wrapping_add(*byte))
            != 0
    {
        return None;
    }

    let mut block = extension + 5;
    while block + 3 <= payload_end {
        let block_bytes = usize::from(edid[block + 2]);
        let next = block.checked_add(3)?.checked_add(block_bytes)?;
        if next > payload_end {
            return None;
        }
        if edid[block] == 0x03 && block_bytes >= 20 {
            let descriptor = block + 3;
            let pixel_clock_10khz = u32::from(edid[descriptor])
                | (u32::from(edid[descriptor + 1]) << 8)
                | (u32::from(edid[descriptor + 2]) << 16);
            let pixel_clock_10khz = pixel_clock_10khz.checked_add(1)?;
            let read_dimension = |offset: usize| {
                u32::from(u16::from_le_bytes([
                    edid[descriptor + offset],
                    edid[descriptor + offset + 1],
                ])) + 1
            };
            let width = read_dimension(4);
            let horizontal_blanking = read_dimension(6);
            let height = read_dimension(12);
            let vertical_blanking = read_dimension(14);
            let total_pixels = u64::from(width.checked_add(horizontal_blanking)?)
                .checked_mul(u64::from(height.checked_add(vertical_blanking)?))?;
            let refresh_millihertz = min(
                u64::from(u32::MAX),
                (u64::from(pixel_clock_10khz) * 10_000_000 + total_pixels / 2) / total_pixels,
            ) as u32;
            return Some((width, height, refresh_millihertz));
        }
        block = next;
    }
    None
}

fn edid_supports_pq_hdr(edid: &[u8]) -> bool {
    let extension_count = usize::from(edid[126]);
    let Some(extension) = (1..=extension_count)
        .map(|index| index * 128)
        .find(|offset| edid.get(*offset) == Some(&0x02))
    else {
        return false;
    };
    let end = usize::from(edid[extension + 2]).clamp(4, 127) + extension;
    let mut offset = extension + 4;
    while offset < end {
        let header = edid[offset];
        let length = usize::from(header & 0x1f);
        let next = offset.saturating_add(1).saturating_add(length);
        if next > end || next > edid.len() {
            return false;
        }
        if header >> 5 == 0x07
            && length >= 3
            && edid[offset + 1] == 0x06
            && edid[offset + 2] & (1 << 2) != 0
        {
            return true;
        }
        offset = next;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_edid_round_trips_the_fallback_mode() {
        let edid = build_monitor_edid(1920, 1080, 60_000, false).unwrap();
        assert_eq!(
            edid[..128]
                .iter()
                .fold(0u8, |sum, byte| sum.wrapping_add(*byte)),
            0
        );
        assert!(edid
            .chunks_exact(128)
            .all(|block| block.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte)) == 0));
        assert_eq!(edid[126], 2);
        assert_eq!(edid[128], 0x02);
        assert_eq!(edid[256], 0x70);
        assert_eq!(
            parse_monitor_edid(&edid),
            Some(MonitorEdidMode {
                width: 1920,
                height: 1080,
                refresh_millihertz: 60_000,
                hdr_capable: 0,
            })
        );
    }

    #[test]
    fn generated_hdr_edid_advertises_pq_bt2020_and_ten_bits() {
        let edid = build_monitor_edid(2420, 1668, 120_000, true).unwrap();
        assert_eq!(edid[20], 0xb5);
        assert!(edid_supports_pq_hdr(&edid));
        assert_eq!(parse_monitor_edid(&edid).unwrap().hdr_capable, 1);
    }

    #[test]
    fn invalid_edid_is_rejected() {
        let mut edid = build_monitor_edid(1920, 1080, 60_000, false).unwrap();
        edid[127] = edid[127].wrapping_add(1);
        assert_eq!(parse_monitor_edid(&edid), None);
    }

    #[test]
    fn native_ipad_120hz_mode_round_trips_through_displayid() {
        assert!(monitor_mode_is_supported(2752, 2064, 120_000));
        assert_eq!(
            parse_monitor_edid(&build_monitor_edid(2752, 2064, 120_000, true).unwrap()),
            Some(MonitorEdidMode {
                width: 2752,
                height: 2064,
                refresh_millihertz: 120_000,
                hdr_capable: 1,
            })
        );
        assert!(monitor_mode_is_supported(2064, 2752, 120_000));
        assert_eq!(
            parse_monitor_edid(&build_monitor_edid(2064, 2752, 120_000, true).unwrap()),
            Some(MonitorEdidMode {
                width: 2064,
                height: 2752,
                refresh_millihertz: 120_000,
                hdr_capable: 1,
            })
        );
    }

    #[test]
    fn displayid_keeps_modes_wider_than_the_base_edid_dtd() {
        assert_eq!(
            parse_monitor_edid(&build_monitor_edid(5120, 2880, 120_000, true).unwrap()),
            Some(MonitorEdidMode {
                width: 5120,
                height: 2880,
                refresh_millihertz: 120_000,
                hdr_capable: 1,
            })
        );
    }

    #[test]
    fn modes_outside_the_negotiated_host_capability_remain_invalid() {
        assert_eq!(
            build_monitor_edid(7681, 4320, 60_000, false),
            Err(MonitorEdidBuildError::InvalidMode)
        );
        assert_eq!(
            build_monitor_edid(5000, 5000, 60_000, false),
            Err(MonitorEdidBuildError::InvalidMode)
        );
        assert_eq!(
            build_monitor_edid(1920, 1080, 0, false),
            Err(MonitorEdidBuildError::InvalidMode)
        );
    }
}
