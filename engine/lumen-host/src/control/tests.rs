use super::native_session::NativeMediaFeedbackRejection;
use super::*;
use crate::{
    HostAuthorities, HostAuthorityPaths, PlatformApplicationPlan, PlatformControlEvent,
    PlatformRuntimeEvent, PlatformSessionPlan,
};
use lumen_engine::{
    client_control_envelope, host_control_envelope, ClientControlEnvelope, ClientSessionHello,
    CodecConfiguration, CodecConfigurationAck, DisplayReconfigurationRequest,
    HostSessionCapabilities, HostSessionPlan, MediaFeedback, NativeAudioChannelMode,
    NativeAudioQuality, NativeChromaSubsampling, NativeColorRange, NativeDisplayGamut,
    NativeDisplayReconfigurationResultCode, NativeDisplayTransfer, NativeDynamicRange,
    NativeNegotiationFailure, NativePolicyMode, NativeVideoBootstrapReason,
    NativeVideoBootstrapResultCode, NativeVideoCapability, NativeVideoCodec, NativeVideoFormat,
    NativeVideoKeyframeRequestReason, NativeVideoProfile, StartSessionAck, VideoBootstrapResult,
    VideoKeyframeRequest, NATIVE_PROTOCOL_VERSION, NATIVE_REQUIRED_MEDIA_CAPABILITIES,
};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::fs;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

fn router() -> (tempfile::TempDir, ControlRouter) {
    router_with_platform(Arc::new(IdlePlatformSessionControl))
}

