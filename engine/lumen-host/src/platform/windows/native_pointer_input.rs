use std::collections::HashMap;

use windows_sys::Win32::Foundation::{POINT, RECT};
use windows_sys::Win32::UI::Controls::{
    CreateSyntheticPointerDevice, DestroySyntheticPointerDevice, POINTER_FEEDBACK_DEFAULT,
    POINTER_TYPE_INFO, POINTER_TYPE_INFO_0,
};
use windows_sys::Win32::UI::Input::Pointer::{
    InjectSyntheticPointerInput, POINTER_FLAG_CANCELED, POINTER_FLAG_DOWN, POINTER_FLAG_INCONTACT,
    POINTER_FLAG_INRANGE, POINTER_FLAG_UP, POINTER_FLAG_UPDATE, POINTER_INFO, POINTER_PEN_INFO,
    POINTER_TOUCH_INFO,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, PEN_FLAG_BARREL, PEN_FLAG_ERASER, PEN_MASK_PRESSURE, PEN_MASK_ROTATION,
    PEN_MASK_TILT_X, PEN_MASK_TILT_Y, PT_PEN, PT_TOUCH, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
    SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, TOUCH_MASK_CONTACTAREA, TOUCH_MASK_ORIENTATION,
    TOUCH_MASK_PRESSURE,
};

const HOVER: u8 = 0;
const DOWN: u8 = 1;
const UP: u8 = 2;
const MOVE: u8 = 3;
const CANCEL: u8 = 4;
const BUTTON_ONLY: u8 = 5;
const HOVER_LEAVE: u8 = 6;
const CANCEL_ALL: u8 = 7;
const ROTATION_UNKNOWN: u16 = 0xffff;
const TILT_UNKNOWN: u8 = 0xff;
const TOOL_ERASER: u8 = 2;
const MAX_TOUCHES: u32 = 16;

pub(super) struct NativeTouchInput {
    pub(super) event_type: u8,
    pub(super) rotation: u16,
    pub(super) pointer_id: u32,
    pub(super) x: f32,
    pub(super) y: f32,
    pub(super) pressure_or_distance: f32,
    pub(super) contact_area_major: f32,
    pub(super) contact_area_minor: f32,
}

pub(super) struct NativePenInput {
    pub(super) event_type: u8,
    pub(super) tool_type: u8,
    pub(super) buttons: u8,
    pub(super) x: f32,
    pub(super) y: f32,
    pub(super) pressure_or_distance: f32,
    pub(super) rotation: u16,
    pub(super) tilt: u8,
}

fn flags(event: u8) -> Result<u32, String> {
    match event {
        HOVER => Ok(POINTER_FLAG_INRANGE | POINTER_FLAG_UPDATE),
        DOWN => Ok(POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_DOWN),
        UP => Ok(POINTER_FLAG_UP),
        MOVE => Ok(POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_UPDATE),
        CANCEL | CANCEL_ALL => Ok(POINTER_FLAG_UP | POINTER_FLAG_CANCELED),
        BUTTON_ONLY | HOVER_LEAVE => Ok(POINTER_FLAG_UPDATE),
        value => Err(format!("unsupported Windows pointer event {value}")),
    }
}

fn location(x: f32, y: f32) -> POINT {
    let left = unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) };
    let top = unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) };
    let width = unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) }.max(1);
    let height = unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) }.max(1);
    POINT {
        x: left + (x.clamp(0.0, 1.0) * (width - 1) as f32).round() as i32,
        y: top + (y.clamp(0.0, 1.0) * (height - 1) as f32).round() as i32,
    }
}

fn common(pointer_type: i32, id: u32, event: u8, x: f32, y: f32) -> Result<POINTER_INFO, String> {
    Ok(POINTER_INFO {
        pointerType: pointer_type,
        pointerId: id,
        pointerFlags: flags(event)?,
        ptPixelLocation: location(x, y),
        ..Default::default()
    })
}

