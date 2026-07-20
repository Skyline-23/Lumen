use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use lumen_engine::{
    decode_native_media_datagram, CodecConfiguration, NativeMediaKind, NativeVideoBootstrapReason,
    NativeVideoCodec, NATIVE_VIDEO_STREAM_ID,
};

use super::SharedControlRouter;
use crate::control::{AudioDeliveryState, InputMotionDeliveryState, VideoDeliveryState};
use crate::media::native_motion::{
    NativeMotionDatagramError, NativeMotionIdentity, NativeMotionReceiver,
};
use crate::media::native_packet::{NativeMediaPacketizer, NativeMediaPacketizerConfig};
use crate::media::native_video::{
    NativeVideoBitstreamNormalizer, NativeVideoConfiguration, NormalizedNativeVideoFrame,
};
use crate::{
    PlatformRuntimeEvent, PlatformRuntimeEventCode, PlatformRuntimeEventDisposition,
    PlatformRuntimeEventSeverity, PlatformSessionControl,
};

const MEDIA_POLL_INTERVAL: Duration = Duration::from_millis(1);

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
    Dropped,
    Failed(MediaFailure),
}

#[derive(Default)]
struct MediaFailureReporter {
    active: HashSet<PlatformRuntimeEventCode>,
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
            MediaAttempt::Inactive | MediaAttempt::Sent | MediaAttempt::Dropped => {
                self.clear_kind(kind, platform)
            }
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
        if !self.active.insert(failure.code) {
            return;
        }
        let message = format!(
            "native-media-{}-{}: {}",
            match failure.kind {
                MediaKind::Video => "video",
                MediaKind::Audio => "audio",
            },
            failure.stage,
            failure.message
        );
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

pub(super) async fn run_native_media_loop(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), String> {
    let mut interval = tokio::time::interval(MEDIA_POLL_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut video = VideoSenderState::default();
    let mut audio = AudioSenderState::default();
    let mut motion = NativeMotionReceiver::default();
    let mut motion_failure_active = false;
    let mut failures = MediaFailureReporter::default();
    loop {
        tokio::select! {
            datagram = connection.read_datagram() => {
                let datagram = datagram.map_err(|error| format!("could not read QUIC media datagram: {error}"))?;
                handle_motion_datagram(
                    &router,
                    platform.as_ref(),
                    session_epoch,
                    &datagram,
                    &mut motion,
                    &mut motion_failure_active,
                );
            }
            _ = interval.tick() => {
                let audio_attempt = poll_and_send_audio(
                    &connection,
                    &router,
                    platform.as_ref(),
                    &mut audio,
                ).await;
                failures.observe(MediaKind::Audio, &audio_attempt, platform.as_ref());
                let video_attempt = poll_and_send_video(
                    &connection,
                    &router,
                    platform.as_ref(),
                    &mut video,
                ).await;
                failures.observe(MediaKind::Video, &video_attempt, platform.as_ref());
            }
        }
    }
}

fn handle_motion_datagram(
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    session_epoch: u32,
    datagram: &[u8],
    receiver: &mut NativeMotionReceiver,
    failure_active: &mut bool,
) {
    let Ok(decoded) = decode_native_media_datagram(datagram) else {
        return;
    };
    if decoded.header.kind != NativeMediaKind::InputMotion {
        return;
    }
    let Some(InputMotionDeliveryState {
        session_epoch: active,
        ..
    }) = router
        .lock()
        .ok()
        .and_then(|router| router.input_motion_delivery_state())
    else {
        return;
    };
    if active != session_epoch {
        return;
    }
    let identity = NativeMotionIdentity { session_epoch };
    match receiver.accept(datagram, identity) {
        Ok(accepted) => match platform.handle_native_motion(session_epoch, accepted.event) {
            Ok(()) => {
                if *failure_active {
                    let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
                        disposition: PlatformRuntimeEventDisposition::Cleared,
                        severity: PlatformRuntimeEventSeverity::Warning,
                        code: PlatformRuntimeEventCode::NativeInputMotion,
                        message: None,
                    });
                    *failure_active = false;
                }
                if accepted.motion_sequence <= 3 || accepted.motion_sequence % 120 == 0 {
                    eprintln!(
                            "Lumen native motion stage=applied session-epoch={session_epoch} datagram-sequence={} motion-sequence={} capture-timestamp-us={}",
                            accepted.datagram_sequence,
                            accepted.motion_sequence,
                            accepted.capture_timestamp_us
                        );
                }
            }
            Err(error) => {
                eprintln!(
                        "Lumen native motion stage=platform-rejected session-epoch={session_epoch} datagram-sequence={} motion-sequence={} error={error}",
                        accepted.datagram_sequence,
                        accepted.motion_sequence
                    );
                if !*failure_active {
                    let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
                        disposition: PlatformRuntimeEventDisposition::Raised,
                        severity: PlatformRuntimeEventSeverity::Warning,
                        code: PlatformRuntimeEventCode::NativeInputMotion,
                        message: Some(format!(
                            "Native motion event {} was rejected: {error}",
                            accepted.motion_sequence
                        )),
                    });
                    *failure_active = true;
                }
            }
        },
        Err(NativeMotionDatagramError::NotMotion) => (),
        Err(error) => eprintln!(
            "Lumen native motion stage=rejected session-epoch={session_epoch} reason={error:?}"
        ),
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AudioSessionIdentity {
    session_epoch: u32,
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
        };
        if self.identity.as_ref() == Some(&identity) {
            return self
                .packetizer
                .as_mut()
                .ok_or_else(|| "audio packetizer is unavailable".to_owned())?
                .reconfigure(delivery.maximum_datagram_payload);
        }
        self.packetizer = Some(NativeMediaPacketizer::new(
            NativeMediaPacketizerConfig {
                kind: NativeMediaKind::Audio,
                maximum_datagram_payload: delivery.maximum_datagram_payload,
                generation_id: 0,
            },
            0,
        )?);
        self.unit_id = 1;
        self.identity = Some(identity);
        Ok(())
    }
}

