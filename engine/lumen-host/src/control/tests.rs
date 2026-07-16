use super::*;
use crate::{
    HostAuthorities, HostAuthorityPaths, PlatformApplicationPlan, PlatformRuntimeEvent,
    PlatformRuntimeEventCode, PlatformRuntimeEventDisposition, PlatformRuntimeEventSeverity,
    PlatformSessionPlan,
};
use lumen_engine::{
    client_control_envelope, host_control_envelope, ClientControlEnvelope, ClientSessionHello,
    CodecConfiguration, CodecConfigurationAck, HostSessionCapabilities, MediaPathResponse,
    NativeAudioChannelMode, NativeAudioQuality, NativeDisplayGamut, NativeDisplayTransfer,
    NativeDynamicRange, NativePolicyMode, NativeVideoCapability, NativeVideoCodec, StartSessionAck,
    StopSession,
};
use serde_json::{json, Value};
use std::fs;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

fn router() -> (tempfile::TempDir, ControlRouter) {
    router_with_platform(Arc::new(IdlePlatformSessionControl))
}

fn router_with_platform(
    platform: Arc<dyn PlatformSessionControl>,
) -> (tempfile::TempDir, ControlRouter) {
    router_with_discovery(platform, HostDiscoveryState::test_default())
}

fn router_with_discovery(
    platform: Arc<dyn PlatformSessionControl>,
    discovery: HostDiscoveryState,
) -> (tempfile::TempDir, ControlRouter) {
    let root = tempfile::tempdir().unwrap();
    let expires_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 3_600;
    fs::write(
        root.path().join("devices.json"),
        serde_json::to_vec(&json!({
            "version": 1,
            "devices": [{
                "id": "device-42",
                "name": "Tablet",
                "platform": "ios",
                "public_key": "test-public-key-material-that-is-long-enough",
                "refresh_token_hash": "unused-refresh-token-hash",
                "access_token_hash": "Pxa-1wifRlPl7yG_0oJNfzqq7MelmOfonFgOFgapzFI",
                "access_token_expires_at_unix_seconds": expires_at,
                "created_at_unix_seconds": 1,
                "revoked": false
            }]
        }))
        .unwrap(),
    )
    .unwrap();
    let paths = HostAuthorityPaths {
        settings: root.path().join("settings.json"),
        owner_account: root.path().join("owner-account.json"),
        devices: root.path().join("devices.json"),
        applications: root.path().join("apps.json"),
        host_identity: root.path().join("lumen-state.json"),
    };
    let authorities = HostAuthorities::open_native(paths).unwrap();
    (
        root,
        ControlRouter::new_with_platform(authorities, discovery, platform),
    )
}

#[derive(Default)]
struct RecordingPlatformSessionControl {
    starts: Mutex<Vec<PlatformSessionPlan>>,
    stops: AtomicUsize,
    application_starts: AtomicUsize,
    application_stops: AtomicUsize,
}

impl PlatformSessionControl for RecordingPlatformSessionControl {
    fn start_application(&self, _plan: PlatformApplicationPlan) -> Result<(), String> {
        self.application_starts.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }

    fn stop_application(&self) -> Result<(), String> {
        self.application_stops.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }

    fn start_session(&self, plan: PlatformSessionPlan) -> Result<(), String> {
        self.starts.lock().unwrap().push(plan);
        Ok(())
    }

    fn stop_session(&self) -> Result<(), String> {
        self.stops.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }
}

#[derive(Default)]
struct FailingPlatformSessionControl {
    runtime_events: Mutex<Vec<PlatformRuntimeEvent>>,
}

impl PlatformSessionControl for FailingPlatformSessionControl {
    fn start_session(&self, _plan: PlatformSessionPlan) -> Result<(), String> {
        Err("screen recording permission denied".to_owned())
    }

    fn stop_session(&self) -> Result<(), String> {
        Ok(())
    }

    fn publish_runtime_event(&self, event: PlatformRuntimeEvent) -> Result<(), String> {
        self.runtime_events.lock().unwrap().push(event);
        Ok(())
    }
}

fn authorized(method: ControlMethod, path: &str) -> ControlRequest {
    let mut request = ControlRequest::new(method, path);
    request.headers = vec![
        ("aUtHoRiZaTiOn".into(), "bEaReR access-token".into()),
        ("lUmEn-DeViCe-Id".into(), "device-42".into()),
    ];
    request
}

