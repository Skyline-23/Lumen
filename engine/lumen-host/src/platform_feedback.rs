pub const ADAPTIVE_TRIGGER_BYTES: usize = 10;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlatformControlFeedback {
    Rumble {
        control_connect_data: u32,
        controller_id: u16,
        low_frequency: u16,
        high_frequency: u16,
    },
    RumbleTriggers {
        control_connect_data: u32,
        controller_id: u16,
        left: u16,
        right: u16,
    },
    MotionEvent {
        control_connect_data: u32,
        controller_id: u16,
        report_rate: u16,
        motion_type: u8,
    },
    RgbLed {
        control_connect_data: u32,
        controller_id: u16,
        red: u8,
        green: u8,
        blue: u8,
    },
    AdaptiveTriggers {
        control_connect_data: u32,
        controller_id: u16,
        event_flags: u8,
        type_left: u8,
        type_right: u8,
        left: [u8; ADAPTIVE_TRIGGER_BYTES],
        right: [u8; ADAPTIVE_TRIGGER_BYTES],
    },
}

impl PlatformControlFeedback {
    pub fn control_connect_data(self) -> u32 {
        match self {
            Self::Rumble {
                control_connect_data,
                ..
            }
            | Self::RumbleTriggers {
                control_connect_data,
                ..
            }
            | Self::MotionEvent {
                control_connect_data,
                ..
            }
            | Self::RgbLed {
                control_connect_data,
                ..
            }
            | Self::AdaptiveTriggers {
                control_connect_data,
                ..
            } => control_connect_data,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LumenHostPlatformControlFeedbackKind {
    Rumble = 0,
    RumbleTriggers = 1,
    MotionEvent = 2,
    RgbLed = 3,
    AdaptiveTriggers = 4,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LumenHostPlatformControlFeedback {
    pub kind: LumenHostPlatformControlFeedbackKind,
    pub control_connect_data: u32,
    pub controller_id: u16,
    pub value_a: u16,
    pub value_b: u16,
    pub report_rate: u16,
    pub motion_type: u8,
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub event_flags: u8,
    pub type_left: u8,
    pub type_right: u8,
    pub left: [u8; ADAPTIVE_TRIGGER_BYTES],
    pub right: [u8; ADAPTIVE_TRIGGER_BYTES],
}

impl From<LumenHostPlatformControlFeedback> for PlatformControlFeedback {
    fn from(feedback: LumenHostPlatformControlFeedback) -> Self {
        match feedback.kind {
            LumenHostPlatformControlFeedbackKind::Rumble => Self::Rumble {
                control_connect_data: feedback.control_connect_data,
                controller_id: feedback.controller_id,
                low_frequency: feedback.value_a,
                high_frequency: feedback.value_b,
            },
            LumenHostPlatformControlFeedbackKind::RumbleTriggers => Self::RumbleTriggers {
                control_connect_data: feedback.control_connect_data,
                controller_id: feedback.controller_id,
                left: feedback.value_a,
                right: feedback.value_b,
            },
            LumenHostPlatformControlFeedbackKind::MotionEvent => Self::MotionEvent {
                control_connect_data: feedback.control_connect_data,
                controller_id: feedback.controller_id,
                report_rate: feedback.report_rate,
                motion_type: feedback.motion_type,
            },
            LumenHostPlatformControlFeedbackKind::RgbLed => Self::RgbLed {
                control_connect_data: feedback.control_connect_data,
                controller_id: feedback.controller_id,
                red: feedback.red,
                green: feedback.green,
                blue: feedback.blue,
            },
            LumenHostPlatformControlFeedbackKind::AdaptiveTriggers => Self::AdaptiveTriggers {
                control_connect_data: feedback.control_connect_data,
                controller_id: feedback.controller_id,
                event_flags: feedback.event_flags,
                type_left: feedback.type_left,
                type_right: feedback.type_right,
                left: feedback.left,
                right: feedback.right,
            },
        }
    }
}

#[cfg(test)]
mod tests;
