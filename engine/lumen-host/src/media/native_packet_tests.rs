use std::collections::BTreeMap;

use lumen_engine::{
    decode_native_media_datagram, native_video_packetization_plan, NativeMediaKind,
    NATIVE_MEDIA_FLAG_FEC_BLOCK, NATIVE_MEDIA_FLAG_KEYFRAME, NATIVE_MEDIA_FLAG_PARITY_SHARD,
};
use reed_solomon_erasure::galois_8::ReedSolomon;

use super::native_packet::{
    NativeMediaPacketizer, NativeMediaPacketizerConfig, NativePacketizedUnit,
};
use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};

const VARYING_FEC_FRAME_BYTES: [usize; 9] = [
    200_070, 221_130, 195_390, 252_720, 212_940, 203_580, 249_210, 273_780, 291_330,
];

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

fn video_frame(payload_bytes: usize) -> PlatformEncodedVideoFrame {
    PlatformEncodedVideoFrame {
        payload: (0..payload_bytes)
            .map(|index| index.wrapping_mul(73).wrapping_add(19) as u8)
            .collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: false,
        requires_bootstrap_acknowledgement: false,
        repair_keyframe: false,
    }
}

#[test]
fn exact_wire_plan_matches_adversarial_padding_header_and_fec_boundaries() {
    const MTU: usize = 1_200;
    const PARITY: u16 = 30;
    let base_shard_bytes = MTU - 28;
    let cases = [
        (1, 2_400),
        (base_shard_bytes, 2_400),
        (base_shard_bytes + 1, 3_600),
        (32 * base_shard_bytes, 50_400),
        (32 * base_shard_bytes + 1, 52_800),
        (200_070, 271_200),
    ];

    let mut packetizer = NativeMediaPacketizer::new(video_config(MTU), 0).unwrap();
    for (index, (payload_bytes, expected_wire_bytes)) in cases.into_iter().enumerate() {
        let plan = native_video_packetization_plan(payload_bytes, MTU, PARITY).unwrap();
        let packetized = packetizer
            .packetize_video_delta(&video_frame(payload_bytes), index as u32 + 1, PARITY)
            .unwrap();
        let emitted_wire_bytes = packetized.datagrams.iter().map(Vec::len).sum::<usize>();

        assert_eq!(plan.total_wire_bytes, expected_wire_bytes);
        assert_eq!(emitted_wire_bytes, plan.total_wire_bytes);
        assert_eq!(packetized.datagrams.len(), plan.total_shards);
        assert!(packetized
            .datagrams
            .iter()
            .all(|datagram| datagram.len() == MTU));
    }
}

fn reconstruct_fec_blocks(packetized: &NativePacketizedUnit) -> Vec<u8> {
    let first = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
    let object_bytes = first.header.object_bytes as usize;
    let block_count = usize::from(first.fec_block.unwrap().block_count);
    let mut reconstructed = vec![0_u8; object_bytes];

    for block_index in 0..block_count {
        let block_datagrams = packetized
            .datagrams
            .iter()
            .filter(|datagram| {
                decode_native_media_datagram(datagram)
                    .unwrap()
                    .fec_block
                    .is_some_and(|block| usize::from(block.block_index) == block_index)
            })
            .collect::<Vec<_>>();
        let first = decode_native_media_datagram(block_datagrams[0]).unwrap();
        let fec_block = first.fec_block.unwrap();
        let data_shards = usize::from(first.header.data_shards);
        let parity_shards = usize::from(first.header.parity_shards);
        let mut shards = block_datagrams
            .iter()
            .enumerate()
            .map(|(index, datagram)| {
                let decoded = decode_native_media_datagram(datagram).unwrap();
                assert_eq!(usize::from(decoded.header.shard_index), index);
                assert_eq!(usize::from(decoded.header.data_shards), data_shards);
                assert_eq!(usize::from(decoded.header.parity_shards), parity_shards);
                Some(payload(datagram))
            })
            .collect::<Vec<_>>();
        shards[block_index % data_shards] = None;
        ReedSolomon::new(data_shards, parity_shards)
            .unwrap()
            .reconstruct(&mut shards)
            .unwrap();

        let block_start = fec_block.object_payload_offset as usize;
        let block_end = packetized
            .datagrams
            .iter()
            .filter_map(|datagram| decode_native_media_datagram(datagram).unwrap().fec_block)
            .find(|block| usize::from(block.block_index) == block_index + 1)
            .map_or(object_bytes, |block| block.object_payload_offset as usize);
        let block_bytes = shards[..data_shards]
            .iter()
            .flat_map(|shard| shard.as_ref().unwrap().iter().copied())
            .take(block_end - block_start)
            .collect::<Vec<_>>();
        reconstructed[block_start..block_end].copy_from_slice(&block_bytes);
    }

    reconstructed
}

