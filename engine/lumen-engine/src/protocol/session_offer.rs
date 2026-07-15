use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;

use serde::Deserialize;

use super::{
    TRANSPORT_FRAME_GATED_HDR, TRANSPORT_FULL_FRAME_HDR, TRANSPORT_SDR,
    TRANSPORT_SDR_BASE_HDR_OVERLAY,
};
use crate::LumenEngineStatus;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LumenSessionOffer {
    pub version: i32,
    pub hidpi: bool,
    pub scale_explicit: bool,
    pub mode_is_logical: bool,
    pub scale_percent: i32,
    pub gamut: i32,
    pub transfer: i32,
    pub current_edr_headroom: f32,
    pub potential_edr_headroom: f32,
    pub current_peak_luminance_nits: i32,
    pub potential_peak_luminance_nits: i32,
    pub supports_frame_gated_hdr: bool,
    pub supports_hdr_tile_overlay: bool,
    pub supports_per_frame_hdr_metadata: bool,
    pub requested_transport: u32,
}

#[derive(Deserialize)]
struct SessionOfferDocument {
    version: i32,
    #[serde(rename = "displayMode")]
    display_mode: SessionOfferDisplayMode,
    sink: SessionOfferSink,
    capabilities: SessionOfferCapabilities,
    #[serde(rename = "requestedDynamicRange")]
    requested_dynamic_range: String,
}

#[derive(Deserialize)]
struct SessionOfferDisplayMode {
    #[serde(rename = "scalePercent")]
    scale_percent: i32,
    #[serde(rename = "hiDPI")]
    hidpi: bool,
    logical: bool,
}

#[derive(Deserialize)]
struct SessionOfferSink {
    gamut: String,
    transfer: String,
    #[serde(rename = "currentEDRHeadroom")]
    current_edr_headroom: f32,
    #[serde(rename = "potentialEDRHeadroom")]
    potential_edr_headroom: f32,
    #[serde(rename = "currentPeakNits")]
    current_peak_nits: i32,
    #[serde(rename = "potentialPeakNits")]
    potential_peak_nits: i32,
}

#[derive(Deserialize)]
struct SessionOfferCapabilities {
    #[serde(rename = "frameGatedHDR")]
    frame_gated_hdr: bool,
    #[serde(rename = "hdrTileOverlay")]
    hdr_tile_overlay: bool,
    #[serde(rename = "perFrameHDRMetadata")]
    per_frame_hdr_metadata: bool,
}

fn parse_gamut(value: &str) -> Option<i32> {
    match value {
        "srgb" | "rec709" | "709" => Some(1),
        "display-p3" | "display_p3" | "p3" => Some(2),
        "rec2020" | "bt2020" | "2020" => Some(3),
        _ => None,
    }
}

fn parse_transfer(value: &str) -> Option<i32> {
    match value {
        "sdr" | "gamma" => Some(1),
        "pq" | "hdr-pq" | "st2084" | "smpte2084" => Some(2),
        "hlg" | "hdr-hlg" => Some(3),
        _ => None,
    }
}

fn parse_requested_transport(value: &str) -> Option<u32> {
    match value {
        "sdr" => Some(TRANSPORT_SDR),
        "full-frame-hdr" => Some(TRANSPORT_FULL_FRAME_HDR),
        "frame-gated-hdr" => Some(TRANSPORT_FRAME_GATED_HDR),
        "sdr-base-hdr-overlay" => Some(TRANSPORT_SDR_BASE_HDR_OVERLAY),
        _ => None,
    }
}

