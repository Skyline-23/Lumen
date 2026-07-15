use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use super::SharedControlRouter;
use crate::control::{AudioDeliveryState, VideoDeliveryState};
use crate::media::native_packet::{NativeMediaPacketizer, NativeMediaPacketizerConfig};
use crate::media::native_path::{
    decode_native_path_probe, encode_native_path_probe, native_path_probe_identity,
    NativePathProbe, NativePathProbeKind,
};
use crate::media::native_video::{
    NativeVideoBitstreamNormalizer, NativeVideoConfiguration, NormalizedNativeVideoFrame,
};
use crate::network_ports::VIDEO_UDP_OFFSET;
use crate::{HostArguments, PlatformSessionControl};
use lumen_engine::{
    CodecConfiguration, NativeVideoCodec, NATIVE_AUDIO_STREAM_ID, NATIVE_INITIAL_CONFIGURATION_ID,
    NATIVE_VIDEO_STREAM_ID,
};

const MEDIA_SEND_POLL_INTERVAL: Duration = Duration::from_millis(1);
const MAXIMUM_CLIENT_DATAGRAM_BYTES: usize = 2_048;

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
    while !stop.load(Ordering::Acquire) {
        let received = match socket.recv_from(&mut datagram) {
            Ok((length, peer)) => {
                let _ = handle_native_path_probe(&socket, &router, peer, &datagram[..length]);
                true
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => false,
            Err(_) => false,
        };
        let sent_video = send_pending_video(&socket, &router, platform.as_ref(), &mut video_sender);
        let sent_audio = send_pending_audio(&socket, &router, platform.as_ref(), &mut audio_sender);
        if !received && !sent_video && !sent_audio {
            thread::sleep(MEDIA_SEND_POLL_INTERVAL);
        }
    }
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
) -> bool {
    let delivery = match router
        .lock()
        .ok()
        .and_then(|router| router.audio_delivery_state())
    {
        Some(delivery) => delivery,
        None => return false,
    };
    let packet = match platform.poll_encoded_audio() {
        Ok(Some(packet)) => packet,
        Ok(None) | Err(_) => return false,
    };
    send_audio_packet(socket, &delivery, sender, packet).is_ok()
}

fn send_audio_packet(
    socket: &UdpSocket,
    delivery: &AudioDeliveryState,
    sender: &mut AudioSenderState,
    packet: crate::PlatformEncodedAudioPacket,
) -> Result<(), String> {
    sender.prepare(delivery)?;
    let unit_id = sender.unit_id;
    let packetized = sender
        .packetizer
        .as_mut()
        .ok_or_else(|| "audio packetizer is unavailable".to_owned())?
        .packetize_audio(&packet, unit_id)?;
    sender.unit_id = sender
        .unit_id
        .checked_add(1)
        .ok_or_else(|| "audio unit id exhausted".to_owned())?;
    for datagram in packetized.datagrams {
        send_datagram(socket, delivery.endpoint, &datagram, "audio")?;
    }
    Ok(())
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
    codec: crate::PlatformVideoCodec,
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
    frame_index: u32,
}

