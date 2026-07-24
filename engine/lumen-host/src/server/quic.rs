use std::fs::File;
use std::io::BufReader;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use lumen_engine::{
    client_telemetry_envelope, decode_client_control_message, decode_client_input_message,
    decode_client_telemetry_message, encode_codec_configuration_message,
    encode_host_control_message, encode_host_input_message, encode_video_bootstrap_message,
    host_control_envelope, host_input_envelope, HostControlEnvelope, HostInputEnvelope,
    HostSessionCapabilities, NativeInputAck, NativeInputFailure, NativeInputFailureCode,
    NativeNegotiationFailure, NativeProtocolError, LUMEN_STREAMING_PROTOCOL_ALPN,
    NATIVE_CONTROL_MESSAGE_LIMIT, NATIVE_INPUT_MESSAGE_LIMIT,
};
use quinn::crypto::rustls::QuicServerConfig;
use quinn::{Endpoint, RecvStream, ServerConfig, TransportConfig, VarInt};
use rustls::pki_types::PrivateKeyDer;
use tokio::sync::Notify;

use super::media::run_native_media_loop;
use super::SharedControlRouter;
use crate::control::{NativeConnectionContext, NativeMediaFeedbackDisposition};
use crate::native_input::NativeInputSequence;
use crate::network_ports::NATIVE_QUIC_OFFSET;
use crate::{
    HostArguments, NativeStreamControl, PlatformNativeInputEvent, PlatformRuntimeEvent,
    PlatformRuntimeEventCode, PlatformRuntimeEventDisposition, PlatformRuntimeEventSeverity,
    PlatformSessionControl,
};

const SERVER_START_TIMEOUT: Duration = Duration::from_secs(2);
const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(10);
const CONNECTION_STREAM_TIMEOUT: Duration = Duration::from_secs(2);
const ERROR_RESPONSE_DELIVERY_GRACE: Duration = Duration::from_millis(500);
const SERVER_MAX_IDLE_TIMEOUT: Duration = Duration::from_secs(120);
const SERVER_KEEP_ALIVE_INTERVAL: Duration = Duration::from_secs(5);
const CODEC_CONFIGURATION_ACK_TIMEOUT: Duration = Duration::from_secs(15);
const CODEC_CONFIGURATION_ACK_POLL_INTERVAL: Duration = Duration::from_millis(10);
const VIDEO_BOOTSTRAP_RESULT_TIMEOUT: Duration = Duration::from_secs(15);
const ERROR_TRANSPORT: u32 = 9;
const PRIORITY_CONTROL: i32 = 100;
const PRIORITY_INPUT: i32 = 90;
const PRIORITY_CODEC_CONFIGURATION: i32 = 80;
const PRIORITY_VIDEO_BOOTSTRAP: i32 = 80;
const PRIORITY_TELEMETRY: i32 = 20;

#[derive(Default)]
pub struct QuicSessionTransport {
    server: Option<QuicServerHandle>,
}

impl NativeStreamControl for QuicSessionTransport {
    fn start(
        &mut self,
        arguments: &HostArguments,
        router: SharedControlRouter,
        platform: Arc<dyn PlatformSessionControl>,
    ) -> Result<(), String> {
        if self.server.is_some() {
            return Err("QUIC session server is already running".to_owned());
        }
        let address = server_address(arguments)?;
        let cert_path = required_path(arguments, "cert")?;
        let key_path = required_path(arguments, "pkey")?;
        let config = load_server_config(&cert_path, &key_path)?;
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let (ready, ready_result) = mpsc::sync_channel(1);
        let configuration_notify = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .native_codec_configuration_notify();
        let bootstrap_notify = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .native_video_bootstrap_notify();
        let thread = match thread::Builder::new()
            .name("lumen-quic-session".to_owned())
            .spawn(move || {
                run_server(
                    config,
                    address,
                    QuicServerContext {
                        router,
                        platform,
                        configuration_notify,
                        bootstrap_notify,
                        stop: thread_stop,
                    },
                    ready,
                )
            }) {
            Ok(thread) => thread,
            Err(error) => return Err(format!("could not start QUIC session thread: {error}")),
        };
        let local_address = match ready_result.recv_timeout(SERVER_START_TIMEOUT) {
            Ok(Ok(address)) => address,
            Ok(Err(error)) => {
                let _ = thread.join();
                return Err(error);
            }
            Err(_) => {
                stop.store(true, Ordering::Release);
                let _ = thread.join();
                return Err("QUIC session server did not become ready".to_owned());
            }
        };
        self.server = Some(QuicServerHandle {
            local_address,
            stop,
            thread: Some(thread),
        });
        Ok(())
    }

    fn force_stop(&mut self) -> Result<(), String> {
        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        stop_quic_server(self.server.take())
    }
}

fn stop_quic_server(server: Option<QuicServerHandle>) -> Result<(), String> {
    let Some(mut server) = server else {
        return Ok(());
    };
    server.stop.store(true, Ordering::Release);
    server
        .thread
        .take()
        .ok_or_else(|| "QUIC session thread is unavailable".to_owned())?
        .join()
        .map_err(|_| "QUIC session thread panicked".to_owned())
}

impl QuicSessionTransport {
    pub fn local_address(&self) -> Option<SocketAddr> {
        self.server.as_ref().map(|server| server.local_address)
    }
}

impl Drop for QuicSessionTransport {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

struct QuicServerHandle {
    local_address: SocketAddr,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

struct QuicServerContext {
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
    configuration_notify: Arc<Notify>,
    bootstrap_notify: Arc<Notify>,
    stop: Arc<AtomicBool>,
}

#[derive(Default)]
struct ControlStreamLifecycle {
    acknowledged_stop: bool,
}

impl ControlStreamLifecycle {
    fn observe_responses(&mut self, responses: &[HostControlEnvelope]) {
        self.acknowledged_stop |= responses.iter().any(|response| {
            matches!(
                response.payload,
                Some(host_control_envelope::Payload::SessionStopped(_))
            )
        });
    }

