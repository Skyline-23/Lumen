use crate::{PlatformEncodedVideoFrame, PlatformVideoCodec};

const AVC_SEQUENCE_PARAMETER_SET: u8 = 7;
const AVC_PICTURE_PARAMETER_SET: u8 = 8;
const HEVC_VIDEO_PARAMETER_SET: u8 = 32;
const HEVC_SEQUENCE_PARAMETER_SET: u8 = 33;
const HEVC_PICTURE_PARAMETER_SET: u8 = 34;
const AV1_CONFIGURATION_MARKER_AND_VERSION: u8 = 0x81;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NativeVideoConfiguration {
    pub(crate) configuration_id: u32,
    pub(crate) codec: PlatformVideoCodec,
    pub(crate) decoder_configuration_record: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct NormalizedNativeVideoFrame {
    pub(crate) frame: PlatformEncodedVideoFrame,
    pub(crate) configuration_id: u32,
    pub(crate) new_configuration: Option<NativeVideoConfiguration>,
}

pub(crate) struct NativeVideoBitstreamNormalizer {
    codec: PlatformVideoCodec,
    active_configuration: Option<Vec<u8>>,
    active_configuration_id: u32,
}

impl NativeVideoBitstreamNormalizer {
    pub(crate) fn new(codec: PlatformVideoCodec) -> Self {
        Self {
            codec,
            active_configuration: None,
            active_configuration_id: 0,
        }
    }

    pub(crate) fn normalize(
        &mut self,
        frame: PlatformEncodedVideoFrame,
    ) -> Result<NormalizedNativeVideoFrame, String> {
        let (payload, discovered_configuration) = match self.codec {
            PlatformVideoCodec::H264 => normalize_avc(&frame.payload)?,
            PlatformVideoCodec::Hevc => normalize_hevc(&frame.payload)?,
            PlatformVideoCodec::Av1 => {
                validate_av1_obu_stream(&frame.payload)?;
                (frame.payload.clone(), None)
            }
        };
        let candidate_configuration = reconcile_configuration(
            discovered_configuration,
            frame.decoder_configuration_record.as_deref(),
        )?;
        if self.codec == PlatformVideoCodec::Av1 {
            if let Some(configuration) = candidate_configuration.as_ref() {
                if configuration.len() < 4
                    || configuration[0] != AV1_CONFIGURATION_MARKER_AND_VERSION
                {
                    return Err("AV1 decoder configuration record is invalid".to_owned());
                }
            }
        }
        let changed = candidate_configuration
            .as_ref()
            .is_some_and(|candidate| self.active_configuration.as_ref() != Some(candidate));
        if self.active_configuration.is_none() && candidate_configuration.is_none() {
            return Err("native video frame arrived before decoder configuration".to_owned());
        }
        if changed && !frame.key_frame {
            return Err("native video configuration changed without a key frame".to_owned());
        }
        let new_configuration = if changed {
            let configuration_id = self
                .active_configuration_id
                .checked_add(1)
                .ok_or_else(|| "native video configuration id exhausted".to_owned())?;
            let decoder_configuration_record =
                candidate_configuration.expect("changed decoder configuration is present");
            self.active_configuration = Some(decoder_configuration_record.clone());
            self.active_configuration_id = configuration_id;
            Some(NativeVideoConfiguration {
                configuration_id,
                codec: self.codec,
                decoder_configuration_record,
            })
        } else {
            None
        };
        Ok(NormalizedNativeVideoFrame {
            frame: PlatformEncodedVideoFrame {
                payload,
                decoder_configuration_record: None,
                ..frame
            },
            configuration_id: self.active_configuration_id,
            new_configuration,
        })
    }
}

fn reconcile_configuration(
    discovered: Option<Vec<u8>>,
    supplied: Option<&[u8]>,
) -> Result<Option<Vec<u8>>, String> {
    match (discovered, supplied) {
        (Some(discovered), Some(supplied)) if discovered != supplied => {
            Err("native encoder configuration disagrees with its parameter sets".to_owned())
        }
        (Some(discovered), _) => Ok(Some(discovered)),
        (None, Some([])) => Err("native encoder configuration is empty".to_owned()),
        (None, Some(supplied)) => Ok(Some(supplied.to_vec())),
        (None, None) => Ok(None),
    }
}

fn normalize_avc(payload: &[u8]) -> Result<(Vec<u8>, Option<Vec<u8>>), String> {
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
        (false, false) => Some(build_avcc(&sequence, &picture)?),
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

fn normalize_hevc(payload: &[u8]) -> Result<(Vec<u8>, Option<Vec<u8>>), String> {
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
        (false, false, false) => Some(build_hvcc(&video, &sequence, &picture)?),
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
            .map_err(|_| "native video NAL unit exceeds the v2 length field".to_owned())?;
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
    if sequence.len() > 31 || picture.len() > u8::MAX as usize {
        return Err("H.264 decoder configuration has too many parameter sets".to_owned());
    }
    let mut output = vec![
        1,
        first[1],
        first[2],
        first[3],
        0xff,
        0xe0 | sequence.len() as u8,
    ];
    push_parameter_sets(&mut output, sequence)?;
    output.push(picture.len() as u8);
    push_parameter_sets(&mut output, picture)?;
    Ok(output)
}

fn build_hvcc(video: &[&[u8]], sequence: &[&[u8]], picture: &[&[u8]]) -> Result<Vec<u8>, String> {
    let profile = parse_hevc_profile(
        sequence
            .first()
            .copied()
            .ok_or_else(|| "HEVC SPS is missing".to_owned())?,
    )?;
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

#[derive(Clone, Copy)]
struct HevcProfile {
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

fn parse_hevc_profile(sequence: &[u8]) -> Result<HevcProfile, String> {
    if hevc_nal_type(sequence) != Some(HEVC_SEQUENCE_PARAMETER_SET) {
        return Err("HEVC decoder configuration does not start with an SPS".to_owned());
    }
    let rbsp = remove_emulation_prevention(&sequence[2..]);
    let mut bits = BitReader::new(&rbsp);
    bits.read_bits(4)?;
    let max_sub_layers_minus_one = bits.read_bits(3)? as u8;
    let temporal_id_nested = bits.read_bit()?;
    let profile_space = bits.read_bits(2)? as u8;
    let tier = bits.read_bit()?;
    let profile_idc = bits.read_bits(5)? as u8;
    let compatibility_flags = bits.read_bits(32)? as u32;
    let constraint_flags = bits.read_bits(48)?;
    let level_idc = bits.read_bits(8)? as u8;
    let mut profile_present = Vec::with_capacity(max_sub_layers_minus_one as usize);
    let mut level_present = Vec::with_capacity(max_sub_layers_minus_one as usize);
    for _ in 0..max_sub_layers_minus_one {
        profile_present.push(bits.read_bit()?);
        level_present.push(bits.read_bit()?);
    }
    if max_sub_layers_minus_one != 0 {
        for _ in max_sub_layers_minus_one..8 {
            bits.read_bits(2)?;
        }
    }
    for index in 0..max_sub_layers_minus_one as usize {
        if profile_present[index] {
            bits.read_bits(88)?;
        }
        if level_present[index] {
            bits.read_bits(8)?;
        }
    }
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
    })
}

fn validate_av1_obu_stream(payload: &[u8]) -> Result<(), String> {
    let mut offset = 0;
    while offset < payload.len() {
        let header = payload[offset];
        if header & 0x80 != 0 || header & 0x01 != 0 || header & 0x02 == 0 {
            return Err("AV1 access unit is not a low-overhead sized OBU stream".to_owned());
        }
        offset += 1;
        if header & 0x04 != 0 {
            offset = offset
                .checked_add(1)
                .filter(|offset| *offset <= payload.len())
                .ok_or_else(|| "AV1 OBU extension is truncated".to_owned())?;
        }
        let (size, size_bytes) = read_leb128(&payload[offset..])?;
        offset = offset
            .checked_add(size_bytes)
            .and_then(|offset| offset.checked_add(size))
            .filter(|offset| *offset <= payload.len())
            .ok_or_else(|| "AV1 OBU payload is truncated".to_owned())?;
    }
    (offset != 0)
        .then_some(())
        .ok_or_else(|| "AV1 access unit is empty".to_owned())
}

fn read_leb128(bytes: &[u8]) -> Result<(usize, usize), String> {
    let mut value = 0_usize;
    for (index, byte) in bytes.iter().copied().enumerate().take(8) {
        value |= usize::from(byte & 0x7f)
            .checked_shl((index * 7) as u32)
            .ok_or_else(|| "AV1 OBU size overflows".to_owned())?;
        if byte & 0x80 == 0 {
            return Ok((value, index + 1));
        }
    }
    Err("AV1 OBU size is truncated or oversized".to_owned())
}

fn avc_nal_type(unit: &[u8]) -> Option<u8> {
    unit.first().map(|header| header & 0x1f)
}

fn hevc_nal_type(unit: &[u8]) -> Option<u8> {
    (unit.len() >= 2).then(|| (unit[0] >> 1) & 0x3f)
}

fn remove_emulation_prevention(bytes: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(bytes.len());
    let mut zeroes = 0;
    for byte in bytes.iter().copied() {
        if zeroes >= 2 && byte == 3 {
            zeroes = 2;
            continue;
        }
        output.push(byte);
        zeroes = if byte == 0 { zeroes + 1 } else { 0 };
    }
    output
}

struct BitReader<'a> {
    bytes: &'a [u8],
    bit: usize,
}

impl<'a> BitReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, bit: 0 }
    }

    fn read_bit(&mut self) -> Result<bool, String> {
        let byte = self
            .bytes
            .get(self.bit / 8)
            .ok_or_else(|| "HEVC SPS is truncated".to_owned())?;
        let value = byte & (1 << (7 - self.bit % 8)) != 0;
        self.bit += 1;
        Ok(value)
    }

    fn read_bits(&mut self, count: usize) -> Result<u64, String> {
        if count > 64 {
            return Err("HEVC bit field exceeds 64 bits".to_owned());
        }
        let mut value = 0_u64;
        for _ in 0..count {
            value = value << 1 | u64::from(self.read_bit()?);
        }
        Ok(value)
    }

    fn read_unsigned_exp_golomb(&mut self) -> Result<u64, String> {
        let mut leading_zeroes = 0_usize;
        while !self.read_bit()? {
            leading_zeroes += 1;
            if leading_zeroes > 63 {
                return Err("HEVC Exp-Golomb value is oversized".to_owned());
            }
        }
        let suffix = self.read_bits(leading_zeroes)?;
        Ok((1_u64 << leading_zeroes) - 1 + suffix)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn separates_h264_configuration_from_length_prefixed_access_units() {
        let mut normalizer = NativeVideoBitstreamNormalizer::new(PlatformVideoCodec::H264);
        let normalized = normalizer
            .normalize(frame(
                vec![
                    0, 0, 0, 1, 0x67, 100, 0, 40, 0x80, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80, 0, 0, 1,
                    0x65, 0x88,
                ],
                None,
            ))
            .unwrap();
        assert_eq!(normalized.configuration_id, 1);
        assert_eq!(normalized.frame.payload, vec![0, 0, 0, 2, 0x65, 0x88]);
        assert_eq!(
            normalized
                .new_configuration
                .unwrap()
                .decoder_configuration_record,
            vec![
                1, 100, 0, 40, 0xff, 0xe1, 0, 5, 0x67, 100, 0, 40, 0x80, 1, 0, 4, 0x68, 0xce, 0x3c,
                0x80,
            ]
        );
    }

    #[test]
    fn builds_hevc_configuration_and_removes_parameter_sets() {
        let sps = sample_hevc_sps();
        let mut payload = Vec::new();
        for unit in [
            &[0x40, 0x01, 0x0c, 0x01][..],
            &sps,
            &[0x44, 0x01, 0xc0],
            &[0x26, 0x01, 0x80],
        ] {
            payload.extend_from_slice(&[0, 0, 0, 1]);
            payload.extend_from_slice(unit);
        }
        let mut normalizer = NativeVideoBitstreamNormalizer::new(PlatformVideoCodec::Hevc);
        let normalized = normalizer.normalize(frame(payload, None)).unwrap();
        assert_eq!(normalized.configuration_id, 1);
        assert_eq!(normalized.frame.payload, vec![0, 0, 0, 3, 0x26, 0x01, 0x80]);
        let configuration = normalized.new_configuration.unwrap();
        assert_eq!(configuration.decoder_configuration_record[0], 1);
        assert_eq!(configuration.decoder_configuration_record[21] & 3, 3);
        assert_eq!(configuration.decoder_configuration_record[22], 3);
    }

    #[test]
    fn requires_explicit_av1_configuration_and_keeps_sized_obus() {
        let mut normalizer = NativeVideoBitstreamNormalizer::new(PlatformVideoCodec::Av1);
        let configuration = vec![AV1_CONFIGURATION_MARKER_AND_VERSION, 0, 0, 0];
        let normalized = normalizer
            .normalize(frame(vec![0x0a, 1, 0], Some(configuration.clone())))
            .unwrap();
        assert_eq!(normalized.frame.payload, vec![0x0a, 1, 0]);
        assert_eq!(
            normalized
                .new_configuration
                .unwrap()
                .decoder_configuration_record,
            configuration
        );
        assert!(normalizer.normalize(frame(vec![0x08, 0], None)).is_err());
    }

    fn frame(
        payload: Vec<u8>,
        decoder_configuration_record: Option<Vec<u8>>,
    ) -> PlatformEncodedVideoFrame {
        PlatformEncodedVideoFrame {
            payload,
            decoder_configuration_record,
            presentation_time_90khz: 90_000,
            key_frame: true,
        }
    }

    fn sample_hevc_sps() -> Vec<u8> {
        let mut bits = BitWriter::default();
        bits.write(4, 0);
        bits.write(3, 0);
        bits.write(1, 1);
        bits.write(2, 0);
        bits.write(1, 0);
        bits.write(5, 1);
        bits.write(32, 0x6000_0000);
        bits.write(48, 0);
        bits.write(8, 120);
        bits.unsigned_exp_golomb(0);
        bits.unsigned_exp_golomb(1);
        bits.unsigned_exp_golomb(1_920);
        bits.unsigned_exp_golomb(1_080);
        bits.write(1, 0);
        bits.unsigned_exp_golomb(0);
        bits.unsigned_exp_golomb(0);
        bits.write(1, 1);
        bits.finish_with_header(&[0x42, 0x01])
    }

    #[derive(Default)]
    struct BitWriter {
        bytes: Vec<u8>,
        bit: usize,
    }

    impl BitWriter {
        fn write(&mut self, count: usize, value: u64) {
            for offset in (0..count).rev() {
                if self.bit % 8 == 0 {
                    self.bytes.push(0);
                }
                if value & (1 << offset) != 0 {
                    let index = self.bytes.len() - 1;
                    self.bytes[index] |= 1 << (7 - self.bit % 8);
                }
                self.bit += 1;
            }
        }

        fn unsigned_exp_golomb(&mut self, value: u64) {
            let code = value + 1;
            let bits = 64 - code.leading_zeros() as usize;
            self.write(bits - 1, 0);
            self.write(bits, code);
        }

        fn finish_with_header(mut self, header: &[u8]) -> Vec<u8> {
            while self.bit % 8 != 0 {
                self.write(1, 0);
            }
            let mut output = header.to_vec();
            output.extend_from_slice(&self.bytes);
            output
        }
    }
}
