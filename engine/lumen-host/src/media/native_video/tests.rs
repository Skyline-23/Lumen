use super::test_fixtures::{
    encoded_frame, H264_420, H264_444, HEVC_420, HEVC_420_10, HEVC_444, HEVC_444_10,
};
use super::*;
use crate::{
    PlatformChromaSubsampling, PlatformColorRange, PlatformDynamicRange, PlatformVideoProfile,
};

#[test]
fn normalizes_every_matching_exact_avc_and_hevc_configuration() {
    // Given: every exact AVC/HEVC 4:2:0 and 4:4:4 format supported by protocol v4.
    let formats = matching_formats();

    // When: each matching key frame reaches a fresh normalizer.
    let results = formats
        .map(|format| NativeVideoBitstreamNormalizer::new(format).normalize(encoded_frame(format)));

    // Then: each format produces configuration one and a packetizable access unit.
    for (format, result) in formats.into_iter().zip(results) {
        let Ok(normalized) = result else {
            panic!("matching exact format was rejected: {format:?}");
        };
        println!(
            "ACCEPT {format:?} configuration_id={}",
            normalized.configuration_id
        );
        assert_eq!(normalized.configuration_id, 1);
        assert!(normalized.new_configuration.is_some());
        assert!(!normalized.frame.payload.is_empty());
    }
}

#[test]
fn rejects_h264_sps_that_disagrees_with_the_selected_exact_format() {
    // Given: a selected High 4:4:4 full-range plan and a High 4:2:0 SPS.
    let selected = H264_444;
    let emitted = H264_420;

    // When: the mismatched configuration reaches normalization.
    let result = NativeVideoBitstreamNormalizer::new(selected).normalize(encoded_frame(emitted));

    // Then: the frame is rejected before a configuration can be forwarded.
    let error = result.unwrap_err();
    println!("REJECT selected={selected:?} emitted={emitted:?} error={error}");
    assert_eq!(error, "H.264 SPS does not match the selected video format");
}

#[test]
fn rejects_hevc_profile_chroma_depth_dynamic_range_and_color_range_mismatches() {
    // Given: an exact Main 4:4:4 10-bit HDR plan and five one-axis SPS mismatches.
    let selected = HEVC_444_10;
    let mismatches = [
        PlatformVideoFormat {
            profile: PlatformVideoProfile::HevcMain,
            ..selected
        },
        PlatformVideoFormat {
            chroma_subsampling: PlatformChromaSubsampling::Yuv420,
            ..selected
        },
        PlatformVideoFormat {
            bit_depth: 8,
            ..selected
        },
        PlatformVideoFormat {
            dynamic_range: PlatformDynamicRange::Sdr,
            ..selected
        },
        PlatformVideoFormat {
            color_range: PlatformColorRange::Full,
            ..selected
        },
    ];

    // When: each mismatched SPS reaches a fresh normalizer.
    let results = mismatches.map(|emitted| {
        NativeVideoBitstreamNormalizer::new(selected).normalize(encoded_frame(emitted))
    });

    // Then: every mismatch fails closed under the selected plan.
    for (emitted, result) in mismatches.into_iter().zip(results) {
        let error = result.unwrap_err();
        println!("REJECT selected={selected:?} emitted={emitted:?} error={error}");
        assert_eq!(error, "HEVC SPS does not match the selected video format");
    }
}

#[test]
fn rejects_stale_configuration_after_an_exact_format_was_accepted() {
    // Given: an active HEVC 4:4:4 normalizer with configuration one.
    let selected = matching_formats()[4];
    let mut normalizer = NativeVideoBitstreamNormalizer::new(selected);
    let Ok(normalized) = normalizer.normalize(encoded_frame(selected)) else {
        panic!("matching initial configuration was rejected");
    };
    assert_eq!(normalized.configuration_id, 1);

    // When: a later key frame carries a 4:2:0 SPS under the unchanged plan.
    let result = normalizer.normalize(encoded_frame(matching_formats()[1]));

    // Then: the stale configuration is rejected instead of advancing its id.
    let error = result.unwrap_err();
    println!("REJECT stale selected={selected:?} error={error}");
    assert_eq!(error, "HEVC SPS does not match the selected video format");
}

#[test]
fn requires_explicit_av1_configuration_and_keeps_sized_obus() {
    let format = PlatformVideoFormat {
        codec: PlatformVideoCodec::Av1,
        profile: PlatformVideoProfile::Av1Main,
        chroma_subsampling: PlatformChromaSubsampling::Yuv420,
        bit_depth: 10,
        dynamic_range: PlatformDynamicRange::Hdr10,
        color_range: PlatformColorRange::Limited,
    };
    let mut normalizer = NativeVideoBitstreamNormalizer::new(format);
    let configuration = vec![AV1_CONFIGURATION_MARKER_AND_VERSION, 0, 0, 0];
    let Ok(normalized) = normalizer.normalize(PlatformEncodedVideoFrame {
        payload: vec![0x0a, 1, 0],
        decoder_configuration_record: Some(configuration.clone()),
        presentation_time_90khz: 90_000,
        key_frame: true,
    }) else {
        panic!("valid AV1 configuration was rejected");
    };
    assert_eq!(normalized.frame.payload, vec![0x0a, 1, 0]);
    let Some(new_configuration) = normalized.new_configuration else {
        panic!("valid AV1 configuration was not activated");
    };
    assert_eq!(
        new_configuration.decoder_configuration_record,
        configuration
    );
}

fn matching_formats() -> [PlatformVideoFormat; 6] {
    [
        H264_420,
        HEVC_420,
        HEVC_420_10,
        H264_444,
        HEVC_444,
        HEVC_444_10,
    ]
}
