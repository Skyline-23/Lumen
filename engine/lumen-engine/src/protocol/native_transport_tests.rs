use super::{
    decode_native_media_datagram, encode_native_media_header,
    encode_native_media_header_with_fec_block, NativeFecBlockExtension, NativeMediaHeader,
    NativeMediaKind, NativeTransportError, LUMEN_STREAMING_PROTOCOL_ALPN,
    LUMEN_STREAMING_PROTOCOL_PACKAGE, NATIVE_FEC_BLOCK_HEADER_BYTES, NATIVE_MEDIA_FLAG_FEC_BLOCK,
    NATIVE_MEDIA_FLAG_PARITY_SHARD, NATIVE_MEDIA_HEADER_BYTES,
};

fn video_header() -> NativeMediaHeader {
    NativeMediaHeader {
        kind: NativeMediaKind::VideoDelta,
        flags: 0,
        generation_id: 0x0102_0304,
        datagram_sequence: 0x1011_1213,
        object_id: 0x2021_2223,
        object_bytes: 0x0001_0002,
        capture_timestamp_us: 0x3031_3233,
        shard_index: 0,
        data_shards: 1,
        parity_shards: 0,
    }
}

#[test]
fn encodes_the_exact_v4_compact_header_vector() {
    let encoded = encode_native_media_header(video_header()).unwrap();
    assert_eq!(NATIVE_MEDIA_HEADER_BYTES, 28);
    assert_eq!(
        encoded,
        [
            0x01, 0x00, 0x00, 0x1c, 0x01, 0x02, 0x03, 0x04, 0x10, 0x11, 0x12, 0x13, 0x20, 0x21,
            0x22, 0x23, 0x00, 0x01, 0x00, 0x02, 0x30, 0x31, 0x32, 0x33, 0x00, 0x01, 0x00, 0x00,
        ]
    );
    let decoded = decode_native_media_datagram(&encoded).unwrap();
    assert_eq!(decoded.header, video_header());
    assert_eq!(decoded.payload_offset, 28);
    assert_eq!(decoded.fec_block, None);
}

#[test]
fn encodes_the_exact_v4_fec_extension_vector() {
    let mut header = video_header();
    header.flags = NATIVE_MEDIA_FLAG_FEC_BLOCK | NATIVE_MEDIA_FLAG_PARITY_SHARD;
    header.shard_index = 2;
    header.data_shards = 2;
    header.parity_shards = 1;
    header.object_bytes = 8_192;
    let extension = NativeFecBlockExtension {
        block_index: 1,
        block_count: 2,
        object_payload_offset: 4_064,
    };
    let encoded = encode_native_media_header_with_fec_block(header, extension).unwrap();
    assert_eq!(encoded.len(), NATIVE_FEC_BLOCK_HEADER_BYTES);
    assert_eq!(&encoded[0..4], &[1, 0x30, 0, 36]);
    assert_eq!(&encoded[24..28], &[2, 2, 1, 0]);
    assert_eq!(&encoded[28..36], &[1, 2, 0, 0, 0, 0, 0x0f, 0xe0]);
    let decoded = decode_native_media_datagram(&encoded).unwrap();
    assert_eq!(decoded.header, header);
    assert_eq!(decoded.fec_block, Some(extension));
}

#[test]
fn enforces_generation_and_reserved_contracts() {
    let mut audio = video_header();
    audio.kind = NativeMediaKind::Audio;
    assert_eq!(
        encode_native_media_header(audio),
        Err(NativeTransportError::InvalidGeneration)
    );
    audio.generation_id = 0;
    assert!(encode_native_media_header(audio).is_ok());

    let mut encoded = encode_native_media_header(video_header()).unwrap();
    encoded[27] = 1;
    assert_eq!(
        decode_native_media_datagram(&encoded),
        Err(NativeTransportError::ReservedField)
    );
}

#[test]
fn rejects_noncanonical_header_lengths() {
    let mut compact = encode_native_media_header(video_header()).unwrap().to_vec();
    compact[2..4].copy_from_slice(&29_u16.to_be_bytes());
    compact.push(0);
    assert_eq!(
        decode_native_media_datagram(&compact),
        Err(NativeTransportError::InvalidHeaderLength)
    );

    let mut fec_header = video_header();
    fec_header.flags = NATIVE_MEDIA_FLAG_FEC_BLOCK;
    fec_header.data_shards = 2;
    fec_header.object_bytes = 8_192;
    let extension = NativeFecBlockExtension {
        block_index: 0,
        block_count: 2,
        object_payload_offset: 0,
    };
    let mut fec = encode_native_media_header_with_fec_block(fec_header, extension)
        .unwrap()
        .to_vec();
    fec[2..4].copy_from_slice(&35_u16.to_be_bytes());
    assert_eq!(
        decode_native_media_datagram(&fec),
        Err(NativeTransportError::InvalidHeaderLength)
    );
}

#[test]
fn binds_v4_to_alpn_instead_of_per_datagram_magic() {
    assert_eq!(LUMEN_STREAMING_PROTOCOL_PACKAGE, "lumen.streaming.v4");
    assert_eq!(LUMEN_STREAMING_PROTOCOL_ALPN, b"lumen-stream/4");
}