#[test]
fn packetizes_video_deltas_and_keyframes_across_the_90khz_wrap_seam() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(80), 0x1011_1213).unwrap();
    let delta = PlatformEncodedVideoFrame {
        payload: (0..65).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: u64::from(u32::MAX),
        key_frame: false,
        requires_bootstrap_acknowledgement: false,
        repair_keyframe: false,
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
    assert_eq!(first.header.capture_timestamp_us, 477_218_577);
    let reconstructed = packetized
        .datagrams
        .iter()
        .flat_map(|datagram| payload(datagram))
        .take(delta.payload.len())
        .collect::<Vec<_>>();
    assert_eq!(reconstructed, delta.payload);

    let keyframe = PlatformEncodedVideoFrame {
        presentation_time_90khz: u64::from(u32::MAX) + 1,
        key_frame: true,
        ..delta
    };
    let keyframe = packetizer.packetize_video_delta(&keyframe, 10, 0).unwrap();
    let first_keyframe = decode_native_media_datagram(&keyframe.datagrams[0]).unwrap();
    assert_eq!(first_keyframe.header.capture_timestamp_us, 477_218_588);
    assert_eq!(
        first_keyframe
            .header
            .capture_timestamp_us
            .wrapping_sub(first.header.capture_timestamp_us),
        11
    );
    assert!(keyframe.datagrams.iter().all(|datagram| {
        decode_native_media_datagram(datagram).unwrap().header.flags & NATIVE_MEDIA_FLAG_KEYFRAME
            != 0
    }));
}

#[test]
fn reed_solomon_parity_recovers_missing_plaintext_delta_shards() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(80), 1).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: (0..130).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 45_000,
        key_frame: false,
        requires_bootstrap_acknowledgement: false,
        repair_keyframe: false,
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
fn fec_packet_bytes_match_stable_wire_vector() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(40), 0x0102_0304).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: (0..13).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: false,
        requires_bootstrap_acknowledgement: false,
        repair_keyframe: false,
    };

    let packetized = packetizer.packetize_video_delta(&frame, 9, 50).unwrap();

    assert_eq!(
        packetized.datagrams,
        vec![
            vec![
                1, 0, 0, 28, 0, 0, 0, 7, 1, 2, 3, 4, 0, 0, 0, 9, 0, 0, 0, 13, 0, 15, 66, 64, 0, 2,
                1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
            ],
            vec![
                1, 0, 0, 28, 0, 0, 0, 7, 1, 2, 3, 5, 0, 0, 0, 9, 0, 0, 0, 13, 0, 15, 66, 64, 1, 2,
                1, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ],
            vec![
                1, 16, 0, 28, 0, 0, 0, 7, 1, 2, 3, 6, 0, 0, 0, 9, 0, 0, 0, 13, 0, 15, 66, 64, 2, 2,
                1, 0, 24, 3, 6, 5, 12, 15, 10, 9, 24, 27, 30, 29,
            ],
        ]
    );
}

