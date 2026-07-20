use prost::Message;

use super::{
    client_control_envelope, decode_client_control_message, decode_host_control_message,
    encode_client_control_message, encode_host_control_message, host_control_envelope,
    negotiate_native_session, ClientControlEnvelope, ClientSessionHello, HostControlEnvelope,
    HostSessionCapabilities, MediaPathChallenge, MediaPathResponse, MediaPathValidated,
    NativeAudioChannelMode, NativeAudioQuality, NativeChromaSubsampling, NativeColorRange,
    NativeControlWireError, NativeDisplayGamut, NativeDisplayTransfer, NativeDynamicRange,
    NativePolicyMode, NativeSessionError, NativeVideoCapability, NativeVideoCodec,
    NativeVideoFormat, NativeVideoKeyframeRequestReason, NativeVideoProfile, SessionStarted,
    VideoKeyframeRequest, NATIVE_VIDEO_STREAM_ID,
};

const V2_HELLO_ENVELOPE_BYTES: &[u8] = &[
    161, 1, 8, 7, 82, 156, 1, 8, 2, 16, 2, 32, 128, 30, 40, 240, 16, 48, 192, 169, 7, 58, 14, 8, 1,
    16, 8, 32, 128, 60, 40, 224, 33, 48, 128, 211, 14, 58, 16, 8, 2, 16, 10, 24, 1, 32, 128, 60,
    40, 224, 33, 48, 128, 211, 14, 64, 2, 72, 2, 80, 192, 11, 88, 128, 128, 128, 32, 98, 3, 2, 6,
    8, 104, 2, 114, 8, 100, 101, 118, 105, 99, 101, 45, 49, 122, 12, 97, 99, 99, 101, 115, 115, 45,
    116, 111, 107, 101, 110, 128, 1, 1, 144, 1, 128, 241, 4, 160, 1, 1, 168, 1, 1, 176, 1, 1, 184,
    1, 1, 192, 1, 200, 1, 200, 1, 2, 208, 1, 2, 221, 1, 154, 153, 25, 64, 229, 1, 0, 0, 128, 65,
    232, 1, 240, 1, 240, 1, 192, 12, 248, 1, 1, 136, 2, 1, 144, 2, 2, 152, 2, 3, 160, 2, 42,
];

const V2_PLAN_ENVELOPE_BYTES: &[u8] = &[
    141, 1, 8, 7, 82, 136, 1, 8, 2, 16, 132, 134, 136, 8, 32, 128, 30, 40, 240, 16, 48, 192, 169,
    7, 56, 2, 64, 10, 72, 2, 80, 2, 88, 248, 10, 96, 2, 104, 1, 112, 1, 120, 8, 128, 1, 136, 39,
    136, 1, 128, 241, 4, 144, 1, 200, 1, 152, 1, 2, 160, 1, 2, 173, 1, 154, 153, 25, 64, 181, 1, 0,
    0, 128, 65, 184, 1, 240, 1, 192, 1, 192, 12, 200, 1, 1, 216, 1, 1, 224, 1, 1, 232, 1, 3, 240,
    1, 1, 248, 1, 1, 128, 2, 1, 136, 2, 42, 144, 2, 8, 162, 2, 8, 0, 1, 2, 3, 4, 5, 6, 7, 168, 2,
    1, 176, 2, 2, 184, 2, 3, 192, 2, 1, 200, 2, 255, 1, 208, 2, 255, 1, 216, 2, 20,
];

