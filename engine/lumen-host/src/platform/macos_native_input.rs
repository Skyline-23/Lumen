use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use core_graphics::event::{CGEvent, CGEventTapLocation, EventField, ScrollEventUnit};
use core_graphics::geometry::{CGPoint, CGRect, CGSize};
use lumen_engine::{NativePointerMotionMode, NativeScrollPhase};

use crate::{PlatformNativeInputEvent, PlatformNativeMotionEvent};

#[path = "macos_native_input_events.rs"]
mod events;
#[path = "macos_native_input_motion.rs"]
mod motion;
#[cfg(test)]
#[path = "macos_native_input_tests.rs"]
mod tests;

use events::{
    event_source, post_text, system_double_click_interval, CoreGraphicsMacInputEventPoster,
    MacInputEventPoster,
};
#[cfg(test)]
use events::{mac_key_code, mac_modifier_flags};
#[cfg(test)]
use motion::{pointer_target, preferred_pointer_bounds, remap_preserved_capture_position};
use motion::{post_pointer_motion, MacPointerMotionInput};

const MAX_NATIVE_INPUT_RESET_ATTEMPTS: usize = 2;
#[cfg(test)]
const DEFAULT_DOUBLE_CLICK_INTERVAL: Duration = Duration::from_millis(500);
// The wire protocol carries button edges, not a click count. CoreGraphics therefore needs a
// host-side click sequence. Keep the worker's location tolerance small and axis-aligned, matching
// macOS screen-point semantics without constructing an AppKit UI object on the QUIC worker.
const CLICK_LOCATION_TOLERANCE_POINTS: f64 = 5.0;
const SCROLL_WHEEL_EVENT_SCROLL_PHASE: u32 = 99;
const SCROLL_WHEEL_EVENT_MOMENTUM_PHASE: u32 = 123;

#[derive(Debug, Default)]
struct MacInputState {
    pressed_keys: HashSet<u16>,
    pressed_buttons: HashSet<u8>,
    click_tracker: MacClickTracker,
    compositions: HashMap<u64, MacComposition>,
}

#[derive(Debug, Default)]
struct MacClickTracker {
    last_down: HashMap<u8, MacClickSample>,
    pending: HashMap<u8, MacPendingClick>,
}

#[derive(Clone, Copy, Debug)]
struct MacClickSample {
    at: Instant,
    location: CGPoint,
    click_state: u32,
}

#[derive(Clone, Copy, Debug)]
struct MacPendingClick {
    at: Instant,
    location: CGPoint,
    click_state: u32,
}

impl MacClickTracker {
    fn begin(&mut self, button: u8, location: CGPoint, now: Instant, interval: Duration) -> u32 {
        let click_state = self
            .last_down
            .get(&button)
            .filter(|last| {
                now.checked_duration_since(last.at)
                    .is_some_and(|elapsed| elapsed <= interval)
                    && click_locations_match(last.location, location)
            })
            .map_or(1, |last| last.click_state.saturating_add(1));
        self.pending.insert(
            button,
            MacPendingClick {
                at: now,
                location,
                click_state,
            },
        );
        click_state
    }

    fn pending(&self, button: u8) -> Option<u32> {
        self.pending.get(&button).map(|click| click.click_state)
    }

    fn finish(&mut self, button: u8, click_state: u32) {
        let pending = self
            .pending
            .remove(&button)
            .expect("button click state must be pending before finish");
        debug_assert_eq!(pending.click_state, click_state);
        self.last_down.insert(
            button,
            MacClickSample {
                at: pending.at,
                location: pending.location,
                click_state: pending.click_state,
            },
        );
    }

    fn rollback_begin(&mut self, button: u8) {
        self.pending.remove(&button);
    }

    fn finish_reset(&mut self, button: u8) {
        self.pending.remove(&button);
        self.last_down.remove(&button);
    }
}

