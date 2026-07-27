use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_void};
use std::mem::transmute;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use core_graphics::display::CGDisplay;
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTapLocation, CGEventType, CGMouseButton, EventField,
    ScrollEventUnit,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::{CGPoint, CGRect, CGSize};
use lumen_engine::{NativePointerMotionMode, NativeScrollPhase};

use crate::{PlatformNativeInputEvent, PlatformNativeMotionEvent};

static POST_EVENT_ACCESS_REQUESTED: AtomicBool = AtomicBool::new(false);
const MAX_NATIVE_INPUT_RESET_ATTEMPTS: usize = 2;
#[cfg(test)]
const DEFAULT_DOUBLE_CLICK_INTERVAL: Duration = Duration::from_millis(500);
// The wire protocol carries button edges, not a click count. CoreGraphics therefore needs a
// host-side click sequence. Keep the worker's location tolerance small and axis-aligned, matching
// macOS screen-point semantics without constructing an AppKit UI object on the QUIC worker.
const CLICK_LOCATION_TOLERANCE_POINTS: f64 = 5.0;
const SCROLL_WHEEL_EVENT_SCROLL_PHASE: u32 = 99;
const SCROLL_WHEEL_EVENT_MOMENTUM_PHASE: u32 = 123;

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> *const c_void;
    fn sel_registerName(name: *const c_char) -> *const c_void;
    fn objc_msgSend();
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn CGPreflightPostEventAccess() -> bool;
    fn CGRequestPostEventAccess() -> bool;
}

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

#[derive(Clone, Copy, Debug)]
struct MacPointerMotionInput {
    mode: NativePointerMotionMode,
    delta_x: i32,
    delta_y: i32,
    normalized_x: f32,
    normalized_y: f32,
}

trait MacInputEventPoster: Send + Sync {
    fn post_key(
        &self,
        hid_usage: u16,
        pressed: bool,
        modifiers: u8,
        repeat: bool,
    ) -> Result<(), String>;
    fn pointer_location(&self) -> Result<CGPoint, String>;
    fn post_button(
        &self,
        button: u8,
        pressed: bool,
        click_state: u32,
        location: CGPoint,
    ) -> Result<(), String>;
}

#[derive(Default)]
struct CoreGraphicsMacInputEventPoster;

impl MacInputEventPoster for CoreGraphicsMacInputEventPoster {
    fn post_key(
        &self,
        hid_usage: u16,
        pressed: bool,
        modifiers: u8,
        repeat: bool,
    ) -> Result<(), String> {
        post_key_event(hid_usage, pressed, modifiers, repeat)
    }

    fn pointer_location(&self) -> Result<CGPoint, String> {
        current_pointer_location()
    }