#[test]
fn sixty_four_byte_shard_parity_matches_stable_wire_vector() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(92), 0).unwrap();
    let frame = video_frame(256);

    let packetized = packetizer.packetize_video_delta(&frame, 9, 50).unwrap();
    let parity_payloads = packetized
        .datagrams
        .iter()
        .filter(|datagram| {
            decode_native_media_datagram(datagram).unwrap().header.flags
                & NATIVE_MEDIA_FLAG_PARITY_SHARD
                != 0
        })
        .map(|datagram| payload(datagram))
        .collect::<Vec<_>>();

    assert_eq!(
        parity_payloads,
        vec![
            vec![
                14, 53, 184, 135, 42, 157, 160, 15, 50, 185, 132, 43, 22, 161, 12, 51, 190, 133,
                40, 23, 174, 13, 48, 191, 130, 41, 20, 175, 18, 49, 188, 131, 46, 21, 172, 19, 62,
                189, 128, 47, 18, 173, 16, 63, 130, 129, 44, 19, 170, 17, 60, 131, 142, 45, 16,
                171, 22, 61, 128, 143, 50, 17, 168, 23,
            ],
            vec![
                78, 245, 248, 71, 106, 221, 96, 79, 242, 249, 68, 107, 214, 97, 76, 243, 254, 69,
                104, 215, 110, 77, 240, 255, 66, 105, 212, 111, 82, 241, 252, 67, 110, 213, 108,
                83, 254, 253, 64, 111, 210, 109, 80, 255, 194, 65, 108, 211, 106, 81, 252, 195, 78,
                109, 208, 107, 86, 253, 192, 79, 114, 209, 104, 87,
            ],
        ]
    );
}

#[test]
fn varying_tail_shapes_do_not_evict_the_hot_full_block_codec() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(1_200), 0).unwrap();
    let large_frame = video_frame(VARYING_FEC_FRAME_BYTES[0]);
    packetizer
        .packetize_video_delta(&large_frame, 1, 20)
        .unwrap();
    let small_tail_shapes = [1_173, 2_345, 3_517, 4_689].map(video_frame);
    for (index, frame) in small_tail_shapes.iter().enumerate() {
        packetizer
            .packetize_video_delta(frame, index as u32 + 2, 20)
            .unwrap();
    }
    let constructions_before_second_large_frame = packetizer.fec_codec_construction_count();

    packetizer
        .packetize_video_delta(&large_frame, 6, 20)
        .unwrap();

    assert_eq!(
        packetizer.fec_codec_construction_count(),
        constructions_before_second_large_frame + 1,
        "only the varying tail codec should need reconstruction"
    );
}

#[test]
fn reconfiguration_reuses_the_length_independent_full_block_codec() {
    let frame = video_frame(VARYING_FEC_FRAME_BYTES[0]);
    let mut packetizer = NativeMediaPacketizer::new(video_config(1_200), 0).unwrap();
    packetizer.packetize_video_delta(&frame, 1, 20).unwrap();
    let constructions_before_reconfiguration = packetizer.fec_codec_construction_count();

    packetizer.reconfigure(1_000).unwrap();
    let reconfigured = packetizer.packetize_video_delta(&frame, 2, 20).unwrap();

    assert!(reconfigured
        .datagrams
        .iter()
        .all(|datagram| datagram.len() == 1_000));
    assert_eq!(
        packetizer.fec_codec_construction_count(),
        constructions_before_reconfiguration + 1,
        "only the new tail shape should need a codec after an MTU change"
    );
}