fn body(response: &ControlResponse) -> Value {
    serde_json::from_slice(&response.body).unwrap()
}

fn local_peer() -> IpAddr {
    IpAddr::V4(Ipv4Addr::LOCALHOST)
}

fn native_hello(application_id: u32) -> ClientSessionHello {
    ClientSessionHello {
        minimum_protocol_version: 2,
        maximum_protocol_version: 2,
        required_features: 0,
        width: 3_840,
        height: 2_160,
        refresh_millihz: 120_000,
        video_capabilities: vec![NativeVideoCapability {
            codec: NativeVideoCodec::Hevc as i32,
            max_bit_depth: 8,
            supports_hdr10: false,
            max_width: 3_840,
            max_height: 2_160,
            max_refresh_millihz: 120_000,
        }],
        requested_dynamic_range: NativeDynamicRange::Sdr as i32,
        requested_policy: NativePolicyMode::UltraLatency as i32,
        maximum_datagram_payload: 1_200,
        receive_memory_bytes: 64 * 1024 * 1024,
        opus_channel_counts: vec![2],
        requested_video_codec: NativeVideoCodec::Hevc as i32,
        device_id: "device-42".to_owned(),
        access_token: "access-token".to_owned(),
        application_id,
        resume: false,
        bitrate_kbps: 80_000,
        play_audio_on_host: false,
        virtual_display: true,
        sink_hidpi: true,
        sink_scale_explicit: true,
        sink_mode_is_logical: true,
        sink_scale_percent: 200,
        sink_gamut: NativeDisplayGamut::DisplayP3 as i32,
        sink_transfer: NativeDisplayTransfer::Sdr as i32,
        sink_current_edr_headroom: 1.0,
        sink_potential_edr_headroom: 1.0,
        sink_current_peak_luminance_nits: 100,
        sink_potential_peak_luminance_nits: 100,
        sink_supports_frame_gated_hdr: false,
        sink_supports_hdr_tile_overlay: false,
        sink_supports_per_frame_hdr_metadata: false,
        requested_audio_quality: NativeAudioQuality::High as i32,
        requested_audio_channel_mode: NativeAudioChannelMode::Stereo as i32,
        streaming_profile_revision: 1,
    }
}

fn native_context() -> NativeConnectionContext {
    NativeConnectionContext {
        peer_address: local_peer(),
        session_epoch: 0x0102_0304,
        media_port: 47_998,
        media_challenge: [0x55; 32],
        media_key: [0x66; 16],
        host_capabilities: HostSessionCapabilities {
            supported_features: 0,
            maximum_width: 7_680,
            maximum_height: 4_320,
            maximum_refresh_millihz: 240_000,
            maximum_datagram_payload: 1_200,
            maximum_receive_memory_bytes: 128 * 1024 * 1024,
            supports_h264: true,
            supports_hevc_main: true,
            supports_hevc_main10: false,
            supports_av1_main: false,
            supports_av1_main10: false,
            supports_hdr10: false,
            supported_opus_channel_counts: vec![2, 6, 8],
        },
    }
}