fn inject(device: usize, info: &POINTER_TYPE_INFO) -> Result<(), String> {
    (unsafe { InjectSyntheticPointerInput(device as *mut _, info, 1) } != 0)
        .then_some(())
        .ok_or_else(|| "Windows synthetic pointer injection failed".to_owned())
}

#[derive(Default)]
pub(super) struct NativePointerInput {
    touch_device: usize,
    pen_device: usize,
    touches: HashMap<(u32, u32), u32>,
    pen_session: Option<u32>,
}

impl NativePointerInput {
    fn ensure_touch(&mut self) -> Result<usize, String> {
        if self.touch_device == 0 {
            self.touch_device = unsafe {
                CreateSyntheticPointerDevice(PT_TOUCH, MAX_TOUCHES, POINTER_FEEDBACK_DEFAULT)
            } as usize;
        }
        (self.touch_device != 0)
            .then_some(self.touch_device)
            .ok_or_else(|| "Windows synthetic touch device creation failed".to_owned())
    }

    fn ensure_pen(&mut self) -> Result<usize, String> {
        if self.pen_device == 0 {
            self.pen_device =
                unsafe { CreateSyntheticPointerDevice(PT_PEN, 1, POINTER_FEEDBACK_DEFAULT) }
                    as usize;
        }
        (self.pen_device != 0)
            .then_some(self.pen_device)
            .ok_or_else(|| "Windows synthetic pen device creation failed".to_owned())
    }

