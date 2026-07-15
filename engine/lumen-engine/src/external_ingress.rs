use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::sync::Mutex;

use crate::LumenEngineStatus;

mod continuity;
mod packet;
use continuity::{payload_fingerprint, ContinuityState};
use packet::PacketState;

pub const EXTERNAL_INGRESS_ACCEPT: u32 = 0;
pub const EXTERNAL_INGRESS_DROP_DUPLICATE_IDENTITY: u32 = 1;
pub const EXTERNAL_INGRESS_RESYNC_CADENCE: u32 = 2;
pub const EXTERNAL_INGRESS_RESYNC_DUPLICATE_PAYLOAD: u32 = 3;
pub const EXTERNAL_INGRESS_RESTART_DUPLICATE_PAYLOAD: u32 = 4;

pub const EXTERNAL_INGRESS_EVENT_SATURATED_DROP: u32 = 0;
pub const EXTERNAL_INGRESS_EVENT_FORWARDER_OVERFLOW: u32 = 1;
pub const EXTERNAL_INGRESS_EVENT_OTHER_DROP: u32 = 2;

pub const EXTERNAL_INGRESS_EVENT_NO_ACTION: u32 = 0;
pub const EXTERNAL_INGRESS_EVENT_RESYNC: u32 = 1;
pub const EXTERNAL_INGRESS_EVENT_RESTART: u32 = 2;

