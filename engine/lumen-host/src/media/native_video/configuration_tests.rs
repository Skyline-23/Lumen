use super::test_fixtures::{encoded_frame, H264_420, H264_444, HEVC_420, HEVC_444};
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
    }
}
