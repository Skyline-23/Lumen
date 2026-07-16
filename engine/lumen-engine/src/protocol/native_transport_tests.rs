use super::{
    decode_native_media_datagram, decode_native_video_access_unit, encode_native_media_header,
    encode_native_media_header_with_fec_block, encode_native_video_access_unit_descriptor,
    NativeFecBlockExtension, NativeMediaHeader, NativeMediaKind, NativeVideoAccessUnitDescriptor,
    LUMEN_STREAMING_EXPORTER_LABEL, LUMEN_STREAMING_PROTOCOL_ALPN, NATIVE_AUDIO_STREAM_ID,
    NATIVE_INPUT_MOTION_STREAM_ID, NATIVE_MEDIA_FLAG_FEC_BLOCK, NATIVE_MEDIA_FLAG_KEYFRAME,
    NATIVE_MEDIA_FLAG_PARITY_SHARD, NATIVE_MEDIA_HEADER_BYTES, NATIVE_MEDIA_MAGIC,
    NATIVE_MEDIA_VERSION, NATIVE_VIDEO_STREAM_ID,
};

fn video_header() -> NativeMediaHeader {
    NativeMediaHeader {
        kind: NativeMediaKind::Video,
        flags: NATIVE_MEDIA_FLAG_KEYFRAME,
        session_epoch: 0x0102_0304,
        path_id: 7,
        policy_revision: 3,
        stream_id: 11,
        shard_index: 1,
        data_shards: 4,
        parity_shards: 2,
        packet_sequence: 0x1011_1213,
        frame_id: 0x2021_2223,
        frame_bytes: 0x0001_0002,
        capture_timestamp_us: 0x3031_3233,
    }
}

#[test]
fn native_media_header_uses_the_exact_network_order_layout() {
    let encoded = encode_native_media_header(video_header()).unwrap();

    assert_eq!(encoded.len(), NATIVE_MEDIA_HEADER_BYTES);
    assert_eq!(
        encoded,
        [
            0x4c, 0x33, 0x03, 0x01, 0x00, 0x01, 0x00, 0x28, 0x01, 0x02, 0x03, 0x04, 0x00, 0x07,
            0x00, 0x03, 0x00, 0x0b, 0x00, 0x01, 0x00, 0x04, 0x00, 0x02, 0x10, 0x11, 0x12, 0x13,
            0x20, 0x21, 0x22, 0x23, 0x00, 0x01, 0x00, 0x02, 0x30, 0x31, 0x32, 0x33,
        ]
    );
}

#[test]
fn video_access_unit_descriptor_uses_network_order_and_exact_length() {
    let descriptor = NativeVideoAccessUnitDescriptor {
        configuration_id: 0x0102_0304,
        access_unit_bytes: 3,
    };
    let mut payload = encode_native_video_access_unit_descriptor(descriptor)
        .unwrap()
        .to_vec();
    payload.extend_from_slice(&[0xaa, 0xbb, 0xcc]);

    assert_eq!(&payload[..8], &[1, 2, 3, 4, 0, 0, 0, 3]);
    assert_eq!(
        decode_native_video_access_unit(&payload).unwrap(),
        (descriptor, &[0xaa, 0xbb, 0xcc][..])
    );
    payload.push(0xdd);
    assert!(decode_native_video_access_unit(&payload).is_err());
}

#[test]
fn native_media_decoder_returns_header_and_extension_aware_payload_offset() {
    let mut datagram = encode_native_media_header(video_header()).unwrap().to_vec();
    datagram[6..8].copy_from_slice(&44_u16.to_be_bytes());
    datagram.extend_from_slice(&[0xaa, 0xbb, 0xcc, 0xdd]);
    datagram.extend_from_slice(&[1, 2, 3]);

    let decoded = decode_native_media_datagram(&datagram).unwrap();

    assert_eq!(decoded.header, video_header());
    assert_eq!(decoded.payload_offset, 44);
    assert_eq!(decoded.fec_block, None);
    assert_eq!(&datagram[decoded.payload_offset..], &[1, 2, 3]);
}

#[test]
fn fec_block_extension_uses_the_exact_network_order_layout() {
    let mut header = video_header();
    header.flags |= NATIVE_MEDIA_FLAG_FEC_BLOCK;
    header.frame_bytes = 8_192;
    let encoded = encode_native_media_header_with_fec_block(
        header,
        NativeFecBlockExtension {
            block_index: 1,
            block_count: 3,
            frame_payload_offset: 4_064,
        },
    )
    .unwrap();

    assert_eq!(&encoded[6..8], &48_u16.to_be_bytes());
    assert_eq!(
        &encoded[40..48],
        &[0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x0f, 0xe0]
    );
    let decoded = decode_native_media_datagram(&encoded).unwrap();
    assert_eq!(decoded.payload_offset, 48);
    assert_eq!(
        decoded.fec_block,
        Some(NativeFecBlockExtension {
            block_index: 1,
            block_count: 3,
            frame_payload_offset: 4_064,
        })
    );
}

#[test]
fn native_media_decoder_rejects_invalid_identity_and_reserved_flags() {
    let mut datagram = encode_native_media_header(video_header()).unwrap();

    datagram[0..2].copy_from_slice(&0_u16.to_be_bytes());
    assert!(decode_native_media_datagram(&datagram).is_err());

    datagram[0..2].copy_from_slice(&NATIVE_MEDIA_MAGIC.to_be_bytes());
    datagram[2] = NATIVE_MEDIA_VERSION + 1;
    assert!(decode_native_media_datagram(&datagram).is_err());

    datagram[2] = NATIVE_MEDIA_VERSION;
    datagram[4..6].copy_from_slice(&0x8000_u16.to_be_bytes());
    assert!(decode_native_media_datagram(&datagram).is_err());
}