    fn validate_eof(self) -> Result<(), String> {
        self.acknowledged_stop.then_some(()).ok_or_else(|| {
            "QUIC session-control stream ended without an acknowledged StopSession".to_owned()
        })
    }
}

fn run_server(
    config: ServerConfig,
    address: SocketAddr,
    context: QuicServerContext,
    ready: mpsc::SyncSender<Result<SocketAddr, String>>,
) {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            let _ = ready.send(Err(format!("could not create QUIC runtime: {error}")));
            return;
        }
    };
    runtime.block_on(async move {
        let endpoint = match Endpoint::server(config, address) {
            Ok(endpoint) => endpoint,
            Err(error) => {
                let _ = ready.send(Err(format!("could not bind QUIC session server: {error}")));
                return;
            }
        };
        let local_address = match endpoint.local_addr() {
            Ok(address) => address,
            Err(error) => {
                let _ = ready.send(Err(format!("could not read QUIC server address: {error}")));
                return;
            }
        };
        if ready.send(Ok(local_address)).is_err() {
            return;
        }
        eprintln!(
            "Lumen native QUIC server ready address={local_address} idle-timeout-ms={} keepalive-ms={}",
            SERVER_MAX_IDLE_TIMEOUT.as_millis(),
            SERVER_KEEP_ALIVE_INTERVAL.as_millis()
        );
        while !context.stop.load(Ordering::Acquire) {
            let incoming = match tokio::time::timeout(ACCEPT_POLL_INTERVAL, endpoint.accept()).await
            {
                Ok(Some(incoming)) => incoming,
                Ok(None) => break,
                Err(_) => continue,
            };
            let router = Arc::clone(&context.router);
            let platform = Arc::clone(&context.platform);
            let configuration_notify = Arc::clone(&context.configuration_notify);
            let bootstrap_notify = Arc::clone(&context.bootstrap_notify);
            tokio::spawn(async move {
                let connection = match incoming.await {
                    Ok(connection) => connection,
                    Err(error) => {
                        report_native_transport_error(
                            platform.as_ref(),
                            format!("QUIC TLS handshake failed: {error}"),
                        );
                        return;
                    }
                };
                let peer = connection.remote_address();
                let alpn =
                    std::str::from_utf8(LUMEN_STREAMING_PROTOCOL_ALPN).unwrap_or("invalid-alpn");
                eprintln!("Lumen native QUIC stage=tls-ready peer={peer} alpn={alpn}");
                if let Err(error) = handle_connection(
                    connection,
                    router,
                    Arc::clone(&platform),
                    configuration_notify,
                    bootstrap_notify,
                )
                .await
                {
                    report_native_transport_error(
                        platform.as_ref(),
                        format!("QUIC native session failed for {peer}: {error}"),
                    );
                }
            });
        }
        endpoint.close(VarInt::from_u32(0), b"host shutdown");
        endpoint.wait_idle().await;
    });
}

async fn handle_connection(
    connection: quinn::Connection,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
    configuration_notify: Arc<Notify>,
    bootstrap_notify: Arc<Notify>,
) -> Result<(), String> {
    let (mut send, mut receive) =
        tokio::time::timeout(CONNECTION_STREAM_TIMEOUT, connection.accept_bi())
            .await
            .map_err(|_| "QUIC client did not open the session-control stream".to_owned())?
            .map_err(|error| format!("could not accept QUIC session-control stream: {error}"))?;
    if send.id().index() != 0 || receive.id().index() != 0 {
        return Err("QUIC session-control stream is not client bidi stream 0".to_owned());
    }
    send.set_priority(PRIORITY_CONTROL)
        .map_err(|error| format!("could not prioritize QUIC control stream: {error}"))?;
    eprintln!(
        "Lumen native QUIC stage=control-stream-ready peer={}",
        connection.remote_address()
    );
    let session_epoch = session_epoch(&connection);
    let maximum_datagram_payload = connection
        .max_datagram_size()
        .ok_or_else(|| "QUIC DATAGRAM was not negotiated".to_owned())?;
    let mut host_capabilities = default_host_capabilities();
    host_capabilities.maximum_datagram_payload = host_capabilities
        .maximum_datagram_payload
        .min(u32::try_from(maximum_datagram_payload).unwrap_or(u32::MAX));
    let context = NativeConnectionContext {
        session_epoch,
        host_capabilities,
    };
    let first_frame = read_control_frame(&mut receive)
        .await?
        .ok_or_else(|| "QUIC session-control stream closed before the native hello".to_owned())?;
    let first_request = decode_client_control_message(&first_frame)
        .map_err(|error| format!("invalid QUIC control frame: {error:?}"))?;
    let request_id = first_request.request_id;
    eprintln!(
        "Lumen native QUIC stage=first-control-ready peer={} request-id={request_id}",
        connection.remote_address()
    );
    let configuration_send =
        match tokio::time::timeout(CONNECTION_STREAM_TIMEOUT, connection.open_uni()).await {
            Err(_) => {
                let error = "QUIC client did not admit the codec-configuration stream".to_owned();
                write_native_transport_error(&mut send, request_id, &error).await?;
                return Err(error);
            }
            Ok(Err(error)) => {
                let error = format!("could not open QUIC codec-configuration stream: {error}");
                write_native_transport_error(&mut send, request_id, &error).await?;
                return Err(error);
            }
            Ok(Ok(send)) => send,
        };
    if configuration_send.id().index() != 0 {
        return Err("codec configuration is not host uni stream 3".to_owned());
    }
    configuration_send
        .set_priority(PRIORITY_CODEC_CONFIGURATION)
        .map_err(|error| format!("could not prioritize codec-configuration stream: {error}"))?;
    eprintln!(
        "Lumen native QUIC stage=codec-stream-ready peer={} stream-id={:?}",
        connection.remote_address(),
        configuration_send.id()
    );
    let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
        disposition: PlatformRuntimeEventDisposition::Cleared,
        severity: PlatformRuntimeEventSeverity::Error,
        code: PlatformRuntimeEventCode::NativeSessionTransport,
        message: None,
    });
    let task_stop = Arc::new(AtomicBool::new(false));
    // Client streams 4 and 8 are not peer-visible until a STREAM frame is transmitted. Do not
    // make either idle stream a prerequisite for returning the session plan on control stream 0.
    let first_control_response_notify = Arc::new(Notify::new());
    let configuration_router = Arc::clone(&router);
    let configuration_task_stop = Arc::clone(&task_stop);
    let configuration_task_notify = Arc::clone(&configuration_notify);
    let mut configuration_task = tokio::spawn(async move {
        publish_codec_configurations(
            configuration_send,
            session_epoch,
            configuration_router,
            configuration_task_stop,
            configuration_task_notify,
        )
        .await
    });
    let bootstrap_connection = connection.clone();
    let bootstrap_router = Arc::clone(&router);
    let bootstrap_stop = Arc::clone(&task_stop);
    let bootstrap_task_notify = Arc::clone(&bootstrap_notify);
    let mut bootstrap_task = tokio::spawn(async move {
        publish_video_bootstraps(
            bootstrap_connection,
            session_epoch,
            bootstrap_router,
            bootstrap_stop,
            bootstrap_task_notify,
        )
        .await
    });
    let auxiliary_connection = connection.clone();
    let auxiliary_router = Arc::clone(&router);
    let auxiliary_platform = Arc::clone(&platform);
    let auxiliary_first_control_response_notify = Arc::clone(&first_control_response_notify);
    let mut auxiliary_task = tokio::spawn(async move {
        auxiliary_first_control_response_notify.notified().await;
        accept_native_auxiliary_streams(
            auxiliary_connection,
            session_epoch,
            auxiliary_router,
            auxiliary_platform,
        )
        .await
    });
    let media_connection = connection.clone();
    let media_router = Arc::clone(&router);
    let media_platform = Arc::clone(&platform);
    let mut media_task = tokio::spawn(async move {
        run_native_media_loop(
            media_connection,
            session_epoch,
            media_router,
            media_platform,
        )
        .await
    });
    let lifecycle_router = Arc::clone(&router);
    let mut control_task = tokio::spawn(async move {
        let result: Result<(), String> = async {
            let first_responses = {
                let mut router = router
                    .lock()
                    .map_err(|_| "native control router lock is poisoned".to_owned())?;
                router.dispatch_native_control(first_request, &context)
            };
            write_control_responses(&mut send, first_responses).await?;
            first_control_response_notify.notify_one();
            handle_control_stream(&mut send, &mut receive, &router, &context).await
        }
        .await;
        result
    });
    let result = tokio::select! {
        result = &mut control_task => join_task("control", result),
        result = &mut configuration_task => join_task("codec configuration", result),
        result = &mut bootstrap_task => join_task("video bootstrap", result),
        result = &mut auxiliary_task => join_task("native auxiliary streams", result),
        result = &mut media_task => join_task("QUIC datagram media", result),
    };
    task_stop.store(true, Ordering::Release);
    configuration_notify.notify_one();
    bootstrap_notify.notify_one();
    if let Err(error) = &result {
        let reason = error.as_bytes();
        connection.close(
            VarInt::from_u32(ERROR_TRANSPORT),
            &reason[..reason.len().min(1_024)],
        );
    } else {
        connection.close(VarInt::from_u32(0), b"session control closed");
    }
    control_task.abort();
    configuration_task.abort();
    bootstrap_task.abort();
    auxiliary_task.abort();
    media_task.abort();
    let cleanup_result = match lifecycle_router.lock() {
        Ok(mut router) => router.terminate_native_connection(session_epoch),
        Err(_) => Err("native control router lock is poisoned".to_owned()),
    };
    if cleanup_result.is_ok() {
        eprintln!(
            "Lumen native QUIC stage=connection-cleanup-complete session-epoch={session_epoch}"
        );
    }
    result.and(cleanup_result)
}

