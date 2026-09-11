use super::{NativeVideoBitstreamNormalizer, pixel};
use crate::{
    PlatformChromaSubsampling, PlatformColorRange, PlatformDynamicRange, PlatformEncodedVideoFrame,
    PlatformVideoCodec, PlatformVideoFormat, PlatformVideoProfile,
};
use fc3_pixel_entropy::frame::{self, FrameMetadata, HEADER_BYTES};
use serde_json::json;
use sha2::{Digest, Sha256};

const FORMAT: PlatformVideoFormat = PlatformVideoFormat {
    codec: PlatformVideoCodec::ShadowVc,
    profile: PlatformVideoProfile::ShadowVcPixel10,
    chroma_subsampling: PlatformChromaSubsampling::Yuv420,
    bit_depth: 10,
    dynamic_range: PlatformDynamicRange::Hdr10,
    color_range: PlatformColorRange::Limited,
};

fn configuration() -> Vec<u8> {
    serde_json::to_vec(&json!({
        "schema": "FC3NativePixelContextTransformerV1",
        "width": 2420,
        "height": 1668,
        "model_sha256": "4ef72951e726f179c0b67f74c42f138b1c12ded49be5a0c92dcd9b58b9b865c1",
        "quantizer": "learned-band-integer-table-v1",
        "bit_depth": 10,
        "chroma": "420",
        "color": "bt2020-pq-limited",
        "reference": "pixel-spectrum-fixed-integer-v3",
        "framing": "fcp3-v2",
        "motion_limit": 128,
        "presentation": "exact-palette-or-signal-bounded-neural-v2",
        "pixel_mask": "plane-bounds-deflate-v1",
        "entropy": {
            "format": "conditional-pixel-rans4-v1",
            "escape": "scale-rice-v1",
            "frequency_sha256": "08b9f5faf0ed3e50866bae69fa8790bb7773001a8ad9df5171fa673b5dfbcf2f",
            "nonzero": true,
            "group": 16
        }
    }))
    .unwrap()
}

fn packet(record: &[u8], generation: u32, parent: u32) -> Vec<u8> {
    let digest = Sha256::digest(record);
    let metadata = FrameMetadata {
        session: u32::from_le_bytes(digest[..4].try_into().unwrap()),
        generation,
        parent,
        canonical_crc: 73,
        previous_crc: if parent == 0 { 0 } else { 73 },
        mode: if parent == 0 { 2 } else { 0 },
        coding: if parent == 0 { 2 } else { 0 },
        residual_bytes: u32::from(parent == 0),
        quantizer_tag: 13,
        ..Default::default()
    };
    let mut bytes = vec![0; metadata.packet_bytes().unwrap()];
    frame::write_header(metadata, &mut bytes).unwrap();
    bytes
}

fn bridge(record: &[u8], packet: &[u8]) -> Vec<u8> {
    let mut bytes = b"FPCB".to_vec();
    bytes.extend_from_slice(&(record.len() as u32).to_le_bytes());
    bytes.extend_from_slice(record);
    bytes.extend_from_slice(packet);
    bytes
}

fn captured_frame(payload: Vec<u8>, key_frame: bool) -> PlatformEncodedVideoFrame {
    PlatformEncodedVideoFrame {
        payload,
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame,
        requires_bootstrap_acknowledgement: key_frame,
        repair_keyframe: false,
    }
}

#[test]
fn pixel_configuration_is_reliable_once_and_absent_from_media_packets() {
    let record = configuration();
    let bootstrap = packet(&record, 1, 0);
    let mut normalizer = NativeVideoBitstreamNormalizer::new(FORMAT);
    let first = normalizer
        .normalize(captured_frame(bridge(&record, &bootstrap), true))
        .unwrap();
    assert_eq!(first.frame.payload, bootstrap);
    assert_eq!(first.configuration_id, 1);
    assert_eq!(
        first
            .new_configuration
            .unwrap()
            .decoder_configuration_record,
        record
    );

    let delta = packet(&record, 2, 1);
    let next = normalizer
        .normalize(captured_frame(delta.clone(), false))
        .unwrap();
    assert_eq!(next.frame.payload, delta);
    assert_eq!(next.frame.payload.len(), HEADER_BYTES);
    assert_eq!(next.configuration_id, 1);
    assert!(next.new_configuration.is_none());

    let repair = packet(&record, 3, 0);
    let repaired = normalizer
        .normalize(captured_frame(bridge(&record, &repair), true))
        .unwrap();
    assert_eq!(repaired.frame.payload, repair);
    assert_eq!(repaired.configuration_id, 1);
    assert!(repaired.new_configuration.is_none());
}

#[test]
fn pixel_rejects_corrupt_bootstraps_without_publishing_configuration() {
    let record = configuration();
    let bootstrap = packet(&record, 1, 0);
    let valid = bridge(&record, &bootstrap);
    let mut normalizer = NativeVideoBitstreamNormalizer::new(FORMAT);
    for length in 0..valid.len() {
        assert!(
            normalizer
                .normalize(captured_frame(valid[..length].to_vec(), true))
                .is_err()
        );
    }
    let mut corrupt = valid.clone();
    *corrupt.last_mut().unwrap() ^= 1;
    assert!(normalizer.normalize(captured_frame(corrupt, true)).is_err());
    assert!(
        normalizer
            .normalize(captured_frame(packet(&record, 2, 1), false))
            .is_err()
    );
    let recovered = normalizer.normalize(captured_frame(valid, true)).unwrap();
    assert_eq!(recovered.configuration_id, 1);
    assert!(recovered.new_configuration.is_some());
}

#[test]
fn pixel_rejects_color_model_geometry_and_frame_identity_mismatches() {
    let record = configuration();
    let bootstrap = packet(&record, 1, 0);
    assert!(pixel::normalize(FORMAT, &bridge(&record, &bootstrap), false, None).is_err());
    assert!(pixel::normalize(FORMAT, &packet(&record, 2, 1), true, Some(&record)).is_err());

    for (field, replacement) in [
        ("color", json!("bt709-srgb-full")),
        ("model_sha256", json!("unknown")),
        ("width", json!(1920)),
        ("bit_depth", json!(8)),
        ("framing", json!("fcp3-v1")),
        ("motion_limit", json!(32)),
        ("motion_limit", json!(null)),
    ] {
        let mut value: serde_json::Value = serde_json::from_slice(&record).unwrap();
        value[field] = replacement;
        let unsupported = serde_json::to_vec(&value).unwrap();
        assert!(pixel::validate_configuration(FORMAT, &unsupported).is_err());
    }

    let mut another_session = record.clone();
    another_session.push(b' ');
    assert!(pixel::normalize(FORMAT, &bootstrap, true, Some(&another_session)).is_err());
    assert!(
        pixel::normalize(
            FORMAT,
            &bridge(&record, &packet(&record, 2, 1)),
            false,
            Some(&record)
        )
        .is_err()
    );
}