#[test]
fn native_hello_authenticates_negotiates_and_requires_the_exact_udp_path() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, mut router) = router_with_platform(platform.clone());
    router
        .authorities()
        .applications()
        .upsert(r#"{"uuid":"native-desktop","name":"Desktop"}"#)
        .unwrap();
    let application_id = router.authorities().applications().applications().unwrap()[0].id;
    let context = native_context();
    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 7,
            payload: Some(client_control_envelope::Payload::Hello(native_hello(
                application_id,
            ))),
        },
        &context,
    );

    assert_eq!(responses.len(), 2);
    let plan = match responses[0].payload.as_ref().unwrap() {
        host_control_envelope::Payload::SessionPlan(plan) => plan,
        _ => panic!("expected native session plan"),
    };
    assert_eq!(plan.session_epoch, context.session_epoch);
    assert_eq!(plan.video_codec, NativeVideoCodec::Hevc as i32);
    let challenge = match responses[1].payload.as_ref().unwrap() {
        host_control_envelope::Payload::MediaPath(challenge) => challenge,
        _ => panic!("expected native media challenge"),
    };
    assert_eq!(challenge.media_port, u32::from(context.media_port));
    assert_eq!(challenge.token, context.media_challenge);

    let endpoint = SocketAddr::new(context.peer_address, 52_000);
    assert!(!router.observe_native_media_path(endpoint, context.session_epoch, 1, &[0x44; 32],));
    assert!(!router.observe_native_media_path(
        SocketAddr::new("192.168.0.99".parse().unwrap(), 52_000),
        context.session_epoch,
        1,
        &context.media_challenge,
    ));
    assert!(router.observe_native_media_path(
        endpoint,
        context.session_epoch,
        1,
        &context.media_challenge,
    ));
    assert_eq!(router.pending_native_media_endpoint(), Some(endpoint));
    assert_eq!(
        router.pending_native_media_key(context.session_epoch),
        Some(context.media_key)
    );
    assert!(!router.pending_native_media_is_validated());

    let validation = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 8,
            payload: Some(client_control_envelope::Payload::MediaPath(
                MediaPathResponse {
                    session_epoch: context.session_epoch,
                    path_id: 1,
                    token: context.media_challenge.to_vec(),
                },
            )),
        },
        &context,
    );
    assert!(matches!(
        validation[0].payload,
        Some(host_control_envelope::Payload::MediaPathValidated(_))
    ));
    assert!(router.pending_native_media_is_validated());

    let started = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 9,
            payload: Some(client_control_envelope::Payload::StartSession(
                StartSessionAck {
                    session_epoch: context.session_epoch,
                },
            )),
        },
        &context,
    );
    assert!(matches!(
        started[0].payload,
        Some(host_control_envelope::Payload::SessionStarted(_))
    ));
    assert_eq!(platform.application_starts.load(Ordering::Relaxed), 1);
    assert_eq!(platform.starts.lock().unwrap().len(), 1);
    let platform_plan = platform.starts.lock().unwrap()[0];
    assert_eq!(platform_plan.width, 3_840);
    assert_eq!(platform_plan.height, 2_160);
    assert_eq!(platform_plan.frames_per_second, 120);
    assert_eq!(platform_plan.bitrate_kbps, 80_000);
    assert_eq!(platform_plan.sink_scale_percent, 200);
    let video_delivery = router.video_delivery_state().unwrap();
    assert_eq!(video_delivery.session_epoch, context.session_epoch);
    assert_eq!(video_delivery.endpoint, endpoint);
    assert_eq!(video_delivery.encryption_key, context.media_key);
    assert_eq!(video_delivery.acknowledged_configuration_id, None);
    let configuration = CodecConfiguration {
        session_epoch: context.session_epoch,
        stream_id: plan.video_stream_id,
        configuration_id: plan.video_configuration_id,
        codec: plan.video_codec,
        decoder_configuration_record: vec![1, 2, 3, 4],
    };
    assert!(router.publish_native_codec_configuration(configuration.clone()));
    let premature_ack = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 10,
            payload: Some(client_control_envelope::Payload::CodecConfigurationAck(
                CodecConfigurationAck {
                    session_epoch: context.session_epoch,
                    stream_id: plan.video_stream_id,
                    configuration_id: plan.video_configuration_id,
                },
            )),
        },
        &context,
    );
    assert!(matches!(
        premature_ack[0].payload,
        Some(host_control_envelope::Payload::Error(_))
    ));
    assert_eq!(
        router.take_native_codec_configuration(context.session_epoch),
        Some(configuration)
    );
    let accepted_ack = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 11,
            payload: Some(client_control_envelope::Payload::CodecConfigurationAck(
                CodecConfigurationAck {
                    session_epoch: context.session_epoch,
                    stream_id: plan.video_stream_id,
                    configuration_id: plan.video_configuration_id,
                },
            )),
        },
        &context,
    );
    assert!(accepted_ack.is_empty());
    assert_eq!(
        router
            .video_delivery_state()
            .unwrap()
            .acknowledged_configuration_id,
        Some(plan.video_configuration_id)
    );
    let audio_delivery = router.audio_delivery_state().unwrap();
    assert_eq!(audio_delivery.endpoint, endpoint);
    assert_eq!(audio_delivery.encryption_key, context.media_key);

    let conflict = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 12,
            payload: Some(client_control_envelope::Payload::Hello(native_hello(
                application_id,
            ))),
        },
        &context,
    );
    assert!(matches!(
        conflict[0].payload,
        Some(host_control_envelope::Payload::Error(_))
    ));

    let stopped = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 13,
            payload: Some(client_control_envelope::Payload::StopSession(StopSession {
                session_epoch: context.session_epoch,
            })),
        },
        &context,
    );
    assert!(matches!(
        stopped[0].payload,
        Some(host_control_envelope::Payload::SessionStopped(_))
    ));
    assert_eq!(platform.stops.load(Ordering::Relaxed), 1);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 1);
    assert!(router.video_delivery_state().is_none());
    assert!(router.audio_delivery_state().is_none());
}

