use std::collections::BTreeMap;

use lumen_engine::settings::CommandInvocation;
use lumen_engine::NativeGamepadButton;

use crate::PlatformNativeInputEvent;

use super::input_state::{
    hid_scan_code, unicode_code_units, WindowsInputAction, WindowsInputState,
    WindowsInputStateError,
};
use super::process_command_line::{environment_block, invocation_command_line};

const SESSION_A: u32 = 21_101;
const SESSION_B: u32 = 21_102;

fn connection(gamepad_id: u8, connected: bool) -> PlatformNativeInputEvent {
    PlatformNativeInputEvent::GamepadConnection {
        gamepad_id,
        connected,
        capabilities: 0x33,
    }
}

#[test]
fn allocates_global_controller_slots_and_routes_feedback_to_the_origin_session() {
    let mut state = WindowsInputState::default();
    assert_eq!(
        state.apply_native(SESSION_A, connection(3, true)).unwrap(),
        vec![WindowsInputAction::ControllerAttach {
            global_index: 0,
            controller_number: 3,
            controller_type: 0,
            capabilities: 0x33,
            supported_button_flags: u32::MAX,
        }]
    );
    assert_eq!(
        state.apply_native(SESSION_B, connection(1, true)).unwrap(),
        vec![WindowsInputAction::ControllerAttach {
            global_index: 1,
            controller_number: 1,
            controller_type: 0,
            capabilities: 0x33,
            supported_button_flags: u32::MAX,
        }]
    );
    assert_eq!(state.feedback_route(0), Some((SESSION_A, 3)));
    assert_eq!(state.feedback_route(1), Some((SESSION_B, 1)));
}

#[test]
fn strictly_requires_native_connection_before_gamepad_state() {
    let mut state = WindowsInputState::default();
    let button = PlatformNativeInputEvent::GamepadButton {
        gamepad_id: 0,
        button: NativeGamepadButton::South,
        pressed: true,
        analog_value: u16::MAX,
    };
    assert_eq!(
        state.apply_native(SESSION_A, button.clone()),
        Err(WindowsInputStateError::NotAttached(0))
    );
    state.apply_native(SESSION_A, connection(0, true)).unwrap();
    assert_eq!(
        state.apply_native(SESSION_A, connection(0, true)),
        Err(WindowsInputStateError::AlreadyAttached(0))
    );
    assert_eq!(
        state.apply_native(SESSION_A, button).unwrap(),
        vec![WindowsInputAction::ControllerUpdate {
            global_index: 0,
            button_flags: 0x1000,
            left_trigger: 0,
            right_trigger: 0,
            left_stick_x: 0,
            left_stick_y: 0,
            right_stick_x: 0,
            right_stick_y: 0,
        }]
    );
}

#[test]
fn updates_and_detaches_only_the_named_native_controller() {
    let mut state = WindowsInputState::default();
    state.apply_native(SESSION_A, connection(2, true)).unwrap();
    assert_eq!(
        state
            .apply_native(
                SESSION_A,
                PlatformNativeInputEvent::GamepadButton {
                    gamepad_id: 2,
                    button: NativeGamepadButton::Guide,
                    pressed: true,
                    analog_value: u16::MAX,
                },
            )
            .unwrap(),
        vec![WindowsInputAction::ControllerUpdate {
            global_index: 0,
            button_flags: 0x0400,
            left_trigger: 0,
            right_trigger: 0,
            left_stick_x: 0,
            left_stick_y: 0,
            right_stick_x: 0,
            right_stick_y: 0,
        }]
    );
    assert_eq!(
        state.apply_native(SESSION_A, connection(2, false)).unwrap(),
        vec![WindowsInputAction::ControllerDetach { global_index: 0 }]
    );
    assert_eq!(state.feedback_route(0), None);
}

