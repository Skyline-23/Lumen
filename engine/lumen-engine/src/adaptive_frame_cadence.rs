//! Adaptive source cadence policy shared by host capture implementations.
//!
//! The controller treats the negotiated frame rate as a ceiling.  It only
//! lowers the source target when the source is supplying frames faster than
//! the encoder is producing them and sustained pending-admission drops prove
//! encoder backpressure.  A clean controller slowly probes back toward the
//! negotiated ceiling.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::sync::Mutex;

use crate::LumenEngineStatus;

const MIN_UPDATE_INTERVAL_SECONDS: f64 = 0.20;
const STABLE_WARMUP_SECONDS: f64 = 1.0;
const IDLE_ACTIVITY_REBASE_SECONDS: f64 = 1.0;
const FRAME_RATE_FLOOR: u32 = 15;
const RATE_DEADBAND_FPS: f64 = 2.0;
const RATE_DEADBAND_RATIO: f64 = 0.05;
const PRESSURE_WINDOWS_BEFORE_DECREASE: u8 = 2;
const CLEAN_WINDOWS_BEFORE_PROBE: u8 = 8;
const PROBE_STEP_DIVISOR: u32 = 24;
const SUSTAINABLE_OUTPUT_MARGIN: f64 = 0.95;
const MIN_SOURCE_SAMPLES_PER_WINDOW: u64 = 4;
const MIN_OUTPUT_SAMPLES_FOR_SUSTAINABLE_RATE: u64 = 4;
const MAX_DECREASE_RATIO: f64 = 0.25;

/// Configuration for one adaptive frame-cadence controller.
///
/// `requested_frame_rate` is the negotiated ceiling.  The controller never
/// raises its target above this value and does not change the wire contract.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAdaptiveFrameCadenceRequest {
    pub requested_frame_rate: u32,
}

/// Cumulative source/encoder observation used by the cadence controller.
///
/// `monotonic_time_seconds` must come from one monotonic clock for the whole
/// lifetime of a controller.  The three counters must be cumulative and must
/// not decrease.  `pending_drop_count` must count only encoder admission or
/// pending-queue drops; intentional source samples skipped because of the
/// current cadence target are not encoder pressure and must not be included.
/// `pipeline_stable` must be false while bootstrap admission is closed (or is
/// otherwise being reconfigured).  Unstable observations rebase the
/// controller and cannot contribute pressure.
/// `callback_latency_milliseconds` is the observed encoder output-callback
/// latency for the current measurement window; pass zero when no callback has
/// completed in the window.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LumenAdaptiveFrameCadenceObservation {
    pub monotonic_time_seconds: f64,
    pub source_frame_count: u64,
    pub output_frame_count: u64,
    pub pending_drop_count: u64,
    pub pipeline_stable: bool,
    pub callback_latency_milliseconds: f64,
}

/// Result of recording one observation.
///
/// `changed` is true only when this observation crossed an adaptive update
/// window and the target changed.  Callers should use `target_frame_rate` as
/// the source scheduling target even when `changed` is false.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenAdaptiveFrameCadenceDecision {
    pub target_frame_rate: u32,
    pub changed: bool,
}

#[derive(Clone, Copy, Debug)]
struct ObservationSnapshot {
    observation: LumenAdaptiveFrameCadenceObservation,
}

#[derive(Debug)]
struct AdaptiveFrameCadenceState {
    ceiling: u32,
    floor: u32,
    target: u32,
    last: Option<ObservationSnapshot>,
    stable_since_seconds: Option<f64>,
    /// Initial bootstrap warmup is one-time.  Later periodic/repair gate
    /// closures rebase measurements without restarting this warmup.
    warmup_complete: bool,
    pressure_windows: u8,
    clean_windows: u8,
}

impl AdaptiveFrameCadenceState {
    fn new(request: LumenAdaptiveFrameCadenceRequest) -> Result<Self, LumenEngineStatus> {
        if request.requested_frame_rate == 0 {
            return Err(LumenEngineStatus::InvalidArgument);
        }

        let ceiling = request.requested_frame_rate;
        let floor = ceiling.min(FRAME_RATE_FLOOR);
        Ok(Self {
            ceiling,
            floor,
            target: ceiling,
            last: None,
            stable_since_seconds: None,
            warmup_complete: false,
            pressure_windows: 0,
            clean_windows: 0,
        })
    }

