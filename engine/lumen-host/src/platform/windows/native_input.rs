use std::sync::Mutex;

use crate::{
    LumenHostPlatformControlFeedback, PlatformApplicationPlan, PlatformControlEvent,
    PlatformControlFeedback, PlatformEncodedAudioPacket, PlatformEncodedVideoFrame,
    PlatformNativeInputEvent, PlatformSessionControl, PlatformSessionPlan,
};

use super::input_policy::WindowsInputPolicy;
use super::input_state::{WindowsInputAction, WindowsInputState};
use super::native_desktop_input;
use super::native_display::NativeWindowsDisplay;
use super::native_media::NativeWindowsMedia;
use super::native_pointer_input::{NativePenInput, NativePointerInput, NativeTouchInput};
use super::native_process::NativeWindowsApplication;
use super::native_vigem::{NativeGamepadState, NativeVigem};

const MAXIMUM_STALE_FEEDBACK: usize = 16;

struct NativeWindowsInput {
    devices: Mutex<NativeInputDevices>,
}

#[derive(Default)]
struct NativeInputDevices {
    pointers: NativePointerInput,
    gamepads: NativeVigem,
}

impl NativeWindowsInput {
    fn new() -> Result<Self, String> {
        Ok(Self {
            devices: Mutex::new(NativeInputDevices::default()),
        })
    }

    fn execute(
        &self,
        control_connect_data: u32,
        action: &WindowsInputAction,
    ) -> Result<(), String> {
        let mut devices = self
            .devices
            .lock()
            .map_err(|_| "Windows input device lock is poisoned".to_owned())?;
        match action {
            WindowsInputAction::MouseButton { button, pressed } => {
                native_desktop_input::button(*button, *pressed)
            }
            WindowsInputAction::HidKeyboard { hid_usage, pressed } => {
                native_desktop_input::hid_keyboard(*hid_usage, *pressed)
            }
            WindowsInputAction::Text { text } => native_desktop_input::text(text.as_bytes()),
            WindowsInputAction::ControllerAttach {
                global_index,
                controller_type,
                capabilities,
                ..
            } => devices
                .gamepads
                .attach(*global_index, *controller_type, *capabilities),
            WindowsInputAction::ControllerDetach { global_index } => {
                devices.gamepads.detach(*global_index)
            }
            WindowsInputAction::ControllerUpdate {
                global_index,
                button_flags,
                left_trigger,
                right_trigger,
                left_stick_x,
                left_stick_y,
                right_stick_x,
                right_stick_y,
            } => devices.gamepads.update(
                *global_index,
                NativeGamepadState {
                    buttons: *button_flags,
                    left_trigger: *left_trigger,
                    right_trigger: *right_trigger,
                    left_stick_x: *left_stick_x,
                    left_stick_y: *left_stick_y,
                    right_stick_x: *right_stick_x,
                    right_stick_y: *right_stick_y,
                },
            ),
            WindowsInputAction::Touch {
                event_type,
                rotation,
                pointer_id,
                x,
                y,
                pressure_or_distance,
                contact_area_major,
                contact_area_minor,
            } => devices.pointers.touch(
                control_connect_data,
                &NativeTouchInput {
                    event_type: *event_type,
                    rotation: *rotation,
                    pointer_id: *pointer_id,
                    x: *x,
                    y: *y,
                    pressure_or_distance: *pressure_or_distance,
                    contact_area_major: *contact_area_major,
                    contact_area_minor: *contact_area_minor,
                },
            ),
            WindowsInputAction::Pen {
                event_type,
                tool_type,
                buttons,
                x,
                y,
                pressure_or_distance,
                rotation,
                tilt,
            } => devices.pointers.pen(
                control_connect_data,
                &NativePenInput {
                    event_type: *event_type,
                    tool_type: *tool_type,
                    buttons: *buttons,
                    x: *x,
                    y: *y,
                    pressure_or_distance: *pressure_or_distance,
                    rotation: *rotation,
                    tilt: *tilt,
                },
            ),
        }
    }

    fn reset_session(&self, control_connect_data: u32) -> Result<(), String> {
        self.devices
            .lock()
            .map_err(|_| "Windows input device lock is poisoned".to_owned())?
            .pointers
            .reset_session(control_connect_data)
    }

    fn poll_feedback(&self) -> Result<Option<LumenHostPlatformControlFeedback>, String> {
        self.devices
            .lock()
            .map_err(|_| "Windows input device lock is poisoned".to_owned())?
            .gamepads
            .poll_feedback()
    }
}

pub(crate) struct WindowsPlatformSessionControl {
    application: NativeWindowsApplication,
    display: NativeWindowsDisplay,
    media: NativeWindowsMedia,
    input: NativeWindowsInput,
    input_policy: WindowsInputPolicy,
    state: Mutex<WindowsInputState>,
}

impl WindowsPlatformSessionControl {
    pub(crate) fn new(arguments: &crate::HostArguments) -> Result<Self, String> {
        let input_policy = WindowsInputPolicy::from_arguments(arguments)?;
        let input = NativeWindowsInput::new()?;
        let media = NativeWindowsMedia::new(arguments)?;
        Ok(Self {
            application: NativeWindowsApplication::default(),
            display: NativeWindowsDisplay::new(arguments)?,
            media,
            input,
            input_policy,
            state: Mutex::new(WindowsInputState::default()),
        })
    }

    fn execute_actions(
        &self,
        control_connect_data: u32,
        actions: &[WindowsInputAction],
    ) -> Result<(), String> {
        for action in actions {
            self.input.execute(control_connect_data, action)?;
        }
        Ok(())
    }
}