fn capability(codec: NativeVideoCodec, bit_depth: u32, hdr10: bool) -> NativeVideoCapability {
    let profile = match (codec, bit_depth) {
        (NativeVideoCodec::H264, 8) => NativeVideoProfile::H264High,
        (NativeVideoCodec::Hevc, 8) => NativeVideoProfile::HevcMain,
        (NativeVideoCodec::Hevc, 10) => NativeVideoProfile::HevcMain10,
        (NativeVideoCodec::Av1, _) => NativeVideoProfile::Av1Main,
        _ => NativeVideoProfile::Unspecified,
    };
    capability_with_format(NativeVideoFormat {
        codec: codec as i32,
        profile: profile as i32,
        chroma_subsampling: NativeChromaSubsampling::Yuv420 as i32,
        bit_depth,
        dynamic_range: if hdr10 {
            NativeDynamicRange::Hdr10
        } else {
            NativeDynamicRange::Sdr
        } as i32,
        color_range: NativeColorRange::Limited as i32,
    })
}

fn capability_with_format(format: NativeVideoFormat) -> NativeVideoCapability {
    NativeVideoCapability {
        format: Some(format),
        max_width: 7_680,
        max_height: 4_320,
        max_refresh_millihz: 240_000,
        hardware_accelerated: Some(true),
    }
}

#[test]
fn generation_three_negotiates_each_exact_hardware_video_row() {
    // Given: five valid 4:2:0 and 4:4:4 codec/profile rows.
    let formats = [
        NativeVideoFormat {
            codec: NativeVideoCodec::H264 as i32,
            profile: NativeVideoProfile::H264High as i32,
            chroma_subsampling: NativeChromaSubsampling::Yuv420 as i32,
            bit_depth: 8,
            dynamic_range: NativeDynamicRange::Sdr as i32,
            color_range: NativeColorRange::Limited as i32,
        },
        NativeVideoFormat {
            codec: NativeVideoCodec::Hevc as i32,
            profile: NativeVideoProfile::HevcMain as i32,
            chroma_subsampling: NativeChromaSubsampling::Yuv420 as i32,
            bit_depth: 8,
            dynamic_range: NativeDynamicRange::Sdr as i32,
            color_range: NativeColorRange::Limited as i32,
        },
        NativeVideoFormat {
            codec: NativeVideoCodec::H264 as i32,
            profile: NativeVideoProfile::H264High444Predictive as i32,
            chroma_subsampling: NativeChromaSubsampling::Yuv444 as i32,
            bit_depth: 8,
            dynamic_range: NativeDynamicRange::Sdr as i32,
            color_range: NativeColorRange::Full as i32,
        },
        NativeVideoFormat {
            codec: NativeVideoCodec::Hevc as i32,
            profile: NativeVideoProfile::HevcMain444 as i32,
            chroma_subsampling: NativeChromaSubsampling::Yuv444 as i32,
            bit_depth: 8,
            dynamic_range: NativeDynamicRange::Sdr as i32,
            color_range: NativeColorRange::Full as i32,
        },
        NativeVideoFormat {
            codec: NativeVideoCodec::Hevc as i32,
            profile: NativeVideoProfile::HevcMain44410 as i32,
            chroma_subsampling: NativeChromaSubsampling::Yuv444 as i32,
            bit_depth: 10,
            dynamic_range: NativeDynamicRange::Hdr10 as i32,
            color_range: NativeColorRange::Limited as i32,
        },
    ];

    // When: each exact row is independently advertised by both peers and selected.
    let selected = formats.clone().map(|format| {
        let mut client = hello();
        client.sink_transfer = if format.dynamic_range == NativeDynamicRange::Hdr10 as i32 {
            NativeDisplayTransfer::Pq
        } else {
            NativeDisplayTransfer::Sdr
        } as i32;
        client.video_capabilities = vec![capability_with_format(format.clone())];
        client.requested_video_format = Some(format.clone());
        let mut host = host();
        host.video_capabilities = vec![capability_with_format(format)];
        negotiate_native_session(&client, &host, 9)
            .unwrap()
            .selected_video_capability
            .unwrap()
    });

    // Then: every plan returns the requested format, geometry, refresh, and hardware evidence.
    for (selected, format) in selected.iter().zip(formats) {
        assert_eq!(selected.format.as_ref(), Some(&format));
        assert_eq!((selected.max_width, selected.max_height), (3_840, 2_160));
        assert_eq!(selected.max_refresh_millihz, 120_000);
        assert_eq!(selected.hardware_accelerated, Some(true));
    }
}