fn join_task(
    task: &'static str,
    result: Result<Result<(), String>, tokio::task::JoinError>,
) -> Result<(), String> {
    match result {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => Err(format!("{task} task failed: {error}")),
        Err(error) => Err(format!("{task} task failed to join: {error}")),
    }
}

async fn publish_codec_configurations(
    mut send: quinn::SendStream,
    session_epoch: u32,
    router: SharedControlRouter,
    stop: Arc<AtomicBool>,
    notify: Arc<Notify>,
) -> Result<(), String> {
    while !stop.load(Ordering::Acquire) {
        let configuration = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .take_native_codec_configuration(session_epoch);
        if let Some(configuration) = configuration {
            let encoded = encode_codec_configuration_message(&configuration)
                .map_err(|error| format!("could not encode codec configuration: {error:?}"))?;
            send.write_all(&encoded)
                .await
                .map_err(|error| format!("could not write codec configuration: {error}"))?;
            eprintln!(
                "Lumen native QUIC stage=codec-configuration-sent session-epoch={} stream-id={} configuration-id={} codec={} record-bytes={}",
                configuration.session_epoch,
                configuration.stream_id,
                configuration.configuration_id,
                configuration.codec,
                configuration.decoder_configuration_record.len()
            );
            let acknowledgement = Box::pin(wait_for_codec_configuration_ack(
                &router,
                configuration.session_epoch,
                configuration.configuration_id,
                CODEC_CONFIGURATION_ACK_TIMEOUT,
                &stop,
            ));
            let peer_stream_state = Box::pin(send.stopped());
            match futures_util::future::select(acknowledgement, peer_stream_state).await {
                futures_util::future::Either::Left((result, _)) => {
                    if result? == CodecConfigurationAckWaitOutcome::Stopped {
                        break;
                    }
                }
                futures_util::future::Either::Right((result, _)) => {
                    let reason = match result {
                        Ok(Some(code)) => format!("peer-stop-code={}", code.into_inner()),
                        Ok(None) => "peer-consumed-finished-stream".to_owned(),
                        Err(error) => format!("stream-state-error={error}"),
                    };
                    return Err(format!(
                        "codec configuration stream stopped before acknowledgement session-epoch={} configuration-id={} {reason}",
                        configuration.session_epoch,
                        configuration.configuration_id
                    ));
                }
            }
        } else {
            notify.notified().await;
        }
    }
    send.finish()
        .map_err(|error| format!("could not finish codec-configuration stream: {error}"))?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CodecConfigurationAckWaitOutcome {
    Acknowledged,
    Stopped,
}

async fn wait_for_codec_configuration_ack(
    router: &SharedControlRouter,
    session_epoch: u32,
    configuration_id: u32,
    timeout: Duration,
    stop: &AtomicBool,
) -> Result<CodecConfigurationAckWaitOutcome, String> {
    tokio::time::timeout(timeout, async {
        loop {
            if stop.load(Ordering::Acquire) {
                return Ok(CodecConfigurationAckWaitOutcome::Stopped);
            }
            let acknowledged = router
                .lock()
                .map_err(|_| "native control router lock is poisoned".to_owned())?
                .native_codec_configuration_is_acknowledged(session_epoch, configuration_id);
            if acknowledged {
                return Ok(CodecConfigurationAckWaitOutcome::Acknowledged);
            }
            tokio::time::sleep(CODEC_CONFIGURATION_ACK_POLL_INTERVAL).await;
        }
    })
    .await
    .map_err(|_| {
        format!(
            "codec configuration acknowledgement timed out session-epoch={session_epoch} configuration-id={configuration_id} timeout-ms={}",
            timeout.as_millis()
        )
    })?
}

async fn publish_video_bootstraps(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    stop: Arc<AtomicBool>,
    notify: Arc<Notify>,
) -> Result<(), String> {
    let mut expected_stream_index = 1_u64;
    while !stop.load(Ordering::Acquire) {
        let bootstrap = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .take_native_video_bootstrap(session_epoch);
        let Some(bootstrap) = bootstrap else {
            notify.notified().await;
            continue;
        };
        let mut send = tokio::time::timeout(CONNECTION_STREAM_TIMEOUT, connection.open_uni())
            .await
            .map_err(|_| "QUIC client did not admit a video-bootstrap stream".to_owned())?
            .map_err(|error| format!("could not open QUIC video-bootstrap stream: {error}"))?;
        if send.id().index() != expected_stream_index {
            return Err(format!(
                "video bootstrap opened unexpected host uni stream index={} expected={expected_stream_index}",
                send.id().index()
            ));
        }
        send.set_priority(PRIORITY_VIDEO_BOOTSTRAP)
            .map_err(|error| format!("could not prioritize video-bootstrap stream: {error}"))?;
        expected_stream_index = expected_stream_index
            .checked_add(1)
            .ok_or_else(|| "video bootstrap stream index exhausted".to_owned())?;
        let encoded = encode_video_bootstrap_message(&bootstrap)
            .map_err(|error| format!("could not encode video bootstrap: {error:?}"))?;
        send.write_all(&encoded)
            .await
            .map_err(|error| format!("could not write video bootstrap: {error}"))?;
        send.finish()
            .map_err(|error| format!("could not finish video bootstrap stream: {error}"))?;
        eprintln!(
            "Lumen native QUIC stage=video-bootstrap-sent session-epoch={} stream-id={} configuration-id={} generation-id={} frame-id={} reason={} access-unit-bytes={}",
            bootstrap.session_epoch,
            bootstrap.stream_id,
            bootstrap.configuration_id,
            bootstrap.generation_id,
            bootstrap.frame_id,
            bootstrap.reason,
            bootstrap.access_unit.len()
        );
        match wait_for_video_bootstrap_result(
            &router,
            bootstrap.session_epoch,
            bootstrap.generation_id,
            VIDEO_BOOTSTRAP_RESULT_TIMEOUT,
            &stop,
        )
        .await?
        {
            VideoBootstrapWaitOutcome::Acknowledged => (),
            VideoBootstrapWaitOutcome::Obsolete => {
                let _ = send.reset(VarInt::from_u32(1));
                eprintln!(
                    "Lumen native QUIC stage=video-bootstrap-obsolete session-epoch={} generation-id={}",
                    bootstrap.session_epoch, bootstrap.generation_id
                );
            }
            VideoBootstrapWaitOutcome::Stopped => break,
        }
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum VideoBootstrapWaitOutcome {
    Acknowledged,
    Obsolete,
    Stopped,
}

async fn wait_for_video_bootstrap_result(
    router: &SharedControlRouter,
    session_epoch: u32,
    generation_id: u32,
    timeout: Duration,
    stop: &AtomicBool,
) -> Result<VideoBootstrapWaitOutcome, String> {
    tokio::time::timeout(timeout, async {
        loop {
            if stop.load(Ordering::Acquire) {
                return Ok(VideoBootstrapWaitOutcome::Stopped);
            }
            let (current_generation, failure, acknowledged) = {
                let router = router
                    .lock()
                    .map_err(|_| "native control router lock is poisoned".to_owned())?;
                (
                    router.native_video_bootstrap_generation(session_epoch),
                    router.native_video_bootstrap_failure(session_epoch, generation_id),
                    router.native_video_bootstrap_is_acknowledged(session_epoch, generation_id),
                )
            };
            if current_generation.is_some_and(|current| current != generation_id) {
                return Ok(VideoBootstrapWaitOutcome::Obsolete);
            }
            if let Some(message) = failure {
                return Err(format!(
                    "video bootstrap decoder rejected generation {generation_id}: {message}"
                ));
            }
            if acknowledged {
                return Ok(VideoBootstrapWaitOutcome::Acknowledged);
            }
            tokio::time::sleep(CODEC_CONFIGURATION_ACK_POLL_INTERVAL).await;
        }
    })
    .await
    .map_err(|_| {
        format!(
            "video bootstrap decode result timed out session-epoch={session_epoch} generation-id={generation_id} timeout-ms={}",
            timeout.as_millis()
        )
    })?
}

async fn handle_control_stream(
    send: &mut quinn::SendStream,
    receive: &mut RecvStream,
    router: &SharedControlRouter,
    context: &NativeConnectionContext,
) -> Result<(), String> {
    let mut lifecycle = ControlStreamLifecycle::default();
    while let Some(frame) = read_control_frame(receive).await? {
        let request = decode_client_control_message(&frame)
            .map_err(|error| format!("invalid QUIC control frame: {error:?}"))?;
        let responses = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .dispatch_native_control(request, context);
        lifecycle.observe_responses(&responses);
        write_control_responses(send, responses).await?;
    }
    lifecycle.validate_eof()?;
    send.finish()
        .map_err(|error| format!("could not finish QUIC session-control stream: {error}"))?;
    send.stopped()
        .await
        .map_err(|error| format!("QUIC session-control response was not acknowledged: {error}"))?;
    Ok(())
}

async fn write_control_responses(
    send: &mut quinn::SendStream,
    responses: Vec<HostControlEnvelope>,
) -> Result<(), String> {
    for response in responses {
        let encoded = encode_host_control_message(&response)
            .map_err(|error| format!("could not encode QUIC control response: {error:?}"))?;
        send.write_all(&encoded)
            .await
            .map_err(|error| format!("could not write QUIC control response: {error}"))?;
    }
    Ok(())
}

async fn write_native_transport_error(
    send: &mut quinn::SendStream,
    request_id: u64,
    message: &str,
) -> Result<(), String> {
    write_control_responses(
        send,
        vec![HostControlEnvelope {
            request_id,
            payload: Some(host_control_envelope::Payload::Error(NativeProtocolError {
                code: ERROR_TRANSPORT,
                message: message.to_owned(),
                negotiation_failure: NativeNegotiationFailure::Unspecified as i32,
            })),
        }],
    )
    .await?;
    send.finish()
        .map_err(|error| format!("could not finish QUIC transport-error response: {error}"))?;
    tokio::time::sleep(ERROR_RESPONSE_DELIVERY_GRACE).await;
    Ok(())
}

fn report_native_transport_error(platform: &dyn PlatformSessionControl, message: String) {
    eprintln!("{message}");
    let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
        disposition: PlatformRuntimeEventDisposition::Raised,
        severity: PlatformRuntimeEventSeverity::Error,
        code: PlatformRuntimeEventCode::NativeSessionTransport,
        message: Some(message),
    });
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeAuxiliaryStreamKind {
    ReliableInput,
    Telemetry,
}

type NativeAuxiliaryStreamTaskResult =
    Result<(NativeAuxiliaryStreamKind, Result<(), String>), tokio::task::JoinError>;

impl NativeAuxiliaryStreamKind {
    const fn task_name(self) -> &'static str {
        match self {
            Self::ReliableInput => "reliable input",
            Self::Telemetry => "telemetry",
        }
    }

    const fn stream_index(self) -> u64 {
        match self {
            Self::ReliableInput => 1,
            Self::Telemetry => 2,
        }
    }

    const fn stream_id(self) -> u64 {
        self.stream_index() * 4
    }

    const fn next(self) -> Option<Self> {
        match self {
            Self::ReliableInput => Some(Self::Telemetry),
            Self::Telemetry => None,
        }
    }
}

async fn accept_native_auxiliary_streams(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), String> {
    let mut next_kind = Some(NativeAuxiliaryStreamKind::ReliableInput);
    let mut stream_tasks = tokio::task::JoinSet::new();
    loop {
        let Some(kind) = next_kind else {
            return join_native_auxiliary_stream_task(stream_tasks.join_next().await);
        };
        tokio::select! {
            // Admission is intentionally unbounded: valid input and telemetry cannot exist before
            // the session plan, and either stream may remain idle for the connection lifetime.
            accepted = connection.accept_bi() => {
                let (send, receive) = accepted.map_err(|error| {
                    format!("could not accept QUIC {} stream: {error}", kind.task_name())
                })?;
                if send.id().index() != kind.stream_index()
                    || receive.id().index() != kind.stream_index()
                {
                    return Err(format!(
                        "{} is not client bidi stream {}",
                        kind.task_name(),
                        kind.stream_id()
                    ));
                }
                match kind {
                    NativeAuxiliaryStreamKind::ReliableInput => {
                        send.set_priority(PRIORITY_INPUT).map_err(|error| {
                            format!("could not prioritize reliable-input stream: {error}")
                        })?;
                        let input_router = Arc::clone(&router);
                        let input_platform = Arc::clone(&platform);
                        stream_tasks.spawn(async move {
                            (
                                NativeAuxiliaryStreamKind::ReliableInput,
                                accept_native_input_stream(
                                    send,
                                    receive,
                                    session_epoch,
                                    input_router,
                                    input_platform,
                                )
                                .await,
                            )
                        });
                    }
                    NativeAuxiliaryStreamKind::Telemetry => {
                        send.set_priority(PRIORITY_TELEMETRY).map_err(|error| {
                            format!("could not prioritize telemetry stream: {error}")
                        })?;
                        let telemetry_router = Arc::clone(&router);
                        stream_tasks.spawn(async move {
                            (
                                NativeAuxiliaryStreamKind::Telemetry,
                                accept_native_telemetry_stream(
                                    send,
                                    receive,
                                    session_epoch,
                                    telemetry_router,
                                )
                                .await,
                            )
                        });
                    }
                }
                next_kind = kind.next();
            }
            completed = stream_tasks.join_next(), if !stream_tasks.is_empty() => {
                return join_native_auxiliary_stream_task(completed);
            }
        }
    }
}

fn join_native_auxiliary_stream_task(
    result: Option<NativeAuxiliaryStreamTaskResult>,
) -> Result<(), String> {
    match result {
        Some(Ok((kind, Ok(())))) => Err(format!(
            "{} ended while the control session was active",
            kind.task_name()
        )),
        Some(Ok((kind, Err(error)))) => Err(format!("{}: {error}", kind.task_name())),
        Some(Err(error)) => Err(format!(
            "native auxiliary stream task failed to join: {error}"
        )),
        None => Err("native auxiliary stream task set ended without a result".to_owned()),
    }
}

async fn accept_native_input_stream(
    mut send: quinn::SendStream,
    mut receive: quinn::RecvStream,
    session_epoch: u32,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), String> {
    eprintln!(
        "Lumen native QUIC stage=input-stream-ready session-epoch={session_epoch} stream-id={:?}",
        receive.id()
    );
    let guard = NativeInputResetGuard::new(session_epoch, Arc::clone(&platform));
    let mut sequence = NativeInputSequence::new(session_epoch);
    let mut command_sequence = 1_u64;
    while let Some(frame) = read_input_frame(&mut receive).await? {
        let envelope = decode_client_input_message(&frame)
            .map_err(|error| format!("invalid QUIC input frame: {error:?}"))?;
        let event_sequence = envelope.event_sequence;
        let event = sequence
            .accept(envelope)
            .map_err(|error| format!("invalid QUIC input event: {error}"))?;
        let active = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .native_input_is_active(session_epoch);
        if !active {
            return Err("native input arrived outside an active session".to_owned());
        }
        let payload = match platform.handle_native_input(session_epoch, event.clone()) {
            Ok(()) => host_input_envelope::Payload::Ack(NativeInputAck {
                highest_contiguous_event_sequence: sequence.highest_contiguous_event_sequence(),
            }),
            Err(error) => {
                eprintln!(
                    "Lumen native input rejected session-epoch={session_epoch} event-sequence={event_sequence} event={} error={error}",
                    native_input_event_summary(&event)
                );
                let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
                    disposition: PlatformRuntimeEventDisposition::Raised,
                    severity: PlatformRuntimeEventSeverity::Warning,
                    code: PlatformRuntimeEventCode::NativeSessionPlatform,
                    message: Some(format!(
                        "Native input event {} was rejected: {error}",
                        native_input_event_summary(&event)
                    )),
                });
                host_input_envelope::Payload::Failure(NativeInputFailure {
                    event_sequence,
                    code: NativeInputFailureCode::PlatformRejected as i32,
                    message: error,
                })
            }
        };
        let response = HostInputEnvelope {
            session_epoch,
            command_sequence,
            payload: Some(payload),
        };
        let encoded = encode_host_input_message(&response)
            .map_err(|error| format!("could not encode QUIC input response: {error:?}"))?;
        send.write_all(&encoded)
            .await
            .map_err(|error| format!("could not write QUIC input response: {error}"))?;
        command_sequence = command_sequence
            .checked_add(1)
            .ok_or_else(|| "native input command sequence exhausted".to_owned())?;
    }
    guard.reset()?;
    eprintln!(
        "Lumen native QUIC stage=input-peer-send-closed session-epoch={session_epoch} response-lane=held"
    );
    hold_native_auxiliary_response_until_session_end(send).await
}