    fn decision(&self, changed: bool) -> LumenAdaptiveFrameCadenceDecision {
        LumenAdaptiveFrameCadenceDecision {
            target_frame_rate: self.target,
            changed,
        }
    }

    fn observe(
        &mut self,
        observation: LumenAdaptiveFrameCadenceObservation,
    ) -> Result<LumenAdaptiveFrameCadenceDecision, LumenEngineStatus> {
        validate_observation(observation)?;

        let Some(previous) = self.last else {
            self.last = Some(ObservationSnapshot { observation });
            self.stable_since_seconds = observation
                .pipeline_stable
                .then_some(observation.monotonic_time_seconds);
            self.warmup_complete = false;
            self.pressure_windows = 0;
            self.clean_windows = 0;
            return Ok(self.decision(false));
        };

        if observation.monotonic_time_seconds < previous.observation.monotonic_time_seconds
            || observation.source_frame_count < previous.observation.source_frame_count
            || observation.output_frame_count < previous.observation.output_frame_count
            || observation.pending_drop_count < previous.observation.pending_drop_count
        {
            return Err(LumenEngineStatus::InvalidArgument);
        }

        let elapsed =
            observation.monotonic_time_seconds - previous.observation.monotonic_time_seconds;

        // Bootstrap and reconfiguration windows are not encoder-pressure
        // windows.  Rebase every unstable observation so that a closed gate
        // cannot carry source/drop deltas into the first stable window.
        if !observation.pipeline_stable {
            self.last = Some(ObservationSnapshot { observation });
            if !self.warmup_complete {
                self.stable_since_seconds = None;
                self.clean_windows = 0;
            }
            self.pressure_windows = 0;
            return Ok(self.decision(false));
        }

        // The first observation after an unstable interval starts a fresh
        // stable epoch.  It is deliberately not measured against the last
        // bootstrap sample, even when the counters advanced while the gate
        // was closed.
        if !previous.observation.pipeline_stable || self.stable_since_seconds.is_none() {
            self.last = Some(ObservationSnapshot { observation });
            if !self.warmup_complete {
                self.stable_since_seconds = Some(observation.monotonic_time_seconds);
                self.clean_windows = 0;
            }
            self.pressure_windows = 0;
            return Ok(self.decision(false));
        }

        // A static desktop can produce no ScreenCaptureKit callbacks for a
        // long time.  The first callback after that idle interval is activity,
        // not a one-second pressure window with zero output.  Restore the
        // negotiated ceiling immediately and rebase so the burst can enter at
        // the ceiling without synthesizing any frames during idle.
        let source_delta = observation
            .source_frame_count
            .saturating_sub(previous.observation.source_frame_count);
        if source_delta > 0 && elapsed >= IDLE_ACTIVITY_REBASE_SECONDS && self.target < self.ceiling
        {
            self.target = self.ceiling;
            self.last = Some(ObservationSnapshot { observation });
            self.pressure_windows = 0;
            self.clean_windows = 0;
            return Ok(self.decision(true));
        }

        // Initial stable windows are intentionally quiet.  Keep rebasing
        // during the warmup so bootstrap/idle history cannot be mistaken for
        // sustained encoder pressure when the first active window begins.
        let stable_since = self
            .stable_since_seconds
            .unwrap_or(observation.monotonic_time_seconds);
        let stable_elapsed = observation.monotonic_time_seconds - stable_since;
        if !self.warmup_complete && stable_elapsed < STABLE_WARMUP_SECONDS {
            self.last = Some(ObservationSnapshot { observation });
            self.pressure_windows = 0;
            self.clean_windows = 0;
            return Ok(self.decision(false));
        }
        self.warmup_complete = true;

        if elapsed < MIN_UPDATE_INTERVAL_SECONDS {
            return Ok(self.decision(false));
        }

        // Keep the start of the active measurement window until the window
        // is complete.  Source callbacks can arrive every few milliseconds;
        // advancing this baseline for every callback would prevent a 200 ms
        // window from ever accumulating.
        self.last = Some(ObservationSnapshot { observation });

        let output_delta = observation
            .output_frame_count
            .saturating_sub(previous.observation.output_frame_count);
        let pending_drop_delta = observation
            .pending_drop_count
            .saturating_sub(previous.observation.pending_drop_count);
        let source_rate = source_delta as f64 / elapsed;
        let output_rate = output_delta as f64 / elapsed;
        let enough_source_samples = source_delta >= MIN_SOURCE_SAMPLES_PER_WINDOW;
        let source_is_ahead = enough_source_samples
            && source_rate > output_rate + RATE_DEADBAND_FPS.max(source_rate * RATE_DEADBAND_RATIO);
        // Source callbacks remain at the ScreenCaptureKit ceiling after the
        // pacer intentionally lowers encoder admission.  Callback latency by
        // itself would therefore keep interpreting that intentional gap as
        // pressure and walk every target down to the floor.  Only an actual
        // encoder pending/admission drop proves that the current target still
        // exceeds capacity.  Output rate remains the sustainable-rate input
        // once that pressure is proven.
        let under_encoder_pressure = source_is_ahead && pending_drop_delta > 0;

        let previous_target = self.target;
        if under_encoder_pressure {
            self.clean_windows = 0;
            self.pressure_windows = self.pressure_windows.saturating_add(1);
            if self.pressure_windows >= PRESSURE_WINDOWS_BEFORE_DECREASE {
                self.pressure_windows = 0;
                self.target =
                    pressure_target(previous_target, self.floor, output_delta, output_rate);
            }
        } else if pending_drop_delta == 0 {
            self.pressure_windows = 0;
            self.clean_windows = self.clean_windows.saturating_add(1);
            if self.clean_windows >= CLEAN_WINDOWS_BEFORE_PROBE && self.target < self.ceiling {
                let step = (self.ceiling / PROBE_STEP_DIVISOR).max(1);
                self.target = self.target.saturating_add(step).min(self.ceiling);
                self.clean_windows = 0;
            }
        } else {
            self.pressure_windows = 0;
            self.clean_windows = 0;
        }

        Ok(self.decision(self.target != previous_target))
    }
}