#[test]
fn generation_three_rejects_missing_exact_format_presence_at_version_negotiation() {
    // Given: generation-three rows missing either the nested format or hardware presence.
    let mut missing_format = hello();
    missing_format.video_capabilities[0].format = None;
    let mut missing_hardware = hello();
    missing_hardware.video_capabilities[0].hardware_accelerated = None;

    // When: each malformed hello reaches the generation boundary.
    let results = [missing_format, missing_hardware]
        .map(|client| negotiate_native_session(&client, &host(), 1));

    // Then: both fail as stale protocol shapes before selection.
    assert!(results
        .into_iter()
        .all(|result| result == Err(NativeSessionError::UnsupportedProtocolVersion)));
}

#[test]
fn generation_three_rejects_exact_profile_chroma_or_range_mismatch_without_fallback() {
    // Given: a valid request whose only advertised client row differs on exact format axes.
    let requested = capability(NativeVideoCodec::H264, 8, false).format.unwrap();
    let mismatches = [
        NativeVideoFormat {
            profile: NativeVideoProfile::H264High444Predictive as i32,
            chroma_subsampling: NativeChromaSubsampling::Yuv444 as i32,
            color_range: NativeColorRange::Full as i32,
            ..requested.clone()
        },
        NativeVideoFormat {
            color_range: NativeColorRange::Full as i32,
            ..requested.clone()
        },
    ];

    // When: negotiation evaluates each nonidentical but valid advertised row.
    let results = mismatches.map(|mismatch| {
        let mut client = hello();
        client.requested_video_format = Some(requested.clone());
        client.video_capabilities = vec![capability_with_format(mismatch)];
        client.sink_transfer = NativeDisplayTransfer::Sdr as i32;
        negotiate_native_session(&client, &host(), 1)
    });

    // Then: no profile, chroma, or range axis is inferred or downgraded.
    assert!(results
        .into_iter()
        .all(|result| result == Err(NativeSessionError::UnsupportedVideoSelection)));
}

#[test]
fn generation_three_rejects_unknown_exact_format_enums() {
    // Given: one requested row whose profile discriminant is unknown to protocol v3.
    let mut client = hello();
    let requested = client.requested_video_format.as_mut().unwrap();
    requested.profile = 999;
    client.video_capabilities[1].format = Some(requested.clone());

    // When: the malformed exact row reaches negotiation.
    let result = negotiate_native_session(&client, &host(), 1);

    // Then: it is rejected at the versioned boundary instead of defaulting a profile.
    assert_eq!(result, Err(NativeSessionError::UnsupportedProtocolVersion));
}

#[test]
fn exact_selection_requires_one_matching_host_row_without_cross_products() {
    // Given: a client requesting HEVC Main10 while the host only has an H.264 row.
    let client = hello();
    let mut host = host();
    host.video_capabilities = vec![capability(NativeVideoCodec::H264, 8, false)];

    // When: negotiation intersects the exact row sets.
    let result = negotiate_native_session(&client, &host, 1);

    // Then: independent codec/profile/depth axes are not combined into a selection.
    assert_eq!(result, Err(NativeSessionError::UnsupportedVideoSelection));
}

#[test]
fn exact_selection_respects_both_client_and_host_geometry_limits() {
    // Given: otherwise exact rows whose client or host width is below the requested mode.
    let mut client_limited = hello();
    client_limited.video_capabilities[1].max_width = client_limited.width - 1;
    let mut host_limited = host();
    host_limited.video_capabilities[2].max_width = hello().width - 1;

    // When: each row set is negotiated independently.
    let results = [
        negotiate_native_session(&client_limited, &host(), 1),
        negotiate_native_session(&hello(), &host_limited, 1),
    ];

    // Then: either side's row bound rejects the mode without selecting a larger cross-product.
    assert!(results
        .into_iter()
        .all(|result| result == Err(NativeSessionError::InvalidDisplayMode)));
}

