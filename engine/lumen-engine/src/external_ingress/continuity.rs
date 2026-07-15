use super::{
    LumenExternalIngressDecision, LumenExternalIngressFrame, EXTERNAL_INGRESS_ACCEPT,
    EXTERNAL_INGRESS_DROP_DUPLICATE_IDENTITY, EXTERNAL_INGRESS_RESTART_DUPLICATE_PAYLOAD,
    EXTERNAL_INGRESS_RESYNC_CADENCE, EXTERNAL_INGRESS_RESYNC_DUPLICATE_PAYLOAD,
};
use crate::LumenEngineStatus;

pub(super) fn payload_fingerprint(payload: &[u8]) -> u64 {
    const OFFSET_BASIS: u64 = 1_469_598_103_934_665_603;
    const PRIME: u64 = 1_099_511_628_211;

    payload.iter().fold(OFFSET_BASIS, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(PRIME)
    })
}

#[derive(Debug, Default)]
pub(super) struct ContinuityState {
    last_source_sequence: u64,
    last_source_display_time_nanoseconds: u64,
    last_packet_timestamp_microseconds: Option<i64>,
    last_payload_hash: u64,
    last_payload_size: u64,
    duplicate_payload_run: u32,
    duplicate_payload_recovery_attempts: u32,
}

impl ContinuityState {
    pub(super) fn reset(&mut self, preserve_recovery_attempts: bool) {
        let recovery_attempts = self.duplicate_payload_recovery_attempts;
        *self = Self::default();
        if preserve_recovery_attempts {
            self.duplicate_payload_recovery_attempts = recovery_attempts;
        }
    }