impl PlatformSessionControl for WindowsPlatformSessionControl {
    fn start_application(&self, plan: PlatformApplicationPlan) -> Result<(), String> {
        self.display.start(&plan)?;
        if let Err(error) = self.application.start(plan) {
            let rollback = self.display.stop().err();
            return Err(match rollback {
                Some(rollback) => {
                    format!("{error}; Windows virtual display rollback also failed: {rollback}")
                }
                None => error,
            });
        }
        Ok(())
    }

    fn stop_application(&self) -> Result<(), String> {
        let application = self.application.stop().err();
        let display = self.display.stop().err();
        match (application, display) {
            (None, None) => Ok(()),
            (Some(error), None) | (None, Some(error)) => Err(error),
            (Some(application), Some(display)) => Err(format!(
                "{application}; virtual display cleanup failed: {display}"
            )),
        }
    }

    fn start_session(&self, plan: PlatformSessionPlan) -> Result<(), String> {
        self.media
            .start(plan, self.display.current_output_name()?)?;
        if let Err(error) = self.display.capture_started() {
            let media = self.media.stop().err();
            let display = self.display.stop().err();
            return Err(cleanup_error(error, media, display));
        }
        Ok(())
    }

    fn stop_session(&self) -> Result<(), String> {
        let media = self.media.stop().err();
        let display = self.display.stop().err();
        match (media, display) {
            (None, None) => Ok(()),
            (Some(error), None) | (None, Some(error)) => Err(error),
            (Some(media), Some(display)) => Err(format!(
                "{media}; Windows display cleanup also failed: {display}"
            )),
        }
    }

    fn poll_encoded_video(&self) -> Result<Option<PlatformEncodedVideoFrame>, String> {
        match self.media.poll_video() {
            Ok(Some(frame)) => match self.display.first_frame_ready() {
                Ok(()) => Ok(Some(frame)),
                Err(error) => {
                    let media = self.media.stop().err();
                    let display = self.display.stop().err();
                    Err(cleanup_error(error, media, display))
                }
            },
            Ok(None) => match self.display.check_first_frame_timeout() {
                Ok(()) => Ok(None),
                Err(error) => {
                    let media = self.media.stop().err();
                    let display = self.display.stop().err();
                    Err(cleanup_error(error, media, display))
                }
            },
            Err(error) => {
                let media = self.media.stop().err();
                let display = self.display.stop().err();
                Err(cleanup_error(error, media, display))
            }
        }
    }

    fn poll_encoded_audio(&self) -> Result<Option<PlatformEncodedAudioPacket>, String> {
        self.media.poll_audio()
    }

    fn handle_control_event(
        &self,
        control_connect_data: u32,
        event: PlatformControlEvent,
    ) -> Result<(), String> {
        match event {
            PlatformControlEvent::ResetInput => {
                let mut state = self
                    .state
                    .lock()
                    .map_err(|_| "Windows input state lock is poisoned".to_owned())?;
                let mut next = state.clone();
                let actions = next.reset(control_connect_data);
                self.execute_actions(control_connect_data, &actions)?;
                self.input.reset_session(control_connect_data)?;
                *state = next;
                Ok(())
            }
            PlatformControlEvent::RequestIdrFrame => self.media.request_key_frame(),
            PlatformControlEvent::InvalidateReferenceFrames {
                first_frame,
                last_frame,
            } => self
                .media
                .invalidate_reference_frames(first_frame, last_frame),
            PlatformControlEvent::ExecuteServerCommand { index } => {
                self.application.execute_server_command(index)
            }
        }
    }

    fn handle_native_input(
        &self,
        session_epoch: u32,
        event: PlatformNativeInputEvent,
    ) -> Result<(), String> {
        if !self.input_policy.allows_native(&event) {
            return Ok(());
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Windows input state lock is poisoned".to_owned())?;
        let mut next = state.clone();
        let actions = next
            .apply_native(session_epoch, event)
            .map_err(|error| error.to_string())?;
        self.execute_actions(session_epoch, &actions)?;
        *state = next;
        Ok(())
    }

    fn reset_native_input(&self, session_epoch: u32) -> Result<(), String> {
        self.handle_control_event(session_epoch, PlatformControlEvent::ResetInput)
    }

    fn poll_control_feedback(&self) -> Result<Option<PlatformControlFeedback>, String> {
        for _ in 0..MAXIMUM_STALE_FEEDBACK {
            let Some(mut feedback) = self.input.poll_feedback()? else {
                return Ok(None);
            };
            let global_index = usize::from(feedback.controller_id);
            let route = self
                .state
                .lock()
                .map_err(|_| "Windows input state lock is poisoned".to_owned())?
                .feedback_route(global_index);
            let Some((control_connect_data, controller_number)) = route else {
                continue;
            };
            feedback.control_connect_data = control_connect_data;
            feedback.controller_id = u16::from(controller_number);
            let feedback = PlatformControlFeedback::from(feedback);
            if self.input_policy.allows_feedback(&feedback) {
                return Ok(Some(feedback));
            }
            return Ok(None);
        }
        Err("Windows native input produced too many stale feedback messages".to_owned())
    }
}

fn cleanup_error(primary: String, media: Option<String>, display: Option<String>) -> String {
    [media, display]
        .into_iter()
        .flatten()
        .fold(primary, |message, cleanup| {
            format!("{message}; Windows stream cleanup also failed: {cleanup}")
        })
}