fn hello() -> ClientSessionHello {
    ClientSessionHello {
        minimum_protocol_version: 2,
        maximum_protocol_version: 2,
        width: 3_840,
        height: 2_160,
        refresh_millihz: 120_000,
        video_capabilities: vec![
            capability(NativeVideoCodec::H264, 8, false),
            capability(NativeVideoCodec::Hevc, 10, true),
        ],
        requested_policy: NativePolicyMode::Balanced as i32,
        maximum_datagram_payload: 1_472,
        receive_memory_bytes: 64 * 1024 * 1024,
        opus_channel_counts: vec![2, 6, 8],
        device_id: "device-1".to_owned(),
        access_token: "access-token".to_owned(),
        application_id: 1,
        resume: false,
        bitrate_kbps: 80_000,
        play_audio_on_host: false,
        virtual_display: true,
        sink_hidpi: true,
        sink_scale_explicit: true,
        sink_mode_is_logical: true,
        sink_scale_percent: 200,
        sink_gamut: NativeDisplayGamut::DisplayP3 as i32,
        sink_transfer: NativeDisplayTransfer::Pq as i32,
        sink_current_edr_headroom: 2.4,
        sink_potential_edr_headroom: 16.0,
        sink_current_peak_luminance_nits: 240,
        sink_potential_peak_luminance_nits: 1_600,
        sink_supports_frame_gated_hdr: true,
        sink_supports_hdr_tile_overlay: false,
        sink_supports_per_frame_hdr_metadata: true,
        requested_audio_quality: NativeAudioQuality::High as i32,
        requested_audio_channel_mode: NativeAudioChannelMode::Surround71 as i32,
        streaming_profile_revision: 42,
        requested_video_format: capability(NativeVideoCodec::Hevc, 10, true).format,
    }
}

#[test]
fn bounded_client_control_envelope_round_trips_one_typed_operation() {
    let envelope = ClientControlEnvelope {
        request_id: 7,
        payload: Some(client_control_envelope::Payload::MediaPath(
            MediaPathResponse {
                session_epoch: 0x0102_0304,
                path_id: 1,
                token: vec![0x44; 32],
            },
        )),
    };

    let encoded = encode_client_control_message(&envelope).unwrap();
    let decoded = decode_client_control_message(&encoded).unwrap();

    assert_eq!(decoded, envelope);
}

#[test]
fn video_keyframe_request_uses_collision_free_control_tag_fifteen() {
    let envelope = ClientControlEnvelope {
        request_id: 19,
        payload: Some(client_control_envelope::Payload::VideoKeyframeRequest(
            VideoKeyframeRequest {
                session_epoch: 0x0102_0304,
                stream_id: u32::from(NATIVE_VIDEO_STREAM_ID),
                after_frame_id: 77,
                reason: NativeVideoKeyframeRequestReason::IncompleteUnit as i32,
            },
        )),
    };

    let encoded = encode_client_control_message(&envelope).unwrap();

    assert_eq!(decode_client_control_message(&encoded).unwrap(), envelope);
    assert_eq!(encoded[3], 0x7a);
}

#[test]
fn bounded_host_control_envelope_round_trips_the_media_challenge() {
    let envelope = HostControlEnvelope {
        request_id: 8,
        payload: Some(host_control_envelope::Payload::MediaPath(
            MediaPathChallenge {
                session_epoch: 0x0102_0304,
                path_id: 1,
                media_port: 47_998,
                token: vec![0x55; 32],
            },
        )),
    };

    let encoded = encode_host_control_message(&envelope).unwrap();
    assert_eq!(decode_host_control_message(&encoded).unwrap(), envelope);
}

