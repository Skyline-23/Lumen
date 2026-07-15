use std::collections::{HashMap, HashSet};
use std::fmt;

use lumen_engine::{NativeContactPhase, NativeGamepadButton};

use crate::PlatformNativeInputEvent;

const MAXIMUM_CONTROLLERS: usize = 16;
const NATIVE_GAMEPAD_A: u32 = 0x1000;
const NATIVE_GAMEPAD_B: u32 = 0x2000;
const NATIVE_GAMEPAD_X: u32 = 0x4000;
const NATIVE_GAMEPAD_Y: u32 = 0x8000;
const NATIVE_GAMEPAD_DPAD_UP: u32 = 0x0001;
const NATIVE_GAMEPAD_DPAD_DOWN: u32 = 0x0002;
const NATIVE_GAMEPAD_DPAD_LEFT: u32 = 0x0004;
const NATIVE_GAMEPAD_DPAD_RIGHT: u32 = 0x0008;
const NATIVE_GAMEPAD_START: u32 = 0x0010;
const NATIVE_GAMEPAD_BACK: u32 = 0x0020;
const NATIVE_GAMEPAD_LEFT_STICK: u32 = 0x0040;
const NATIVE_GAMEPAD_RIGHT_STICK: u32 = 0x0080;
const NATIVE_GAMEPAD_LEFT_BUMPER: u32 = 0x0100;
const NATIVE_GAMEPAD_RIGHT_BUMPER: u32 = 0x0200;
const NATIVE_GAMEPAD_GUIDE: u32 = 0x0400;

pub(crate) fn unicode_code_units(text: &str) -> Result<Vec<u16>, &'static str> {
    if text.is_empty() || text.contains('\0') {
        return Err("Windows text input is empty or contains NUL");
    }
    Ok(text.encode_utf16().collect())
}

#[derive(Clone, Default)]
struct SessionInputState {
    pressed_mouse_buttons: HashSet<u8>,
    pressed_hid_keys: HashSet<u16>,
    compositions: HashMap<u64, NativeComposition>,
    controllers: [Option<usize>; MAXIMUM_CONTROLLERS],
    native_gamepads: [NativeGamepadSnapshot; MAXIMUM_CONTROLLERS],
}