async fn poll_and_send_audio(
    connection: &quinn::Connection,
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    sender: &mut AudioSenderState,
) -> MediaAttempt {
    let Some(delivery) = router
        .lock()
        .ok()
        .and_then(|router| router.audio_delivery_state())
    else {
        return MediaAttempt::Inactive;
    };
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
    if let Err(message) = sender.prepare(&delivery) {
        return MediaAttempt::Failed(audio_failure("packetizer-failed", message));
    }
    let unit_id = sender.unit_id;
    let packetized = match sender
        .packetizer
        .as_mut()
        .expect("prepared audio packetizer")
        .packetize_audio(&packet, unit_id)
    {
        Ok(packetized) => packetized,
        Err(message) => return MediaAttempt::Failed(audio_failure("packetizer-failed", message)),
    };
    for datagram in packetized.datagrams {
        if let Err(error) = connection.send_datagram_wait(datagram.into()).await {
            return MediaAttempt::Failed(audio_failure(
                "quic-datagram-send-failed",
                error.to_string(),
            ));
        }
    }
    sender.unit_id = match unit_id.checked_add(1) {
        Some(next) => next,
        None => {
            return MediaAttempt::Failed(audio_failure(
                "packetizer-failed",
                "audio unit id exhausted".to_owned(),
            ))
        }
    };
    if unit_id <= 3 || unit_id % 200 == 0 {
        eprintln!(
            "Lumen native media sent kind=audio session-epoch={} unit-id={unit_id}",
            delivery.session_epoch
        );
    }
    MediaAttempt::Sent
}