#[test]
fn bounded_host_control_envelope_round_trips_media_path_validation() {
    let envelope = HostControlEnvelope {
        request_id: 9,
        payload: Some(host_control_envelope::Payload::MediaPathValidated(
            MediaPathValidated {
                session_epoch: 0x0102_0304,
                path_id: 1,
            },
        )),
    };

    let encoded = encode_host_control_message(&envelope).unwrap();
    assert_eq!(decode_host_control_message(&encoded).unwrap(), envelope);
}

#[test]
fn bounded_host_control_envelope_round_trips_session_started() {
    let envelope = HostControlEnvelope {
        request_id: 10,
        payload: Some(host_control_envelope::Payload::SessionStarted(
            SessionStarted {
                session_epoch: 0x0102_0304,
            },
        )),
    };

    let encoded = encode_host_control_message(&envelope).unwrap();
    assert_eq!(decode_host_control_message(&encoded).unwrap(), envelope);
}

#[test]
fn control_decoder_rejects_empty_missing_trailing_and_oversized_frames() {
    assert_eq!(
        encode_client_control_message(&ClientControlEnvelope {
            request_id: 0,
            payload: None,
        }),
        Err(NativeControlWireError::InvalidEnvelope)
    );
    assert_eq!(
        decode_client_control_message(&[]),
        Err(NativeControlWireError::TruncatedLength)
    );
    assert_eq!(
        decode_client_control_message(&[1]),
        Err(NativeControlWireError::TruncatedMessage)
    );

    let envelope = ClientControlEnvelope {
        request_id: 9,
        payload: Some(client_control_envelope::Payload::Hello(hello())),
    };
    let mut encoded = encode_client_control_message(&envelope).unwrap();
    encoded.push(0);
    assert_eq!(
        decode_client_control_message(&encoded),
        Err(NativeControlWireError::TrailingBytes)
    );

    let mut oversized = vec![0x81, 0x80, 0x02];
    oversized.resize(32_772, 0);
    assert_eq!(
        decode_client_control_message(&oversized),
        Err(NativeControlWireError::MessageTooLarge)
    );
}

fn host() -> HostSessionCapabilities {
    HostSessionCapabilities {
        maximum_datagram_payload: 1_400,
        maximum_receive_memory_bytes: 128 * 1024 * 1024,
        video_capabilities: vec![
            capability(NativeVideoCodec::H264, 8, false),
            capability(NativeVideoCodec::Hevc, 8, false),
            capability(NativeVideoCodec::Hevc, 10, true),
            capability(NativeVideoCodec::Av1, 10, true),
        ],
        supported_opus_channel_counts: vec![2, 6, 8],
    }
}

#[test]
fn protobuf_hello_is_length_delimited_and_round_trips_exactly() {
    let hello = hello();
    let mut encoded = Vec::new();
    hello.encode_length_delimited(&mut encoded).unwrap();
    let decoded = ClientSessionHello::decode_length_delimited(encoded.as_slice()).unwrap();
    assert_eq!(decoded, hello);
}

#[test]
fn characterizes_generation_two_hello_and_plan_wire_bytes() {
    // Given: the pinned generation-two hello and plan bytes captured before the hard break.
    let hello = decode_client_control_message(V2_HELLO_ENVELOPE_BYTES).unwrap();
    let plan = decode_host_control_message(V2_PLAN_ENVELOPE_BYTES).unwrap();

    // When: the generation-three decoder projects the retired messages without defaults.
    let client_control_envelope::Payload::Hello(hello) = hello.payload.unwrap() else {
        panic!("generation-two fixture did not contain a hello");
    };
    let host_control_envelope::Payload::SessionPlan(plan) = plan.payload.unwrap() else {
        panic!("generation-two fixture did not contain a plan");
    };

    // Then: both fixtures retain version two and lack every required exact-format field.
    assert_eq!(
        (
            hello.minimum_protocol_version,
            hello.maximum_protocol_version
        ),
        (2, 2)
    );
    assert!(hello.requested_video_format.is_none());
    assert_eq!(plan.protocol_version, 2);
    assert!(plan.selected_video_capability.is_none());
}