#[test]
fn native_start_returns_the_platform_failure_and_publishes_a_typed_runtime_error() {
    let platform = Arc::new(FailingPlatformSessionControl::default());
    let (_root, mut router) = router_with_platform(platform.clone());
    router
        .authorities()
        .applications()
        .upsert(r#"{"uuid":"native-desktop","name":"Desktop"}"#)
        .unwrap();
    let application_id = router.authorities().applications().applications().unwrap()[0].id;
    let context = native_context();
    let hello = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 7,
            payload: Some(client_control_envelope::Payload::Hello(native_hello(
                application_id,
            ))),
        },
        &context,
    );
    let host_control_envelope::Payload::SessionPlan(plan) = hello[0].payload.as_ref().unwrap()
    else {
        panic!("expected native session plan");
    };
    let endpoint = SocketAddr::new(context.peer_address, 52_000);
    assert!(router.observe_native_media_path(
        endpoint,
        context.session_epoch,
        plan.path_id as u16,
        &context.media_challenge,
    ));
    let path = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 8,
            payload: Some(client_control_envelope::Payload::MediaPath(
                MediaPathResponse {
                    session_epoch: context.session_epoch,
                    path_id: plan.path_id,
                    token: context.media_challenge.to_vec(),
                },
            )),
        },
        &context,
    );
    assert!(matches!(
        path[0].payload,
        Some(host_control_envelope::Payload::MediaPathValidated(_))
    ));

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 9,
            payload: Some(client_control_envelope::Payload::StartSession(
                StartSessionAck {
                    session_epoch: context.session_epoch,
                },
            )),
        },
        &context,
    );

    let host_control_envelope::Payload::Error(error) = responses[0].payload.as_ref().unwrap()
    else {
        panic!("expected native platform error");
    };
    assert_eq!(error.code, 7);
    assert_eq!(
        error.message,
        "platform stream session could not be started: screen recording permission denied"
    );
    assert_eq!(
        *platform.runtime_events.lock().unwrap(),
        vec![PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Error,
            code: PlatformRuntimeEventCode::NativeSessionPlatform,
            message: Some(
                "platform stream session could not be started: screen recording permission denied"
                    .to_owned(),
            ),
        }]
    );
}

#[test]
fn native_hello_rejects_bad_device_credentials_before_negotiation() {
    let (_root, mut router) = router();
    router
        .authorities()
        .applications()
        .upsert(r#"{"uuid":"native-desktop","name":"Desktop"}"#)
        .unwrap();
    let application_id = router.authorities().applications().applications().unwrap()[0].id;
    let mut hello = native_hello(application_id);
    hello.access_token = "wrong-token".to_owned();

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 9,
            payload: Some(client_control_envelope::Payload::Hello(hello)),
        },
        &native_context(),
    );

    match responses[0].payload.as_ref().unwrap() {
        host_control_envelope::Payload::Error(error) => assert_eq!(error.code, 2),
        _ => panic!("expected authentication error"),
    }
    assert_eq!(router.pending_native_media_endpoint(), None);
}

#[test]
fn routes_all_versioned_auth_operations_with_strict_json_transport() {
    let (_root, mut router) = router();
    for path in [
        "/api/v1/auth/enrollment-challenge",
        "/api/v1/auth/enroll",
        "/api/v1/auth/token-challenge",
        "/api/v1/auth/token",
        "/api/v1/auth/revoke",
    ] {
        let mut request = ControlRequest::new(ControlMethod::Post, path);
        request.headers.push((
            "Content-Type".into(),
            "application/json; charset=utf-8".into(),
        ));
        request.body = br#"{}"#.to_vec();
        let response = router.dispatch(&request);
        assert_eq!(response.status_code, 400, "{path}");
        assert_eq!(body(&response)["error"]["code"], "invalid-request");
        assert_eq!(response.cache_control, "no-store");
    }

    let mut wrong_type =
        ControlRequest::new(ControlMethod::Post, "/api/v1/auth/enrollment-challenge");
    wrong_type
        .headers
        .push(("Content-Type".into(), "text/plain".into()));
    assert_eq!(router.dispatch(&wrong_type).status_code, 400);
}

