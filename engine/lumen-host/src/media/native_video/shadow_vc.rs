use crate::{PlatformChromaSubsampling, PlatformColorRange, PlatformDynamicRange,
    PlatformVideoCodec, PlatformVideoFormat, PlatformVideoProfile};

const MODEL: &str = "fc3-spatial-base16-v1";
const CHECKPOINT: &str = "f8db4b2ec5c1a63ab4d9bb1c1fda16901769e8afe31793fdd4adcfa81a7f0ce2";
const REGIONAL_MODEL: &str = "fc4-regional-predictor8-v1";
const REGIONAL_CHECKPOINT: &str = "24efd0c26f332a15c92c015cf68cf8d4254a11b1b9ba798f66b0667ee8e51b86";

fn dimensions(width: u64, height: u64) -> bool {
    (2..=3840).contains(&width) && (2..=2160).contains(&height)
        && width % 2 == 0 && height % 2 == 0
}

pub(super) fn validate(format: PlatformVideoFormat, bytes: &[u8]) -> Result<(), String> {
    if bytes.len() > 1024 || format.codec != PlatformVideoCodec::ShadowVc
        || !matches!(format.profile, PlatformVideoProfile::ShadowVcSpatialBase16 | PlatformVideoProfile::ShadowVcRegionalPredictor8)
        || format.chroma_subsampling != PlatformChromaSubsampling::Yuv420
        || format.bit_depth != 10 || format.dynamic_range != PlatformDynamicRange::Sdr
        || format.color_range != PlatformColorRange::Limited {
        return Err("unsupported ShadowVC format".into());
    }
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| "invalid ShadowVC configuration")?;
    let (version, model, checkpoint) = if format.profile == PlatformVideoProfile::ShadowVcRegionalPredictor8 {
        (2, REGIONAL_MODEL, REGIONAL_CHECKPOINT)
    } else { (1, MODEL, CHECKPOINT) };
    if value["version"] != version || value["model"] != model || value["checkpoint"] != checkpoint
        || !dimensions(value["width"].as_u64().unwrap_or(0), value["height"].as_u64().unwrap_or(0)) {
        return Err("ShadowVC model or geometry mismatch".into());
    }
    Ok(())
}

/// Native producer already supplies a complete CRC-protected SCV1 frame.
/// Preserve it byte-for-byte; its source ID is independent of the QUIC object ID.
pub(super) fn configuration_from_frame(bytes: &[u8]) -> Result<Vec<u8>, String> {
    if bytes.starts_with(b"SCV2") { return regional_configuration_from_frame(bytes); }
    if !(24..=8*1024*1024).contains(&bytes.len()) || &bytes[..4] != b"SCV1" {
        return Err("invalid SCV1 frame".into());
    }
    let read = |offset| u32::from_le_bytes(bytes[offset..offset+4].try_into().unwrap());
    let width = read(8);
    let height = read(12);
    if read(4) == 0 || !dimensions(u64::from(width),u64::from(height)) {
        return Err("invalid SCV1 geometry or identity".into());
    }
    let indexes: Vec<u32> = (0..6).filter(|i| (i%3)*1280 < width && (i/3)*1088 < height).collect();
    if read(16) as usize != indexes.len() { return Err("invalid SCV1 tile count".into()); }
    let mut cursor = 20;
    for index in indexes {
        if cursor+12 > bytes.len()-4 || read(cursor) != index { return Err("invalid SCV1 tile order".into()); }
        let z = read(cursor+4) as usize; let base = read(cursor+8) as usize;
        cursor += 12;
        if z < 4 || base < 4 || z > bytes.len()-cursor-4 || base > bytes.len()-cursor-z-4 {
            return Err("invalid SCV1 stream lengths".into());
        }
        cursor += z+base;
    }
    if cursor != bytes.len()-4 { return Err("trailing SCV1 data".into()); }
    serde_json::to_vec(&serde_json::json!({"version":1,"model":MODEL,"checkpoint":CHECKPOINT,
        "width":width,"height":height})).map_err(|error| error.to_string())
}