#[test]
fn native_hid_and_multilingual_composition_preserve_exact_desktop_semantics() {
    assert_eq!(
        unicode_code_units("한글🙂").unwrap(),
        vec![0xd55c, 0xae00, 0xd83d, 0xde42]
    );
    assert!(unicode_code_units("").is_err());
    assert!(unicode_code_units("unsafe\0text").is_err());
    let command = invocation_command_line(&CommandInvocation {
        program: r"C:\Program Files\Lumen\app.exe".to_owned(),
        arguments: vec![
            "plain".to_owned(),
            "two words".to_owned(),
            "quote\"here".to_owned(),
            r"C:\path with space\".to_owned(),
        ],
    })
    .unwrap();
    assert_eq!(
        String::from_utf16(&command[..command.len() - 1]).unwrap(),
        r#""C:\Program Files\Lumen\app.exe" plain "two words" "quote\"here" "C:\path with space\\""#
    );
    let environment = environment_block(&BTreeMap::from([
        ("LUMEN_LANGUAGE".to_owned(), "한국어".to_owned()),
        ("PATH".to_owned(), r"C:\Old".to_owned()),
        ("Path".to_owned(), r"C:\Lumen".to_owned()),
    ]))
    .unwrap();
    assert!(environment.ends_with(&[0, 0]));
    assert!(environment
        .windows(3)
        .any(|units| units == [0xd55c, 0xad6d, 0xc5b4]));
    assert_eq!(
        String::from_utf16(&environment)
            .unwrap()
            .to_lowercase()
            .matches("path=")
            .count(),
        1
    );

    assert_eq!(hid_scan_code(0x04), Some((0x1e, false)));
    assert_eq!(hid_scan_code(0xe4), Some((0x1d, true)));
    let mut state = WindowsInputState::default();
    assert_eq!(
        state
            .apply_native(
                SESSION_A,
                PlatformNativeInputEvent::Keyboard {
                    hid_usage: 0x04,
                    pressed: true,
                    modifiers: 0x01,
                    repeat: false,
                },
            )
            .unwrap(),
        vec![
            WindowsInputAction::HidKeyboard {
                hid_usage: 0xe0,
                pressed: true,
            },
            WindowsInputAction::HidKeyboard {
                hid_usage: 0x04,
                pressed: true,
            },
            WindowsInputAction::HidKeyboard {
                hid_usage: 0xe0,
                pressed: false,
            },
        ]
    );
    assert!(state
        .apply_native(
            SESSION_A,
            PlatformNativeInputEvent::Text {
                text: "한글".to_owned(),
                composition_id: 7,
                commit: false,
                selection_start_utf8: 6,
                selection_length_utf8: 0,
            },
        )
        .unwrap()
        .is_empty());
    assert_eq!(
        state
            .apply_native(
                SESSION_A,
                PlatformNativeInputEvent::Text {
                    text: "한글".to_owned(),
                    composition_id: 7,
                    commit: true,
                    selection_start_utf8: 6,
                    selection_length_utf8: 0,
                },
            )
            .unwrap(),
        vec![WindowsInputAction::Text {
            text: "한글".to_owned(),
        }]
    );
}

#[test]
fn reset_releases_native_pressed_state_and_detaches_every_session_controller() {
    let mut state = WindowsInputState::default();
    state
        .apply_native(
            SESSION_A,
            PlatformNativeInputEvent::PointerButton {
                pointer_id: 0,
                button: 2,
                pressed: true,
            },
        )
        .unwrap();
    state
        .apply_native(
            SESSION_A,
            PlatformNativeInputEvent::Keyboard {
                hid_usage: 0x05,
                pressed: true,
                modifiers: 0,
                repeat: false,
            },
        )
        .unwrap();
    state.apply_native(SESSION_A, connection(4, true)).unwrap();
    assert_eq!(
        state.reset(SESSION_A),
        vec![
            WindowsInputAction::MouseButton {
                button: 2,
                pressed: false,
            },
            WindowsInputAction::HidKeyboard {
                hid_usage: 0x05,
                pressed: false,
            },
            WindowsInputAction::ControllerDetach { global_index: 0 },
        ]
    );
    assert_eq!(state.feedback_route(0), None);
    assert!(state.reset(SESSION_A).is_empty());
}
