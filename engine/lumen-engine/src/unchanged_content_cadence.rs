//! Host-side cadence policy for an unchanged ScreenCaptureKit surface.
//!
//! This controller deliberately consumes content metadata rather than pixels.
//! ScreenCaptureKit already tells the host whether a sample is idle and, when
//! available, which damage rectangles were produced.  A static display can
//! therefore enter a bounded two-frame-per-second refresh without hashing a
//! 4K surface on the capture callback.  The negotiated rate remains the
//! ceiling; activity or an untrusted metadata sample reopens the ceiling and
//! starts a fresh confirmation epoch.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::NonNull;
use std::sync::Mutex;

use crate::LumenEngineStatus;

const LOW_FRAME_RATE: u32 = 2;
const IDLE_CONFIRMATION_SECONDS: f64 = 1.0;

/// Validated content metadata classification used inside the controller.
///
/// The C boundary carries a raw `u32` instead of a Rust `repr(C)` enum. C
/// callers can provide a future/unknown discriminant, and converting that
/// value to a Rust enum before validation would be undefined behavior. Unknown
/// raw values therefore map to this fail-open variant.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum ContentCadenceSignal {
    #[default]
    Unknown,
    Changed,
    Unchanged,
    Idle,
}

impl ContentCadenceSignal {
    fn from_raw(raw: u32) -> Self {
        match raw {
            1 => Self::Changed,
            2 => Self::Unchanged,
            3 => Self::Idle,
            _ => Self::Unknown,
        }
    }
}

/// Configuration for one unchanged-content cadence controller.
///
/// `requested_frame_rate` is the negotiated ceiling.  The low-rate target is
/// intentionally fixed at two frames per second so all host adapters share
/// the same bounded idle behavior.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenContentCadenceRequest {
    pub requested_frame_rate: u32,
}

/// One cumulative content observation from the host capture adapter.
///
/// `monotonic_time_seconds` must use one monotonic clock for the lifetime of a
/// controller.  `pipeline_stable` must be false while capture bootstrap,
/// reconfiguration, or a media-epoch boundary is unsettled.  Unstable or
/// unknown observations rebase the confirmation epoch and keep cadence at the
/// negotiated ceiling.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LumenContentCadenceObservation {
    pub monotonic_time_seconds: f64,
    /// One of the `LumenContentCadenceSignal*` constants from the C header.
    /// Unknown values fail open.
    pub signal: u32,
    pub pipeline_stable: bool,
}

/// Result of recording one content observation or external activity wake.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct LumenContentCadenceDecision {
    pub target_frame_rate: u32,
    pub changed: bool,
    pub low_rate_active: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum ContentCadenceMode {
    #[default]
    Active,
    LowRate,
}

#[derive(Debug)]
struct ContentCadenceState {
    ceiling: u32,
    target: u32,
    mode: ContentCadenceMode,
    last_time_seconds: Option<f64>,
    idle_since_seconds: Option<f64>,
}

impl ContentCadenceState {
    fn new(request: LumenContentCadenceRequest) -> Result<Self, LumenEngineStatus> {
        if request.requested_frame_rate == 0 {
            return Err(LumenEngineStatus::InvalidArgument);
        }

        Ok(Self {
            ceiling: request.requested_frame_rate,
            target: request.requested_frame_rate,
            mode: ContentCadenceMode::Active,
            last_time_seconds: None,
            idle_since_seconds: None,
        })
    }

    fn decision(&self, changed: bool) -> LumenContentCadenceDecision {
        LumenContentCadenceDecision {
            target_frame_rate: self.target,
            changed,
            low_rate_active: self.mode == ContentCadenceMode::LowRate,
        }
    }