fn regional_configuration_from_frame(bytes: &[u8]) -> Result<Vec<u8>, String> {
    if !(36..=32*1024*1024).contains(&bytes.len()) { return Err("invalid SCV2 frame length".into()); }
    let read = |offset| u32::from_le_bytes(bytes[offset..offset+4].try_into().unwrap());
    let id = read(4); let width = read(8); let height = read(12); let parent = read(16);
    if id == 0 || parent >= id || !dimensions(u64::from(width), u64::from(height)) {
        return Err("invalid SCV2 geometry or reference".into());
    }
    let mut cursor = 32;
    for index in 0..3 {
        let length = read(20+index*4) as usize;
        if length <= 28 || length > bytes.len()-cursor-4 { return Err("invalid SCV2 plane length".into()); }
        let scale = if index == 0 { 1 } else { 2 };
        if &bytes[cursor..cursor+4] != b"F4R2" || read(cursor+4) != id || read(cursor+8) != parent
            || read(cursor+12) != width/scale || read(cursor+16) != height/scale {
            return Err("inconsistent SCV2 plane identity".into());
        }
        cursor += length;
    }
    if cursor != bytes.len()-4 { return Err("trailing SCV2 data".into()); }
    serde_json::to_vec(&serde_json::json!({"version":2,"model":REGIONAL_MODEL,"checkpoint":REGIONAL_CHECKPOINT,
        "width":width,"height":height})).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn regional_envelope_binds_profile_geometry_and_all_plane_references() {
        let mut bytes = b"SCV2".to_vec();
        for word in [7_u32, 258, 130, 6, 29, 29, 29] { bytes.extend(word.to_le_bytes()); }
        for scale in [1, 2, 2] {
            bytes.extend(b"F4R2");
            for word in [7_u32, 6, 258/scale, 130/scale, 0, 0] { bytes.extend(word.to_le_bytes()); }
            bytes.push(0); // Envelope parser does not perform entropy decoding.
        }
        bytes.extend(0_u32.to_le_bytes());
        let record = configuration_from_frame(&bytes).unwrap();
        let format = PlatformVideoFormat { codec: PlatformVideoCodec::ShadowVc,
            profile: PlatformVideoProfile::ShadowVcRegionalPredictor8,
            chroma_subsampling: PlatformChromaSubsampling::Yuv420, bit_depth: 10,
            dynamic_range: PlatformDynamicRange::Sdr, color_range: PlatformColorRange::Limited };
        validate(format, &record).unwrap();
        assert!(validate(PlatformVideoFormat { profile: PlatformVideoProfile::ShadowVcSpatialBase16, ..format }, &record).is_err());
        for length in 0..bytes.len() { assert!(configuration_from_frame(&bytes[..length]).is_err()); }
        let mut bad = bytes.clone(); bad[40] = 5;
        assert!(configuration_from_frame(&bad).is_err());
        bad = bytes.clone(); bad[16] = 7;
        assert!(configuration_from_frame(&bad).is_err());
        bytes.push(0); assert!(configuration_from_frame(&bytes).is_err());
    }
    #[test]
    fn bounded_independent_frame_preserves_geometry_and_identity_contract() {
        let mut bytes = b"SCV1".to_vec();
        for word in [7_u32, 2, 2, 1, 0, 4, 4, 0, 0, 0] { bytes.extend(word.to_le_bytes()); }
        let record = configuration_from_frame(&bytes).unwrap();
        let format = PlatformVideoFormat { codec: PlatformVideoCodec::ShadowVc,
            profile: PlatformVideoProfile::ShadowVcSpatialBase16,
            chroma_subsampling: PlatformChromaSubsampling::Yuv420, bit_depth: 10,
            dynamic_range: PlatformDynamicRange::Sdr, color_range: PlatformColorRange::Limited };
        validate(format, &record).unwrap();
        assert!(validate(PlatformVideoFormat { dynamic_range: PlatformDynamicRange::Hdr10, ..format }, &record).is_err());
        assert!(validate(format, br#"{"version":1,"model":"unknown"}"#).is_err());
        for length in 0..bytes.len() { assert!(configuration_from_frame(&bytes[..length]).is_err()); }
        let mut bad = bytes.clone(); bad[8] = 3;
        assert!(configuration_from_frame(&bad).is_err());
        bad = bytes.clone(); bad[20] = 1;
        assert!(configuration_from_frame(&bad).is_err());
        bytes.push(0); assert!(configuration_from_frame(&bytes).is_err());
    }
}
