use std::ffi::{c_char, c_void};
use std::mem::transmute;
use std::sync::atomic::{AtomicBool, Ordering};

use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTapLocation, CGEventType, CGMouseButton, EventField,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::CGPoint;

static POST_EVENT_ACCESS_REQUESTED: AtomicBool = AtomicBool::new(false);

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

pub(super) trait MacInputEventPoster: Send + Sync {
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
pub(super) struct CoreGraphicsMacInputEventPoster;

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

pub(super) fn post_key_event(
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

pub(super) fn post_text(text: &str) -> Result<(), String> {
    let down = CGEvent::new_keyboard_event(event_source()?, 0, true)
        .map_err(|_| "could not create macOS Unicode key-down event".to_owned())?;
    down.set_string(text);
    down.post(CGEventTapLocation::HID);
    let up = CGEvent::new_keyboard_event(event_source()?, 0, false)
        .map_err(|_| "could not create macOS Unicode key-up event".to_owned())?;
    up.post(CGEventTapLocation::HID);
    Ok(())
}

pub(super) fn current_pointer_location() -> Result<CGPoint, String> {
    let source = event_source()?;
    let location = CGEvent::new(source)
        .map_err(|_| "could not inspect the macOS pointer location".to_owned())?
        .location();
    Ok(location)
}

pub(super) fn post_button_event(
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

pub(super) fn system_double_click_interval() -> Result<std::time::Duration, String> {
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
    std::time::Duration::try_from_secs_f64(seconds)
        .map_err(|_| "AppKit returned an unrepresentable double-click interval".to_owned())
}

pub(super) fn event_source() -> Result<CGEventSource, String> {
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

pub(super) fn mac_modifier_flags(modifiers: u8) -> CGEventFlags {
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

pub(super) fn mac_key_code(hid_usage: u16) -> Option<u16> {
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
