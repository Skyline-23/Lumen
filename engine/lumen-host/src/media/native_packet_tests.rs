use lumen_engine::{
    decode_native_media_datagram, NativeMediaKind, NATIVE_MEDIA_FLAG_FEC_BLOCK,
    NATIVE_MEDIA_FLAG_PARITY_SHARD,
};
use reed_solomon_erasure::galois_8::ReedSolomon;

use super::native_packet::{NativeMediaPacketizer, NativeMediaPacketizerConfig};
use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};

fn video_config(maximum_datagram_payload: usize) -> NativeMediaPacketizerConfig {
    NativeMediaPacketizerConfig {
        kind: NativeMediaKind::VideoDelta,
        maximum_datagram_payload,
        generation_id: 7,
    }
}

fn payload(datagram: &[u8]) -> Vec<u8> {
    let decoded = decode_native_media_datagram(datagram).unwrap();
    datagram[decoded.payload_offset..].to_vec()
}

#[test]
fn packetizes_only_video_deltas_with_generation_bound_compact_headers() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(80), 0x1011_1213).unwrap();
    let delta = PlatformEncodedVideoFrame {
        payload: (0..65).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: false,
    };

    let packetized = packetizer.packetize_video_delta(&delta, 9, 0).unwrap();

    assert_eq!(packetized.datagrams.len(), 2);
    assert_eq!(packetized.next_sequence, 0x1011_1215);
    assert!(packetized
        .datagrams
        .iter()
        .all(|datagram| datagram.len() == 80));
    let first = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
    assert_eq!(first.header.kind, NativeMediaKind::VideoDelta);
    assert_eq!(first.header.generation_id, 7);
    assert_eq!(first.header.datagram_sequence, 0x1011_1213);
    assert_eq!(first.header.object_id, 9);
    assert_eq!(first.header.object_bytes, delta.payload.len() as u32);
    assert_eq!(first.header.capture_timestamp_us, 1_000_000);
    let reconstructed = packetized
        .datagrams
        .iter()
        .flat_map(|datagram| payload(datagram))
        .take(delta.payload.len())
        .collect::<Vec<_>>();
    assert_eq!(reconstructed, delta.payload);

    let keyframe = PlatformEncodedVideoFrame {
        key_frame: true,
        ..delta
    };
    assert_eq!(
        packetizer.packetize_video_delta(&keyframe, 10, 0),
        Err("video keyframes must use the reliable bootstrap stream".to_owned())
    );
}

#[test]
fn reed_solomon_parity_recovers_missing_plaintext_delta_shards() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(80), 1).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: (0..130).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 45_000,
        key_frame: false,
    };
    let packetized = packetizer.packetize_video_delta(&frame, 4, 34).unwrap();
    let first = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
    let data_shards = usize::from(first.header.data_shards);
    let parity_shards = usize::from(first.header.parity_shards);
    assert!(data_shards > 1);
    assert!(parity_shards > 0);

    let mut shards = packetized
        .datagrams
        .iter()
        .map(|datagram| Some(payload(datagram)))
        .collect::<Vec<_>>();
    for (index, datagram) in packetized.datagrams.iter().enumerate() {
        let decoded = decode_native_media_datagram(datagram).unwrap();
        assert_eq!(decoded.header.shard_index, index as u8);
        assert_eq!(
            decoded.header.flags & NATIVE_MEDIA_FLAG_PARITY_SHARD != 0,
            index >= data_shards
        );
    }
    shards[1] = None;
    ReedSolomon::new(data_shards, parity_shards)
        .unwrap()
        .reconstruct(&mut shards)
        .unwrap();
    let reconstructed = shards[..data_shards]
        .iter()
        .flat_map(|shard| shard.as_ref().unwrap().iter().copied())
        .take(frame.payload.len())
        .collect::<Vec<_>>();
    assert_eq!(reconstructed, frame.payload);
}

#[test]
fn splits_large_delta_objects_into_block_local_fec_metadata() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(80), 0).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: (0..15_000).map(|index| index as u8).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: false,
    };

    let packetized = packetizer.packetize_video_delta(&frame, 12, 1).unwrap();
    assert!(packetized
        .datagrams
        .iter()
        .all(|datagram| datagram.len() == 80));
    let first = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
    assert_ne!(first.header.flags & NATIVE_MEDIA_FLAG_FEC_BLOCK, 0);
    let first_block = first.fec_block.unwrap();
    assert_eq!(first_block.block_index, 0);
    assert!(first_block.block_count >= 2);
    assert_eq!(first_block.object_payload_offset, 0);

    let next = packetized
        .datagrams
        .iter()
        .map(|datagram| decode_native_media_datagram(datagram).unwrap())
        .find(|decoded| decoded.fec_block.unwrap().block_index == 1)
        .unwrap();
    assert_eq!(next.fec_block.unwrap().block_count, first_block.block_count);
    assert!(next.fec_block.unwrap().object_payload_offset > 0);
    assert_eq!(next.header.object_id, first.header.object_id);
    assert_eq!(next.header.object_bytes, first.header.object_bytes);
}

#[test]
fn audio_uses_generation_zero_and_raw_zero_padded_quic_datagram_payload() {
    let mut packetizer = NativeMediaPacketizer::new(
        NativeMediaPacketizerConfig {
            kind: NativeMediaKind::Audio,
            maximum_datagram_payload: 80,
            generation_id: 0,
        },
        0,
    )
    .unwrap();
    let packet = PlatformEncodedAudioPacket {
        payload: vec![1, 2, 3, 4, 5],
        presentation_time_48khz: 24_000,
        duration_frames: 240,
    };

    let packetized = packetizer.packetize_audio(&packet, 6).unwrap();

    assert_eq!(packetized.datagrams.len(), 1);
    assert_eq!(packetized.datagrams[0].len(), 80);
    let decoded = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
    assert_eq!(decoded.header.kind, NativeMediaKind::Audio);
    assert_eq!(decoded.header.generation_id, 0);
    assert_eq!(decoded.header.object_id, 6);
    assert_eq!(decoded.header.object_bytes, 5);
    assert_eq!(decoded.header.capture_timestamp_us, 500_000);
    let shard = payload(&packetized.datagrams[0]);
    assert_eq!(&shard[..5], packet.payload);
    assert!(shard[5..].iter().all(|byte| *byte == 0));
}

#[test]
fn reconfiguration_preserves_datagram_sequence_and_generation_is_explicit() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(80), 9).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: vec![7; 20],
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: false,
    };
    let first = packetizer.packetize_video_delta(&frame, 1, 0).unwrap();
    packetizer.reconfigure(96).unwrap();
    packetizer.update_video_generation(8).unwrap();
    let second = packetizer.packetize_video_delta(&frame, 2, 0).unwrap();

    let first_header = decode_native_media_datagram(&first.datagrams[0])
        .unwrap()
        .header;
    let second_header = decode_native_media_datagram(&second.datagrams[0])
        .unwrap()
        .header;
    assert_eq!(first_header.datagram_sequence, 9);
    assert_eq!(second_header.datagram_sequence, first.next_sequence);
    assert_eq!(first_header.generation_id, 7);
    assert_eq!(second_header.generation_id, 8);
}
