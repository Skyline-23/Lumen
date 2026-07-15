use lumen_host::{
    LumenHostPlatformChromaSubsampling, LumenHostPlatformColorRange, LumenHostPlatformDynamicRange,
    LumenHostPlatformSessionPlan, LumenHostPlatformVideoCodec, LumenHostPlatformVideoProfile,
    PlatformChromaSubsampling, PlatformColorRange, PlatformDynamicRange, PlatformSessionPlan,
    PlatformVideoCodec, PlatformVideoFormat, PlatformVideoProfile,
};
use std::mem::{align_of, offset_of, size_of};

#[test]
fn exact_platform_format_crosses_the_c_abi_without_boolean_inference() {
    // Given: one exact HEVC Main 4:2:0 SDR selection.
    let plan = PlatformSessionPlan {
        width: 3_840,
        height: 2_160,
        frames_per_second: 120,
        bitrate_kbps: 80_000,
        video_format: PlatformVideoFormat {
            codec: PlatformVideoCodec::Hevc,
            profile: PlatformVideoProfile::HevcMain,
            chroma_subsampling: PlatformChromaSubsampling::Yuv420,
            bit_depth: 8,
            dynamic_range: PlatformDynamicRange::Sdr,
            color_range: PlatformColorRange::Limited,
        },
        audio_channels: 8,
        enhanced_audio_quality: true,
        play_audio_on_host: false,
        virtual_display: true,
        encoder_csc_mode: 2,
        sink_hidpi: true,
        sink_scale_explicit: true,
        sink_mode_is_logical: true,
        sink_scale_percent: 200,
        sink_gamut: 2,
        sink_transfer: 1,
        sink_current_edr_headroom: 1.0,
        sink_potential_edr_headroom: 1.0,
        sink_current_peak_luminance_nits: 100,
        sink_potential_peak_luminance_nits: 100,
        sink_supports_frame_gated_hdr: false,
        sink_supports_hdr_tile_overlay: false,
        sink_supports_per_frame_hdr_metadata: false,
        negotiated_dynamic_range_transport: 1,
    };

    // When: the Rust plan is lowered to the C callback contract.
    let abi = LumenHostPlatformSessionPlan::from(plan);

    // Then: every selected format axis remains typed and exact.
    assert_eq!(abi.video_codec, LumenHostPlatformVideoCodec::Hevc);
    assert_eq!(abi.video_profile, LumenHostPlatformVideoProfile::HevcMain);
    assert_eq!(
        abi.chroma_subsampling,
        LumenHostPlatformChromaSubsampling::Yuv420
    );
    assert_eq!(abi.bit_depth, 8);
    assert_eq!(abi.dynamic_range, LumenHostPlatformDynamicRange::Sdr);
    assert_eq!(abi.color_range, LumenHostPlatformColorRange::Limited);
}

#[test]
fn exact_platform_format_has_a_stable_c_layout() {
    // Given: the nested exact-format and session-plan ABI types.
    // When: Rust computes their C representation.
    // Then: offsets match the checked-in C header contract.
    assert_eq!(size_of::<LumenHostPlatformSessionPlan>(), 88);
    assert_eq!(align_of::<LumenHostPlatformSessionPlan>(), 4);
    assert_eq!(offset_of!(LumenHostPlatformSessionPlan, video_codec), 16);
    assert_eq!(offset_of!(LumenHostPlatformSessionPlan, video_profile), 20);
    assert_eq!(
        offset_of!(LumenHostPlatformSessionPlan, chroma_subsampling),
        24
    );
    assert_eq!(offset_of!(LumenHostPlatformSessionPlan, bit_depth), 28);
    assert_eq!(offset_of!(LumenHostPlatformSessionPlan, dynamic_range), 32);
    assert_eq!(offset_of!(LumenHostPlatformSessionPlan, color_range), 36);
    assert_eq!(offset_of!(LumenHostPlatformSessionPlan, audio_channels), 40);
    assert_eq!(
        offset_of!(
            LumenHostPlatformSessionPlan,
            negotiated_dynamic_range_transport
        ),
        84
    );
}
