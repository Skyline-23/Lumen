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
    decode_client_control_message, decode_client_input_message, encode_codec_configuration_message,
    encode_host_control_message, encode_host_input_message, host_input_envelope, HostInputEnvelope,
    HostSessionCapabilities, NativeInputAck, NATIVE_CONTROL_MESSAGE_LIMIT,
    NATIVE_INPUT_MESSAGE_LIMIT,
};
use quinn::crypto::rustls::QuicServerConfig;
use quinn::{Endpoint, RecvStream, ServerConfig, TransportConfig, VarInt};
use rustls::pki_types::PrivateKeyDer;
use tokio::sync::Notify;

use super::media::NativeUdpMediaTransport;
use super::SharedControlRouter;
use crate::control::NativeConnectionContext;
use crate::native_input::NativeInputSequence;
use crate::network_ports::{NATIVE_QUIC_OFFSET, VIDEO_UDP_OFFSET};
use crate::{HostArguments, NativeStreamControl, PlatformSessionControl};

const ALPN: &[u8] = b"lumen-stream/2";
const EXPORTER_LABEL: &[u8] = b"EXPORTER-Lumen-Session-v2";
const SERVER_START_TIMEOUT: Duration = Duration::from_secs(2);
const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(10);
const CONNECTION_STREAM_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Default)]
pub struct QuicSessionTransport {
    server: Option<QuicServerHandle>,
    media: NativeUdpMediaTransport,
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
        let media_port = media_port(arguments)?;
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
        self.media
            .start(arguments, Arc::clone(&router), Arc::clone(&platform))?;
        let thread = match thread::Builder::new()
            .name("lumen-quic-session".to_owned())
            .spawn(move || {
                run_server(
                    config,
                    address,
                    QuicServerContext {
                        media_port,
                        router,
                        platform,
                        configuration_notify,
                        stop: thread_stop,
                    },
                    ready,
                )
            }) {
            Ok(thread) => thread,
            Err(error) => {
                let media_error = self.media.stop().err();
                return Err(transport_start_error(
                    format!("could not start QUIC session thread: {error}"),
                    media_error,
                ));
            }
        };
        let local_address = match ready_result.recv_timeout(SERVER_START_TIMEOUT) {
            Ok(Ok(address)) => address,
            Ok(Err(error)) => {
                let _ = thread.join();
                let media_error = self.media.stop().err();
                return Err(transport_start_error(error, media_error));
            }
            Err(_) => {
                stop.store(true, Ordering::Release);
                let _ = thread.join();
                let media_error = self.media.stop().err();
                return Err(transport_start_error(
                    "QUIC session server did not become ready".to_owned(),
                    media_error,
                ));
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
        let quic_result = stop_quic_server(self.server.take());
        let media_result = self.media.stop();
        match (quic_result, media_result) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(quic), Ok(())) => Err(quic),
            (Ok(()), Err(media)) => Err(media),
            (Err(quic), Err(media)) => {
                Err(format!("{quic}; native UDP media stop failed: {media}"))
            }
        }
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

fn transport_start_error(primary: String, media_error: Option<String>) -> String {
    match media_error {
        Some(media_error) => {
            format!("{primary}; native UDP media rollback also failed: {media_error}")
        }
        None => primary,
    }
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
    media_port: u16,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
    configuration_notify: Arc<Notify>,
    stop: Arc<AtomicBool>,
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
            let media_port = context.media_port;
            tokio::spawn(async move {
                if let Ok(connection) = incoming.await {
                    if let Err(_error) = handle_connection(
                        connection,
                        media_port,
                        router,
                        platform,
                        configuration_notify,
                    )
                    .await
                    {
                        #[cfg(test)]
                        eprintln!("QUIC session failed: {_error}");
                    }
                }
            });
        }
        endpoint.close(VarInt::from_u32(0), b"host shutdown");
        endpoint.wait_idle().await;
    });
}

