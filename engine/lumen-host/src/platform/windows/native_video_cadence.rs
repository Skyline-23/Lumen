use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Condvar, Mutex};

use lumen_engine::{
    LumenAdaptiveFrameCadenceController, LumenAdaptiveFrameCadenceObservation,
    LumenAdaptiveFrameCadenceRequest, LumenContentCadenceController,
    LumenContentCadenceObservation, LumenContentCadenceRequest,
};

use super::super::driver_abi::{
    DRIVER_CONTENT_SIGNAL_CHANGED, DRIVER_CONTENT_SIGNAL_UNCHANGED, DRIVER_CONTENT_SIGNAL_UNKNOWN,
};

pub(super) struct WindowsAdaptiveFrameCadence {
    controller: LumenAdaptiveFrameCadenceController,
    ceiling_frame_rate: u32,
}

impl WindowsAdaptiveFrameCadence {
    pub(super) fn new(ceiling_frame_rate: u32) -> Result<Self, String> {
        let controller =
            LumenAdaptiveFrameCadenceController::new(LumenAdaptiveFrameCadenceRequest {
                requested_frame_rate: ceiling_frame_rate,
            })
            .map_err(|status| format!("Windows adaptive frame cadence setup failed: {status:?}"))?;
        Ok(Self {
            controller,
            ceiling_frame_rate,
        })
    }

    pub(super) fn observe(
        &self,
        observation: LumenAdaptiveFrameCadenceObservation,
    ) -> Result<u32, String> {
        let decision = self.controller.observe(observation).map_err(|status| {
            format!("Windows adaptive frame cadence observation failed: {status:?}")
        })?;
        Ok(decision.target_frame_rate.clamp(1, self.ceiling_frame_rate))
    }
}

pub(super) struct WindowsCadenceAdmission {
    target_frame_rate: u32,
    last_admitted_timestamp_90khz: Option<u64>,
    next_deadline_scaled: Option<u128>,
}

impl WindowsCadenceAdmission {
    pub(super) fn new() -> Self {
        Self {
            target_frame_rate: 0,
            last_admitted_timestamp_90khz: None,
            next_deadline_scaled: None,
        }
    }

    pub(super) fn reset(&mut self) {
        *self = Self::new();
    }

    pub(super) fn admits(
        &mut self,
        source_timestamp_90khz: u64,
        target_frame_rate: u32,
        ceiling_frame_rate: u32,
        force: bool,
    ) -> bool {
        const TICKS_PER_SECOND: u128 = 90_000;
        let target = target_frame_rate.clamp(1, ceiling_frame_rate.max(1));
        let source_scaled = u128::from(source_timestamp_90khz) * u128::from(target);

        if self.target_frame_rate != target {
            self.target_frame_rate = target;
            self.next_deadline_scaled = self
                .last_admitted_timestamp_90khz
                .map(|timestamp| u128::from(timestamp) * u128::from(target) + TICKS_PER_SECOND);
        }

        if force {
            self.last_admitted_timestamp_90khz = Some(source_timestamp_90khz);
            self.next_deadline_scaled = Some(source_scaled + TICKS_PER_SECOND);
            return true;
        }

        let Some(deadline) = self.next_deadline_scaled else {
            self.last_admitted_timestamp_90khz = Some(source_timestamp_90khz);
            self.next_deadline_scaled = Some(source_scaled + TICKS_PER_SECOND);
            return true;
        };
        if source_scaled < deadline {
            return false;
        }

        self.last_admitted_timestamp_90khz = Some(source_timestamp_90khz);
        let elapsed = source_scaled.saturating_sub(deadline);
        let intervals = elapsed / TICKS_PER_SECOND + 1;
        self.next_deadline_scaled = Some(deadline + intervals * TICKS_PER_SECOND);
        true
    }
}

pub(super) fn effective_target_frame_rate(
    ceiling_frame_rate: u32,
    adaptive_target_frame_rate: u32,
    content_target_frame_rate: u32,
    admission_divisor: u8,
) -> u32 {
    let ceiling = ceiling_frame_rate.max(1);
    let divisor = u32::from(admission_divisor.max(1));
    let client_target = ceiling.div_ceil(divisor);
    adaptive_target_frame_rate
        .clamp(1, ceiling)
        .min(content_target_frame_rate.clamp(1, ceiling))
        .min(client_target)
}

pub(super) struct WindowsUnchangedContentCadence {
    controller: LumenContentCadenceController,
    ceiling_frame_rate: u32,
}

