use std::collections::HashSet;
use std::future::Future;
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
pub(super) const NATIVE_MEDIA_SEND_BUFFER_BYTES: usize = 4 * 1024 * 1024;
const NATIVE_AUDIO_EGRESS_RESERVE_BYTES: usize = 2 * 1_200;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DatagramBatchMode {
    FreshEnqueue,
    DeadlineWait,
}

impl DatagramBatchMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::FreshEnqueue => "capacity-reserved-enqueue",
            Self::DeadlineWait => "deadline-wait",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DatagramBatchDropReason {
    QueueBarrierDeadlineExceeded,
    SendDeadlineExceeded,
}

impl DatagramBatchDropReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::QueueBarrierDeadlineExceeded => "queue-barrier-deadline-exceeded",
            Self::SendDeadlineExceeded => "send-deadline-exceeded",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum DatagramBatchStatus {
    Complete,
    Dropped(DatagramBatchDropReason),
    Failed(String),
}

#[derive(Debug, Eq, PartialEq)]
struct DatagramBatchReport {
    status: DatagramBatchStatus,
    mode: DatagramBatchMode,
    total_datagrams: usize,
    sent_datagrams: usize,
    total_bytes: usize,
    queue_wait_duration: Duration,
    send_wait_duration: Duration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DatagramDeadlineElapsed;

enum DatagramSendOutcome {
    Sent,
    DeadlineExceeded,
    Failed(String),
}

async fn wait_for_datagram_deadline<F>(
    deadline: Instant,
    future: F,
) -> Result<F::Output, DatagramDeadlineElapsed>
where
    F: Future,
{
    if Instant::now() >= deadline {
        return Err(DatagramDeadlineElapsed);
    }
    tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), future)
        .await
        .map_err(|_| DatagramDeadlineElapsed)
}

async fn send_connection_datagram(
    connection: &quinn::Connection,
    mode: DatagramBatchMode,
    datagram: Vec<u8>,
    deadline: Option<Instant>,
) -> DatagramSendOutcome {
    let result = match mode {
        DatagramBatchMode::FreshEnqueue => connection.send_datagram(datagram.into()),
        DatagramBatchMode::DeadlineWait => {
            let Some(deadline) = deadline else {
                return DatagramSendOutcome::DeadlineExceeded;
            };
            match wait_for_datagram_deadline(
                deadline,
                connection.send_datagram_wait(datagram.into()),
            )
            .await
            {
                Ok(result) => result,
                Err(_) => return DatagramSendOutcome::DeadlineExceeded,
            }
        }
    };
    match result {
        Ok(()) => DatagramSendOutcome::Sent,
        Err(error) => DatagramSendOutcome::Failed(error.to_string()),
    }
}

async fn send_datagram_batch<Send, SendFuture>(
    datagrams: Vec<Vec<u8>>,
    mode: DatagramBatchMode,
    deadline: Option<Instant>,
    mut send: Send,
) -> DatagramBatchReport
where
    Send: FnMut(DatagramBatchMode, Vec<u8>, Option<Instant>) -> SendFuture,
    SendFuture: Future<Output = DatagramSendOutcome>,
{
    let total_datagrams = datagrams.len();
    let total_bytes = datagrams.iter().map(Vec::len).sum();
    let mut report = DatagramBatchReport {
        status: DatagramBatchStatus::Complete,
        mode,
        total_datagrams,
        sent_datagrams: 0,
        total_bytes,
        queue_wait_duration: Duration::ZERO,
        send_wait_duration: Duration::ZERO,
    };
    if mode == DatagramBatchMode::DeadlineWait && deadline.is_none() {
        report.status = DatagramBatchStatus::Dropped(DatagramBatchDropReason::SendDeadlineExceeded);
        return report;
    }

    for datagram in datagrams {
        let send_started = Instant::now();
        let outcome = send(mode, datagram, deadline).await;
        if mode == DatagramBatchMode::DeadlineWait {
            report.send_wait_duration += send_started.elapsed();
        }
        match outcome {
            DatagramSendOutcome::Sent => {
                report.sent_datagrams += 1;
            }
            DatagramSendOutcome::DeadlineExceeded => {
                report.status =
                    DatagramBatchStatus::Dropped(DatagramBatchDropReason::SendDeadlineExceeded);
                break;
            }
            DatagramSendOutcome::Failed(error) => {
                report.status = DatagramBatchStatus::Failed(error);
                break;
            }
        }
    }
    report
}

async fn wait_for_datagram_queue_capacity<Space, Wait, WaitFuture>(
    capacity: usize,
    required_capacity: usize,
    deadline: Instant,
    mut send_buffer_space: Space,
    mut wait: Wait,
) -> Result<Duration, DatagramDeadlineElapsed>
where
    Space: FnMut() -> usize,
    Wait: FnMut(Instant) -> WaitFuture,
    WaitFuture: Future<Output = Result<(), DatagramDeadlineElapsed>>,
{
    if required_capacity > capacity {
        return Err(DatagramDeadlineElapsed);
    }
    let started = Instant::now();
    loop {
        if Instant::now() >= deadline {
            return Err(DatagramDeadlineElapsed);
        }
        if send_buffer_space() >= required_capacity {
            return Ok(started.elapsed());
        }
        wait(deadline).await?;
    }
}