fn validate_observation(
    observation: LumenAdaptiveFrameCadenceObservation,
) -> Result<(), LumenEngineStatus> {
    if !observation.monotonic_time_seconds.is_finite()
        || observation.monotonic_time_seconds < 0.0
        || !observation.callback_latency_milliseconds.is_finite()
        || observation.callback_latency_milliseconds < 0.0
    {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    Ok(())
}

fn pressure_target(current_target: u32, floor: u32, output_delta: u64, output_rate: f64) -> u32 {
    if current_target <= floor {
        return floor;
    }

    // Backpressure can be noisy (and zero output has no sustainable-rate
    // estimate), so one pressure decision may reduce the target by at most a
    // quarter of its current value.  A later sustained pressure window may
    // reduce it again; a large ceiling cannot jump directly to the floor from
    // one sparse/zero-output window.
    let maximum_reduction = (f64::from(current_target) * MAX_DECREASE_RATIO).floor() as u32;
    let bounded_lower_target = current_target.saturating_sub(maximum_reduction).max(floor);
    let sustainable_target = if output_delta >= MIN_OUTPUT_SAMPLES_FOR_SUSTAINABLE_RATE {
        (output_rate.max(0.0) * SUSTAINABLE_OUTPUT_MARGIN).round() as u32
    } else {
        bounded_lower_target
    };
    sustainable_target.clamp(bounded_lower_target, current_target)
}

/// Opaque, thread-safe adaptive frame-cadence controller.
pub struct LumenAdaptiveFrameCadenceController {
    inner: Mutex<AdaptiveFrameCadenceState>,
}

impl LumenAdaptiveFrameCadenceController {
    /// Creates a controller whose target starts at the negotiated frame-rate
    /// ceiling.
    pub fn new(request: LumenAdaptiveFrameCadenceRequest) -> Result<Self, LumenEngineStatus> {
        AdaptiveFrameCadenceState::new(request).map(|state| Self {
            inner: Mutex::new(state),
        })
    }

    /// Records one cumulative source/encoder observation and returns the
    /// current source scheduling target.
    pub fn observe(
        &self,
        observation: LumenAdaptiveFrameCadenceObservation,
    ) -> Result<LumenAdaptiveFrameCadenceDecision, LumenEngineStatus> {
        self.inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?
            .observe(observation)
    }

    /// Returns the current source scheduling target without consuming an
    /// observation.
    pub fn target(&self) -> Result<u32, LumenEngineStatus> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?
            .target)
    }
}