async fn accept_native_telemetry_stream(
    send: quinn::SendStream,
    mut receive: quinn::RecvStream,
    session_epoch: u32,
    router: SharedControlRouter,
) -> Result<(), String> {
    eprintln!(
        "Lumen native QUIC stage=telemetry-stream-ready session-epoch={session_epoch} stream-id={:?}",
        receive.id()
    );
    let mut expected_sequence = 1_u64;
    let mut logged_audio_feedback = false;
    while let Some(frame) =
        read_length_delimited_frame(&mut receive, NATIVE_CONTROL_MESSAGE_LIMIT, "telemetry").await?
    {
        let envelope = decode_client_telemetry_message(&frame)
            .map_err(|error| format!("invalid QUIC telemetry frame: {error:?}"))?;
        if envelope.sequence != expected_sequence {
            return Err(format!(
                "QUIC telemetry sequence is not contiguous expected={expected_sequence} received={}",
                envelope.sequence
            ));
        }
        expected_sequence = expected_sequence
            .checked_add(1)
            .ok_or_else(|| "QUIC telemetry sequence exhausted".to_owned())?;
        let Some(client_telemetry_envelope::Payload::MediaFeedback(feedback)) = envelope.payload
        else {
            return Err("QUIC telemetry envelope has no payload".to_owned());
        };
        let disposition = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .observe_native_media_feedback(&feedback, session_epoch);
        match disposition {
            Ok(NativeMediaFeedbackDisposition::AppliedVideo) => {}
            Ok(NativeMediaFeedbackDisposition::AcceptedAudio) => {
                if !logged_audio_feedback {
                    eprintln!(
                        "Lumen native QUIC stage=media-feedback-accepted-audio session-epoch={session_epoch} telemetry-sequence={} stream-id={} first-sequence={} highest-sequence={} received-datagrams={} recovered-shards={} unrecoverable-objects={} late-objects={} reordered-datagrams={} jitter-us={} decoder-queue-depth={} presentation-drops={} window-ms={}",
                        envelope.sequence,
                        feedback.stream_id,
                        feedback.first_datagram_sequence,
                        feedback.highest_datagram_sequence,
                        feedback.received_datagrams,
                        feedback.recovered_shards,
                        feedback.unrecoverable_objects,
                        feedback.late_objects,
                        feedback.reordered_datagrams,
                        feedback.estimated_jitter_us,
                        feedback.decoder_queue_depth,
                        feedback.presentation_drops,
                        feedback.window_milliseconds,
                    );
                    logged_audio_feedback = true;
                }
            }
            Err(reason) => {
                return Err(format!(
                    "QUIC media feedback was rejected reason={} telemetry-sequence={} stream-id={} first-sequence={} highest-sequence={} received-datagrams={} recovered-shards={} unrecoverable-objects={} late-objects={} reordered-datagrams={} jitter-us={} decoder-queue-depth={} presentation-drops={} window-ms={}",
                    reason.code(),
                    envelope.sequence,
                    feedback.stream_id,
                    feedback.first_datagram_sequence,
                    feedback.highest_datagram_sequence,
                    feedback.received_datagrams,
                    feedback.recovered_shards,
                    feedback.unrecoverable_objects,
                    feedback.late_objects,
                    feedback.reordered_datagrams,
                    feedback.estimated_jitter_us,
                    feedback.decoder_queue_depth,
                    feedback.presentation_drops,
                    feedback.window_milliseconds,
                ));
            }
        }
    }
    eprintln!(
        "Lumen native QUIC stage=telemetry-peer-send-closed session-epoch={session_epoch} response-lane=held"
    );
    hold_native_auxiliary_response_until_session_end(send).await
}

