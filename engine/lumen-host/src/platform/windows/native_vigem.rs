use std::collections::VecDeque;
use std::ffi::c_void;
use std::sync::{Arc, Mutex};

use crate::{LumenHostPlatformControlFeedback, LumenHostPlatformControlFeedbackKind};

const SUCCESS: u32 = 0x2000_0000;
const MAX_GAMEPADS: usize = 16;
const MAX_FEEDBACK: usize = 64;
const TYPE_PLAYSTATION: u8 = 2;
const CAP_TOUCHPAD: u16 = 0x08;
const CAP_ACCEL: u16 = 0x10;
const CAP_GYRO: u16 = 0x20;

const DPAD_UP: u32 = 0x0001;
const DPAD_DOWN: u32 = 0x0002;
const DPAD_LEFT: u32 = 0x0004;
const DPAD_RIGHT: u32 = 0x0008;
const START: u32 = 0x0010;
const BACK: u32 = 0x0020;
const LEFT_STICK: u32 = 0x0040;
const RIGHT_STICK: u32 = 0x0080;
const LEFT_SHOULDER: u32 = 0x0100;
const RIGHT_SHOULDER: u32 = 0x0200;
const HOME: u32 = 0x0400;
const A: u32 = 0x1000;
const B: u32 = 0x2000;
const X: u32 = 0x4000;
const Y: u32 = 0x8000;
const TOUCHPAD: u32 = 0x100000;
const MISC: u32 = 0x200000;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct XusbReport {
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    left_x: i16,
    left_y: i16,
    right_x: i16,
    right_y: i16,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct Ds4ReportEx {
    bytes: [u8; 63],
}

impl Default for Ds4ReportEx {
    fn default() -> Self {
        let mut bytes = [0_u8; 63];
        bytes[0..4].fill(0x80);
        bytes[4] = 8;
        bytes[11] = 0xff;
        bytes[29] = 0x1a;
        bytes[32] = 1;
        bytes[34] = 0x80;
        bytes[38] = 0x80;
        Self { bytes }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
struct LightbarColor {
    red: u8,
    green: u8,
    blue: u8,
}

const _: () = assert!(std::mem::size_of::<XusbReport>() == 12);
const _: () = assert!(std::mem::size_of::<Ds4ReportEx>() == 63);
const _: () = assert!(std::mem::size_of::<LightbarColor>() == 3);

type X360Callback = unsafe extern "system" fn(*mut c_void, *mut c_void, u8, u8, u8, *mut c_void);
type Ds4Callback =
    unsafe extern "system" fn(*mut c_void, *mut c_void, u8, u8, LightbarColor, *mut c_void);

unsafe extern "C" {
    fn vigem_alloc() -> *mut c_void;
    fn vigem_free(client: *mut c_void);
    fn vigem_connect(client: *mut c_void) -> u32;
    fn vigem_disconnect(client: *mut c_void);
    fn vigem_target_x360_alloc() -> *mut c_void;
    fn vigem_target_ds4_alloc() -> *mut c_void;
    fn vigem_target_free(target: *mut c_void);
    fn vigem_target_add(client: *mut c_void, target: *mut c_void) -> u32;
    fn vigem_target_remove(client: *mut c_void, target: *mut c_void) -> u32;
    fn vigem_target_x360_register_notification(
        client: *mut c_void,
        target: *mut c_void,
        callback: X360Callback,
        user: *mut c_void,
    ) -> u32;
    fn vigem_target_ds4_register_notification(
        client: *mut c_void,
        target: *mut c_void,
        callback: Ds4Callback,
        user: *mut c_void,
    ) -> u32;
    fn vigem_target_x360_update(
        client: *mut c_void,
        target: *mut c_void,
        report: XusbReport,
    ) -> u32;
    fn vigem_target_ds4_update_ex(
        client: *mut c_void,
        target: *mut c_void,
        report: Ds4ReportEx,
    ) -> u32;
}

type FeedbackQueue = Arc<Mutex<VecDeque<LumenHostPlatformControlFeedback>>>;

struct CallbackContext {
    index: u8,
    queue: FeedbackQueue,
}

struct Gamepad {
    target: usize,
    ds4: bool,
    xusb: XusbReport,
    ds4_report: Ds4ReportEx,
    callback: Box<CallbackContext>,
}

unsafe extern "system" fn x360_feedback(
    _: *mut c_void,
    _: *mut c_void,
    large: u8,
    small: u8,
    _: u8,
    user: *mut c_void,
) {
    let context = unsafe { &*(user as *const CallbackContext) };
    enqueue(
        &context.queue,
        feedback(
            context.index,
            LumenHostPlatformControlFeedbackKind::Rumble,
            u16::from(large) * 257,
            u16::from(small) * 257,
        ),
    );
}

unsafe extern "system" fn ds4_feedback(
    _: *mut c_void,
    _: *mut c_void,
    large: u8,
    small: u8,
    color: LightbarColor,
    user: *mut c_void,
) {
    let context = unsafe { &*(user as *const CallbackContext) };
    enqueue(
        &context.queue,
        feedback(
            context.index,
            LumenHostPlatformControlFeedbackKind::Rumble,
            u16::from(large) * 257,
            u16::from(small) * 257,
        ),
    );
    let mut led = feedback(
        context.index,
        LumenHostPlatformControlFeedbackKind::RgbLed,
        0,
        0,
    );
    led.red = color.red;
    led.green = color.green;
    led.blue = color.blue;
    enqueue(&context.queue, led);
}

fn feedback(
    index: u8,
    kind: LumenHostPlatformControlFeedbackKind,
    a: u16,
    b: u16,
) -> LumenHostPlatformControlFeedback {
    LumenHostPlatformControlFeedback {
        kind,
        control_connect_data: 0,
        controller_id: u16::from(index),
        value_a: a,
        value_b: b,
        report_rate: 0,
        motion_type: 0,
        red: 0,
        green: 0,
        blue: 0,
        event_flags: 0,
        type_left: 0,
        type_right: 0,
        left: [0; 10],
        right: [0; 10],
    }
}

fn enqueue(queue: &FeedbackQueue, value: LumenHostPlatformControlFeedback) {
    if let Ok(mut queue) = queue.lock() {
        if queue.len() == MAX_FEEDBACK {
            queue.pop_front();
        }
        queue.push_back(value);
    }
}

pub(super) struct NativeVigem {
    client: usize,
    connected: bool,
    gamepads: [Option<Gamepad>; MAX_GAMEPADS],
    feedback: FeedbackQueue,
}

pub(super) struct NativeGamepadState {
    pub(super) buttons: u32,
    pub(super) left_trigger: u8,
    pub(super) right_trigger: u8,
    pub(super) left_stick_x: i16,
    pub(super) left_stick_y: i16,
    pub(super) right_stick_x: i16,
    pub(super) right_stick_y: i16,
}

impl Default for NativeVigem {
    fn default() -> Self {
        Self {
            client: 0,
            connected: false,
            gamepads: std::array::from_fn(|_| None),
            feedback: Arc::new(Mutex::new(VecDeque::new())),
        }
    }
}

impl NativeVigem {
    fn client(&mut self) -> Result<*mut c_void, String> {
        if self.client == 0 {
            self.client = unsafe { vigem_alloc() } as usize;
        }
        if self.client == 0 {
            return Err("ViGEm client allocation failed".to_owned());
        }
        if !self.connected {
            let status = unsafe { vigem_connect(self.client as *mut _) };
            if status != SUCCESS {
                return Err(format!("ViGEm connect failed: {status:#x}"));
            }
            self.connected = true;
        }
        Ok(self.client as *mut _)
    }

    pub(super) fn attach(
        &mut self,
        index: usize,
        controller_type: u8,
        capabilities: u16,
    ) -> Result<(), String> {
        if index >= MAX_GAMEPADS {
            return Err("controller index exceeds ViGEm capacity".to_owned());
        }
        self.detach(index)?;
        let client = self.client()?;
        let ds4 = controller_type == TYPE_PLAYSTATION
            || capabilities & (CAP_TOUCHPAD | CAP_ACCEL | CAP_GYRO) != 0;
        let target = unsafe {
            if ds4 {
                vigem_target_ds4_alloc()
            } else {
                vigem_target_x360_alloc()
            }
        };
        if target.is_null() {
            return Err("ViGEm target allocation failed".to_owned());
        }
        let mut gamepad = Gamepad {
            target: target as usize,
            ds4,
            xusb: XusbReport::default(),
            ds4_report: Ds4ReportEx::default(),
            callback: Box::new(CallbackContext {
                index: index as u8,
                queue: Arc::clone(&self.feedback),
            }),
        };
        if unsafe { vigem_target_add(client, target) } != SUCCESS {
            unsafe { vigem_target_free(target) };
            return Err("ViGEm target add failed".to_owned());
        }
        let user = (&mut *gamepad.callback) as *mut CallbackContext as *mut c_void;
        let registered = unsafe {
            if ds4 {
                vigem_target_ds4_register_notification(client, target, ds4_feedback, user)
            } else {
                vigem_target_x360_register_notification(client, target, x360_feedback, user)
            }
        };
        if registered != SUCCESS {
            unsafe {
                vigem_target_remove(client, target);
                vigem_target_free(target);
            }
            return Err("ViGEm feedback registration failed".to_owned());
        }
        self.gamepads[index] = Some(gamepad);
        Ok(())
    }

    pub(super) fn detach(&mut self, index: usize) -> Result<(), String> {
        if index >= MAX_GAMEPADS {
            return Err("controller index exceeds ViGEm capacity".to_owned());
        }
        let Some(gamepad) = self.gamepads[index].take() else {
            return Ok(());
        };
        if self.connected {
            unsafe {
                vigem_target_remove(self.client as *mut _, gamepad.target as *mut _);
            }
        }
        unsafe { vigem_target_free(gamepad.target as *mut _) };
        Ok(())
    }

    pub(super) fn update(&mut self, index: usize, state: NativeGamepadState) -> Result<(), String> {
        let client = self.client as *mut c_void;
        let gamepad = self
            .gamepads
            .get_mut(index)
            .and_then(Option::as_mut)
            .ok_or_else(|| "controller is not attached".to_owned())?;
        let status = if gamepad.ds4 {
            let report = &mut gamepad.ds4_report.bytes;
            report[0] = axis(state.left_stick_x);
            report[1] = 255 - axis(state.left_stick_y);
            report[2] = axis(state.right_stick_x);
            report[3] = 255 - axis(state.right_stick_y);
            write_u16(
                report,
                4,
                ds4_buttons(state.buttons, state.left_trigger, state.right_trigger)
                    | u16::from(ds4_dpad(state.buttons)),
            );
            report[6] = ((state.buttons & HOME != 0) as u8)
                | (((state.buttons & (TOUCHPAD | MISC) != 0) as u8) << 1);
            report[7] = state.left_trigger;
            report[8] = state.right_trigger;
            unsafe {
                vigem_target_ds4_update_ex(client, gamepad.target as *mut _, gamepad.ds4_report)
            }
        } else {
            gamepad.xusb = XusbReport {
                buttons: xusb_buttons(state.buttons),
                left_trigger: state.left_trigger,
                right_trigger: state.right_trigger,
                left_x: state.left_stick_x,
                left_y: state.left_stick_y,
                right_x: state.right_stick_x,
                right_y: state.right_stick_y,
            };
            unsafe { vigem_target_x360_update(client, gamepad.target as *mut _, gamepad.xusb) }
        };
        if status == SUCCESS {
            Ok(())
        } else {
            Err(format!("ViGEm update failed: {status:#x}"))
        }
    }

    pub(super) fn poll_feedback(
        &mut self,
    ) -> Result<Option<LumenHostPlatformControlFeedback>, String> {
        self.feedback
            .lock()
            .map(|mut queue| queue.pop_front())
            .map_err(|_| "ViGEm feedback queue is poisoned".to_owned())
    }
}

impl Drop for NativeVigem {
    fn drop(&mut self) {
        for index in 0..MAX_GAMEPADS {
            let _ = self.detach(index);
        }
        unsafe {
            if self.connected {
                vigem_disconnect(self.client as *mut _);
            }
            if self.client != 0 {
                vigem_free(self.client as *mut _);
            }
        }
    }
}

fn axis(value: i16) -> u8 {
    ((i32::from(value) + 32768) / 257) as u8
}
fn write_u16(bytes: &mut [u8], offset: usize, value: u16) {
    bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}
fn xusb_buttons(flags: u32) -> u16 {
    (flags as u16 & 0x83ff)
        | if flags & (HOME | MISC) != 0 {
            0x0400
        } else {
            0
        }
        | (flags as u16 & 0xf000)
}
fn ds4_dpad(flags: u32) -> u8 {
    match (
        flags & DPAD_UP != 0,
        flags & DPAD_DOWN != 0,
        flags & DPAD_LEFT != 0,
        flags & DPAD_RIGHT != 0,
    ) {
        (true, _, _, true) => 1,
        (_, true, _, true) => 3,
        (_, true, true, _) => 5,
        (true, _, true, _) => 7,
        (true, _, _, _) => 0,
        (_, _, _, true) => 2,
        (_, true, _, _) => 4,
        (_, _, true, _) => 6,
        _ => 8,
    }
}
fn ds4_buttons(flags: u32, lt: u8, rt: u8) -> u16 {
    let mut value = 0;
    if flags & LEFT_STICK != 0 {
        value |= 1 << 14
    }
    if flags & RIGHT_STICK != 0 {
        value |= 1 << 15
    }
    if flags & LEFT_SHOULDER != 0 {
        value |= 1 << 8
    }
    if flags & RIGHT_SHOULDER != 0 {
        value |= 1 << 9
    }
    if flags & START != 0 {
        value |= 1 << 13
    }
    if flags & BACK != 0 {
        value |= 1 << 12
    }
    if flags & A != 0 {
        value |= 1 << 5
    }
    if flags & B != 0 {
        value |= 1 << 6
    }
    if flags & X != 0 {
        value |= 1 << 4
    }
    if flags & Y != 0 {
        value |= 1 << 7
    }
    if lt > 0 {
        value |= 1 << 10
    }
    if rt > 0 {
        value |= 1 << 11
    }
    value
}