#[test]
fn generation_three_golden_hello_and_plan_bytes_are_stable() {
    // Given: the canonical exact HEVC Main10 HDR hello and selected plan.
    let hello_fixture = hello();
    let hello_envelope = ClientControlEnvelope {
        request_id: 7,
        payload: Some(client_control_envelope::Payload::Hello(
            hello_fixture.clone(),
        )),
    };
    let plan_envelope = HostControlEnvelope {
        request_id: 7,
        payload: Some(host_control_envelope::Payload::SessionPlan(
            negotiate_native_session(&hello_fixture, &host(), 0x0102_0304).unwrap(),
        )),
    };

    // When: both protocol-three envelopes are encoded through production framing.
    let hello_bytes = encode_client_control_message(&hello_envelope).unwrap();
    let plan_bytes = encode_host_control_message(&plan_envelope).unwrap();
    assert_eq!(
        decode_client_control_message(&hello_bytes).unwrap(),
        hello_envelope
    );
    assert_eq!(
        decode_host_control_message(&plan_bytes).unwrap(),
        plan_envelope
    );

    // Then: both generations have deterministic byte-for-byte golden fixtures.
    assert_eq!(
        hello_bytes,
        vec![
            194, 1, 8, 7, 82, 189, 1, 8, 2, 16, 2, 32, 128, 30, 40, 240, 16, 48, 192, 169, 7, 58,
            26, 58, 12, 8, 1, 16, 2, 24, 1, 32, 8, 40, 1, 48, 1, 64, 128, 60, 72, 224, 33, 80, 128,
            211, 14, 88, 1, 58, 26, 58, 12, 8, 2, 16, 5, 24, 1, 32, 10, 40, 2, 48, 1, 64, 128, 60,
            72, 224, 33, 80, 128, 211, 14, 88, 1, 72, 2, 80, 192, 11, 88, 128, 128, 128, 32, 98, 3,
            2, 6, 8, 114, 8, 100, 101, 118, 105, 99, 101, 45, 49, 122, 12, 97, 99, 99, 101, 115,
            115, 45, 116, 111, 107, 101, 110, 128, 1, 1, 144, 1, 128, 241, 4, 160, 1, 1, 168, 1, 1,
            176, 1, 1, 184, 1, 1, 192, 1, 200, 1, 200, 1, 2, 208, 1, 2, 221, 1, 154, 153, 25, 64,
            229, 1, 0, 0, 128, 65, 232, 1, 240, 1, 240, 1, 192, 12, 248, 1, 1, 136, 2, 1, 144, 2,
            2, 152, 2, 3, 160, 2, 42, 170, 2, 12, 8, 2, 16, 5, 24, 1, 32, 10, 40, 2, 48, 1,
        ]
    );
    assert_eq!(
        plan_bytes,
        vec![
            164, 1, 8, 7, 82, 159, 1, 8, 2, 16, 132, 134, 136, 8, 32, 128, 30, 40, 240, 16, 48,
            192, 169, 7, 80, 2, 88, 248, 10, 96, 2, 104, 1, 112, 1, 120, 8, 128, 1, 136, 39, 136,
            1, 128, 241, 4, 144, 1, 200, 1, 152, 1, 2, 160, 1, 2, 173, 1, 154, 153, 25, 64, 181, 1,
            0, 0, 128, 65, 184, 1, 240, 1, 192, 1, 192, 12, 200, 1, 1, 216, 1, 1, 224, 1, 1, 232,
            1, 3, 240, 1, 1, 248, 1, 1, 128, 2, 1, 136, 2, 42, 144, 2, 8, 162, 2, 8, 0, 1, 2, 3, 4,
            5, 6, 7, 168, 2, 1, 176, 2, 2, 184, 2, 3, 192, 2, 1, 200, 2, 255, 1, 208, 2, 255, 1,
            216, 2, 20, 226, 2, 26, 58, 12, 8, 2, 16, 5, 24, 1, 32, 10, 40, 2, 48, 1, 64, 128, 30,
            72, 240, 16, 80, 192, 169, 7, 88, 1,
        ]
    );
    if let Some(directory) = std::env::var_os("LUMEN_PROTOCOL_GOLDEN_DIR") {
        let directory = std::path::PathBuf::from(directory);
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("v3-client-hello.bin"), &hello_bytes).unwrap();
        std::fs::write(directory.join("v3-host-plan.bin"), &plan_bytes).unwrap();
    }
}