async fn hold_native_auxiliary_response_until_session_end(
    _send: quinn::SendStream,
) -> Result<(), String> {
    // Peer FIN closes only the client-to-host half. Control owns connection teardown, so retain
    // the host response half until the outer session task aborts it after StopSession or failure.
    std::future::pending().await
}

fn native_input_event_summary(event: &PlatformNativeInputEvent) -> String {
    match event {
        PlatformNativeInputEvent::Keyboard { hid_usage, pressed, .. } => {
            format!("keyboard(hidUsage={hid_usage:#x},pressed={pressed})")
        }
        PlatformNativeInputEvent::Text { composition_id, commit, .. } => {
            format!("text(compositionId={composition_id},commit={commit})")
        }
        PlatformNativeInputEvent::PointerButton { pointer_id, button, pressed } => {
            format!("pointerButton(pointerId={pointer_id},button={button},pressed={pressed})")
        }
        PlatformNativeInputEvent::GamepadConnection {
            gamepad_id,
            connected,
            capabilities,
        } => format!(
            "gamepadConnection(gamepadId={gamepad_id},connected={connected},capabilities={capabilities:#x})"
        ),
        PlatformNativeInputEvent::GamepadButton {
            gamepad_id,
            button,
            pressed,
            analog_value,
        } => format!(
            "gamepadButton(gamepadId={gamepad_id},button={button:?},pressed={pressed},analogValue={analog_value})"
        ),
        PlatformNativeInputEvent::TouchContact { contact_id, phase, .. } => {
            format!("touchContact(contactId={contact_id},phase={phase:?})")
        }
        PlatformNativeInputEvent::PenContact { pointer_id, phase, .. } => {
            format!("penContact(pointerId={pointer_id},phase={phase:?})")
        }
        PlatformNativeInputEvent::RumbleAcknowledged {
            command_sequence,
            gamepad_id,
            accepted,
        } => format!(
            "rumbleAcknowledged(commandSequence={command_sequence},gamepadId={gamepad_id},accepted={accepted})"
        ),
    }
}

