use std::mem::size_of;

use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY,
    KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, KEYEVENTF_UNICODE, MOUSEEVENTF_LEFTDOWN,
    MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_RIGHTDOWN,
    MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, MOUSEINPUT,
};

use super::input_state::{hid_scan_code, unicode_code_units};

const XBUTTON1: u16 = 0x0001;
const XBUTTON2: u16 = 0x0002;

fn inject(inputs: &[INPUT]) -> Result<(), String> {
    if inputs.is_empty() {
        return Err("Windows input batch is empty".to_owned());
    }
    let sent = unsafe {
        SendInput(
            inputs.len() as u32,
            inputs.as_ptr(),
            size_of::<INPUT>() as i32,
        )
    };
    if sent == inputs.len() as u32 {
        Ok(())
    } else {
        Err(format!(
            "Windows SendInput accepted {sent}/{} events",
            inputs.len()
        ))
    }
}

fn mouse(dx: i32, dy: i32, data: u32, flags: u32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: data,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn key(virtual_key: u16, scan_code: u16, flags: u32) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: virtual_key,
                wScan: scan_code,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

pub(super) fn button(button: u8, pressed: bool) -> Result<(), String> {
    let (flags, data) = match (button, pressed) {
        (1, true) => (MOUSEEVENTF_LEFTDOWN, 0),
        (1, false) => (MOUSEEVENTF_LEFTUP, 0),
        (2, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
        (2, false) => (MOUSEEVENTF_MIDDLEUP, 0),
        (3, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
        (3, false) => (MOUSEEVENTF_RIGHTUP, 0),
        (4, true) => (MOUSEEVENTF_XDOWN, u32::from(XBUTTON1)),
        (4, false) => (MOUSEEVENTF_XUP, u32::from(XBUTTON1)),
        (5, true) => (MOUSEEVENTF_XDOWN, u32::from(XBUTTON2)),
        (5, false) => (MOUSEEVENTF_XUP, u32::from(XBUTTON2)),
        _ => return Err(format!("unsupported Windows mouse button {button}")),
    };
    inject(&[mouse(0, 0, data, flags)])
}

pub(super) fn hid_keyboard(hid_usage: u16, pressed: bool) -> Result<(), String> {
    let (scan_code, extended) = hid_scan_code(hid_usage)
        .ok_or_else(|| format!("unsupported Windows USB HID keyboard usage {hid_usage:#x}"))?;
    let mut flags = KEYEVENTF_SCANCODE;
    if extended {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    if !pressed {
        flags |= KEYEVENTF_KEYUP;
    }
    inject(&[key(0, scan_code, flags)])
}

pub(super) fn text(utf8: &[u8]) -> Result<(), String> {
    let text = std::str::from_utf8(utf8)
        .map_err(|error| format!("Windows text input is not valid UTF-8: {error}"))?;
    let code_units = unicode_code_units(text).map_err(str::to_owned)?;
    let mut inputs = Vec::with_capacity(code_units.len() * 2);
    for code_unit in code_units {
        inputs.push(key(0, code_unit, KEYEVENTF_UNICODE));
        inputs.push(key(0, code_unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
    }
    inject(&inputs)
}
