use std::collections::HashSet;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use lumen_engine::{
    decode_native_media_datagram, CodecConfiguration, NativeMediaKind, NativeVideoBootstrapReason,
    NativeVideoCodec, NATIVE_AUDIO_STREAM_ID, NATIVE_VIDEO_STREAM_ID,
};

use super::adaptive_video::apply_adaptive_video_policy_request;
use super::packet_arrival::{PacketArrivalHistory, PacketIdentity};
use super::SharedControlRouter;
use crate::control::{
    AudioDeliveryState, InputMotionDeliveryState, NativeAdaptiveVideoPolicyRequest,
    NativeVideoRepairSource, VideoDeliveryState,
};
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
use tokio::sync::mpsc;
#[cfg(test)]
use tokio::sync::oneshot;

const MEDIA_POLL_INTERVAL: Duration = Duration::from_millis(1);
const MAXIMUM_VIDEO_WIRE_BURST_DATAGRAMS: usize = 2;
const PERIODIC_KEYFRAME_SCHEDULING_MARGIN_US: u64 = 5_000;
const PERIODIC_KEYFRAME_DEADLINE_FRAMES: u64 = 4;
pub(super) const NATIVE_MEDIA_SEND_BUFFER_BYTES: usize = 4 * 1024 * 1024;
const NATIVE_AUDIO_EGRESS_RESERVE_BYTES: usize = 2 * 1_200;
const PACKET_ARRIVAL_WARNING_COMMAND_CAPACITY: usize = 8;
const PACKET_ARRIVAL_WARNING_MESSAGE: &str = "packet-arrival-history-unavailable";

#[derive(Clone)]
struct PacketArrivalHistoryWarningReporter {
    commands: mpsc::Sender<PacketArrivalHistoryWarningCommand>,
    warning_present: Arc<AtomicBool>,
}

enum PacketArrivalHistoryWarningCommand {
    Unavailable,
    Available,
    #[cfg(test)]
    Flush(oneshot::Sender<()>),
}

impl PacketArrivalHistoryWarningReporter {
    fn spawn(platform: Arc<dyn PlatformSessionControl>) -> Self {
        let (commands, mut receiver) = mpsc::channel(PACKET_ARRIVAL_WARNING_COMMAND_CAPACITY);
        let warning_present = Arc::new(AtomicBool::new(false));
        tokio::spawn(async move {
            let mut warning_active = false;
            while let Some(command) = receiver.recv().await {
                match command {
                    PacketArrivalHistoryWarningCommand::Unavailable if !warning_active => {
                        let event = PlatformRuntimeEvent {
                            disposition: PlatformRuntimeEventDisposition::Raised,
                            severity: PlatformRuntimeEventSeverity::Warning,
                            code: PlatformRuntimeEventCode::NativePacketArrivalFeedback,
                            message: Some(PACKET_ARRIVAL_WARNING_MESSAGE.to_owned()),
                        };
                        if let Err(error) = platform.publish_runtime_event(event) {
                            eprintln!(
                                "Lumen native media stage=packet-arrival-warning-publish-failed error={error}"
                            );
                        }
                        warning_active = true;
                    }
                    PacketArrivalHistoryWarningCommand::Available if warning_active => {
                        let event = PlatformRuntimeEvent {
                            disposition: PlatformRuntimeEventDisposition::Cleared,
                            severity: PlatformRuntimeEventSeverity::Warning,
                            code: PlatformRuntimeEventCode::NativePacketArrivalFeedback,
                            message: None,
                        };
                        if let Err(error) = platform.publish_runtime_event(event) {
                            eprintln!(
                                "Lumen native media stage=packet-arrival-warning-clear-failed error={error}"
                            );
                        }
                        warning_active = false;
                    }
                    #[cfg(test)]
                    PacketArrivalHistoryWarningCommand::Flush(response) => {
                        let _ = response.send(());
                    }
                    PacketArrivalHistoryWarningCommand::Unavailable
                    | PacketArrivalHistoryWarningCommand::Available => (),
                }
            }
        });
        Self {
            commands,
            warning_present,
        }
    }

    fn unavailable(&self) {
        if self
            .warning_present
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        if self
            .commands
            .try_send(PacketArrivalHistoryWarningCommand::Unavailable)
            .is_err()
        {
            self.warning_present.store(false, Ordering::Release);
        }
    }

    fn available(&self) {
        if !self.warning_present.swap(false, Ordering::AcqRel) {
            return;
        }
        if self
            .commands
            .try_send(PacketArrivalHistoryWarningCommand::Available)
            .is_err()
        {
            self.warning_present.store(true, Ordering::Release);
        }
    }

    #[cfg(test)]
    async fn flush(&self) {
        let (response, receive) = oneshot::channel();
        self.commands
            .send(PacketArrivalHistoryWarningCommand::Flush(response))
            .await
            .unwrap();
        receive.await.unwrap();
    }
}

#[derive(Clone)]
struct PacketArrivalSendObservation {
    history: PacketArrivalHistory,
    warning_reporter: PacketArrivalHistoryWarningReporter,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DatagramBatchMode {
    FreshEnqueue,
    DeadlineWait,
    CommittedDrain,
}

impl DatagramBatchMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::FreshEnqueue => "capacity-reserved-enqueue",
            Self::DeadlineWait => "deadline-wait",
            Self::CommittedDrain => "committed-object-drain",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DatagramBatchDropReason {
    QueueBarrier,
    Send,
    WireRate,
}

impl DatagramBatchDropReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::QueueBarrier => "queue-barrier-deadline-exceeded",
            Self::Send => "send-deadline-exceeded",
            Self::WireRate => "wire-rate-deadline-exceeded",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum DatagramBatchStatus {
    Complete,
    Dropped(DatagramBatchDropReason),
    Failed(String),
    Terminal(String),
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
        DatagramBatchMode::CommittedDrain => connection.send_datagram_wait(datagram.into()).await,
    };
    match result {
        Ok(()) => DatagramSendOutcome::Sent,
        Err(error) => DatagramSendOutcome::Failed(error.to_string()),
    }
}

async fn send_tracked_connection_datagram(
    connection: &quinn::Connection,
    packet_arrival: &PacketArrivalSendObservation,
    mode: DatagramBatchMode,
    datagram: Vec<u8>,
    deadline: Option<Instant>,
) -> DatagramSendOutcome {
    let identity = decode_native_media_datagram(&datagram)
        .ok()
        .and_then(|decoded| {
            let stream_id = match decoded.header.kind {
                NativeMediaKind::VideoDelta => NATIVE_VIDEO_STREAM_ID,
                NativeMediaKind::Audio => NATIVE_AUDIO_STREAM_ID,
                NativeMediaKind::InputMotion => return None,
            };
            Some(PacketIdentity {
                stream_id,
                datagram_sequence: decoded.header.datagram_sequence,
            })
        });
    let outcome = send_connection_datagram(connection, mode, datagram, deadline).await;
    record_successful_datagram(packet_arrival, identity, &outcome);
    outcome
}