async fn handle_connection(
    connection: quinn::Connection,
    media_port: u16,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
    configuration_notify: Arc<Notify>,
) -> Result<(), String> {
    let (mut send, mut receive) =
        tokio::time::timeout(CONNECTION_STREAM_TIMEOUT, connection.accept_bi())
            .await
            .map_err(|_| "QUIC client did not open the session-control stream".to_owned())?
            .map_err(|error| format!("could not accept QUIC session-control stream: {error}"))?;
    let (session_epoch, media_key, media_challenge) = session_material(&connection)?;
    let context = NativeConnectionContext {
        peer_address: connection.remote_address().ip(),
        session_epoch,
        media_port,
        media_challenge,
        media_key,
        host_capabilities: default_host_capabilities(),
    };
    let input_connection = connection.clone();
    let input_router = Arc::clone(&router);
    let input_platform = Arc::clone(&platform);
    let input_task = tokio::spawn(async move {
        accept_native_input_stream(
            input_connection,
            session_epoch,
            input_router,
            input_platform,
        )
        .await
    });
    let configuration_stop = Arc::new(AtomicBool::new(false));
    let configuration_connection = connection.clone();
    let configuration_router = Arc::clone(&router);
    let configuration_task_stop = Arc::clone(&configuration_stop);
    let configuration_task_notify = Arc::clone(&configuration_notify);
    let configuration_task = tokio::spawn(async move {
        publish_codec_configurations(
            configuration_connection,
            session_epoch,
            configuration_router,
            configuration_task_stop,
            configuration_task_notify,
        )
        .await
    });
    let control_result = handle_control_stream(&mut send, &mut receive, &router, &context).await;
    configuration_stop.store(true, Ordering::Release);
    configuration_notify.notify_one();
    let configuration_result = configuration_task
        .await
        .map_err(|error| format!("codec configuration task failed: {error}"))?;
    connection.close(VarInt::from_u32(0), b"session control closed");
    let input_result = input_task
        .await
        .map_err(|error| format!("native input task failed: {error}"))?;
    control_result?;
    configuration_result?;
    input_result
}

async fn publish_codec_configurations(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    stop: Arc<AtomicBool>,
    notify: Arc<Notify>,
) -> Result<(), String> {
    let mut send = tokio::time::timeout(CONNECTION_STREAM_TIMEOUT, connection.open_uni())
        .await
        .map_err(|_| "QUIC client did not admit the codec-configuration stream".to_owned())?
        .map_err(|error| format!("could not open QUIC codec-configuration stream: {error}"))?;
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
        } else {
            notify.notified().await;
        }
    }
    send.finish()
        .map_err(|error| format!("could not finish codec-configuration stream: {error}"))?;
    Ok(())
}

async fn handle_control_stream(
    send: &mut quinn::SendStream,
    receive: &mut RecvStream,
    router: &SharedControlRouter,
    context: &NativeConnectionContext,
) -> Result<(), String> {
    while let Some(frame) = read_control_frame(receive).await? {
        let request = decode_client_control_message(&frame)
            .map_err(|error| format!("invalid QUIC control frame: {error:?}"))?;
        let responses = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())?
            .dispatch_native_control(request, context);
        for response in responses {
            let encoded = encode_host_control_message(&response)
                .map_err(|error| format!("could not encode QUIC control response: {error:?}"))?;
            send.write_all(&encoded)
                .await
                .map_err(|error| format!("could not write QUIC control response: {error}"))?;
        }
    }
    send.finish()
        .map_err(|error| format!("could not finish QUIC session-control stream: {error}"))?;
    send.stopped()
        .await
        .map_err(|error| format!("QUIC session-control response was not acknowledged: {error}"))?;
    Ok(())
}