#[test]
fn enforces_one_case_insensitive_bearer_and_device_header() {
    let (_root, mut router) = router();
    let response = router.dispatch(&authorized(ControlMethod::Get, "/api/v1/settings"));
    assert_eq!(response.status_code, 200);
    assert_eq!(body(&response)["schemaVersion"], 1);

    let missing = ControlRequest::new(ControlMethod::Get, "/api/v1/settings");
    let response = router.dispatch(&missing);
    assert_eq!(response.status_code, 401);
    assert_eq!(
        body(&response)["error"]["code"],
        "invalid-device-credential"
    );

    let mut duplicate = authorized(ControlMethod::Get, "/api/v1/settings");
    duplicate
        .headers
        .push(("authorization".into(), "Bearer duplicate".into()));
    assert_eq!(router.dispatch(&duplicate).status_code, 400);

    let mut cookie = authorized(ControlMethod::Get, "/api/v1/settings");
    cookie.headers.push(("Cookie".into(), "auth=secret".into()));
    assert_eq!(router.dispatch(&cookie).status_code, 400);
}

#[test]
fn dispatches_snapshot_patch_and_resumable_events_through_one_authority() {
    let (_root, mut router) = router();
    let snapshot = router.dispatch(&authorized(ControlMethod::Get, "/api/v1/settings"));
    assert_eq!(snapshot.status_code, 200);
    let revision = body(&snapshot)["revision"].as_u64().unwrap();

    let mut patch = authorized(ControlMethod::Patch, "/api/v1/settings");
    patch
        .headers
        .push(("Content-Type".into(), "application/json".into()));
    patch.body = serde_json::to_vec(&json!({
        "schemaVersion": 1,
        "baseRevision": revision,
        "requestId": "router-1",
        "changes": {"general": {"name": "Rust Host"}}
    }))
    .unwrap();
    let patched = router.dispatch(&patch);
    assert_eq!(
        patched.status_code,
        200,
        "{}",
        String::from_utf8_lossy(&patched.body)
    );
    assert_eq!(body(&patched)["effective"]["general"]["name"], "Rust Host");

    let mut events = authorized(ControlMethod::Get, "/api/v1/settings/events");
    events
        .query
        .push(("afterRevision".into(), revision.to_string()));
    let events = router.dispatch(&events);
    assert_eq!(events.status_code, 200);
    assert_eq!(body(&events)["afterRevision"], revision);
    assert_eq!(body(&events)["events"].as_array().unwrap().len(), 1);
}

#[test]
fn rejects_oversized_duplicate_and_authentication_query_transports() {
    let (_root, mut router) = router();
    let mut oversized = authorized(ControlMethod::Patch, "/api/v1/settings");
    oversized
        .headers
        .push(("Content-Type".into(), "application/json".into()));
    oversized.body = vec![b'x'; MAXIMUM_JSON_REQUEST_BYTES + 1];
    assert_eq!(router.dispatch(&oversized).status_code, 400);

    let mut duplicate = authorized(ControlMethod::Get, "/api/v1/settings/events");
    duplicate.query = vec![
        ("afterRevision".into(), "1".into()),
        ("afterrevision".into(), "0".into()),
    ];
    assert_eq!(router.dispatch(&duplicate).status_code, 400);

    let mut query_token = authorized(ControlMethod::Get, "/api/v1/settings");
    query_token
        .query
        .push(("accessToken".into(), "secret".into()));
    let response = router.dispatch(&query_token);
    assert_eq!(response.status_code, 400);
    assert_eq!(body(&response)["error"]["code"], "invalid-request");
}