#[derive(Clone, Debug, PartialEq)]
struct NativeComposition {
    text: String,
    selection_start_utf8: usize,
    selection_length_utf8: usize,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeGamepadSnapshot {
    buttons: u32,
    left_trigger: u8,
    right_trigger: u8,
    left_stick_x: i16,
    left_stick_y: i16,
    right_stick_x: i16,
    right_stick_y: i16,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ControllerRoute {
    control_connect_data: u32,
    controller_number: u8,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum WindowsInputAction {
    MouseButton {
        button: u8,
        pressed: bool,
    },
    HidKeyboard {
        hid_usage: u16,
        pressed: bool,
    },
    Text {
        text: String,
    },
    ControllerAttach {
        global_index: usize,
        controller_number: u8,
        controller_type: u8,
        capabilities: u16,
        supported_button_flags: u32,
    },
    ControllerDetach {
        global_index: usize,
    },
    ControllerUpdate {
        global_index: usize,
        button_flags: u32,
        left_trigger: u8,
        right_trigger: u8,
        left_stick_x: i16,
        left_stick_y: i16,
        right_stick_x: i16,
        right_stick_y: i16,
    },
    Touch {
        event_type: u8,
        rotation: u16,
        pointer_id: u32,
        x: f32,
        y: f32,
        pressure_or_distance: f32,
        contact_area_major: f32,
        contact_area_minor: f32,
    },
    Pen {
        event_type: u8,
        tool_type: u8,
        buttons: u8,
        x: f32,
        y: f32,
        pressure_or_distance: f32,
        rotation: u16,
        tilt: u8,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum WindowsInputStateError {
    AlreadyAttached(u8),
    NotAttached(u8),
    SlotsExhausted,
    InvalidCapabilities(u32),
}

impl fmt::Display for WindowsInputStateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyAttached(controller) => {
                write!(formatter, "controller {controller} is already attached")
            }
            Self::NotAttached(controller) => {
                write!(formatter, "controller {controller} is not attached")
            }
            Self::SlotsExhausted => {
                formatter.write_str("all Windows virtual controller slots are occupied")
            }
            Self::InvalidCapabilities(capabilities) => {
                write!(
                    formatter,
                    "native controller capabilities {capabilities:#x} are invalid"
                )
            }
        }
    }
}

#[derive(Clone, Default)]
pub(crate) struct WindowsInputState {
    sessions: HashMap<u32, SessionInputState>,
    controller_routes: [Option<ControllerRoute>; MAXIMUM_CONTROLLERS],
}

impl WindowsInputState {
    pub(crate) fn reset(&mut self, control_connect_data: u32) -> Vec<WindowsInputAction> {
        let Some(session) = self.sessions.remove(&control_connect_data) else {
            return Vec::new();
        };
        let mut actions = Vec::new();
        let mut buttons: Vec<_> = session.pressed_mouse_buttons.into_iter().collect();
        buttons.sort_unstable();
        actions.extend(
            buttons
                .into_iter()
                .map(|button| WindowsInputAction::MouseButton {
                    button,
                    pressed: false,
                }),
        );
        let mut hid_keys: Vec<_> = session.pressed_hid_keys.into_iter().collect();
        hid_keys.sort_unstable();
        actions.extend(
            hid_keys
                .into_iter()
                .map(|hid_usage| WindowsInputAction::HidKeyboard {
                    hid_usage,
                    pressed: false,
                }),
        );
        for global_index in session.controllers.into_iter().flatten() {
            self.controller_routes[global_index] = None;
            actions.push(WindowsInputAction::ControllerDetach { global_index });
        }
        actions
    }

    pub(crate) fn apply_native(
        &mut self,
        session_epoch: u32,
        event: PlatformNativeInputEvent,
    ) -> Result<Vec<WindowsInputAction>, WindowsInputStateError> {
        match event {
            PlatformNativeInputEvent::Keyboard {
                hid_usage,
                pressed,
                modifiers,
                repeat,
            } => Ok(self.native_keyboard(session_epoch, hid_usage, pressed, modifiers, repeat)),
            PlatformNativeInputEvent::Text {
                text,
                composition_id,
                commit,
                selection_start_utf8,
                selection_length_utf8,
            } => {
                let session = self.sessions.entry(session_epoch).or_default();
                if commit {
                    session.compositions.remove(&composition_id);
                    Ok((!text.is_empty())
                        .then_some(WindowsInputAction::Text { text })
                        .into_iter()
                        .collect())
                } else {
                    let composition = NativeComposition {
                        text,
                        selection_start_utf8,
                        selection_length_utf8,
                    };
                    if session.compositions.get(&composition_id) != Some(&composition) {
                        session.compositions.insert(composition_id, composition);
                    }
                    Ok(Vec::new())
                }
            }
            PlatformNativeInputEvent::PointerButton {
                pointer_id: _,
                button,
                pressed,
            } => {
                let session = self.sessions.entry(session_epoch).or_default();
                let changed = if pressed {
                    session.pressed_mouse_buttons.insert(button)
                } else {
                    session.pressed_mouse_buttons.remove(&button)
                };
                Ok(changed
                    .then_some(WindowsInputAction::MouseButton { button, pressed })
                    .into_iter()
                    .collect())
            }
            PlatformNativeInputEvent::GamepadConnection {
                gamepad_id,
                connected,
                capabilities,
            } => {
                if connected {
                    let capabilities = u16::try_from(capabilities)
                        .map_err(|_| WindowsInputStateError::InvalidCapabilities(capabilities))?;
                    self.attach_controller(session_epoch, gamepad_id, 0, capabilities, u32::MAX)
                } else {
                    self.detach_controller(session_epoch, gamepad_id)
                }
            }
            PlatformNativeInputEvent::GamepadButton {
                gamepad_id,
                button,
                pressed,
                analog_value: _,
            } => {
                let global_index = self.controller_index(session_epoch, gamepad_id)?;
                let gamepad = &mut self
                    .sessions
                    .get_mut(&session_epoch)
                    .expect("controller routes require a session")
                    .native_gamepads[usize::from(gamepad_id)];
                let mask = native_gamepad_button_mask(button);
                if pressed {
                    gamepad.buttons |= mask;
                } else {
                    gamepad.buttons &= !mask;
                }
                Ok(vec![WindowsInputAction::ControllerUpdate {
                    global_index,
                    button_flags: gamepad.buttons,
                    left_trigger: gamepad.left_trigger,
                    right_trigger: gamepad.right_trigger,
                    left_stick_x: gamepad.left_stick_x,
                    left_stick_y: gamepad.left_stick_y,
                    right_stick_x: gamepad.right_stick_x,
                    right_stick_y: gamepad.right_stick_y,
                }])
            }
            PlatformNativeInputEvent::TouchContact {
                contact_id,
                phase,
                normalized_x,
                normalized_y,
                pressure,
            } => Ok(vec![WindowsInputAction::Touch {
                event_type: native_contact_event_type(phase),
                rotation: 0,
                pointer_id: contact_id,
                x: normalized_x,
                y: normalized_y,
                pressure_or_distance: pressure,
                contact_area_major: 0.0,
                contact_area_minor: 0.0,
            }]),
            PlatformNativeInputEvent::PenContact {
                pointer_id: _,
                phase,
                buttons,
                normalized_x,
                normalized_y,
                pressure,
            } => Ok(vec![WindowsInputAction::Pen {
                event_type: native_contact_event_type(phase),
                tool_type: 0,
                buttons: buttons as u8,
                x: normalized_x,
                y: normalized_y,
                pressure_or_distance: pressure,
                rotation: 0,
                tilt: 0,
            }]),
            PlatformNativeInputEvent::RumbleAcknowledged { .. } => Ok(Vec::new()),
        }
    }

    pub(crate) fn feedback_route(&self, global_index: usize) -> Option<(u32, u8)> {
        self.controller_routes
            .get(global_index)
            .and_then(|route| *route)
            .map(|route| (route.control_connect_data, route.controller_number))
    }

    fn attach_controller(
        &mut self,
        control_connect_data: u32,
        controller_number: u8,
        controller_type: u8,
        capabilities: u16,
        supported_button_flags: u32,
    ) -> Result<Vec<WindowsInputAction>, WindowsInputStateError> {
        let session = self.sessions.entry(control_connect_data).or_default();
        let slot = &mut session.controllers[usize::from(controller_number)];
        if slot.is_some() {
            return Err(WindowsInputStateError::AlreadyAttached(controller_number));
        }
        let global_index = self
            .controller_routes
            .iter()
            .position(Option::is_none)
            .ok_or(WindowsInputStateError::SlotsExhausted)?;
        *slot = Some(global_index);
        session.native_gamepads[usize::from(controller_number)] = NativeGamepadSnapshot::default();
        self.controller_routes[global_index] = Some(ControllerRoute {
            control_connect_data,
            controller_number,
        });
        Ok(vec![WindowsInputAction::ControllerAttach {
            global_index,
            controller_number,
            controller_type,
            capabilities,
            supported_button_flags,
        }])
    }

    fn detach_controller(
        &mut self,
        control_connect_data: u32,
        controller_number: u8,
    ) -> Result<Vec<WindowsInputAction>, WindowsInputStateError> {
        let global_index = self.controller_index(control_connect_data, controller_number)?;
        self.sessions
            .get_mut(&control_connect_data)
            .expect("controller routes require a session")
            .controllers[usize::from(controller_number)] = None;
        self.sessions
            .get_mut(&control_connect_data)
            .expect("controller routes require a session")
            .native_gamepads[usize::from(controller_number)] = NativeGamepadSnapshot::default();
        self.controller_routes[global_index] = None;
        Ok(vec![WindowsInputAction::ControllerDetach { global_index }])
    }

    fn controller_index(
        &self,
        control_connect_data: u32,
        controller_number: u8,
    ) -> Result<usize, WindowsInputStateError> {
        self.sessions
            .get(&control_connect_data)
            .and_then(|session| session.controllers[usize::from(controller_number)])
            .ok_or(WindowsInputStateError::NotAttached(controller_number))
    }

    fn native_keyboard(
        &mut self,
        session_epoch: u32,
        hid_usage: u16,
        pressed: bool,
        modifiers: u8,
        repeat: bool,
    ) -> Vec<WindowsInputAction> {
        let session = self.sessions.entry(session_epoch).or_default();
        let was_pressed = session.pressed_hid_keys.contains(&hid_usage);
        if pressed {
            session.pressed_hid_keys.insert(hid_usage);
        } else {
            session.pressed_hid_keys.remove(&hid_usage);
        }
        if (pressed && was_pressed && !repeat) || (!pressed && !was_pressed) {
            return Vec::new();
        }

        let modifier = hid_modifier_mask(hid_usage);
        let mut actions = Vec::new();
        if pressed && modifier.is_none() {
            let held_modifiers = session
                .pressed_hid_keys
                .iter()
                .filter_map(|usage| hid_modifier_mask(*usage))
                .fold(0_u8, |mask, modifier| mask | modifier);
            let synthetic = modifiers & !held_modifiers;
            for (mask, usage) in hid_modifier_usages() {
                if synthetic & mask != 0 {
                    actions.push(WindowsInputAction::HidKeyboard {
                        hid_usage: usage,
                        pressed: true,
                    });
                }
            }
            actions.push(WindowsInputAction::HidKeyboard { hid_usage, pressed });
            for (mask, usage) in hid_modifier_usages().into_iter().rev() {
                if synthetic & mask != 0 {
                    actions.push(WindowsInputAction::HidKeyboard {
                        hid_usage: usage,
                        pressed: false,
                    });
                }
            }
        } else {
            actions.push(WindowsInputAction::HidKeyboard { hid_usage, pressed });
        }
        actions
    }
}

fn native_gamepad_button_mask(button: NativeGamepadButton) -> u32 {
    match button {
        NativeGamepadButton::South => NATIVE_GAMEPAD_A,
        NativeGamepadButton::East => NATIVE_GAMEPAD_B,
        NativeGamepadButton::West => NATIVE_GAMEPAD_X,
        NativeGamepadButton::North => NATIVE_GAMEPAD_Y,
        NativeGamepadButton::LeftBumper => NATIVE_GAMEPAD_LEFT_BUMPER,
        NativeGamepadButton::RightBumper => NATIVE_GAMEPAD_RIGHT_BUMPER,
        NativeGamepadButton::LeftStick => NATIVE_GAMEPAD_LEFT_STICK,
        NativeGamepadButton::RightStick => NATIVE_GAMEPAD_RIGHT_STICK,
        NativeGamepadButton::Back => NATIVE_GAMEPAD_BACK,
        NativeGamepadButton::Start => NATIVE_GAMEPAD_START,
        NativeGamepadButton::Guide => NATIVE_GAMEPAD_GUIDE,
        NativeGamepadButton::DpadUp => NATIVE_GAMEPAD_DPAD_UP,
        NativeGamepadButton::DpadDown => NATIVE_GAMEPAD_DPAD_DOWN,
        NativeGamepadButton::DpadLeft => NATIVE_GAMEPAD_DPAD_LEFT,
        NativeGamepadButton::DpadRight => NATIVE_GAMEPAD_DPAD_RIGHT,
        NativeGamepadButton::Unspecified => 0,
    }
}

fn native_contact_event_type(phase: NativeContactPhase) -> u8 {
    match phase {
        NativeContactPhase::Began => 1,
        NativeContactPhase::Ended => 2,
        NativeContactPhase::Cancelled => 4,
        NativeContactPhase::Unspecified => 0,
    }
}

fn hid_modifier_mask(hid_usage: u16) -> Option<u8> {
    if (0xe0..=0xe7).contains(&hid_usage) {
        Some(1_u8 << (hid_usage - 0xe0))
    } else {
        None
    }
}

fn hid_modifier_usages() -> [(u8, u16); 8] {
    std::array::from_fn(|index| (1 << index, 0xe0 + index as u16))
}

pub(super) fn hid_scan_code(hid_usage: u16) -> Option<(u16, bool)> {
    let mapped = match hid_usage {
        0x04 => (0x1e, false),
        0x05 => (0x30, false),
        0x06 => (0x2e, false),
        0x07 => (0x20, false),
        0x08 => (0x12, false),
        0x09 => (0x21, false),
        0x0a => (0x22, false),
        0x0b => (0x23, false),
        0x0c => (0x17, false),
        0x0d => (0x24, false),
        0x0e => (0x25, false),
        0x0f => (0x26, false),
        0x10 => (0x32, false),
        0x11 => (0x31, false),
        0x12 => (0x18, false),
        0x13 => (0x19, false),
        0x14 => (0x10, false),
        0x15 => (0x13, false),
        0x16 => (0x1f, false),
        0x17 => (0x14, false),
        0x18 => (0x16, false),
        0x19 => (0x2f, false),
        0x1a => (0x11, false),
        0x1b => (0x2d, false),
        0x1c => (0x15, false),
        0x1d => (0x2c, false),
        0x1e..=0x26 => (hid_usage - 0x1e + 0x02, false),
        0x27 => (0x0b, false),
        0x28 => (0x1c, false),
        0x29 => (0x01, false),
        0x2a => (0x0e, false),
        0x2b => (0x0f, false),
        0x2c => (0x39, false),
        0x2d => (0x0c, false),
        0x2e => (0x0d, false),
        0x2f => (0x1a, false),
        0x30 => (0x1b, false),
        0x31 | 0x32 => (0x2b, false),
        0x33 => (0x27, false),
        0x34 => (0x28, false),
        0x35 => (0x29, false),
        0x36 => (0x33, false),
        0x37 => (0x34, false),
        0x38 => (0x35, false),
        0x39 => (0x3a, false),
        0x3a..=0x43 => (hid_usage - 0x3a + 0x3b, false),
        0x44 => (0x57, false),
        0x45 => (0x58, false),
        0x46 => (0x37, true),
        0x47 => (0x46, false),
        0x49 => (0x52, true),
        0x4a => (0x47, true),
        0x4b => (0x49, true),
        0x4c => (0x53, true),
        0x4d => (0x4f, true),
        0x4e => (0x51, true),
        0x4f => (0x4d, true),
        0x50 => (0x4b, true),
        0x51 => (0x50, true),
        0x52 => (0x48, true),
        0x53 => (0x45, false),
        0x54 => (0x35, true),
        0x55 => (0x37, false),
        0x56 => (0x4a, false),
        0x57 => (0x4e, false),
        0x58 => (0x1c, true),
        0x59 => (0x4f, false),
        0x5a => (0x50, false),
        0x5b => (0x51, false),
        0x5c => (0x4b, false),
        0x5d => (0x4c, false),
        0x5e => (0x4d, false),
        0x5f => (0x47, false),
        0x60 => (0x48, false),
        0x61 => (0x49, false),
        0x62 => (0x52, false),
        0x63 => (0x53, false),
        0x65 => (0x5d, true),
        0xe0 => (0x1d, false),
        0xe1 => (0x2a, false),
        0xe2 => (0x38, false),
        0xe3 => (0x5b, true),
        0xe4 => (0x1d, true),
        0xe5 => (0x36, false),
        0xe6 => (0x38, true),
        0xe7 => (0x5c, true),
        _ => return None,
    };
    Some(mapped)
}
