use crate::{PlatformDynamicRange, PlatformVideoFormat};
use fc3_pixel_entropy::{frame, product};
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
    let width = value["width"].as_u64().unwrap_or(0);
    let height = value["height"].as_u64().unwrap_or(0);
    let expected = product::session_configuration(
        width,
        height,
        format.dynamic_range == PlatformDynamicRange::Hdr10,
    )
    .ok_or("unsupported pixel geometry")?;
    let expected: serde_json::Value =
        serde_json::from_str(expected).map_err(|_| "invalid bundled pixel configuration")?;
    if value != expected {
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