#[test]
fn native_media_header_rejects_invalid_shard_and_parity_contracts() {
    let mut invalid = video_header();
    invalid.shard_index = invalid.data_shards + invalid.parity_shards;
    assert!(encode_native_media_header(invalid).is_err());

    invalid = video_header();
    invalid.flags |= NATIVE_MEDIA_FLAG_PARITY_SHARD;
    assert!(encode_native_media_header(invalid).is_err());

    invalid = video_header();
    invalid.shard_index = invalid.data_shards;
    assert!(encode_native_media_header(invalid).is_err());

    invalid.flags |= NATIVE_MEDIA_FLAG_PARITY_SHARD;
    assert!(encode_native_media_header(invalid).is_ok());
}

#[test]
fn native_transport_fixture_matches_the_rust_wire_constants() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/protocol/lumen-native-transport-conformance.json"
    )))
    .unwrap();

    assert_eq!(fixture["version"], NATIVE_MEDIA_VERSION);
    assert_eq!(fixture["mediaDatagramHeader"]["magic"], NATIVE_MEDIA_MAGIC);
    assert_eq!(
        fixture["mediaDatagramHeader"]["bytes"],
        NATIVE_MEDIA_HEADER_BYTES
    );
    assert_eq!(fixture["feedbackIntervalMilliseconds"], 16);
    assert_eq!(fixture["mediaPlane"], "lumen-udp-aead");
    assert_eq!(fixture["logicalStreamIds"]["video"], NATIVE_VIDEO_STREAM_ID);
    assert_eq!(fixture["logicalStreamIds"]["audio"], NATIVE_AUDIO_STREAM_ID);
    assert_eq!(
        fixture["logicalStreamIds"]["inputMotion"],
        NATIVE_INPUT_MOTION_STREAM_ID
    );
    assert_eq!(fixture["discovery"]["defaultQuicPort"], 48_010);
    assert_eq!(fixture["fec"]["fieldPolynomial"], 0x11d);
    assert_eq!(
        fixture["fec"]["generatorMatrix"]["systematicTransform"],
        "G=V*inverse(V[0:dataShards,0:dataShards])"
    );
    assert_eq!(fixture["videoAccessUnit"]["descriptorBytes"], 8);
    assert_eq!(fixture["audioUnit"]["durationFrames"], 240);
    assert_eq!(fixture["input"]["reliableEnvelope"], "ClientInputEnvelope");
    assert_eq!(fixture["input"]["clientEnvelopeFields"]["keyboard"], 10);
    assert_eq!(fixture["input"]["hostEnvelopeFields"]["rumble"], 12);
    assert_eq!(
        fixture["input"]["motionEnvelopeFields"]["gamepadMotion"],
        14
    );
    assert_eq!(fixture["input"]["pointerButtons"]["forward"], 5);
    assert!(fixture.get("mandatoryFallbackMediaPlane").is_none());
    assert_eq!(fixture["requiredVideoContracts"][0], "hevc-main-sdr");
    assert!(fixture["optionalVideoContracts"]
        .as_array()
        .unwrap()
        .contains(&serde_json::Value::String("av1-main-sdr".to_owned())));
    assert!(fixture["forbiddenCompatibilityProtocols"]
        .as_array()
        .unwrap()
        .contains(&serde_json::Value::String("prores".to_owned())));
}

#[test]
fn streaming_protocol_documented_media_identity_matches_the_fixture() {
    // Given: the prose contract, machine-readable fixture, and generated identifiers.
    let contract = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/protocol/lumen-streaming-protocol.md"
    ));
    let fixture: serde_json::Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/protocol/lumen-native-transport-conformance.json"
    )))
    .unwrap();

    // When: the documented table values and transport identifiers are parsed.
    let documented_magic = contract
        .lines()
        .find(|line| line.starts_with("| 0 | 2 | magic `0x"))
        .and_then(|line| line.split("`0x").nth(1))
        .and_then(|value| value.split('`').next())
        .and_then(|value| u16::from_str_radix(value, 16).ok())
        .unwrap();
    let documented_version = contract
        .lines()
        .find(|line| line.starts_with("| 2 | 1 | protocol version `"))
        .and_then(|line| line.split('`').nth(1))
        .and_then(|value| value.parse::<u8>().ok())
        .unwrap();
    let alpn = std::str::from_utf8(LUMEN_STREAMING_PROTOCOL_ALPN).unwrap();
    let exporter = std::str::from_utf8(LUMEN_STREAMING_EXPORTER_LABEL).unwrap();

    // Then: documentation, fixture, generated constants, and generation claims agree exactly.
    assert_eq!(documented_magic, fixture["mediaDatagramHeader"]["magic"]);
    assert_eq!(documented_version, fixture["version"]);
    assert_eq!(documented_magic, NATIVE_MEDIA_MAGIC);
    assert_eq!(documented_version, NATIVE_MEDIA_VERSION);
    assert_eq!(fixture["alpn"], alpn);
    assert!(contract.contains(&format!("`{alpn}`")));
    assert!(contract.contains(&format!("`{exporter}`")));
    assert!(!contract.contains("v2"));
}