fn record_successful_datagram(
    packet_arrival: &PacketArrivalSendObservation,
    identity: Option<PacketIdentity>,
    outcome: &DatagramSendOutcome,
) {
    if matches!(outcome, DatagramSendOutcome::Sent) {
        if let Some(identity) = identity {
            match packet_arrival.history.record_sent(identity) {
                Ok(()) => packet_arrival.warning_reporter.available(),
                Err(error) => {
                    eprintln!(
                        "Lumen native media stage=packet-arrival-history-unavailable stream-id={} datagram-sequence={} reason={}",
                        identity.stream_id,
                        identity.datagram_sequence,
                        error.code(),
                    );
                    packet_arrival.warning_reporter.unavailable();
                }
            }
        }
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
        report.status = DatagramBatchStatus::Dropped(DatagramBatchDropReason::Send);
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
                report.status = DatagramBatchStatus::Dropped(DatagramBatchDropReason::Send);
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

#[allow(clippy::too_many_arguments)]
async fn send_admitted_datagram<Space, Send, SendFuture>(
    admission_gate: &tokio::sync::Mutex<()>,
    capacity: usize,
    required_capacity: usize,
    deadline: Instant,
    mode: DatagramBatchMode,
    datagram: Vec<u8>,
    send_buffer_space: &mut Space,
    send: &mut Send,
) -> Result<(Duration, DatagramSendOutcome), DatagramDeadlineElapsed>
where
    Space: FnMut() -> usize,
    Send: FnMut(DatagramBatchMode, Vec<u8>, Option<Instant>) -> SendFuture,
    SendFuture: Future<Output = DatagramSendOutcome>,
{
    if required_capacity > capacity {
        return Err(DatagramDeadlineElapsed);
    }
    let started = Instant::now();
    if Instant::now() >= deadline {
        return Err(DatagramDeadlineElapsed);
    }
    let admission = wait_for_datagram_deadline(deadline, admission_gate.lock()).await?;
    if send_buffer_space() < required_capacity {
        return Err(DatagramDeadlineElapsed);
    }
    let outcome = send(mode, datagram, Some(deadline)).await;
    drop(admission);
    Ok((started.elapsed(), outcome))
}

async fn send_tracked_admitted_connection_datagram(
    connection: &quinn::Connection,
    packet_arrival: &PacketArrivalSendObservation,
    admission_gate: &tokio::sync::Mutex<()>,
    mode: DatagramBatchMode,
    datagram: Vec<u8>,
    deadline: Option<Instant>,
) -> DatagramSendOutcome {
    let admission = match deadline {
        Some(deadline) => match wait_for_datagram_deadline(deadline, admission_gate.lock()).await {
            Ok(admission) => admission,
            Err(_) => return DatagramSendOutcome::DeadlineExceeded,
        },
        None => admission_gate.lock().await,
    };
    let outcome =
        send_tracked_connection_datagram(connection, packet_arrival, mode, datagram, deadline)
            .await;
    drop(admission);
    outcome
}

#[cfg(test)]
async fn send_video_datagram_batch<Barrier, BarrierFuture, Send, SendFuture>(
    datagrams: Vec<Vec<u8>>,
    send_buffer_capacity: usize,
    audio_reserve_bytes: usize,
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
    let required_capacity = if mode == DatagramBatchMode::FreshEnqueue {
        total_bytes.saturating_add(audio_reserve_bytes)
    } else {
        video_capacity
    };
    let barrier_started = Instant::now();
    let queue_wait_duration = match wait_for_capacity(required_capacity, deadline).await {
        Ok(duration) => duration,
        Err(_) => {
            return DatagramBatchReport {
                status: DatagramBatchStatus::Dropped(DatagramBatchDropReason::QueueBarrier),
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

#[allow(clippy::too_many_arguments)]
async fn send_wire_paced_video_datagram_batch<Barrier, BarrierFuture, Space, Send, SendFuture>(
    datagrams: Vec<Vec<u8>>,
    send_buffer_capacity: usize,
    audio_reserve_bytes: usize,
    deadline: Instant,
    admission_gate: &tokio::sync::Mutex<()>,
    wire_pacer: &Arc<tokio::sync::Mutex<VideoWireRatePacer>>,
    session_epoch: u32,
    wire_budget_kbps: u32,
    maximum_datagram_payload: usize,
    mut wait_for_capacity: Barrier,
    mut send_buffer_space: Space,
    mut send: Send,
) -> DatagramBatchReport
where
    Barrier: FnMut(usize, Instant) -> BarrierFuture,
    BarrierFuture: Future<Output = Result<Duration, DatagramDeadlineElapsed>>,
    Space: FnMut() -> usize,
    Send: FnMut(DatagramBatchMode, Vec<u8>, Option<Instant>) -> SendFuture,
    SendFuture: Future<Output = DatagramSendOutcome>,
{
    let total_datagrams = datagrams.len();
    let total_bytes = datagrams.iter().map(Vec::len).sum::<usize>();
    let video_capacity = send_buffer_capacity.saturating_sub(audio_reserve_bytes);
    let mode = if total_bytes <= video_capacity {
        DatagramBatchMode::FreshEnqueue
    } else {
        DatagramBatchMode::DeadlineWait
    };
    let required_capacity = if mode == DatagramBatchMode::FreshEnqueue {
        total_bytes.saturating_add(audio_reserve_bytes)
    } else {
        video_capacity
    };
    let barrier_started = Instant::now();
    let queue_wait_duration = match wait_for_capacity(required_capacity, deadline).await {
        Ok(duration) => duration,
        Err(_) => {
            return DatagramBatchReport {
                status: DatagramBatchStatus::Dropped(DatagramBatchDropReason::QueueBarrier),
                mode,
                total_datagrams,
                sent_datagrams: 0,
                total_bytes,
                queue_wait_duration: barrier_started.elapsed(),
                send_wait_duration: Duration::ZERO,
            };
        }
    };
    let datagram_bytes = datagrams.iter().map(Vec::len).collect::<Vec<_>>();
    let reservation = {
        let mut pacer = wire_pacer.lock().await;
        if pacer.prepare(session_epoch, wire_budget_kbps).is_err() {
            None
        } else {
            let before = pacer.clone();
            pacer
                .reserve(
                    &datagram_bytes,
                    maximum_datagram_payload,
                    Instant::now(),
                    deadline,
                )
                .map(|schedule| (schedule, before, pacer.clone()))
        }
    };
    let Some((schedule, pacer_before_reservation, pacer_after_reservation)) = reservation else {
        return DatagramBatchReport {
            status: DatagramBatchStatus::Dropped(DatagramBatchDropReason::WireRate),
            mode,
            total_datagrams,
            sent_datagrams: 0,
            total_bytes,
            queue_wait_duration,
            send_wait_duration: Duration::ZERO,
        };
    };
    let mut report = DatagramBatchReport {
        status: DatagramBatchStatus::Complete,
        mode,
        total_datagrams,
        sent_datagrams: 0,
        total_bytes,
        queue_wait_duration,
        send_wait_duration: Duration::ZERO,
    };
    for (index, (datagram, send_at)) in datagrams.into_iter().zip(schedule).enumerate() {
        let send_started = Instant::now();
        tokio::time::sleep_until(send_at.into()).await;
        if index == 0 && Instant::now() > deadline {
            report.status = DatagramBatchStatus::Dropped(DatagramBatchDropReason::Send);
            break;
        }
        let outcome = if index == 0 {
            match send_admitted_datagram(
                admission_gate,
                send_buffer_capacity,
                required_capacity,
                deadline,
                mode,
                datagram,
                &mut send_buffer_space,
                &mut send,
            )
            .await
            {
                Ok((queue_wait_duration, outcome)) => {
                    report.queue_wait_duration += queue_wait_duration;
                    outcome
                }
                Err(_) => {
                    report.status =
                        DatagramBatchStatus::Dropped(DatagramBatchDropReason::QueueBarrier);
                    report.queue_wait_duration += send_started.elapsed();
                    break;
                }
            }
        } else {
            send(DatagramBatchMode::CommittedDrain, datagram, None).await
        };
        if mode == DatagramBatchMode::DeadlineWait || index != 0 {
            report.send_wait_duration += send_started.elapsed();
        }
        match outcome {
            DatagramSendOutcome::Sent => report.sent_datagrams += 1,
            DatagramSendOutcome::DeadlineExceeded => {
                report.status = if index == 0 {
                    DatagramBatchStatus::Dropped(DatagramBatchDropReason::Send)
                } else {
                    DatagramBatchStatus::Terminal(
                        "committed video object drain reported a local deadline".to_owned(),
                    )
                };
                break;
            }
            DatagramSendOutcome::Failed(error) => {
                report.status = if index == 0 {
                    DatagramBatchStatus::Failed(error)
                } else {
                    DatagramBatchStatus::Terminal(error)
                };
                break;
            }
        }
    }
    if report.sent_datagrams == 0 {
        let mut pacer = wire_pacer.lock().await;
        pacer.rollback_reservation_if_current(pacer_before_reservation, &pacer_after_reservation);
    }
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
    packet_arrival_history: PacketArrivalHistory,
    video_wire_pacer: Arc<tokio::sync::Mutex<VideoWireRatePacer>>,
) -> Result<(), String> {
    let packet_arrival_warning_reporter =
        PacketArrivalHistoryWarningReporter::spawn(Arc::clone(&platform));
    let packet_arrival = PacketArrivalSendObservation {
        history: packet_arrival_history,
        warning_reporter: packet_arrival_warning_reporter,
    };
    let admission_gate = Arc::new(tokio::sync::Mutex::new(()));
    run_native_media_tasks(
        run_native_audio_sender(
            connection.clone(),
            session_epoch,
            router.clone(),
            Arc::clone(&platform),
            packet_arrival.clone(),
            Arc::clone(&admission_gate),
        ),
        run_native_video_sender(
            connection.clone(),
            session_epoch,
            router.clone(),
            Arc::clone(&platform),
            packet_arrival,
            video_wire_pacer,
            admission_gate,
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
    packet_arrival: PacketArrivalSendObservation,
    admission_gate: Arc<tokio::sync::Mutex<()>>,
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
            &packet_arrival,
            &admission_gate,
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
    packet_arrival: PacketArrivalSendObservation,
    wire_pacer: Arc<tokio::sync::Mutex<VideoWireRatePacer>>,
    admission_gate: Arc<tokio::sync::Mutex<()>>,
) -> Result<(), String> {
    let mut interval = tokio::time::interval(MEDIA_POLL_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut video = VideoSenderState::default();
    let mut failures = MediaFailureReporter::default();
    loop {
        interval.tick().await;
        let attempt = poll_and_send_video(
            &connection,
            session_epoch,
            &router,
            &platform,
            &mut video,
            &packet_arrival,
            &wire_pacer,
            &admission_gate,
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
    packet_arrival: &PacketArrivalSendObservation,
    admission_gate: &tokio::sync::Mutex<()>,
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
        |mode, datagram, deadline| {
            send_tracked_admitted_connection_datagram(
                connection,
                packet_arrival,
                admission_gate,
                mode,
                datagram,
                deadline,
            )
        },
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
        DatagramBatchStatus::Terminal(message) => MediaAttempt::Terminal(audio_failure(
            "quic-datagram-connection-failed",
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
    /// Published to the adaptive controller as a wire-budget floor.
    keyframe_wire_rate_requirement_kbps: Option<u32>,
}

#[derive(Clone, Default)]
pub(super) struct VideoWireRatePacer {
    session_epoch: Option<u32>,
    wire_budget_kbps: u32,
    next_send_at: Option<Instant>,
}

impl VideoWireRatePacer {
    pub(super) fn prepare(
        &mut self,
        session_epoch: u32,
        wire_budget_kbps: u32,
    ) -> Result<(), String> {
        if wire_budget_kbps == 0 {
            return Err("native video wire budget is zero".to_owned());
        }
        if self.session_epoch != Some(session_epoch) {
            self.session_epoch = Some(session_epoch);
            self.next_send_at = None;
        }
        self.wire_budget_kbps = wire_budget_kbps;
        Ok(())
    }

    pub(super) fn reserve(
        &mut self,
        datagram_bytes: &[usize],
        maximum_datagram_payload: usize,
        now: Instant,
        deadline: Instant,
    ) -> Option<Vec<Instant>> {
        let burst_bits = u64::try_from(maximum_datagram_payload)
            .ok()?
            .checked_mul(u64::try_from(MAXIMUM_VIDEO_WIRE_BURST_DATAGRAMS).ok()?)?
            .checked_mul(8)?;
        let burst_nanoseconds = burst_bits
            .checked_mul(1_000_000)?
            .div_ceil(u64::from(self.wire_budget_kbps));
        let burst_floor = now.checked_sub(Duration::from_nanos(burst_nanoseconds))?;
        let mut cursor = self
            .next_send_at
            .map_or(burst_floor, |reserved| reserved.max(burst_floor));
        let mut send_times = Vec::with_capacity(datagram_bytes.len());
        for bytes in datagram_bytes {
            let wire_bits = u64::try_from(*bytes).ok()?.checked_mul(8)?;
            let pacing_nanoseconds = wire_bits
                .checked_mul(1_000_000)?
                .div_ceil(u64::from(self.wire_budget_kbps));
            cursor = cursor.checked_add(Duration::from_nanos(pacing_nanoseconds))?;
            let send_at = cursor.max(now);
            if send_at > deadline {
                return None;
            }
            send_times.push(send_at);
        }
        self.next_send_at = Some(cursor);
        Some(send_times)
    }

    fn rollback_reservation_if_current(&mut self, before: Self, reserved: &Self) {
        if self.session_epoch == reserved.session_epoch
            && self.wire_budget_kbps == reserved.wire_budget_kbps
            && self.next_send_at == reserved.next_send_at
        {
            *self = before;
        }
    }
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

#[derive(Debug, Eq, PartialEq)]
enum VideoDatagramDeadlineError {
    InvalidWireBudget,
    InvalidRefreshCadence,
    ArithmeticOverflow,
}

/// The bounded window is a latency target, not a transport limit. Exceeding it
/// reports the rate that would satisfy it instead of failing the session.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct VideoDatagramPacing {
    deadline_us: u64,
    required_wire_kbps: Option<u32>,
}

fn four_refresh_frame_wire_window_us(
    refresh_millihz: u32,
) -> Result<u64, VideoDatagramDeadlineError> {
    if refresh_millihz == 0 {
        return Err(VideoDatagramDeadlineError::InvalidRefreshCadence);
    }
    1_000_000_000_u64
        .checked_mul(PERIODIC_KEYFRAME_DEADLINE_FRAMES)
        .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)
        .map(|four_frame_numerator| four_frame_numerator.div_ceil(u64::from(refresh_millihz)))
}

fn periodic_keyframe_deadline_cap_us(
    refresh_millihz: u32,
) -> Result<u64, VideoDatagramDeadlineError> {
    // Four refresh periods bound wire serialization. Scheduler wakeup tolerance is a separate
    // allowance so the same serialized object does not become invalid only at higher refresh.
    four_refresh_frame_wire_window_us(refresh_millihz)?
        .checked_add(PERIODIC_KEYFRAME_SCHEDULING_MARGIN_US)
        .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)
}

fn video_datagram_deadline_us<DatagramBytes, ObjectAge>(
    same_generation_periodic_keyframe: bool,
    datagram_bytes: DatagramBytes,
    maximum_datagram_payload: usize,
    wire_budget_kbps: u32,
    maximum_object_delay_us: u32,
    refresh_millihz: u32,
    object_age_us: ObjectAge,
) -> Result<VideoDatagramPacing, VideoDatagramDeadlineError>
where
    DatagramBytes: IntoIterator<Item = usize>,
    ObjectAge: FnOnce() -> u64,
{
    let delta_deadline_us = u64::from(maximum_object_delay_us);
    if !same_generation_periodic_keyframe {
        return Ok(VideoDatagramPacing {
            deadline_us: delta_deadline_us,
            required_wire_kbps: None,
        });
    }
    if wire_budget_kbps == 0 {
        return Err(VideoDatagramDeadlineError::InvalidWireBudget);
    }
    let cap_us = periodic_keyframe_deadline_cap_us(refresh_millihz)?;

    let total_bytes = datagram_bytes.into_iter().try_fold(0_u64, |total, bytes| {
        total
            .checked_add(
                u64::try_from(bytes).map_err(|_| VideoDatagramDeadlineError::ArithmeticOverflow)?,
            )
            .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)
    })?;
    let burst_bytes = u64::try_from(maximum_datagram_payload)
        .map_err(|_| VideoDatagramDeadlineError::ArithmeticOverflow)?
        .checked_mul(
            u64::try_from(MAXIMUM_VIDEO_WIRE_BURST_DATAGRAMS)
                .map_err(|_| VideoDatagramDeadlineError::ArithmeticOverflow)?,
        )
        .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)?;
    let paced_bits = total_bytes
        .saturating_sub(burst_bytes)
        .checked_mul(8)
        .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)?;
    let paced_microseconds = paced_bits
        .checked_mul(1_000)
        .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)?
        .div_ceil(u64::from(wire_budget_kbps));
    let required_us = paced_microseconds
        .checked_add(PERIODIC_KEYFRAME_SCHEDULING_MARGIN_US)
        .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)?
        .checked_add(object_age_us())
        .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)?
        .max(delta_deadline_us);
    if required_us <= cap_us {
        return Ok(VideoDatagramPacing {
            deadline_us: required_us,
            required_wire_kbps: None,
        });
    }

    let required_wire_kbps = required_wire_kbps_for_paced_window(
        paced_bits,
        cap_us,
        object_age_us_already_charged(required_us, paced_microseconds),
    )?;
    Ok(VideoDatagramPacing {
        deadline_us: required_us,
        required_wire_kbps: Some(required_wire_kbps),
    })
}

/// Window microseconds consumed by everything other than wire serialization.
fn object_age_us_already_charged(required_us: u64, paced_microseconds: u64) -> u64 {
    required_us.saturating_sub(paced_microseconds)
}

/// Smallest wire budget that serializes `paced_bits` in the remaining window.
fn required_wire_kbps_for_paced_window(
    paced_bits: u64,
    cap_us: u64,
    fixed_overhead_us: u64,
) -> Result<u32, VideoDatagramDeadlineError> {
    let serialization_budget_us = cap_us.saturating_sub(fixed_overhead_us).max(1);
    let required_kbps = paced_bits
        .checked_mul(1_000)
        .ok_or(VideoDatagramDeadlineError::ArithmeticOverflow)?
        .div_ceil(serialization_budget_us)
        .max(1);
    Ok(u32::try_from(required_kbps).unwrap_or(u32::MAX))
}

fn periodic_keyframe_drop_requires_wire_pressure(
    same_generation_periodic_keyframe: bool,
    status: &DatagramBatchStatus,
) -> bool {
    same_generation_periodic_keyframe
        && matches!(
            status,
            DatagramBatchStatus::Dropped(
                DatagramBatchDropReason::QueueBarrier
                    | DatagramBatchDropReason::Send
                    | DatagramBatchDropReason::WireRate
            )
        )
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
    if bootstrap.reason == NativeVideoBootstrapReason::Periodic
        && !platform_requires_acknowledgement
    {
        VideoKeyframeDelivery::SameGenerationDatagram
    } else {
        VideoKeyframeDelivery::ReliableBootstrap(bootstrap)
    }
}

impl VideoSenderState {
    /// Keeps the highest requirement so a small keyframe cannot lower the floor.
    fn record_keyframe_wire_rate_requirement(&mut self, required_wire_kbps: u32) {
        self.keyframe_wire_rate_requirement_kbps = Some(
            self.keyframe_wire_rate_requirement_kbps
                .map_or(required_wire_kbps, |current| {
                    current.max(required_wire_kbps)
                }),
        );
    }

    /// A drop proves the requirement exceeds the current budget.
    fn escalate_keyframe_wire_rate_requirement(&mut self, current_wire_budget_kbps: u32) {
        let escalated = current_wire_budget_kbps
            .saturating_mul(125)
            .div_ceil(100)
            .max(current_wire_budget_kbps.saturating_add(1));
        self.record_keyframe_wire_rate_requirement(escalated);
    }

    fn take_keyframe_wire_rate_requirement(&mut self) -> Option<u32> {
        self.keyframe_wire_rate_requirement_kbps.take()
    }

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

#[derive(Debug, Eq, PartialEq)]
enum VideoDatagramCompletion {
    Continue { request_repair: bool },
    TerminalTransport(String),
}

fn finish_video_datagram_delivery(
    sender: &mut VideoSenderState,
    frame_id: u32,
    status: &DatagramBatchStatus,
    bootstrap_pending: bool,
) -> Result<VideoDatagramCompletion, String> {
    if let DatagramBatchStatus::Terminal(message) = status {
        return Ok(VideoDatagramCompletion::TerminalTransport(message.clone()));
    }
    let request_repair = sender.finish_delta_delivery(
        frame_id,
        *status != DatagramBatchStatus::Complete,
        bootstrap_pending,
    )?;
    Ok(VideoDatagramCompletion::Continue { request_repair })
}

#[allow(clippy::too_many_arguments)]
async fn poll_and_send_video(
    connection: &quinn::Connection,
    session_epoch: u32,
    router: &SharedControlRouter,
    platform: &Arc<dyn PlatformSessionControl>,
    sender: &mut VideoSenderState,
    packet_arrival: &PacketArrivalSendObservation,
    wire_pacer: &Arc<tokio::sync::Mutex<VideoWireRatePacer>>,
    admission_gate: &tokio::sync::Mutex<()>,
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
        let repair = router.lock().map_err(|_| {
            video_capture_failure(
                "post-bootstrap-keyframe-request-failed",
                "native control router lock is poisoned".to_owned(),
            )
        });
        let repair = match repair {
            Ok(mut router) => router.request_native_video_repair(
                delivery.session_epoch,
                NativeVideoRepairSource::PostBootstrapDrain,
            ),
            Err(failure) => return MediaAttempt::Terminal(failure),
        };
        if let Err(message) = repair {
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
        let repair = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())
            .and_then(|mut router| {
                router.request_native_video_repair(
                    delivery.session_epoch,
                    NativeVideoRepairSource::StaleDelta,
                )
            });
        if let Err(message) = repair {
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
    let mut same_generation_periodic_keyframe = false;
    if normalized.frame.key_frame {
        let delivery_kind = classify_video_keyframe_delivery(
            normalized.new_configuration.is_some(),
            delivery.acknowledged_generation_id.is_some(),
            normalized.frame.repair_keyframe,
            normalized.frame.requires_bootstrap_acknowledgement,
        );
        match delivery_kind {
            VideoKeyframeDelivery::SameGenerationDatagram => {
                same_generation_periodic_keyframe = true;
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
    let pacing = match video_datagram_deadline_us(
        same_generation_periodic_keyframe,
        packetized.datagrams.iter().map(Vec::len),
        delivery.maximum_datagram_payload,
        delivery.wire_budget_kbps,
        delivery.maximum_object_delay_us,
        delivery.refresh_millihz,
        || duration_to_microseconds(pending_since.elapsed()),
    ) {
        Ok(pacing) => pacing,
        Err(VideoDatagramDeadlineError::InvalidWireBudget) => {
            return MediaAttempt::Failed(video_failure(
                "packetizer-failed",
                "video wire budget is zero".to_owned(),
            ))
        }
        Err(VideoDatagramDeadlineError::InvalidRefreshCadence) => {
            return MediaAttempt::Failed(video_failure(
                "packetizer-failed",
                "video refresh cadence is zero".to_owned(),
            ))
        }
        Err(VideoDatagramDeadlineError::ArithmeticOverflow) => {
            return MediaAttempt::Failed(video_failure(
                "packetizer-failed",
                "video object deadline arithmetic overflowed".to_owned(),
            ))
        }
    };
    let deadline_us = pacing.deadline_us;
    if let Some(required_wire_kbps) = pacing.required_wire_kbps {
        sender.record_keyframe_wire_rate_requirement(required_wire_kbps);
    }
    let Some(deadline) = pending_since.checked_add(Duration::from_micros(deadline_us)) else {
        return MediaAttempt::Failed(video_failure(
            "packetizer-failed",
            "video object deadline overflowed".to_owned(),
        ));
    };
    let report = send_wire_paced_video_datagram_batch(
        packetized.datagrams,
        NATIVE_MEDIA_SEND_BUFFER_BYTES,
        NATIVE_AUDIO_EGRESS_RESERVE_BYTES,
        deadline,
        admission_gate,
        wire_pacer,
        delivery.session_epoch,
        delivery.wire_budget_kbps,
        delivery.maximum_datagram_payload,
        |required_capacity, deadline| {
            wait_for_connection_datagram_queue_capacity(connection, required_capacity, deadline)
        },
        || connection.datagram_send_buffer_space(),
        |mode, datagram, deadline| {
            send_tracked_connection_datagram(connection, packet_arrival, mode, datagram, deadline)
        },
    )
    .await;
    let delivery_complete = report.status == DatagramBatchStatus::Complete;
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
            deadline_us,
        );
    }
    if periodic_keyframe_drop_requires_wire_pressure(
        same_generation_periodic_keyframe,
        &report.status,
    ) {
        sender.escalate_keyframe_wire_rate_requirement(delivery.wire_budget_kbps);
    }
    if let Some(required_wire_kbps) = sender.take_keyframe_wire_rate_requirement() {
        let request = router.lock().ok().and_then(|mut router| {
            match router.require_native_video_keyframe_wire_rate(
                delivery.session_epoch,
                required_wire_kbps,
            ) {
                Ok(request) => Some(request),
                Err(message) => {
                    eprintln!(
                        "Lumen native media stage=keyframe-wire-rate-rejected session-epoch={} required-kbps={required_wire_kbps} error={message}",
                        delivery.session_epoch
                    );
                    None
                }
            }
        });
        if let Some(request) = request {
            if matches!(&request, NativeAdaptiveVideoPolicyRequest::Applied(_)) {
                eprintln!(
                    "Lumen native media stage=keyframe-wire-rate-reserved session-epoch={} required-kbps={required_wire_kbps} frame-id={frame_id}",
                    delivery.session_epoch
                );
                let policy_router = Arc::clone(router);
                let policy_platform = Arc::clone(platform);
                let policy_session_epoch = delivery.session_epoch;
                tokio::spawn(async move {
                    if let Err(error) = apply_adaptive_video_policy_request(
                        &policy_router,
                        policy_platform,
                        policy_session_epoch,
                        request,
                    )
                    .await
                    {
                        eprintln!(
                            "Lumen native media stage=keyframe-wire-rate-apply-failed session-epoch={policy_session_epoch} error={error}"
                        );
                    }
                });
            }
        }
    }
    let request_repair = match finish_video_datagram_delivery(
        sender,
        frame_id,
        &report.status,
        delivery.bootstrap_pending,
    ) {
        Ok(VideoDatagramCompletion::Continue { request_repair }) => request_repair,
        Ok(VideoDatagramCompletion::TerminalTransport(message)) => {
            return MediaAttempt::Terminal(video_failure(
                "quic-datagram-connection-failed",
                format!("{message}; frame-id={frame_id}"),
            ));
        }
        Err(message) => return MediaAttempt::Failed(video_failure("packetizer-failed", message)),
    };
    if request_repair {
        let repair = router
            .lock()
            .map_err(|_| "native control router lock is poisoned".to_owned())
            .and_then(|mut router| {
                router.request_native_video_repair(
                    delivery.session_epoch,
                    NativeVideoRepairSource::IncompleteTransport,
                )
            });
        if let Err(message) = repair {
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
        DatagramBatchStatus::Terminal(message) => MediaAttempt::Terminal(video_failure(
            "quic-datagram-connection-failed",
            format!("{message}; frame-id={frame_id}"),
        )),
    }
}

fn video_failure(stage: &'static str, message: String) -> MediaFailure {
    MediaFailure {
        code: if matches!(
            stage,
            "quic-datagram-send-failed" | "quic-datagram-connection-failed"
        ) {
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

fn timestamp_to_microseconds(timestamp: u64, clock_rate: u64) -> u32 {
    ((u128::from(timestamp) * 1_000_000) / u128::from(clock_rate)) as u32
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
        DatagramBatchStatus::Terminal(error) => (
            "datagram-batch-terminal",
            "connection-failed",
            error.as_str(),
        ),
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
    use super::super::packet_arrival::{
        PacketArrivalFeedbackError, PacketArrivalHistory, PacketIdentity,
    };
    use super::{
        classify_video_keyframe_delivery, delivery_for_session, finish_video_datagram_delivery,
        four_refresh_frame_wire_window_us, object_deadline_exceeded,
        periodic_keyframe_deadline_cap_us, periodic_keyframe_drop_requires_wire_pressure,
        record_successful_datagram, run_native_media_tasks, send_admitted_datagram,
        send_datagram_batch, send_video_datagram_batch, send_wire_paced_video_datagram_batch,
        video_datagram_deadline_us, wait_for_datagram_deadline, wait_for_datagram_queue_capacity,
        DatagramBatchDropReason, DatagramBatchMode, DatagramBatchStatus, DatagramDeadlineElapsed,
        DatagramSendOutcome, PacketArrivalHistoryWarningReporter, PacketArrivalSendObservation,
        SessionDelivery, VideoBootstrapClassification, VideoDatagramCompletion,
        VideoDatagramDeadlineError, VideoDatagramPacing, VideoKeyframeDelivery, VideoSenderState,
        VideoWireRatePacer, MAXIMUM_VIDEO_WIRE_BURST_DATAGRAMS,
    };
    use lumen_engine::{
        native_video_packetization_plan, MediaFeedback, NativeVideoBootstrapReason,
    };
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::future::Future;
    use std::pin::Pin;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::sync::Mutex;
    use std::task::{Context, Poll};
    use std::time::{Duration, Instant};
    use tokio::sync::Notify;

    #[derive(Default)]
    struct RuntimeEventPlatform {
        events: Mutex<Vec<crate::PlatformRuntimeEvent>>,
    }

    impl crate::PlatformSessionControl for RuntimeEventPlatform {
        fn start_session(&self, _: crate::PlatformSessionPlan) -> Result<(), String> {
            Ok(())
        }

        fn stop_session(&self) -> Result<(), String> {
            Ok(())
        }

        fn publish_runtime_event(&self, event: crate::PlatformRuntimeEvent) -> Result<(), String> {
            self.events.lock().unwrap().push(event);
            Ok(())
        }
    }

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
    fn periodic_keyframe_deadline_uses_actual_wire_bytes_and_configured_burst() {
        let datagram_bytes = vec![1_170; 235];

        assert_eq!(
            video_datagram_deadline_us(
                true,
                datagram_bytes.iter().copied(),
                1_170,
                66_269,
                16_668,
                60_000,
                || 0,
            ),
            Ok(VideoDatagramPacing {
                deadline_us: 37_910,
                required_wire_kbps: None,
            })
        );
        let visited_delta_bytes = Cell::new(0);
        let read_delta_age = Cell::new(false);
        assert_eq!(
            video_datagram_deadline_us(
                false,
                datagram_bytes.iter().map(|bytes| {
                    visited_delta_bytes.set(visited_delta_bytes.get() + 1);
                    *bytes
                }),
                1_170,
                66_269,
                16_668,
                0,
                || {
                    read_delta_age.set(true);
                    u64::MAX
                },
            ),
            Ok(VideoDatagramPacing {
                deadline_us: 16_668,
                required_wire_kbps: None,
            })
        );
        assert_eq!(visited_delta_bytes.get(), 0);
        assert!(!read_delta_age.get());
    }

    #[test]
    fn sixty_hertz_periodic_keyframe_deadline_admits_observed_wire_size() {
        let origin = Instant::now();
        let datagram_bytes = vec![1_170; 235];
        let deadline_us = video_datagram_deadline_us(
            true,
            datagram_bytes.iter().copied(),
            1_170,
            66_269,
            16_668,
            60_000,
            || 0,
        )
        .expect("observed periodic keyframe fits a sixty-hertz four-frame deadline")
        .deadline_us;
        let mut pacer = VideoWireRatePacer::default();
        pacer.prepare(42, 66_269).unwrap();

        let schedule = pacer
            .reserve(
                &datagram_bytes,
                1_170,
                origin,
                origin + Duration::from_micros(deadline_us),
            )
            .expect("extended periodic deadline admits the complete object");

        assert_eq!(schedule.len(), datagram_bytes.len());
        assert!(schedule.last().copied().unwrap() <= origin + Duration::from_micros(37_910));
        assert_eq!(pacer.session_epoch, Some(42));
    }

    #[test]
    fn one_hundred_twenty_hertz_periodic_keyframe_uses_external_scheduler_margin() {
        let datagram_bytes = vec![1_170; 235];

        assert_eq!(
            video_datagram_deadline_us(
                true,
                datagram_bytes.iter().copied(),
                1_170,
                66_269,
                16_668,
                120_000,
                || 0,
            ),
            Ok(VideoDatagramPacing {
                deadline_us: 37_910,
                required_wire_kbps: None,
            })
        );
    }

    #[test]
    fn periodic_keyframe_cap_places_scheduler_margin_outside_four_frame_wire_window() {
        assert_eq!(four_refresh_frame_wire_window_us(60_000), Ok(66_667));
        assert_eq!(four_refresh_frame_wire_window_us(120_000), Ok(33_334));
        assert_eq!(periodic_keyframe_deadline_cap_us(60_000), Ok(71_667));
        assert_eq!(periodic_keyframe_deadline_cap_us(120_000), Ok(38_334));
        assert_eq!(
            periodic_keyframe_deadline_cap_us(0),
            Err(VideoDatagramDeadlineError::InvalidRefreshCadence)
        );
    }

    #[test]
    fn periodic_keyframe_deadline_admits_cap_equality_and_requires_rate_beyond_it() {
        assert_eq!(
            video_datagram_deadline_us(
                true,
                std::iter::empty(),
                1_170,
                66_269,
                16_668,
                120_000,
                || 33_334,
            ),
            Ok(VideoDatagramPacing {
                deadline_us: 38_334,
                required_wire_kbps: None,
            })
        );
        let beyond_cap = video_datagram_deadline_us(
            true,
            std::iter::empty(),
            1_170,
            66_269,
            16_668,
            120_000,
            || 33_335,
        )
        .expect("exceeding the latency window is never a transport failure");
        assert_eq!(beyond_cap.deadline_us, 38_335);
        // Pure fixed overhead: no finite rate shrinks it, so the floor stays at 1.
        assert_eq!(beyond_cap.required_wire_kbps, Some(1));
    }

    #[test]
    fn periodic_keyframe_deadline_charges_age_and_mixed_datagram_lengths() {
        assert_eq!(
            video_datagram_deadline_us(
                true,
                [1_170, 585, 1_170],
                1_170,
                66_269,
                1_000,
                60_000,
                || 100,
            ),
            Ok(VideoDatagramPacing {
                deadline_us: 5_171,
                required_wire_kbps: None,
            })
        );
    }

    #[test]
    fn non_empty_pacer_wire_rejection_raises_rate_instead_of_failing() {
        let origin = Instant::now();
        let mut pacer = VideoWireRatePacer::default();
        pacer.prepare(42, 66_269).unwrap();
        pacer
            .reserve(
                &vec![1_170; 200],
                1_170,
                origin,
                origin + Duration::from_secs(1),
            )
            .expect("prior object reserves the non-empty pacer");
        let periodic_deadline_us = video_datagram_deadline_us(
            true,
            std::iter::repeat_n(1_170, 50),
            1_170,
            66_269,
            16_668,
            120_000,
            || 0,
        )
        .expect("periodic object fits an otherwise empty pacer")
        .deadline_us;
        let periodic_schedule = pacer.reserve(
            &vec![1_170; 50],
            1_170,
            origin,
            origin + Duration::from_micros(periodic_deadline_us),
        );
        assert!(periodic_schedule.is_none());

        let status = DatagramBatchStatus::Dropped(DatagramBatchDropReason::WireRate);
        assert!(periodic_keyframe_drop_requires_wire_pressure(true, &status));
        let mut sender = VideoSenderState::default();
        sender.escalate_keyframe_wire_rate_requirement(66_269);
        assert_eq!(
            sender.take_keyframe_wire_rate_requirement(),
            Some(82_837),
            "a dropped keyframe escalates strictly above the budget that failed"
        );
        assert_eq!(sender.take_keyframe_wire_rate_requirement(), None);
        assert!(!sender.repair_required);
        assert_eq!(sender.frame_id, 0);
    }

    #[test]
    fn periodic_deadline_drops_request_wire_pressure_without_failing() {
        for reason in [
            DatagramBatchDropReason::QueueBarrier,
            DatagramBatchDropReason::Send,
            DatagramBatchDropReason::WireRate,
        ] {
            let status = DatagramBatchStatus::Dropped(reason);
            assert!(periodic_keyframe_drop_requires_wire_pressure(true, &status));
            assert!(!periodic_keyframe_drop_requires_wire_pressure(
                false, &status
            ));
        }

        for status in [
            DatagramBatchStatus::Complete,
            DatagramBatchStatus::Failed("send failed".to_owned()),
            DatagramBatchStatus::Terminal("connection failed".to_owned()),
        ] {
            assert!(!periodic_keyframe_drop_requires_wire_pressure(
                true, &status
            ));
        }
    }

    /// Regression: a 39296 us keyframe against a 38334 us window terminated the
    /// live session at 3600-class resolution.
    #[test]
    fn oversized_periodic_keyframe_requests_more_wire_rate_instead_of_failing() {
        let starving_budget_kbps = 66_269_u32;
        let datagram_bytes = vec![1_170_usize; 340];

        let pacing = video_datagram_deadline_us(
            true,
            datagram_bytes.iter().copied(),
            1_170,
            starving_budget_kbps,
            16_668,
            120_000,
            || 0,
        )
        .expect("an oversized periodic keyframe is never a transport failure");

        let cap_us = periodic_keyframe_deadline_cap_us(120_000)
            .expect("120 Hz cadence yields a bounded window");
        assert!(
            pacing.deadline_us > cap_us,
            "this fixture must actually exceed the latency window"
        );
        let required_wire_kbps = pacing
            .required_wire_kbps
            .expect("exceeding the window must publish a required wire rate");
        assert!(
            required_wire_kbps > starving_budget_kbps,
            "the requirement must exceed the budget that could not serialize the keyframe"
        );

        let repaced = video_datagram_deadline_us(
            true,
            datagram_bytes.iter().copied(),
            1_170,
            required_wire_kbps,
            16_668,
            120_000,
            || 0,
        )
        .expect("re-pacing at the required rate stays admissible");
        assert!(
            repaced.deadline_us <= cap_us,
            "the required rate must bring the keyframe inside the window"
        );
        assert_eq!(
            repaced.required_wire_kbps, None,
            "a keyframe that fits must not keep escalating the budget"
        );
    }

    #[test]
    fn emitted_wire_pacer_accounts_exact_packetized_bytes_without_nominal_fec_math() {
        let origin = Instant::now();
        let deadline = origin + Duration::from_secs(1);
        let mut pacer = VideoWireRatePacer::default();
        pacer.prepare(7, 1_200).unwrap();

        assert_eq!(
            pacer.reserve(&[1_200, 1_200], 1_200, origin, deadline),
            Some(vec![origin, origin])
        );
        assert_eq!(
            pacer.reserve(&[1_200, 1_200, 1_200], 1_200, origin, deadline),
            Some(vec![
                origin + Duration::from_millis(8),
                origin + Duration::from_millis(16),
                origin + Duration::from_millis(24),
            ])
        );
        assert_eq!(pacer.next_send_at, Some(origin + Duration::from_millis(24)));
    }

    #[test]
    fn variable_frame_sizes_never_exceed_the_actual_byte_token_envelope() {
        const MTU: usize = 1_200;
        const WIRE_KBPS: u32 = 25_536;
        let origin = Instant::now();
        let deadline = origin + Duration::from_secs(5);
        let mut pacer = VideoWireRatePacer::default();
        pacer.prepare(9, WIRE_KBPS).unwrap();
        let mut cumulative_bytes = 0_u64;

        for payload_bytes in [1, 37_504, 37_505, 200_070, 7_777, 291_330] {
            let plan = native_video_packetization_plan(payload_bytes, MTU, 30).unwrap();
            let datagrams = vec![MTU; plan.total_shards];
            let send_times = pacer
                .reserve(&datagrams, MTU, origin, deadline)
                .expect("five-second envelope admits the adversarial sequence");
            for send_at in send_times {
                cumulative_bytes += MTU as u64;
                let elapsed_nanoseconds = send_at.duration_since(origin).as_nanos();
                let envelope_bits = u128::try_from(MTU * MAXIMUM_VIDEO_WIRE_BURST_DATAGRAMS * 8)
                    .unwrap()
                    .saturating_add(
                        u128::from(WIRE_KBPS).saturating_mul(elapsed_nanoseconds) / 1_000_000,
                    );
                assert!(u128::from(cumulative_bytes) * 8 <= envelope_bits);
            }
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn post_barrier_wire_reservation_drops_the_whole_object_before_first_send() {
        let pacer = Arc::new(tokio::sync::Mutex::new(VideoWireRatePacer::default()));
        let admission_gate = tokio::sync::Mutex::new(());
        let sent = Rc::new(Cell::new(0_usize));
        let sent_by_transport = Rc::clone(&sent);
        let deadline = Instant::now() + Duration::from_millis(40);

        let report = send_wire_paced_video_datagram_batch(
            vec![vec![0; 1_200]; 6],
            16 * 1_200,
            0,
            deadline,
            &admission_gate,
            &pacer,
            7,
            1_200,
            1_200,
            |_, _| async {
                tokio::time::sleep(Duration::from_millis(25)).await;
                Ok(Duration::from_millis(25))
            },
            || 16 * 1_200,
            move |_, _, _| {
                sent_by_transport.set(sent_by_transport.get() + 1);
                async { DatagramSendOutcome::Sent }
            },
        )
        .await;

        assert_eq!(
            report.status,
            DatagramBatchStatus::Dropped(DatagramBatchDropReason::WireRate)
        );
        assert_eq!(report.sent_datagrams, 0);
        assert_eq!(sent.get(), 0);
        assert_eq!(pacer.lock().await.next_send_at, None);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn committed_wire_object_drains_after_post_first_capacity_delay() {
        let pacer = Arc::new(tokio::sync::Mutex::new(VideoWireRatePacer::default()));
        let admission_gate = tokio::sync::Mutex::new(());
        let sent = Rc::new(Cell::new(0_usize));
        let sent_by_transport = Rc::clone(&sent);
        let deadline = Instant::now() + Duration::from_millis(30);

        let report = send_wire_paced_video_datagram_batch(
            vec![vec![0; 1_200]; 3],
            16 * 1_200,
            0,
            deadline,
            &admission_gate,
            &pacer,
            7,
            48_000,
            1_200,
            |_, _| async { Ok(Duration::ZERO) },
            || 16 * 1_200,
            move |mode, _, send_deadline| {
                let index = sent_by_transport.get();
                sent_by_transport.set(index + 1);
                async move {
                    if index == 0 {
                        assert_eq!(mode, DatagramBatchMode::FreshEnqueue);
                        assert_eq!(send_deadline, Some(deadline));
                    } else {
                        assert_eq!(mode, DatagramBatchMode::CommittedDrain);
                        assert_eq!(send_deadline, None);
                    }
                    if index == 1 {
                        tokio::time::sleep(Duration::from_millis(45)).await;
                    }
                    DatagramSendOutcome::Sent
                }
            },
        )
        .await;

        assert_eq!(report.status, DatagramBatchStatus::Complete);
        assert_eq!(report.sent_datagrams, 3);
        assert_eq!(sent.get(), 3);
        assert!(Instant::now() > deadline);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn fatal_committed_drain_bypasses_repair_and_is_terminal() {
        let pacer = Arc::new(tokio::sync::Mutex::new(VideoWireRatePacer::default()));
        let admission_gate = tokio::sync::Mutex::new(());
        let send_attempts = Rc::new(Cell::new(0_usize));
        let transport_attempts = Rc::clone(&send_attempts);
        let deadline = Instant::now() + Duration::from_millis(100);

        let report = send_wire_paced_video_datagram_batch(
            vec![vec![0; 1_200]; 3],
            16 * 1_200,
            0,
            deadline,
            &admission_gate,
            &pacer,
            7,
            48_000,
            1_200,
            |_, _| async { Ok(Duration::ZERO) },
            || 16 * 1_200,
            move |mode, _, _| {
                let index = transport_attempts.get();
                transport_attempts.set(index + 1);
                async move {
                    if index == 0 {
                        assert_eq!(mode, DatagramBatchMode::FreshEnqueue);
                        DatagramSendOutcome::Sent
                    } else {
                        assert_eq!(mode, DatagramBatchMode::CommittedDrain);
                        DatagramSendOutcome::Failed("connection lost".to_owned())
                    }
                }
            },
        )
        .await;

        assert_eq!(
            report.status,
            DatagramBatchStatus::Terminal("connection lost".to_owned())
        );
        assert_eq!(report.sent_datagrams, 1);
        assert_eq!(send_attempts.get(), 2);

        let mut sender = VideoSenderState::default();
        let initial_frame_id = sender.frame_id;
        let completion = finish_video_datagram_delivery(&mut sender, 41, &report.status, false)
            .expect("terminal transport classification");
        assert_eq!(
            completion,
            VideoDatagramCompletion::TerminalTransport("connection lost".to_owned())
        );
        assert!(!sender.repair_required);
        assert_eq!(sender.frame_id, initial_frame_id);
    }

    #[test]
    fn periodic_keyframes_stay_in_generation_while_lifecycle_keyframes_remain_bootstraps() {
        assert_eq!(
            classify_video_keyframe_delivery(false, true, false, false),
            VideoKeyframeDelivery::SameGenerationDatagram
        );
        assert_eq!(
            classify_video_keyframe_delivery(false, true, false, true),
            VideoKeyframeDelivery::ReliableBootstrap(VideoBootstrapClassification {
                reason: NativeVideoBootstrapReason::Periodic,
                requires_encoder_resume: true,
            })
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
    async fn prior_video_allows_the_next_complete_object_when_capacity_is_available() {
        let required = Rc::new(Cell::new(0));
        let requested_capacity = Rc::clone(&required);
        let report = send_video_datagram_batch(
            vec![vec![1; 4], vec![2; 4]],
            12,
            0,
            Instant::now() + Duration::from_secs(1),
            move |required_capacity, deadline| {
                requested_capacity.set(required_capacity);
                async move {
                    wait_for_datagram_queue_capacity(
                        12,
                        required_capacity,
                        deadline,
                        || 8,
                        |_| async { panic!("the complete video object already fits") },
                    )
                    .await
                }
            },
            |_, _, _| async { DatagramSendOutcome::Sent },
        )
        .await;

        assert_eq!(required.get(), 8);
        assert_eq!(report.status, DatagramBatchStatus::Complete);
        assert_eq!(report.sent_datagrams, 2);
    }

    #[tokio::test]
    async fn capacity_check_and_first_enqueue_share_one_admission_gate() {
        let admission_gate = tokio::sync::Mutex::new(());
        let capacity_checked = Rc::new(Cell::new(false));
        let checked = Rc::clone(&capacity_checked);
        let sent = Rc::clone(&capacity_checked);
        let deadline = Instant::now() + Duration::from_secs(1);

        let (_, outcome) = send_admitted_datagram(
            &admission_gate,
            12,
            8,
            deadline,
            DatagramBatchMode::FreshEnqueue,
            vec![1; 4],
            &mut || {
                assert!(admission_gate.try_lock().is_err());
                checked.set(true);
                8
            },
            &mut |mode, _, send_deadline| {
                assert!(admission_gate.try_lock().is_err());
                assert!(sent.get());
                async move {
                    assert_eq!(mode, DatagramBatchMode::FreshEnqueue);
                    assert_eq!(send_deadline, Some(deadline));
                    DatagramSendOutcome::Sent
                }
            },
        )
        .await
        .expect("capacity admission succeeds");

        assert!(matches!(outcome, DatagramSendOutcome::Sent));
        assert!(admission_gate.try_lock().is_ok());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn final_admission_failure_drops_the_whole_object_before_first_send() {
        let admission_gate = tokio::sync::Mutex::new(());
        let pacer = Arc::new(tokio::sync::Mutex::new(VideoWireRatePacer::default()));
        let sent = Rc::new(Cell::new(0_usize));
        let sent_by_transport = Rc::clone(&sent);
        let deadline = Instant::now() + Duration::from_millis(20);

        let report = send_wire_paced_video_datagram_batch(
            vec![vec![1; 4], vec![2; 4]],
            12,
            0,
            deadline,
            &admission_gate,
            &pacer,
            7,
            48_000,
            4,
            |required_capacity, _| {
                assert_eq!(required_capacity, 8);
                async { Ok(Duration::ZERO) }
            },
            || 4,
            move |_, _, _| {
                sent_by_transport.set(sent_by_transport.get() + 1);
                async { DatagramSendOutcome::Sent }
            },
        )
        .await;

        assert_eq!(
            report.status,
            DatagramBatchStatus::Dropped(DatagramBatchDropReason::QueueBarrier)
        );
        assert_eq!(report.sent_datagrams, 0);
        assert_eq!(sent.get(), 0);
        assert_eq!(pacer.lock().await.next_send_at, None);
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
            DatagramBatchStatus::Dropped(DatagramBatchDropReason::QueueBarrier)
        );
        assert_eq!(blocked.sent_datagrams, 0);
        assert!(sent.borrow().is_empty());

        let recovered_log = Rc::clone(&sent);
        let fresh = send_video_datagram_batch(
            vec![vec![2; 4], vec![2; 4]],
            8,
            0,
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
            DatagramBatchStatus::Dropped(DatagramBatchDropReason::Send)
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

    #[tokio::test]
    async fn sender_history_records_only_successful_datagram_admission() {
        let history = PacketArrivalHistory::spawn();
        history.set_enabled(true);
        let warning_reporter =
            PacketArrivalHistoryWarningReporter::spawn(Arc::new(RuntimeEventPlatform::default()));
        let packet_arrival = PacketArrivalSendObservation {
            history: history.clone(),
            warning_reporter,
        };
        let dropped = PacketIdentity {
            stream_id: 1,
            datagram_sequence: 30,
        };
        let sent = PacketIdentity {
            stream_id: 1,
            datagram_sequence: 31,
        };
        record_successful_datagram(
            &packet_arrival,
            Some(dropped),
            &DatagramSendOutcome::DeadlineExceeded,
        );
        record_successful_datagram(&packet_arrival, Some(sent), &DatagramSendOutcome::Sent);

        let mut sent_run = Vec::from(31_u32.to_be_bytes());
        sent_run.extend_from_slice(&1_u64.to_be_bytes());
        sent_run.push(0);
        let accepted = history
            .observe(&MediaFeedback {
                stream_id: 1,
                first_datagram_sequence: 31,
                highest_datagram_sequence: 31,
                received_datagrams: 1,
                window_milliseconds: 250,
                packet_arrival_reference_time_us: 1_000,
                packet_arrival_runs: sent_run,
                ..MediaFeedback::default()
            })
            .await;
        assert!(accepted.is_ok());

        let mut dropped_run = Vec::from(30_u32.to_be_bytes());
        dropped_run.extend_from_slice(&1_u64.to_be_bytes());
        dropped_run.push(0);
        assert_eq!(
            history
                .observe(&MediaFeedback {
                    stream_id: 1,
                    first_datagram_sequence: 30,
                    highest_datagram_sequence: 30,
                    received_datagrams: 1,
                    window_milliseconds: 250,
                    packet_arrival_reference_time_us: 1_000,
                    packet_arrival_runs: dropped_run,
                    ..MediaFeedback::default()
                })
                .await,
            Err(PacketArrivalFeedbackError::UntrackedDatagram)
        );
    }

    #[tokio::test]
    async fn unavailable_packet_arrival_history_publishes_one_bounded_typed_warning() {
        let history = PacketArrivalHistory::unavailable();
        let platform = Arc::new(RuntimeEventPlatform::default());
        let warning_reporter = PacketArrivalHistoryWarningReporter::spawn(platform.clone());
        let packet_arrival = PacketArrivalSendObservation {
            history,
            warning_reporter: warning_reporter.clone(),
        };
        let identity = PacketIdentity {
            stream_id: 1,
            datagram_sequence: 31,
        };

        record_successful_datagram(&packet_arrival, Some(identity), &DatagramSendOutcome::Sent);
        record_successful_datagram(&packet_arrival, Some(identity), &DatagramSendOutcome::Sent);
        warning_reporter.flush().await;

        assert_eq!(
            *platform.events.lock().unwrap(),
            vec![crate::PlatformRuntimeEvent {
                disposition: crate::PlatformRuntimeEventDisposition::Raised,
                severity: crate::PlatformRuntimeEventSeverity::Warning,
                code: crate::PlatformRuntimeEventCode::NativePacketArrivalFeedback,
                message: Some("packet-arrival-history-unavailable".to_owned()),
            }]
        );

        warning_reporter.available();
        warning_reporter.flush().await;
        assert_eq!(
            platform.events.lock().unwrap().last(),
            Some(&crate::PlatformRuntimeEvent {
                disposition: crate::PlatformRuntimeEventDisposition::Cleared,
                severity: crate::PlatformRuntimeEventSeverity::Warning,
                code: crate::PlatformRuntimeEventCode::NativePacketArrivalFeedback,
                message: None,
            })
        );
        assert_eq!(platform.events.lock().unwrap().len(), 2);
    }
}
