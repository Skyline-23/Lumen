use crate::{
    PlatformChromaSubsampling, PlatformColorRange, PlatformDynamicRange, PlatformVideoCodec,
    PlatformVideoFormat, PlatformVideoProfile,
};

use super::bit_reader::{remove_emulation_prevention, BitReader};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct VideoSignal {
    pub(super) color_range: PlatformColorRange,
    pub(super) dynamic_range: PlatformDynamicRange,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ParsedVideoFormat {
    profile: PlatformVideoProfile,
    chroma_subsampling: PlatformChromaSubsampling,
    bit_depth: u8,
    signal: VideoSignal,
}

pub(super) fn validate_avc_sps(
    sequence: &[u8],
    expected: PlatformVideoFormat,
) -> Result<(), String> {
    if expected.codec != PlatformVideoCodec::H264 {
        return Err("H.264 SPS was supplied for a different selected codec".to_owned());
    }
    let parsed = parse_avc_sps(sequence)?;
    let matches = parsed.profile == expected.profile
        && parsed.chroma_subsampling == expected.chroma_subsampling
        && parsed.bit_depth == expected.bit_depth
        && parsed.signal.color_range == expected.color_range
        && parsed.signal.dynamic_range == expected.dynamic_range;
    if matches {
        Ok(())
    } else {
        Err("H.264 SPS does not match the selected video format".to_owned())
    }
}

pub(super) fn read_video_signal(
    bits: &mut BitReader<'_>,
    vui_present: bool,
) -> Result<VideoSignal, String> {
    if !vui_present {
        return Err("video SPS is missing VUI color conformance".to_owned());
    }
    if bits.read_bit()? {
        let aspect_ratio_idc = bits.read_bits(8)?;
        if aspect_ratio_idc == 255 {
            bits.read_bits(16)?;
            bits.read_bits(16)?;
        }
    }
    if bits.read_bit()? {
        bits.read_bit()?;
    }
    if !bits.read_bit()? {
        return Err("video SPS is missing video signal conformance".to_owned());
    }
    bits.read_bits(3)?;
    let color_range = if bits.read_bit()? {
        PlatformColorRange::Full
    } else {
        PlatformColorRange::Limited
    };
    if !bits.read_bit()? {
        return Err("video SPS is missing transfer characteristics".to_owned());
    }
    bits.read_bits(8)?;
    let transfer_characteristics = u8::try_from(bits.read_bits(8)?)
        .map_err(|_| "video SPS transfer characteristics are invalid".to_owned())?;
    bits.read_bits(8)?;
    let dynamic_range = match transfer_characteristics {
        1 | 6 | 13 | 14 | 15 => PlatformDynamicRange::Sdr,
        16 => PlatformDynamicRange::Hdr10,
        _ => return Err("video SPS transfer characteristics are unsupported".to_owned()),
    };
    Ok(VideoSignal {
        color_range,
        dynamic_range,
    })
}

fn parse_avc_sps(sequence: &[u8]) -> Result<ParsedVideoFormat, String> {
    if sequence.first().map(|header| header & 0x1f) != Some(7) {
        return Err("H.264 decoder configuration does not start with an SPS".to_owned());
    }
    let rbsp = remove_emulation_prevention(&sequence[1..]);
    let mut bits = BitReader::new(&rbsp);
    let profile_idc =
        u8::try_from(bits.read_bits(8)?).map_err(|_| "H.264 profile is invalid".to_owned())?;
    bits.read_bits(8)?;
    bits.read_bits(8)?;
    bits.read_unsigned_exp_golomb()?;
    let (chroma_format_idc, bit_depth) = if matches!(
        profile_idc,
        44 | 83 | 86 | 100 | 110 | 118 | 122 | 128 | 134 | 135 | 138 | 139 | 244
    ) {
        let chroma_format_idc = u8::try_from(bits.read_unsigned_exp_golomb()?)
            .map_err(|_| "H.264 chroma format is invalid".to_owned())?;
        if chroma_format_idc == 3 {
            bits.read_bit()?;
        }
        let luma_depth = u8::try_from(bits.read_unsigned_exp_golomb()?)
            .ok()
            .and_then(|value| value.checked_add(8))
            .ok_or_else(|| "H.264 luma depth is invalid".to_owned())?;
        let chroma_depth = u8::try_from(bits.read_unsigned_exp_golomb()?)
            .ok()
            .and_then(|value| value.checked_add(8))
            .ok_or_else(|| "H.264 chroma depth is invalid".to_owned())?;
        if luma_depth != chroma_depth {
            return Err("H.264 luma and chroma depths disagree".to_owned());
        }
        bits.read_bit()?;
        if bits.read_bit()? {
            let list_count = if chroma_format_idc == 3 { 12 } else { 8 };
            for index in 0..list_count {
                if bits.read_bit()? {
                    skip_avc_scaling_list(&mut bits, if index < 6 { 16 } else { 64 })?;
                }
            }
        }
        (chroma_format_idc, luma_depth)
    } else {
        (1, 8)
    };
    bits.read_unsigned_exp_golomb()?;
    match bits.read_unsigned_exp_golomb()? {
        0 => {
            bits.read_unsigned_exp_golomb()?;
        }
        1 => {
            bits.read_bit()?;
            bits.read_signed_exp_golomb()?;
            bits.read_signed_exp_golomb()?;
            let cycle = bits.read_unsigned_exp_golomb()?;
            for _ in 0..cycle {
                bits.read_signed_exp_golomb()?;
            }
        }
        2 => {}
        _ => return Err("H.264 picture-order mode is invalid".to_owned()),
    }
    bits.read_unsigned_exp_golomb()?;
    bits.read_bit()?;
    bits.read_unsigned_exp_golomb()?;
    bits.read_unsigned_exp_golomb()?;
    if !bits.read_bit()? {
        bits.read_bit()?;
    }
    bits.read_bit()?;
    if bits.read_bit()? {
        for _ in 0..4 {
            bits.read_unsigned_exp_golomb()?;
        }
    }
    let vui_present = bits.read_bit()?;
    let signal = read_video_signal(&mut bits, vui_present)?;
    let profile = match profile_idc {
        77 => PlatformVideoProfile::H264Main,
        100 => PlatformVideoProfile::H264High,
        244 => PlatformVideoProfile::H264High444Predictive,
        _ => return Err("H.264 SPS profile is unsupported".to_owned()),
    };
    let chroma_subsampling = match chroma_format_idc {
        1 => PlatformChromaSubsampling::Yuv420,
        3 => PlatformChromaSubsampling::Yuv444,
        _ => return Err("H.264 SPS chroma format is unsupported".to_owned()),
    };
    Ok(ParsedVideoFormat {
        profile,
        chroma_subsampling,
        bit_depth,
        signal,
    })
}

fn skip_avc_scaling_list(bits: &mut BitReader<'_>, size: usize) -> Result<(), String> {
    let mut last_scale = 8_i64;
    let mut next_scale = 8_i64;
    for _ in 0..size {
        if next_scale != 0 {
            next_scale = (last_scale + bits.read_signed_exp_golomb()? + 256) % 256;
        }
        if next_scale != 0 {
            last_scale = next_scale;
        }
    }
    Ok(())
}
