use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use core_graphics::display::CGDisplay;
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTapLocation, CGEventType, CGMouseButton, EventField,
    ScrollEventUnit,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::CGPoint;
use lumen_engine::NativePointerMotionMode;

use crate::{PlatformNativeInputEvent, PlatformNativeMotionEvent};

#[derive(Debug, Default)]
struct MacInputState {
    pressed_keys: HashSet<u16>,
    pressed_buttons: HashSet<u8>,
    compositions: HashMap<u64, MacComposition>,
    scroll_remainder_x: i32,
    scroll_remainder_y: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MacComposition {
    text: String,
    selection_start_utf8: usize,
    selection_length_utf8: usize,
}

#[derive(Default)]
pub(crate) struct MacNativeInput {
    state: Mutex<HashMap<u32, MacInputState>>,
}

impl MacNativeInput {
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
                if pressed {
                    state.pressed_keys.insert(hid_usage);
                } else {
                    state.pressed_keys.remove(&hid_usage);
                }
                if (pressed && was_pressed && !repeat) || (!pressed && !was_pressed) {
                    return Ok(());
                }
                post_key(hid_usage, pressed, modifiers)
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
            } => {
                let changed = if pressed {
                    state.pressed_buttons.insert(button)
                } else {
                    state.pressed_buttons.remove(&button)
                };
                if changed {
                    post_button(button, pressed)
                } else {
                    Ok(())
                }
            }
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
                state,
                mode,
                delta_x,
                delta_y,
                normalized_x,
                normalized_y,
            ),
            PlatformNativeMotionEvent::Scroll {
                pointer_id: _,
                delta_x_1024_points,
                delta_y_1024_points,
            } => {
                state.scroll_remainder_x =
                    state.scroll_remainder_x.saturating_add(delta_x_1024_points);
                state.scroll_remainder_y =
                    state.scroll_remainder_y.saturating_add(delta_y_1024_points);
                let horizontal = state.scroll_remainder_x / 1024;
                let vertical = state.scroll_remainder_y / 1024;
                state.scroll_remainder_x %= 1024;
                state.scroll_remainder_y %= 1024;
                if horizontal == 0 && vertical == 0 {
                    return Ok(());
                }
                let event = CGEvent::new_scroll_event(
                    event_source()?,
                    ScrollEventUnit::PIXEL,
                    2,
                    vertical,
                    horizontal,
                    0,
                )
                .map_err(|_| "could not create macOS scroll event".to_owned())?;
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

    pub(crate) fn reset(&self, session_epoch: u32) -> Result<(), String> {
        let state = self
            .state
            .lock()
            .map_err(|_| "macOS native input state is unavailable".to_owned())?
            .remove(&session_epoch);
        let Some(state) = state else {
            return Ok(());
        };
        let mut errors = Vec::new();
        let mut keys: Vec<_> = state.pressed_keys.into_iter().collect();
        keys.sort_unstable();
        for hid_usage in keys {
            if let Err(error) = post_key(hid_usage, false, 0) {
                errors.push(error);
            }
        }
        let mut buttons: Vec<_> = state.pressed_buttons.into_iter().collect();
        buttons.sort_unstable();
        for button in buttons {
            if let Err(error) = post_button(button, false) {
                errors.push(error);
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }
}

fn post_pointer_motion(
    display_id: u32,
    state: &MacInputState,
    mode: NativePointerMotionMode,
    delta_x: i32,
    delta_y: i32,
    normalized_x: f32,
    normalized_y: f32,
) -> Result<(), String> {
    let source = event_source()?;
    let current = CGEvent::new(source.clone())
        .map_err(|_| "could not inspect the macOS pointer location".to_owned())?
        .location();
    let bounds = CGDisplay::new(display_id).bounds();
    if bounds.size.width <= 0.0 || bounds.size.height <= 0.0 {
        return Err(format!(
            "macOS native motion display {display_id} has no published bounds"
        ));
    }
    let target = match mode {
        NativePointerMotionMode::Relative => {
            let origin = if point_in_rect(current, bounds) {
                current
            } else {
                CGPoint::new(
                    bounds.origin.x + bounds.size.width / 2.0,
                    bounds.origin.y + bounds.size.height / 2.0,
                )
            };
            CGPoint::new(
                (origin.x + f64::from(delta_x))
                    .clamp(bounds.origin.x, bounds.origin.x + bounds.size.width - 1.0),
                (origin.y + f64::from(delta_y))
                    .clamp(bounds.origin.y, bounds.origin.y + bounds.size.height - 1.0),
            )
        }
        NativePointerMotionMode::Absolute => CGPoint::new(
            bounds.origin.x + f64::from(normalized_x) * (bounds.size.width - 1.0),
            bounds.origin.y + f64::from(normalized_y) * (bounds.size.height - 1.0),
        ),
        NativePointerMotionMode::Unspecified => {
            return Err("macOS native pointer motion mode is unspecified".to_owned())
        }
    };
    let (event_type, button) = drag_event(state);
    let event = CGEvent::new_mouse_event(source, event_type, target, button)
        .map_err(|_| "could not create macOS pointer motion event".to_owned())?;
    event.set_integer_value_field(EventField::MOUSE_EVENT_DELTA_X, i64::from(delta_x));
    event.set_integer_value_field(EventField::MOUSE_EVENT_DELTA_Y, i64::from(delta_y));
    event.post(CGEventTapLocation::HID);
    Ok(())
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

fn post_key(hid_usage: u16, pressed: bool, modifiers: u8) -> Result<(), String> {
    let key_code = mac_key_code(hid_usage)
        .ok_or_else(|| format!("unsupported macOS USB HID keyboard usage {hid_usage:#x}"))?;
    let event = CGEvent::new_keyboard_event(event_source()?, key_code, pressed)
        .map_err(|_| "could not create macOS keyboard event".to_owned())?;
    event.set_flags(mac_modifier_flags(modifiers));
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

fn post_button(button: u8, pressed: bool) -> Result<(), String> {
    let source = event_source()?;
    let location = CGEvent::new(source.clone())
        .map_err(|_| "could not inspect the macOS pointer location".to_owned())?
        .location();
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
    event.post(CGEventTapLocation::HID);
    Ok(())
}

fn event_source() -> Result<CGEventSource, String> {
    CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| "could not create macOS HID event source".to_owned())
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
    use super::*;

    #[test]
    fn usb_hid_mapping_preserves_physical_keys_and_multilingual_modifiers() {
        assert_eq!(mac_key_code(0x04), Some(0x00));
        assert_eq!(mac_key_code(0xe4), Some(0x3e));
        assert_eq!(mac_key_code(0x48), None);
        assert!(mac_modifier_flags(0xff).contains(CGEventFlags::CGEventFlagCommand));
    }
}