async fn read_control_frame(receive: &mut RecvStream) -> Result<Option<Vec<u8>>, String> {
    read_length_delimited_frame(receive, NATIVE_CONTROL_MESSAGE_LIMIT, "control").await
}

async fn read_input_frame(receive: &mut RecvStream) -> Result<Option<Vec<u8>>, String> {
    read_length_delimited_frame(receive, NATIVE_INPUT_MESSAGE_LIMIT, "input").await
}

async fn read_length_delimited_frame(
    receive: &mut RecvStream,
    allocation_limit: usize,
    surface: &str,
) -> Result<Option<Vec<u8>>, String> {
    let mut prefix = Vec::with_capacity(3);
    let mut length = 0_usize;
    let mut shift = 0_u32;
    for index in 0..10 {
        let mut byte = [0_u8; 1];
        let read = receive
            .read(&mut byte)
            .await
            .map_err(|error| format!("could not read QUIC {surface} frame: {error}"))?;
        let Some(read) = read else {
            return if index == 0 {
                Ok(None)
            } else {
                Err(format!("QUIC {surface} length prefix is truncated"))
            };
        };
        if read != 1 {
            return Err(format!("QUIC {surface} length prefix read was incomplete"));
        }
        prefix.push(byte[0]);
        let value = usize::from(byte[0] & 0x7f)
            .checked_shl(shift)
            .ok_or_else(|| format!("QUIC {surface} length overflowed"))?;
        length = length
            .checked_add(value)
            .ok_or_else(|| format!("QUIC {surface} length overflowed"))?;
        if byte[0] & 0x80 == 0 {
            if length > allocation_limit {
                return Err(format!("QUIC {surface} frame exceeds the allocation limit"));
            }
            let mut body = vec![0_u8; length];
            receive
                .read_exact(&mut body)
                .await
                .map_err(|error| format!("QUIC {surface} body is truncated: {error}"))?;
            prefix.extend_from_slice(&body);
            return Ok(Some(prefix));
        }
        shift = shift
            .checked_add(7)
            .ok_or_else(|| format!("QUIC {surface} length overflowed"))?;
    }
    Err(format!("QUIC {surface} length prefix overflowed"))
}

struct NativeInputResetGuard {
    session_epoch: u32,
    platform: Arc<dyn PlatformSessionControl>,
    active: bool,
}

impl NativeInputResetGuard {
    fn new(session_epoch: u32, platform: Arc<dyn PlatformSessionControl>) -> Self {
        Self {
            session_epoch,
            platform,
            active: true,
        }
    }

    fn reset(mut self) -> Result<(), String> {
        self.active = false;
        self.platform.reset_native_input(self.session_epoch)
    }
}

impl Drop for NativeInputResetGuard {
    fn drop(&mut self) {
        if self.active {
            let _ = self.platform.reset_native_input(self.session_epoch);
        }
    }
}

fn session_epoch(connection: &quinn::Connection) -> u32 {
    let value = connection.stable_id() as u64;
    let folded = (value ^ (value >> 32)) as u32;
    folded.max(1)
}

fn default_host_capabilities() -> HostSessionCapabilities {
    HostSessionCapabilities {
        maximum_datagram_payload: 1_200,
        maximum_receive_memory_bytes: 256 * 1024 * 1024,
        video_capabilities: default_video_capabilities(),
        supported_opus_channel_counts: vec![2, 6, 8],
    }
}

fn default_video_capabilities() -> Vec<lumen_engine::NativeVideoCapability> {
    use lumen_engine::{
        NativeChromaSubsampling, NativeColorRange, NativeDynamicRange, NativeVideoCapability,
        NativeVideoCodec, NativeVideoFormat, NativeVideoProfile,
    };

    [
        (
            NativeVideoCodec::H264,
            NativeVideoProfile::H264High,
            NativeChromaSubsampling::Yuv420,
            8,
            NativeDynamicRange::Sdr,
            NativeColorRange::Limited,
        ),
        (
            NativeVideoCodec::Hevc,
            NativeVideoProfile::HevcMain,
            NativeChromaSubsampling::Yuv420,
            8,
            NativeDynamicRange::Sdr,
            NativeColorRange::Limited,
        ),
        (
            NativeVideoCodec::Hevc,
            NativeVideoProfile::HevcMain10,
            NativeChromaSubsampling::Yuv420,
            10,
            NativeDynamicRange::Hdr10,
            NativeColorRange::Limited,
        ),
        (
            NativeVideoCodec::H264,
            NativeVideoProfile::H264High444Predictive,
            NativeChromaSubsampling::Yuv444,
            8,
            NativeDynamicRange::Sdr,
            NativeColorRange::Full,
        ),
        (
            NativeVideoCodec::Hevc,
            NativeVideoProfile::HevcMain444,
            NativeChromaSubsampling::Yuv444,
            8,
            NativeDynamicRange::Sdr,
            NativeColorRange::Full,
        ),
        (
            NativeVideoCodec::Hevc,
            NativeVideoProfile::HevcMain44410,
            NativeChromaSubsampling::Yuv444,
            10,
            NativeDynamicRange::Hdr10,
            NativeColorRange::Limited,
        ),
    ]
    .into_iter()
    .map(
        |(codec, profile, chroma, bit_depth, dynamic_range, color_range)| NativeVideoCapability {
            format: Some(NativeVideoFormat {
                codec: codec as i32,
                profile: profile as i32,
                chroma_subsampling: chroma as i32,
                bit_depth,
                dynamic_range: dynamic_range as i32,
                color_range: color_range as i32,
            }),
            max_width: 7_680,
            max_height: 4_320,
            max_refresh_millihz: 240_000,
            hardware_accelerated: Some(true),
        },
    )
    .collect()
}