impl WindowsUnchangedContentCadence {
    pub(super) fn new(ceiling_frame_rate: u32) -> Result<Self, String> {
        let controller = LumenContentCadenceController::new(LumenContentCadenceRequest {
            requested_frame_rate: ceiling_frame_rate,
        })
        .map_err(|status| format!("Windows unchanged-content cadence setup failed: {status:?}"))?;
        Ok(Self {
            controller,
            ceiling_frame_rate,
        })
    }

    pub(super) fn observe(
        &self,
        time: f64,
        signal: u32,
        pipeline_stable: bool,
    ) -> Result<u32, String> {
        let signal = match signal {
            DRIVER_CONTENT_SIGNAL_CHANGED | DRIVER_CONTENT_SIGNAL_UNCHANGED => signal,
            _ => DRIVER_CONTENT_SIGNAL_UNKNOWN,
        };
        let decision = self
            .controller
            .observe(LumenContentCadenceObservation {
                monotonic_time_seconds: time,
                signal,
                pipeline_stable,
            })
            .map_err(|status| {
                format!("Windows unchanged-content cadence observation failed: {status:?}")
            })?;
        Ok(decision.target_frame_rate.clamp(1, self.ceiling_frame_rate))
    }

    pub(super) fn wake(&self, time: f64) -> Result<u32, String> {
        let decision = self.controller.wake(time).map_err(|status| {
            format!("Windows unchanged-content cadence wake failed: {status:?}")
        })?;
        Ok(decision.target_frame_rate.clamp(1, self.ceiling_frame_rate))
    }
}

/// Cross-thread wake ownership for a capture worker that may be blocked in a
/// synchronous driver dequeue. Input validation reserves the wake before the
/// native injection, then commits or cancels it transactionally. The worker
/// only consumes committed wakes, so a failed injection cannot wake cadence.
pub(super) struct ContentCadenceWakeLatch {
    state: AtomicU8,
    transition: Mutex<()>,
    /// A frame can arrive after input reserves the wake but before native
    /// injection commits it. The capture worker waits only in that narrow
    /// RESERVED window so a failed injection can still cancel without
    /// waking cadence, while the first input-driven frame cannot be admitted
    /// against the parked target.
    resolution: Condvar,
}

impl Default for ContentCadenceWakeLatch {
    fn default() -> Self {
        Self {
            state: AtomicU8::new(Self::IDLE),
            transition: Mutex::new(()),
            resolution: Condvar::new(),
        }
    }
}

impl ContentCadenceWakeLatch {
    const IDLE: u8 = 0;
    const RESERVED: u8 = 1;
    const COMMITTED: u8 = 2;

    pub(super) fn reserve(&self) -> bool {
        let _guard = self
            .transition
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.state
            .compare_exchange(
                Self::IDLE,
                Self::RESERVED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    pub(super) fn commit(&self) -> bool {
        let _guard = self
            .transition
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let committed = self
            .state
            .compare_exchange(
                Self::RESERVED,
                Self::COMMITTED,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok();
        if committed {
            self.resolution.notify_all();
        }
        committed
    }

    pub(super) fn cancel(&self) -> bool {
        let _guard = self
            .transition
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let cancelled = self
            .state
            .compare_exchange(
                Self::RESERVED,
                Self::IDLE,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok();
        if cancelled {
            self.resolution.notify_all();
        }
        cancelled
    }

    pub(super) fn take(&self) -> bool {
        self.state
            .compare_exchange(
                Self::COMMITTED,
                Self::IDLE,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
    }

    /// Takes a committed wake for the current frame. If native input is still
    /// being injected, wait for that reservation to commit or cancel before
    /// deciding whether cadence may be reopened. The steady IDLE path is one
    /// atomic load; only COMMITTED or RESERVED states need coordination.
    pub(super) fn take_for_frame(&self) -> bool {
        loop {
            match self.state.load(Ordering::Acquire) {
                Self::IDLE => return false,
                Self::COMMITTED => {
                    if self.take() {
                        return true;
                    }
                }
                Self::RESERVED => {
                    let mut guard = self
                        .transition
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    while self.state.load(Ordering::Acquire) == Self::RESERVED {
                        guard = self
                            .resolution
                            .wait(guard)
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                    }
                    drop(guard);
                }
                _ => return false,
            }
        }
    }

    pub(super) fn clear(&self) {
        let _guard = self
            .transition
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.state.store(Self::IDLE, Ordering::Release);
        self.resolution.notify_all();
    }
}