/// Creates a cadence controller.  The returned pointer remains valid until
/// [`lumen_engine_adaptive_frame_cadence_destroy`] is called.  No pointer is
/// retained from `request`.
#[no_mangle]
pub extern "C" fn lumen_engine_adaptive_frame_cadence_create(
    request: LumenAdaptiveFrameCadenceRequest,
    controller_out: *mut *mut LumenAdaptiveFrameCadenceController,
) -> LumenEngineStatus {
    let Some(mut controller_out) = NonNull::new(controller_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        LumenAdaptiveFrameCadenceController::new(request)
    })) {
        Ok(Ok(controller)) => {
            let controller = Box::into_raw(Box::new(controller));
            unsafe { *controller_out.as_mut() = controller };
            LumenEngineStatus::Ok
        }
        Ok(Err(status)) => status,
        Err(_) => LumenEngineStatus::Panic,
    }
}

/// Destroys a controller created by
/// [`lumen_engine_adaptive_frame_cadence_create`].  `controller` may be null;
/// a non-null value must not be used again after this call.
///
/// # Safety
///
/// `controller` must be null or a pointer previously returned through
/// [`lumen_engine_adaptive_frame_cadence_create`] that has not already been
/// destroyed. No other thread may access the controller while it is being
/// destroyed.
#[no_mangle]
pub unsafe extern "C" fn lumen_engine_adaptive_frame_cadence_destroy(
    controller: *mut LumenAdaptiveFrameCadenceController,
) {
    if !controller.is_null() {
        drop(unsafe { Box::from_raw(controller) });
    }
}