#[test]
fn generation_three_rejects_legacy_hello_without_exact_video_format() {
    // Given: a byte-for-byte legacy hello without the generation-three exact format fields.
    let envelope = decode_client_control_message(V2_HELLO_ENVELOPE_BYTES).unwrap();
    let client_control_envelope::Payload::Hello(hello) = envelope.payload.unwrap() else {
        panic!("generation-two fixture did not contain a hello");
    };

    // When: the stale hello reaches session negotiation.
    let result = negotiate_native_session(&hello, &host(), 0x0102_0304);

    // Then: the exact-format generation fails before a session plan can be created.
    assert_eq!(result, Err(NativeSessionError::UnsupportedProtocolVersion));
}

#[test]
fn generation_three_rejects_loose_maximum_bit_depth_inference() {
    // Given: a capability that only implies ten-bit support through a loose maximum.
    let mut client = hello();
    client.video_capabilities[1]
        .format
        .as_mut()
        .unwrap()
        .bit_depth = 11;

    // When: the client requests the prior inferred HEVC HDR selection.
    let result = negotiate_native_session(&client, &host(), 0x0102_0304);

    // Then: negotiation requires an exact bit-depth row instead of maximum inference.
    assert_eq!(result, Err(NativeSessionError::UnsupportedProtocolVersion));
}

#[test]
fn negotiates_the_exact_account_selected_hevc_hdr_profile() {
    let plan = negotiate_native_session(&hello(), &host(), 0x0102_0304).unwrap();

    assert_eq!(plan.protocol_version, 2);
    assert_eq!(plan.session_epoch, 0x0102_0304);
    let selected_format = plan.selected_video_format().unwrap();
    assert_eq!(selected_format.codec, NativeVideoCodec::Hevc as i32);
    assert_eq!(
        selected_format.profile,
        NativeVideoProfile::HevcMain10 as i32
    );
    assert_eq!(selected_format.bit_depth, 10);
    assert_eq!(
        selected_format.dynamic_range,
        NativeDynamicRange::Hdr10 as i32
    );
    assert_eq!(plan.maximum_datagram_payload, 1_400);
    assert_eq!(plan.maximum_presentable_frames, 2);
    assert_eq!(plan.path_id, 1);
    assert_eq!(plan.policy_revision, 1);
    assert_eq!(plan.opus_channel_count, 8);
    assert_eq!(plan.opus_packet_duration_microseconds, 5_000);
    assert_eq!(plan.opus_stream_count, 8);
    assert_eq!(plan.opus_coupled_stream_count, 0);
    assert_eq!(plan.opus_mapping, vec![0, 1, 2, 3, 4, 5, 6, 7]);
    assert_eq!(plan.video_stream_id, 1);
    assert_eq!(plan.audio_stream_id, 2);
    assert_eq!(plan.input_motion_stream_id, 3);
    assert_eq!(plan.video_configuration_id, 1);
    assert_eq!(plan.maximum_data_shards, 255);
    assert_eq!(plan.maximum_parity_shards, 255);
    assert_eq!(plan.initial_parity_percentage, 20);
    assert_eq!(plan.bitrate_kbps, 80_000);
    assert_eq!(plan.sink_scale_percent, 200);
    assert_eq!(plan.sink_gamut, NativeDisplayGamut::DisplayP3 as i32);
    assert_eq!(plan.sink_transfer, NativeDisplayTransfer::Pq as i32);
    assert_eq!(
        plan.dynamic_range_transport,
        super::TRANSPORT_FRAME_GATED_HDR
    );
    assert!(plan.enhanced_audio_quality);
    assert_eq!(plan.streaming_profile_revision, 42);
}