fn audio_failure(stage: &'static str, message: String) -> MediaFailure {
    MediaFailure {
        code: if stage == "packetizer-failed" {
            PlatformRuntimeEventCode::NativeAudioPacketizer
        } else {
            PlatformRuntimeEventCode::NativeAudioUdpSend
        },
        kind: MediaKind::Audio,
        stage,
        message,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct VideoSessionIdentity {
    video_format: crate::PlatformVideoFormat,
    session_epoch: u32,
}

#[derive(Default)]
struct VideoSenderState {
    identity: Option<VideoSessionIdentity>,
    packetizer: Option<NativeMediaPacketizer>,
    normalizer: Option<NativeVideoBitstreamNormalizer>,
    pending_frame: Option<NormalizedNativeVideoFrame>,
    pending_since: Option<Instant>,
    repair_required: bool,
    frame_id: u32,
}

impl VideoSenderState {
    fn prepare(&mut self, delivery: &VideoDeliveryState) -> Result<(), String> {
        let identity = VideoSessionIdentity {
            video_format: delivery.video_format,
            session_epoch: delivery.session_epoch,
        };
        if self.identity.as_ref() == Some(&identity) {
            if let Some(packetizer) = self.packetizer.as_mut() {
                packetizer.reconfigure(delivery.maximum_datagram_payload)?;
                if let Some(generation_id) = delivery.acknowledged_generation_id {
                    packetizer.update_video_generation(generation_id)?;
                }
            }
            return Ok(());
        }
        self.packetizer = None;
        self.normalizer = Some(NativeVideoBitstreamNormalizer::new(delivery.video_format));
        self.pending_frame = None;
        self.pending_since = None;
        self.repair_required = false;
        self.frame_id = 1;
        self.identity = Some(identity);
        Ok(())
    }
}

async fn poll_and_send_video(
    connection: &quinn::Connection,
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    sender: &mut VideoSenderState,
) -> MediaAttempt {
    let Some(delivery) = router
        .lock()
        .ok()
        .and_then(|router| router.video_delivery_state())
    else {
        return MediaAttempt::Inactive;
    };
    if let Err(message) = sender.prepare(&delivery) {
        return MediaAttempt::Failed(video_failure("packetizer-failed", message));
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
        let normalized = match sender
            .normalizer
            .as_mut()
            .expect("prepared video normalizer")
            .normalize(frame)
        {
            Ok(normalized) => normalized,
            Err(message) => {
                return MediaAttempt::Failed(video_failure("normalization-failed", message))
            }
        };
        if let Some(configuration) = normalized.new_configuration.clone() {
            let published = router.lock().is_ok_and(|mut router| {
                router.publish_native_codec_configuration(codec_configuration(
                    &delivery,
                    configuration,
                ))
            });
            if !published {
                return MediaAttempt::Failed(video_failure(
                    "configuration-publish-failed",
                    "video codec configuration could not be published".to_owned(),
                ));
            }
        }
        sender.pending_frame = Some(normalized);
        sender.pending_since = Some(Instant::now());
    }

    let normalized = sender.pending_frame.as_ref().expect("staged video frame");
    if delivery.acknowledged_configuration_id != Some(normalized.configuration_id) {
        return MediaAttempt::Waiting;
    }
    if !normalized.frame.key_frame
        && sender.pending_since.is_some_and(|pending_since| {
            object_deadline_exceeded(pending_since.elapsed(), delivery.maximum_object_delay_us)
        })
    {
        let stale_frame_id = sender.frame_id;
        sender.pending_frame = None;
        sender.pending_since = None;
        sender.repair_required = true;
        let _ = platform.handle_control_event(
            delivery.session_epoch,
            crate::PlatformControlEvent::RequestIdrFrame,
        );
        eprintln!(
            "Lumen object delivery stage=stale-video-delta-dropped session-epoch={} generation-id={} frame-id={} deadline-us={} target-bitrate-kbps={} admission-divisor={}",
            delivery.session_epoch,
            delivery.acknowledged_generation_id.unwrap_or_default(),
            stale_frame_id,
            delivery.maximum_object_delay_us,
            delivery.target_bitrate_kbps,
            delivery.admission_divisor
        );
        return MediaAttempt::Dropped;
    }
    let frame_id = sender.frame_id;
    if normalized.frame.key_frame {
        let reason = if normalized.new_configuration.is_some()
            && delivery.acknowledged_generation_id.is_some()
        {
            NativeVideoBootstrapReason::ConfigurationChange
        } else if delivery.acknowledged_generation_id.is_none() {
            NativeVideoBootstrapReason::Initial
        } else if sender.repair_required {
            NativeVideoBootstrapReason::Repair
        } else {
            eprintln!(
                "Lumen object delivery stage=unexpected-keyframe-promoted-to-repair session-epoch={} frame-id={frame_id}",
                delivery.session_epoch
            );
            NativeVideoBootstrapReason::Repair
        };
        let published = router.lock().ok().and_then(|mut router| {
            router.publish_native_video_bootstrap(
                normalized.configuration_id,
                frame_id,
                timestamp_to_microseconds(normalized.frame.presentation_time_90khz, 90_000),
                reason,
                normalized.frame.payload.clone(),
            )
        });
        if published.is_none() {
            return MediaAttempt::Waiting;
        }
        sender.frame_id = match frame_id.checked_add(1) {
            Some(next) => next,
            None => {
                return MediaAttempt::Failed(video_failure(
                    "packetizer-failed",
                    "video frame id exhausted".to_owned(),
                ))
            }
        };
        sender.pending_frame = None;
        sender.pending_since = None;
        sender.repair_required = false;
        return MediaAttempt::Waiting;
    }

    let Some(generation_id) = delivery.acknowledged_generation_id else {
        return MediaAttempt::Waiting;
    };
    if sender.packetizer.is_none() {
        sender.packetizer = match NativeMediaPacketizer::new(
            NativeMediaPacketizerConfig {
                kind: NativeMediaKind::VideoDelta,
                maximum_datagram_payload: delivery.maximum_datagram_payload,
                generation_id,
            },
            0,
        ) {
            Ok(packetizer) => Some(packetizer),
            Err(message) => {
                return MediaAttempt::Failed(video_failure("packetizer-failed", message))
            }
        };
    }
    let packetizer = sender.packetizer.as_mut().expect("video packetizer");
    if let Err(message) = packetizer.update_video_generation(generation_id) {
        return MediaAttempt::Failed(video_failure("packetizer-failed", message));
    }
    let packetized = match packetizer.packetize_video_delta(
        &normalized.frame,
        frame_id,
        delivery.fec_percentage,
    ) {
        Ok(packetized) => packetized,
        Err(message) => return MediaAttempt::Failed(video_failure("packetizer-failed", message)),
    };
    let datagram_count = packetized.datagrams.len();
    for datagram in packetized.datagrams {
        if let Err(error) = connection.send_datagram_wait(datagram.into()).await {
            return MediaAttempt::Failed(video_failure(
                "quic-datagram-send-failed",
                error.to_string(),
            ));
        }
    }
    sender.frame_id = match frame_id.checked_add(1) {
        Some(next) => next,
        None => {
            return MediaAttempt::Failed(video_failure(
                "packetizer-failed",
                "video frame id exhausted".to_owned(),
            ))
        }
    };
    sender.pending_frame = None;
    sender.pending_since = None;
    if let Ok(mut router) = router.lock() {
        let _ = router.observe_native_video_frame_sent(delivery.session_epoch, frame_id);
    }
    if frame_id <= 3 || frame_id % 120 == 0 {
        eprintln!(
            "Lumen native media sent kind=video-delta session-epoch={} generation-id={generation_id} frame-id={frame_id} datagrams={datagram_count}",
            delivery.session_epoch
        );
    }
    MediaAttempt::Sent
}

fn video_failure(stage: &'static str, message: String) -> MediaFailure {
    MediaFailure {
        code: if stage == "quic-datagram-send-failed" {
            PlatformRuntimeEventCode::NativeVideoUdpSend
        } else {
            PlatformRuntimeEventCode::NativeVideoPacketizer
        },
        kind: MediaKind::Video,
        stage,
        message,
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

fn timestamp_to_microseconds(timestamp: u32, clock_rate: u64) -> u32 {
    ((u64::from(timestamp) * 1_000_000) / clock_rate) as u32
}

fn object_deadline_exceeded(age: Duration, maximum_object_delay_us: u32) -> bool {
    age > Duration::from_micros(u64::from(maximum_object_delay_us))
}

#[cfg(test)]
mod tests {
    use super::object_deadline_exceeded;
    use std::time::Duration;

    #[test]
    fn video_delta_deadline_is_strict_and_microsecond_exact() {
        assert!(!object_deadline_exceeded(
            Duration::from_micros(25_000),
            25_000
        ));
        assert!(object_deadline_exceeded(
            Duration::from_micros(25_001),
            25_000
        ));
    }
}