impl VideoSenderState {
    fn prepare(&mut self, delivery: &VideoDeliveryState) -> Result<(), String> {
        let identity = VideoSessionIdentity {
            codec: delivery.codec,
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
        self.normalizer = Some(NativeVideoBitstreamNormalizer::new(delivery.codec));
        self.pending_frame = None;
        self.frame_index = 1;
        self.identity = Some(identity);
        Ok(())
    }
}

fn send_pending_video(
    socket: &UdpSocket,
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    sender: &mut VideoSenderState,
) -> bool {
    let delivery = match router
        .lock()
        .ok()
        .and_then(|router| router.video_delivery_state())
    {
        Some(delivery) => delivery,
        None => return false,
    };
    if sender.prepare(&delivery).is_err() {
        return false;
    }
    if sender.pending_frame.is_none() {
        let frame = match platform.poll_encoded_video() {
            Ok(Some(frame)) => frame,
            Ok(None) | Err(_) => return false,
        };
        let configuration = match sender.stage(frame) {
            Ok(configuration) => configuration,
            Err(_) => return false,
        };
        if let Some(configuration) = configuration {
            let wire = codec_configuration(&delivery, configuration);
            if !router
                .lock()
                .is_ok_and(|mut router| router.publish_native_codec_configuration(wire))
            {
                return false;
            }
        }
    }
    sender.send_staged(socket, &delivery).is_ok()
}

#[cfg(test)]
fn send_video_frame(
    socket: &UdpSocket,
    delivery: &VideoDeliveryState,
    sender: &mut VideoSenderState,
    frame: crate::PlatformEncodedVideoFrame,
) -> Result<(), String> {
    sender.prepare(delivery)?;
    sender.stage(frame)?;
    sender.send_staged(socket, delivery)
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
        self.pending_frame = Some(normalized);
        Ok(configuration)
    }

    fn send_staged(
        &mut self,
        socket: &UdpSocket,
        delivery: &VideoDeliveryState,
    ) -> Result<(), String> {
        let normalized = self
            .pending_frame
            .as_ref()
            .ok_or_else(|| "native video sender has no pending frame".to_owned())?;
        if delivery.acknowledged_configuration_id != Some(normalized.configuration_id) {
            return Err("native video configuration is not acknowledged".to_owned());
        }
        self.packetizer
            .as_mut()
            .ok_or_else(|| "video packetizer is unavailable".to_owned())?
            .update_video_configuration(normalized.configuration_id)?;
        let frame_index = self.frame_index;
        let packetized = self
            .packetizer
            .as_mut()
            .ok_or_else(|| "video packetizer is unavailable".to_owned())?
            .packetize_video(&normalized.frame, frame_index, delivery.fec_percentage)?;
        self.frame_index = self
            .frame_index
            .checked_add(1)
            .ok_or_else(|| "video frame id exhausted".to_owned())?;
        for datagram in packetized.datagrams {
            let sent = socket
                .send_to(&datagram, delivery.endpoint)
                .map_err(|error| format!("video datagram send failed: {error}"))?;
            if sent != datagram.len() {
                return Err("video datagram send was incomplete".to_owned());
            }
        }
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
    use std::sync::atomic::{AtomicU16, Ordering};

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
    fn sends_packetized_video_to_the_admitted_endpoint_and_resets_per_session() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let sender_socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let mut sender = VideoSenderState::default();
        let delivery = VideoDeliveryState {
            codec: crate::PlatformVideoCodec::H264,
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
                crate::PlatformEncodedVideoFrame {
                    payload: h264_key_frame(0x65),
                    decoder_configuration_record: None,
                    presentation_time_90khz: 90_000,
                    key_frame: true,
                },
            ),
            Err("native video configuration is not acknowledged".to_owned())
        );
        let delivery = VideoDeliveryState {
            acknowledged_configuration_id: Some(1),
            ..delivery
        };
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

        let next_delivery = VideoDeliveryState {
            session_epoch: 8,
            ..delivery
        };
        send_video_frame(
            &sender_socket,
            &next_delivery,
            &mut sender,
            crate::PlatformEncodedVideoFrame {
                payload: h264_key_frame(0x65),
                decoder_configuration_record: None,
                presentation_time_90khz: 90_001,
                key_frame: true,
            },
        )
        .unwrap();
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

    fn h264_key_frame(slice_header: u8) -> Vec<u8> {
        vec![
            0,
            0,
            0,
            1,
            0x67,
            100,
            0,
            40,
            0x80,
            0,
            0,
            1,
            0x68,
            0xce,
            0x3c,
            0x80,
            0,
            0,
            1,
            slice_header,
            0x88,
        ]
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
