use crate::{PlatformDynamicRange, PlatformVideoFormat};
use fc3_pixel_entropy::frame;
use sha2::{Digest, Sha256};

pub(super) fn validate_configuration(
    format: PlatformVideoFormat,
    record: &[u8],
) -> Result<(), String> {
    if record.len() > 4096 {
        return Err("pixel configuration exceeds its bound".into());
    }
    let value: serde_json::Value =
        serde_json::from_slice(record).map_err(|_| "invalid pixel configuration")?;
    let color = if format.dynamic_range == PlatformDynamicRange::Hdr10 {
        "bt2020-pq-limited"
    } else {
        "bt709-srgb-full"
    };
    let width = value["width"].as_u64().unwrap_or(0);
    let height = value["height"].as_u64().unwrap_or(0);
    if value["schema"] != "FC3NativePixelContextTransformerV1"
        || value["model_sha256"]
            != "4ef72951e726f179c0b67f74c42f138b1c12ded49be5a0c92dcd9b58b9b865c1"
        || value["entropy"]["frequency_sha256"]
            != "08b9f5faf0ed3e50866bae69fa8790bb7773001a8ad9df5171fa673b5dfbcf2f"
        || value["quantizer"] != "learned-band-integer-table-v1"
        || value["bit_depth"] != 10
        || value["chroma"] != "420"
        || value["color"] != color
        || value["reference"] != "pixel-spectrum-fixed-integer-v3"
        || value["presentation"] != "exact-palette-or-signal-bounded-neural-v2"
        || value["pixel_mask"] != "plane-bounds-deflate-v1"
        || value["entropy"]["format"] != "conditional-pixel-rans4-v1"
        || value["entropy"]["escape"] != "scale-rice-v1"
        || value["entropy"]["nonzero"] != true
        || value["entropy"]["group"] != 16
        || !matches!((width, height), (2816, 1836) | (2420, 1668))
    {
        return Err("unsupported pixel model, entropy or color contract".into());
    }
    Ok(())
}

/// FPCB is local bridge framing only. The wire receives the stripped FCP3
/// packet and a separate reliable configuration when that record changes.
pub(super) fn normalize(
    format: PlatformVideoFormat,
    payload: &[u8],
    keyframe: bool,
    active: Option<&[u8]>,
) -> Result<(Vec<u8>, Option<Vec<u8>>), String> {
    let (packet, discovered) = if payload.starts_with(b"FPCB") {
        let size = payload
            .get(4..8)
            .and_then(|bytes| bytes.try_into().ok())
            .map(u32::from_le_bytes)
            .ok_or("truncated pixel bridge header")? as usize;
        if !keyframe || !(1..=4096).contains(&size) {
            return Err("pixel configuration must accompany an independent bootstrap".into());
        }
        let record = payload
            .get(8..8 + size)
            .ok_or("truncated pixel configuration")?;
        validate_configuration(format, record)?;
        (&payload[8 + size..], Some(record.to_vec()))
    } else {
        (payload, None)
    };
    let configuration = discovered
        .as_deref()
        .or(active)
        .ok_or("missing pixel configuration")?;
    let metadata = frame::parse(packet).ok_or("invalid pixel frame")?;
    let digest = Sha256::digest(configuration);
    let identity = u32::from_le_bytes(digest[..4].try_into().unwrap());
    if metadata.session != identity || keyframe != (metadata.parent == 0) {
        return Err("pixel frame disagrees with the negotiated session".into());
    }
    Ok((packet.to_vec(), discovered))
}