pub(crate) fn router_with_platform(
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
pub(crate) struct RecordingPlatformSessionControl {
    starts: Mutex<Vec<PlatformSessionPlan>>,
    reconfigurations: Mutex<Vec<PlatformSessionPlan>>,
    stops: AtomicUsize,
    application_starts: AtomicUsize,
    application_stops: AtomicUsize,
    control_events: Mutex<Vec<(u32, PlatformControlEvent)>>,
}

impl RecordingPlatformSessionControl {
    pub(crate) fn stop_count(&self) -> usize {
        self.stops.load(Ordering::Relaxed)
    }

    pub(crate) fn application_stop_count(&self) -> usize {
        self.application_stops.load(Ordering::Relaxed)
    }

    pub(crate) fn control_events(&self) -> Vec<(u32, PlatformControlEvent)> {
        self.control_events.lock().unwrap().clone()
    }
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

    fn reconfigure_session(&self, plan: PlatformSessionPlan) -> Result<(), String> {
        self.reconfigurations.lock().unwrap().push(plan);
        Ok(())
    }

    fn handle_control_event(
        &self,
        session_epoch: u32,
        event: PlatformControlEvent,
    ) -> Result<(), String> {
        self.control_events
            .lock()
            .unwrap()
            .push((session_epoch, event));
        Ok(())
    }

    fn handle_native_input(
        &self,
        _session_epoch: u32,
        _event: crate::PlatformNativeInputEvent,
    ) -> Result<(), String> {
        Ok(())
    }

    fn handle_native_motion(
        &self,
        _session_epoch: u32,
        _event: crate::PlatformNativeMotionEvent,
    ) -> Result<(), String> {
        Ok(())
    }
}

#[derive(Default)]
struct FailingPlatformSessionControl {
    runtime_events: Mutex<Vec<PlatformRuntimeEvent>>,
    stops: AtomicUsize,
}

pub(crate) struct RetryingCleanupPlatformSessionControl {
    start_result: Result<(), String>,
    stop_results: Mutex<VecDeque<Result<(), String>>>,
    application_stop_results: Mutex<VecDeque<Result<(), String>>>,
    stops: AtomicUsize,
    application_stops: AtomicUsize,
}

impl RetryingCleanupPlatformSessionControl {
    pub(crate) fn new(stop_results: impl IntoIterator<Item = Result<(), String>>) -> Self {
        Self {
            start_result: Ok(()),
            stop_results: Mutex::new(stop_results.into_iter().collect()),
            application_stop_results: Mutex::new(VecDeque::new()),
            stops: AtomicUsize::new(0),
            application_stops: AtomicUsize::new(0),
        }
    }

    fn with_start_failure(
        start_error: impl Into<String>,
        stop_results: impl IntoIterator<Item = Result<(), String>>,
    ) -> Self {
        Self {
            start_result: Err(start_error.into()),
            stop_results: Mutex::new(stop_results.into_iter().collect()),
            application_stop_results: Mutex::new(VecDeque::new()),
            stops: AtomicUsize::new(0),
            application_stops: AtomicUsize::new(0),
        }
    }

    fn with_application_stop_results(
        stop_results: impl IntoIterator<Item = Result<(), String>>,
        application_stop_results: impl IntoIterator<Item = Result<(), String>>,
    ) -> Self {
        Self {
            start_result: Ok(()),
            stop_results: Mutex::new(stop_results.into_iter().collect()),
            application_stop_results: Mutex::new(application_stop_results.into_iter().collect()),
            stops: AtomicUsize::new(0),
            application_stops: AtomicUsize::new(0),
        }
    }

    pub(crate) fn stop_count(&self) -> usize {
        self.stops.load(Ordering::Relaxed)
    }

    pub(crate) fn application_stop_count(&self) -> usize {
        self.application_stops.load(Ordering::Relaxed)
    }
}

impl PlatformSessionControl for RetryingCleanupPlatformSessionControl {
    fn start_application(&self, _plan: PlatformApplicationPlan) -> Result<(), String> {
        Ok(())
    }

    fn stop_application(&self) -> Result<(), String> {
        self.application_stops.fetch_add(1, Ordering::Relaxed);
        self.application_stop_results
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(Ok(()))
    }

    fn start_session(&self, _plan: PlatformSessionPlan) -> Result<(), String> {
        self.start_result.clone()
    }

    fn stop_session(&self) -> Result<(), String> {
        self.stops.fetch_add(1, Ordering::Relaxed);
        self.stop_results
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(Ok(()))
    }
}

impl PlatformSessionControl for FailingPlatformSessionControl {
    fn start_session(&self, _plan: PlatformSessionPlan) -> Result<(), String> {
        Err("screen recording permission denied".to_owned())
    }

    fn stop_session(&self) -> Result<(), String> {
        self.stops.fetch_add(1, Ordering::Relaxed);
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

pub(crate) fn native_hello(application_id: u32) -> ClientSessionHello {
    let requested_video_format = NativeVideoFormat {
        codec: NativeVideoCodec::Hevc as i32,
        profile: NativeVideoProfile::HevcMain as i32,
        chroma_subsampling: NativeChromaSubsampling::Yuv420 as i32,
        bit_depth: 8,
        dynamic_range: NativeDynamicRange::Sdr as i32,
        color_range: NativeColorRange::Limited as i32,
    };
    ClientSessionHello {
        minimum_protocol_version: NATIVE_PROTOCOL_VERSION,
        maximum_protocol_version: NATIVE_PROTOCOL_VERSION,
        width: 3_840,
        height: 2_160,
        refresh_millihz: 120_000,
        video_capabilities: vec![NativeVideoCapability {
            format: Some(requested_video_format.clone()),
            max_width: 3_840,
            max_height: 2_160,
            max_refresh_millihz: 120_000,
            hardware_accelerated: Some(true),
        }],
        requested_policy: NativePolicyMode::UltraLatency as i32,
        maximum_datagram_payload: 1_200,
        receive_memory_bytes: 64 * 1024 * 1024,
        opus_channel_counts: vec![2],
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
        requested_video_format: Some(requested_video_format),
        media_capabilities: NATIVE_REQUIRED_MEDIA_CAPABILITIES,
    }
}

fn native_context() -> NativeConnectionContext {
    NativeConnectionContext {
        session_epoch: 0x0102_0304,
        host_capabilities: HostSessionCapabilities {
            maximum_datagram_payload: 1_200,
            maximum_receive_memory_bytes: 128 * 1024 * 1024,
            video_capabilities: native_hello(1).video_capabilities,
            supported_opus_channel_counts: vec![2, 6, 8],
        },
    }
}

fn started_native_router(
    platform: Arc<dyn PlatformSessionControl>,
) -> (
    tempfile::TempDir,
    ControlRouter,
    NativeConnectionContext,
    HostSessionPlan,
) {
    let (root, mut router) = router_with_platform(platform);
    router
        .authorities()
        .applications()
        .upsert(r#"{"uuid":"native-desktop","name":"Desktop"}"#)
        .unwrap();
    let application_id = router.authorities().applications().applications().unwrap()[0].id;
    let context = native_context();
    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 1,
            payload: Some(client_control_envelope::Payload::Hello(native_hello(
                application_id,
            ))),
        },
        &context,
    );
    let host_control_envelope::Payload::SessionPlan(plan) = responses[0].payload.clone().unwrap()
    else {
        panic!("expected native session plan");
    };
    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 2,
            payload: Some(client_control_envelope::Payload::StartSession(
                StartSessionAck {
                    session_epoch: context.session_epoch,
                },
            )),
        },
        &context,
    );
    assert!(matches!(
        responses[0].payload,
        Some(host_control_envelope::Payload::SessionStarted(_))
    ));
    (root, router, context, plan)
}

