use crate::{
    PlatformChromaSubsampling, PlatformVideoCodec, PlatformVideoFormat, PlatformVideoProfile,
};

use super::hevc_sps::{parse_and_validate_hevc_sps, HevcProfile};
use super::sps::validate_avc_sps;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct HevcConfigurationHeader {
    profile_space: u8,
    tier: bool,
    profile_idc: u8,
    compatibility_flags: u32,
    constraint_flags: u64,
    level_idc: u8,
    chroma_format_idc: u8,
    bit_depth_luma_minus8: u8,
    bit_depth_chroma_minus8: u8,
    temporal_layers: u8,
    temporal_id_nested: bool,
}

pub(super) fn validate_decoder_configuration(
    format: PlatformVideoFormat,
    record: &[u8],
) -> Result<(), String> {
    match format.codec {
        PlatformVideoCodec::H264 => validate_avcc(format, record),
        PlatformVideoCodec::Hevc => validate_hvcc(format, record),
        PlatformVideoCodec::Av1 => Ok(()),
    }
}

fn validate_avcc(format: PlatformVideoFormat, record: &[u8]) -> Result<(), String> {
    if record.len() < 7 || record[0] != 1 {
        return Err("H.264 decoder configuration record is invalid".to_owned());
    }
    if record[4] != 0xff || record[5] & 0xe0 != 0xe0 {
        return Err("H.264 decoder configuration header is invalid".to_owned());
    }
    let sequence_count = usize::from(record[5] & 0x1f);
    if sequence_count == 0 {
        return Err("H.264 decoder configuration has no SPS".to_owned());
    }
    let mut offset = 6_usize;
    for _ in 0..sequence_count {
        let sequence = parameter_set(record, &mut offset, "H.264 SPS")?;
        validate_avc_sps(sequence, format)?;
        validate_avcc_header(format, record, sequence)?;
    }
    let picture_count = usize::from(
        *record
            .get(offset)
            .ok_or_else(|| "H.264 decoder configuration has no PPS count".to_owned())?,
    );
    offset += 1;
    if picture_count == 0 {
        return Err("H.264 decoder configuration has no PPS".to_owned());
    }
    for _ in 0..picture_count {
        parameter_set(record, &mut offset, "H.264 PPS")?;
    }
    Ok(())
}

fn validate_hvcc(format: PlatformVideoFormat, record: &[u8]) -> Result<(), String> {
    if record.len() < 23 || record[0] != 1 {
        return Err("HEVC decoder configuration record is invalid".to_owned());
    }
    let header = HevcConfigurationHeader::parse(record)?;
    if !header.matches_selected(format) {
        return Err(
            "HEVC decoder configuration header does not match the selected video format".to_owned(),
        );
    }
    let array_count = usize::from(record[22]);
    let mut offset = 23_usize;
    let mut sequence_count = 0_usize;
    for _ in 0..array_count {
        let nal_type = record
            .get(offset)
            .map(|header| header & 0x3f)
            .ok_or_else(|| "HEVC decoder configuration array is truncated".to_owned())?;
        offset += 1;
        let count = read_u16(record, &mut offset, "HEVC parameter-set count")?;
        for _ in 0..count {
            let parameter_set = parameter_set(record, &mut offset, "HEVC parameter set")?;
            if nal_type == 33 {
                let profile = parse_and_validate_hevc_sps(parameter_set, format)?;
                if !header.matches_sps(profile) {
                    return Err(
                        "HEVC decoder configuration header disagrees with its SPS".to_owned()
                    );
                }
                sequence_count += 1;
            }
        }
    }
    if sequence_count == 0 {
        Err("HEVC decoder configuration has no SPS".to_owned())
    } else {
        Ok(())
    }
}

fn validate_avcc_header(
    format: PlatformVideoFormat,
    record: &[u8],
    sequence: &[u8],
) -> Result<(), String> {
    let expected_profile = match format.profile {
        PlatformVideoProfile::H264Main => 77,
        PlatformVideoProfile::H264High => 100,
        PlatformVideoProfile::H264High444Predictive => 244,
        PlatformVideoProfile::HevcMain
        | PlatformVideoProfile::HevcMain10
        | PlatformVideoProfile::HevcMain444
        | PlatformVideoProfile::HevcMain44410
        | PlatformVideoProfile::Av1Main => {
            return Err(
                "H.264 decoder configuration header does not match the selected video format"
                    .to_owned(),
            );
        }
    };
    let sps_header = sequence
        .get(1..4)
        .ok_or_else(|| "H.264 SPS header is truncated".to_owned())?;
    if record[1] == expected_profile && record.get(1..4) == Some(sps_header) {
        Ok(())
    } else {
        Err("H.264 decoder configuration header disagrees with its SPS".to_owned())
    }
}

