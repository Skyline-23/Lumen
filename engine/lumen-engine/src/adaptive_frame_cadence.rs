//! Adaptive source cadence policy shared by host capture implementations.
//!
//! The controller treats the negotiated frame rate as a ceiling.  It only
//! lowers the source target when the source is supplying frames faster than
//! the encoder is producing them and either pending admission drops or output
//! callback latency confirms encoder backpressure.  A clean controller slowly
//! probes back toward the negotiated ceiling.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::sync::Mutex;

use crate::LumenEngineStatus;

const MIN_UPDATE_INTERVAL_SECONDS: f64 = 0.20;
const FRAME_RATE_FLOOR: u32 = 15;
const RATE_DEADBAND_FPS: f64 = 2.0;
const RATE_DEADBAND_RATIO: f64 = 0.05;
const PRESSURE_WINDOWS_BEFORE_DECREASE: u8 = 2;
const CLEAN_WINDOWS_BEFORE_PROBE: u8 = 8;
const PROBE_STEP_DIVISOR: u32 = 24;
const SUSTAINABLE_OUTPUT_MARGIN: f64 = 0.95;

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
        if elapsed < MIN_UPDATE_INTERVAL_SECONDS {
            return Ok(self.decision(false));
        }

        // Keep the start of the active measurement window until the window
        // is complete.  Source callbacks can arrive every few milliseconds;
        // advancing this baseline for every callback would prevent a 200 ms
        // window from ever accumulating.
        self.last = Some(ObservationSnapshot { observation });

        let source_delta = observation
            .source_frame_count
            .saturating_sub(previous.observation.source_frame_count);
        let output_delta = observation
            .output_frame_count
            .saturating_sub(previous.observation.output_frame_count);
        let pending_drop_delta = observation
            .pending_drop_count
            .saturating_sub(previous.observation.pending_drop_count);
        let source_rate = source_delta as f64 / elapsed;
        let output_rate = output_delta as f64 / elapsed;
        let source_is_ahead =
            source_rate > output_rate + RATE_DEADBAND_FPS.max(source_rate * RATE_DEADBAND_RATIO);
        let callback_is_slow = observation.callback_latency_milliseconds
            > callback_latency_threshold_milliseconds(self.target);
        let under_encoder_pressure =
            source_is_ahead && (pending_drop_delta > 0 || callback_is_slow);

        let previous_target = self.target;
        if under_encoder_pressure {
            self.clean_windows = 0;
            self.pressure_windows = self.pressure_windows.saturating_add(1);
            if self.pressure_windows >= PRESSURE_WINDOWS_BEFORE_DECREASE {
                self.pressure_windows = 0;
                let sustainable_rate = output_rate.max(0.0);
                let pressure_target = if sustainable_rate > 0.0 {
                    (sustainable_rate * SUSTAINABLE_OUTPUT_MARGIN).round() as u32
                } else {
                    self.floor
                };
                self.target = pressure_target.clamp(self.floor, self.target);
                if self.target == previous_target && self.target > self.floor {
                    self.target = self.target.saturating_sub(1).max(self.floor);
                }
            }
        } else if pending_drop_delta == 0 && !callback_is_slow {
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

fn callback_latency_threshold_milliseconds(ceiling: u32) -> f64 {
    (1_500.0 / f64::from(ceiling)).max(8.0)
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
            callback_latency_milliseconds: callback_latency,
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
        for frame in 1..=64_u64 {
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

        assert!(changed_at.expect("two completed pressure windows") >= 49);
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

        let no_encoder_evidence = state.observe(observation(1.3, 36, 30, 0, 0.0)).unwrap();
        assert_eq!(no_encoder_evidence.target_frame_rate, 120);

        let first_callback_window = state.observe(observation(1.6, 72, 60, 0, 40.0)).unwrap();
        assert_eq!(first_callback_window.target_frame_rate, 120);
        assert!(!first_callback_window.changed);

        let callback_backpressure = state.observe(observation(1.9, 108, 90, 0, 40.0)).unwrap();
        assert!(callback_backpressure.target_frame_rate < 120);
        assert!(callback_backpressure.changed);
    }

    #[test]
    fn pressure_moves_fast_toward_sustainable_output_but_respects_floor() {
        let mut state = state();
        state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        let first_pressure = state.observe(observation(1.3, 36, 18, 1, 40.0)).unwrap();
        assert_eq!(first_pressure.target_frame_rate, 120);
        assert!(!first_pressure.changed);

        let decision = state.observe(observation(1.6, 72, 36, 2, 40.0)).unwrap();
        assert_eq!(decision.target_frame_rate, 57);
        assert!(decision.changed);

        let hold_down = state.observe(observation(1.9, 108, 36, 3, 40.0)).unwrap();
        assert_eq!(hold_down.target_frame_rate, 57);
        assert!(!hold_down.changed);

        let floor = state.observe(observation(2.2, 144, 36, 4, 40.0)).unwrap();
        assert_eq!(floor.target_frame_rate, 15);
        assert!(floor.changed);

        let floor_stable = state.observe(observation(2.5, 180, 36, 5, 40.0)).unwrap();
        assert_eq!(floor_stable.target_frame_rate, 15);
    }

    #[test]
    fn clean_windows_probe_slowly_back_to_ceiling() {
        let mut state = state();
        state.observe(observation(1.0, 0, 0, 0, 0.0)).unwrap();
        state.observe(observation(1.3, 36, 18, 1, 40.0)).unwrap();
        state.observe(observation(1.6, 72, 36, 2, 40.0)).unwrap();
        assert!(state.target < state.ceiling);

        let first_clean = state.observe(observation(1.9, 90, 54, 2, 0.0)).unwrap();
        assert_eq!(first_clean.target_frame_rate, state.target);
        let target_before_probe = state.target;
        for window in 2..CLEAN_WINDOWS_BEFORE_PROBE {
            let offset = u64::from(window) * 18;
            let clean = state
                .observe(observation(
                    1.6 + f64::from(window) * 0.3,
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
                1.6 + f64::from(CLEAN_WINDOWS_BEFORE_PROBE) * 0.3,
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