    pub(super) fn touch(&mut self, session: u32, event: &NativeTouchInput) -> Result<(), String> {
        if event.event_type == CANCEL_ALL {
            return self.reset_touches(session);
        }
        let key = (session, event.pointer_id);
        let id = match self.touches.get(&key).copied() {
            Some(id) => id,
            None if matches!(event.event_type, DOWN | HOVER) => {
                let id = (1..=MAX_TOUCHES)
                    .find(|candidate| !self.touches.values().any(|used| used == candidate))
                    .ok_or_else(|| "Windows touch capacity exhausted".to_owned())?;
                self.touches.insert(key, id);
                id
            }
            None => return Err("Windows touch references an unknown pointer".to_owned()),
        };
        let point = location(event.x, event.y);
        let screen_width = unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) }.max(1);
        let screen_height = unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) }.max(1);
        let contact_width =
            (event.contact_area_major.clamp(0.0, 1.0) * screen_width as f32).round() as i32;
        let contact_height =
            (event.contact_area_minor.clamp(0.0, 1.0) * screen_height as f32).round() as i32;
        let in_contact = matches!(event.event_type, DOWN | MOVE);
        let touch = POINTER_TOUCH_INFO {
            pointerInfo: common(PT_TOUCH, id, event.event_type, event.x, event.y)?,
            touchMask: (if in_contact {
                TOUCH_MASK_PRESSURE | TOUCH_MASK_CONTACTAREA
            } else {
                0
            }) | (if event.rotation == ROTATION_UNKNOWN {
                0
            } else {
                TOUCH_MASK_ORIENTATION
            }),
            rcContact: RECT {
                left: point.x - contact_width / 2,
                top: point.y - contact_height / 2,
                right: point.x + contact_width / 2,
                bottom: point.y + contact_height / 2,
            },
            orientation: if event.rotation == ROTATION_UNKNOWN {
                0
            } else {
                u32::from(event.rotation % 360)
            },
            pressure: if in_contact {
                (event.pressure_or_distance.clamp(0.0, 1.0) * 1024.0).round() as u32
            } else {
                0
            },
            ..Default::default()
        };
        let info = POINTER_TYPE_INFO {
            r#type: PT_TOUCH,
            Anonymous: POINTER_TYPE_INFO_0 { touchInfo: touch },
        };
        inject(self.ensure_touch()?, &info)?;
        if matches!(event.event_type, UP | CANCEL | HOVER_LEAVE) {
            self.touches.remove(&key);
        }
        Ok(())
    }

    pub(super) fn pen(&mut self, session: u32, event: &NativePenInput) -> Result<(), String> {
        if event.event_type == CANCEL_ALL {
            return self.reset_pen(session);
        }
        let in_contact = matches!(event.event_type, DOWN | MOVE);
        let mut mask = if in_contact { PEN_MASK_PRESSURE } else { 0 };
        if event.rotation != ROTATION_UNKNOWN {
            mask |= PEN_MASK_ROTATION;
        }
        let (tilt_x, tilt_y) = if event.tilt != TILT_UNKNOWN && event.rotation != ROTATION_UNKNOWN {
            mask |= PEN_MASK_TILT_X | PEN_MASK_TILT_Y;
            let rotation = f32::from(event.rotation).to_radians();
            let tilt = f32::from(event.tilt).to_radians();
            let radial = tilt.sin();
            let vertical = tilt.cos();
            (
                ((-rotation).sin() * radial)
                    .atan2(vertical)
                    .to_degrees()
                    .round() as i32,
                ((-rotation).cos() * radial)
                    .atan2(vertical)
                    .to_degrees()
                    .round() as i32,
            )
        } else {
            (0, 0)
        };
        let pen = POINTER_PEN_INFO {
            pointerInfo: common(PT_PEN, 1, event.event_type, event.x, event.y)?,
            penFlags: (if event.buttons == 0 {
                0
            } else {
                PEN_FLAG_BARREL
            }) | (if event.tool_type == TOOL_ERASER {
                PEN_FLAG_ERASER
            } else {
                0
            }),
            penMask: mask,
            pressure: if in_contact {
                (event.pressure_or_distance.clamp(0.0, 1.0) * 1024.0).round() as u32
            } else {
                0
            },
            rotation: if event.rotation == ROTATION_UNKNOWN {
                0
            } else {
                u32::from(event.rotation % 360)
            },
            tiltX: tilt_x,
            tiltY: tilt_y,
        };
        let info = POINTER_TYPE_INFO {
            r#type: PT_PEN,
            Anonymous: POINTER_TYPE_INFO_0 { penInfo: pen },
        };
        inject(self.ensure_pen()?, &info)?;
        self.pen_session = if matches!(event.event_type, UP | CANCEL | HOVER_LEAVE) {
            None
        } else {
            Some(session)
        };
        Ok(())
    }

    pub(super) fn reset_session(&mut self, session: u32) -> Result<(), String> {
        self.reset_touches(session)?;
        self.reset_pen(session)
    }

    fn reset_touches(&mut self, session: u32) -> Result<(), String> {
        let active: Vec<_> = self
            .touches
            .iter()
            .filter_map(|(&(owner, protocol_id), &id)| {
                (owner == session).then_some((protocol_id, id))
            })
            .collect();
        for (protocol_id, id) in active {
            if self.touch_device != 0 {
                let touch = POINTER_TOUCH_INFO {
                    pointerInfo: common(PT_TOUCH, id, CANCEL, 0.0, 0.0)?,
                    ..Default::default()
                };
                let info = POINTER_TYPE_INFO {
                    r#type: PT_TOUCH,
                    Anonymous: POINTER_TYPE_INFO_0 { touchInfo: touch },
                };
                inject(self.touch_device, &info)?;
            }
            self.touches.remove(&(session, protocol_id));
        }
        Ok(())
    }

    fn reset_pen(&mut self, session: u32) -> Result<(), String> {
        if self.pen_session != Some(session) {
            return Ok(());
        }
        if self.pen_device != 0 {
            let pen = POINTER_PEN_INFO {
                pointerInfo: common(PT_PEN, 1, CANCEL, 0.0, 0.0)?,
                ..Default::default()
            };
            let info = POINTER_TYPE_INFO {
                r#type: PT_PEN,
                Anonymous: POINTER_TYPE_INFO_0 { penInfo: pen },
            };
            inject(self.pen_device, &info)?;
        }
        self.pen_session = None;
        Ok(())
    }
}

impl Drop for NativePointerInput {
    fn drop(&mut self) {
        unsafe {
            if self.touch_device != 0 {
                DestroySyntheticPointerDevice(self.touch_device as *mut _);
            }
            if self.pen_device != 0 {
                DestroySyntheticPointerDevice(self.pen_device as *mut _);
            }
        }
    }
}