#[test]
fn rejects_an_unsupported_selection_without_silent_fallback() {
    let mut client = hello();
    client.video_capabilities.truncate(1);
    assert_eq!(
        negotiate_native_session(&client, &host(), 7),
        Err(NativeSessionError::UnsupportedVideoSelection)
    );
}

#[test]
fn negotiates_optional_hevc_main_for_an_sdr_request() {
    let mut client = hello();
    client
        .video_capabilities
        .push(capability(NativeVideoCodec::Hevc, 8, false));
    client.requested_video_format = capability(NativeVideoCodec::Hevc, 8, false).format;
    client.sink_transfer = NativeDisplayTransfer::Sdr as i32;
    let plan = negotiate_native_session(&client, &host(), 8).unwrap();

    let selected_format = plan.selected_video_format().unwrap();
    assert_eq!(selected_format.codec, NativeVideoCodec::Hevc as i32);
    assert_eq!(selected_format.bit_depth, 8);
    assert_eq!(
        selected_format.dynamic_range,
        NativeDynamicRange::Sdr as i32
    );
}

#[test]
fn negotiates_explicit_av1_without_requiring_h264_capability() {
    let mut client = hello();
    client.video_capabilities = vec![capability(NativeVideoCodec::Av1, 10, true)];
    client.requested_video_format = capability(NativeVideoCodec::Av1, 10, true).format;
    let plan = negotiate_native_session(&client, &host(), 9).unwrap();
    let selected_format = plan.selected_video_format().unwrap();
    assert_eq!(selected_format.codec, NativeVideoCodec::Av1 as i32);
    assert_eq!(
        selected_format.dynamic_range,
        NativeDynamicRange::Hdr10 as i32
    );
}

#[test]
fn rejects_invalid_version_feature_datagram_and_memory_contracts() {
    let mut client = hello();
    client.maximum_protocol_version = 1;
    assert_eq!(
        negotiate_native_session(&client, &host(), 1),
        Err(NativeSessionError::UnsupportedProtocolVersion)
    );

    client = hello();
    client.maximum_datagram_payload = 1_199;
    assert_eq!(
        negotiate_native_session(&client, &host(), 1),
        Err(NativeSessionError::DatagramPayloadTooSmall)
    );

    client = hello();
    client.receive_memory_bytes = 0;
    assert_eq!(
        negotiate_native_session(&client, &host(), 1),
        Err(NativeSessionError::InvalidReceiveMemory)
    );

    client = hello();
    client.sink_scale_percent = 0;
    assert_eq!(
        negotiate_native_session(&client, &host(), 1),
        Err(NativeSessionError::InvalidPresentationContract)
    );

    client = hello();
    client.sink_transfer = NativeDisplayTransfer::Hlg as i32;
    assert_eq!(
        negotiate_native_session(&client, &host(), 1),
        Err(NativeSessionError::InvalidPresentationContract)
    );
}

#[test]
fn protobuf_authority_has_no_prores_or_media_fallback_contract() {
    let schema = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/protocol/lumen-streaming-v3.proto"
    ));
    assert!(schema.contains("package lumen.streaming.v3;"));
    assert!(!schema.to_ascii_lowercase().contains("prores"));
    assert!(!schema.contains("QUIC_DATAGRAM"));
    assert!(!schema.contains("media_fallback"));
}