#[test]
fn dynamic_block_width_preserves_the_protocol_object_capacity() {
    const MINIMUM_MTU: usize = 37;
    const SHARD_BYTES: usize = 1;
    const MAXIMUM_DATA_SHARDS_AT_FEC_20: usize = 213;

    let mut packetizer = NativeMediaPacketizer::new(video_config(MINIMUM_MTU), 0).unwrap();
    let first_dynamic_payload = 255 * 32 * SHARD_BYTES + 1;
    let dynamic = packetizer
        .packetize_video_delta(&video_frame(first_dynamic_payload), 1, 20)
        .unwrap();
    let first = decode_native_media_datagram(&dynamic.datagrams[0]).unwrap();
    assert_eq!(first.header.data_shards, 33);
    assert_eq!(first.header.parity_shards, 7);
    assert_eq!(first.fec_block.unwrap().block_count, 248);

    let maximum_payload = 255 * MAXIMUM_DATA_SHARDS_AT_FEC_20 * SHARD_BYTES;
    let maximum = packetizer
        .packetize_video_delta(&video_frame(maximum_payload), 2, 20)
        .unwrap();
    let first = decode_native_media_datagram(&maximum.datagrams[0]).unwrap();
    assert_eq!(first.header.data_shards, 213);
    assert_eq!(first.header.parity_shards, 43);
    assert_eq!(first.fec_block.unwrap().block_count, 255);

    assert_eq!(
        packetizer.packetize_video_delta(&video_frame(maximum_payload + 1), 3, 20),
        Err("native media packetization plan is invalid".to_owned())
    );
}

#[test]
fn varying_large_fec_frames_use_bounded_blocks_and_reconstruct_after_loss() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(1_200), 0).unwrap();

    for (index, payload_bytes) in VARYING_FEC_FRAME_BYTES.into_iter().enumerate() {
        let frame = video_frame(payload_bytes);
        let packetized = packetizer
            .packetize_video_delta(&frame, index as u32 + 1, 20)
            .unwrap();
        let first = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
        assert!(
            first.fec_block.is_some(),
            "large parity frame must use bounded FEC blocks"
        );
        assert!(packetized
            .datagrams
            .iter()
            .all(|datagram| datagram.len() == 1_200));
        assert!(packetized.datagrams.len() < 4_096);
        assert!(packetized.datagrams.iter().map(Vec::len).sum::<usize>() < 8 * 1024 * 1024);

        let mut block_shapes = BTreeMap::new();
        for datagram in &packetized.datagrams {
            let decoded = decode_native_media_datagram(datagram).unwrap();
            let block = decoded.fec_block.unwrap();
            block_shapes.entry(block.block_index).or_insert((
                usize::from(decoded.header.data_shards),
                usize::from(decoded.header.parity_shards),
            ));
        }
        assert_eq!(
            block_shapes.len(),
            usize::from(first.fec_block.unwrap().block_count)
        );
        assert!(block_shapes
            .values()
            .all(|(data_shards, _)| *data_shards <= 32));
        assert!(block_shapes.values().all(|(data_shards, parity_shards)| {
            *parity_shards == (*data_shards * 20).div_ceil(100)
        }));
        for shape in block_shapes.values().take(block_shapes.len() - 1) {
            assert_eq!(*shape, (32, 7));
        }
        assert_eq!(reconstruct_fec_blocks(&packetized), frame.payload);
    }
}

#[test]
fn splits_large_delta_objects_into_block_local_fec_metadata() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(80), 0).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: (0..15_000).map(|index| index as u8).collect(),
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: false,
        requires_bootstrap_acknowledgement: false,
        repair_keyframe: false,
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
fn single_shard_audio_uses_generation_zero_and_exact_opus_payload_length() {
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
    assert_eq!(packetized.datagrams[0].len(), 28 + packet.payload.len());
    let decoded = decode_native_media_datagram(&packetized.datagrams[0]).unwrap();
    assert_eq!(decoded.header.kind, NativeMediaKind::Audio);
    assert_eq!(decoded.header.generation_id, 0);
    assert_eq!(decoded.header.object_id, 6);
    assert_eq!(decoded.header.object_bytes, 5);
    assert_eq!(decoded.header.capture_timestamp_us, 500_000);
    let shard = payload(&packetized.datagrams[0]);
    assert_eq!(shard, packet.payload);
}

#[test]
fn reconfiguration_preserves_datagram_sequence_and_generation_is_explicit() {
    let mut packetizer = NativeMediaPacketizer::new(video_config(80), 9).unwrap();
    let frame = PlatformEncodedVideoFrame {
        payload: vec![7; 20],
        decoder_configuration_record: None,
        presentation_time_90khz: 90_000,
        key_frame: false,
        requires_bootstrap_acknowledgement: false,
        repair_keyframe: false,
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