fn configured_native_router(
    platform: Arc<dyn PlatformSessionControl>,
) -> (
    tempfile::TempDir,
    ControlRouter,
    NativeConnectionContext,
    HostSessionPlan,
) {
    let (root, mut router, context, plan) = started_native_router(platform);
    let configuration = CodecConfiguration {
        session_epoch: context.session_epoch,
        stream_id: plan.video_stream_id,
        configuration_id: plan.video_configuration_id,
        codec: plan.selected_video_format().unwrap().codec,
        decoder_configuration_record: vec![1, 2, 3, 4],
    };
    assert!(router.publish_native_codec_configuration(configuration.clone()));
    assert_eq!(
        router.take_native_codec_configuration(context.session_epoch),
        Some(configuration)
    );
    assert!(router
        .dispatch_native_control(
            ClientControlEnvelope {
                request_id: 3,
                payload: Some(client_control_envelope::Payload::CodecConfigurationAck(
                    CodecConfigurationAck {
                        session_epoch: context.session_epoch,
                        stream_id: plan.video_stream_id,
                        configuration_id: plan.video_configuration_id,
                    },
                )),
            },
            &context,
        )
        .is_empty());
    (root, router, context, plan)
}

#[test]
fn native_v4_hello_negotiates_without_a_direct_udp_path_exchange() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, router, context, plan) = started_native_router(platform.clone());

    assert_eq!(plan.protocol_version, NATIVE_PROTOCOL_VERSION);
    assert_eq!(plan.session_epoch, context.session_epoch);
    assert_eq!(plan.maximum_datagram_payload, 1_200);
    assert!(plan.maximum_object_delay_us > 0);
    assert!(router.video_delivery_state().is_some());
    assert!(router.audio_delivery_state().is_some());
    assert_eq!(platform.starts.lock().unwrap().len(), 1);
}

#[test]
fn native_v4_reconfigures_display_without_stopping_the_active_session() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, mut router, context, initial) = started_native_router(platform.clone());

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 3,
            payload: Some(client_control_envelope::Payload::DisplayReconfiguration(
                DisplayReconfigurationRequest {
                    session_epoch: context.session_epoch,
                    revision: 7,
                    width: 2_160,
                    height: 3_840,
                    refresh_millihz: 120_000,
                    sink_hidpi: true,
                    sink_scale_explicit: true,
                    sink_mode_is_logical: true,
                    sink_scale_percent: 200,
                },
            )),
        },
        &context,
    );

    let Some(host_control_envelope::Payload::DisplayReconfiguration(result)) =
        responses[0].payload.as_ref()
    else {
        panic!("expected display reconfiguration result");
    };
    assert_eq!(
        NativeDisplayReconfigurationResultCode::try_from(result.result).unwrap(),
        NativeDisplayReconfigurationResultCode::Applied
    );
    assert_eq!(result.revision, 7);
    assert_eq!(result.plan.as_ref().unwrap().encoded_width, 2_160);
    assert_eq!(result.plan.as_ref().unwrap().encoded_height, 3_840);
    assert!(result.plan.as_ref().unwrap().video_configuration_id > initial.video_configuration_id);
    assert_eq!(platform.reconfigurations.lock().unwrap().len(), 1);
    assert_eq!(platform.stop_count(), 0);
    assert!(router.video_delivery_state().is_some());
}

#[test]
fn failed_stop_is_retained_for_disconnect_cleanup_retry() {
    let platform = Arc::new(RetryingCleanupPlatformSessionControl::new([
        Err("workspace recovery remains pending".to_owned()),
        Ok(()),
    ]));
    let (_root, mut router, context, _plan) = started_native_router(platform.clone());

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 3,
            payload: Some(client_control_envelope::Payload::StopSession(
                lumen_engine::StopSession {
                    session_epoch: context.session_epoch,
                },
            )),
        },
        &context,
    );

    let Some(host_control_envelope::Payload::Error(error)) = responses[0].payload.as_ref() else {
        panic!("expected the first cleanup failure");
    };
    assert_eq!(error.message, "platform session cleanup failed");
    assert!(router.video_delivery_state().is_none());

    assert_eq!(
        router.terminate_native_connection(context.session_epoch),
        Ok(())
    );
    assert!(router.video_delivery_state().is_none());
    assert_eq!(platform.stops.load(Ordering::Relaxed), 2);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 1);
}

#[test]
fn next_hello_retries_incomplete_disconnect_cleanup_before_negotiation() {
    let platform = Arc::new(RetryingCleanupPlatformSessionControl::new([
        Err("workspace recovery remains pending".to_owned()),
        Ok(()),
    ]));
    let (_root, mut router, context, _plan) = started_native_router(platform.clone());
    let application_id = router.authorities().applications().applications().unwrap()[0].id;

    assert!(router
        .terminate_native_connection(context.session_epoch)
        .is_err());
    let next_context = NativeConnectionContext {
        session_epoch: context.session_epoch + 1,
        host_capabilities: context.host_capabilities.clone(),
    };
    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 4,
            payload: Some(client_control_envelope::Payload::Hello(native_hello(
                application_id,
            ))),
        },
        &next_context,
    );

    assert!(matches!(
        responses[0].payload,
        Some(host_control_envelope::Payload::SessionPlan(_))
    ));
    assert_eq!(platform.stops.load(Ordering::Relaxed), 2);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 1);
}

