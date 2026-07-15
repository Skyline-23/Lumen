use crate::{HostArguments, PlatformControlFeedback, PlatformNativeInputEvent};

pub(super) struct WindowsInputPolicy {
    keyboard: bool,
    mouse: bool,
    controller: bool,
    native_pen_touch: bool,
    forward_rumble: bool,
}

impl WindowsInputPolicy {
    pub(super) fn from_arguments(arguments: &HostArguments) -> Result<Self, String> {
        Ok(Self {
            keyboard: boolean(arguments, "keyboard")?,
            mouse: boolean(arguments, "mouse")?,
            controller: boolean(arguments, "controller")?,
            native_pen_touch: boolean(arguments, "native_pen_touch")?,
            forward_rumble: boolean(arguments, "forward_rumble")?,
        })
    }

    pub(super) fn allows_feedback(&self, feedback: &PlatformControlFeedback) -> bool {
        self.forward_rumble
            || !matches!(
                feedback,
                PlatformControlFeedback::Rumble { .. }
                    | PlatformControlFeedback::RumbleTriggers { .. }
            )
    }

    pub(super) fn allows_native(&self, event: &PlatformNativeInputEvent) -> bool {
        match event {
            PlatformNativeInputEvent::Keyboard { .. } | PlatformNativeInputEvent::Text { .. } => {
                self.keyboard
            }
            PlatformNativeInputEvent::PointerButton { .. } => self.mouse,
            PlatformNativeInputEvent::TouchContact { .. }
            | PlatformNativeInputEvent::PenContact { .. } => self.native_pen_touch,
            PlatformNativeInputEvent::GamepadConnection { .. }
            | PlatformNativeInputEvent::GamepadButton { .. }
            | PlatformNativeInputEvent::RumbleAcknowledged { .. } => self.controller,
        }
    }
}

fn boolean(arguments: &HostArguments, key: &str) -> Result<bool, String> {
    match arguments.get(key) {
        Some("true") => Ok(true),
        Some("false") => Ok(false),
        _ => Err(format!("Windows input policy {key} is invalid")),
    }
}
