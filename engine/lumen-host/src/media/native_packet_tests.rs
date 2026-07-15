use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce, Tag};
use lumen_engine::{
    decode_native_media_datagram, decode_native_video_access_unit, NativeMediaKind,
    NATIVE_MEDIA_FLAG_CONFIGURATION_BOUNDARY, NATIVE_MEDIA_FLAG_KEYFRAME,
    NATIVE_MEDIA_FLAG_PARITY_SHARD, NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES,
};
use reed_solomon_erasure::galois_8::ReedSolomon;

use super::native_packet::{direct_udp_nonce, NativeMediaPacketizer, NativeMediaPacketizerConfig};
use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};

const TEST_KEY: [u8; 16] = [0x42; 16];

fn config() -> NativeMediaPacketizerConfig {
    NativeMediaPacketizerConfig {
        session_epoch: 0x0102_0304,
        path_id: 7,
        policy_revision: 3,
        stream_id: 11,
        configuration_id: 1,
        maximum_datagram_payload: 80,
        direct_udp_key: TEST_KEY,
    }
}

fn decrypt_payload(datagram: &[u8], key: &[u8; 16]) -> Vec<u8> {
    let decoded = decode_native_media_datagram(datagram).unwrap();
    let (ciphertext, tag) = datagram[40..].split_at(datagram.len() - 40 - 16);
    let mut plaintext = ciphertext.to_vec();
    Aes128Gcm::new_from_slice(key)
        .unwrap()
        .decrypt_in_place_detached(
            Nonce::from_slice(&direct_udp_nonce(&decoded.header)),
            &datagram[..40],
            &mut plaintext,
            Tag::from_slice(tag),
        )
        .unwrap();
    plaintext
}

#[test]
fn packetizes_video_with_configuration_descriptor_and_bounded_datagrams() {
    let mut packetizer = NativeMediaPacketizer::new(config(), 0x1011_1213).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: (0..65).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: true,
    };

    let packetized = packetizer.packetize_video(&frame, 9, 0).unwrap();

    assert_eq!(packetized.datagrams.len(), 4);
    assert_eq!(packetized.next_sequence, 0x1011_1217);
    let first = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
    assert_eq!(first.header.kind, NativeMediaKind::Video);
    assert_eq!(
        first.header.flags,
        NATIVE_MEDIA_FLAG_KEYFRAME | NATIVE_MEDIA_FLAG_CONFIGURATION_BOUNDARY
    );
    assert_eq!(first.header.session_epoch, 0x0102_0304);
    assert_eq!(first.header.path_id, 7);
    assert_eq!(first.header.policy_revision, 3);
    assert_eq!(first.header.stream_id, 11);
    assert_eq!(first.header.shard_index, 0);
    assert_eq!(first.header.data_shards, 4);
    assert_eq!(first.header.parity_shards, 0);
    assert_eq!(first.header.packet_sequence, 0x1011_1213);
    assert_eq!(first.header.frame_id, 9);
    assert_eq!(
        first.header.frame_bytes,
        (frame.payload.len() + NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES) as u32
    );
    assert_eq!(first.header.capture_timestamp_us, 1_000_000);
    assert!(packetized
        .datagrams
        .iter()
        .all(|datagram| datagram.len() == 80));
    let reconstructed = packetized
        .datagrams
        .iter()
        .flat_map(|datagram| decrypt_payload(datagram, &TEST_KEY))
        .take(first.header.frame_bytes as usize)
        .collect::<Vec<_>>();
    let (descriptor, recovered) = decode_native_video_access_unit(&reconstructed).unwrap();
    assert_eq!(descriptor.configuration_id, 1);
    assert_eq!(recovered, frame.payload);

    let repeated_keyframe = packetizer.packetize_video(&frame, 10, 0).unwrap();
    let repeated_header = decode_native_media_datagram(&repeated_keyframe.datagrams[0])
        .unwrap()
        .header;
    assert_eq!(
        repeated_header.flags, NATIVE_MEDIA_FLAG_KEYFRAME,
        "configuration boundaries are emitted once per configuration"
    );
}

#[test]
fn reed_solomon_parity_recovers_missing_native_video_shards() {
    let mut packetizer = NativeMediaPacketizer::new(config(), 1).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: (0..65).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 45_000,
        key_frame: true,
    };
    let packetized = packetizer.packetize_video(&frame, 4, 34).unwrap();
    assert_eq!(packetized.datagrams.len(), 6);

    let mut shards = packetized
        .datagrams
        .iter()
        .map(|datagram| Some(decrypt_payload(datagram, &TEST_KEY)))
        .collect::<Vec<_>>();
    for (index, datagram) in packetized.datagrams.iter().enumerate() {
        let decoded = decode_native_media_datagram(datagram).unwrap();
        assert_eq!(decoded.header.shard_index, index as u16);
        assert_eq!(decoded.header.data_shards, 4);
        assert_eq!(decoded.header.parity_shards, 2);
        assert_eq!(
            decoded.header.flags & NATIVE_MEDIA_FLAG_PARITY_SHARD != 0,
            index >= 4
        );
    }
    shards[1] = None;
    shards[5] = None;
    ReedSolomon::new(4, 2)
        .unwrap()
        .reconstruct(&mut shards)
        .unwrap();
    let reconstructed = shards[..4]
        .iter()
        .flat_map(|shard| shard.as_ref().unwrap().iter().copied())
        .take(frame.payload.len() + NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES)
        .collect::<Vec<_>>();
    let (_, recovered) = decode_native_video_access_unit(&reconstructed).unwrap();
    assert_eq!(recovered, frame.payload);
}