#[test]
fn unauthenticated_hello_cannot_retry_retained_cleanup() {
    let platform = Arc::new(RetryingCleanupPlatformSessionControl::new([
        Err("workspace recovery remains pending".to_owned()),
        Ok(()),
    ]));
    let (_root, mut router, context, _plan) = started_native_router(platform.clone());
    let application_id = router.authorities().applications().applications().unwrap()[0].id;
    assert!(router
        .terminate_native_connection(context.session_epoch)
        .is_err());
    let mut hello = native_hello(application_id);
    hello.access_token = "invalid-access-token".to_owned();

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 4,
            payload: Some(client_control_envelope::Payload::Hello(hello)),
        },
        &NativeConnectionContext {
            session_epoch: context.session_epoch + 1,
            host_capabilities: context.host_capabilities.clone(),
        },
    );

    let Some(host_control_envelope::Payload::Error(error)) = responses[0].payload.as_ref() else {
        panic!("expected authentication rejection");
    };
    assert_eq!(error.code, 2);
    assert_eq!(platform.stops.load(Ordering::Relaxed), 1);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 1);
}

#[test]
fn different_application_hello_cannot_retry_retained_cleanup() {
    let platform = Arc::new(RetryingCleanupPlatformSessionControl::new([
        Err("workspace recovery remains pending".to_owned()),
        Ok(()),
    ]));
    let (_root, mut router, context, _plan) = started_native_router(platform.clone());
    router
        .authorities()
        .applications()
        .upsert(r#"{"uuid":"other-native-desktop","name":"Other Desktop"}"#)
        .unwrap();
    let different_application_id = router
        .authorities()
        .applications()
        .applications()
        .unwrap()
        .into_iter()
        .find(|application| application.uuid == "other-native-desktop")
        .unwrap()
        .id;
    assert!(router
        .terminate_native_connection(context.session_epoch)
        .is_err());

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 4,
            payload: Some(client_control_envelope::Payload::Hello(native_hello(
                different_application_id,
            ))),
        },
        &NativeConnectionContext {
            session_epoch: context.session_epoch + 1,
            host_capabilities: context.host_capabilities.clone(),
        },
    );

    let Some(host_control_envelope::Payload::Error(error)) = responses[0].payload.as_ref() else {
        panic!("expected retained owner rejection");
    };
    assert_eq!(error.code, 5);
    assert_eq!(platform.stops.load(Ordering::Relaxed), 1);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 1);
}

#[test]
fn force_stop_retries_cleanup_without_losing_native_ownership() {
    let platform = Arc::new(RetryingCleanupPlatformSessionControl::new([
        Err("workspace recovery remains pending".to_owned()),
        Ok(()),
    ]));
    let (_root, mut router, _context, _plan) = started_native_router(platform.clone());

    assert_eq!(
        router.force_stop_stream(),
        Err("workspace recovery remains pending".to_owned())
    );
    assert_eq!(router.force_stop_stream(), Ok(()));
    assert_eq!(platform.stops.load(Ordering::Relaxed), 2);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 1);
}

#[test]
fn force_stop_does_not_duplicate_retained_application_cleanup() {
    let platform = Arc::new(
        RetryingCleanupPlatformSessionControl::with_application_stop_results(
            [Ok(())],
            [
                Err("application teardown remains pending".to_owned()),
                Ok(()),
            ],
        ),
    );
    let (_root, mut router, _context, _plan) = started_native_router(platform.clone());

    assert_eq!(
        router.force_stop_stream(),
        Err("application teardown remains pending".to_owned())
    );
    assert_eq!(platform.stops.load(Ordering::Relaxed), 1);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 1);

    assert_eq!(router.force_stop_stream(), Ok(()));
    assert_eq!(router.force_stop_stream(), Ok(()));
    assert_eq!(platform.stops.load(Ordering::Relaxed), 1);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 2);
}

