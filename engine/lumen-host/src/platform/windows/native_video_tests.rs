use super::super::driver_abi::DRIVER_CONTENT_SIGNAL_UNCHANGED;
use super::*;
fn plan(ten_bit: bool) -> NativeVideoEncoderPlan {
    NativeVideoEncoderPlan {
        session_epoch: 1,
        encoder_epoch: 1,
        codec: PlatformVideoCodec::Hevc,
        width: 3_840,
        height: 2_160,
        frames_per_second: 120,
        bitrate_bps: 80_000_000,
        ten_bit,
        chroma_subsampling: PlatformChromaSubsampling::Yuv444,
    }
}

#[test]
fn selects_media_foundation_hevc_444_contracts() {
    let eight_bit = plan(false);
    assert_eq!(input_subtype(eight_bit), MFVideoFormat_AYUV);
    assert_eq!(
        output_profile(eight_bit),
        u32::try_from(eAVEncH265VProfile_Main_444_8.0).unwrap()
    );

    let ten_bit = plan(true);
    assert_eq!(input_subtype(ten_bit), MFVideoFormat_Y410);
    assert_eq!(
        output_profile(ten_bit),
        u32::try_from(eAVEncH265VProfile_Main_444_10.0).unwrap()
    );
}

#[test]
fn initial_periodic_and_repair_keyframes_pause_for_bootstrap_acknowledgement() {
    let sample = |key_frame, repair_keyframe, periodic_keyframe| NativeEncodedVideoSample {
        payload: vec![1],
        presentation_time_90khz: 0,
        key_frame,
        repair_keyframe,
        periodic_keyframe,
    };

    assert!(sample_requires_bootstrap_pause(
        &sample(true, false, false),
        true
    ));
    assert!(sample_requires_bootstrap_pause(
        &sample(true, true, false),
        false
    ));
    assert!(sample_requires_bootstrap_pause(
        &sample(true, false, true),
        false
    ));
    assert!(!sample_requires_bootstrap_pause(
        &sample(true, false, false),
        false
    ));
    assert!(!sample_requires_bootstrap_pause(
        &sample(false, false, true),
        false
    ));
}

#[test]
fn divisor_two_admission_preserves_capture_timeline_gaps() {
    let mut next = 0;
    let mut admissions_until_next = 0;
    let duration = 166_666;
    let admitted_timestamps = (0..4)
        .map(|_| {
            take_admitted_video_timestamp(&mut next, duration, &mut admissions_until_next, 2, false)
                .unwrap()
        })
        .collect::<Vec<_>>();

    assert_eq!(
        admitted_timestamps,
        vec![Some(0), None, Some(333_332), None]
    );
    assert_eq!(next, 666_664);
}

#[test]
fn adaptive_target_and_client_divisor_share_one_admission_budget() {
    assert_eq!(effective_target_frame_rate(120, 120, 120, 1), 120);
    assert_eq!(effective_target_frame_rate(120, 120, 120, 2), 60);
    assert_eq!(effective_target_frame_rate(120, 60, 120, 1), 60);
    assert_eq!(effective_target_frame_rate(120, 60, 60, 2), 60);
    assert_eq!(effective_target_frame_rate(120, 40, 120, 2), 40);
    assert_eq!(effective_target_frame_rate(120, 30, 120, 4), 30);
    assert_eq!(effective_target_frame_rate(120, 120, 2, 1), 2);
}