/// Records one cumulative observation and writes the current scheduling
/// decision.  `controller` and `decision_out` must be valid for the duration
/// of this call.  The function catches Rust panics and never unwinds across
/// the C ABI boundary.
#[no_mangle]
pub extern "C" fn lumen_engine_adaptive_frame_cadence_observe(
    controller: *mut LumenAdaptiveFrameCadenceController,
    observation: LumenAdaptiveFrameCadenceObservation,
    decision_out: *mut LumenAdaptiveFrameCadenceDecision,
) -> LumenEngineStatus {
    let Some(controller) = NonNull::new(controller) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut decision_out) = NonNull::new(decision_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let controller = unsafe { controller.as_ref() };
        let decision = controller.observe(observation)?;
        unsafe { *decision_out.as_mut() = decision };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

/// Reads the current target without consuming an observation.  The output
/// pointer must be valid for the duration of this call.  This is useful when
/// a host needs to apply the target on a different scheduling thread.
#[no_mangle]
pub extern "C" fn lumen_engine_adaptive_frame_cadence_target(
    controller: *const LumenAdaptiveFrameCadenceController,
    target_out: *mut u32,
) -> LumenEngineStatus {
    let Some(controller) = NonNull::new(controller.cast_mut()) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut target_out) = NonNull::new(target_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let target = unsafe { controller.as_ref() }.target()?;
        unsafe { *target_out.as_mut() = target };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn observation(
        time: f64,
        source: u64,
        output: u64,
        drops: u64,
        callback_latency: f64,
    ) -> LumenAdaptiveFrameCadenceObservation {
        LumenAdaptiveFrameCadenceObservation {
            monotonic_time_seconds: time,
            source_frame_count: source,
            output_frame_count: output,
            pending_drop_count: drops,
            pipeline_stable: true,
            callback_latency_milliseconds: callback_latency,
        }
    }

    fn unstable_observation(
        time: f64,
        source: u64,
        output: u64,
        drops: u64,
        callback_latency: f64,
    ) -> LumenAdaptiveFrameCadenceObservation {
        LumenAdaptiveFrameCadenceObservation {
            pipeline_stable: false,
            ..observation(time, source, output, drops, callback_latency)
        }
    }

    fn state() -> AdaptiveFrameCadenceState {
        AdaptiveFrameCadenceState::new(LumenAdaptiveFrameCadenceRequest {
            requested_frame_rate: 120,
        })
        .unwrap()
    }

    #[test]
    fn starts_at_the_negotiated_ceiling_and_waits_for_a_window() {
        let mut state = state();
        assert_eq!(
            state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap(),
            LumenAdaptiveFrameCadenceDecision {
                target_frame_rate: 120,
                changed: false,
            }
        );
        assert_eq!(
            state.observe(observation(1.1, 12, 12, 0, 0.0)).unwrap(),
            LumenAdaptiveFrameCadenceDecision {
                target_frame_rate: 120,
                changed: false,
            }
        );
    }

    #[test]
    fn frequent_observations_coalesce_into_one_adaptive_window() {
        let mut state = state();
        state.observe(observation(0.0, 0, 0, 0, 0.0)).unwrap();

        let mut changed_at = None;
        for frame in 1..=320_u64 {
            let decision = state
                .observe(observation(
                    frame as f64 * 0.008,
                    frame,
                    frame / 2,
                    frame,
                    40.0,
                ))
                .unwrap();
            if decision.changed {
                changed_at = Some(frame);
                break;
            }
            assert_eq!(decision.target_frame_rate, 120);
        }

        assert!(changed_at.expect("two completed pressure windows") >= 150);
        assert!(state.target < state.ceiling);
    }

    #[test]
    fn static_or_idle_source_without_drops_stays_at_the_ceiling() {
        let mut state = state();
        state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        let decision = state.observe(observation(1.3, 0, 0, 0, 0.0)).unwrap();
        assert_eq!(decision.target_frame_rate, 120);
        assert!(!decision.changed);
    }

    #[test]
    fn pressure_requires_source_ahead_and_encoder_evidence() {
        let mut state = state();
        state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();

        let no_encoder_evidence = state.observe(observation(2.1, 36, 30, 0, 0.0)).unwrap();
        assert_eq!(no_encoder_evidence.target_frame_rate, 120);

        let first_callback_window = state.observe(observation(2.4, 72, 60, 0, 40.0)).unwrap();
        assert_eq!(first_callback_window.target_frame_rate, 120);
        assert!(!first_callback_window.changed);

        let callback_latency_only = state.observe(observation(2.7, 108, 90, 0, 40.0)).unwrap();
        assert_eq!(callback_latency_only.target_frame_rate, 120);
        assert!(!callback_latency_only.changed);

        let first_drop_window = state.observe(observation(3.0, 144, 108, 1, 40.0)).unwrap();
        assert_eq!(first_drop_window.target_frame_rate, 120);
        assert!(!first_drop_window.changed);

        let sustained_admission_pressure =
            state.observe(observation(3.3, 180, 126, 2, 40.0)).unwrap();
        assert!(sustained_admission_pressure.target_frame_rate < 120);
        assert!(sustained_admission_pressure.changed);
    }

    #[test]
    fn pressure_moves_fast_toward_sustainable_output_but_respects_floor() {
        let mut state = state();
        state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        let first_pressure = state.observe(observation(2.1, 36, 18, 1, 40.0)).unwrap();
        assert_eq!(first_pressure.target_frame_rate, 120);
        assert!(!first_pressure.changed);

        let decision = state.observe(observation(2.4, 72, 36, 2, 40.0)).unwrap();
        assert_eq!(decision.target_frame_rate, 90);
        assert!(decision.changed);

        let hold_down = state.observe(observation(2.7, 108, 36, 3, 40.0)).unwrap();
        assert_eq!(hold_down.target_frame_rate, 90);
        assert!(!hold_down.changed);

        let next_pressure = state.observe(observation(3.0, 144, 36, 4, 40.0)).unwrap();
        assert_eq!(next_pressure.target_frame_rate, 68);
        assert!(next_pressure.changed);

        let bounded_again = state.observe(observation(3.3, 180, 36, 5, 40.0)).unwrap();
        assert_eq!(bounded_again.target_frame_rate, 68);

        let floor = state.observe(observation(3.6, 216, 36, 6, 40.0)).unwrap();
        assert_eq!(floor.target_frame_rate, 51);
        assert!(floor.changed);

        let floor_stable = state.observe(observation(3.9, 252, 36, 7, 40.0)).unwrap();
        assert_eq!(floor_stable.target_frame_rate, 51);
    }

    #[test]
    fn clean_windows_probe_slowly_back_to_ceiling() {
        let mut state = state();
        state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        state.observe(observation(2.1, 36, 18, 1, 40.0)).unwrap();
        state.observe(observation(2.4, 72, 36, 2, 40.0)).unwrap();
        assert!(state.target < state.ceiling);

        let first_clean = state.observe(observation(2.7, 90, 54, 2, 0.0)).unwrap();
        assert_eq!(first_clean.target_frame_rate, state.target);
        let target_before_probe = state.target;
        for window in 2..CLEAN_WINDOWS_BEFORE_PROBE {
            let offset = u64::from(window) * 18;
            let clean = state
                .observe(observation(
                    2.4 + f64::from(window) * 0.3,
                    72 + offset,
                    36 + offset,
                    2,
                    0.0,
                ))
                .unwrap();
            assert_eq!(clean.target_frame_rate, target_before_probe);
            assert!(!clean.changed);
        }
        let probe_offset = u64::from(CLEAN_WINDOWS_BEFORE_PROBE) * 18;
        let probe = state
            .observe(observation(
                2.4 + f64::from(CLEAN_WINDOWS_BEFORE_PROBE) * 0.3,
                72 + probe_offset,
                36 + probe_offset,
                2,
                0.0,
            ))
            .unwrap();
        assert_eq!(probe.target_frame_rate, target_before_probe + 5);
        assert!(probe.changed);
    }

    #[test]
    fn unstable_bootstrap_windows_rebase_and_get_a_stable_warmup() {
        let mut state = state();
        state
            .observe(unstable_observation(1.0, 0, 0, 0, 80.0))
            .unwrap();
        state
            .observe(unstable_observation(1.3, 100, 0, 20, 80.0))
            .unwrap();

        // The first stable sample starts a new epoch; bootstrap counters and
        // stale latency cannot become the first pressure window.
        let stable_start = state.observe(observation(1.6, 100, 0, 20, 80.0)).unwrap();
        assert_eq!(stable_start.target_frame_rate, 120);
        assert!(!stable_start.changed);

        let warmup = state.observe(observation(2.3, 136, 18, 21, 80.0)).unwrap();
        assert_eq!(warmup.target_frame_rate, 120);
        assert!(!warmup.changed);

        // Sustained pressure only begins after the one-second stable epoch.
        let first_pressure = state.observe(observation(2.7, 172, 36, 22, 80.0)).unwrap();
        assert_eq!(first_pressure.target_frame_rate, 120);
        assert!(!first_pressure.changed);
        let second_pressure = state.observe(observation(3.0, 208, 54, 23, 80.0)).unwrap();
        assert!(second_pressure.changed);
        assert!(second_pressure.target_frame_rate < 120);
    }

    #[test]
    fn sparse_or_zero_output_never_jumps_to_the_floor() {
        let mut sparse_state = state();
        sparse_state
            .observe(observation(1.0, 0, 0, 0, 0.0))
            .unwrap();

        // Sparse source samples are not enough to establish a pressure
        // window, even when a drop counter changed.
        sparse_state
            .observe(observation(2.1, 1, 0, 1, 80.0))
            .unwrap();
        let sparse = sparse_state
            .observe(observation(2.4, 2, 0, 2, 80.0))
            .unwrap();
        assert_eq!(sparse.target_frame_rate, 120);
        assert!(!sparse.changed);

        // Zero output has no sustainable-rate estimate.  It still takes two
        // real drop windows to react, and one reaction is bounded to 25%.
        let mut zero_output = state();
        zero_output.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        zero_output
            .observe(observation(2.1, 36, 0, 1, 80.0))
            .unwrap();
        let bounded = zero_output
            .observe(observation(2.4, 72, 0, 2, 80.0))
            .unwrap();
        assert_eq!(bounded.target_frame_rate, 90);
        assert!(bounded.target_frame_rate > FRAME_RATE_FLOOR);
        assert!(120 - bounded.target_frame_rate <= 30);
    }

    #[test]
    fn stale_latency_without_new_output_allows_clean_recovery() {
        let mut state = state();
        state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        state.observe(observation(2.1, 36, 18, 1, 80.0)).unwrap();
        let downshift = state.observe(observation(2.4, 72, 36, 2, 80.0)).unwrap();
        assert_eq!(downshift.target_frame_rate, 90);

        // The callback latency remains high, but output_delta is zero.  The
        // value is stale and must not prevent clean-window recovery.
        let mut decision = LumenAdaptiveFrameCadenceDecision::default();
        for window in 0..CLEAN_WINDOWS_BEFORE_PROBE {
            decision = state
                .observe(observation(
                    2.7 + f64::from(window) * 0.3,
                    90 + u64::from(window) * 18,
                    36,
                    2,
                    80.0,
                ))
                .unwrap();
        }
        assert!(decision.changed);
        assert_eq!(decision.target_frame_rate, 95);
    }

    #[test]
    fn periodic_unstable_rebases_preserve_completed_warmup_and_clean_recovery() {
        let mut state = state();
        state.observe(observation(0.0, 0, 0, 0, 0.0)).unwrap();
        // Complete the one-time stable warmup, then create a lower target.
        state.observe(observation(1.1, 36, 36, 0, 0.0)).unwrap();
        state.observe(observation(1.4, 72, 36, 1, 80.0)).unwrap();
        assert_eq!(
            state
                .observe(observation(1.7, 108, 54, 2, 80.0))
                .unwrap()
                .target_frame_rate,
            90
        );

        let mut source = 108;
        let mut output = 54;
        let mut decision = LumenAdaptiveFrameCadenceDecision::default();
        for window in 0..CLEAN_WINDOWS_BEFORE_PROBE {
            source += 18;
            output += 18;
            let time = 2.0 + f64::from(window) * 0.4;
            decision = state
                .observe(observation(time, source, output, 2, 0.0))
                .unwrap();

            if window + 1 < CLEAN_WINDOWS_BEFORE_PROBE {
                // A periodic/repair bootstrap briefly closes the gate.  It
                // rebases the next stable sample but must not restart the
                // completed warmup or erase clean recovery progress.
                state
                    .observe(unstable_observation(time + 0.05, source, output, 2, 0.0))
                    .unwrap();
                state
                    .observe(observation(time + 0.10, source, output, 2, 0.0))
                    .unwrap();
            }
        }
        assert!(decision.changed);
        assert_eq!(decision.target_frame_rate, 95);
    }

    #[test]
    fn idle_activity_restores_ceiling_without_synthesizing_frames() {
        let mut state = state();
        state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        state.observe(observation(2.1, 36, 18, 1, 80.0)).unwrap();
        let downshift = state.observe(observation(2.4, 72, 36, 2, 80.0)).unwrap();
        assert_eq!(downshift.target_frame_rate, 90);

        // No source callback during the idle interval means no observation and
        // no synthetic output.  An explicit idle observation still stays at
        // the lower target.
        let idle = state.observe(observation(4.0, 72, 36, 2, 80.0)).unwrap();
        assert_eq!(idle.target_frame_rate, 90);
        assert!(!idle.changed);

        // The first callback after the long gap immediately restores the
        // negotiated ceiling, even though this one callback is sparse.
        let activity = state.observe(observation(6.0, 73, 36, 2, 80.0)).unwrap();
        assert_eq!(activity.target_frame_rate, 120);
        assert!(activity.changed);
    }

    #[test]
    fn floor_low_ceiling_and_invalid_inputs_are_deterministic() {
        let mut low_ceiling = AdaptiveFrameCadenceState::new(LumenAdaptiveFrameCadenceRequest {
            requested_frame_rate: 10,
        })
        .unwrap();
        assert_eq!(low_ceiling.target, 10);
        low_ceiling.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        low_ceiling
            .observe(observation(2.1, 36, 0, 1, 80.0))
            .unwrap();
        let floor = low_ceiling
            .observe(observation(2.4, 72, 0, 2, 80.0))
            .unwrap();
        assert_eq!(floor.target_frame_rate, 10);
        assert!(!floor.changed);

        let mut sparse_low_ceiling =
            AdaptiveFrameCadenceState::new(LumenAdaptiveFrameCadenceRequest {
                requested_frame_rate: 20,
            })
            .unwrap();
        sparse_low_ceiling
            .observe(observation(1.0, 0, 0, 0, 0.0))
            .unwrap();
        sparse_low_ceiling
            .observe(observation(2.1, 36, 0, 1, 80.0))
            .unwrap();
        let sparse_floor = sparse_low_ceiling
            .observe(observation(2.4, 72, 0, 2, 80.0))
            .unwrap();
        assert_eq!(sparse_floor.target_frame_rate, 15);
        assert!(sparse_floor.target_frame_rate >= FRAME_RATE_FLOOR);

        let mut invalid = state();
        assert_eq!(
            invalid.observe(observation(f64::NAN, 0, 0, 0, 0.0)),
            Err(LumenEngineStatus::InvalidArgument)
        );
        assert_eq!(
            invalid.observe(observation(1.0, 0, 0, 0, -1.0)),
            Err(LumenEngineStatus::InvalidArgument)
        );
        assert_eq!(invalid.target, 120);
    }

    #[test]
    fn cadence_abi_version_and_observation_layout_stay_in_sync() {
        assert_eq!(crate::ABI_VERSION, 68);
        assert_eq!(crate::lumen_engine_abi_version(), 68);
        assert_eq!(
            std::mem::size_of::<LumenAdaptiveFrameCadenceObservation>(),
            48
        );
    }

    #[test]
    fn stale_clock_or_counter_is_rejected_without_mutating_state() {
        let mut state = state();
        state.observe(observation(1.0, 10, 10, 0, 0.0)).unwrap();
        let result = state.observe(observation(0.9, 11, 11, 0, 0.0));
        assert_eq!(result, Err(LumenEngineStatus::InvalidArgument));
        assert_eq!(state.target, 120);
    }

    #[test]
    fn ffi_catches_bad_pointers_and_invalid_configuration() {
        assert_eq!(
            lumen_engine_adaptive_frame_cadence_create(
                LumenAdaptiveFrameCadenceRequest::default(),
                std::ptr::null_mut(),
            ),
            LumenEngineStatus::InvalidArgument
        );
        let mut controller = std::ptr::null_mut();
        assert_eq!(
            lumen_engine_adaptive_frame_cadence_create(
                LumenAdaptiveFrameCadenceRequest {
                    requested_frame_rate: 120
                },
                &mut controller,
            ),
            LumenEngineStatus::Ok
        );
        assert_eq!(
            lumen_engine_adaptive_frame_cadence_observe(
                controller,
                observation(1.0, 0, 0, 0, 0.0),
                std::ptr::null_mut(),
            ),
            LumenEngineStatus::InvalidArgument
        );
        let mut target = 0;
        assert_eq!(
            lumen_engine_adaptive_frame_cadence_target(controller, &mut target),
            LumenEngineStatus::Ok
        );
        assert_eq!(target, 120);
        unsafe { lumen_engine_adaptive_frame_cadence_destroy(controller) };
    }
}