    fn post_button(
        &self,
        button: u8,
        pressed: bool,
        click_state: u32,
        location: CGPoint,
    ) -> Result<(), String> {
        post_button_event(button, pressed, click_state, location)
    }
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
                    return Ok(());
                }
                self.poster
                    .post_key(hid_usage, pressed, modifiers, repeat)?;
                if pressed {
                    state.pressed_keys.insert(hid_usage);
                } else {
                    state.pressed_keys.remove(&hid_usage);
                }
                Ok(())
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
                        Ok(())
                    } else {
                        post_text(&text)
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
                    Ok(())
                }
            }
            PlatformNativeInputEvent::PointerButton {
                pointer_id: _,
                button,
                pressed,
                absolute_position: _,
            } => self.handle_pointer_button(state, button, pressed, None),
            PlatformNativeInputEvent::RumbleAcknowledged { .. } => Ok(()),
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
        event: PlatformNativeMotionEvent,
    ) -> Result<(), String> {
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
            } => post_pointer_motion(
                display_id,
                planned_bounds,
                state,
                MacPointerMotionInput {
                    mode,
                    delta_x,
                    delta_y,
                    normalized_x,
                    normalized_y,
                },
            )
            .map(|_| ()),
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
                Ok(())
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
        pointer_id: u32,
        button: u8,
        pressed: bool,
        normalized_x: f32,
        normalized_y: f32,
    ) -> Result<(), String> {
        let mut states = self
            .state
            .lock()
            .map_err(|_| "macOS native input state is unavailable".to_owned())?;
        let state = states.entry(session_epoch).or_default();
        let location = post_pointer_motion(
            display_id,
            planned_bounds,
            state,
            MacPointerMotionInput {
                mode: NativePointerMotionMode::Absolute,
                delta_x: 0,
                delta_y: 0,
                normalized_x,
                normalized_y,
            },
        )?;
        let _ = pointer_id;
        self.handle_pointer_button(state, button, pressed, Some(location))
    }

    fn handle_pointer_button(
        &self,
        state: &mut MacInputState,
        button: u8,
        pressed: bool,
        exact_location: Option<CGPoint>,
    ) -> Result<(), String> {
        let was_pressed = state.pressed_buttons.contains(&button);
        if pressed == was_pressed {
            Ok(())
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
            Ok(())
        } else {
            let location = exact_location.map_or_else(|| self.poster.pointer_location(), Ok)?;
            let click_state = state.click_tracker.pending(button).ok_or_else(|| {
                format!("macOS native input button {button} has no matching click state")
            })?;
            self.poster
                .post_button(button, false, click_state, location)?;
            state.pressed_buttons.remove(&button);
            state.click_tracker.finish(button, click_state);
            Ok(())
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

fn post_pointer_motion(
    display_id: u32,
    planned_bounds: Option<MacInputDisplayBounds>,
    state: &MacInputState,
    input: MacPointerMotionInput,
) -> Result<CGPoint, String> {
    let source = event_source()?;
    let current = CGEvent::new(source.clone())
        .map_err(|_| "could not inspect the macOS pointer location".to_owned())?
        .location();
    let bounds = preferred_pointer_bounds(
        display_id,
        CGDisplay::new(display_id).bounds(),
        planned_bounds,
    )?;
    let target = pointer_target(
        current,
        bounds,
        input.mode,
        input.delta_x,
        input.delta_y,
        input.normalized_x,
        input.normalized_y,
    )?;
    let (event_type, button) = drag_event(state);
    let event = CGEvent::new_mouse_event(source, event_type, target, button)
        .map_err(|_| "could not create macOS pointer motion event".to_owned())?;
    event.set_integer_value_field(EventField::MOUSE_EVENT_DELTA_X, i64::from(input.delta_x));
    event.set_integer_value_field(EventField::MOUSE_EVENT_DELTA_Y, i64::from(input.delta_y));
    event.post(CGEventTapLocation::HID);
    Ok(target)
}

fn preferred_pointer_bounds(
    display_id: u32,
    published_bounds: CGRect,
    planned_bounds: Option<MacInputDisplayBounds>,
) -> Result<CGRect, String> {
    // Input targets the active session display. Its published bounds must win over the planned
    // virtual geometry whenever CoreGraphics has them available.
    if published_bounds.size.width > 0.0 && published_bounds.size.height > 0.0 {
        return Ok(published_bounds);
    }
    planned_bounds
        .and_then(MacInputDisplayBounds::rect)
        .ok_or_else(|| {
            format!("macOS native motion display {display_id} has no published or planned bounds")
        })
}

fn pointer_target(
    current: CGPoint,
    bounds: CGRect,
    mode: NativePointerMotionMode,
    delta_x: i32,
    delta_y: i32,
    normalized_x: f32,
    normalized_y: f32,
) -> Result<CGPoint, String> {
    match mode {
        NativePointerMotionMode::Relative => {
            let origin = if point_in_rect(current, bounds) {
                current
            } else {
                CGPoint::new(
                    bounds.origin.x + bounds.size.width / 2.0,
                    bounds.origin.y + bounds.size.height / 2.0,
                )
            };
            Ok(CGPoint::new(
                (origin.x + f64::from(delta_x))
                    .clamp(bounds.origin.x, bounds.origin.x + bounds.size.width - 1.0),
                (origin.y + f64::from(delta_y))
                    .clamp(bounds.origin.y, bounds.origin.y + bounds.size.height - 1.0),
            ))
        }
        NativePointerMotionMode::Absolute => Ok(CGPoint::new(
            bounds.origin.x + f64::from(normalized_x) * (bounds.size.width - 1.0),
            bounds.origin.y + f64::from(normalized_y) * (bounds.size.height - 1.0),
        )),
        NativePointerMotionMode::Unspecified => {
            Err("macOS native pointer motion mode is unspecified".to_owned())
        }
    }
}

fn point_in_rect(point: CGPoint, bounds: core_graphics::geometry::CGRect) -> bool {
    point.x >= bounds.origin.x
        && point.x < bounds.origin.x + bounds.size.width
        && point.y >= bounds.origin.y
        && point.y < bounds.origin.y + bounds.size.height
}

fn drag_event(state: &MacInputState) -> (CGEventType, CGMouseButton) {
    if state.pressed_buttons.contains(&1) {
        (CGEventType::LeftMouseDragged, CGMouseButton::Left)
    } else if state.pressed_buttons.contains(&3) {
        (CGEventType::RightMouseDragged, CGMouseButton::Right)
    } else if state
        .pressed_buttons
        .iter()
        .any(|button| (2..=5).contains(button))
    {
        (CGEventType::OtherMouseDragged, CGMouseButton::Center)
    } else {
        (CGEventType::MouseMoved, CGMouseButton::Left)
    }
}

fn post_key_event(
    hid_usage: u16,
    pressed: bool,
    modifiers: u8,
    repeat: bool,
) -> Result<(), String> {
    let key_code = mac_key_code(hid_usage)
        .ok_or_else(|| format!("unsupported macOS USB HID keyboard usage {hid_usage:#x}"))?;
    let event = CGEvent::new_keyboard_event(event_source()?, key_code, pressed)
        .map_err(|_| "could not create macOS keyboard event".to_owned())?;
    event.set_flags(mac_modifier_flags(modifiers));
    event.set_integer_value_field(EventField::KEYBOARD_EVENT_AUTOREPEAT, i64::from(repeat));
    event.post(CGEventTapLocation::HID);
    Ok(())
}

fn post_text(text: &str) -> Result<(), String> {
    let down = CGEvent::new_keyboard_event(event_source()?, 0, true)
        .map_err(|_| "could not create macOS Unicode key-down event".to_owned())?;
    down.set_string(text);
    down.post(CGEventTapLocation::HID);
    let up = CGEvent::new_keyboard_event(event_source()?, 0, false)
        .map_err(|_| "could not create macOS Unicode key-up event".to_owned())?;
    up.post(CGEventTapLocation::HID);
    Ok(())
}

fn current_pointer_location() -> Result<CGPoint, String> {
    let source = event_source()?;
    let location = CGEvent::new(source)
        .map_err(|_| "could not inspect the macOS pointer location".to_owned())?
        .location();
    Ok(location)
}

fn post_button_event(
    button: u8,
    pressed: bool,
    click_state: u32,
    location: CGPoint,
) -> Result<(), String> {
    let source = event_source()?;
    let (event_type, mouse_button, button_number) = match (button, pressed) {
        (1, true) => (CGEventType::LeftMouseDown, CGMouseButton::Left, 0),
        (1, false) => (CGEventType::LeftMouseUp, CGMouseButton::Left, 0),
        (2, true) => (CGEventType::OtherMouseDown, CGMouseButton::Center, 2),
        (2, false) => (CGEventType::OtherMouseUp, CGMouseButton::Center, 2),
        (3, true) => (CGEventType::RightMouseDown, CGMouseButton::Right, 1),
        (3, false) => (CGEventType::RightMouseUp, CGMouseButton::Right, 1),
        (4 | 5, true) => (
            CGEventType::OtherMouseDown,
            CGMouseButton::Center,
            button - 1,
        ),
        (4 | 5, false) => (CGEventType::OtherMouseUp, CGMouseButton::Center, button - 1),
        _ => return Err(format!("unsupported macOS pointer button {button}")),
    };
    let event = CGEvent::new_mouse_event(source, event_type, location, mouse_button)
        .map_err(|_| "could not create macOS pointer button event".to_owned())?;
    event.set_integer_value_field(
        EventField::MOUSE_EVENT_BUTTON_NUMBER,
        i64::from(button_number),
    );
    event.set_integer_value_field(EventField::MOUSE_EVENT_CLICK_STATE, i64::from(click_state));
    event.post(CGEventTapLocation::HID);
    Ok(())
}

fn system_double_click_interval() -> Result<Duration, String> {
    const NSEVENT_CLASS: &[u8] = b"NSEvent\0";
    const DOUBLE_CLICK_INTERVAL_SELECTOR: &[u8] = b"doubleClickInterval\0";
    type DoubleClickIntervalMessage = unsafe extern "C" fn(*const c_void, *const c_void) -> f64;

    // SAFETY: Category 8 (FFI boundary). This invokes AppKit's documented class property
    // `+[NSEvent doubleClickInterval]`, which returns the current system double-click interval.
    let class = unsafe { objc_getClass(NSEVENT_CLASS.as_ptr().cast()) };
    let selector = unsafe { sel_registerName(DOUBLE_CLICK_INTERVAL_SELECTOR.as_ptr().cast()) };
    if class.is_null() || selector.is_null() {
        return Err("could not resolve AppKit double-click interval".to_owned());
    }
    // SAFETY: Category 8 (FFI boundary). `objc_msgSend` is called with the NSEvent class and a
    // zero-argument selector whose ABI returns NSTimeInterval (a C double).
    let send: DoubleClickIntervalMessage = unsafe { transmute(objc_msgSend as *const ()) };
    let seconds = unsafe { send(class, selector) };
    if !seconds.is_finite() || seconds <= 0.0 {
        return Err("AppKit returned an invalid double-click interval".to_owned());
    }
    Duration::try_from_secs_f64(seconds)
        .map_err(|_| "AppKit returned an unrepresentable double-click interval".to_owned())
}

fn event_source() -> Result<CGEventSource, String> {
    ensure_post_event_access()?;
    CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| "could not create macOS HID event source".to_owned())
}

fn ensure_post_event_access() -> Result<(), String> {
    // SAFETY: Category 8 (FFI boundary). These CoreGraphics functions take no pointers and
    // return the current process' event-synthesis authorization state.
    if unsafe { CGPreflightPostEventAccess() } {
        return Ok(());
    }
    if !POST_EVENT_ACCESS_REQUESTED.swap(true, Ordering::AcqRel) {
        // SAFETY: Category 8 (FFI boundary). The function has no arguments and may present the
        // system authorization prompt for this signed helper process.
        if unsafe { CGRequestPostEventAccess() } {
            return Ok(());
        }
    }
    Err(
        "macOS event synthesis is not authorized; allow LumenHostWorker in Privacy & Security > Accessibility"
            .to_owned(),
    )
}

fn mac_modifier_flags(modifiers: u8) -> CGEventFlags {
    let mut flags = CGEventFlags::CGEventFlagNull;
    if modifiers & 0x22 != 0 {
        flags.insert(CGEventFlags::CGEventFlagShift);
    }
    if modifiers & 0x11 != 0 {
        flags.insert(CGEventFlags::CGEventFlagControl);
    }
    if modifiers & 0x44 != 0 {
        flags.insert(CGEventFlags::CGEventFlagAlternate);
    }
    if modifiers & 0x88 != 0 {
        flags.insert(CGEventFlags::CGEventFlagCommand);
    }
    flags
}

fn mac_key_code(hid_usage: u16) -> Option<u16> {
    let key_code = match hid_usage {
        0x04 => 0x00,
        0x05 => 0x0b,
        0x06 => 0x08,
        0x07 => 0x02,
        0x08 => 0x0e,
        0x09 => 0x03,
        0x0a => 0x05,
        0x0b => 0x04,
        0x0c => 0x22,
        0x0d => 0x26,
        0x0e => 0x28,
        0x0f => 0x25,
        0x10 => 0x2e,
        0x11 => 0x2d,
        0x12 => 0x1f,
        0x13 => 0x23,
        0x14 => 0x0c,
        0x15 => 0x0f,
        0x16 => 0x01,
        0x17 => 0x11,
        0x18 => 0x20,
        0x19 => 0x09,
        0x1a => 0x0d,
        0x1b => 0x07,
        0x1c => 0x10,
        0x1d => 0x06,
        0x1e => 0x12,
        0x1f => 0x13,
        0x20 => 0x14,
        0x21 => 0x15,
        0x22 => 0x17,
        0x23 => 0x16,
        0x24 => 0x1a,
        0x25 => 0x1c,
        0x26 => 0x19,
        0x27 => 0x1d,
        0x28 => 0x24,
        0x29 => 0x35,
        0x2a => 0x33,
        0x2b => 0x30,
        0x2c => 0x31,
        0x2d => 0x1b,
        0x2e => 0x18,
        0x2f => 0x21,
        0x30 => 0x1e,
        0x31 | 0x32 => 0x2a,
        0x33 => 0x29,
        0x34 => 0x27,
        0x35 => 0x32,
        0x36 => 0x2b,
        0x37 => 0x2f,
        0x38 => 0x2c,
        0x39 => 0x39,
        0x3a => 0x7a,
        0x3b => 0x78,
        0x3c => 0x63,
        0x3d => 0x76,
        0x3e => 0x60,
        0x3f => 0x61,
        0x40 => 0x62,
        0x41 => 0x64,
        0x42 => 0x65,
        0x43 => 0x6d,
        0x44 => 0x67,
        0x45 => 0x6f,
        0x49 => 0x72,
        0x4a => 0x73,
        0x4b => 0x74,
        0x4c => 0x75,
        0x4d => 0x77,
        0x4e => 0x79,
        0x4f => 0x7c,
        0x50 => 0x7b,
        0x51 => 0x7d,
        0x52 => 0x7e,
        0x53 => 0x47,
        0x54 => 0x4b,
        0x55 => 0x43,
        0x56 => 0x4e,
        0x57 => 0x45,
        0x58 => 0x4c,
        0x59 => 0x53,
        0x5a => 0x54,
        0x5b => 0x55,
        0x5c => 0x56,
        0x5d => 0x57,
        0x5e => 0x58,
        0x5f => 0x59,
        0x60 => 0x5b,
        0x61 => 0x5c,
        0x62 => 0x52,
        0x63 => 0x41,
        0xe0 => 0x3b,
        0xe1 => 0x38,
        0xe2 => 0x3a,
        0xe3 => 0x37,
        0xe4 => 0x3e,
        0xe5 => 0x3c,
        0xe6 => 0x3d,
        0xe7 => 0x36,
        _ => return None,
    };
    Some(key_code)
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use super::*;

    #[derive(Clone, Debug, Eq, PartialEq)]
    enum PostedEvent {
        Key {
            hid_usage: u16,
            pressed: bool,
            modifiers: u8,
            repeat: bool,
        },
        Button {
            button: u8,
            pressed: bool,
            click_state: u32,
        },
    }

    struct RecordingPoster {
        outcomes: Mutex<VecDeque<Result<(), String>>>,
        events: Mutex<Vec<PostedEvent>>,
        button_locations: Mutex<Vec<(f64, f64)>>,
    }

    impl RecordingPoster {
        fn new(outcomes: impl IntoIterator<Item = Result<(), String>>) -> Self {
            Self {
                outcomes: Mutex::new(outcomes.into_iter().collect()),
                events: Mutex::new(Vec::new()),
                button_locations: Mutex::new(Vec::new()),
            }
        }

        fn events(&self) -> Vec<PostedEvent> {
            self.events.lock().unwrap().clone()
        }

        fn button_locations(&self) -> Vec<(f64, f64)> {
            self.button_locations.lock().unwrap().clone()
        }

        fn record(&self, event: PostedEvent) -> Result<(), String> {
            self.events.lock().unwrap().push(event);
            self.outcomes.lock().unwrap().pop_front().unwrap_or(Ok(()))
        }
    }

    impl MacInputEventPoster for RecordingPoster {
        fn post_key(
            &self,
            hid_usage: u16,
            pressed: bool,
            modifiers: u8,
            repeat: bool,
        ) -> Result<(), String> {
            self.record(PostedEvent::Key {
                hid_usage,
                pressed,
                modifiers,
                repeat,
            })
        }

        fn pointer_location(&self) -> Result<CGPoint, String> {
            Ok(CGPoint::new(120.0, 80.0))
        }

        fn post_button(
            &self,
            button: u8,
            pressed: bool,
            click_state: u32,
            location: CGPoint,
        ) -> Result<(), String> {
            self.button_locations
                .lock()
                .unwrap()
                .push((location.x, location.y));
            self.record(PostedEvent::Button {
                button,
                pressed,
                click_state,
            })
        }
    }

    #[test]
    fn positioned_button_uses_exact_motion_target_without_pointer_requery() {
        let poster = Arc::new(RecordingPoster::new([]));
        let input = MacNativeInput::with_poster(poster.clone());
        let mut state = MacInputState::default();

        input
            .handle_pointer_button(&mut state, 1, true, Some(CGPoint::new(321.0, 654.0)))
            .unwrap();

        assert_eq!(poster.button_locations(), [(321.0, 654.0)]);
    }

    #[test]
    fn click_tracker_marks_two_matching_pairs_as_single_then_double_clicks() {
        let mut tracker = MacClickTracker::default();
        let start = Instant::now();
        let location = CGPoint::new(120.0, 80.0);
        let interval = Duration::from_millis(500);

        let first = tracker.begin(1, location, start, interval);
        tracker.finish(1, first);
        let second = tracker.begin(1, location, start + Duration::from_millis(100), interval);
        tracker.finish(1, second);

        assert_eq!(first, 1);
        assert_eq!(second, 2);
    }

    #[test]
    fn click_tracker_resets_after_interval_or_pointer_movement() {
        let mut tracker = MacClickTracker::default();
        let start = Instant::now();
        let location = CGPoint::new(120.0, 80.0);
        let interval = Duration::from_millis(500);

        let first = tracker.begin(1, location, start, interval);
        tracker.finish(1, first);
        let late = tracker.begin(1, location, start + Duration::from_millis(700), interval);
        tracker.finish(1, late);
        let moved = tracker.begin(
            1,
            CGPoint::new(128.0, 80.0),
            start + Duration::from_millis(800),
            interval,
        );

        assert_eq!(late, 1);
        assert_eq!(moved, 1);
    }

    #[test]
    fn click_location_policy_applies_tolerance_per_axis() {
        let origin = CGPoint::new(120.0, 80.0);

        assert!(click_locations_match(origin, CGPoint::new(125.0, 85.0)));
        assert!(!click_locations_match(origin, CGPoint::new(125.01, 80.0)));
        assert!(!click_locations_match(origin, CGPoint::new(120.0, 85.01)));
    }

    #[test]
    fn click_tracker_keeps_button_sequences_independent() {
        let mut tracker = MacClickTracker::default();
        let start = Instant::now();
        let location = CGPoint::new(120.0, 80.0);
        let interval = Duration::from_millis(500);

        let left = tracker.begin(1, location, start, interval);
        tracker.finish(1, left);
        let right = tracker.begin(3, location, start + Duration::from_millis(30), interval);
        tracker.finish(3, right);
        let left_again = tracker.begin(1, location, start + Duration::from_millis(100), interval);

        assert_eq!(left, 1);
        assert_eq!(right, 1);
        assert_eq!(left_again, 2);
    }

    #[test]
    fn continuous_scroll_maps_gesture_and_momentum_phases_without_quantization_state() {
        assert_eq!(mac_scroll_phases(NativeScrollPhase::Began), (1, 0));
        assert_eq!(mac_scroll_phases(NativeScrollPhase::Changed), (2, 0));
        assert_eq!(mac_scroll_phases(NativeScrollPhase::Ended), (4, 0));
        assert_eq!(mac_scroll_phases(NativeScrollPhase::Cancelled), (8, 0));
        assert_eq!(mac_scroll_phases(NativeScrollPhase::MomentumBegan), (0, 1));
        assert_eq!(
            mac_scroll_phases(NativeScrollPhase::MomentumChanged),
            (0, 2)
        );
        assert_eq!(mac_scroll_phases(NativeScrollPhase::MomentumEnded), (0, 3));
    }

    #[test]
    fn rapid_left_pairs_emit_matching_click_state_on_down_and_up() {
        let poster = Arc::new(RecordingPoster::new([Ok(()), Ok(()), Ok(()), Ok(())]));
        let input = MacNativeInput::with_poster_and_click_interval(
            poster.clone(),
            Duration::from_millis(500),
        );
        let press = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: true,
            absolute_position: None,
        };
        let release = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: false,
            absolute_position: None,
        };

        input.handle(21, press.clone()).unwrap();
        input.handle(21, release.clone()).unwrap();
        input.handle(21, press).unwrap();
        input.handle(21, release).unwrap();

        assert_eq!(
            poster.events(),
            vec![
                PostedEvent::Button {
                    button: 1,
                    pressed: true,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: true,
                    click_state: 2,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 2,
                },
            ]
        );
    }

    #[test]
    fn system_double_click_interval_is_available_from_appkit() {
        let interval = system_double_click_interval().expect("AppKit double-click interval");
        assert!(!interval.is_zero());
    }

    #[test]
    fn reset_discards_click_sequence_for_reused_session_epoch() {
        let poster = Arc::new(RecordingPoster::new([
            Ok(()),
            Ok(()),
            Ok(()),
            Ok(()),
            Ok(()),
        ]));
        let input = MacNativeInput::with_poster_and_click_interval(
            poster.clone(),
            Duration::from_millis(500),
        );
        let press = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: true,
            absolute_position: None,
        };
        let release = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: false,
            absolute_position: None,
        };

        input.handle(22, press.clone()).unwrap();
        input.handle(22, release.clone()).unwrap();
        input.reset(22).unwrap();
        input.handle(22, press).unwrap();

        assert_eq!(
            poster.events(),
            vec![
                PostedEvent::Button {
                    button: 1,
                    pressed: true,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: true,
                    click_state: 1,
                },
            ]
        );
    }

    #[test]
    fn failed_left_release_remains_pressed_for_reset_retry() {
        let poster = Arc::new(RecordingPoster::new([
            Ok(()),
            Err("left-up failed".to_owned()),
            Err("reset attempt one failed".to_owned()),
            Ok(()),
        ]));
        let input = MacNativeInput::with_poster(poster.clone());
        let press = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: true,
            absolute_position: None,
        };
        let release = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: false,
            absolute_position: None,
        };

        input.handle(7, press).unwrap();
        assert_eq!(input.handle(7, release), Err("left-up failed".to_owned()));
        input.reset(7).unwrap();
        input.reset(7).unwrap();

        assert_eq!(
            poster.events(),
            vec![
                PostedEvent::Button {
                    button: 1,
                    pressed: true,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
            ]
        );
    }

    #[test]
    fn repeated_key_down_preserves_the_native_autorepeat_marker() {
        let poster = Arc::new(RecordingPoster::new([Ok(()), Ok(()), Ok(())]));
        let input = MacNativeInput::with_poster(poster.clone());

        input
            .handle(
                8,
                PlatformNativeInputEvent::Keyboard {
                    hid_usage: 0x04,
                    pressed: true,
                    modifiers: 0,
                    repeat: false,
                },
            )
            .unwrap();
        input
            .handle(
                8,
                PlatformNativeInputEvent::Keyboard {
                    hid_usage: 0x04,
                    pressed: true,
                    modifiers: 0,
                    repeat: true,
                },
            )
            .unwrap();
        input
            .handle(
                8,
                PlatformNativeInputEvent::Keyboard {
                    hid_usage: 0x04,
                    pressed: false,
                    modifiers: 0,
                    repeat: false,
                },
            )
            .unwrap();

        assert_eq!(
            poster.events(),
            vec![
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: true,
                    modifiers: 0,
                    repeat: false,
                },
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: true,
                    modifiers: 0,
                    repeat: true,
                },
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: false,
                    modifiers: 0,
                    repeat: false,
                },
            ]
        );
    }

    #[test]
    fn failed_key_release_remains_pressed_for_reset_retry() {
        let poster = Arc::new(RecordingPoster::new([
            Ok(()),
            Err("key-up failed".to_owned()),
            Err("reset attempt one failed".to_owned()),
            Ok(()),
        ]));
        let input = MacNativeInput::with_poster(poster.clone());
        let press = PlatformNativeInputEvent::Keyboard {
            hid_usage: 0x04,
            pressed: true,
            modifiers: 0x88,
            repeat: false,
        };
        let release = PlatformNativeInputEvent::Keyboard {
            hid_usage: 0x04,
            pressed: false,
            modifiers: 0,
            repeat: false,
        };

        input.handle(9, press).unwrap();
        assert_eq!(input.handle(9, release), Err("key-up failed".to_owned()));
        input.reset(9).unwrap();
        input.reset(9).unwrap();

        assert_eq!(
            poster.events(),
            vec![
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: true,
                    modifiers: 0x88,
                    repeat: false,
                },
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: false,
                    modifiers: 0,
                    repeat: false,
                },
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: false,
                    modifiers: 0,
                    repeat: false,
                },
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: false,
                    modifiers: 0,
                    repeat: false,
                },
            ]
        );
    }

    #[test]
    fn failed_button_press_does_not_leave_a_pressed_ledger_entry() {
        let poster = Arc::new(RecordingPoster::new([Err("left-down failed".to_owned())]));
        let input = MacNativeInput::with_poster(poster.clone());
        let press = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: true,
            absolute_position: None,
        };

        assert_eq!(input.handle(11, press), Err("left-down failed".to_owned()));
        input.reset(11).unwrap();

        assert_eq!(
            poster.events(),
            vec![PostedEvent::Button {
                button: 1,
                pressed: true,
                click_state: 1,
            }]
        );
    }

    #[test]
    fn failed_reset_retains_one_retry_then_discards_the_epoch_after_final_failure() {
        let poster = Arc::new(RecordingPoster::new([
            Ok(()),
            Err("left-up failed".to_owned()),
            Err("reset attempt one failed".to_owned()),
            Err("reset attempt two failed".to_owned()),
        ]));
        let input = MacNativeInput::with_poster(poster.clone());
        let press = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: true,
            absolute_position: None,
        };
        let release = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: false,
            absolute_position: None,
        };

        input.handle(12, press).unwrap();
        assert!(input.handle(12, release).is_err());
        assert!(input.reset(12).is_err());
        input.reset(12).unwrap();

        assert_eq!(
            poster.events(),
            vec![
                PostedEvent::Button {
                    button: 1,
                    pressed: true,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
            ]
        );
    }

    #[test]
    fn reset_retries_only_failed_items_after_partial_release() {
        let poster = Arc::new(RecordingPoster::new([
            Ok(()),
            Ok(()),
            Ok(()),
            Err("button-up failed".to_owned()),
            Ok(()),
        ]));
        let input = MacNativeInput::with_poster(poster.clone());
        let key_press = PlatformNativeInputEvent::Keyboard {
            hid_usage: 0x04,
            pressed: true,
            modifiers: 0,
            repeat: false,
        };
        let button_press = PlatformNativeInputEvent::PointerButton {
            pointer_id: 0,
            button: 1,
            pressed: true,
            absolute_position: None,
        };

        input.handle(13, key_press).unwrap();
        input.handle(13, button_press).unwrap();
        input.reset(13).unwrap();

        assert_eq!(
            poster.events(),
            vec![
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: true,
                    modifiers: 0,
                    repeat: false,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: true,
                    click_state: 1,
                },
                PostedEvent::Key {
                    hid_usage: 0x04,
                    pressed: false,
                    modifiers: 0,
                    repeat: false,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
                PostedEvent::Button {
                    button: 1,
                    pressed: false,
                    click_state: 1,
                },
            ]
        );
    }

    #[test]
    fn usb_hid_mapping_preserves_physical_keys_and_multilingual_modifiers() {
        assert_eq!(mac_key_code(0x04), Some(0x00));
        assert_eq!(mac_key_code(0xe4), Some(0x3e));
        assert_eq!(mac_key_code(0x48), None);
        assert!(mac_modifier_flags(0xff).contains(CGEventFlags::CGEventFlagCommand));
    }

    #[test]
    fn planned_virtual_bounds_map_relative_and_absolute_pointer_motion() {
        let bounds = MacInputDisplayBounds {
            width: 2340.0,
            height: 1612.0,
        }
        .rect()
        .expect("planned bounds");
        let relative = pointer_target(
            CGPoint::new(4000.0, 4000.0),
            bounds,
            NativePointerMotionMode::Relative,
            10,
            -12,
            0.0,
            0.0,
        )
        .expect("relative target");
        assert_eq!(relative.x, 1180.0);
        assert_eq!(relative.y, 794.0);
        let absolute = pointer_target(
            CGPoint::new(0.0, 0.0),
            bounds,
            NativePointerMotionMode::Absolute,
            0,
            0,
            1.0,
            1.0,
        )
        .expect("absolute target");
        assert_eq!(absolute.x, 2339.0);
        assert_eq!(absolute.y, 1611.0);
    }

    #[test]
    fn published_session_bounds_take_precedence_over_planned_virtual_bounds() {
        let published = CGRect::new(&CGPoint::new(1440.0, 0.0), &CGSize::new(2560.0, 1440.0));
        let planned = MacInputDisplayBounds {
            width: 960.0,
            height: 540.0,
        };
        let selected = preferred_pointer_bounds(76, published, Some(planned))
            .expect("published session bounds");
        assert_eq!(selected.origin.x, 1440.0);
        assert_eq!(selected.size.width, 2560.0);
        assert_eq!(selected.size.height, 1440.0);
    }
}