#[test]
fn splits_large_video_frames_into_bounded_independently_recoverable_fec_blocks() {
    let mut packetizer = NativeMediaPacketizer::new(config(), 0).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: (0..6_100).map(|index| index as u8).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: true,
    };

    let packetized = packetizer.packetize_video(&frame, 12, 1).unwrap();

    assert_eq!(packetized.datagrams.len(), 387);
    assert_eq!(packetized.next_sequence, 387);
    assert!(packetized
        .datagrams
        .iter()
        .all(|datagram| datagram.len() == 80));
    let first = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
    assert_eq!(first.payload_offset, 48);
    assert_eq!(first.fec_block.unwrap().block_index, 0);
    assert_eq!(first.fec_block.unwrap().block_count, 2);
    assert_eq!(first.fec_block.unwrap().frame_payload_offset, 0);
    let second_block = decode_native_media_datagram(&packetized.datagrams[256]).unwrap();
    assert_eq!(second_block.fec_block.unwrap().block_index, 1);
    assert_eq!(second_block.fec_block.unwrap().block_count, 2);
    assert_eq!(second_block.fec_block.unwrap().frame_payload_offset, 4_048);
    assert_eq!(second_block.header.data_shards, 129);
    assert_eq!(second_block.header.parity_shards, 2);
}

#[test]
fn direct_udp_encrypts_only_payload_and_authenticates_the_native_header() {
    let key = std::array::from_fn(|index| index as u8);
    let mut direct_config = config();
    direct_config.direct_udp_key = key;
    let mut packetizer = NativeMediaPacketizer::new(direct_config, 0x2021_2223).unwrap();
    let packetized = packetizer
        .packetize_audio(
            &PlatformEncodedAudioPacket {
                payload: vec![1, 2, 3, 4, 5],
                presentation_time_48khz: 24_000,
                duration_frames: 240,
            },
            6,
        )
        .unwrap();
    assert_eq!(packetized.datagrams.len(), 1);
    assert_eq!(packetized.datagrams[0].len(), 80);

    let datagram = &packetized.datagrams[0];
    let decoded = decode_native_media_datagram(datagram).unwrap();
    assert_eq!(decoded.header.kind, NativeMediaKind::Audio);
    assert_eq!(decoded.header.capture_timestamp_us, 500_000);
    let (ciphertext, tag) = datagram[40..].split_at(datagram.len() - 40 - 16);
    let mut plaintext = ciphertext.to_vec();
    Aes128Gcm::new_from_slice(&key)
        .unwrap()
        .decrypt_in_place_detached(
            Nonce::from_slice(&direct_udp_nonce(&decoded.header)),
            &datagram[..40],
            &mut plaintext,
            Tag::from_slice(tag),
        )
        .unwrap();
    assert_eq!(&plaintext[..5], &[1, 2, 3, 4, 5]);

    let mut tampered = datagram.clone();
    tampered[27] ^= 1;
    let changed = decode_native_media_datagram(&tampered).unwrap();
    let (ciphertext, tag) = tampered[40..].split_at(tampered.len() - 40 - 16);
    let mut plaintext = ciphertext.to_vec();
    assert!(Aes128Gcm::new_from_slice(&key)
        .unwrap()
        .decrypt_in_place_detached(
            Nonce::from_slice(&direct_udp_nonce(&changed.header)),
            &tampered[..40],
            &mut plaintext,
            Tag::from_slice(tag),
        )
        .is_err());
}

#[test]
fn policy_reconfiguration_preserves_the_nonce_sequence() {
    let mut packetizer = NativeMediaPacketizer::new(config(), 9).unwrap();
    let packet = PlatformEncodedAudioPacket {
        payload: vec![1, 2, 3],
        presentation_time_48khz: 0,
        duration_frames: 240,
    };
    let first = packetizer.packetize_audio(&packet, 1).unwrap();
    packetizer.reconfigure(4, 96).unwrap();
    let second = packetizer.packetize_audio(&packet, 2).unwrap();

    let first_header = decode_native_media_datagram(&first.datagrams[0])
        .unwrap()
        .header;
    let second_header = decode_native_media_datagram(&second.datagrams[0])
        .unwrap()
        .header;
    assert_eq!(first_header.packet_sequence, 9);
    assert_eq!(first_header.policy_revision, 3);
    assert_eq!(second_header.packet_sequence, 10);
    assert_eq!(second_header.policy_revision, 4);
    assert_eq!(second.datagrams[0].len(), 96);
}
