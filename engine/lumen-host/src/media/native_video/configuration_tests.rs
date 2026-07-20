use super::test_fixtures::{encoded_frame, H264_420, H264_444, HEVC_420, HEVC_420_10, HEVC_444};
use super::*;
use crate::PlatformEncodedVideoFrame;

#[test]
fn supplied_avcc_and_hvcc_are_validated_against_the_selected_plan() {
    // Given: independently normalized H.264 and HEVC 4:2:0 configuration records.
    let emitted_formats = [H264_420, HEVC_420];
    let records = emitted_formats.map(|format| {
        let Ok(normalized) =
            NativeVideoBitstreamNormalizer::new(format).normalize(encoded_frame(format))
        else {
            panic!("matching fixture did not normalize");
        };
        let Some(configuration) = normalized.new_configuration else {
            panic!("matching fixture produced no configuration");
        };
        configuration.decoder_configuration_record
    });

    // When: the records are supplied without in-band parameter sets under matching plans.
    let accepted = emitted_formats
        .into_iter()
        .zip(records.clone())
        .map(|(format, record)| {
            NativeVideoBitstreamNormalizer::new(format).normalize(slice_frame(format.codec, record))
        });

    // Then: both matching records are accepted as configuration one.
    for result in accepted {
        let Ok(normalized) = result else {
            panic!("matching supplied configuration was rejected");
        };
        assert_eq!(normalized.configuration_id, 1);
    }

    let selected_formats = [H264_444, HEVC_444];

    // When: those same records are supplied under incompatible 4:4:4 plans.
    let rejected = selected_formats
        .into_iter()
        .zip(records)
        .map(|(selected, record)| {
            let result = NativeVideoBitstreamNormalizer::new(selected)
                .normalize(slice_frame(selected.codec, record));
            (selected, result)
        });

    // Then: each stale record is rejected before it can become active.
    for (selected, result) in rejected {
        let error = result.unwrap_err();
        println!("REJECT supplied selected={selected:?} error={error}");
        assert!(error.contains("does not match the selected video format"));
    }
}

#[test]
fn rejects_avcc_profile_header_mismatch_when_sps_matches_selected_format() {
    // Given: a valid High 4:2:0 SPS inside avcC whose summary header claims Main profile.
    let mut record = decoder_configuration(H264_420);
    record[1] = 77;

    // When: the supplied record reaches the selected High 4:2:0 normalizer.
    let result = NativeVideoBitstreamNormalizer::new(H264_420)
        .normalize(slice_frame(PlatformVideoCodec::H264, record));

    // Then: the lying avcC header is rejected even though its embedded SPS is valid.
    assert_eq!(
        result.unwrap_err(),
        "H.264 decoder configuration header disagrees with its SPS"
    );
}

#[test]
fn rejects_hvcc_header_mismatch_when_sps_matches_selected_format() {
    // Given: valid Main10 4:2:0 SPS records with one lying hvcC header field each.
    let record = decoder_configuration(HEVC_420_10);
    let mut profile = record.clone();
    profile[1] = profile[1] & 0xe0 | 1;
    let mut tier = record.clone();
    tier[1] ^= 0x20;
    let mut level = record.clone();
    level[12] ^= 1;
    let mut chroma = record.clone();
    chroma[16] = chroma[16] & 0xfc | 3;
    let mut bit_depth = record;
    bit_depth[17] &= 0xf8;
    bit_depth[18] &= 0xf8;
    let mismatches = [profile, tier, level, chroma, bit_depth];
    let expected_errors = [
        "HEVC decoder configuration header does not match the selected video format",
        "HEVC decoder configuration header disagrees with its SPS",
        "HEVC decoder configuration header disagrees with its SPS",
        "HEVC decoder configuration header does not match the selected video format",
        "HEVC decoder configuration header does not match the selected video format",
    ];

    // When: each supplied record reaches the selected Main10 4:2:0 normalizer.
    let results = mismatches.map(|record| {
        NativeVideoBitstreamNormalizer::new(HEVC_420_10)
            .normalize(slice_frame(PlatformVideoCodec::Hevc, record))
    });

    // Then: profile, tier, level, chroma, and bit-depth header lies all fail closed.
    for (result, expected) in results.into_iter().zip(expected_errors) {
        assert_eq!(result.unwrap_err(), expected);
    }
}

fn decoder_configuration(format: PlatformVideoFormat) -> Vec<u8> {
    let Ok(normalized) =
        NativeVideoBitstreamNormalizer::new(format).normalize(encoded_frame(format))
    else {
        panic!("matching fixture did not normalize");
    };
    let Some(configuration) = normalized.new_configuration else {
        panic!("matching fixture produced no configuration");
    };
    configuration.decoder_configuration_record
}

fn slice_frame(codec: PlatformVideoCodec, record: Vec<u8>) -> PlatformEncodedVideoFrame {
    PlatformEncodedVideoFrame {
        payload: match codec {
            PlatformVideoCodec::H264 => vec![0, 0, 0, 1, 0x65, 0x88],
            PlatformVideoCodec::Hevc => vec![0, 0, 0, 1, 0x26, 0x01, 0x80],
            PlatformVideoCodec::Av1 => Vec::new(),
        },
        decoder_configuration_record: Some(record),
        presentation_time_90khz: 90_000,
        key_frame: true,
        requires_bootstrap_acknowledgement: false,
        repair_keyframe: false,
    }
}
