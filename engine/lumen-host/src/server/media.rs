use std::collections::HashSet;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use super::SharedControlRouter;
use crate::control::{AudioDeliveryState, InputMotionDeliveryState, VideoDeliveryState};
use crate::media::native_motion::{
    NativeMotionDatagramError, NativeMotionIdentity, NativeMotionReceiver,
};
use crate::media::native_packet::{NativeMediaPacketizer, NativeMediaPacketizerConfig};
use crate::media::native_path::{
    decode_native_path_probe, encode_native_path_probe, native_path_probe_identity,
    NativePathProbe, NativePathProbeKind,
};
use crate::media::native_video::{
    NativeVideoBitstreamNormalizer, NativeVideoConfiguration, NormalizedNativeVideoFrame,
};
use crate::network_ports::VIDEO_UDP_OFFSET;
use crate::{
    HostArguments, PlatformRuntimeEvent, PlatformRuntimeEventCode, PlatformRuntimeEventDisposition,
    PlatformRuntimeEventSeverity, PlatformSessionControl,
};
use lumen_engine::{
    decode_native_media_datagram, CodecConfiguration, NativeMediaKind, NativeVideoCodec,
    NATIVE_AUDIO_STREAM_ID, NATIVE_INITIAL_CONFIGURATION_ID, NATIVE_VIDEO_STREAM_ID,
};

const MEDIA_SEND_POLL_INTERVAL: Duration = Duration::from_millis(1);
const MAXIMUM_CLIENT_DATAGRAM_BYTES: usize = 2_048;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum MediaKind {
    Video,
    Audio,
}

#[derive(Debug)]
struct MediaFailure {
    code: PlatformRuntimeEventCode,
    kind: MediaKind,
    stage: &'static str,
    message: String,
}

#[derive(Debug)]
enum MediaAttempt {
    Inactive,
    Idle,
    Waiting,
    Sent,
    Failed(MediaFailure),
}

impl MediaAttempt {
    fn did_work(&self) -> bool {
        matches!(self, Self::Sent)
    }
}

#[derive(Default)]
struct MediaFailureReporter {
    active: HashSet<PlatformRuntimeEventCode>,
}

#[derive(Default)]
struct InputMotionFailureReporter {
    active: bool,
}

impl InputMotionFailureReporter {
    fn applied(&mut self, platform: &dyn PlatformSessionControl) {
        if self.active {
            self.active = false;
            let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
                disposition: PlatformRuntimeEventDisposition::Cleared,
                severity: PlatformRuntimeEventSeverity::Warning,
                code: PlatformRuntimeEventCode::NativeInputMotion,
                message: None,
            });
        }
    }

    fn rejected(&mut self, message: String, platform: &dyn PlatformSessionControl) {
        if self.active {
            return;
        }
        self.active = true;
        let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Warning,
            code: PlatformRuntimeEventCode::NativeInputMotion,
            message: Some(format!("native-input-motion-apply-failed: {message}")),
        });
    }
}

impl MediaFailureReporter {
    fn observe(
        &mut self,
        kind: MediaKind,
        attempt: &MediaAttempt,
        platform: &dyn PlatformSessionControl,
    ) {
        match attempt {
            MediaAttempt::Failed(failure) => self.raise(failure, platform),
            MediaAttempt::Inactive | MediaAttempt::Sent => self.clear_kind(kind, platform),
            MediaAttempt::Idle | MediaAttempt::Waiting => (),
        }
    }

    fn clear_kind(&mut self, kind: MediaKind, platform: &dyn PlatformSessionControl) {
        for code in failure_codes(kind) {
            if self.active.remove(&code) {
                let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
                    disposition: PlatformRuntimeEventDisposition::Cleared,
                    severity: PlatformRuntimeEventSeverity::Warning,
                    code,
                    message: None,
                });
            }
        }
    }

    fn raise(&mut self, failure: &MediaFailure, platform: &dyn PlatformSessionControl) {
        let message = format!(
            "native-media-{}-{}: {}",
            media_kind_name(failure.kind),
            failure.stage,
            failure.message
        );
        if !self.active.insert(failure.code) {
            return;
        }
        eprintln!("Lumen native media warning code={message}");
        let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Warning,
            code: failure.code,
            message: Some(message),
        });
    }
}

fn failure_codes(kind: MediaKind) -> [PlatformRuntimeEventCode; 3] {
    match kind {
        MediaKind::Video => [
            PlatformRuntimeEventCode::NativeVideoCapturePoll,
            PlatformRuntimeEventCode::NativeVideoPacketizer,
            PlatformRuntimeEventCode::NativeVideoUdpSend,
        ],
        MediaKind::Audio => [
            PlatformRuntimeEventCode::NativeAudioCapturePoll,
            PlatformRuntimeEventCode::NativeAudioPacketizer,
            PlatformRuntimeEventCode::NativeAudioUdpSend,
        ],
    }
}

fn media_kind_name(kind: MediaKind) -> &'static str {
    match kind {
        MediaKind::Video => "video",
        MediaKind::Audio => "audio",
    }
}

#[derive(Default)]
pub(super) struct NativeUdpMediaTransport {
    server: Option<MediaServerHandle>,
}

impl NativeUdpMediaTransport {
    pub(super) fn start(
        &mut self,
        arguments: &HostArguments,
        router: SharedControlRouter,
        platform: Arc<dyn PlatformSessionControl>,
    ) -> Result<(), String> {
        if self.server.is_some() {
            return Err("native UDP media transport is already running".to_owned());
        }
        self.server = Some(start_native_media_server(arguments, router, platform)?);
        Ok(())
    }

    pub(super) fn stop(&mut self) -> Result<(), String> {
        stop_media_server(self.server.take())
    }
}