    fn observe(
        &mut self,
        observation: LumenContentCadenceObservation,
    ) -> Result<LumenContentCadenceDecision, LumenEngineStatus> {
        validate_time(observation.monotonic_time_seconds)?;
        self.validate_monotonic_time(observation.monotonic_time_seconds)?;

        let previous_target = self.target;
        self.last_time_seconds = Some(observation.monotonic_time_seconds);

        // A closed bootstrap/reconfiguration gate or an untrusted metadata
        // value must fail open.  Clearing the confirmation epoch prevents a
        // long unstable interval from immediately entering low rate on the
        // first callback after a repair.
        let signal = ContentCadenceSignal::from_raw(observation.signal);
        if !observation.pipeline_stable || signal == ContentCadenceSignal::Unknown {
            self.rebase_active();
            return Ok(self.decision(self.target != previous_target));
        }

        match signal {
            ContentCadenceSignal::Changed => {
                self.rebase_active();
            }
            ContentCadenceSignal::Idle | ContentCadenceSignal::Unchanged => {
                let idle_since = *self
                    .idle_since_seconds
                    .get_or_insert(observation.monotonic_time_seconds);
                if observation.monotonic_time_seconds - idle_since >= IDLE_CONFIRMATION_SECONDS {
                    self.mode = ContentCadenceMode::LowRate;
                    self.target = self.ceiling.min(LOW_FRAME_RATE);
                }
            }
            ContentCadenceSignal::Unknown => {
                // Handled above; keep this arm explicit so a future enum
                // extension cannot accidentally become a lowering signal.
                self.rebase_active();
            }
        }

        Ok(self.decision(self.target != previous_target))
    }

    fn wake(
        &mut self,
        monotonic_time_seconds: f64,
    ) -> Result<LumenContentCadenceDecision, LumenEngineStatus> {
        validate_time(monotonic_time_seconds)?;
        self.validate_monotonic_time(monotonic_time_seconds)?;

        let previous_target = self.target;
        self.last_time_seconds = Some(monotonic_time_seconds);
        self.rebase_active();
        Ok(self.decision(self.target != previous_target))
    }

    fn validate_monotonic_time(&self, time: f64) -> Result<(), LumenEngineStatus> {
        if self
            .last_time_seconds
            .is_some_and(|previous| time < previous)
        {
            return Err(LumenEngineStatus::InvalidArgument);
        }
        Ok(())
    }

    fn rebase_active(&mut self) {
        self.mode = ContentCadenceMode::Active;
        self.target = self.ceiling;
        self.idle_since_seconds = None;
    }
}

fn validate_time(time: f64) -> Result<(), LumenEngineStatus> {
    if !time.is_finite() || time < 0.0 {
        return Err(LumenEngineStatus::InvalidArgument);
    }
    Ok(())
}

/// Opaque, thread-safe unchanged-content cadence controller.
pub struct LumenContentCadenceController {
    inner: Mutex<ContentCadenceState>,
}

impl LumenContentCadenceController {
    pub fn new(request: LumenContentCadenceRequest) -> Result<Self, LumenEngineStatus> {
        ContentCadenceState::new(request).map(|state| Self {
            inner: Mutex::new(state),
        })
    }

    pub fn observe(
        &self,
        observation: LumenContentCadenceObservation,
    ) -> Result<LumenContentCadenceDecision, LumenEngineStatus> {
        self.inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?
            .observe(observation)
    }

    pub fn wake(
        &self,
        monotonic_time_seconds: f64,
    ) -> Result<LumenContentCadenceDecision, LumenEngineStatus> {
        self.inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?
            .wake(monotonic_time_seconds)
    }

    pub fn target(&self) -> Result<u32, LumenEngineStatus> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| LumenEngineStatus::InvalidState)?
            .target)
    }
}

