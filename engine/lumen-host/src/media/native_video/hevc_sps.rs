use crate::{
    PlatformChromaSubsampling, PlatformVideoCodec, PlatformVideoFormat, PlatformVideoProfile,
};

use super::bit_reader::{remove_emulation_prevention, BitReader};
use super::sps::{read_video_signal, VideoSignal};

#[derive(Clone, Copy)]
pub(super) struct HevcProfile {
    pub(super) profile_space: u8,
    pub(super) tier: bool,
    pub(super) profile_idc: u8,
    pub(super) compatibility_flags: u32,
    pub(super) constraint_flags: u64,
    pub(super) level_idc: u8,
    pub(super) chroma_format_idc: u8,
    pub(super) bit_depth_luma_minus8: u8,
    pub(super) bit_depth_chroma_minus8: u8,
    pub(super) temporal_layers: u8,
    pub(super) temporal_id_nested: bool,
    signal: VideoSignal,
}

pub(super) fn parse_and_validate_hevc_sps(
    sequence: &[u8],
    expected: PlatformVideoFormat,
) -> Result<HevcProfile, String> {
    if expected.codec != PlatformVideoCodec::Hevc {
        return Err("HEVC SPS was supplied for a different selected codec".to_owned());
    }
    let profile = parse_hevc_sps(sequence)?;
    let selected_profile_matches = match expected.profile {
        PlatformVideoProfile::HevcMain => profile.profile_idc == 1,
        PlatformVideoProfile::HevcMain10 => profile.profile_idc == 2,
        PlatformVideoProfile::HevcMain444 | PlatformVideoProfile::HevcMain44410 => {
            profile.profile_idc == 4
        }
        PlatformVideoProfile::H264Main
        | PlatformVideoProfile::H264High
        | PlatformVideoProfile::H264High444Predictive
        | PlatformVideoProfile::Av1Main => false,
    };
    let selected_chroma = match profile.chroma_format_idc {
        1 => Some(PlatformChromaSubsampling::Yuv420),
        3 => Some(PlatformChromaSubsampling::Yuv444),
        _ => None,
    };
    let luma_depth = profile.bit_depth_luma_minus8.checked_add(8);
    let chroma_depth = profile.bit_depth_chroma_minus8.checked_add(8);
    let matches = selected_profile_matches
        && selected_chroma == Some(expected.chroma_subsampling)
        && luma_depth == Some(expected.bit_depth)
        && chroma_depth == Some(expected.bit_depth)
        && profile.signal.dynamic_range == expected.dynamic_range
        && profile.signal.color_range == expected.color_range;
    if matches {
        Ok(profile)
    } else {
        Err("HEVC SPS does not match the selected video format".to_owned())
    }
}