impl Drop for NativeUdpMediaTransport {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

struct MediaServerHandle {
    stop: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
}

fn start_native_media_server(
    arguments: &HostArguments,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<MediaServerHandle, String> {
    let address = native_media_address(arguments)?;
    let socket = UdpSocket::bind(address)
        .map_err(|error| format!("could not bind native UDP media socket at {address}: {error}"))?;
    socket
        .set_nonblocking(true)
        .map_err(|error| format!("could not make native UDP media socket nonblocking: {error}"))?;
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let thread = thread::Builder::new()
        .name("lumen-native-udp-media".to_owned())
        .spawn(move || native_receive_loop(socket, router, platform, thread_stop))
        .map_err(|error| format!("could not start native UDP media worker: {error}"))?;
    Ok(MediaServerHandle {
        stop,
        threads: vec![thread],
    })
}

fn stop_media_server(server: Option<MediaServerHandle>) -> Result<(), String> {
    let Some(server) = server else {
        return Ok(());
    };
    server.stop.store(true, Ordering::Release);
    if server
        .threads
        .into_iter()
        .any(|thread| thread.join().is_err())
    {
        Err("native UDP media worker panicked".to_owned())
    } else {
        Ok(())
    }
}

fn native_receive_loop(
    socket: UdpSocket,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
    stop: Arc<AtomicBool>,
) {
    let mut datagram = [0_u8; MAXIMUM_CLIENT_DATAGRAM_BYTES];
    let mut video_sender = VideoSenderState::default();
    let mut audio_sender = AudioSenderState::default();
    let mut failure_reporter = MediaFailureReporter::default();
    let mut motion_receiver = NativeMotionReceiver::default();
    let mut motion_failure_reporter = InputMotionFailureReporter::default();
    while !stop.load(Ordering::Acquire) {
        let received = match socket.recv_from(&mut datagram) {
            Ok((length, peer)) => {
                if !handle_native_path_probe(&socket, &router, peer, &datagram[..length]) {
                    let _ = handle_native_motion_datagram(
                        &router,
                        platform.as_ref(),
                        peer,
                        &datagram[..length],
                        &mut motion_receiver,
                        &mut motion_failure_reporter,
                    );
                }
                true
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => false,
            Err(_) => false,
        };
        let video_attempt =
            send_pending_video(&socket, &router, platform.as_ref(), &mut video_sender);
        failure_reporter.observe(MediaKind::Video, &video_attempt, platform.as_ref());
        let audio_attempt =
            send_pending_audio(&socket, &router, platform.as_ref(), &mut audio_sender);
        failure_reporter.observe(MediaKind::Audio, &audio_attempt, platform.as_ref());
        if !received && !video_attempt.did_work() && !audio_attempt.did_work() {
            thread::sleep(MEDIA_SEND_POLL_INTERVAL);
        }
    }
}

fn handle_native_motion_datagram(
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    peer: SocketAddr,
    datagram: &[u8],
    receiver: &mut NativeMotionReceiver,
    failure_reporter: &mut InputMotionFailureReporter,
) -> bool {
    let Ok(decoded) = decode_native_media_datagram(datagram) else {
        return false;
    };
    if decoded.header.kind != NativeMediaKind::InputMotion {
        return false;
    }
    let Some(delivery) = router
        .lock()
        .ok()
        .and_then(|router| router.input_motion_delivery_state())
    else {
        log_motion_rejection("inactive-session", peer, decoded.header.session_epoch, None);
        return true;
    };
    apply_native_motion_datagram(
        platform,
        peer,
        datagram,
        &delivery,
        receiver,
        failure_reporter,
    );
    true
}

fn apply_native_motion_datagram(
    platform: &dyn PlatformSessionControl,
    peer: SocketAddr,
    datagram: &[u8],
    delivery: &InputMotionDeliveryState,
    receiver: &mut NativeMotionReceiver,
    failure_reporter: &mut InputMotionFailureReporter,
) {
    if peer != delivery.endpoint {
        log_motion_rejection(
            "endpoint-mismatch",
            peer,
            delivery.session_epoch,
            Some(delivery.endpoint),
        );
        return;
    }
    let identity = NativeMotionIdentity {
        session_epoch: delivery.session_epoch,
        path_id: delivery.path_id,
        policy_revision: delivery.policy_revision,
    };
    let accepted = match receiver.accept(datagram, identity, &delivery.encryption_key) {
        Ok(accepted) => accepted,
        Err(error) => {
            log_motion_decode_rejection(peer, identity, error);
            return;
        }
    };
    let payload = motion_payload_name(&accepted.event);
    if should_log_motion(accepted.motion_sequence) {
        for stage in ["authenticated", "decoded", "sequence-accepted"] {
            eprintln!(
                "Lumen native motion stage={stage} session-epoch={} path-id={} policy-revision={} packet-sequence={} motion-sequence={} capture-timestamp-us={} payload={} peer={peer}",
                accepted.identity.session_epoch,
                accepted.identity.path_id,
                accepted.identity.policy_revision,
                accepted.packet_sequence,
                accepted.motion_sequence,
                accepted.capture_timestamp_us,
                payload,
            );
        }
    }
    match platform.handle_native_motion(accepted.identity.session_epoch, accepted.event) {
        Ok(()) => {
            failure_reporter.applied(platform);
            if should_log_motion(accepted.motion_sequence) {
                eprintln!(
                    "Lumen native motion stage=applied session-epoch={} motion-sequence={} payload={} peer={peer}",
                    accepted.identity.session_epoch, accepted.motion_sequence, payload
                );
            }
        }
        Err(error) => {
            eprintln!(
                "Lumen native motion stage=apply-rejected session-epoch={} motion-sequence={} payload={} peer={peer} error={error}",
                accepted.identity.session_epoch, accepted.motion_sequence, payload
            );
            failure_reporter.rejected(error, platform);
        }
    }
}

fn motion_payload_name(event: &crate::PlatformNativeMotionEvent) -> &'static str {
    match event {
        crate::PlatformNativeMotionEvent::Pointer { .. } => "pointer",
        crate::PlatformNativeMotionEvent::Scroll { .. } => "scroll",
        crate::PlatformNativeMotionEvent::Touch { .. } => "touch",
        crate::PlatformNativeMotionEvent::Pen { .. } => "pen",
        crate::PlatformNativeMotionEvent::Gamepad { .. } => "gamepad",
    }
}

fn should_log_motion(sequence: u32) -> bool {
    sequence <= 3 || sequence % 120 == 0
}

fn log_motion_rejection(
    reason: &'static str,
    peer: SocketAddr,
    session_epoch: u32,
    expected_peer: Option<SocketAddr>,
) {
    eprintln!(
        "Lumen native motion stage=rejected reason={reason} session-epoch={session_epoch} peer={peer} expected-peer={}",
        expected_peer.map_or_else(|| "none".to_owned(), |value| value.to_string())
    );
}

fn log_motion_decode_rejection(
    peer: SocketAddr,
    identity: NativeMotionIdentity,
    error: NativeMotionDatagramError,
) {
    eprintln!(
        "Lumen native motion stage=rejected reason={error:?} session-epoch={} path-id={} policy-revision={} peer={peer}",
        identity.session_epoch, identity.path_id, identity.policy_revision
    );
}

fn handle_native_path_probe(
    socket: &UdpSocket,
    router: &SharedControlRouter,
    peer: SocketAddr,
    datagram: &[u8],
) -> bool {
    let Some((session_epoch, path_id)) = native_path_probe_identity(datagram) else {
        return false;
    };
    let Some(key) = router
        .lock()
        .ok()
        .and_then(|router| router.pending_native_media_key(session_epoch))
    else {
        return false;
    };
    let Ok(probe) = decode_native_path_probe(datagram, &key) else {
        return false;
    };
    if probe.kind != NativePathProbeKind::Request || probe.path_id != path_id {
        return false;
    }
    let Ok(response) = encode_native_path_probe(
        NativePathProbe {
            kind: NativePathProbeKind::Response,
            ..probe
        },
        &key,
    ) else {
        return false;
    };
    if socket.send_to(&response, peer).ok() != Some(response.len()) {
        return false;
    }
    router.lock().is_ok_and(|mut router| {
        router.observe_native_media_path(peer, session_epoch, path_id, &probe.challenge)
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AudioSessionIdentity {
    session_epoch: u32,
    path_id: u16,
    key: [u8; 16],
}

#[derive(Default)]
struct AudioSenderState {
    identity: Option<AudioSessionIdentity>,
    packetizer: Option<NativeMediaPacketizer>,
    unit_id: u32,
}

impl AudioSenderState {
    fn prepare(&mut self, delivery: &AudioDeliveryState) -> Result<(), String> {
        let identity = AudioSessionIdentity {
            session_epoch: delivery.session_epoch,
            path_id: delivery.path_id,
            key: delivery.encryption_key,
        };
        if self.identity.as_ref() == Some(&identity) {
            return self
                .packetizer
                .as_mut()
                .ok_or_else(|| "audio packetizer is unavailable".to_owned())?
                .reconfigure(delivery.policy_revision, delivery.maximum_datagram_payload);
        }
        self.packetizer = Some(NativeMediaPacketizer::new(
            NativeMediaPacketizerConfig {
                session_epoch: delivery.session_epoch,
                path_id: delivery.path_id,
                policy_revision: delivery.policy_revision,
                stream_id: NATIVE_AUDIO_STREAM_ID,
                configuration_id: NATIVE_INITIAL_CONFIGURATION_ID,
                maximum_datagram_payload: delivery.maximum_datagram_payload,
                direct_udp_key: delivery.encryption_key,
            },
            0,
        )?);
        self.unit_id = 1;
        self.identity = Some(identity);
        Ok(())
    }
}

fn send_pending_audio(
    socket: &UdpSocket,
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    sender: &mut AudioSenderState,
) -> MediaAttempt {
    let delivery = match router
        .lock()
        .ok()
        .and_then(|router| router.audio_delivery_state())
    {
        Some(delivery) => delivery,
        None => return MediaAttempt::Inactive,
    };
    poll_and_send_audio(socket, &delivery, platform, sender)
}

fn poll_and_send_audio(
    socket: &UdpSocket,
    delivery: &AudioDeliveryState,
    platform: &dyn PlatformSessionControl,
    sender: &mut AudioSenderState,
) -> MediaAttempt {
    let packet = match platform.poll_encoded_audio() {
        Ok(Some(packet)) => packet,
        Ok(None) => return MediaAttempt::Idle,
        Err(message) => {
            return MediaAttempt::Failed(MediaFailure {
                code: PlatformRuntimeEventCode::NativeAudioCapturePoll,
                kind: MediaKind::Audio,
                stage: "capture-poll-failed",
                message,
            })
        }
    };
    match send_audio_packet(socket, delivery, sender, packet) {
        Ok(()) => MediaAttempt::Sent,
        Err(failure) => MediaAttempt::Failed(failure),
    }
}

fn send_audio_packet(
    socket: &UdpSocket,
    delivery: &AudioDeliveryState,
    sender: &mut AudioSenderState,
    packet: crate::PlatformEncodedAudioPacket,
) -> Result<(), MediaFailure> {
    sender.prepare(delivery).map_err(audio_packetizer_failure)?;
    let unit_id = sender.unit_id;
    let packetized = sender
        .packetizer
        .as_mut()
        .ok_or_else(|| audio_packetizer_failure("audio packetizer is unavailable".to_owned()))?
        .packetize_audio(&packet, unit_id)
        .map_err(audio_packetizer_failure)?;
    sender.unit_id = sender
        .unit_id
        .checked_add(1)
        .ok_or_else(|| audio_packetizer_failure("audio unit id exhausted".to_owned()))?;
    let datagram_count = packetized.datagrams.len();
    for datagram in packetized.datagrams {
        send_datagram(socket, delivery.endpoint, &datagram, "audio").map_err(|message| {
            MediaFailure {
                code: PlatformRuntimeEventCode::NativeAudioUdpSend,
                kind: MediaKind::Audio,
                stage: "udp-send-failed",
                message,
            }
        })?;
    }
    if unit_id <= 3 || unit_id % 200 == 0 {
        eprintln!(
            "Lumen native media sent kind=audio session-epoch={} unit-id={unit_id} datagrams={datagram_count} endpoint={}",
            delivery.session_epoch, delivery.endpoint
        );
    }
    Ok(())
}

fn audio_packetizer_failure(message: String) -> MediaFailure {
    MediaFailure {
        code: PlatformRuntimeEventCode::NativeAudioPacketizer,
        kind: MediaKind::Audio,
        stage: "packetizer-failed",
        message,
    }
}

fn send_datagram(
    socket: &UdpSocket,
    endpoint: SocketAddr,
    datagram: &[u8],
    kind: &str,
) -> Result<(), String> {
    let sent = socket
        .send_to(datagram, endpoint)
        .map_err(|error| format!("{kind} datagram send failed: {error}"))?;
    if sent == datagram.len() {
        Ok(())
    } else {
        Err(format!("{kind} datagram send was incomplete"))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct VideoSessionIdentity {
    video_format: crate::PlatformVideoFormat,
    session_epoch: u32,
    path_id: u16,
    key: [u8; 16],
}

#[derive(Default)]
struct VideoSenderState {
    identity: Option<VideoSessionIdentity>,
    packetizer: Option<NativeMediaPacketizer>,
    normalizer: Option<NativeVideoBitstreamNormalizer>,
    pending_frame: Option<NormalizedNativeVideoFrame>,
    pending_configuration_boundary: Option<u32>,
    frame_index: u32,
    last_sent_frame: Option<SentVideoFrame>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SentVideoFrame {
    frame_id: u32,
    key_frame: bool,
}

impl VideoSenderState {
    fn prepare(&mut self, delivery: &VideoDeliveryState) -> Result<(), String> {
        let identity = VideoSessionIdentity {
            video_format: delivery.video_format,
            session_epoch: delivery.session_epoch,
            path_id: delivery.path_id,
            key: delivery.encryption_key,
        };
        if self.identity.as_ref() == Some(&identity) {
            return self
                .packetizer
                .as_mut()
                .ok_or_else(|| "video packetizer is unavailable".to_owned())?
                .reconfigure(delivery.policy_revision, delivery.maximum_datagram_payload);
        }
        self.packetizer = Some(NativeMediaPacketizer::new(
            NativeMediaPacketizerConfig {
                session_epoch: delivery.session_epoch,
                path_id: delivery.path_id,
                policy_revision: delivery.policy_revision,
                stream_id: NATIVE_VIDEO_STREAM_ID,
                configuration_id: NATIVE_INITIAL_CONFIGURATION_ID,
                maximum_datagram_payload: delivery.maximum_datagram_payload,
                direct_udp_key: delivery.encryption_key,
            },
            0,
        )?);
        self.normalizer = Some(NativeVideoBitstreamNormalizer::new(delivery.video_format));
        self.pending_frame = None;
        self.pending_configuration_boundary = None;
        self.frame_index = 1;
        self.last_sent_frame = None;
        self.identity = Some(identity);
        Ok(())
    }

    fn take_last_sent_frame(&mut self) -> Option<SentVideoFrame> {
        self.last_sent_frame.take()
    }
}

fn send_pending_video(
    socket: &UdpSocket,
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    sender: &mut VideoSenderState,
) -> MediaAttempt {
    let delivery = match router
        .lock()
        .ok()
        .and_then(|router| router.video_delivery_state())
    {
        Some(delivery) => delivery,
        None => return MediaAttempt::Inactive,
    };
    let attempt = poll_and_send_video(socket, &delivery, platform, sender, |configuration| {
        router
            .lock()
            .is_ok_and(|mut router| router.publish_native_codec_configuration(configuration))
    });
    if let Some(sent) = sender.take_last_sent_frame() {
        let _ = router.lock().map(|mut router| {
            router.observe_native_video_frame_sent(
                delivery.session_epoch,
                sent.frame_id,
                sent.key_frame,
            )
        });
    }
    attempt
}

fn poll_and_send_video(
    socket: &UdpSocket,
    delivery: &VideoDeliveryState,
    platform: &dyn PlatformSessionControl,
    sender: &mut VideoSenderState,
    publish_configuration: impl FnOnce(CodecConfiguration) -> bool,
) -> MediaAttempt {
    if let Err(message) = sender.prepare(delivery) {
        return MediaAttempt::Failed(video_packetizer_failure(message));
    }
    if sender.pending_frame.is_none() {
        let frame = match platform.poll_encoded_video() {
            Ok(Some(frame)) => frame,
            Ok(None) => return MediaAttempt::Idle,
            Err(message) => {
                return MediaAttempt::Failed(MediaFailure {
                    code: PlatformRuntimeEventCode::NativeVideoCapturePoll,
                    kind: MediaKind::Video,
                    stage: "capture-poll-failed",
                    message,
                })
            }
        };
        let configuration = match sender.stage(frame) {
            Ok(configuration) => configuration,
            Err(message) => return MediaAttempt::Failed(video_packetizer_failure(message)),
        };
        if let Some(configuration) = configuration {
            let wire = codec_configuration(delivery, configuration);
            if !publish_configuration(wire) {
                return MediaAttempt::Failed(video_packetizer_failure(
                    "video codec configuration could not be published".to_owned(),
                ));
            }
        }
    }
    if let Some(configuration_id) = sender.acknowledged_configuration_boundary(delivery) {
        if let Err(message) = platform.handle_control_event(
            delivery.session_epoch,
            crate::PlatformControlEvent::ResumeVideoEncodingAfterCodecAck,
        ) {
            return MediaAttempt::Failed(video_packetizer_failure(format!(
                "could not resume video encoding after codec acknowledgement: {message}"
            )));
        }
        sender.release_configuration_boundary(configuration_id);
        eprintln!(
            "Lumen native media stage=codec-ack-encoding-resumed session-epoch={} configuration-id={configuration_id}",
            delivery.session_epoch
        );
    }
    match sender.send_staged(socket, delivery) {
        Ok(()) => MediaAttempt::Sent,
        Err(VideoSendError::WaitingForConfiguration) => MediaAttempt::Waiting,
        Err(VideoSendError::Failure(failure)) => MediaAttempt::Failed(failure),
    }
}

#[cfg(test)]
#[path = "media/configuration_header_tests.rs"]
mod configuration_header_tests;

#[cfg(test)]
fn send_video_frame(
    socket: &UdpSocket,
    delivery: &VideoDeliveryState,
    sender: &mut VideoSenderState,
    frame: crate::PlatformEncodedVideoFrame,
) -> Result<(), String> {
    sender.prepare(delivery)?;
    sender.stage(frame)?;
    sender
        .send_staged(socket, delivery)
        .map_err(|error| match error {
            VideoSendError::WaitingForConfiguration => {
                "native video configuration is not acknowledged".to_owned()
            }
            VideoSendError::Failure(failure) => failure.message,
        })
}

#[derive(Debug)]
enum VideoSendError {
    WaitingForConfiguration,
    Failure(MediaFailure),
}

fn video_packetizer_failure(message: String) -> MediaFailure {
    MediaFailure {
        code: PlatformRuntimeEventCode::NativeVideoPacketizer,
        kind: MediaKind::Video,
        stage: "packetizer-failed",
        message,
    }
}

impl VideoSenderState {
    fn stage(
        &mut self,
        frame: crate::PlatformEncodedVideoFrame,
    ) -> Result<Option<NativeVideoConfiguration>, String> {
        if self.pending_frame.is_some() {
            return Err("native video sender already has a pending frame".to_owned());
        }
        let normalized = self
            .normalizer
            .as_mut()
            .ok_or_else(|| "video bitstream normalizer is unavailable".to_owned())?
            .normalize(frame)?;
        let configuration = normalized.new_configuration.clone();
        if let Some(configuration) = &configuration {
            self.pending_configuration_boundary = Some(configuration.configuration_id);
        }
        self.pending_frame = Some(normalized);
        Ok(configuration)
    }

    fn acknowledged_configuration_boundary(&self, delivery: &VideoDeliveryState) -> Option<u32> {
        let configuration_id = self.pending_configuration_boundary?;
        (delivery.acknowledged_configuration_id == Some(configuration_id))
            .then_some(configuration_id)
    }

    fn release_configuration_boundary(&mut self, configuration_id: u32) {
        if self.pending_configuration_boundary == Some(configuration_id) {
            self.pending_configuration_boundary = None;
        }
    }

    fn send_staged(
        &mut self,
        socket: &UdpSocket,
        delivery: &VideoDeliveryState,
    ) -> Result<(), VideoSendError> {
        let normalized = self.pending_frame.as_ref().ok_or_else(|| {
            VideoSendError::Failure(video_packetizer_failure(
                "native video sender has no pending frame".to_owned(),
            ))
        })?;
        if delivery.acknowledged_configuration_id != Some(normalized.configuration_id) {
            return Err(VideoSendError::WaitingForConfiguration);
        }
        self.packetizer
            .as_mut()
            .ok_or_else(|| {
                VideoSendError::Failure(video_packetizer_failure(
                    "video packetizer is unavailable".to_owned(),
                ))
            })?
            .update_video_configuration(normalized.configuration_id)
            .map_err(|message| VideoSendError::Failure(video_packetizer_failure(message)))?;
        let frame_index = self.frame_index;
        let packetized = self
            .packetizer
            .as_mut()
            .ok_or_else(|| {
                VideoSendError::Failure(video_packetizer_failure(
                    "video packetizer is unavailable".to_owned(),
                ))
            })?
            .packetize_video(&normalized.frame, frame_index, delivery.fec_percentage)
            .map_err(|message| VideoSendError::Failure(video_packetizer_failure(message)))?;
        self.frame_index = self.frame_index.checked_add(1).ok_or_else(|| {
            VideoSendError::Failure(video_packetizer_failure(
                "video frame id exhausted".to_owned(),
            ))
        })?;
        let datagram_count = packetized.datagrams.len();
        for datagram in packetized.datagrams {
            let sent = socket
                .send_to(&datagram, delivery.endpoint)
                .map_err(|error| {
                    VideoSendError::Failure(MediaFailure {
                        code: PlatformRuntimeEventCode::NativeVideoUdpSend,
                        kind: MediaKind::Video,
                        stage: "udp-send-failed",
                        message: format!("video datagram send failed: {error}"),
                    })
                })?;
            if sent != datagram.len() {
                return Err(VideoSendError::Failure(MediaFailure {
                    code: PlatformRuntimeEventCode::NativeVideoUdpSend,
                    kind: MediaKind::Video,
                    stage: "udp-send-failed",
                    message: "video datagram send was incomplete".to_owned(),
                }));
            }
        }
        if frame_index <= 3 || frame_index % 120 == 0 {
            eprintln!(
                "Lumen native media sent kind=video session-epoch={} frame-id={frame_index} datagrams={datagram_count} endpoint={}",
                delivery.session_epoch, delivery.endpoint
            );
        }
        self.last_sent_frame = Some(SentVideoFrame {
            frame_id: frame_index,
            key_frame: normalized.frame.key_frame,
        });
        self.pending_frame = None;
        Ok(())
    }
}

fn codec_configuration(
    delivery: &VideoDeliveryState,
    configuration: NativeVideoConfiguration,
) -> CodecConfiguration {
    CodecConfiguration {
        session_epoch: delivery.session_epoch,
        stream_id: u32::from(NATIVE_VIDEO_STREAM_ID),
        configuration_id: configuration.configuration_id,
        codec: match configuration.codec {
            crate::PlatformVideoCodec::H264 => NativeVideoCodec::H264 as i32,
            crate::PlatformVideoCodec::Hevc => NativeVideoCodec::Hevc as i32,
            crate::PlatformVideoCodec::Av1 => NativeVideoCodec::Av1 as i32,
        },
        decoder_configuration_record: configuration.decoder_configuration_record,
    }
}

fn native_media_address(arguments: &HostArguments) -> Result<SocketAddr, String> {
    let base_port = arguments
        .get("port")
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| "native UDP media base port is invalid".to_owned())?;
    let ip = match arguments.get("address_family") {
        Some("ipv4") => IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        Some("both") => IpAddr::V6(Ipv6Addr::UNSPECIFIED),
        _ => return Err("native UDP media address family is invalid".to_owned()),
    };
    base_port
        .checked_add(VIDEO_UDP_OFFSET)
        .map(|port| SocketAddr::new(ip, port))
        .ok_or_else(|| "native UDP media port overflowed".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicU16, Ordering};
    use std::sync::Mutex;

    struct ScriptedMediaPlatform {
        audio: Mutex<VecDeque<Result<Option<crate::PlatformEncodedAudioPacket>, String>>>,
        video: Mutex<VecDeque<Result<Option<crate::PlatformEncodedVideoFrame>, String>>>,
        controls: Mutex<Vec<(u32, crate::PlatformControlEvent)>>,
        motions: Mutex<Vec<(u32, crate::PlatformNativeMotionEvent)>>,
        events: Mutex<Vec<PlatformRuntimeEvent>>,
    }

    impl PlatformSessionControl for ScriptedMediaPlatform {
        fn start_session(&self, _plan: crate::PlatformSessionPlan) -> Result<(), String> {
            Ok(())
        }

        fn stop_session(&self) -> Result<(), String> {
            Ok(())
        }

        fn poll_encoded_audio(&self) -> Result<Option<crate::PlatformEncodedAudioPacket>, String> {
            self.audio.lock().unwrap().pop_front().unwrap_or(Ok(None))
        }

        fn poll_encoded_video(&self) -> Result<Option<crate::PlatformEncodedVideoFrame>, String> {
            self.video.lock().unwrap().pop_front().unwrap_or(Ok(None))
        }

        fn handle_control_event(
            &self,
            session_epoch: u32,
            event: crate::PlatformControlEvent,
        ) -> Result<(), String> {
            self.controls.lock().unwrap().push((session_epoch, event));
            Ok(())
        }

        fn handle_native_motion(
            &self,
            session_epoch: u32,
            event: crate::PlatformNativeMotionEvent,
        ) -> Result<(), String> {
            self.motions.lock().unwrap().push((session_epoch, event));
            Ok(())
        }

        fn publish_runtime_event(&self, event: PlatformRuntimeEvent) -> Result<(), String> {
            self.events.lock().unwrap().push(event);
            Ok(())
        }
    }

    #[test]
    fn derives_the_single_native_media_port() {
        let ipv4 = arguments_with("address_family", "ipv4");
        assert_eq!(
            native_media_address(&ipv4).unwrap(),
            SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 47_998)
        );

        let both = arguments_with("address_family", "both");
        assert_eq!(
            native_media_address(&both).unwrap(),
            SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 47_998)
        );
    }

    #[test]
    fn owns_the_native_media_port_for_one_transport_lifetime() {
        let base_port = available_base_port();
        let arguments = arguments_with("port", &base_port.to_string());
        let address = native_media_address(&arguments).unwrap();
        let mut transport = NativeUdpMediaTransport::default();
        let router = test_router();
        let platform = Arc::new(crate::IdlePlatformSessionControl);
        transport
            .start(&arguments, Arc::clone(&router), platform.clone())
            .unwrap();
        assert_eq!(
            transport.start(&arguments, router, platform),
            Err("native UDP media transport is already running".to_owned())
        );
        assert!(UdpSocket::bind(address).is_err());
        transport.stop().unwrap();
        UdpSocket::bind(address).unwrap();
    }

    #[test]
    fn authenticates_sequences_and_applies_native_motion_to_the_platform() {
        let peer = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 49_998);
        let identity = NativeMotionIdentity {
            session_epoch: 77,
            path_id: 5,
            policy_revision: 2,
        };
        let key = [0x73; 16];
        let delivery = InputMotionDeliveryState {
            session_epoch: identity.session_epoch,
            path_id: identity.path_id,
            policy_revision: identity.policy_revision,
            endpoint: peer,
            encryption_key: key,
        };
        let platform = ScriptedMediaPlatform {
            audio: Mutex::new(VecDeque::new()),
            video: Mutex::new(VecDeque::new()),
            controls: Mutex::new(Vec::new()),
            motions: Mutex::new(Vec::new()),
            events: Mutex::new(Vec::new()),
        };
        let mut receiver = NativeMotionReceiver::default();
        let mut reporter = InputMotionFailureReporter::default();
        let datagram =
            crate::media::native_motion::test_pointer_motion_datagram(identity, &key, 9, 11);

        apply_native_motion_datagram(
            &platform,
            peer,
            &datagram,
            &delivery,
            &mut receiver,
            &mut reporter,
        );
        apply_native_motion_datagram(
            &platform,
            peer,
            &datagram,
            &delivery,
            &mut receiver,
            &mut reporter,
        );

        let motions = platform.motions.lock().unwrap();
        assert_eq!(motions.len(), 1, "a replay must not reach the platform");
        assert_eq!(motions[0].0, 77);
        assert!(matches!(
            motions[0].1,
            crate::PlatformNativeMotionEvent::Pointer {
                delta_x: 4,
                delta_y: -2,
                ..
            }
        ));
        assert!(platform.events.lock().unwrap().is_empty());
    }

    #[test]
    fn sends_packetized_video_to_the_admitted_endpoint_and_resets_per_session() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let mut sender = VideoSenderState::default();
        let delivery = VideoDeliveryState {
            video_format: crate::PlatformVideoFormat {
                codec: crate::PlatformVideoCodec::H264,
                profile: crate::PlatformVideoProfile::H264High,
                chroma_subsampling: crate::PlatformChromaSubsampling::Yuv420,
                bit_depth: 8,
                dynamic_range: crate::PlatformDynamicRange::Sdr,
                color_range: crate::PlatformColorRange::Limited,
            },
            acknowledged_configuration_id: None,
            session_epoch: 7,
            path_id: 1,
            policy_revision: 1,
            maximum_datagram_payload: 1_200,
            endpoint: receiver.local_addr().unwrap(),
            encryption_key: [0x22; 16],
            fec_percentage: 0,
        };
        assert_eq!(
            send_video_frame(
                &sender_socket,
                &delivery,
                &mut sender,
                crate::media::native_video::test_fixtures::encoded_frame(delivery.video_format),
            ),
            Err("native video configuration is not acknowledged".to_owned())
        );
        let delivery = VideoDeliveryState {
            acknowledged_configuration_id: Some(1),
            ..delivery
        };
        assert_eq!(
            sender.acknowledged_configuration_boundary(&delivery),
            Some(1)
        );
        sender.release_configuration_boundary(1);
        sender.send_staged(&sender_socket, &delivery).unwrap();
        let mut packet = [0_u8; 2_048];
        let (length, _) = receiver.recv_from(&mut packet).unwrap();
        assert_eq!(length, 1_200);
        let first = lumen_engine::decode_native_media_datagram(&packet[..length]).unwrap();
        assert_eq!(first.header.kind, lumen_engine::NativeMediaKind::Video);
        assert_eq!(first.header.session_epoch, 7);
        assert_eq!(first.header.frame_id, 1);
        assert_ne!(
            first.header.flags & lumen_engine::NATIVE_MEDIA_FLAG_KEYFRAME,
            0
        );

        let next_unacknowledged_delivery = VideoDeliveryState {
            acknowledged_configuration_id: None,
            session_epoch: 8,
            ..delivery
        };
        assert_eq!(
            send_video_frame(
                &sender_socket,
                &next_unacknowledged_delivery,
                &mut sender,
                crate::media::native_video::test_fixtures::encoded_frame(
                    next_unacknowledged_delivery.video_format
                ),
            ),
            Err("native video configuration is not acknowledged".to_owned())
        );
        let next_delivery = VideoDeliveryState {
            acknowledged_configuration_id: Some(1),
            ..next_unacknowledged_delivery
        };
        assert_eq!(
            sender.acknowledged_configuration_boundary(&next_delivery),
            Some(1)
        );
        sender.release_configuration_boundary(1);
        sender.send_staged(&sender_socket, &next_delivery).unwrap();
        let (length, _) = receiver.recv_from(&mut packet).unwrap();
        assert_eq!(length, 1_200);
        let second = lumen_engine::decode_native_media_datagram(&packet[..length]).unwrap();
        assert_eq!(second.header.session_epoch, 8);
        assert_eq!(second.header.frame_id, 1);
        assert_ne!(
            second.header.flags & lumen_engine::NATIVE_MEDIA_FLAG_KEYFRAME,
            0
        );
    }

    #[test]
    fn codec_ack_releases_the_retained_key_frame_before_the_first_dependent_frame() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let video_format = crate::media::native_video::test_fixtures::H264_420;
        let inter_frame = |timestamp| crate::PlatformEncodedVideoFrame {
            payload: vec![0, 0, 0, 1, 0x41, 0x9a, 0x22],
            decoder_configuration_record: None,
            presentation_time_90khz: timestamp,
            key_frame: false,
        };
        let platform = ScriptedMediaPlatform {
            audio: Mutex::new(VecDeque::new()),
            video: Mutex::new(VecDeque::from([
                Ok(Some(
                    crate::media::native_video::test_fixtures::encoded_frame(video_format),
                )),
                Ok(Some(inter_frame(90_001))),
            ])),
            controls: Mutex::new(Vec::new()),
            motions: Mutex::new(Vec::new()),
            events: Mutex::new(Vec::new()),
        };
        let unacknowledged = VideoDeliveryState {
            video_format,
            acknowledged_configuration_id: None,
            session_epoch: 77,
            path_id: 1,
            policy_revision: 1,
            maximum_datagram_payload: 1_200,
            endpoint: receiver.local_addr().unwrap(),
            encryption_key: [0x52; 16],
            fec_percentage: 0,
        };
        let mut sender = VideoSenderState::default();

        assert!(matches!(
            poll_and_send_video(
                &sender_socket,
                &unacknowledged,
                &platform,
                &mut sender,
                |_| true,
            ),
            MediaAttempt::Waiting
        ));
        let acknowledged = VideoDeliveryState {
            acknowledged_configuration_id: Some(1),
            ..unacknowledged
        };
        assert!(matches!(
            poll_and_send_video(
                &sender_socket,
                &acknowledged,
                &platform,
                &mut sender,
                |_| true,
            ),
            MediaAttempt::Sent
        ));
        assert!(matches!(
            platform.controls.lock().unwrap().as_slice(),
            [(
                77,
                crate::PlatformControlEvent::ResumeVideoEncodingAfterCodecAck
            )]
        ));

        assert!(matches!(
            poll_and_send_video(
                &sender_socket,
                &acknowledged,
                &platform,
                &mut sender,
                |_| true,
            ),
            MediaAttempt::Sent
        ));

        let mut packet = [0_u8; 2_048];
        let first = loop {
            let (length, _) = receiver.recv_from(&mut packet).unwrap();
            let decoded = lumen_engine::decode_native_media_datagram(&packet[..length]).unwrap();
            if decoded.header.frame_id == 1 {
                break decoded;
            }
        };
        assert_ne!(
            first.header.flags & lumen_engine::NATIVE_MEDIA_FLAG_KEYFRAME,
            0
        );
        let second = loop {
            let (length, _) = receiver.recv_from(&mut packet).unwrap();
            let decoded = lumen_engine::decode_native_media_datagram(&packet[..length]).unwrap();
            if decoded.header.frame_id == 2 {
                break decoded;
            }
        };
        assert_eq!(
            second.header.flags & lumen_engine::NATIVE_MEDIA_FLAG_KEYFRAME,
            0
        );
    }

    #[test]
    fn successful_video_send_exposes_the_exact_keyframe_for_repair_completion() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let video_format = crate::media::native_video::test_fixtures::H264_420;
        let platform = ScriptedMediaPlatform {
            audio: Mutex::new(VecDeque::new()),
            video: Mutex::new(VecDeque::from([Ok(Some(
                crate::media::native_video::test_fixtures::encoded_frame(video_format),
            ))])),
            controls: Mutex::new(Vec::new()),
            motions: Mutex::new(Vec::new()),
            events: Mutex::new(Vec::new()),
        };
        let delivery = VideoDeliveryState {
            video_format,
            acknowledged_configuration_id: Some(1),
            session_epoch: 78,
            path_id: 1,
            policy_revision: 1,
            maximum_datagram_payload: 1_200,
            endpoint: receiver.local_addr().unwrap(),
            encryption_key: [0x53; 16],
            fec_percentage: 0,
        };
        let mut sender = VideoSenderState::default();

        assert!(matches!(
            poll_and_send_video(&sender_socket, &delivery, &platform, &mut sender, |_| true,),
            MediaAttempt::Sent
        ));
        assert_eq!(
            sender.take_last_sent_frame(),
            Some(SentVideoFrame {
                frame_id: 1,
                key_frame: true,
            })
        );
        assert_eq!(sender.take_last_sent_frame(), None);
    }

    #[test]
    fn rejects_mismatched_sps_before_network_media() {
        // Given: a 4:4:4 delivery plan and an encoder frame carrying a 4:2:0 SPS.
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_millis(25)))
            .unwrap();
        let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let selected = crate::media::native_video::test_fixtures::H264_444;
        let emitted = crate::media::native_video::test_fixtures::H264_420;
        let delivery = VideoDeliveryState {
            video_format: selected,
            acknowledged_configuration_id: None,
            session_epoch: 7,
            path_id: 1,
            policy_revision: 1,
            maximum_datagram_payload: 1_200,
            endpoint: receiver.local_addr().unwrap(),
            encryption_key: [0x22; 16],
            fec_percentage: 0,
        };

