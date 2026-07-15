use prost::Message;

use super::{
    client_control_envelope, decode_client_control_message, decode_host_control_message,
    encode_client_control_message, encode_host_control_message, host_control_envelope,
    negotiate_native_session, ClientControlEnvelope, ClientSessionHello, HostControlEnvelope,
    HostSessionCapabilities, MediaPathChallenge, MediaPathResponse, MediaPathValidated,
    NativeAudioChannelMode, NativeAudioQuality, NativeControlWireError, NativeDisplayGamut,
    NativeDisplayTransfer, NativeDynamicRange, NativePolicyMode, NativeSessionError,
    NativeVideoCapability, NativeVideoCodec, SessionStarted,
};

fn capability(
    codec: NativeVideoCodec,
    max_bit_depth: u32,
    supports_hdr10: bool,
) -> NativeVideoCapability {
    NativeVideoCapability {
        codec: codec as i32,
        max_bit_depth,
        supports_hdr10,
        max_width: 7_680,
        max_height: 4_320,
        max_refresh_millihz: 240_000,
    }
}

fn hello() -> ClientSessionHello {
    ClientSessionHello {
        minimum_protocol_version: 2,
        maximum_protocol_version: 2,
        required_features: 0,
        width: 3_840,
        height: 2_160,
        refresh_millihz: 120_000,
        video_capabilities: vec![
            capability(NativeVideoCodec::H264, 8, false),
            capability(NativeVideoCodec::Hevc, 10, true),
        ],
        requested_dynamic_range: NativeDynamicRange::Hdr10 as i32,
        requested_policy: NativePolicyMode::Balanced as i32,
        maximum_datagram_payload: 1_472,
        receive_memory_bytes: 64 * 1024 * 1024,
        opus_channel_counts: vec![2, 6, 8],
        requested_video_codec: NativeVideoCodec::Hevc as i32,
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
        supported_features: 0,
        maximum_width: 6_016,
        maximum_height: 3_384,
        maximum_refresh_millihz: 240_000,
        maximum_datagram_payload: 1_400,
        maximum_receive_memory_bytes: 128 * 1024 * 1024,
        supports_h264: true,
        supports_hevc_main: true,
        supports_hevc_main10: true,
        supports_av1_main: true,
        supports_av1_main10: true,
        supports_hdr10: true,
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
fn negotiates_the_exact_account_selected_hevc_hdr_profile() {
    let plan = negotiate_native_session(&hello(), &host(), 0x0102_0304).unwrap();

    assert_eq!(plan.protocol_version, 2);
    assert_eq!(plan.session_epoch, 0x0102_0304);
    assert_eq!(plan.video_codec, NativeVideoCodec::Hevc as i32);
    assert_eq!(plan.bit_depth, 10);
    assert_eq!(plan.dynamic_range, NativeDynamicRange::Hdr10 as i32);
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
    client.requested_dynamic_range = NativeDynamicRange::Sdr as i32;
    client.sink_transfer = NativeDisplayTransfer::Sdr as i32;
    let plan = negotiate_native_session(&client, &host(), 8).unwrap();

    assert_eq!(plan.video_codec, NativeVideoCodec::Hevc as i32);
    assert_eq!(plan.bit_depth, 8);
    assert_eq!(plan.dynamic_range, NativeDynamicRange::Sdr as i32);
}

#[test]
fn negotiates_explicit_av1_without_requiring_h264_capability() {
    let mut client = hello();
    client.video_capabilities = vec![capability(NativeVideoCodec::Av1, 10, true)];
    client.requested_video_codec = NativeVideoCodec::Av1 as i32;
    let plan = negotiate_native_session(&client, &host(), 9).unwrap();
    assert_eq!(plan.video_codec, NativeVideoCodec::Av1 as i32);
    assert_eq!(plan.dynamic_range, NativeDynamicRange::Hdr10 as i32);
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
    client.required_features = 1;
    assert_eq!(
        negotiate_native_session(&client, &host(), 1),
        Err(NativeSessionError::UnsupportedRequiredFeatures)
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
        "/../../docs/protocol/lumen-streaming-v2.proto"
    ));
    assert!(schema.contains("package lumen.streaming.v2;"));
    assert!(!schema.to_ascii_lowercase().contains("prores"));
    assert!(!schema.contains("QUIC_DATAGRAM"));
    assert!(!schema.contains("media_fallback"));
}