pub const EXTERNAL_INGRESS_PACKET_ACCEPT: u32 = 0;
pub const EXTERNAL_INGRESS_PACKET_DROP_UNSUPPORTED_CODEC: u32 = 1;
pub const EXTERNAL_INGRESS_PACKET_DROP_CODEC_MISMATCH: u32 = 2;
pub const EXTERNAL_INGRESS_PACKET_DROP_WAITING_FOR_IDR: u32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LumenExternalIngressFrame {
    pub source_sequence: u64,
    pub source_display_time_nanoseconds: u64,
    pub has_packet_timestamp: bool,
    pub packet_timestamp_microseconds: i64,
    pub has_callback_latency: bool,
    pub callback_latency_milliseconds: f64,
    pub is_replay: bool,
    pub is_idr: bool,
    pub callback_latency_threshold_milliseconds: f64,
    pub packet_timestamp_threshold_milliseconds: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LumenExternalIngressDecision {
    pub action: u32,
    pub sequence_delta: u64,
    pub has_source_display_delta: bool,
    pub source_display_delta_milliseconds: f64,
    pub has_packet_timestamp_delta: bool,
    pub packet_timestamp_delta_milliseconds: f64,
    pub has_callback_latency: bool,
    pub callback_latency_milliseconds: f64,
    pub duplicate_payload: bool,
    pub cadence_anomaly: bool,
    pub callback_latency_spike: bool,
    pub packet_timestamp_drift: bool,
    pub duplicate_payload_run: u32,
    pub duplicate_payload_recovery_attempts: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenExternalIngressEventDecision {
    pub action: u32,
    pub saturated_drop_run: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenExternalIngressPacketAdmission {
    pub frame_codec: i32,
    pub requested_video_format: i32,
    pub is_idr: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenExternalIngressPacketDecision {
    pub action: u32,
    pub effective_video_format: i32,
    pub codec_adopted: bool,
    pub should_log_codec_mismatch: bool,
    pub should_log_waiting_for_idr: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenExternalIngressPacketAllocation {
    pub frame_index: i64,
    pub is_first_packet: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenExternalIngressProgressDecision {
    pub stalled: bool,
    pub should_log_stall: bool,
}

#[derive(Debug, Default)]
struct ExternalIngressState {
    continuity: ContinuityState,
    saturated_drop_run: u32,
    packet: PacketState,
    last_progress_frame_count: u64,
    reported_frame_stall: bool,
}

impl ExternalIngressState {
    fn admit_packet(
        &mut self,
        packet: LumenExternalIngressPacketAdmission,
    ) -> LumenExternalIngressPacketDecision {
        self.packet.admit(packet)
    }

    fn allocate_packet(&mut self) -> LumenExternalIngressPacketAllocation {
        self.packet.allocate()
    }

    fn record_progress(
        &mut self,
        frame_count: u64,
        producer_active: bool,
    ) -> LumenExternalIngressProgressDecision {
        let stalled = producer_active && frame_count == self.last_progress_frame_count;
        let decision = LumenExternalIngressProgressDecision {
            stalled,
            should_log_stall: stalled && !self.reported_frame_stall,
        };
        self.reported_frame_stall = stalled;
        self.last_progress_frame_count = frame_count;
        decision
    }

    fn reset(&mut self, preserve_recovery_attempts: bool) {
        self.continuity.reset(preserve_recovery_attempts);
        self.packet.reset_session();
        if !preserve_recovery_attempts {
            self.saturated_drop_run = 0;
        }
    }

    fn record_event(
        &mut self,
        event_kind: u32,
    ) -> Result<LumenExternalIngressEventDecision, LumenEngineStatus> {
        let action = match event_kind {
            EXTERNAL_INGRESS_EVENT_SATURATED_DROP => {
                self.saturated_drop_run = self.saturated_drop_run.saturating_add(1);
                if self.saturated_drop_run >= 3 {
                    EXTERNAL_INGRESS_EVENT_RESTART
                } else {
                    EXTERNAL_INGRESS_EVENT_RESYNC
                }
            }
            EXTERNAL_INGRESS_EVENT_FORWARDER_OVERFLOW => {
                self.saturated_drop_run = 0;
                EXTERNAL_INGRESS_EVENT_RESYNC
            }
            EXTERNAL_INGRESS_EVENT_OTHER_DROP => {
                self.saturated_drop_run = 0;
                EXTERNAL_INGRESS_EVENT_NO_ACTION
            }
            _ => return Err(LumenEngineStatus::InvalidArgument),
        };
        Ok(LumenExternalIngressEventDecision {
            action,
            saturated_drop_run: self.saturated_drop_run,
        })
    }

    fn evaluate(
        &mut self,
        frame: LumenExternalIngressFrame,
        payload_hash: u64,
        payload_size: u64,
    ) -> Result<LumenExternalIngressDecision, LumenEngineStatus> {
        self.continuity.evaluate(frame, payload_hash, payload_size)
    }
}

pub struct LumenExternalIngressPolicy {
    inner: Mutex<ExternalIngressState>,
}

#[no_mangle]
pub extern "C" fn lumen_external_ingress_policy_create(
    policy_out: *mut *mut LumenExternalIngressPolicy,
) -> LumenEngineStatus {
    let Some(mut policy_out) = NonNull::new(policy_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(|| {
        Box::into_raw(Box::new(LumenExternalIngressPolicy {
            inner: Mutex::new(ExternalIngressState::default()),
        }))
    }) {
        Ok(policy) => {
            unsafe { *policy_out.as_mut() = policy };
            LumenEngineStatus::Ok
        }
        Err(_) => LumenEngineStatus::Panic,
    }
}

#[no_mangle]
pub extern "C" fn lumen_external_ingress_policy_destroy(policy: *mut LumenExternalIngressPolicy) {
    if !policy.is_null() {
        unsafe { drop(Box::from_raw(policy)) };
    }
}

#[no_mangle]
pub extern "C" fn lumen_external_ingress_policy_reset(
    policy: *const LumenExternalIngressPolicy,
    preserve_recovery_attempts: bool,
) -> LumenEngineStatus {
    let Some(policy) = NonNull::new(policy.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let mut state = unsafe { policy.as_ref() }
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        state.reset(preserve_recovery_attempts);
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[no_mangle]
pub extern "C" fn lumen_external_ingress_policy_evaluate(
    policy: *const LumenExternalIngressPolicy,
    frame: LumenExternalIngressFrame,
    payload: *const u8,
    payload_length: usize,
    decision_out: *mut LumenExternalIngressDecision,
) -> LumenEngineStatus {
    let Some(policy) = NonNull::new(policy.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut decision_out) = NonNull::new(decision_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let payload = if payload_length == 0 {
        &[][..]
    } else {
        let Some(payload) = NonNull::new(payload.cast_mut()) else {
            return LumenEngineStatus::InvalidArgument;
        };
        unsafe { std::slice::from_raw_parts(payload.as_ptr(), payload_length) }
    };
    catch_unwind(AssertUnwindSafe(|| {
        let mut state = unsafe { policy.as_ref() }
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        let decision =
            state.evaluate(frame, payload_fingerprint(payload), payload_length as u64)?;
        unsafe { *decision_out.as_mut() = decision };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[no_mangle]
pub extern "C" fn lumen_external_ingress_policy_record_event(
    policy: *const LumenExternalIngressPolicy,
    event_kind: u32,
    decision_out: *mut LumenExternalIngressEventDecision,
) -> LumenEngineStatus {
    let Some(policy) = NonNull::new(policy.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut decision_out) = NonNull::new(decision_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let mut state = unsafe { policy.as_ref() }
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        let decision = state.record_event(event_kind)?;
        unsafe { *decision_out.as_mut() = decision };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[no_mangle]
pub extern "C" fn lumen_external_ingress_policy_admit_packet(
    policy: *const LumenExternalIngressPolicy,
    packet: LumenExternalIngressPacketAdmission,
    decision_out: *mut LumenExternalIngressPacketDecision,
) -> LumenEngineStatus {
    let Some(policy) = NonNull::new(policy.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut decision_out) = NonNull::new(decision_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let mut state = unsafe { policy.as_ref() }
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        unsafe { *decision_out.as_mut() = state.admit_packet(packet) };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[no_mangle]
pub extern "C" fn lumen_external_ingress_policy_allocate_packet(
    policy: *const LumenExternalIngressPolicy,
    allocation_out: *mut LumenExternalIngressPacketAllocation,
) -> LumenEngineStatus {
    let Some(policy) = NonNull::new(policy.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut allocation_out) = NonNull::new(allocation_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let mut state = unsafe { policy.as_ref() }
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        unsafe { *allocation_out.as_mut() = state.allocate_packet() };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[no_mangle]
pub extern "C" fn lumen_external_ingress_policy_record_progress(
    policy: *const LumenExternalIngressPolicy,
    frame_count: u64,
    producer_active: bool,
    decision_out: *mut LumenExternalIngressProgressDecision,
) -> LumenEngineStatus {
    let Some(policy) = NonNull::new(policy.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut decision_out) = NonNull::new(decision_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let mut state = unsafe { policy.as_ref() }
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?;
        unsafe { *decision_out.as_mut() = state.record_progress(frame_count, producer_active) };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_saturation_resyncs_then_restarts_until_full_reset() {
        let mut state = ExternalIngressState::default();
        assert_eq!(
            state
                .record_event(EXTERNAL_INGRESS_EVENT_SATURATED_DROP)
                .unwrap(),
            LumenExternalIngressEventDecision {
                action: EXTERNAL_INGRESS_EVENT_RESYNC,
                saturated_drop_run: 1,
            }
        );
        state.reset(true);
        assert_eq!(
            state
                .record_event(EXTERNAL_INGRESS_EVENT_SATURATED_DROP)
                .unwrap()
                .action,
            EXTERNAL_INGRESS_EVENT_RESYNC
        );
        state.reset(true);
        assert_eq!(
            state
                .record_event(EXTERNAL_INGRESS_EVENT_SATURATED_DROP)
                .unwrap()
                .action,
            EXTERNAL_INGRESS_EVENT_RESTART
        );
        state.reset(false);
        assert_eq!(state.saturated_drop_run, 0);
    }

    #[test]
    fn progress_reports_one_stall_until_frames_advance() {
        let mut state = ExternalIngressState::default();
        assert_eq!(
            state.record_progress(0, true),
            LumenExternalIngressProgressDecision {
                stalled: true,
                should_log_stall: true,
            }
        );
        assert!(state.record_progress(0, true).stalled);
        assert!(!state.record_progress(0, true).should_log_stall);
        assert!(!state.record_progress(1, true).stalled);
        assert!(state.record_progress(1, true).should_log_stall);
        assert!(!state.record_progress(1, false).stalled);

        state.reset(false);
        assert!(!state.record_progress(2, true).stalled);
    }
}