#[test]
fn failed_application_stop_retries_only_the_remaining_cleanup() {
    let platform = Arc::new(
        RetryingCleanupPlatformSessionControl::with_application_stop_results(
            [Ok(())],
            [
                Err("application teardown remains pending".to_owned()),
                Ok(()),
            ],
        ),
    );
    let (_root, mut router, context, _plan) = started_native_router(platform.clone());

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 3,
            payload: Some(client_control_envelope::Payload::StopSession(
                lumen_engine::StopSession {
                    session_epoch: context.session_epoch,
                },
            )),
        },
        &context,
    );

    assert!(matches!(
        responses[0].payload,
        Some(host_control_envelope::Payload::Error(_))
    ));
    assert!(router.video_delivery_state().is_none());
    assert_eq!(
        router.terminate_native_connection(context.session_epoch),
        Ok(())
    );
    assert_eq!(platform.stops.load(Ordering::Relaxed), 1);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 2);
}

#[test]
fn failed_start_rollback_is_retained_for_disconnect_cleanup_retry() {
    let platform = Arc::new(RetryingCleanupPlatformSessionControl::with_start_failure(
        "capture publication failed",
        [Err("workspace recovery remains pending".to_owned()), Ok(())],
    ));
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
            request_id: 1,
            payload: Some(client_control_envelope::Payload::Hello(native_hello(
                application_id,
            ))),
        },
        &context,
    );
    assert!(matches!(
        hello[0].payload,
        Some(host_control_envelope::Payload::SessionPlan(_))
    ));

    let start = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 2,
            payload: Some(client_control_envelope::Payload::StartSession(
                StartSessionAck {
                    session_epoch: context.session_epoch,
                },
            )),
        },
        &context,
    );
    let Some(host_control_envelope::Payload::Error(error)) = start[0].payload.as_ref() else {
        panic!("expected the platform start failure");
    };
    assert!(error.message.contains("platform session rollback failed"));

    assert_eq!(
        router.terminate_native_connection(context.session_epoch),
        Ok(())
    );
    assert_eq!(platform.stops.load(Ordering::Relaxed), 2);
    assert_eq!(platform.application_stops.load(Ordering::Relaxed), 1);
}

#[test]
fn decoded_bootstraps_resume_only_the_generation_that_owns_encoder_admission() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, mut router, context, plan) = configured_native_router(platform.clone());

    assert_eq!(
        router
            .video_delivery_state()
            .unwrap()
            .acknowledged_generation_id,
        None
    );
    let generation_id = router
        .publish_native_video_bootstrap(
            plan.video_configuration_id,
            1,
            900,
            NativeVideoBootstrapReason::Initial,
            true,
            vec![9, 8, 7],
        )
        .unwrap();
    let bootstrap = router
        .take_native_video_bootstrap(context.session_epoch)
        .unwrap();
    assert_eq!(bootstrap.generation_id, generation_id);
    assert_eq!(bootstrap.frame_id, 1);
    assert_eq!(
        router
            .video_delivery_state()
            .unwrap()
            .acknowledged_generation_id,
        None
    );

    assert!(router
        .dispatch_native_control(
            ClientControlEnvelope {
                request_id: 4,
                payload: Some(client_control_envelope::Payload::VideoBootstrapResult(
                    VideoBootstrapResult {
                        session_epoch: context.session_epoch,
                        stream_id: plan.video_stream_id,
                        configuration_id: plan.video_configuration_id,
                        generation_id,
                        frame_id: 1,
                        result: NativeVideoBootstrapResultCode::Decoded as i32,
                        message: String::new(),
                    },
                ),),
            },
            &context,
        )
        .is_empty());
    assert_eq!(
        router
            .video_delivery_state()
            .unwrap()
            .acknowledged_generation_id,
        Some(generation_id)
    );
    assert_eq!(
        platform
            .control_events
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, event)| {
                *event == PlatformControlEvent::ResumeVideoEncodingAfterCodecAck
            })
            .count(),
        1
    );
    assert!(router.observe_native_video_frame_sent(context.session_epoch, 120));
    assert!(router
        .dispatch_native_control(
            ClientControlEnvelope {
                request_id: 5,
                payload: Some(client_control_envelope::Payload::VideoKeyframeRequest(
                    VideoKeyframeRequest {
                        session_epoch: context.session_epoch,
                        stream_id: plan.video_stream_id,
                        after_frame_id: 120,
                        reason: NativeVideoKeyframeRequestReason::DecoderRecovery as i32,
                        generation_id,
                    },
                )),
            },
            &context,
        )
        .is_empty());
    assert!(router.native_video_keyframe_request_is_outstanding());

    let periodic_generation = router
        .publish_native_video_bootstrap(
            plan.video_configuration_id,
            121,
            90_900,
            NativeVideoBootstrapReason::Periodic,
            false,
            vec![6, 5, 4],
        )
        .unwrap();
    let periodic = router
        .take_native_video_bootstrap(context.session_epoch)
        .unwrap();
    assert_eq!(
        NativeVideoBootstrapReason::try_from(periodic.reason),
        Ok(NativeVideoBootstrapReason::Periodic)
    );
    assert!(router
        .dispatch_native_control(
            ClientControlEnvelope {
                request_id: 6,
                payload: Some(client_control_envelope::Payload::VideoBootstrapResult(
                    VideoBootstrapResult {
                        session_epoch: context.session_epoch,
                        stream_id: plan.video_stream_id,
                        configuration_id: plan.video_configuration_id,
                        generation_id: periodic_generation,
                        frame_id: 121,
                        result: NativeVideoBootstrapResultCode::Decoded as i32,
                        message: String::new(),
                    },
                )),
            },
            &context,
        )
        .is_empty());
    assert_eq!(
        router
            .video_delivery_state()
            .unwrap()
            .acknowledged_generation_id,
        Some(periodic_generation)
    );
    assert_eq!(
        platform
            .control_events
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, event)| {
                *event == PlatformControlEvent::ResumeVideoEncodingAfterCodecAck
            })
            .count(),
        1
    );
    assert!(router.native_video_keyframe_request_is_outstanding());

    let repair_generation = router
        .publish_native_video_bootstrap(
            plan.video_configuration_id,
            122,
            91_800,
            NativeVideoBootstrapReason::Repair,
            true,
            vec![3, 2, 1],
        )
        .unwrap();
    let repair = router
        .take_native_video_bootstrap(context.session_epoch)
        .unwrap();
    assert_eq!(
        NativeVideoBootstrapReason::try_from(repair.reason),
        Ok(NativeVideoBootstrapReason::Repair)
    );
    assert!(router
        .dispatch_native_control(
            ClientControlEnvelope {
                request_id: 7,
                payload: Some(client_control_envelope::Payload::VideoBootstrapResult(
                    VideoBootstrapResult {
                        session_epoch: context.session_epoch,
                        stream_id: plan.video_stream_id,
                        configuration_id: plan.video_configuration_id,
                        generation_id: repair_generation,
                        frame_id: 122,
                        result: NativeVideoBootstrapResultCode::Decoded as i32,
                        message: String::new(),
                    },
                )),
            },
            &context,
        )
        .is_empty());
    assert!(!router.native_video_keyframe_request_is_outstanding());
    assert_eq!(
        platform
            .control_events
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, event)| {
                *event == PlatformControlEvent::ResumeVideoEncodingAfterCodecAck
            })
            .count(),
        2
    );
}