    pub(super) fn evaluate(
        &mut self,
        frame: LumenExternalIngressFrame,
        payload_hash: u64,
        payload_size: u64,
    ) -> Result<LumenExternalIngressDecision, LumenEngineStatus> {
        if (frame.has_callback_latency && !frame.callback_latency_milliseconds.is_finite())
            || !frame.callback_latency_threshold_milliseconds.is_finite()
            || frame.callback_latency_threshold_milliseconds < 0.0
            || !frame.packet_timestamp_threshold_milliseconds.is_finite()
            || frame.packet_timestamp_threshold_milliseconds < 0.0
        {
            return Err(LumenEngineStatus::InvalidArgument);
        }

        let sequence_delta = if self.last_source_sequence > 0
            && frame.source_sequence >= self.last_source_sequence
        {
            frame.source_sequence - self.last_source_sequence
        } else {
            0
        };
        let source_display_delta = if self.last_source_display_time_nanoseconds > 0
            && frame.source_display_time_nanoseconds >= self.last_source_display_time_nanoseconds
        {
            Some(
                (frame.source_display_time_nanoseconds - self.last_source_display_time_nanoseconds)
                    as f64
                    / 1_000_000.0,
            )
        } else {
            None
        };
        let packet_timestamp_delta = self
            .last_packet_timestamp_microseconds
            .and_then(|previous| {
                frame
                    .has_packet_timestamp
                    .then(|| (frame.packet_timestamp_microseconds - previous) as f64 / 1_000.0)
            });
        let has_payload_baseline = self.last_payload_size != 0;
        let duplicate_payload =
            self.last_payload_size == payload_size && self.last_payload_hash == payload_hash;
        let duplicate_source_identity = self.last_source_sequence > 0
            && self.last_source_display_time_nanoseconds > 0
            && frame.source_sequence == self.last_source_sequence
            && frame.source_display_time_nanoseconds == self.last_source_display_time_nanoseconds;

        let mut decision = LumenExternalIngressDecision {
            action: EXTERNAL_INGRESS_ACCEPT,
            sequence_delta,
            has_source_display_delta: source_display_delta.is_some(),
            source_display_delta_milliseconds: source_display_delta.unwrap_or_default(),
            has_packet_timestamp_delta: packet_timestamp_delta.is_some(),
            packet_timestamp_delta_milliseconds: packet_timestamp_delta.unwrap_or_default(),
            has_callback_latency: frame.has_callback_latency,
            callback_latency_milliseconds: frame.callback_latency_milliseconds,
            duplicate_payload,
            cadence_anomaly: source_display_delta.is_some_and(|delta| delta <= 0.0),
            callback_latency_spike: frame.has_callback_latency
                && frame.callback_latency_milliseconds
                    > frame.callback_latency_threshold_milliseconds,
            packet_timestamp_drift: packet_timestamp_delta
                .is_some_and(|delta| delta > frame.packet_timestamp_threshold_milliseconds),
            duplicate_payload_run: self.duplicate_payload_run,
            duplicate_payload_recovery_attempts: self.duplicate_payload_recovery_attempts,
        };

        if duplicate_source_identity && duplicate_payload {
            decision.action = EXTERNAL_INGRESS_DROP_DUPLICATE_IDENTITY;
            return Ok(decision);
        }

        if duplicate_payload
            && !frame.is_replay
            && sequence_delta > 0
            && source_display_delta.is_some_and(|delta| delta > 0.0)
        {
            self.duplicate_payload_run = self.duplicate_payload_run.saturating_add(1);
        } else {
            self.duplicate_payload_run = 0;
            if has_payload_baseline {
                self.duplicate_payload_recovery_attempts = 0;
            }
        }

        if decision.cadence_anomaly && !frame.is_idr {
            decision.action = EXTERNAL_INGRESS_RESYNC_CADENCE;
        } else if self.duplicate_payload_run >= 2 && !frame.is_idr {
            self.duplicate_payload_recovery_attempts =
                self.duplicate_payload_recovery_attempts.saturating_add(1);
            decision.action = if self.duplicate_payload_recovery_attempts >= 2 {
                EXTERNAL_INGRESS_RESTART_DUPLICATE_PAYLOAD
            } else {
                EXTERNAL_INGRESS_RESYNC_DUPLICATE_PAYLOAD
            };
        }

        decision.duplicate_payload_run = self.duplicate_payload_run;
        decision.duplicate_payload_recovery_attempts = self.duplicate_payload_recovery_attempts;
        if decision.action != EXTERNAL_INGRESS_ACCEPT {
            return Ok(decision);
        }

        if duplicate_payload && frame.is_replay {
            self.duplicate_payload_run = 0;
            self.duplicate_payload_recovery_attempts = 0;
            decision.duplicate_payload_run = 0;
            decision.duplicate_payload_recovery_attempts = 0;
        }

        self.last_source_sequence = frame.source_sequence;
        self.last_source_display_time_nanoseconds = frame.source_display_time_nanoseconds;
        self.last_packet_timestamp_microseconds = frame
            .has_packet_timestamp
            .then_some(frame.packet_timestamp_microseconds);
        self.last_payload_hash = payload_hash;
        self.last_payload_size = payload_size;
        Ok(decision)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(sequence: u64, display_ns: u64) -> LumenExternalIngressFrame {
        LumenExternalIngressFrame {
            source_sequence: sequence,
            source_display_time_nanoseconds: display_ns,
            has_packet_timestamp: true,
            packet_timestamp_microseconds: (display_ns / 1_000) as i64,
            callback_latency_threshold_milliseconds: 80.0,
            packet_timestamp_threshold_milliseconds: 80.0,
            ..Default::default()
        }
    }

    #[test]
    fn duplicate_identity_is_dropped_without_advancing_state() {
        let mut state = ContinuityState::default();
        assert_eq!(
            state.evaluate(frame(1, 1_000_000), 7, 100).unwrap().action,
            EXTERNAL_INGRESS_ACCEPT
        );
        assert_eq!(
            state.evaluate(frame(1, 1_000_000), 7, 100).unwrap().action,
            EXTERNAL_INGRESS_DROP_DUPLICATE_IDENTITY
        );
    }

    #[test]
    fn repeated_payload_resyncs_then_restarts_after_preserved_recovery() {
        let mut state = ContinuityState::default();
        state.evaluate(frame(1, 1_000_000), 7, 100).unwrap();
        state.evaluate(frame(2, 2_000_000), 7, 100).unwrap();
        let first = state.evaluate(frame(3, 3_000_000), 7, 100).unwrap();
        assert_eq!(first.action, EXTERNAL_INGRESS_RESYNC_DUPLICATE_PAYLOAD);
        assert_eq!(first.duplicate_payload_recovery_attempts, 1);

        state.reset(true);
        let mut idr = frame(4, 4_000_000);
        idr.is_idr = true;
        state.evaluate(idr, 7, 100).unwrap();
        state.evaluate(frame(5, 5_000_000), 7, 100).unwrap();
        let second = state.evaluate(frame(6, 6_000_000), 7, 100).unwrap();
        assert_eq!(second.action, EXTERNAL_INGRESS_RESTART_DUPLICATE_PAYLOAD);
        assert_eq!(second.duplicate_payload_recovery_attempts, 2);
    }

    #[test]
    fn cadence_and_latency_anomalies_are_reported_separately() {
        let mut state = ContinuityState::default();
        state.evaluate(frame(1, 1_000_000), 1, 100).unwrap();
        let mut anomalous = frame(2, 1_000_000);
        anomalous.has_callback_latency = true;
        anomalous.callback_latency_milliseconds = 90.0;
        anomalous.packet_timestamp_microseconds = 200_000;
        let decision = state.evaluate(anomalous, 2, 100).unwrap();
        assert_eq!(decision.action, EXTERNAL_INGRESS_RESYNC_CADENCE);
        assert!(decision.cadence_anomaly);
        assert!(decision.callback_latency_spike);
        assert!(decision.packet_timestamp_drift);
    }

    #[test]
    fn payload_fingerprint_matches_the_previous_native_fnv_contract() {
        assert_eq!(payload_fingerprint(b"hello"), 0x005a_0d15_131e_c7a1);
    }
}