        // When: the frame reaches the sender's normalization boundary.
        let result = send_video_frame(
            &sender_socket,
            &delivery,
            &mut VideoSenderState::default(),
            crate::media::native_video::test_fixtures::encoded_frame(emitted),
        );

        // Then: conformance fails and no media datagram reaches the network peer.
        assert_eq!(
            result,
            Err("H.264 SPS does not match the selected video format".to_owned())
        );
        let mut datagram = [0_u8; 2_048];
        assert!(matches!(
            receiver.recv_from(&mut datagram).unwrap_err().kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        ));
    }

    #[test]
    fn sends_opus_units_with_the_native_media_contract() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let delivery = AudioDeliveryState {
            session_epoch: 0x0102_0304,
            path_id: 1,
            policy_revision: 1,
            maximum_datagram_payload: 1_200,
            endpoint: receiver.local_addr().unwrap(),
            encryption_key: std::array::from_fn(|index| index as u8),
        };
        let mut sender = AudioSenderState::default();
        for index in 0..4_u32 {
            send_audio_packet(
                &sender_socket,
                &delivery,
                &mut sender,
                crate::PlatformEncodedAudioPacket {
                    payload: vec![1, 2, 3],
                    presentation_time_48khz: index * 240,
                    duration_frames: 240,
                },
            )
            .unwrap();
        }
        let mut packet = [0_u8; 2_048];
        let mut received = Vec::new();
        for _ in 0..4 {
            let (length, _) = receiver.recv_from(&mut packet).unwrap();
            received.push(packet[..length].to_vec());
        }
        assert!(received.iter().all(|datagram| datagram.len() == 1_200));
        for (index, datagram) in received.iter().enumerate() {
            let decoded = lumen_engine::decode_native_media_datagram(datagram).unwrap();
            assert_eq!(decoded.header.kind, lumen_engine::NativeMediaKind::Audio);
            assert_eq!(decoded.header.session_epoch, 0x0102_0304);
            assert_eq!(decoded.header.frame_id, index as u32 + 1);
        }

        let next_session = AudioDeliveryState {
            session_epoch: 0x0102_0305,
            ..delivery
        };
        send_audio_packet(
            &sender_socket,
            &next_session,
            &mut sender,
            crate::PlatformEncodedAudioPacket {
                payload: vec![0, 1, 2],
                presentation_time_48khz: 0,
                duration_frames: 240,
            },
        )
        .unwrap();
        let (length, _) = receiver.recv_from(&mut packet).unwrap();
        assert_eq!(length, 1_200);
        let decoded = lumen_engine::decode_native_media_datagram(&packet[..length]).unwrap();
        assert_eq!(decoded.header.session_epoch, 0x0102_0305);
        assert_eq!(decoded.header.frame_id, 1);
    }

    #[test]
    fn resumes_audio_and_video_after_empty_capture_polls() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_millis(50)))
            .unwrap();
        let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let video_format = crate::media::native_video::test_fixtures::H264_420;
        let platform = ScriptedMediaPlatform {
            audio: Mutex::new(VecDeque::from([
                Ok(None),
                Ok(Some(crate::PlatformEncodedAudioPacket {
                    payload: vec![1, 2, 3],
                    presentation_time_48khz: 0,
                    duration_frames: 240,
                })),
                Ok(None),
                Ok(Some(crate::PlatformEncodedAudioPacket {
                    payload: vec![4, 5, 6],
                    presentation_time_48khz: 240,
                    duration_frames: 240,
                })),
            ])),
            video: Mutex::new(VecDeque::from([
                Ok(None),
                Ok(Some(
                    crate::media::native_video::test_fixtures::encoded_frame(video_format),
                )),
                Ok(None),
                Ok(Some(
                    crate::media::native_video::test_fixtures::encoded_frame(video_format),
                )),
                Ok(Some(
                    crate::media::native_video::test_fixtures::encoded_frame(video_format),
                )),
            ])),
            controls: Mutex::new(Vec::new()),
            motions: Mutex::new(Vec::new()),
            events: Mutex::new(Vec::new()),
        };
        let audio_delivery = AudioDeliveryState {
            session_epoch: 77,
            path_id: 1,
            policy_revision: 1,
            maximum_datagram_payload: 1_200,
            endpoint: receiver.local_addr().unwrap(),
            encryption_key: [0x41; 16],
        };
        let video_delivery = VideoDeliveryState {
            video_format,
            acknowledged_configuration_id: Some(1),
            session_epoch: 77,
            path_id: 1,
            policy_revision: 1,
            maximum_datagram_payload: 1_200,
            endpoint: receiver.local_addr().unwrap(),
            encryption_key: [0x41; 16],
            fec_percentage: 0,
        };
        let mut audio_sender = AudioSenderState::default();
        let mut video_sender = VideoSenderState::default();

        assert!(matches!(
            poll_and_send_audio(
                &sender_socket,
                &audio_delivery,
                &platform,
                &mut audio_sender
            ),
            MediaAttempt::Idle
        ));
        assert!(matches!(
            poll_and_send_audio(
                &sender_socket,
                &audio_delivery,
                &platform,
                &mut audio_sender
            ),
            MediaAttempt::Sent
        ));
        assert!(matches!(
            poll_and_send_audio(
                &sender_socket,
                &audio_delivery,
                &platform,
                &mut audio_sender
            ),
            MediaAttempt::Idle
        ));
        assert!(matches!(
            poll_and_send_audio(
                &sender_socket,
                &audio_delivery,
                &platform,
                &mut audio_sender
            ),
            MediaAttempt::Sent
        ));

        assert!(matches!(
            poll_and_send_video(
                &sender_socket,
                &video_delivery,
                &platform,
                &mut video_sender,
                |_| true,
            ),
            MediaAttempt::Idle
        ));
        assert!(matches!(
            poll_and_send_video(
                &sender_socket,
                &video_delivery,
                &platform,
                &mut video_sender,
                |_| true,
            ),
            MediaAttempt::Sent
        ));
        assert!(matches!(
            poll_and_send_video(
                &sender_socket,
                &video_delivery,
                &platform,
                &mut video_sender,
                |_| true,
            ),
            MediaAttempt::Idle
        ));
        assert!(matches!(
            poll_and_send_video(
                &sender_socket,
                &video_delivery,
                &platform,
                &mut video_sender,
                |_| true,
            ),
            MediaAttempt::Sent
        ));
        assert!(matches!(
            platform.controls.lock().unwrap().as_slice(),
            [(
                77,
                crate::PlatformControlEvent::ResumeVideoEncodingAfterCodecAck
            )]
        ));

        let mut datagram = [0_u8; 2_048];
        let mut audio_units = HashSet::new();
        let mut video_frames = HashSet::new();
        while let Ok((length, _)) = receiver.recv_from(&mut datagram) {
            let decoded = lumen_engine::decode_native_media_datagram(&datagram[..length]).unwrap();
            match decoded.header.kind {
                lumen_engine::NativeMediaKind::Audio => {
                    audio_units.insert(decoded.header.frame_id);
                }
                lumen_engine::NativeMediaKind::Video => {
                    video_frames.insert(decoded.header.frame_id);
                }
                lumen_engine::NativeMediaKind::InputMotion => {}
            }
        }
        assert_eq!(audio_units, HashSet::from([1, 2]));
        assert_eq!(video_frames, HashSet::from([1, 2]));
    }

    #[test]
    fn publishes_typed_capture_failure_and_clears_it_after_media_recovers() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let platform = ScriptedMediaPlatform {
            audio: Mutex::new(VecDeque::from([
                Err("audio source unavailable".to_owned()),
                Ok(Some(crate::PlatformEncodedAudioPacket {
                    payload: vec![1, 2, 3],
                    presentation_time_48khz: 0,
                    duration_frames: 240,
                })),
            ])),
            video: Mutex::new(VecDeque::new()),
            controls: Mutex::new(Vec::new()),
            motions: Mutex::new(Vec::new()),
            events: Mutex::new(Vec::new()),
        };
        let delivery = AudioDeliveryState {
            session_epoch: 91,
            path_id: 1,
            policy_revision: 1,
            maximum_datagram_payload: 1_200,
            endpoint: receiver.local_addr().unwrap(),
            encryption_key: [0x51; 16],
        };
        let mut sender = AudioSenderState::default();
        let mut reporter = MediaFailureReporter::default();

        let failed = poll_and_send_audio(&sender_socket, &delivery, &platform, &mut sender);
        reporter.observe(MediaKind::Audio, &failed, &platform);
        let recovered = poll_and_send_audio(&sender_socket, &delivery, &platform, &mut sender);
        reporter.observe(MediaKind::Audio, &recovered, &platform);

        assert!(matches!(failed, MediaAttempt::Failed(_)));
        assert!(matches!(recovered, MediaAttempt::Sent));
        let events = platform.events.lock().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(
            events[0],
            PlatformRuntimeEvent {
                disposition: PlatformRuntimeEventDisposition::Raised,
                severity: PlatformRuntimeEventSeverity::Warning,
                code: PlatformRuntimeEventCode::NativeAudioCapturePoll,
                message: Some(
                    "native-media-audio-capture-poll-failed: audio source unavailable".to_owned()
                ),
            }
        );
        assert_eq!(
            events[1],
            PlatformRuntimeEvent {
                disposition: PlatformRuntimeEventDisposition::Cleared,
                severity: PlatformRuntimeEventSeverity::Warning,
                code: PlatformRuntimeEventCode::NativeAudioCapturePoll,
                message: None,
            }
        );
    }

    fn available_base_port() -> u16 {
        static NEXT_BASE_PORT: AtomicU16 = AtomicU16::new(58_000);
        for _ in 0..100 {
            let base_port = NEXT_BASE_PORT.fetch_add(16, Ordering::Relaxed);
            let addresses = [base_port + VIDEO_UDP_OFFSET];
            let sockets = addresses
                .into_iter()
                .map(|port| UdpSocket::bind((Ipv4Addr::LOCALHOST, port)))
                .collect::<Result<Vec<_>, _>>();
            if sockets.is_ok() {
                return base_port;
            }
        }
        panic!("no UDP media test port range is available");
    }

    fn arguments_with(key: &str, value: &str) -> HostArguments {
        let mut values = crate::config::tests::valid_arguments();
        let prefix = format!("{key}=");
        let argument = values
            .iter_mut()
            .find(|argument| argument.starts_with(&prefix))
            .unwrap();
        *argument = format!("{key}={value}");
        HostArguments::parse(values).unwrap()
    }

    fn test_router() -> SharedControlRouter {
        let root = tempfile::tempdir().unwrap().keep();
        let paths = crate::HostAuthorityPaths {
            settings: root.join("settings.json"),
            owner_account: root.join("owner-account.json"),
            devices: root.join("devices.json"),
            applications: root.join("apps.json"),
            host_identity: root.join("lumen-state.json"),
        };
        let authorities = crate::HostAuthorities::open_native(paths).unwrap();
        Arc::new(std::sync::Mutex::new(crate::ControlRouter::new(
            authorities,
            crate::HostDiscoveryState::test_default(),
        )))
    }
}