#[test]
fn decoder_rejected_bootstrap_returns_a_typed_platform_error_and_keeps_deltas_closed() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, mut router, context, plan) = configured_native_router(platform);
    let generation_id = router
        .publish_native_video_bootstrap(
            plan.video_configuration_id,
            1,
            900,
            NativeVideoBootstrapReason::Initial,
            true,
            vec![9, 8, 7],
        )
        .unwrap();
    assert!(router
        .take_native_video_bootstrap(context.session_epoch)
        .is_some());

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 4,
            payload: Some(client_control_envelope::Payload::VideoBootstrapResult(
                VideoBootstrapResult {
                    session_epoch: context.session_epoch,
                    stream_id: plan.video_stream_id,
                    configuration_id: plan.video_configuration_id,
                    generation_id,
                    frame_id: 1,
                    result: NativeVideoBootstrapResultCode::DecoderRejected as i32,
                    message: "hardware decoder rejected bootstrap".to_owned(),
                },
            )),
        },
        &context,
    );

    let Some(host_control_envelope::Payload::Error(error)) = responses[0].payload.as_ref() else {
        panic!("expected typed bootstrap rejection");
    };
    assert_eq!(error.code, 7);
    assert_eq!(error.message, "hardware decoder rejected bootstrap");
    assert_eq!(
        router
            .video_delivery_state()
            .unwrap()
            .acknowledged_generation_id,
        None
    );
}

#[test]
fn stale_generation_keyframe_request_is_ignored_without_reopening_the_encoder() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, mut router, context, plan) = configured_native_router(platform.clone());
    let generation_id = router
        .publish_native_video_bootstrap(
            plan.video_configuration_id,
            1,
            900,
            NativeVideoBootstrapReason::Initial,
            true,
            vec![9, 8, 7],
        )
        .unwrap();
    assert!(router
        .take_native_video_bootstrap(context.session_epoch)
        .is_some());
    assert!(router
        .dispatch_native_control(
            ClientControlEnvelope {
                request_id: 4,
                payload: Some(client_control_envelope::Payload::VideoBootstrapResult(
                    VideoBootstrapResult {
                        session_epoch: context.session_epoch,
                        stream_id: plan.video_stream_id,
                        configuration_id: plan.video_configuration_id,
                        generation_id,
                        frame_id: 1,
                        result: NativeVideoBootstrapResultCode::Decoded as i32,
                        message: String::new(),
                    },
                ),),
            },
            &context,
        )
        .is_empty());
    assert!(router.observe_native_video_frame_sent(context.session_epoch, 2));

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 5,
            payload: Some(client_control_envelope::Payload::VideoKeyframeRequest(
                VideoKeyframeRequest {
                    session_epoch: context.session_epoch,
                    stream_id: plan.video_stream_id,
                    after_frame_id: 2,
                    reason: NativeVideoKeyframeRequestReason::DecoderRecovery as i32,
                    generation_id: generation_id + 1,
                },
            )),
        },
        &context,
    );

    assert!(responses.is_empty());
    assert!(!router.native_video_keyframe_request_is_outstanding());
}

