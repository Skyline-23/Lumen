use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use lumen_engine::MediaFeedback;
use tokio::sync::{mpsc, oneshot};

const RUN_PREFIX_BYTES: usize = 12;
const MAXIMUM_TRACKED_DATAGRAMS: usize = 65_536;
const MAXIMUM_COMMANDS: usize = MAXIMUM_TRACKED_DATAGRAMS;
const MAXIMUM_FEEDBACK_SEQUENCES: usize = 4_096;
const MAXIMUM_FEEDBACK_PAYLOAD_BYTES: usize = 16 * 1_024;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(super) struct PacketIdentity {
    pub(super) stream_id: u16,
    pub(super) datagram_sequence: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct PacketArrivalObservation {
    pub(super) received_datagrams: usize,
    pub(super) covered_sequences: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum PacketArrivalFeedbackError {
    Unsupported,
    MissingField,
    MalformedRun,
    ArrivalDeltaOverflow,
    CountMismatch,
    PayloadTooLarge,
    SequenceRangeMismatch,
    UntrackedDatagram,
    ActorUnavailable,
}

impl PacketArrivalFeedbackError {
    pub(super) const fn code(self) -> &'static str {
        match self {
            Self::Unsupported => "packet-arrival-unsupported",
            Self::MissingField => "packet-arrival-missing-field",
            Self::MalformedRun => "packet-arrival-malformed-run",
            Self::ArrivalDeltaOverflow => "packet-arrival-delta-overflow",
            Self::CountMismatch => "packet-arrival-count-mismatch",
            Self::PayloadTooLarge => "packet-arrival-payload-too-large",
            Self::SequenceRangeMismatch => "packet-arrival-sequence-range-mismatch",
            Self::UntrackedDatagram => "packet-arrival-untracked-datagram",
            Self::ActorUnavailable => "packet-arrival-history-unavailable",
        }
    }
}

#[derive(Clone)]
pub(super) struct PacketArrivalHistory {
    commands: mpsc::Sender<Command>,
    enabled: Arc<AtomicBool>,
}

enum Command {
    Record(PacketIdentity),
    Observe {
        feedback: MediaFeedback,
        response: oneshot::Sender<Result<PacketArrivalObservation, PacketArrivalFeedbackError>>,
    },
}

#[derive(Default)]
struct State {
    sent: HashSet<PacketIdentity>,
    insertion_order: VecDeque<PacketIdentity>,
}

impl PacketArrivalHistory {
    pub(super) fn spawn() -> Self {
        let (commands, mut receiver) = mpsc::channel(MAXIMUM_COMMANDS);
        tokio::spawn(async move {
            let mut state = State::default();
            while let Some(command) = receiver.recv().await {
                match command {
                    Command::Record(identity) => state.record(identity),
                    Command::Observe { feedback, response } => {
                        let _ = response.send(state.observe(&feedback));
                    }
                }
            }
        });
        Self {
            commands,
            enabled: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(super) fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Release);
    }

    #[cfg(test)]
    pub(super) fn unavailable() -> Self {
        let (commands, receiver) = mpsc::channel(1);
        drop(receiver);
        Self {
            commands,
            enabled: Arc::new(AtomicBool::new(true)),
        }
    }

    pub(super) async fn record_sent(
        &self,
        identity: PacketIdentity,
    ) -> Result<(), PacketArrivalFeedbackError> {
        if !self.enabled.load(Ordering::Acquire) {
            return Ok(());
        }
        self.commands
            .send(Command::Record(identity))
            .await
            .map_err(|_| PacketArrivalFeedbackError::ActorUnavailable)
    }

    pub(super) async fn observe(
        &self,
        feedback: &MediaFeedback,
    ) -> Result<PacketArrivalObservation, PacketArrivalFeedbackError> {
        if !self.enabled.load(Ordering::Acquire) {
            return Err(PacketArrivalFeedbackError::Unsupported);
        }
        let (response, receive) = oneshot::channel();
        self.commands
            .send(Command::Observe {
                feedback: feedback.clone(),
                response,
            })
            .await
            .map_err(|_| PacketArrivalFeedbackError::ActorUnavailable)?;
        receive
            .await
            .map_err(|_| PacketArrivalFeedbackError::ActorUnavailable)?
    }
}

impl State {
    fn record(&mut self, identity: PacketIdentity) {
        if self.sent.insert(identity) {
            self.insertion_order.push_back(identity);
        }
        while self.insertion_order.len() > MAXIMUM_TRACKED_DATAGRAMS {
            if let Some(expired) = self.insertion_order.pop_front() {
                self.sent.remove(&expired);
            }
        }
    }

    fn observe(
        &mut self,
        feedback: &MediaFeedback,
    ) -> Result<PacketArrivalObservation, PacketArrivalFeedbackError> {
        let runs = decode_runs(feedback)?;
        let stream_id = u16::try_from(feedback.stream_id)
            .map_err(|_| PacketArrivalFeedbackError::MalformedRun)?;
        let mut received = Vec::new();
        let mut covered = Vec::new();
        for run in runs {
            for offset in 0..=run.highest_offset {
                let sequence = run
                    .first_sequence
                    .checked_add(u32::from(offset))
                    .ok_or(PacketArrivalFeedbackError::MalformedRun)?;
                let identity = PacketIdentity {
                    stream_id,
                    datagram_sequence: sequence,
                };
                covered.push(identity);
                if run.bitmap & (1_u64 << offset) != 0 {
                    if !self.sent.contains(&identity) {
                        return Err(PacketArrivalFeedbackError::UntrackedDatagram);
                    }
                    received.push(identity);
                }
            }
        }
        if received.len() != feedback.received_datagrams as usize {
            return Err(PacketArrivalFeedbackError::CountMismatch);
        }
        for identity in &covered {
            self.sent.remove(identity);
        }
        Ok(PacketArrivalObservation {
            received_datagrams: received.len(),
            covered_sequences: covered.len(),
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DecodedRun {
    first_sequence: u32,
    bitmap: u64,
    highest_offset: u8,
}

fn decode_runs(feedback: &MediaFeedback) -> Result<Vec<DecodedRun>, PacketArrivalFeedbackError> {
    let has_reference = feedback.packet_arrival_reference_time_us != 0;
    let has_runs = !feedback.packet_arrival_runs.is_empty();
    if !has_reference && !has_runs {
        return Ok(Vec::new());
    }
    if !has_reference || !has_runs {
        return Err(PacketArrivalFeedbackError::MissingField);
    }
    let maximum_delta = u64::from(feedback.window_milliseconds).saturating_mul(1_000);
    let bytes = &feedback.packet_arrival_runs;
    if bytes.len() > MAXIMUM_FEEDBACK_PAYLOAD_BYTES
        || feedback.received_datagrams as usize > MAXIMUM_FEEDBACK_SEQUENCES
    {
        return Err(PacketArrivalFeedbackError::PayloadTooLarge);
    }
    let mut cursor = 0;
    let mut previous_last = None;
    let mut runs = Vec::new();
    let mut received_sequences = 0_usize;
    let mut covered_sequences = 0_usize;
    while cursor < bytes.len() {
        if bytes.len() - cursor < RUN_PREFIX_BYTES {
            return Err(PacketArrivalFeedbackError::MalformedRun);
        }
        let first_sequence = u32::from_be_bytes(
            bytes[cursor..cursor + 4]
                .try_into()
                .map_err(|_| PacketArrivalFeedbackError::MalformedRun)?,
        );
        let bitmap = u64::from_be_bytes(
            bytes[cursor + 4..cursor + 12]
                .try_into()
                .map_err(|_| PacketArrivalFeedbackError::MalformedRun)?,
        );
        cursor += RUN_PREFIX_BYTES;
        if bitmap == 0 {
            return Err(PacketArrivalFeedbackError::MalformedRun);
        }
        let highest_offset = (u64::BITS - 1 - bitmap.leading_zeros()) as u8;
        received_sequences = received_sequences
            .checked_add(bitmap.count_ones() as usize)
            .filter(|count| *count <= MAXIMUM_FEEDBACK_SEQUENCES)
            .ok_or(PacketArrivalFeedbackError::PayloadTooLarge)?;
        covered_sequences = covered_sequences
            .checked_add(usize::from(highest_offset) + 1)
            .filter(|count| *count <= MAXIMUM_FEEDBACK_SEQUENCES)
            .ok_or(PacketArrivalFeedbackError::PayloadTooLarge)?;
        let last_sequence = first_sequence
            .checked_add(u32::from(highest_offset))
            .ok_or(PacketArrivalFeedbackError::MalformedRun)?;
        if first_sequence < feedback.first_datagram_sequence
            || last_sequence > feedback.highest_datagram_sequence
        {
            return Err(PacketArrivalFeedbackError::SequenceRangeMismatch);
        }
        if previous_last.is_some_and(|previous| first_sequence <= previous) {
            return Err(PacketArrivalFeedbackError::MalformedRun);
        }
        for _ in 0..bitmap.count_ones() {
            let (delta, consumed) = decode_varint(&bytes[cursor..])?;
            if delta > maximum_delta
                || feedback
                    .packet_arrival_reference_time_us
                    .checked_add(delta)
                    .is_none()
            {
                return Err(PacketArrivalFeedbackError::ArrivalDeltaOverflow);
            }
            cursor += consumed;
        }
        previous_last = Some(last_sequence);
        runs.push(DecodedRun {
            first_sequence,
            bitmap,
            highest_offset,
        });
    }
    if received_sequences != feedback.received_datagrams as usize {
        return Err(PacketArrivalFeedbackError::CountMismatch);
    }
    Ok(runs)
}

fn decode_varint(bytes: &[u8]) -> Result<(u64, usize), PacketArrivalFeedbackError> {
    let mut value = 0_u64;
    for (index, byte) in bytes.iter().copied().take(10).enumerate() {
        if index == 9 && byte > 1 {
            return Err(PacketArrivalFeedbackError::ArrivalDeltaOverflow);
        }
        value |= u64::from(byte & 0x7f) << (index * 7);
        if byte & 0x80 == 0 {
            return Ok((value, index + 1));
        }
    }
    Err(PacketArrivalFeedbackError::MalformedRun)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feedback(runs: Vec<u8>, received_datagrams: u32) -> MediaFeedback {
        MediaFeedback {
            stream_id: 1,
            first_datagram_sequence: 0,
            highest_datagram_sequence: u32::MAX,
            received_datagrams,
            window_milliseconds: 250,
            packet_arrival_reference_time_us: 1_000_000,
            packet_arrival_runs: runs,
            ..MediaFeedback::default()
        }
    }

    #[tokio::test]
    async fn history_accepts_only_recorded_received_datagrams() {
        let history = PacketArrivalHistory::spawn();
        history.set_enabled(true);
        history
            .record_sent(PacketIdentity {
                stream_id: 1,
                datagram_sequence: 10,
            })
            .await
            .unwrap();
        history
            .record_sent(PacketIdentity {
                stream_id: 1,
                datagram_sequence: 12,
            })
            .await
            .unwrap();
        let mut runs = Vec::from(10_u32.to_be_bytes());
        runs.extend_from_slice(&0b101_u64.to_be_bytes());
        runs.extend_from_slice(&[0, 25]);

        let observation = history.observe(&feedback(runs, 2)).await.unwrap();

        assert_eq!(observation.received_datagrams, 2);
        assert_eq!(observation.covered_sequences, 3);
    }

    #[tokio::test]
    async fn history_rejects_arrivals_for_datagrams_that_were_not_sent() {
        let history = PacketArrivalHistory::spawn();
        history.set_enabled(true);
        let mut runs = Vec::from(44_u32.to_be_bytes());
        runs.extend_from_slice(&1_u64.to_be_bytes());
        runs.push(0);

        assert_eq!(
            history.observe(&feedback(runs, 1)).await,
            Err(PacketArrivalFeedbackError::UntrackedDatagram)
        );
    }

    #[tokio::test]
    async fn unnegotiated_history_omits_recording_and_rejects_observation() {
        let history = PacketArrivalHistory::spawn();
        history
            .record_sent(PacketIdentity {
                stream_id: 1,
                datagram_sequence: 1,
            })
            .await
            .unwrap();
        assert_eq!(
            history.observe(&feedback(Vec::new(), 0)).await,
            Err(PacketArrivalFeedbackError::Unsupported)
        );
    }

    #[test]
    fn malformed_or_partial_packet_arrival_fields_fail_closed() {
        let mut partial = feedback(Vec::new(), 0);
        assert_eq!(
            decode_runs(&partial),
            Err(PacketArrivalFeedbackError::MissingField)
        );
        partial.packet_arrival_runs = vec![0; RUN_PREFIX_BYTES];
        assert_eq!(
            decode_runs(&partial),
            Err(PacketArrivalFeedbackError::MalformedRun)
        );
    }

    #[test]
    fn packet_arrival_feedback_bounds_payload_and_covered_sequences() {
        let oversized = feedback(vec![0; MAXIMUM_FEEDBACK_PAYLOAD_BYTES + 1], 0);
        assert_eq!(
            decode_runs(&oversized),
            Err(PacketArrivalFeedbackError::PayloadTooLarge)
        );

        let mut runs = Vec::new();
        for sequence in (0..=4_096_u32).step_by(64) {
            runs.extend_from_slice(&sequence.to_be_bytes());
            runs.extend_from_slice(&u64::MAX.to_be_bytes());
            runs.extend(std::iter::repeat_n(0, 64));
        }
        assert_eq!(
            decode_runs(&feedback(runs, 4_096)),
            Err(PacketArrivalFeedbackError::PayloadTooLarge)
        );
    }

    #[tokio::test]
    async fn run_range_mismatch_rejects_without_consuming_sent_history() {
        let history = PacketArrivalHistory::spawn();
        history.set_enabled(true);
        for sequence in [10, 11, 12] {
            history
                .record_sent(PacketIdentity {
                    stream_id: 1,
                    datagram_sequence: sequence,
                })
                .await
                .unwrap();
        }

        let mut below = Vec::from(10_u32.to_be_bytes());
        below.extend_from_slice(&0b11_u64.to_be_bytes());
        below.extend_from_slice(&[0, 1]);
        let mut below_feedback = feedback(below, 2);
        below_feedback.first_datagram_sequence = 11;
        below_feedback.highest_datagram_sequence = 12;
        assert_eq!(
            history.observe(&below_feedback).await,
            Err(PacketArrivalFeedbackError::SequenceRangeMismatch)
        );

        let mut above = Vec::from(11_u32.to_be_bytes());
        above.extend_from_slice(&0b11_u64.to_be_bytes());
        above.extend_from_slice(&[0, 1]);
        let mut above_feedback = feedback(above, 2);
        above_feedback.first_datagram_sequence = 10;
        above_feedback.highest_datagram_sequence = 11;
        assert_eq!(
            history.observe(&above_feedback).await,
            Err(PacketArrivalFeedbackError::SequenceRangeMismatch)
        );

        let mut boundary = Vec::from(10_u32.to_be_bytes());
        boundary.extend_from_slice(&0b111_u64.to_be_bytes());
        boundary.extend_from_slice(&[0, 1, 2]);
        let mut boundary_feedback = feedback(boundary, 3);
        boundary_feedback.first_datagram_sequence = 10;
        boundary_feedback.highest_datagram_sequence = 12;
        assert_eq!(
            history.observe(&boundary_feedback).await,
            Ok(PacketArrivalObservation {
                received_datagrams: 3,
                covered_sequences: 3,
            })
        );
    }
}