#[test]
fn serves_the_authenticated_application_catalog_from_the_rust_authority() {
    let (_root, mut router) = router();
    router
        .authorities()
        .applications()
        .upsert(
            r#"{
                "uuid":"20B27694-B7F6-8D27-F513-406EA3DAC42B",
                "name":"Desktop",
                "image-path":"desktop.png"
            }"#,
        )
        .unwrap();

    let response = router.dispatch(&authorized(ControlMethod::Get, "/api/discovery/apps"));
    assert_eq!(response.status_code, 200);
    let payload = body(&response);
    assert_eq!(payload["status"], true);
    assert_eq!(payload["apps"].as_array().unwrap().len(), 1);
    assert!(payload["apps"][0]["id"].as_u64().unwrap() > 0);
    assert_eq!(
        payload["apps"][0]["uuid"],
        "20B27694-B7F6-8D27-F513-406EA3DAC42B"
    );
    assert_eq!(payload["apps"][0]["title"], "Desktop");
    assert_eq!(payload["apps"][0]["hdrSupported"], true);
    assert_eq!(payload["apps"][0]["isAppCollectorGame"], false);
    assert_eq!(payload["currentApp"], "");
    assert!(!payload["hostUUID"].as_str().unwrap().is_empty());
    assert_eq!(payload["name"], "Lumen");
    assert!(payload.get("hostName").is_none());
}

#[test]
fn serves_the_authenticated_lumen_host_descriptor_from_rust_state() {
    let (_root, mut router) = router();
    let response = router.dispatch(&authorized(ControlMethod::Get, "/api/discovery/host"));
    assert_eq!(response.status_code, 200);
    let payload = body(&response);
    assert_eq!(payload["status"], true);
    assert_eq!(payload["host"]["name"], "Lumen");
    assert!(payload["host"].get("displayName").is_none());
    assert_eq!(payload["host"]["wakeOnLan"]["supported"], false);
    assert!(payload["host"]["wakeOnLan"].get("macAddress").is_none());
    assert!(payload["host"]["wakeOnLan"].get("udpPort").is_none());
    assert_eq!(payload["host"]["deviceAuthentication"], "ready");
    assert_eq!(payload["host"]["currentGameID"], 0);
    assert_eq!(payload["host"]["serverState"], "LUMEN_SERVER_FREE");
    assert_eq!(payload["host"]["sessionQuicPort"], 48_010);
    assert_eq!(payload["host"]["directMediaUdpPort"], 47_998);
    assert_eq!(payload["host"]["controlHttpsPort"], 47_990);
    assert!(!payload["host"]["serverUniqueId"]
        .as_str()
        .unwrap()
        .is_empty());
    assert_eq!(payload["host"]["serviceType"], "_lumen._udp");
    assert_eq!(payload["host"]["serverCodecModeSupport"], 0);
    assert_eq!(payload["host"]["clientCertificateRequired"], false);
    assert_eq!(payload["host"]["audioCapabilities"]["schemaVersion"], 1);
    assert_eq!(
        payload["host"]["audioCapabilities"]["channelModes"],
        serde_json::json!(["stereo", "5.1", "7.1"])
    );
    assert_eq!(
        payload["host"]["audioCapabilities"]["enhancedAudioQuality"],
        true
    );
    assert_eq!(payload["host"]["audioCapabilities"]["sampleRate"], 48_000);
    assert_eq!(
        payload["host"]["audioCapabilities"]["packetDurationMilliseconds"],
        5
    );
    assert_eq!(
        payload["host"]["audioCapabilities"]["opusApplication"],
        "restricted-low-delay"
    );
    assert_eq!(
        payload["host"]["audioCapabilities"]["variableBitrate"],
        false
    );

    let unauthorized = ControlRequest::new(ControlMethod::Get, "/api/discovery/host");
    assert_eq!(router.dispatch(&unauthorized).status_code, 401);
}

#[test]
fn serves_a_normalized_automatic_wake_on_lan_target_when_the_active_nic_is_safe() {
    let discovery = HostDiscoveryState::test_with_wake_on_lan([0x02, 0x1a, 0x2b, 0x3c, 0x4d, 0x5e]);
    let (_root, mut router) =
        router_with_discovery(Arc::new(IdlePlatformSessionControl), discovery);

    let response = router.dispatch(&authorized(ControlMethod::Get, "/api/discovery/host"));

    assert_eq!(response.status_code, 200);
    assert_eq!(
        body(&response)["host"]["wakeOnLan"],
        json!({
            "supported": true,
            "macAddress": "02:1A:2B:3C:4D:5E",
            "udpPort": 9
        })
    );
}