fn parse_hevc_sps(sequence: &[u8]) -> Result<HevcProfile, String> {
    if sequence.len() < 3 || (sequence[0] >> 1) & 0x3f != 33 {
        return Err("HEVC decoder configuration does not start with an SPS".to_owned());
    }
    let rbsp = remove_emulation_prevention(&sequence[2..]);
    let mut bits = BitReader::new(&rbsp);
    bits.read_bits(4)?;
    let max_sub_layers_minus_one = u8::try_from(bits.read_bits(3)?)
        .map_err(|_| "HEVC sub-layer count is invalid".to_owned())?;
    let temporal_id_nested = bits.read_bit()?;
    let profile_space =
        u8::try_from(bits.read_bits(2)?).map_err(|_| "HEVC profile space is invalid".to_owned())?;
    let tier = bits.read_bit()?;
    let profile_idc =
        u8::try_from(bits.read_bits(5)?).map_err(|_| "HEVC profile is invalid".to_owned())?;
    let compatibility_flags = u32::try_from(bits.read_bits(32)?)
        .map_err(|_| "HEVC compatibility flags are invalid".to_owned())?;
    let constraint_flags = bits.read_bits(48)?;
    let level_idc =
        u8::try_from(bits.read_bits(8)?).map_err(|_| "HEVC level is invalid".to_owned())?;
    skip_sub_layer_profile_tier_levels(&mut bits, max_sub_layers_minus_one)?;
    bits.read_unsigned_exp_golomb()?;
    let chroma_format_idc = u8::try_from(bits.read_unsigned_exp_golomb()?)
        .map_err(|_| "HEVC chroma format exceeds the configuration field".to_owned())?;
    if chroma_format_idc > 3 {
        return Err("HEVC chroma format is invalid".to_owned());
    }
    if chroma_format_idc == 3 {
        bits.read_bit()?;
    }
    bits.read_unsigned_exp_golomb()?;
    bits.read_unsigned_exp_golomb()?;
    if bits.read_bit()? {
        for _ in 0..4 {
            bits.read_unsigned_exp_golomb()?;
        }
    }
    let bit_depth_luma_minus8 = u8::try_from(bits.read_unsigned_exp_golomb()?)
        .map_err(|_| "HEVC luma depth exceeds the configuration field".to_owned())?;
    let bit_depth_chroma_minus8 = u8::try_from(bits.read_unsigned_exp_golomb()?)
        .map_err(|_| "HEVC chroma depth exceeds the configuration field".to_owned())?;
    if bit_depth_luma_minus8 > 7 || bit_depth_chroma_minus8 > 7 {
        return Err("HEVC bit depth is invalid".to_owned());
    }
    let log2_max_pic_order_cnt_lsb_minus4 = bits.read_unsigned_exp_golomb()?;
    let sub_layer_ordering_info_present = bits.read_bit()?;
    let first_layer = if sub_layer_ordering_info_present {
        0
    } else {
        max_sub_layers_minus_one
    };
    for _ in first_layer..=max_sub_layers_minus_one {
        bits.read_unsigned_exp_golomb()?;
        bits.read_unsigned_exp_golomb()?;
        bits.read_unsigned_exp_golomb()?;
    }
    for _ in 0..6 {
        bits.read_unsigned_exp_golomb()?;
    }
    if bits.read_bit()? && bits.read_bit()? {
        skip_scaling_list_data(&mut bits)?;
    }
    bits.read_bit()?;
    bits.read_bit()?;
    if bits.read_bit()? {
        bits.read_bits(4)?;
        bits.read_bits(4)?;
        bits.read_unsigned_exp_golomb()?;
        bits.read_unsigned_exp_golomb()?;
        bits.read_bit()?;
    }
    let short_term_sets = usize::try_from(bits.read_unsigned_exp_golomb()?)
        .map_err(|_| "HEVC short-term reference count is oversized".to_owned())?;
    skip_short_term_reference_sets(&mut bits, short_term_sets)?;
    if bits.read_bit()? {
        let long_term_count = bits.read_unsigned_exp_golomb()?;
        let poc_bits = usize::try_from(log2_max_pic_order_cnt_lsb_minus4 + 4)
            .map_err(|_| "HEVC picture-order field is oversized".to_owned())?;
        for _ in 0..long_term_count {
            bits.read_bits(poc_bits)?;
            bits.read_bit()?;
        }
    }
    bits.read_bit()?;
    bits.read_bit()?;
    let vui_present = bits.read_bit()?;
    let signal = read_video_signal(&mut bits, vui_present)?;
    Ok(HevcProfile {
        profile_space,
        tier,
        profile_idc,
        compatibility_flags,
        constraint_flags,
        level_idc,
        chroma_format_idc,
        bit_depth_luma_minus8,
        bit_depth_chroma_minus8,
        temporal_layers: max_sub_layers_minus_one + 1,
        temporal_id_nested,
        signal,
    })
}

fn skip_sub_layer_profile_tier_levels(bits: &mut BitReader<'_>, count: u8) -> Result<(), String> {
    let mut profile_present = Vec::with_capacity(usize::from(count));
    let mut level_present = Vec::with_capacity(usize::from(count));
    for _ in 0..count {
        profile_present.push(bits.read_bit()?);
        level_present.push(bits.read_bit()?);
    }
    if count != 0 {
        for _ in count..8 {
            bits.read_bits(2)?;
        }
    }
    for index in 0..usize::from(count) {
        if profile_present[index] {
            bits.read_bits(88)?;
        }
        if level_present[index] {
            bits.read_bits(8)?;
        }
    }
    Ok(())
}

fn skip_scaling_list_data(bits: &mut BitReader<'_>) -> Result<(), String> {
    for size_id in 0..4_usize {
        let step = if size_id == 3 { 3 } else { 1 };
        for _ in (0..6).step_by(step) {
            if bits.read_bit()? {
                if size_id > 1 {
                    bits.read_signed_exp_golomb()?;
                }
                let coefficient_count = 64_usize.min(1 << (4 + (size_id << 1)));
                for _ in 0..coefficient_count {
                    bits.read_signed_exp_golomb()?;
                }
            } else {
                bits.read_unsigned_exp_golomb()?;
            }
        }
    }
    Ok(())
}

fn skip_short_term_reference_sets(bits: &mut BitReader<'_>, count: usize) -> Result<(), String> {
    let mut delta_pocs = Vec::with_capacity(count);
    for index in 0..count {
        let predicted = index != 0 && bits.read_bit()?;
        if predicted {
            bits.read_bit()?;
            bits.read_unsigned_exp_golomb()?;
            let reference_count = delta_pocs[index - 1];
            let mut current_count = 0_usize;
            for _ in 0..=reference_count {
                let used = bits.read_bit()?;
                let use_delta = used || bits.read_bit()?;
                current_count += usize::from(use_delta);
            }
            delta_pocs.push(current_count);
        } else {
            let negative = usize::try_from(bits.read_unsigned_exp_golomb()?)
                .map_err(|_| "HEVC negative picture count is oversized".to_owned())?;
            let positive = usize::try_from(bits.read_unsigned_exp_golomb()?)
                .map_err(|_| "HEVC positive picture count is oversized".to_owned())?;
            for _ in 0..negative + positive {
                bits.read_unsigned_exp_golomb()?;
                bits.read_bit()?;
            }
            delta_pocs.push(negative + positive);
        }
    }
    Ok(())
}
