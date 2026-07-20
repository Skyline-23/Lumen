use crate::PlatformVideoFormat;

use super::hevc_sps::parse_and_validate_hevc_sps;
use super::sps::validate_avc_sps;

const AVC_SEQUENCE_PARAMETER_SET: u8 = 7;
const AVC_PICTURE_PARAMETER_SET: u8 = 8;
const HEVC_VIDEO_PARAMETER_SET: u8 = 32;
const HEVC_SEQUENCE_PARAMETER_SET: u8 = 33;
const HEVC_PICTURE_PARAMETER_SET: u8 = 34;

pub(super) fn normalize_avc(
    payload: &[u8],
    expected: PlatformVideoFormat,
) -> Result<(Vec<u8>, Option<Vec<u8>>), String> {
    let units = annex_b_units(payload)?;
    let sequence = units
        .iter()
        .copied()
        .filter(|unit| avc_nal_type(unit) == Some(AVC_SEQUENCE_PARAMETER_SET))
        .collect::<Vec<_>>();
    let picture = units
        .iter()
        .copied()
        .filter(|unit| avc_nal_type(unit) == Some(AVC_PICTURE_PARAMETER_SET))
        .collect::<Vec<_>>();
    let configuration = match (sequence.is_empty(), picture.is_empty()) {
        (true, true) => None,
        (false, false) => {
            for parameter_set in &sequence {
                validate_avc_sps(parameter_set, expected)?;
            }
            Some(build_avcc(&sequence, &picture)?)
        }
        _ => return Err("H.264 parameter-set update is incomplete".to_owned()),
    };
    let access_unit = length_prefixed_access_unit(&units, |unit| {
        matches!(
            avc_nal_type(unit),
            Some(AVC_SEQUENCE_PARAMETER_SET) | Some(AVC_PICTURE_PARAMETER_SET)
        )
    })?;
    Ok((access_unit, configuration))
}

pub(super) fn normalize_hevc(
    payload: &[u8],
    expected: PlatformVideoFormat,
) -> Result<(Vec<u8>, Option<Vec<u8>>), String> {
    let units = annex_b_units(payload)?;
    let video = units
        .iter()
        .copied()
        .filter(|unit| hevc_nal_type(unit) == Some(HEVC_VIDEO_PARAMETER_SET))
        .collect::<Vec<_>>();
    let sequence = units
        .iter()
        .copied()
        .filter(|unit| hevc_nal_type(unit) == Some(HEVC_SEQUENCE_PARAMETER_SET))
        .collect::<Vec<_>>();
    let picture = units
        .iter()
        .copied()
        .filter(|unit| hevc_nal_type(unit) == Some(HEVC_PICTURE_PARAMETER_SET))
        .collect::<Vec<_>>();
    let configuration = match (video.is_empty(), sequence.is_empty(), picture.is_empty()) {
        (true, true, true) => None,
        (false, false, false) => Some(build_hvcc(&video, &sequence, &picture, expected)?),
        _ => return Err("HEVC parameter-set update is incomplete".to_owned()),
    };
    let access_unit = length_prefixed_access_unit(&units, |unit| {
        matches!(
            hevc_nal_type(unit),
            Some(HEVC_VIDEO_PARAMETER_SET)
                | Some(HEVC_SEQUENCE_PARAMETER_SET)
                | Some(HEVC_PICTURE_PARAMETER_SET)
        )
    })?;
    Ok((access_unit, configuration))
}

fn annex_b_units(payload: &[u8]) -> Result<Vec<&[u8]>, String> {
    let mut starts = Vec::new();
    let mut index = 0;
    while index + 3 <= payload.len() {
        let start_bytes = if index + 4 <= payload.len() && payload[index..index + 4] == [0, 0, 0, 1]
        {
            4
        } else if payload[index..index + 3] == [0, 0, 1] {
            3
        } else {
            index += 1;
            continue;
        };
        starts.push((index, start_bytes));
        index += start_bytes;
    }
    if starts.is_empty() || payload[..starts[0].0].iter().any(|byte| *byte != 0) {
        return Err("native H.26x access unit is not Annex-B".to_owned());
    }
    let mut units = Vec::with_capacity(starts.len());
    for (position, (start, start_bytes)) in starts.iter().copied().enumerate() {
        let unit_start = start + start_bytes;
        let mut unit_end = starts
            .get(position + 1)
            .map_or(payload.len(), |(next, _)| *next);
        while unit_end > unit_start && payload[unit_end - 1] == 0 {
            unit_end -= 1;
        }
        if unit_start < unit_end {
            units.push(&payload[unit_start..unit_end]);
        }
    }
    (!units.is_empty())
        .then_some(units)
        .ok_or_else(|| "native H.26x access unit contains no NAL units".to_owned())
}