#[test]
fn newer_bootstrap_replaces_an_obsolete_unacknowledged_generation() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, mut router, context, plan) = configured_native_router(platform.clone());
    let first_generation = router
        .publish_native_video_bootstrap(
            plan.video_configuration_id,
            1,
            900,
            NativeVideoBootstrapReason::Initial,
            true,
            vec![1, 2, 3],
        )
        .unwrap();
    assert!(router
        .take_native_video_bootstrap(context.session_epoch)
        .is_some());
    let second_generation = router
        .publish_native_video_bootstrap(
            plan.video_configuration_id,
            2,
            1_800,
            NativeVideoBootstrapReason::Repair,
            true,
            vec![4, 5, 6],
        )
        .unwrap();
    assert!(second_generation > first_generation);
    assert_eq!(
        router.native_video_bootstrap_generation(context.session_epoch),
        Some(second_generation)
    );
    let replacement = router
        .take_native_video_bootstrap(context.session_epoch)
        .unwrap();
    assert_eq!(replacement.generation_id, second_generation);

    let stale = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 5,
            payload: Some(client_control_envelope::Payload::VideoBootstrapResult(
                VideoBootstrapResult {
                    session_epoch: context.session_epoch,
                    stream_id: plan.video_stream_id,
                    configuration_id: plan.video_configuration_id,
                    generation_id: first_generation,
                    frame_id: 1,
                    result: NativeVideoBootstrapResultCode::Decoded as i32,
                    message: String::new(),
                },
            )),
        },
        &context,
    );
    assert!(stale.is_empty());
    assert!(!router.native_video_bootstrap_is_acknowledged(context.session_epoch, first_generation));
    assert!(platform.control_events.lock().unwrap().is_empty());

    let current = ClientControlEnvelope {
        request_id: 6,
        payload: Some(client_control_envelope::Payload::VideoBootstrapResult(
            VideoBootstrapResult {
                session_epoch: context.session_epoch,
                stream_id: plan.video_stream_id,
                configuration_id: plan.video_configuration_id,
                generation_id: second_generation,
                frame_id: 2,
                result: NativeVideoBootstrapResultCode::Decoded as i32,
                message: String::new(),
            },
        )),
    };
    assert!(router
        .dispatch_native_control(current.clone(), &context)
        .is_empty());
    assert_eq!(platform.control_events.lock().unwrap().len(), 1);

    let duplicate = router.dispatch_native_control(current, &context);
    assert!(duplicate.is_empty());
    assert_eq!(platform.control_events.lock().unwrap().len(), 1);
}