impl HevcConfigurationHeader {
    fn parse(record: &[u8]) -> Result<Self, String> {
        if record[13] & 0xf0 != 0xf0
            || record[15] & 0xfc != 0xfc
            || record[16] & 0xfc != 0xfc
            || record[17] & 0xf8 != 0xf8
            || record[18] & 0xf8 != 0xf8
            || record[21] & 3 != 3
        {
            return Err("HEVC decoder configuration header is invalid".to_owned());
        }
        Ok(Self {
            profile_space: record[1] >> 6,
            tier: record[1] & 0x20 != 0,
            profile_idc: record[1] & 0x1f,
            compatibility_flags: u32::from_be_bytes([record[2], record[3], record[4], record[5]]),
            constraint_flags: u64::from_be_bytes([
                0, 0, record[6], record[7], record[8], record[9], record[10], record[11],
            ]),
            level_idc: record[12],
            chroma_format_idc: record[16] & 3,
            bit_depth_luma_minus8: record[17] & 7,
            bit_depth_chroma_minus8: record[18] & 7,
            temporal_layers: record[21] >> 3 & 7,
            temporal_id_nested: record[21] & 4 != 0,
        })
    }

    fn matches_selected(self, format: PlatformVideoFormat) -> bool {
        let profile_idc = match format.profile {
            PlatformVideoProfile::HevcMain => 1,
            PlatformVideoProfile::HevcMain10 => 2,
            PlatformVideoProfile::HevcMain444 | PlatformVideoProfile::HevcMain44410 => 4,
            PlatformVideoProfile::H264Main
            | PlatformVideoProfile::H264High
            | PlatformVideoProfile::H264High444Predictive
            | PlatformVideoProfile::Av1Main => return false,
        };
        let chroma_format_idc = match format.chroma_subsampling {
            PlatformChromaSubsampling::Yuv420 => 1,
            PlatformChromaSubsampling::Yuv444 => 3,
        };
        format.bit_depth.checked_sub(8).is_some_and(|bit_depth| {
            self.profile_idc == profile_idc
                && self.chroma_format_idc == chroma_format_idc
                && self.bit_depth_luma_minus8 == bit_depth
                && self.bit_depth_chroma_minus8 == bit_depth
        })
    }

    fn matches_sps(self, profile: HevcProfile) -> bool {
        self.profile_space == profile.profile_space
            && self.tier == profile.tier
            && self.profile_idc == profile.profile_idc
            && self.compatibility_flags == profile.compatibility_flags
            && self.constraint_flags == profile.constraint_flags
            && self.level_idc == profile.level_idc
            && self.chroma_format_idc == profile.chroma_format_idc
            && self.bit_depth_luma_minus8 == profile.bit_depth_luma_minus8
            && self.bit_depth_chroma_minus8 == profile.bit_depth_chroma_minus8
            && self.temporal_layers == profile.temporal_layers
            && self.temporal_id_nested == profile.temporal_id_nested
    }
}

fn parameter_set<'a>(record: &'a [u8], offset: &mut usize, kind: &str) -> Result<&'a [u8], String> {
    let length = read_u16(record, offset, kind)?;
    let end = offset
        .checked_add(length)
        .filter(|end| *end <= record.len())
        .ok_or_else(|| format!("{kind} is truncated"))?;
    let parameter_set = &record[*offset..end];
    *offset = end;
    Ok(parameter_set)
}

fn read_u16(record: &[u8], offset: &mut usize, kind: &str) -> Result<usize, String> {
    let end = offset
        .checked_add(2)
        .filter(|end| *end <= record.len())
        .ok_or_else(|| format!("{kind} is truncated"))?;
    let bytes = [record[*offset], record[*offset + 1]];
    *offset = end;
    Ok(usize::from(u16::from_be_bytes(bytes)))
}