fn length_prefixed_access_unit(
    units: &[&[u8]],
    skip: impl Fn(&[u8]) -> bool,
) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    for unit in units.iter().copied().filter(|unit| !skip(unit)) {
        let length = u32::try_from(unit.len())
            .map_err(|_| "native video NAL unit exceeds the length field".to_owned())?;
        output.extend_from_slice(&length.to_be_bytes());
        output.extend_from_slice(unit);
    }
    (!output.is_empty())
        .then_some(output)
        .ok_or_else(|| "native video access unit contains only parameter sets".to_owned())
}

fn build_avcc(sequence: &[&[u8]], picture: &[&[u8]]) -> Result<Vec<u8>, String> {
    let first = sequence
        .first()
        .filter(|unit| unit.len() >= 4)
        .ok_or_else(|| "H.264 SPS is too short".to_owned())?;
    if sequence.len() > 31 || picture.len() > usize::from(u8::MAX) {
        return Err("H.264 decoder configuration has too many parameter sets".to_owned());
    }
    let sequence_count = u8::try_from(sequence.len())
        .map_err(|_| "H.264 sequence parameter count is invalid".to_owned())?;
    let picture_count = u8::try_from(picture.len())
        .map_err(|_| "H.264 picture parameter count is invalid".to_owned())?;
    let mut output = vec![1, first[1], first[2], first[3], 0xff, 0xe0 | sequence_count];
    push_parameter_sets(&mut output, sequence)?;
    output.push(picture_count);
    push_parameter_sets(&mut output, picture)?;
    Ok(output)
}

fn build_hvcc(
    video: &[&[u8]],
    sequence: &[&[u8]],
    picture: &[&[u8]],
    expected: PlatformVideoFormat,
) -> Result<Vec<u8>, String> {
    let first_sequence = sequence
        .first()
        .copied()
        .ok_or_else(|| "HEVC SPS is missing".to_owned())?;
    let profile = parse_and_validate_hevc_sps(first_sequence, expected)?;
    for parameter_set in &sequence[1..] {
        parse_and_validate_hevc_sps(parameter_set, expected)?;
    }
    let mut output = Vec::new();
    output.push(1);
    output.push(profile.profile_space << 6 | u8::from(profile.tier) << 5 | profile.profile_idc);
    output.extend_from_slice(&profile.compatibility_flags.to_be_bytes());
    output.extend_from_slice(&profile.constraint_flags.to_be_bytes()[2..]);
    output.push(profile.level_idc);
    output.extend_from_slice(&0xf000_u16.to_be_bytes());
    output.push(0xfc);
    output.push(0xfc | profile.chroma_format_idc);
    output.push(0xf8 | profile.bit_depth_luma_minus8);
    output.push(0xf8 | profile.bit_depth_chroma_minus8);
    output.extend_from_slice(&0_u16.to_be_bytes());
    output.push(profile.temporal_layers << 3 | u8::from(profile.temporal_id_nested) << 2 | 3);
    output.push(3);
    push_hevc_array(&mut output, HEVC_VIDEO_PARAMETER_SET, video)?;
    push_hevc_array(&mut output, HEVC_SEQUENCE_PARAMETER_SET, sequence)?;
    push_hevc_array(&mut output, HEVC_PICTURE_PARAMETER_SET, picture)?;
    Ok(output)
}

fn push_parameter_sets(output: &mut Vec<u8>, units: &[&[u8]]) -> Result<(), String> {
    for unit in units {
        let length = u16::try_from(unit.len())
            .map_err(|_| "decoder configuration parameter set is too large".to_owned())?;
        output.extend_from_slice(&length.to_be_bytes());
        output.extend_from_slice(unit);
    }
    Ok(())
}

fn push_hevc_array(output: &mut Vec<u8>, nal_type: u8, units: &[&[u8]]) -> Result<(), String> {
    let count = u16::try_from(units.len())
        .map_err(|_| "HEVC decoder configuration has too many parameter sets".to_owned())?;
    output.push(0x80 | nal_type);
    output.extend_from_slice(&count.to_be_bytes());
    push_parameter_sets(output, units)
}

fn avc_nal_type(unit: &[u8]) -> Option<u8> {
    unit.first().map(|header| header & 0x1f)
}

fn hevc_nal_type(unit: &[u8]) -> Option<u8> {
    (unit.len() >= 2).then(|| (unit[0] >> 1) & 0x3f)
}