fn click_locations_match(first: CGPoint, second: CGPoint) -> bool {
    (first.x - second.x).abs() <= CLICK_LOCATION_TOLERANCE_POINTS
        && (first.y - second.y).abs() <= CLICK_LOCATION_TOLERANCE_POINTS
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MacComposition {
    text: String,
    selection_start_utf8: usize,
    selection_length_utf8: usize,
}

pub(crate) struct MacNativeInput {
    state: Mutex<HashMap<u32, MacInputState>>,
    poster: Arc<dyn MacInputEventPoster>,
    click_interval_override: Option<Duration>,
}

impl Default for MacNativeInput {
    fn default() -> Self {
        Self {
            state: Mutex::default(),
            poster: Arc::new(CoreGraphicsMacInputEventPoster),
            click_interval_override: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct MacInputDisplayBounds {
    pub(crate) width: f64,
    pub(crate) height: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct MacInputCaptureViewport {
    pub(crate) width: f64,
    pub(crate) height: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct MacPositionedButtonInput {
    pub(crate) pointer_id: u32,
    pub(crate) button: u8,
    pub(crate) pressed: bool,
    pub(crate) normalized_x: f32,
    pub(crate) normalized_y: f32,
}

impl MacInputDisplayBounds {
    fn rect(self) -> Option<CGRect> {
        (self.width > 0.0 && self.height > 0.0).then(|| {
            CGRect::new(
                &CGPoint::new(0.0, 0.0),
                &CGSize::new(self.width, self.height),
            )
        })
    }
}

impl MacNativeInput {
    #[cfg(test)]
    fn with_poster(poster: Arc<dyn MacInputEventPoster>) -> Self {
        Self::with_poster_and_click_interval(poster, DEFAULT_DOUBLE_CLICK_INTERVAL)
    }

    #[cfg(test)]
    fn with_poster_and_click_interval(
        poster: Arc<dyn MacInputEventPoster>,
        click_interval_override: Duration,
    ) -> Self {
        Self {
            state: Mutex::default(),
            poster,
            click_interval_override: Some(click_interval_override),
        }
    }

    fn double_click_interval(&self) -> Result<Duration, String> {
        self.click_interval_override
            .map_or_else(system_double_click_interval, Ok)
    }

    pub(crate) fn handle(
        &self,
        session_epoch: u32,
        event: PlatformNativeInputEvent,
    ) -> Result<(), String> {
        self.handle_activity(session_epoch, event).map(|_| ())
    }

    pub(crate) fn handle_activity(
        &self,
        session_epoch: u32,
        event: PlatformNativeInputEvent,
    ) -> Result<bool, String> {
        let mut states = self
            .state
            .lock()
            .map_err(|_| "macOS native input state is unavailable".to_owned())?;
        let state = states.entry(session_epoch).or_default();
        match event {
            PlatformNativeInputEvent::Keyboard {
                hid_usage,
                pressed,
                modifiers,
                repeat,
            } => {
                let was_pressed = state.pressed_keys.contains(&hid_usage);
                if (pressed && was_pressed && !repeat) || (!pressed && !was_pressed) {
                    return Ok(false);
                }
                self.poster
                    .post_key(hid_usage, pressed, modifiers, repeat)?;
                if pressed {
                    state.pressed_keys.insert(hid_usage);
                } else {
                    state.pressed_keys.remove(&hid_usage);
                }
                Ok(true)
            }
            PlatformNativeInputEvent::Text {
                text,
                composition_id,
                commit,
                selection_start_utf8,
                selection_length_utf8,
            } => {
                if commit {
                    state.compositions.remove(&composition_id);
                    if text.is_empty() {
                        Ok(false)
                    } else {
                        post_text(&text).map(|_| true)
                    }
                } else {
                    let composition = MacComposition {
                        text,
                        selection_start_utf8,
                        selection_length_utf8,
                    };
                    if state.compositions.get(&composition_id) != Some(&composition) {
                        state.compositions.insert(composition_id, composition);
                    }
                    Ok(false)
                }
            }
            PlatformNativeInputEvent::PointerButton {
                pointer_id: _,
                button,
                pressed,
                absolute_position: _,
            } => self.handle_pointer_button(state, button, pressed, None),
            PlatformNativeInputEvent::RumbleAcknowledged { .. } => Ok(false),
            PlatformNativeInputEvent::GamepadConnection { .. }
            | PlatformNativeInputEvent::GamepadButton { .. } => {
                Err("macOS virtual gamepad injection is not implemented".to_owned())
            }
            PlatformNativeInputEvent::TouchContact { .. }
            | PlatformNativeInputEvent::PenContact { .. } => {
                Err("macOS native touch and pen injection is not implemented".to_owned())
            }
        }
    }

    pub(crate) fn handle_motion(
        &self,
        session_epoch: u32,
        display_id: u32,
        planned_bounds: Option<MacInputDisplayBounds>,
        capture_viewport: Option<MacInputCaptureViewport>,
        event: PlatformNativeMotionEvent,
    ) -> Result<bool, String> {
        let mut states = self
            .state
            .lock()
            .map_err(|_| "macOS native input state is unavailable".to_owned())?;
        let state = states.entry(session_epoch).or_default();
        match event {
            PlatformNativeMotionEvent::Pointer {
                pointer_id: _,
                mode,
                delta_x,
                delta_y,
                normalized_x,
                normalized_y,
            } => {
                if mode == NativePointerMotionMode::Relative && delta_x == 0 && delta_y == 0 {
                    return Ok(false);
                }
                post_pointer_motion(
                    display_id,
                    planned_bounds,
                    capture_viewport,
                    state,
                    MacPointerMotionInput {
                        mode,
                        delta_x,
                        delta_y,
                        normalized_x,
                        normalized_y,
                    },
                )
                .map(|_| true)
            }
            PlatformNativeMotionEvent::Scroll {
                pointer_id: _,
                delta_x_1024_points,
                delta_y_1024_points,
                phase,
                velocity_x_1024_points_per_second: _,
                velocity_y_1024_points_per_second: _,
                continuous_precision,
            } => {
                let horizontal = delta_x_1024_points / 1024;
                let vertical = delta_y_1024_points / 1024;
                let event = CGEvent::new_scroll_event(
                    event_source()?,
                    ScrollEventUnit::PIXEL,
                    2,
                    vertical,
                    horizontal,
                    0,
                )
                .map_err(|_| "could not create macOS scroll event".to_owned())?;
                event.set_double_value_field(
                    EventField::SCROLL_WHEEL_EVENT_FIXED_POINT_DELTA_AXIS_1,
                    f64::from(delta_y_1024_points) / 1_024.0,
                );
                event.set_double_value_field(
                    EventField::SCROLL_WHEEL_EVENT_FIXED_POINT_DELTA_AXIS_2,
                    f64::from(delta_x_1024_points) / 1_024.0,
                );
                event.set_integer_value_field(
                    EventField::SCROLL_WHEEL_EVENT_IS_CONTINUOUS,
                    i64::from(continuous_precision),
                );
                let (scroll_phase, momentum_phase) = mac_scroll_phases(phase);
                event.set_integer_value_field(SCROLL_WHEEL_EVENT_SCROLL_PHASE, scroll_phase);
                event.set_integer_value_field(SCROLL_WHEEL_EVENT_MOMENTUM_PHASE, momentum_phase);
                event.post(CGEventTapLocation::HID);
                Ok(true)
            }
            PlatformNativeMotionEvent::Touch { .. } | PlatformNativeMotionEvent::Pen { .. } => {
                Err("macOS native touch and pen motion injection is not implemented".to_owned())
            }
            PlatformNativeMotionEvent::Gamepad { .. } => {
                Err("macOS virtual gamepad motion injection is not implemented".to_owned())
            }
        }
    }

    pub(crate) fn handle_positioned_button(
        &self,
        session_epoch: u32,
        display_id: u32,
        planned_bounds: Option<MacInputDisplayBounds>,
        capture_viewport: Option<MacInputCaptureViewport>,
        input: MacPositionedButtonInput,
    ) -> Result<(), String> {
        self.handle_positioned_button_activity(
            session_epoch,
            display_id,
            planned_bounds,
            capture_viewport,
            input,
        )
        .map(|_| ())
    }

    pub(crate) fn handle_positioned_button_activity(
        &self,
        session_epoch: u32,
        display_id: u32,
        planned_bounds: Option<MacInputDisplayBounds>,
        capture_viewport: Option<MacInputCaptureViewport>,
        input: MacPositionedButtonInput,
    ) -> Result<bool, String> {
        let mut states = self
            .state
            .lock()
            .map_err(|_| "macOS native input state is unavailable".to_owned())?;
        let state = states.entry(session_epoch).or_default();
        let location = post_pointer_motion(
            display_id,
            planned_bounds,
            capture_viewport,
            state,
            MacPointerMotionInput {
                mode: NativePointerMotionMode::Absolute,
                delta_x: 0,
                delta_y: 0,
                normalized_x: input.normalized_x,
                normalized_y: input.normalized_y,
            },
        )?;
        let _ = input.pointer_id;
        self.handle_pointer_button(state, input.button, input.pressed, Some(location))?;
        Ok(true)
    }

    fn handle_pointer_button(
        &self,
        state: &mut MacInputState,
        button: u8,
        pressed: bool,
        exact_location: Option<CGPoint>,
    ) -> Result<bool, String> {
        let was_pressed = state.pressed_buttons.contains(&button);
        if pressed == was_pressed {
            Ok(false)
        } else if pressed {
            let location = exact_location.map_or_else(|| self.poster.pointer_location(), Ok)?;
            let click_state = state.click_tracker.begin(
                button,
                location,
                Instant::now(),
                self.double_click_interval()?,
            );
            if let Err(error) = self.poster.post_button(button, true, click_state, location) {
                state.click_tracker.rollback_begin(button);
                return Err(error);
            }
            state.pressed_buttons.insert(button);
            Ok(true)
        } else {
            let location = exact_location.map_or_else(|| self.poster.pointer_location(), Ok)?;
            let click_state = state.click_tracker.pending(button).ok_or_else(|| {
                format!("macOS native input button {button} has no matching click state")
            })?;
            self.poster
                .post_button(button, false, click_state, location)?;
            state.pressed_buttons.remove(&button);
            state.click_tracker.finish(button, click_state);
            Ok(true)
        }
    }

    pub(crate) fn reset(&self, session_epoch: u32) -> Result<(), String> {
        let mut states = self
            .state
            .lock()
            .map_err(|_| "macOS native input state is unavailable".to_owned())?;
        for attempt in 0..MAX_NATIVE_INPUT_RESET_ATTEMPTS {
            let mut errors = Vec::new();
            {
                let Some(state) = states.get_mut(&session_epoch) else {
                    return Ok(());
                };

                let mut keys: Vec<_> = state.pressed_keys.iter().copied().collect();
                keys.sort_unstable();
                let mut released_keys = Vec::new();
                for hid_usage in keys {
                    match self.poster.post_key(hid_usage, false, 0, false) {
                        Ok(()) => released_keys.push(hid_usage),
                        Err(error) => errors.push(error),
                    }
                }
                for hid_usage in released_keys {
                    state.pressed_keys.remove(&hid_usage);
                }

                let mut buttons: Vec<_> = state.pressed_buttons.iter().copied().collect();
                buttons.sort_unstable();
                let mut released_buttons = Vec::new();
                for button in buttons {
                    let click_state = state.click_tracker.pending(button).ok_or_else(|| {
                        format!("macOS native input button {button} has no matching click state")
                    });
                    let location = self.poster.pointer_location();
                    match (click_state, location) {
                        (Ok(click_state), Ok(location)) => {
                            match self
                                .poster
                                .post_button(button, false, click_state, location)
                            {
                                Ok(()) => released_buttons.push((button, click_state)),
                                Err(error) => errors.push(error),
                            }
                        }
                        (Err(error), _) | (_, Err(error)) => errors.push(error),
                    }
                }
                for (button, _click_state) in released_buttons {
                    state.pressed_buttons.remove(&button);
                    state.click_tracker.finish_reset(button);
                }
            }

            if errors.is_empty() {
                states.remove(&session_epoch);
                return Ok(());
            }
            if attempt + 1 == MAX_NATIVE_INPUT_RESET_ATTEMPTS {
                if let Some(state) = states.get_mut(&session_epoch) {
                    state.compositions.clear();
                }
                // Failed entries were retained for the bounded second pass above. Once both
                // passes fail, discard this epoch's ledger after returning the terminal error
                // so a dead session cannot retain an unbounded stale entry; the QUIC guard
                // reports the terminal failure through the typed runtime-event boundary.
                states.remove(&session_epoch);
                return Err(errors.join("; "));
            }
        }
        unreachable!("native input reset attempts are bounded above");
    }

    /// Releases input owned by every live native session.
    ///
    /// Platform workspace teardown is not coupled to the lifetime of an
    /// individual QUIC input stream, so it must drain every epoch before the
    /// desktop disappears. Per-epoch reset remains idempotent for the stream
    /// guard that may run afterward.
    pub(crate) fn reset_all(&self) -> Result<(), String> {
        let mut session_epochs: Vec<_> = self
            .state
            .lock()
            .map_err(|_| "macOS native input state is unavailable".to_owned())?
            .keys()
            .copied()
            .collect();
        session_epochs.sort_unstable();

        let mut errors = Vec::new();
        for session_epoch in session_epochs {
            if let Err(error) = self.reset(session_epoch) {
                errors.push(format!("session epoch {session_epoch}: {error}"));
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }
}

fn mac_scroll_phases(phase: NativeScrollPhase) -> (i64, i64) {
    match phase {
        NativeScrollPhase::Began => (1, 0),
        NativeScrollPhase::Changed => (2, 0),
        NativeScrollPhase::Ended => (4, 0),
        NativeScrollPhase::Cancelled => (8, 0),
        NativeScrollPhase::MomentumBegan => (0, 1),
        NativeScrollPhase::MomentumChanged => (0, 2),
        NativeScrollPhase::MomentumEnded => (0, 3),
        NativeScrollPhase::Unspecified => (0, 0),
    }
}