pub fn parse_session_offer(value: &[u8]) -> Option<LumenSessionOffer> {
    let offer: SessionOfferDocument = serde_json::from_slice(value).ok()?;
    if offer.version != 1
        || !(1..=800).contains(&offer.display_mode.scale_percent)
        || !offer.sink.current_edr_headroom.is_finite()
        || offer.sink.current_edr_headroom < 0.0
        || !offer.sink.potential_edr_headroom.is_finite()
        || offer.sink.potential_edr_headroom < 0.0
        || offer.sink.current_peak_nits < 0
        || offer.sink.potential_peak_nits < 0
    {
        return None;
    }

    Some(LumenSessionOffer {
        version: offer.version,
        hidpi: offer.display_mode.hidpi,
        scale_explicit: true,
        mode_is_logical: offer.display_mode.logical,
        scale_percent: offer.display_mode.scale_percent,
        gamut: parse_gamut(&offer.sink.gamut)?,
        transfer: parse_transfer(&offer.sink.transfer)?,
        current_edr_headroom: offer.sink.current_edr_headroom,
        potential_edr_headroom: offer.sink.potential_edr_headroom,
        current_peak_luminance_nits: offer.sink.current_peak_nits,
        potential_peak_luminance_nits: offer.sink.potential_peak_nits,
        supports_frame_gated_hdr: offer.capabilities.frame_gated_hdr,
        supports_hdr_tile_overlay: offer.capabilities.hdr_tile_overlay,
        supports_per_frame_hdr_metadata: offer.capabilities.per_frame_hdr_metadata,
        requested_transport: parse_requested_transport(&offer.requested_dynamic_range)?,
    })
}

#[no_mangle]
pub extern "C" fn lumen_engine_parse_session_offer(
    value: *const u8,
    value_length: usize,
    offer_out: *mut LumenSessionOffer,
) -> LumenEngineStatus {
    let Some(value) = NonNull::new(value.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut offer_out) = NonNull::new(offer_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(value.as_ptr(), value_length) };
        parse_session_offer(bytes)
    })) {
        Ok(Some(offer)) => {
            unsafe { *offer_out.as_mut() = offer };
            LumenEngineStatus::Ok
        }
        Ok(None) => LumenEngineStatus::InvalidArgument,
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versioned_session_offer_is_parsed_by_rust() {
        let offer = br#"{
            "version": 1,
            "displayMode": {"scalePercent": 200, "hiDPI": true, "logical": true},
            "sink": {
                "gamut": "display-p3",
                "transfer": "pq",
                "currentEDRHeadroom": 2.4,
                "potentialEDRHeadroom": 16.0,
                "currentPeakNits": 240,
                "potentialPeakNits": 1600
            },
            "capabilities": {
                "frameGatedHDR": true,
                "hdrTileOverlay": false,
                "perFrameHDRMetadata": true
            },
            "requestedDynamicRange": "frame-gated-hdr"
        }"#;

        let parsed = parse_session_offer(offer).expect("valid session offer");

        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.scale_percent, 200);
        assert!(parsed.hidpi);
        assert!(parsed.mode_is_logical);
        assert_eq!(parsed.gamut, 2);
        assert_eq!(parsed.transfer, 2);
        assert_eq!(parsed.current_edr_headroom, 2.4);
        assert_eq!(parsed.potential_edr_headroom, 16.0);
        assert_eq!(parsed.current_peak_luminance_nits, 240);
        assert_eq!(parsed.potential_peak_luminance_nits, 1600);
        assert!(parsed.supports_frame_gated_hdr);
        assert!(!parsed.supports_hdr_tile_overlay);
        assert!(parsed.supports_per_frame_hdr_metadata);
        assert_eq!(parsed.requested_transport, TRANSPORT_FRAME_GATED_HDR);
    }

    #[test]
    fn invalid_session_offers_are_rejected_by_rust() {
        for offer in [
            br#"not-json"#.as_slice(),
            br#"{"version":2}"#.as_slice(),
            br#"{"version":1}"#.as_slice(),
            br#"{
                "version":1,
                "displayMode":{"scalePercent":0,"hiDPI":false,"logical":false},
                "sink":{"gamut":"srgb","transfer":"sdr","currentEDRHeadroom":1,"potentialEDRHeadroom":1,"currentPeakNits":100,"potentialPeakNits":100},
                "capabilities":{"frameGatedHDR":false,"hdrTileOverlay":false,"perFrameHDRMetadata":false},
                "requestedDynamicRange":"sdr"
            }"#.as_slice(),
            br#"{
                "version":1,
                "displayMode":{"scalePercent":100,"hiDPI":false,"logical":false},
                "sink":{"gamut":"invalid","transfer":"sdr","currentEDRHeadroom":1,"potentialEDRHeadroom":1,"currentPeakNits":100,"potentialPeakNits":100},
                "capabilities":{"frameGatedHDR":false,"hdrTileOverlay":false,"perFrameHDRMetadata":false},
                "requestedDynamicRange":"sdr"
            }"#.as_slice(),
        ] {
            assert!(parse_session_offer(offer).is_none());
        }
    }
}