#[test]
fn unchanged_content_cadence_and_transactional_wake_fail_open() {
    let controller = WindowsUnchangedContentCadence::new(120).unwrap();
    assert_eq!(
        controller.observe(0.0, DRIVER_CONTENT_SIGNAL_UNCHANGED, true),
        Ok(120)
    );
    assert_eq!(
        controller.observe(1.0, DRIVER_CONTENT_SIGNAL_UNCHANGED, true),
        Ok(2)
    );
    assert_eq!(controller.wake(1.01), Ok(120));
    assert_eq!(
        controller.observe(1.99, DRIVER_CONTENT_SIGNAL_UNCHANGED, true),
        Ok(120)
    );

    let controller = WindowsUnchangedContentCadence::new(120).unwrap();
    assert_eq!(controller.observe(0.0, 99, true), Ok(120));
    assert_eq!(controller.observe(1.0, 99, true), Ok(120));

    let latch = Arc::new(ContentCadenceWakeLatch::default());
    let producer = Arc::clone(&latch);
    let result = thread::spawn(move || {
        producer.reserve();
        producer.commit();
        Ok::<(), String>(())
    })
    .join()
    .expect("wake producer must not wait for a frame");
    assert_eq!(result, Ok(()));
    assert!(latch.take_for_frame());
    assert!(!latch.take_for_frame());

    let latch = ContentCadenceWakeLatch::default();
    latch.reserve();
    latch.cancel();
    assert!(!latch.take_for_frame());

    latch.reserve();
    latch.clear();
    assert!(!latch.take_for_frame());
}

#[test]
fn cadence_admission_preserves_fractional_variable_rate_without_double_decimation() {
    let mut admission = WindowsCadenceAdmission::new();
    let admitted = (0..120)
        .filter(|index| admission.admits(index * 750, 60, 120, false))
        .count();
    assert_eq!(admitted, 60);

    let mut admission = WindowsCadenceAdmission::new();
    let admitted = (0..120)
        .filter(|index| admission.admits(index * 750, 58, 120, false))
        .count();
    assert_eq!(admitted, 58, "fractional deadlines must preserve 58 fps");

    let mut admission = WindowsCadenceAdmission::new();
    let admitted = (0..80)
        .filter(|index| admission.admits(index * 1_125, 58, 120, false))
        .count();
    assert_eq!(
        admitted, 58,
        "an 80 fps source must not be scaled by the negotiated 120 fps ceiling"
    );
}

#[test]
fn capture_timestamps_wrap_and_duration_stays_vfr_safe() {
    let previous = u32::MAX - 450;
    let current: u32 = 450;
    let step = u64::from(current.wrapping_sub(previous));
    let first = capture_timestamp_hns(0).unwrap();
    let second = capture_timestamp_hns(step).unwrap();
    assert_eq!(first, 0);
    assert_eq!(second, 100_111);

    let duration = second - first;
    assert!(duration > 0);
    assert!(duration < 200_000);

    assert!(capture_timestamp_step_is_forward(previous, current));
    assert!(!capture_timestamp_step_is_forward(500, 500));
    assert!(!capture_timestamp_step_is_forward(10_000, 9_000));
    assert!(!capture_timestamp_step_is_forward(
        500,
        500_u32.wrapping_sub(MAX_CAPTURE_TIMESTAMP_STEP_90KHZ + 1),
    ));
}

#[test]
fn media_foundation_duration_clamps_long_capture_gaps_but_keeps_vfr_timestamps() {
    let long_gap = MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS * 3;
    let duration = long_gap.clamp(
        MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
        MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
    );
    assert_eq!(duration, MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS);
    assert_eq!(
        1_i64.clamp(
            MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
            MAX_MEDIA_FOUNDATION_FRAME_DURATION_HNS,
        ),
        MIN_MEDIA_FOUNDATION_FRAME_DURATION_HNS
    );
}

#[test]
fn variant_array_cleanup_visits_every_value_including_unexpected_types() {
    let mut values = [
        VARIANT::from(1_u32),
        VARIANT::from(true),
        VARIANT::default(),
    ];
    let base = values.as_mut_ptr();
    let mut visited = Vec::new();

    unsafe {
        visit_variant_elements(base, values.len(), |value| {
            visited.push(value.offset_from(base));
        });
    }

    assert_eq!(visited, vec![0, 1, 2]);
}