/// Creates an unchanged-content cadence controller.  The returned pointer
/// remains valid until [`lumen_engine_content_cadence_destroy`] is called.
#[no_mangle]
pub extern "C" fn lumen_engine_content_cadence_create(
    request: LumenContentCadenceRequest,
    controller_out: *mut *mut LumenContentCadenceController,
) -> LumenEngineStatus {
    let Some(mut controller_out) = NonNull::new(controller_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        LumenContentCadenceController::new(request)
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
/// [`lumen_engine_content_cadence_create`].
///
/// # Safety
///
/// `controller` must be null or a live pointer previously returned by
/// [`lumen_engine_content_cadence_create`] that has not already been
/// destroyed. No other thread may access it while it is destroyed.
#[no_mangle]
pub unsafe extern "C" fn lumen_engine_content_cadence_destroy(
    controller: *mut LumenContentCadenceController,
) {
    if !controller.is_null() {
        drop(unsafe { Box::from_raw(controller) });
    }
}

/// Records content metadata and writes the current scheduling decision.
#[no_mangle]
pub extern "C" fn lumen_engine_content_cadence_observe(
    controller: *mut LumenContentCadenceController,
    observation: LumenContentCadenceObservation,
    decision_out: *mut LumenContentCadenceDecision,
) -> LumenEngineStatus {
    let Some(controller) = NonNull::new(controller) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut decision_out) = NonNull::new(decision_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let decision = unsafe { controller.as_ref() }.observe(observation)?;
        unsafe { *decision_out.as_mut() = decision };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

/// Reopens the negotiated ceiling after a validated reliable host input or
/// motion event and starts a fresh unchanged-content confirmation epoch.
#[no_mangle]
pub extern "C" fn lumen_engine_content_cadence_wake(
    controller: *mut LumenContentCadenceController,
    monotonic_time_seconds: f64,
    decision_out: *mut LumenContentCadenceDecision,
) -> LumenEngineStatus {
    let Some(controller) = NonNull::new(controller) else {
        return LumenEngineStatus::InvalidArgument;
    };
    let Some(mut decision_out) = NonNull::new(decision_out) else {
        return LumenEngineStatus::InvalidArgument;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let decision = unsafe { controller.as_ref() }.wake(monotonic_time_seconds)?;
        unsafe { *decision_out.as_mut() = decision };
        Ok::<(), LumenEngineStatus>(())
    }))
    .map_or(LumenEngineStatus::Panic, |result| {
        result.map_or_else(|status| status, |_| LumenEngineStatus::Ok)
    })
}

/// Reads the current content cadence target without consuming an observation.
#[no_mangle]
pub extern "C" fn lumen_engine_content_cadence_target(
    controller: *const LumenContentCadenceController,
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

    fn raw_signal(signal: ContentCadenceSignal) -> u32 {
        match signal {
            ContentCadenceSignal::Unknown => 0,
            ContentCadenceSignal::Changed => 1,
            ContentCadenceSignal::Unchanged => 2,
            ContentCadenceSignal::Idle => 3,
        }
    }

    fn observation(time: f64, signal: ContentCadenceSignal) -> LumenContentCadenceObservation {
        LumenContentCadenceObservation {
            monotonic_time_seconds: time,
            signal: raw_signal(signal),
            pipeline_stable: true,
        }
    }

    fn state() -> ContentCadenceState {
        ContentCadenceState::new(LumenContentCadenceRequest {
            requested_frame_rate: 120,
        })
        .unwrap()
    }

    #[test]
    fn idle_content_requires_one_second_confirmation_before_two_fps() {
        let mut state = state();
        assert_eq!(
            state
                .observe(observation(1.0, ContentCadenceSignal::Idle))
                .unwrap()
                .target_frame_rate,
            120
        );
        let before_confirmation = state
            .observe(observation(1.99, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(before_confirmation.target_frame_rate, 120);
        assert!(!before_confirmation.changed);

        let confirmed = state
            .observe(observation(2.0, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(confirmed.target_frame_rate, 2);
        assert!(confirmed.changed);
        assert!(confirmed.low_rate_active);

        let held = state
            .observe(observation(10.0, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(held.target_frame_rate, 2);
        assert!(!held.changed);
        assert!(held.low_rate_active);

        let mut low_ceiling = ContentCadenceState::new(LumenContentCadenceRequest {
            requested_frame_rate: 1,
        })
        .unwrap();
        low_ceiling
            .observe(observation(0.0, ContentCadenceSignal::Idle))
            .unwrap();
        let low_decision = low_ceiling
            .observe(observation(1.0, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(low_decision.target_frame_rate, 1);
        assert!(low_decision.low_rate_active);
    }

    #[test]
    fn changed_content_immediately_wakes_and_rebases_confirmation() {
        let mut state = state();
        state
            .observe(observation(0.0, ContentCadenceSignal::Idle))
            .unwrap();
        state
            .observe(observation(1.0, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(state.target, 2);

        let changed = state
            .observe(observation(1.01, ContentCadenceSignal::Changed))
            .unwrap();
        assert_eq!(changed.target_frame_rate, 120);
        assert!(changed.changed);
        assert!(!changed.low_rate_active);

        let not_yet_confirmed = state
            .observe(observation(1.99, ContentCadenceSignal::Unchanged))
            .unwrap();
        assert_eq!(not_yet_confirmed.target_frame_rate, 120);
        assert!(!not_yet_confirmed.changed);
        state
            .observe(observation(2.99, ContentCadenceSignal::Unchanged))
            .unwrap();
        assert_eq!(state.target, 2);

        let wake = state.wake(3.0).unwrap();
        assert_eq!(wake.target_frame_rate, 120);
        assert!(wake.changed);
        assert!(!wake.low_rate_active);

        let not_yet_confirmed = state
            .observe(observation(3.99, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(not_yet_confirmed.target_frame_rate, 120);
        assert!(!not_yet_confirmed.changed);
    }

    #[test]
    fn unknown_or_unstable_metadata_fails_open_and_rebases() {
        let mut state = state();
        state
            .observe(observation(0.0, ContentCadenceSignal::Idle))
            .unwrap();
        state
            .observe(observation(1.0, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(state.target, 2);

        let mut unstable = observation(1.01, ContentCadenceSignal::Idle);
        unstable.pipeline_stable = false;
        let decision = state.observe(unstable).unwrap();
        assert_eq!(decision.target_frame_rate, 120);
        assert!(decision.changed);

        let unknown = state
            .observe(observation(1.02, ContentCadenceSignal::Unknown))
            .unwrap();
        assert_eq!(unknown.target_frame_rate, 120);
        assert!(!unknown.low_rate_active);

        state
            .observe(observation(2.0, ContentCadenceSignal::Idle))
            .unwrap();
        state
            .observe(observation(3.0, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(state.target, 2);

        let mut invalid = observation(3.01, ContentCadenceSignal::Idle);
        invalid.signal = 99;
        let decision = state.observe(invalid).unwrap();
        assert_eq!(decision.target_frame_rate, 120);
        assert!(decision.changed);
        assert!(!decision.low_rate_active);
    }

    #[test]
    fn invalid_or_stale_time_does_not_mutate_state() {
        let mut state = state();
        state
            .observe(observation(1.0, ContentCadenceSignal::Idle))
            .unwrap();
        assert_eq!(
            state.observe(observation(0.9, ContentCadenceSignal::Changed)),
            Err(LumenEngineStatus::InvalidArgument)
        );
        assert_eq!(state.target, 120);
        assert_eq!(
            state.observe(observation(f64::NAN, ContentCadenceSignal::Idle)),
            Err(LumenEngineStatus::InvalidArgument)
        );
        assert_eq!(state.target, 120);

        assert_eq!(
            lumen_engine_content_cadence_create(
                LumenContentCadenceRequest::default(),
                std::ptr::null_mut(),
            ),
            LumenEngineStatus::InvalidArgument
        );

        let mut controller = std::ptr::null_mut();
        assert_eq!(
            lumen_engine_content_cadence_create(
                LumenContentCadenceRequest {
                    requested_frame_rate: 120,
                },
                &mut controller,
            ),
            LumenEngineStatus::Ok
        );

        assert_eq!(
            lumen_engine_content_cadence_observe(
                controller,
                observation(0.0, ContentCadenceSignal::Unknown),
                std::ptr::null_mut(),
            ),
            LumenEngineStatus::InvalidArgument
        );

        let mut target = 0;
        assert_eq!(
            lumen_engine_content_cadence_target(controller, &mut target),
            LumenEngineStatus::Ok
        );
        assert_eq!(target, 120);
        unsafe { lumen_engine_content_cadence_destroy(controller) };

        assert_eq!(std::mem::size_of::<LumenContentCadenceRequest>(), 4);
        assert_eq!(std::mem::size_of::<LumenContentCadenceObservation>(), 16);
        assert_eq!(std::mem::size_of::<LumenContentCadenceDecision>(), 8);
    }
}