async fn wait_for_connection_datagram_queue_capacity(
    connection: &quinn::Connection,
    required_capacity: usize,
    deadline: Instant,
) -> Result<Duration, DatagramDeadlineElapsed> {
    wait_for_datagram_queue_capacity(
        NATIVE_MEDIA_SEND_BUFFER_BYTES,
        required_capacity,
        deadline,
        || connection.datagram_send_buffer_space(),
        |deadline| async move {
            wait_for_datagram_deadline(deadline, tokio::time::sleep(MEDIA_POLL_INTERVAL))
                .await
                .map(|_| ())
        },
    )
    .await
}

async fn send_video_datagram_batch<Barrier, BarrierFuture, Send, SendFuture>(
    datagrams: Vec<Vec<u8>>,
    send_buffer_capacity: usize,
    audio_reserve_bytes: usize,
    queue_was_empty_before_current_audio: bool,
    deadline: Instant,
    mut wait_for_capacity: Barrier,
    send: Send,
) -> DatagramBatchReport
where
    Barrier: FnMut(usize, Instant) -> BarrierFuture,
    BarrierFuture: Future<Output = Result<Duration, DatagramDeadlineElapsed>>,
    Send: FnMut(DatagramBatchMode, Vec<u8>, Option<Instant>) -> SendFuture,
    SendFuture: Future<Output = DatagramSendOutcome>,
{
    let total_bytes = datagrams.iter().map(Vec::len).sum::<usize>();
    let video_capacity = send_buffer_capacity.saturating_sub(audio_reserve_bytes);
    let mode = if total_bytes <= video_capacity {
        DatagramBatchMode::FreshEnqueue
    } else {
        DatagramBatchMode::DeadlineWait
    };
    let required_capacity =
        if mode == DatagramBatchMode::FreshEnqueue && queue_was_empty_before_current_audio {
            total_bytes.saturating_add(audio_reserve_bytes)
        } else {
            video_capacity
        };
    let barrier_started = Instant::now();
    let queue_wait_duration = match wait_for_capacity(required_capacity, deadline).await {
        Ok(duration) => duration,
        Err(_) => {
            return DatagramBatchReport {
                status: DatagramBatchStatus::Dropped(
                    DatagramBatchDropReason::QueueBarrierDeadlineExceeded,
                ),
                mode,
                total_datagrams: datagrams.len(),
                sent_datagrams: 0,
                total_bytes,
                queue_wait_duration: barrier_started.elapsed(),
                send_wait_duration: Duration::ZERO,
            };
        }
    };
    let mut report = send_datagram_batch(datagrams, mode, Some(deadline), send).await;
    report.queue_wait_duration = queue_wait_duration;
    report
}

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
    Superseded { active_session_epoch: u32 },
    Idle,
    Waiting,
    Sent,
    Dropped,
    Failed(MediaFailure),
    Terminal(MediaFailure),
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
            MediaAttempt::Terminal(failure) => self.raise_terminal(failure, platform),
            MediaAttempt::Inactive
            | MediaAttempt::Superseded { .. }
            | MediaAttempt::Sent
            | MediaAttempt::Dropped => self.clear_kind(kind, platform),
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

    fn raise_terminal(&mut self, failure: &MediaFailure, platform: &dyn PlatformSessionControl) {
        let message = media_failure_message(failure);
        eprintln!("Lumen native media error code={message}");
        let _ = platform.publish_runtime_event(PlatformRuntimeEvent {
            disposition: PlatformRuntimeEventDisposition::Raised,
            severity: PlatformRuntimeEventSeverity::Error,
            code: failure.code,
            message: Some(message),
        });
    }
}

fn media_failure_message(failure: &MediaFailure) -> String {
    format!(
        "native-media-{}-{}: {}",
        match failure.kind {
            MediaKind::Video => "video",
            MediaKind::Audio => "audio",
        },
        failure.stage,
        failure.message
    )
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
    run_native_media_tasks(
        run_native_audio_sender(
            connection.clone(),
            session_epoch,
            router.clone(),
            Arc::clone(&platform),
        ),
        run_native_video_sender(
            connection.clone(),
            session_epoch,
            router.clone(),
            Arc::clone(&platform),
        ),
        run_native_motion_receiver(connection, session_epoch, router, platform),
    )
    .await
}

async fn run_native_media_tasks<Audio, Video, Motion>(
    audio: Audio,
    video: Video,
    motion: Motion,
) -> Result<(), String>
where
    Audio: Future<Output = Result<(), String>>,
    Video: Future<Output = Result<(), String>>,
    Motion: Future<Output = Result<(), String>>,
{
    tokio::pin!(audio, video, motion);
    tokio::select! {
        result = &mut audio => result,
        result = &mut video => result,
        result = &mut motion => result,
    }
}