async fn accept_native_input_stream(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), String> {
    let (mut send, mut receive) =
        tokio::time::timeout(CONNECTION_STREAM_TIMEOUT, connection.accept_bi())
            .await
            .map_err(|_| "QUIC client did not open the reliable input stream".to_owned())?
            .map_err(|error| format!("could not accept QUIC reliable input stream: {error}"))?;
    let guard = NativeInputResetGuard::new(session_epoch, Arc::clone(&platform));
    let mut sequence = NativeInputSequence::new(session_epoch);
    let mut command_sequence = 1_u64;
    while let Some(frame) = read_input_frame(&mut receive).await? {
        let envelope = decode_client_input_message(&frame)
            .map_err(|error| format!("invalid QUIC input frame: {error:?}"))?;
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
        platform
            .handle_native_input(session_epoch, event)
            .map_err(|error| format!("native platform input failed: {error}"))?;
        let response = HostInputEnvelope {
            session_epoch,
            command_sequence,
            payload: Some(host_input_envelope::Payload::Ack(NativeInputAck {
                highest_contiguous_event_sequence: sequence.highest_contiguous_event_sequence(),
            })),
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
    send.finish()
        .map_err(|error| format!("could not finish QUIC input stream: {error}"))?;
    send.stopped()
        .await
        .map_err(|error| format!("QUIC input response was not acknowledged: {error}"))?;
    guard.reset()
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

fn session_material(connection: &quinn::Connection) -> Result<(u32, [u8; 16], [u8; 32]), String> {
    let mut material = [0_u8; 52];
    connection
        .export_keying_material(&mut material, EXPORTER_LABEL, b"")
        .map_err(|_| "could not derive QUIC session key material".to_owned())?;
    let mut epoch = u32::from_be_bytes(material[0..4].try_into().unwrap());
    if epoch == 0 {
        epoch = 1;
    }
    let media_key = material[4..20].try_into().unwrap();
    let media_challenge = material[20..52].try_into().unwrap();
    Ok((epoch, media_key, media_challenge))
}

fn default_host_capabilities() -> HostSessionCapabilities {
    HostSessionCapabilities {
        supported_features: 0,
        maximum_width: 7_680,
        maximum_height: 4_320,
        maximum_refresh_millihz: 240_000,
        maximum_datagram_payload: 1_200,
        maximum_receive_memory_bytes: 256 * 1024 * 1024,
        supports_h264: true,
        supports_hevc_main: true,
        supports_hevc_main10: false,
        supports_av1_main: false,
        supports_av1_main10: false,
        supports_hdr10: false,
        supported_opus_channel_counts: vec![2, 6, 8],
    }
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
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let crypto = QuicServerConfig::try_from(tls)
        .map_err(|error| format!("QUIC TLS configuration is invalid: {error}"))?;
    let mut config = ServerConfig::with_crypto(Arc::new(crypto));
    let mut transport = TransportConfig::default();
    transport.max_concurrent_bidi_streams(VarInt::from_u32(3));
    // The client never opens unidirectional streams. The host opens one outbound codec stream.
    transport.max_concurrent_uni_streams(VarInt::from_u32(0));
    transport.datagram_receive_buffer_size(None);
    transport.datagram_send_buffer_size(0);
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

fn media_port(arguments: &HostArguments) -> Result<u16, String> {
    base_port(arguments)?
        .checked_add(VIDEO_UDP_OFFSET)
        .ok_or_else(|| "native media port overflowed".to_owned())
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
    use std::net::{Ipv4Addr, UdpSocket};
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    use lumen_engine::{
        client_control_envelope, client_input_envelope, decode_host_control_message,
        decode_host_input_message, host_control_envelope, host_input_envelope,
        ClientControlEnvelope, ClientInputEnvelope, ClientSessionHello, CodecConfiguration,
        CodecConfigurationAck, MediaPathResponse, NativeAudioChannelMode, NativeAudioQuality,
        NativeDisplayGamut, NativeDisplayTransfer, NativeDynamicRange, NativeKeyboardInput,
        NativePolicyMode, NativeVideoCapability, NativeVideoCodec, StartSessionAck,
    };
    use quinn::crypto::rustls::QuicClientConfig;
    use rustls::pki_types::CertificateDer;
    use serde_json::json;

    use super::*;
    use crate::{
        media::native_path::{
            decode_native_path_probe, encode_native_path_probe, NativePathProbe,
            NativePathProbeKind, PATH_DATAGRAM_BYTES,
        },
        ControlRouter, HostAuthorities, HostAuthorityPaths, HostDiscoveryState,
        IdlePlatformSessionControl,
    };

    #[test]
    fn quic_bootstrap_authenticates_and_derives_one_native_media_session() {
        let root = tempfile::tempdir().unwrap();
        let (certificate, certificate_der) = write_identity(root.path());
        let (router, application_id) = test_router(root.path());
        let arguments = test_arguments(root.path(), &certificate);
        let shared_router = Arc::new(Mutex::new(router));
        let mut transport = QuicSessionTransport::default();
        transport
            .start(
                &arguments,
                Arc::clone(&shared_router),
                Arc::new(IdlePlatformSessionControl),
            )
            .unwrap();
        let server = transport.local_address().unwrap();

        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let expected_media_key = runtime.block_on(async {
            let mut roots = rustls::RootCertStore::empty();
            roots.add(certificate_der).unwrap();
            let mut tls = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            tls.alpn_protocols = vec![ALPN.to_vec()];
            let crypto = QuicClientConfig::try_from(tls).unwrap();
            let mut client = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
            let mut client_config = quinn::ClientConfig::new(Arc::new(crypto));
            let mut client_transport = TransportConfig::default();
            client_transport.max_concurrent_uni_streams(VarInt::from_u32(1));
            client_config.transport_config(Arc::new(client_transport));
            client.set_default_client_config(client_config);
            let connection = client
                .connect(
                    SocketAddr::from((Ipv4Addr::LOCALHOST, server.port())),
                    "localhost",
                )
                .unwrap()
                .await
                .unwrap();
            assert!(connection.max_datagram_size().is_none());

            let expected_material = session_material(&connection).unwrap();
            let (mut send, mut receive) = connection.open_bi().await.unwrap();
            let (mut input_send, mut input_receive) = connection.open_bi().await.unwrap();
            let request = ClientControlEnvelope {
                request_id: 7,
                payload: Some(client_control_envelope::Payload::Hello(native_hello(
                    application_id,
                ))),
            };
            send.write_all(&lumen_engine::encode_client_control_message(&request).unwrap())
                .await
                .unwrap();
            let plan = decode_host_control_message(
                &read_control_frame(&mut receive).await.unwrap().unwrap(),
            )
            .unwrap();
            let challenge = decode_host_control_message(
                &read_control_frame(&mut receive).await.unwrap().unwrap(),
            )
            .unwrap();

            let host_control_envelope::Payload::SessionPlan(plan) = plan.payload.unwrap() else {
                panic!("first host response was not the negotiated session plan");
            };
            let host_control_envelope::Payload::MediaPath(challenge) = challenge.payload.unwrap()
            else {
                panic!("second host response was not the native media-path challenge");
            };
            assert_eq!(plan.session_epoch, expected_material.0);
            assert_eq!(challenge.session_epoch, expected_material.0);
            assert_eq!(challenge.path_id, plan.path_id);
            assert_eq!(challenge.token, expected_material.2);

            let media = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
            media
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let probe = encode_native_path_probe(
                NativePathProbe {
                    kind: NativePathProbeKind::Request,
                    session_epoch: plan.session_epoch,
                    path_id: plan.path_id as u16,
                    challenge: expected_material.2,
                },
                &expected_material.1,
            )
            .unwrap();
            media
                .send_to(
                    &probe,
                    SocketAddr::from((Ipv4Addr::LOCALHOST, challenge.media_port as u16)),
                )
                .unwrap();
            let mut probe_response = [0_u8; PATH_DATAGRAM_BYTES];
            let (length, _) = media.recv_from(&mut probe_response).unwrap();
            assert_eq!(length, PATH_DATAGRAM_BYTES);
            assert_eq!(
                decode_native_path_probe(&probe_response, &expected_material.1)
                    .unwrap()
                    .kind,
                NativePathProbeKind::Response
            );

            let path_response = ClientControlEnvelope {
                request_id: 8,
                payload: Some(client_control_envelope::Payload::MediaPath(
                    MediaPathResponse {
                        session_epoch: plan.session_epoch,
                        path_id: plan.path_id,
                        token: expected_material.2.to_vec(),
                    },
                )),
            };
            send.write_all(&lumen_engine::encode_client_control_message(&path_response).unwrap())
                .await
                .unwrap();
            let validated = decode_host_control_message(
                &read_control_frame(&mut receive).await.unwrap().unwrap(),
            )
            .unwrap();
            assert!(matches!(
                validated.payload,
                Some(host_control_envelope::Payload::MediaPathValidated(_))
            ));

            let start = ClientControlEnvelope {
                request_id: 9,
                payload: Some(client_control_envelope::Payload::StartSession(
                    StartSessionAck {
                        session_epoch: plan.session_epoch,
                    },
                )),
            };
            send.write_all(&lumen_engine::encode_client_control_message(&start).unwrap())
                .await
                .unwrap();
            let started = decode_host_control_message(
                &read_control_frame(&mut receive).await.unwrap().unwrap(),
            )
            .unwrap();
            assert!(matches!(
                started.payload,
                Some(host_control_envelope::Payload::SessionStarted(_))
            ));

            let configuration = CodecConfiguration {
                session_epoch: plan.session_epoch,
                stream_id: plan.video_stream_id,
                configuration_id: plan.video_configuration_id,
                codec: plan.video_codec,
                decoder_configuration_record: vec![1, 2, 3, 4],
            };
            assert!(shared_router
                .lock()
                .unwrap()
                .publish_native_codec_configuration(configuration.clone()));
            let mut configuration_receive =
                tokio::time::timeout(CONNECTION_STREAM_TIMEOUT, connection.accept_uni())
                    .await
                    .unwrap()
                    .unwrap();
            assert_eq!(
                read_control_frame(&mut configuration_receive)
                    .await
                    .unwrap()
                    .unwrap(),
                lumen_engine::encode_codec_configuration_message(&configuration).unwrap()
            );
            let configuration_ack = ClientControlEnvelope {
                request_id: 10,
                payload: Some(client_control_envelope::Payload::CodecConfigurationAck(
                    CodecConfigurationAck {
                        session_epoch: plan.session_epoch,
                        stream_id: plan.video_stream_id,
                        configuration_id: plan.video_configuration_id,
                    },
                )),
            };
            send.write_all(
                &lumen_engine::encode_client_control_message(&configuration_ack).unwrap(),
            )
            .await
            .unwrap();

            let input = ClientInputEnvelope {
                session_epoch: plan.session_epoch,
                event_sequence: 1,
                payload: Some(client_input_envelope::Payload::Keyboard(
                    NativeKeyboardInput {
                        hid_usage: 0x04,
                        pressed: true,
                        modifiers: 0,
                        repeat: false,
                    },
                )),
            };
            input_send
                .write_all(&lumen_engine::encode_client_input_message(&input).unwrap())
                .await
                .unwrap();
            let ack = decode_host_input_message(
                &read_input_frame(&mut input_receive).await.unwrap().unwrap(),
            )
            .unwrap();
            let Some(host_input_envelope::Payload::Ack(ack)) = ack.payload else {
                panic!("host input response was not an acknowledgement");
            };
            assert_eq!(ack.highest_contiguous_event_sequence, 1);

            input_send.finish().unwrap();
            assert!(read_input_frame(&mut input_receive)
                .await
                .unwrap()
                .is_none());
            send.finish().unwrap();
            assert!(read_control_frame(&mut receive).await.unwrap().is_none());
            assert!(configuration_receive
                .read(&mut [0_u8; 1])
                .await
                .unwrap()
                .is_none());

            connection.close(VarInt::from_u32(0), b"test complete");
            client.wait_idle().await;
            expected_material.1
        });

        let pending_key = shared_router
            .lock()
            .unwrap()
            .pending_native_media_key_from_test();
        assert_eq!(pending_key, Some(expected_media_key));
        transport.stop().unwrap();
    }

    struct TestIdentity {
        cert_path: PathBuf,
        key_path: PathBuf,
    }

    fn write_identity(root: &Path) -> (TestIdentity, CertificateDer<'static>) {
        let identity = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()]).unwrap();
        let cert_path = root.join("cert.pem");
        let key_path = root.join("key.pem");
        fs::write(&cert_path, identity.cert.pem()).unwrap();
        fs::write(&key_path, identity.signing_key.serialize_pem()).unwrap();
        (
            TestIdentity {
                cert_path,
                key_path,
            },
            identity.cert.der().clone(),
        )
    }

    fn test_arguments(root: &Path, identity: &TestIdentity) -> HostArguments {
        let occupied = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let quic_port = occupied.local_addr().unwrap().port();
        assert!(quic_port > NATIVE_QUIC_OFFSET);
        drop(occupied);
        let base_port = quic_port - NATIVE_QUIC_OFFSET;
        let mut values = crate::config::tests::valid_arguments();
        replace_argument(&mut values, "address_family", "ipv4".to_owned());
        replace_argument(&mut values, "port", base_port.to_string());
        replace_argument(
            &mut values,
            "cert",
            identity.cert_path.display().to_string(),
        );
        replace_argument(&mut values, "pkey", identity.key_path.display().to_string());
        replace_argument(
            &mut values,
            "credentials_file",
            root.join("credentials.json").display().to_string(),
        );
        replace_argument(
            &mut values,
            "file_apps",
            root.join("apps.json").display().to_string(),
        );
        replace_argument(
            &mut values,
            "file_state",
            root.join("state.json").display().to_string(),
        );
        HostArguments::parse(values).unwrap()
    }

    fn replace_argument(values: &mut [String], key: &str, value: String) {
        let prefix = format!("{key}=");
        let argument = values
            .iter_mut()
            .find(|argument| argument.starts_with(&prefix))
            .unwrap();
        *argument = format!("{key}={value}");
    }

    fn test_router(root: &Path) -> (ControlRouter, u32) {
        let expires_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3_600;
        fs::write(
            root.join("devices.json"),
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
            settings: root.join("settings.json"),
            owner_account: root.join("owner-account.json"),
            devices: root.join("devices.json"),
            applications: root.join("apps.json"),
            host_identity: root.join("state.json"),
        };
        let authorities = HostAuthorities::open_native(paths).unwrap();
        authorities
            .applications()
            .upsert(r#"{"uuid":"native-desktop","name":"Desktop"}"#)
            .unwrap();
        let application_id = authorities.applications().applications().unwrap()[0].id;
        (
            ControlRouter::new_with_platform(
                authorities,
                HostDiscoveryState::test_default(),
                Arc::new(IdlePlatformSessionControl),
            ),
            application_id,
        )
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
}