fn load_server_config(cert_path: &Path, key_path: &Path) -> Result<ServerConfig, String> {
    let mut cert_reader = BufReader::new(
        File::open(cert_path)
            .map_err(|error| format!("could not open QUIC certificate: {error}"))?,
    );
    let certificates = rustls_pemfile::certs(&mut cert_reader)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("could not parse QUIC certificate: {error}"))?;
    if certificates.is_empty() {
        return Err("QUIC certificate chain is empty".to_owned());
    }
    let key = load_private_key(key_path)?;
    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certificates, key)
        .map_err(|error| format!("QUIC TLS identity is invalid: {error}"))?;
    tls.alpn_protocols = vec![LUMEN_STREAMING_PROTOCOL_ALPN.to_vec()];
    let crypto = QuicServerConfig::try_from(tls)
        .map_err(|error| format!("QUIC TLS configuration is invalid: {error}"))?;
    let mut config = ServerConfig::with_crypto(Arc::new(crypto));
    let mut transport = TransportConfig::default();
    transport.max_idle_timeout(Some(
        SERVER_MAX_IDLE_TIMEOUT
            .try_into()
            .map_err(|error| format!("QUIC idle timeout is invalid: {error}"))?,
    ));
    transport.keep_alive_interval(Some(SERVER_KEEP_ALIVE_INTERVAL));
    transport.max_concurrent_bidi_streams(VarInt::from_u32(3));
    // The client never opens unidirectional streams. Host uni concurrency is advertised by the peer.
    transport.max_concurrent_uni_streams(VarInt::from_u32(0));
    transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
    transport.datagram_send_buffer_size(4 * 1024 * 1024);
    config.transport_config(Arc::new(transport));
    Ok(config)
}

fn load_private_key(path: &Path) -> Result<PrivateKeyDer<'static>, String> {
    let mut reader = BufReader::new(
        File::open(path).map_err(|error| format!("could not open QUIC private key: {error}"))?,
    );
    rustls_pemfile::private_key(&mut reader)
        .map_err(|error| format!("could not parse QUIC private key: {error}"))?
        .ok_or_else(|| "QUIC private key is missing".to_owned())
}

fn required_path(arguments: &HostArguments, key: &'static str) -> Result<PathBuf, String> {
    arguments
        .get(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| format!("QUIC {key} path is missing"))
}

fn server_address(arguments: &HostArguments) -> Result<SocketAddr, String> {
    let port = base_port(arguments)?
        .checked_add(NATIVE_QUIC_OFFSET)
        .ok_or_else(|| "QUIC session port overflowed".to_owned())?;
    Ok(SocketAddr::new(bind_ip(arguments)?, port))
}

fn base_port(arguments: &HostArguments) -> Result<u16, String> {
    arguments
        .get("port")
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| "native host base port is invalid".to_owned())
}