async fn run_native_audio_sender(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), String> {
    let mut interval = tokio::time::interval(MEDIA_POLL_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut audio = AudioSenderState::default();
    let mut failures = MediaFailureReporter::default();
    loop {
        interval.tick().await;
        let attempt = poll_and_send_audio(
            &connection,
            session_epoch,
            &router,
            platform.as_ref(),
            &mut audio,
        )
        .await;
        failures.observe(MediaKind::Audio, &attempt, platform.as_ref());
        match attempt {
            MediaAttempt::Superseded {
                active_session_epoch,
            } => {
                eprintln!(
                    "Lumen native media stage=session-superseded kind=audio session-epoch={session_epoch} active-session-epoch={active_session_epoch}"
                );
                return Ok(());
            }
            MediaAttempt::Terminal(failure) => {
                return Err(format!(
                    "native audio {} failed: {}",
                    failure.stage, failure.message
                ));
            }
            _ => {}
        }
    }
}

async fn run_native_video_sender(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), String> {
    let mut interval = tokio::time::interval(MEDIA_POLL_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut video = VideoSenderState::default();
    let mut failures = MediaFailureReporter::default();
    loop {
        interval.tick().await;
        let queue_was_empty_before_video =
            connection.datagram_send_buffer_space() == NATIVE_MEDIA_SEND_BUFFER_BYTES;
        let attempt = poll_and_send_video(
            &connection,
            session_epoch,
            &router,
            platform.as_ref(),
            &mut video,
            queue_was_empty_before_video,
        )
        .await;
        failures.observe(MediaKind::Video, &attempt, platform.as_ref());
        match attempt {
            MediaAttempt::Superseded {
                active_session_epoch,
            } => {
                eprintln!(
                    "Lumen native media stage=session-superseded kind=video session-epoch={session_epoch} active-session-epoch={active_session_epoch}"
                );
                return Ok(());
            }
            MediaAttempt::Terminal(failure) => {
                return Err(format!(
                    "native video {} failed: {}",
                    failure.stage, failure.message
                ));
            }
            _ => {}
        }
    }
}

async fn run_native_motion_receiver(
    connection: quinn::Connection,
    session_epoch: u32,
    router: SharedControlRouter,
    platform: Arc<dyn PlatformSessionControl>,
) -> Result<(), String> {
    let mut motion = NativeMotionReceiver::default();
    let mut motion_failure_active = false;
    loop {
        let datagram = connection
            .read_datagram()
            .await
            .map_err(|error| format!("could not read QUIC media datagram: {error}"))?;
        handle_motion_datagram(
            &router,
            platform.as_ref(),
            session_epoch,
            &datagram,
            &mut motion,
            &mut motion_failure_active,
        );
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

#[derive(Clone, Debug, Eq, PartialEq)]
enum SessionDelivery<T> {
    Inactive,
    Owned(T),
    Superseded { active_session_epoch: u32 },
}

fn delivery_for_session<T>(
    delivery: Option<T>,
    expected_session_epoch: u32,
    session_epoch: impl FnOnce(&T) -> u32,
) -> SessionDelivery<T> {
    let Some(delivery) = delivery else {
        return SessionDelivery::Inactive;
    };
    let active_session_epoch = session_epoch(&delivery);
    if active_session_epoch != expected_session_epoch {
        return SessionDelivery::Superseded {
            active_session_epoch,
        };
    }
    SessionDelivery::Owned(delivery)
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
    session_epoch: u32,
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    sender: &mut AudioSenderState,
) -> MediaAttempt {
    let delivery = router
        .lock()
        .ok()
        .and_then(|router| router.audio_delivery_state());
    let delivery =
        match delivery_for_session(delivery, session_epoch, |delivery| delivery.session_epoch) {
            SessionDelivery::Inactive => return MediaAttempt::Inactive,
            SessionDelivery::Owned(delivery) => delivery,
            SessionDelivery::Superseded {
                active_session_epoch,
            } => {
                return MediaAttempt::Superseded {
                    active_session_epoch,
                }
            }
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
    let pending_since = Instant::now();
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
    let packet_duration =
        Duration::from_micros(u64::from(packet.duration_frames).saturating_mul(1_000_000) / 48_000);
    let Some(deadline) = pending_since.checked_add(packet_duration) else {
        return MediaAttempt::Failed(audio_failure(
            "packetizer-failed",
            "audio object deadline overflowed".to_owned(),
        ));
    };
    let report = send_datagram_batch(
        packetized.datagrams,
        DatagramBatchMode::DeadlineWait,
        Some(deadline),
        |mode, datagram, deadline| send_connection_datagram(connection, mode, datagram, deadline),
    )
    .await;
    sender.unit_id = match unit_id.checked_add(1) {
        Some(next) => next,
        None => {
            return MediaAttempt::Failed(audio_failure(
                "packetizer-failed",
                "audio unit id exhausted".to_owned(),
            ))
        }
    };
    if unit_id <= 3
        || unit_id.checked_rem(200) == Some(0)
        || report.status != DatagramBatchStatus::Complete
    {
        log_datagram_batch(
            "audio",
            delivery.session_epoch,
            0,
            unit_id,
            &report,
            duration_to_microseconds(pending_since.elapsed()),
            duration_to_microseconds(packet_duration),
        );
    }
    match &report.status {
        DatagramBatchStatus::Complete => MediaAttempt::Sent,
        DatagramBatchStatus::Dropped(_) => MediaAttempt::Dropped,
        DatagramBatchStatus::Failed(message) => MediaAttempt::Failed(audio_failure(
            "quic-datagram-send-failed",
            format!("{message}; unit-id={unit_id}"),
        )),
    }
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
    repair_after_bootstrap: bool,
    frame_id: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct VideoBootstrapClassification {
    reason: NativeVideoBootstrapReason,
    requires_encoder_resume: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum VideoKeyframeDelivery {
    SameGenerationDatagram,
    ReliableBootstrap(VideoBootstrapClassification),
}

fn classify_video_bootstrap(
    has_new_configuration: bool,
    has_acknowledged_generation: bool,
    repair_keyframe: bool,
    platform_requires_acknowledgement: bool,
) -> VideoBootstrapClassification {
    if !has_acknowledged_generation {
        VideoBootstrapClassification {
            reason: NativeVideoBootstrapReason::Initial,
            requires_encoder_resume: true,
        }
    } else if repair_keyframe {
        VideoBootstrapClassification {
            reason: NativeVideoBootstrapReason::Repair,
            requires_encoder_resume: true,
        }
    } else if has_new_configuration {
        VideoBootstrapClassification {
            reason: NativeVideoBootstrapReason::ConfigurationChange,
            requires_encoder_resume: platform_requires_acknowledgement,
        }
    } else {
        VideoBootstrapClassification {
            reason: NativeVideoBootstrapReason::Periodic,
            requires_encoder_resume: platform_requires_acknowledgement,
        }
    }
}

fn classify_video_keyframe_delivery(
    has_new_configuration: bool,
    has_acknowledged_generation: bool,
    repair_keyframe: bool,
    platform_requires_acknowledgement: bool,
) -> VideoKeyframeDelivery {
    let bootstrap = classify_video_bootstrap(
        has_new_configuration,
        has_acknowledged_generation,
        repair_keyframe,
        platform_requires_acknowledgement,
    );
    if bootstrap.reason == NativeVideoBootstrapReason::Periodic {
        VideoKeyframeDelivery::SameGenerationDatagram
    } else {
        VideoKeyframeDelivery::ReliableBootstrap(bootstrap)
    }
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
        self.repair_after_bootstrap = false;
        self.frame_id = 1;
        self.identity = Some(identity);
        Ok(())
    }

    fn pending_bootstrap_frame_should_drop(
        &mut self,
        repair_keyframe: bool,
        age: Option<Duration>,
        maximum_object_delay_us: u32,
    ) -> bool {
        if repair_keyframe {
            return false;
        }
        let should_drop = self.repair_after_bootstrap
            || age.is_some_and(|age| object_deadline_exceeded(age, maximum_object_delay_us));
        self.repair_after_bootstrap |= should_drop;
        should_drop
    }

    fn take_post_bootstrap_repair_request(&mut self, bootstrap_pending: bool) -> bool {
        if bootstrap_pending || !self.repair_after_bootstrap {
            return false;
        }
        self.repair_after_bootstrap = false;
        self.repair_required = true;
        true
    }

    fn finish_delta_delivery(
        &mut self,
        frame_id: u32,
        repair_required: bool,
        bootstrap_pending: bool,
    ) -> Result<bool, String> {
        self.frame_id = frame_id
            .checked_add(1)
            .ok_or_else(|| "video frame id exhausted".to_owned())?;
        self.pending_frame = None;
        self.pending_since = None;
        if repair_required && bootstrap_pending {
            self.repair_after_bootstrap = true;
            return Ok(false);
        }
        let request_repair = repair_required && !self.repair_required;
        self.repair_required |= repair_required;
        Ok(request_repair)
    }
}

async fn poll_and_send_video(
    connection: &quinn::Connection,
    session_epoch: u32,
    router: &SharedControlRouter,
    platform: &dyn PlatformSessionControl,
    sender: &mut VideoSenderState,
    queue_was_empty_before_current_audio: bool,
) -> MediaAttempt {
    let delivery = router
        .lock()
        .ok()
        .and_then(|router| router.video_delivery_state());
    let delivery =
        match delivery_for_session(delivery, session_epoch, |delivery| delivery.session_epoch) {
            SessionDelivery::Inactive => return MediaAttempt::Inactive,
            SessionDelivery::Owned(delivery) => delivery,
            SessionDelivery::Superseded {
                active_session_epoch,
            } => {
                return MediaAttempt::Superseded {
                    active_session_epoch,
                }
            }
        };
    if let Err(message) = sender.prepare(&delivery) {
        return MediaAttempt::Failed(video_failure("packetizer-failed", message));
    }
    if sender.take_post_bootstrap_repair_request(delivery.bootstrap_pending) {
        if let Err(message) = platform.handle_control_event(
            delivery.session_epoch,
            crate::PlatformControlEvent::RequestIdrFrame,
        ) {
            return MediaAttempt::Terminal(video_capture_failure(
                "post-bootstrap-keyframe-request-failed",
                message,
            ));
        }
        eprintln!(
            "Lumen object delivery stage=post-bootstrap-repair-requested session-epoch={}",
            delivery.session_epoch
        );
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
    if !normalized.frame.key_frame && (sender.repair_required || delivery.repair_keyframe_requested)
    {
        sender.pending_frame = None;
        sender.pending_since = None;
        return MediaAttempt::Dropped;
    }
    if delivery.bootstrap_pending {
        // Retain at most one fresh dependent frame for one negotiated object deadline. If the
        // bootstrap ACK is slower, drain later encoded frames without requesting another IDR;
        // one owned repair is requested only after the pending generation is acknowledged.
        let repair_keyframe = normalized.frame.repair_keyframe;
        if normalized.frame.key_frame && repair_keyframe {
            sender.pending_since = None;
            return MediaAttempt::Waiting;
        }
        let pending_age = sender
            .pending_since
            .map(|pending_since| pending_since.elapsed());
        if sender.pending_bootstrap_frame_should_drop(
            repair_keyframe,
            pending_age,
            delivery.maximum_object_delay_us,
        ) {
            sender.pending_frame = None;
            sender.pending_since = None;
            sender.repair_after_bootstrap = true;
            return MediaAttempt::Dropped;
        }
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
        if let Err(message) = platform.handle_control_event(
            delivery.session_epoch,
            crate::PlatformControlEvent::RequestIdrFrame,
        ) {
            return MediaAttempt::Terminal(video_capture_failure(
                "stale-frame-keyframe-request-failed",
                message,
            ));
        }
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
        let delivery_kind = classify_video_keyframe_delivery(
            normalized.new_configuration.is_some(),
            delivery.acknowledged_generation_id.is_some(),
            normalized.frame.repair_keyframe,
            normalized.frame.requires_bootstrap_acknowledgement,
        );
        match delivery_kind {
            VideoKeyframeDelivery::SameGenerationDatagram => {
                eprintln!(
                    "Lumen object delivery stage=periodic-keyframe-datagram session-epoch={} generation-id={} frame-id={frame_id}",
                    delivery.session_epoch,
                    delivery.acknowledged_generation_id.unwrap_or_default()
                );
            }
            VideoKeyframeDelivery::ReliableBootstrap(classification) => {
                let published = router.lock().ok().and_then(|mut router| {
                    router.publish_native_video_bootstrap(
                        normalized.configuration_id,
                        frame_id,
                        timestamp_to_microseconds(normalized.frame.presentation_time_90khz, 90_000),
                        classification.reason,
                        classification.requires_encoder_resume,
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
                if classification.reason == NativeVideoBootstrapReason::Repair {
                    sender.repair_required = false;
                }
                return MediaAttempt::Waiting;
            }
        }
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
    let pending_since = sender.pending_since.expect("staged video frame timestamp");
    let Some(deadline) = pending_since.checked_add(Duration::from_micros(u64::from(
        delivery.maximum_object_delay_us,
    ))) else {
        return MediaAttempt::Failed(video_failure(
            "packetizer-failed",
            "video object deadline overflowed".to_owned(),
        ));
    };
    let report = send_video_datagram_batch(
        packetized.datagrams,
        NATIVE_MEDIA_SEND_BUFFER_BYTES,
        NATIVE_AUDIO_EGRESS_RESERVE_BYTES,
        queue_was_empty_before_current_audio,
        deadline,
        |required_capacity, deadline| {
            wait_for_connection_datagram_queue_capacity(connection, required_capacity, deadline)
        },
        |mode, datagram, deadline| send_connection_datagram(connection, mode, datagram, deadline),
    )
    .await;
    let delivery_complete = report.status == DatagramBatchStatus::Complete;
    let request_repair = match sender.finish_delta_delivery(
        frame_id,
        !delivery_complete,
        delivery.bootstrap_pending,
    ) {
        Ok(request_repair) => request_repair,
        Err(message) => return MediaAttempt::Failed(video_failure("packetizer-failed", message)),
    };
    let object_age_us = duration_to_microseconds(pending_since.elapsed());
    if frame_id <= 3
        || frame_id.checked_rem(120) == Some(0)
        || report.mode == DatagramBatchMode::DeadlineWait
        || !delivery_complete
    {
        log_datagram_batch(
            "video-delta",
            delivery.session_epoch,
            generation_id,
            frame_id,
            &report,
            object_age_us,
            u64::from(delivery.maximum_object_delay_us),
        );
    }
    if request_repair {
        if let Err(message) = platform.handle_control_event(
            delivery.session_epoch,
            crate::PlatformControlEvent::RequestIdrFrame,
        ) {
            return MediaAttempt::Terminal(video_capture_failure(
                "transport-keyframe-request-failed",
                message,
            ));
        }
        eprintln!(
            "Lumen object delivery stage=transport-repair-requested session-epoch={} generation-id={generation_id} frame-id={frame_id} cause=incomplete-object",
            delivery.session_epoch,
        );
    }
    match &report.status {
        DatagramBatchStatus::Complete => {
            if let Ok(mut router) = router.lock() {
                let _ = router.observe_native_video_frame_sent(delivery.session_epoch, frame_id);
            }
            MediaAttempt::Sent
        }
        DatagramBatchStatus::Dropped(_) => MediaAttempt::Dropped,
        DatagramBatchStatus::Failed(message) => MediaAttempt::Failed(video_failure(
            "quic-datagram-send-failed",
            format!("{message}; frame-id={frame_id}"),
        )),
    }
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

fn video_capture_failure(stage: &'static str, message: String) -> MediaFailure {
    MediaFailure {
        code: PlatformRuntimeEventCode::NativeVideoCapturePoll,
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

fn duration_to_microseconds(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

#[allow(clippy::too_many_arguments)]
fn log_datagram_batch(
    kind: &str,
    session_epoch: u32,
    generation_id: u32,
    object_id: u32,
    report: &DatagramBatchReport,
    object_age_us: u64,
    deadline_us: u64,
) {
    let (stage, outcome, error) = match &report.status {
        DatagramBatchStatus::Complete => ("datagram-batch-sent", "complete", ""),
        DatagramBatchStatus::Dropped(reason) => ("datagram-batch-dropped", reason.as_str(), ""),
        DatagramBatchStatus::Failed(error) => {
            ("datagram-batch-failed", "send-failed", error.as_str())
        }
    };
    eprintln!(
        "Lumen native media stage={stage} kind={kind} session-epoch={session_epoch} generation-id={generation_id} object-id={object_id} outcome={outcome} error={error} transport-mode={} datagrams-sent={} datagrams-total={} bytes={} queue-wait-us={} send-wait-us={} object-age-us={object_age_us} deadline-us={deadline_us}",
        report.mode.as_str(),
        report.sent_datagrams,
        report.total_datagrams,
        report.total_bytes,
        duration_to_microseconds(report.queue_wait_duration),
        duration_to_microseconds(report.send_wait_duration),
    );
}

fn object_deadline_exceeded(age: Duration, maximum_object_delay_us: u32) -> bool {
    age > Duration::from_micros(u64::from(maximum_object_delay_us))
}

#[cfg(test)]
mod tests {
    use super::{
        classify_video_keyframe_delivery, delivery_for_session, object_deadline_exceeded,
        run_native_media_tasks, send_datagram_batch, send_video_datagram_batch,
        wait_for_datagram_deadline, wait_for_datagram_queue_capacity, DatagramBatchDropReason,
        DatagramBatchMode, DatagramBatchStatus, DatagramDeadlineElapsed, DatagramSendOutcome,
        SessionDelivery, VideoBootstrapClassification, VideoKeyframeDelivery, VideoSenderState,
    };
    use lumen_engine::NativeVideoBootstrapReason;
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::future::Future;
    use std::pin::Pin;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::task::{Context, Poll};
    use std::time::{Duration, Instant};
    use tokio::sync::Notify;

    struct PendingSend {
        polls: Arc<AtomicUsize>,
        dropped: Arc<AtomicBool>,
    }

    impl Future for PendingSend {
        type Output = Result<(), &'static str>;

        fn poll(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<Self::Output> {
            self.polls.fetch_add(1, Ordering::SeqCst);
            Poll::Pending
        }
    }

    impl Drop for PendingSend {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::SeqCst);
        }
    }

    struct DropSignal(Arc<AtomicBool>);

    impl Drop for DropSignal {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    #[tokio::test]
    async fn pending_video_future_does_not_block_audio_future() {
        let audio_started = Arc::new(Notify::new());
        let audio_started_signal = Arc::clone(&audio_started);
        let never_finishes = || async {
            std::future::pending::<()>().await;
            Ok::<(), String>(())
        };
        let scheduler = tokio::spawn(run_native_media_tasks(
            async move {
                audio_started_signal.notify_one();
                std::future::pending::<()>().await;
                Ok::<(), String>(())
            },
            never_finishes(),
            never_finishes(),
        ));

        tokio::time::timeout(Duration::from_millis(50), audio_started.notified())
            .await
            .expect("audio future must begin independently of pending video");

        scheduler.abort();
        let _ = scheduler.await;
    }

    #[tokio::test]
    async fn superseded_sender_completion_cancels_the_remaining_media_lanes() {
        let video_dropped = Arc::new(AtomicBool::new(false));
        let motion_dropped = Arc::new(AtomicBool::new(false));
        let video_drop_signal = DropSignal(Arc::clone(&video_dropped));
        let motion_drop_signal = DropSignal(Arc::clone(&motion_dropped));
        let video = async move {
            let _drop_signal = video_drop_signal;
            std::future::pending::<Result<(), String>>().await
        };
        let motion = async move {
            let _drop_signal = motion_drop_signal;
            std::future::pending::<Result<(), String>>().await
        };

        run_native_media_tasks(async { Ok(()) }, video, motion)
            .await
            .expect("a superseded lane should end its connection without a transport error");

        assert!(video_dropped.load(Ordering::SeqCst));
        assert!(motion_dropped.load(Ordering::SeqCst));
    }

    #[test]
    fn session_delivery_rejects_new_session_media_for_a_stale_connection() {
        let active = (42_u32, "new-session-media");

        assert_eq!(
            delivery_for_session(Some(active), 41, |delivery| delivery.0),
            SessionDelivery::Superseded {
                active_session_epoch: 42,
            }
        );
        assert_eq!(
            delivery_for_session(Some(active), 42, |delivery| delivery.0),
            SessionDelivery::Owned(active)
        );
        assert_eq!(
            delivery_for_session::<(u32, &str)>(None, 42, |delivery| delivery.0),
            SessionDelivery::Inactive
        );
    }

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

    #[test]
    fn periodic_keyframes_stay_in_generation_while_lifecycle_keyframes_remain_bootstraps() {
        assert_eq!(
            classify_video_keyframe_delivery(false, true, false, false),
            VideoKeyframeDelivery::SameGenerationDatagram
        );

        for (actual, expected_reason, expected_resume) in [
            (
                classify_video_keyframe_delivery(true, false, true, true),
                NativeVideoBootstrapReason::Initial,
                true,
            ),
            (
                classify_video_keyframe_delivery(true, true, false, true),
                NativeVideoBootstrapReason::ConfigurationChange,
                true,
            ),
            (
                classify_video_keyframe_delivery(false, true, true, true),
                NativeVideoBootstrapReason::Repair,
                true,
            ),
        ] {
            assert_eq!(
                actual,
                VideoKeyframeDelivery::ReliableBootstrap(VideoBootstrapClassification {
                    reason: expected_reason,
                    requires_encoder_resume: expected_resume,
                })
            );
        }
    }

    #[test]
    fn pending_reliable_bootstrap_drains_then_requests_one_post_ack_repair() {
        let mut sender = VideoSenderState::default();
        assert!(!sender.pending_bootstrap_frame_should_drop(
            false,
            Some(Duration::from_micros(16_668)),
            16_668,
        ));
        assert!(!sender.take_post_bootstrap_repair_request(false));

        assert!(sender.pending_bootstrap_frame_should_drop(
            false,
            Some(Duration::from_micros(16_669)),
            16_668,
        ));
        assert!(sender.pending_bootstrap_frame_should_drop(false, Some(Duration::ZERO), 16_668,));
        assert!(!sender.take_post_bootstrap_repair_request(true));
        assert!(sender.take_post_bootstrap_repair_request(false));
        assert!(!sender.take_post_bootstrap_repair_request(false));
        assert!(sender.repair_required);

        let mut owned = VideoSenderState::default();
        assert!(!owned.pending_bootstrap_frame_should_drop(
            true,
            Some(Duration::from_secs(1)),
            16_668,
        ));
        assert!(!owned.take_post_bootstrap_repair_request(false));
    }

    #[tokio::test]
    async fn occupied_queue_barrier_deadline_cancels_without_sending() {
        let polls = Arc::new(AtomicUsize::new(0));
        let dropped = Arc::new(AtomicBool::new(false));
        let wait_polls = Arc::clone(&polls);
        let wait_dropped = Arc::clone(&dropped);
        let deadline = Instant::now() + Duration::from_millis(2);

        let result = wait_for_datagram_queue_capacity(
            12,
            12,
            deadline,
            || 8,
            move |deadline| {
                let pending = PendingSend {
                    polls: Arc::clone(&wait_polls),
                    dropped: Arc::clone(&wait_dropped),
                };
                async move {
                    wait_for_datagram_deadline(deadline, pending)
                        .await
                        .map(|_| ())
                }
            },
        )
        .await;

        assert_eq!(result, Err(DatagramDeadlineElapsed));
        assert!(polls.load(Ordering::SeqCst) > 0);
        assert!(dropped.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn available_capacity_admits_complete_video_object_without_draining_audio() {
        let queued = Rc::new(RefCell::new((4_usize, VecDeque::from([vec![9_u8; 4]]))));
        let requested = Rc::new(Cell::new(0));
        let barrier_queue = Rc::clone(&queued);
        let requested_capacity = Rc::clone(&requested);
        let send_queue = Rc::clone(&queued);
        let report = send_video_datagram_batch(
            vec![vec![1; 4], vec![2; 4]],
            12,
            0,
            true,
            Instant::now() + Duration::from_secs(1),
            move |required_capacity, deadline| {
                requested_capacity.set(required_capacity);
                let queued = Rc::clone(&barrier_queue);
                async move {
                    wait_for_datagram_queue_capacity(
                        12,
                        required_capacity,
                        deadline,
                        || 12 - queued.borrow().0,
                        |_| async {
                            panic!("complete video object already fits beside queued audio")
                        },
                    )
                    .await
                }
            },
            move |_, datagram, _| {
                let queued = Rc::clone(&send_queue);
                async move {
                    let mut queued = queued.borrow_mut();
                    queued.0 += datagram.len();
                    queued.1.push_back(datagram);
                    DatagramSendOutcome::Sent
                }
            },
        )
        .await;

        assert_eq!(requested.get(), 8);
        assert_eq!(report.status, DatagramBatchStatus::Complete);
        assert_eq!(report.mode, DatagramBatchMode::FreshEnqueue);
        assert_eq!(report.sent_datagrams, 2);
        assert_eq!(
            queued
                .borrow()
                .1
                .iter()
                .map(|datagram| datagram[0])
                .collect::<Vec<_>>(),
            vec![9, 1, 2]
        );
    }

    #[tokio::test]
    async fn video_capacity_preserves_headroom_for_the_next_audio_packets() {
        let required = Rc::new(Cell::new(0));
        let requested_capacity = Rc::clone(&required);
        let report = send_video_datagram_batch(
            vec![vec![1; 4], vec![2; 4]],
            16,
            4,
            true,
            Instant::now() + Duration::from_secs(1),
            move |required_capacity, _| {
                requested_capacity.set(required_capacity);
                async { Ok(Duration::ZERO) }
            },
            |_, _, _| async { DatagramSendOutcome::Sent },
        )
        .await;

        assert_eq!(required.get(), 12);
        assert_eq!(report.status, DatagramBatchStatus::Complete);
        assert_eq!(report.sent_datagrams, 2);
    }

    #[tokio::test]
    async fn possible_prior_video_requires_full_queue_drain() {
        let required = Rc::new(Cell::new(0));
        let requested_capacity = Rc::clone(&required);
        let report = send_video_datagram_batch(
            vec![vec![1; 4], vec![2; 4]],
            12,
            0,
            false,
            Instant::now() + Duration::from_secs(1),
            move |required_capacity, _| {
                requested_capacity.set(required_capacity);
                async { Err(DatagramDeadlineElapsed) }
            },
            |_, _, _| async {
                panic!("video must not enqueue behind a possible prior video object")
            },
        )
        .await;

        assert_eq!(required.get(), 12);
        assert_eq!(
            report.status,
            DatagramBatchStatus::Dropped(DatagramBatchDropReason::QueueBarrierDeadlineExceeded)
        );
        assert_eq!(report.sent_datagrams, 0);
    }

    #[tokio::test]
    async fn from_empty_fresh_batch_enqueues_one_complete_object() {
        let queued = Rc::new(RefCell::new((0_usize, VecDeque::new())));
        let send_queue = Rc::clone(&queued);
        let report = send_datagram_batch(
            vec![vec![1; 4], vec![2; 4], vec![3; 4]],
            DatagramBatchMode::FreshEnqueue,
            None,
            move |mode, datagram, _| {
                let queued = Rc::clone(&send_queue);
                async move {
                    assert_eq!(mode, DatagramBatchMode::FreshEnqueue);
                    let mut queued = queued.borrow_mut();
                    while queued.0 > 12 {
                        let dropped: Vec<u8> = queued.1.pop_front().expect("queued datagram");
                        queued.0 -= dropped.len();
                    }
                    queued.0 += datagram.len();
                    queued.1.push_back(datagram);
                    DatagramSendOutcome::Sent
                }
            },
        )
        .await;

        assert_eq!(report.status, DatagramBatchStatus::Complete);
        assert_eq!(report.mode, DatagramBatchMode::FreshEnqueue);
        assert_eq!(report.total_datagrams, 3);
        assert_eq!(report.sent_datagrams, 3);
        assert_eq!(report.total_bytes, 12);
        assert_eq!(
            queued
                .borrow()
                .1
                .iter()
                .map(|datagram| datagram[0])
                .collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
    }

    #[tokio::test]
    async fn barrier_timeout_drops_whole_frame_then_empty_queue_recovers_latest() {
        let sent = Rc::new(RefCell::new(Vec::new()));
        let send_log = Rc::clone(&sent);
        let blocked = send_video_datagram_batch(
            vec![vec![1; 4], vec![1; 4]],
            8,
            0,
            false,
            Instant::now() + Duration::from_secs(1),
            |_, _| async { Err(DatagramDeadlineElapsed) },
            move |_, datagram, _| {
                let sent = Rc::clone(&send_log);
                async move {
                    sent.borrow_mut().push(datagram);
                    DatagramSendOutcome::Sent
                }
            },
        )
        .await;

        assert_eq!(
            blocked.status,
            DatagramBatchStatus::Dropped(DatagramBatchDropReason::QueueBarrierDeadlineExceeded)
        );
        assert_eq!(blocked.sent_datagrams, 0);
        assert!(sent.borrow().is_empty());

        let recovered_log = Rc::clone(&sent);
        let fresh = send_video_datagram_batch(
            vec![vec![2; 4], vec![2; 4]],
            8,
            0,
            false,
            Instant::now() + Duration::from_secs(1),
            |_, _| async { Ok(Duration::ZERO) },
            move |_, datagram, _| {
                let sent = Rc::clone(&recovered_log);
                async move {
                    sent.borrow_mut().push(datagram);
                    DatagramSendOutcome::Sent
                }
            },
        )
        .await;

        assert_eq!(fresh.status, DatagramBatchStatus::Complete);
        assert_eq!(fresh.mode, DatagramBatchMode::FreshEnqueue);
        assert_eq!(fresh.sent_datagrams, 2);
        assert_eq!(
            sent.borrow()
                .iter()
                .map(|datagram| datagram[0])
                .collect::<Vec<_>>(),
            vec![2, 2]
        );
    }

    #[tokio::test]
    async fn audio_wait_is_bounded_and_never_uses_evicting_send() {
        let sent = Rc::new(RefCell::new(Vec::new()));
        let calls = Rc::new(Cell::new(0));
        let send_log = Rc::clone(&sent);
        let send_calls = Rc::clone(&calls);
        let report = send_datagram_batch(
            vec![vec![1; 800], vec![1; 800]],
            DatagramBatchMode::DeadlineWait,
            Some(Instant::now() + Duration::from_secs(1)),
            move |mode, datagram, _| {
                let sent = Rc::clone(&send_log);
                let call = send_calls.get();
                send_calls.set(call + 1);
                async move {
                    assert_eq!(mode, DatagramBatchMode::DeadlineWait);
                    if call == 0 {
                        sent.borrow_mut().push(datagram);
                        DatagramSendOutcome::Sent
                    } else {
                        DatagramSendOutcome::DeadlineExceeded
                    }
                }
            },
        )
        .await;

        assert_eq!(
            report.status,
            DatagramBatchStatus::Dropped(DatagramBatchDropReason::SendDeadlineExceeded)
        );
        assert_eq!(report.mode, DatagramBatchMode::DeadlineWait);
        assert_eq!(report.sent_datagrams, 1);
        assert_eq!(sent.borrow().len(), 1);
    }

    #[test]
    fn transport_drop_during_bootstrap_defers_one_repair_until_ack() {
        let mut sender = VideoSenderState {
            frame_id: 41,
            ..VideoSenderState::default()
        };

        assert!(!sender.finish_delta_delivery(41, true, true).unwrap());

        assert_eq!(sender.frame_id, 42);
        assert!(!sender.repair_required);
        assert!(sender.repair_after_bootstrap);
        assert!(!sender.take_post_bootstrap_repair_request(true));
        assert!(sender.take_post_bootstrap_repair_request(false));
        assert!(!sender.take_post_bootstrap_repair_request(false));
        assert!(sender.pending_frame.is_none());
        assert!(sender.pending_since.is_none());
    }
}