#[test]
fn media_feedback_uses_audio_pressure_to_adapt_video_delivery_without_reducing_cadence() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, mut router, context, plan) = started_native_router(platform);
    let initial = router.video_delivery_state().unwrap();

    let audio_feedback = MediaFeedback {
        stream_id: plan.audio_stream_id,
        highest_datagram_sequence: 3,
        received_datagrams: 3,
        unrecoverable_objects: 2,
        late_objects: 1,
        decoder_queue_depth: 8,
        presentation_drops: 2,
        window_milliseconds: 250,
        first_datagram_sequence: 1,
        ..MediaFeedback::default()
    };
    let audio_decision = router
        .observe_native_media_feedback(&audio_feedback, context.session_epoch)
        .unwrap();
    let NativeMediaFeedbackDisposition::Applied(audio_decision) = audio_decision else {
        panic!("audio playback pressure must reduce the video budget");
    };
    assert!(audio_decision.changed);
    assert_eq!(audio_decision.congestion_source, CongestionSource::Audio);
    let audio_adapted = router.video_delivery_state().unwrap();
    assert!(audio_adapted.target_bitrate_kbps < initial.target_bitrate_kbps);
    assert_eq!(audio_adapted.admission_divisor, 1);

    let congested_feedback = MediaFeedback {
        stream_id: plan.video_stream_id,
        highest_datagram_sequence: 200,
        received_datagrams: 100,
        recovered_shards: 0,
        unrecoverable_objects: 100,
        late_objects: 0,
        reordered_datagrams: 0,
        estimated_jitter_us: 4_000,
        decoder_queue_depth: 3,
        presentation_drops: 1,
        window_milliseconds: 250,
        first_datagram_sequence: 1,
    };
    let video_decision = router
        .observe_native_media_feedback(&congested_feedback, context.session_epoch)
        .unwrap();
    assert!(matches!(
        video_decision,
        NativeMediaFeedbackDisposition::Applied(_)
    ));
    let adapted = router.video_delivery_state().unwrap();
    assert_eq!(
        adapted.fec_percentage,
        (audio_adapted.fec_percentage + 5).min(30)
    );
    assert!(adapted.target_bitrate_kbps < audio_adapted.target_bitrate_kbps);
    assert_eq!(adapted.admission_divisor, 1);

    let wrong_stream = MediaFeedback {
        stream_id: u32::MAX,
        window_milliseconds: 250,
        ..MediaFeedback::default()
    };
    assert_eq!(
        router.observe_native_media_feedback(&wrong_stream, context.session_epoch),
        Err(NativeMediaFeedbackRejection::StreamMismatch)
    );

    let nonempty_zero_duration = MediaFeedback {
        stream_id: plan.audio_stream_id,
        received_datagrams: 1,
        ..MediaFeedback::default()
    };
    assert_eq!(
        router.observe_native_media_feedback(&nonempty_zero_duration, context.session_epoch),
        Err(NativeMediaFeedbackRejection::WindowDurationMismatch)
    );

    let reversed_range = MediaFeedback {
        stream_id: plan.audio_stream_id,
        highest_datagram_sequence: 3,
        first_datagram_sequence: 4,
        window_milliseconds: 250,
        ..MediaFeedback::default()
    };
    assert_eq!(
        router.observe_native_media_feedback(&reversed_range, context.session_epoch),
        Err(NativeMediaFeedbackRejection::InvalidSequenceRange)
    );
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
    assert!(matches!(
        hello[0].payload,
        Some(host_control_envelope::Payload::SessionPlan(_))
    ));

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 8,
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
    assert_eq!(platform.stops.load(Ordering::Relaxed), 1);
    assert!(router.video_delivery_state().is_none());
}

#[test]
fn generation_three_hello_is_rejected_before_pending_session_mutation() {
    let platform = Arc::new(RecordingPlatformSessionControl::default());
    let (_root, mut router) = router_with_platform(platform.clone());
    router
        .authorities()
        .applications()
        .upsert(r#"{"uuid":"native-desktop","name":"Desktop"}"#)
        .unwrap();
    let application_id = router.authorities().applications().applications().unwrap()[0].id;
    let context = native_context();
    let mut hello = native_hello(application_id);
    hello.minimum_protocol_version = 3;
    hello.maximum_protocol_version = 3;

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 77,
            payload: Some(client_control_envelope::Payload::Hello(hello)),
        },
        &context,
    );

    let Some(host_control_envelope::Payload::Error(error)) = responses[0].payload.as_ref() else {
        panic!("stale hello did not return a typed protocol error");
    };
    assert_eq!(
        error.negotiation_failure,
        NativeNegotiationFailure::UnsupportedProtocolVersion as i32
    );
    assert_eq!(
        error.message,
        "protocol version 4 is not in the client offer"
    );
    assert!(router.video_delivery_state().is_none());
    assert_eq!(platform.starts.lock().unwrap().len(), 0);
}

#[test]
fn malformed_exact_video_row_is_not_misreported_as_a_protocol_version_error() {
    let (_root, mut router) = router();
    router
        .authorities()
        .applications()
        .upsert(r#"{"uuid":"native-desktop","name":"Desktop"}"#)
        .unwrap();
    let application_id = router.authorities().applications().applications().unwrap()[0].id;
    let mut hello = native_hello(application_id);
    hello.requested_video_format.as_mut().unwrap().profile = 999;
    hello.video_capabilities[0].format = hello.requested_video_format.clone();

    let responses = router.dispatch_native_control(
        ClientControlEnvelope {
            request_id: 78,
            payload: Some(client_control_envelope::Payload::Hello(hello)),
        },
        &native_context(),
    );

    let Some(host_control_envelope::Payload::Error(error)) = responses[0].payload.as_ref() else {
        panic!("malformed exact row did not return a typed negotiation error");
    };
    assert_eq!(
        error.negotiation_failure,
        NativeNegotiationFailure::UnsupportedVideoSelection as i32
    );
    assert_eq!(
        error.message,
        "the exact hardware video selection is malformed or unsupported"
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
    assert!(router.video_delivery_state().is_none());
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
    assert!(payload["host"].get("directMediaUdpPort").is_none());
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
