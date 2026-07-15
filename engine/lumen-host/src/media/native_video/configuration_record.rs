use crate::{PlatformVideoCodec, PlatformVideoFormat};

use super::hevc_sps::parse_and_validate_hevc_sps;
use super::sps::validate_avc_sps;

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
    let sequence_count = usize::from(record[5] & 0x1f);
    if sequence_count == 0 {
        return Err("H.264 decoder configuration has no SPS".to_owned());
    }
    let mut offset = 6_usize;
    for _ in 0..sequence_count {
        let sequence = parameter_set(record, &mut offset, "H.264 SPS")?;
        validate_avc_sps(sequence, format)?;
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
                parse_and_validate_hevc_sps(parameter_set, format)?;
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