fn bind_ip(arguments: &HostArguments) -> Result<IpAddr, String> {
    match arguments.get("address_family") {
        Some("ipv4") => Ok(IpAddr::V4(Ipv4Addr::UNSPECIFIED)),
        Some("both") => Ok(IpAddr::V6(Ipv6Addr::UNSPECIFIED)),
        _ => Err("QUIC address family is invalid".to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::Mutex;

    use lumen_engine::{
        client_control_envelope, client_input_envelope, client_telemetry_envelope,
        decode_host_control_message, decode_host_input_message, encode_client_control_message,
        encode_client_input_message, encode_client_telemetry_message, host_control_envelope,
        host_input_envelope, ClientControlEnvelope, ClientInputEnvelope, ClientTelemetryEnvelope,
        MediaFeedback, NativeKeyboardInput, SessionStopped, StartSessionAck, StopSession,
        NATIVE_PROTOCOL_VERSION,
    };
    use quinn::crypto::rustls::QuicClientConfig;

    use crate::control::tests::{native_hello, router_with_platform};
    use crate::IdlePlatformSessionControl;

    use super::*;

    fn native_test_router() -> (
        tempfile::TempDir,
        SharedControlRouter,
        Arc<dyn PlatformSessionControl>,
        u32,
    ) {
        let platform: Arc<dyn PlatformSessionControl> = Arc::new(IdlePlatformSessionControl);
        let (root, router) = router_with_platform(Arc::clone(&platform));
        router
            .authorities()
            .applications()
            .upsert(r#"{"uuid":"native-desktop","name":"Desktop"}"#)
            .unwrap();
        let application_id = router.authorities().applications().applications().unwrap()[0].id;
        (root, Arc::new(Mutex::new(router)), platform, application_id)
    }

    fn loopback_quic_configs(root: &tempfile::TempDir) -> (ServerConfig, quinn::ClientConfig) {
        let certified = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
        let certificate = certified.cert.der().clone();
        let certificate_path = root.path().join("quic-cert.pem");
        let key_path = root.path().join("quic-key.pem");
        fs::write(&certificate_path, certified.cert.pem()).unwrap();
        fs::write(&key_path, certified.signing_key.serialize_pem()).unwrap();
        let server_config = load_server_config(&certificate_path, &key_path).unwrap();

        let mut roots = rustls::RootCertStore::empty();
        roots.add(certificate).unwrap();
        let mut tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        tls.alpn_protocols = vec![LUMEN_STREAMING_PROTOCOL_ALPN.to_vec()];
        let crypto = QuicClientConfig::try_from(tls).unwrap();
        let mut client_config = quinn::ClientConfig::new(Arc::new(crypto));
        let mut transport = TransportConfig::default();
        transport.max_concurrent_uni_streams(VarInt::from_u32(8));
        transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
        transport.datagram_send_buffer_size(4 * 1024 * 1024);
        client_config.transport_config(Arc::new(transport));
        (server_config, client_config)
    }

    #[test]
    fn control_stream_eof_requires_an_acknowledged_stop() {
        assert_eq!(
            ControlStreamLifecycle::default().validate_eof(),
            Err("QUIC session-control stream ended without an acknowledged StopSession".to_owned())
        );

        let mut lifecycle = ControlStreamLifecycle::default();
        lifecycle.observe_responses(&[HostControlEnvelope {
            request_id: 11,
            payload: Some(host_control_envelope::Payload::SessionStopped(
                SessionStopped { session_epoch: 42 },
            )),
        }]);
        assert_eq!(lifecycle.validate_eof(), Ok(()));
    }

    #[test]
    fn v4_alpn_and_numeric_protocol_are_independent_authorities() {
        assert_eq!(LUMEN_STREAMING_PROTOCOL_ALPN, b"lumen-stream/4");
        assert_eq!(NATIVE_PROTOCOL_VERSION, 4);
    }

    #[test]
    fn reliable_object_stream_priorities_precede_telemetry_and_datagrams() {
        assert!(PRIORITY_CONTROL > PRIORITY_CODEC_CONFIGURATION);
        assert!(PRIORITY_INPUT > PRIORITY_VIDEO_BOOTSTRAP);
        assert!(PRIORITY_VIDEO_BOOTSTRAP > PRIORITY_TELEMETRY);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn session_plan_precedes_lazy_auxiliary_stream_admission() {
        let (root, router, platform, application_id) = native_test_router();
        let (server_config, client_config) = loopback_quic_configs(&root);
        let server_endpoint = Endpoint::server(
            server_config,
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        )
        .unwrap();
        let server_address = server_endpoint.local_addr().unwrap();
        let mut client_endpoint =
            Endpoint::client(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)).unwrap();
        client_endpoint.set_default_client_config(client_config);
        let connecting = client_endpoint
            .connect(server_address, "localhost")
            .unwrap();
        let incoming = server_endpoint.accept().await.unwrap();
        let (client_connection, server_connection) = tokio::join!(connecting, incoming);
        let client_connection = client_connection.unwrap();
        let server_connection = server_connection.unwrap();

        let configuration_notify = router.lock().unwrap().native_codec_configuration_notify();
        let bootstrap_notify = router.lock().unwrap().native_video_bootstrap_notify();
        let server_task = tokio::spawn(handle_connection(
            server_connection,
            Arc::clone(&router),
            Arc::clone(&platform),
            configuration_notify,
            bootstrap_notify,
        ));

        let (mut control_send, mut control_receive) = client_connection.open_bi().await.unwrap();
        assert_eq!(control_send.id().index(), 0);
        let (mut input_send, mut input_receive) = client_connection.open_bi().await.unwrap();
        assert_eq!(input_send.id().index(), 1);
        let (mut telemetry_send, mut telemetry_receive) =
            client_connection.open_bi().await.unwrap();
        assert_eq!(telemetry_send.id().index(), 2);

        let hello = ClientControlEnvelope {
            request_id: 1,
            payload: Some(client_control_envelope::Payload::Hello(native_hello(
                application_id,
            ))),
        };
        control_send
            .write_all(&encode_client_control_message(&hello).unwrap())
            .await
            .unwrap();

        let response = tokio::time::timeout(
            Duration::from_secs(1),
            read_control_frame(&mut control_receive),
        )
        .await
        .expect("session plan must not wait for idle client streams 4 and 8")
        .unwrap()
        .unwrap();
        let response = decode_host_control_message(&response).unwrap();
        assert_eq!(response.request_id, 1);
        let plan = match response.payload {
            Some(host_control_envelope::Payload::SessionPlan(plan)) => plan,
            Some(host_control_envelope::Payload::Error(error)) => panic!(
                "expected native session plan, received protocol error code={} negotiation-failure={} message={}",
                error.code, error.negotiation_failure, error.message
            ),
            _ => panic!("expected native session plan, received another control payload"),
        };

        let start = ClientControlEnvelope {
            request_id: 2,
            payload: Some(client_control_envelope::Payload::StartSession(
                StartSessionAck {
                    session_epoch: plan.session_epoch,
                },
            )),
        };
        control_send
            .write_all(&encode_client_control_message(&start).unwrap())
            .await
            .unwrap();
        let response = tokio::time::timeout(
            Duration::from_secs(1),
            read_control_frame(&mut control_receive),
        )
        .await
        .expect("session start must not wait for idle client streams 4 and 8")
        .unwrap()
        .unwrap();
        let response = decode_host_control_message(&response).unwrap();
        assert_eq!(response.request_id, 2);
        assert!(matches!(
            response.payload,
            Some(host_control_envelope::Payload::SessionStarted(_))
        ));

        let initial_delivery_state = router.lock().unwrap().video_delivery_state().unwrap();
        let input = ClientInputEnvelope {
            session_epoch: plan.session_epoch,
            event_sequence: 1,
            payload: Some(client_input_envelope::Payload::Keyboard(
                NativeKeyboardInput {
                    hid_usage: 4,
                    pressed: true,
                    modifiers: 0,
                    repeat: false,
                },
            )),
        };
        input_send
            .write_all(&encode_client_input_message(&input).unwrap())
            .await
            .unwrap();
        let response =
            tokio::time::timeout(Duration::from_secs(1), read_input_frame(&mut input_receive))
                .await
                .expect("reliable input stream 4 was not admitted after its first valid frame")
                .unwrap()
                .unwrap();
        let response = decode_host_input_message(&response).unwrap();
        assert_eq!(response.session_epoch, plan.session_epoch);
        assert!(matches!(
            response.payload,
            Some(host_input_envelope::Payload::Ack(ack))
                if ack.highest_contiguous_event_sequence == 1
        ));

        let audio_telemetry = ClientTelemetryEnvelope {
            sequence: 1,
            payload: Some(client_telemetry_envelope::Payload::MediaFeedback(
                MediaFeedback {
                    stream_id: plan.audio_stream_id,
                    highest_datagram_sequence: 3,
                    received_datagrams: 3,
                    window_milliseconds: 250,
                    first_datagram_sequence: 1,
                    ..MediaFeedback::default()
                },
            )),
        };
        telemetry_send
            .write_all(&encode_client_telemetry_message(&audio_telemetry).unwrap())
            .await
            .unwrap();
        let video_telemetry = ClientTelemetryEnvelope {
            sequence: 2,
            payload: Some(client_telemetry_envelope::Payload::MediaFeedback(
                MediaFeedback {
                    stream_id: plan.video_stream_id,
                    highest_datagram_sequence: 200,
                    received_datagrams: 100,
                    unrecoverable_objects: 100,
                    window_milliseconds: 250,
                    first_datagram_sequence: 1,
                    ..MediaFeedback::default()
                },
            )),
        };
        telemetry_send
            .write_all(&encode_client_telemetry_message(&video_telemetry).unwrap())
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let delivery_state = router.lock().unwrap().video_delivery_state().unwrap();
                if delivery_state != initial_delivery_state {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("audio and video feedback were not admitted on telemetry stream 8");

        input_send.finish().unwrap();
        telemetry_send.finish().unwrap();
        let (input_response, telemetry_response) = tokio::join!(
            tokio::time::timeout(
                Duration::from_millis(250),
                read_input_frame(&mut input_receive)
            ),
            tokio::time::timeout(
                Duration::from_millis(250),
                read_length_delimited_frame(
                    &mut telemetry_receive,
                    NATIVE_CONTROL_MESSAGE_LIMIT,
                    "telemetry",
                )
            ),
        );
        assert!(
            input_response.is_err(),
            "host ended ordered input feedback before the control session stopped"
        );
        assert!(
            telemetry_response.is_err(),
            "host ended telemetry response before the control session stopped"
        );

        let stop = ClientControlEnvelope {
            request_id: 3,
            payload: Some(client_control_envelope::Payload::StopSession(StopSession {
                session_epoch: plan.session_epoch,
            })),
        };
        control_send
            .write_all(&encode_client_control_message(&stop).unwrap())
            .await
            .unwrap();
        let response = tokio::time::timeout(
            Duration::from_secs(1),
            read_control_frame(&mut control_receive),
        )
        .await
        .expect("stop response was not returned")
        .unwrap()
        .unwrap();
        let response = decode_host_control_message(&response).unwrap();
        assert_eq!(response.request_id, 3);
        assert!(matches!(
            response.payload,
            Some(host_control_envelope::Payload::SessionStopped(_))
        ));
        control_send.finish().unwrap();
        let control_eof = tokio::time::timeout(
            Duration::from_secs(1),
            read_control_frame(&mut control_receive),
        )
        .await
        .expect("server did not finish the acknowledged control stream")
        .unwrap();
        assert!(control_eof.is_none());

        let server_result = tokio::time::timeout(Duration::from_secs(1), server_task)
            .await
            .expect("server connection task did not stop")
            .unwrap();
        assert!(server_result.is_ok(), "{server_result:?}");
        client_connection.close(VarInt::from_u32(0), b"test complete");
        client_endpoint.close(VarInt::from_u32(0), b"test complete");
        server_endpoint.close(VarInt::from_u32(0), b"test complete");
    }
}
