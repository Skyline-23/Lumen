use std::fmt;

use lumen_engine::{
    client_input_envelope, client_motion_envelope, ClientInputEnvelope, NativeContactPhase,
    NativeGamepadButton, NativePointerMotionMode,
};

const MAXIMUM_GAMEPADS: u32 = 16;
const MAXIMUM_HID_KEYBOARD_USAGE: u32 = 0xe7;
const MAXIMUM_MODIFIER_MASK: u32 = 0xff;
const MAXIMUM_ANALOG_VALUE: u32 = u16::MAX as u32;

#[derive(Clone, Debug, PartialEq)]
pub enum PlatformNativeInputEvent {
    Keyboard {
        hid_usage: u16,
        pressed: bool,
        modifiers: u8,
        repeat: bool,
    },
    Text {
        text: String,
        composition_id: u64,
        commit: bool,
        selection_start_utf8: usize,
        selection_length_utf8: usize,
    },
    PointerButton {
        pointer_id: u32,
        button: u8,
        pressed: bool,
    },
    GamepadConnection {
        gamepad_id: u8,
        connected: bool,
        capabilities: u32,
    },
    GamepadButton {
        gamepad_id: u8,
        button: NativeGamepadButton,
        pressed: bool,
        analog_value: u16,
    },
    TouchContact {
        contact_id: u32,
        phase: NativeContactPhase,
        normalized_x: f32,
        normalized_y: f32,
        pressure: f32,
    },
    PenContact {
        pointer_id: u32,
        phase: NativeContactPhase,
        buttons: u32,
        normalized_x: f32,
        normalized_y: f32,
        pressure: f32,
    },
    RumbleAcknowledged {
        command_sequence: u64,
        gamepad_id: u8,
        accepted: bool,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum PlatformNativeMotionEvent {
    Pointer {
        pointer_id: u32,
        mode: NativePointerMotionMode,
        delta_x: i32,
        delta_y: i32,
        normalized_x: f32,
        normalized_y: f32,
    },
    Scroll {
        pointer_id: u32,
        delta_x_1024_points: i32,
        delta_y_1024_points: i32,
    },
    Touch {
        contact_id: u32,
        normalized_x: f32,
        normalized_y: f32,
        pressure: f32,
    },
    Pen {
        pointer_id: u32,
        normalized_x: f32,
        normalized_y: f32,
        pressure: f32,
        tilt_x_degrees: f32,
        tilt_y_degrees: f32,
        rotation_degrees: f32,
    },
    Gamepad {
        gamepad_id: u8,
        left_stick_x: i16,
        left_stick_y: i16,
        right_stick_x: i16,
        right_stick_y: i16,
        left_trigger: u16,
        right_trigger: u16,
        gyro_x: f32,
        gyro_y: f32,
        gyro_z: f32,
        acceleration_x: f32,
        acceleration_y: f32,
        acceleration_z: f32,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NativeInputError {
    SessionEpochMismatch { expected: u32, received: u32 },
    EventSequenceMismatch { expected: u64, received: u64 },
    SequenceExhausted,
    MissingPayload,
    InvalidKeyboardUsage(u32),
    InvalidModifierMask(u32),
    InvalidTextSelection,
    InvalidPointerButton(u32),
    InvalidGamepad(u32),
    InvalidGamepadButton(i32),
    InvalidAnalogValue(u32),
    InvalidContactPhase(i32),
    InvalidContactGeometry,
    InvalidPenButtons(u32),
    InvalidRumbleAcknowledgement,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NativeMotionError {
    MissingPayload,
    InvalidPointerMode(i32),
    InvalidPointerGeometry,
    InvalidContactGeometry,
    InvalidGamepad(u32),
    InvalidGamepadAxis(i32),
    InvalidAnalogValue(u32),
    InvalidMotionVector,
}

impl fmt::Display for NativeInputError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SessionEpochMismatch { expected, received } => write!(
                formatter,
                "native input session epoch mismatch: expected {expected}, received {received}"
            ),
            Self::EventSequenceMismatch { expected, received } => write!(
                formatter,
                "native input sequence mismatch: expected {expected}, received {received}"
            ),
            Self::SequenceExhausted => formatter.write_str("native input sequence exhausted"),
            Self::MissingPayload => formatter.write_str("native input payload is missing"),
            Self::InvalidKeyboardUsage(usage) => {
                write!(formatter, "native keyboard HID usage {usage:#x} is invalid")
            }
            Self::InvalidModifierMask(mask) => {
                write!(
                    formatter,
                    "native keyboard modifier mask {mask:#x} is invalid"
                )
            }
            Self::InvalidTextSelection => {
                formatter.write_str("native text selection is not on UTF-8 boundaries")
            }
            Self::InvalidPointerButton(button) => {
                write!(formatter, "native pointer button {button} is invalid")
            }
            Self::InvalidGamepad(gamepad) => {
                write!(formatter, "native gamepad {gamepad} is invalid")
            }
            Self::InvalidGamepadButton(button) => {
                write!(formatter, "native gamepad button {button} is invalid")
            }
            Self::InvalidAnalogValue(value) => {
                write!(formatter, "native analog value {value} is invalid")
            }
            Self::InvalidContactPhase(phase) => {
                write!(formatter, "native contact phase {phase} is invalid")
            }
            Self::InvalidContactGeometry => {
                formatter.write_str("native contact geometry is invalid")
            }
            Self::InvalidPenButtons(buttons) => {
                write!(formatter, "native pen button mask {buttons:#x} is invalid")
            }
            Self::InvalidRumbleAcknowledgement => {
                formatter.write_str("native rumble acknowledgement identity is invalid")
            }
        }
    }
}

impl fmt::Display for NativeMotionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingPayload => formatter.write_str("native motion payload is missing"),
            Self::InvalidPointerMode(mode) => {
                write!(formatter, "native pointer motion mode {mode} is invalid")
            }
            Self::InvalidPointerGeometry => {
                formatter.write_str("native pointer geometry is invalid")
            }
            Self::InvalidContactGeometry => {
                formatter.write_str("native motion contact geometry is invalid")
            }
            Self::InvalidGamepad(gamepad) => {
                write!(formatter, "native motion gamepad {gamepad} is invalid")
            }
            Self::InvalidGamepadAxis(value) => {
                write!(formatter, "native gamepad motion axis {value} is invalid")
            }
            Self::InvalidAnalogValue(value) => {
                write!(formatter, "native motion analog value {value} is invalid")
            }
            Self::InvalidMotionVector => {
                formatter.write_str("native motion vector contains a non-finite value")
            }
        }
    }
}

#[derive(Debug)]
pub(crate) struct NativeInputSequence {
    session_epoch: u32,
    next_event_sequence: u64,
}

impl NativeInputSequence {
    pub(crate) fn new(session_epoch: u32) -> Self {
        Self {
            session_epoch,
            next_event_sequence: 1,
        }
    }

    pub(crate) fn accept(
        &mut self,
        envelope: ClientInputEnvelope,
    ) -> Result<PlatformNativeInputEvent, NativeInputError> {
        if envelope.session_epoch != self.session_epoch {
            return Err(NativeInputError::SessionEpochMismatch {
                expected: self.session_epoch,
                received: envelope.session_epoch,
            });
        }
        if envelope.event_sequence != self.next_event_sequence {
            return Err(NativeInputError::EventSequenceMismatch {
                expected: self.next_event_sequence,
                received: envelope.event_sequence,
            });
        }
        let event = PlatformNativeInputEvent::try_from(
            envelope.payload.ok_or(NativeInputError::MissingPayload)?,
        )?;
        self.next_event_sequence = self
            .next_event_sequence
            .checked_add(1)
            .ok_or(NativeInputError::SequenceExhausted)?;
        Ok(event)
    }

    pub(crate) fn highest_contiguous_event_sequence(&self) -> u64 {
        self.next_event_sequence - 1
    }
}

impl TryFrom<client_input_envelope::Payload> for PlatformNativeInputEvent {
    type Error = NativeInputError;

    fn try_from(payload: client_input_envelope::Payload) -> Result<Self, Self::Error> {
        match payload {
            client_input_envelope::Payload::Keyboard(input) => {
                if !(1..=MAXIMUM_HID_KEYBOARD_USAGE).contains(&input.hid_usage) {
                    return Err(NativeInputError::InvalidKeyboardUsage(input.hid_usage));
                }
                let hid_usage = u16::try_from(input.hid_usage)
                    .map_err(|_| NativeInputError::InvalidKeyboardUsage(input.hid_usage))?;
                let modifiers = u8::try_from(input.modifiers)
                    .map_err(|_| NativeInputError::InvalidModifierMask(input.modifiers))?;
                if input.modifiers > MAXIMUM_MODIFIER_MASK {
                    return Err(NativeInputError::InvalidModifierMask(input.modifiers));
                }
                Ok(Self::Keyboard {
                    hid_usage,
                    pressed: input.pressed,
                    modifiers,
                    repeat: input.repeat,
                })
            }
            client_input_envelope::Payload::Text(input) => {
                let selection_start = usize::try_from(input.selection_start_utf8)
                    .map_err(|_| NativeInputError::InvalidTextSelection)?;
                let selection_length = usize::try_from(input.selection_length_utf8)
                    .map_err(|_| NativeInputError::InvalidTextSelection)?;
                let selection_end = selection_start
                    .checked_add(selection_length)
                    .ok_or(NativeInputError::InvalidTextSelection)?;
                if selection_end > input.text_utf8.len()
                    || !input.text_utf8.is_char_boundary(selection_start)
                    || !input.text_utf8.is_char_boundary(selection_end)
                {
                    return Err(NativeInputError::InvalidTextSelection);
                }
                Ok(Self::Text {
                    text: input.text_utf8,
                    composition_id: input.composition_id,
                    commit: input.commit,
                    selection_start_utf8: selection_start,
                    selection_length_utf8: selection_length,
                })
            }
            client_input_envelope::Payload::PointerButton(input) => {
                let button = u8::try_from(input.button)
                    .map_err(|_| NativeInputError::InvalidPointerButton(input.button))?;
                if !(1..=5).contains(&button) {
                    return Err(NativeInputError::InvalidPointerButton(input.button));
                }
                Ok(Self::PointerButton {
                    pointer_id: input.pointer_id,
                    button,
                    pressed: input.pressed,
                })
            }
            client_input_envelope::Payload::GamepadConnection(input) => {
                Ok(Self::GamepadConnection {
                    gamepad_id: gamepad_id(input.gamepad_id)?,
                    connected: input.connected,
                    capabilities: input.capabilities,
                })
            }
            client_input_envelope::Payload::GamepadButton(input) => {
                if input.analog_value > MAXIMUM_ANALOG_VALUE {
                    return Err(NativeInputError::InvalidAnalogValue(input.analog_value));
                }
                let button = NativeGamepadButton::try_from(input.button)
                    .ok()
                    .filter(|button| *button != NativeGamepadButton::Unspecified)
                    .ok_or(NativeInputError::InvalidGamepadButton(input.button))?;
                Ok(Self::GamepadButton {
                    gamepad_id: gamepad_id(input.gamepad_id)?,
                    button,
                    pressed: input.pressed,
                    analog_value: input.analog_value as u16,
                })
            }
            client_input_envelope::Payload::TouchContact(input) => {
                let phase = contact_phase(input.phase)?;
                validate_contact(input.normalized_x, input.normalized_y, input.pressure)?;
                Ok(Self::TouchContact {
                    contact_id: input.contact_id,
                    phase,
                    normalized_x: input.normalized_x,
                    normalized_y: input.normalized_y,
                    pressure: input.pressure,
                })
            }
            client_input_envelope::Payload::PenContact(input) => {
                let phase = contact_phase(input.phase)?;
                validate_contact(input.normalized_x, input.normalized_y, input.pressure)?;
                if input.buttons > u8::MAX as u32 {
                    return Err(NativeInputError::InvalidPenButtons(input.buttons));
                }
                Ok(Self::PenContact {
                    pointer_id: input.pointer_id,
                    phase,
                    buttons: input.buttons,
                    normalized_x: input.normalized_x,
                    normalized_y: input.normalized_y,
                    pressure: input.pressure,
                })
            }
            client_input_envelope::Payload::RumbleAck(input) => {
                if input.command_sequence == 0 {
                    return Err(NativeInputError::InvalidRumbleAcknowledgement);
                }
                Ok(Self::RumbleAcknowledged {
                    command_sequence: input.command_sequence,
                    gamepad_id: gamepad_id(input.gamepad_id)?,
                    accepted: input.accepted,
                })
            }
        }
    }
}

impl TryFrom<client_motion_envelope::Payload> for PlatformNativeMotionEvent {
    type Error = NativeMotionError;

    fn try_from(payload: client_motion_envelope::Payload) -> Result<Self, Self::Error> {
        match payload {
            client_motion_envelope::Payload::PointerMotion(input) => {
                let mode = NativePointerMotionMode::try_from(input.mode)
                    .ok()
                    .filter(|mode| *mode != NativePointerMotionMode::Unspecified)
                    .ok_or(NativeMotionError::InvalidPointerMode(input.mode))?;
                if mode == NativePointerMotionMode::Absolute
                    && !normalized_pair(input.normalized_x, input.normalized_y)
                {
                    return Err(NativeMotionError::InvalidPointerGeometry);
                }
                Ok(Self::Pointer {
                    pointer_id: input.pointer_id,
                    mode,
                    delta_x: input.delta_x,
                    delta_y: input.delta_y,
                    normalized_x: input.normalized_x,
                    normalized_y: input.normalized_y,
                })
            }
            client_motion_envelope::Payload::Scroll(input) => Ok(Self::Scroll {
                pointer_id: input.pointer_id,
                delta_x_1024_points: input.delta_x_1024_points,
                delta_y_1024_points: input.delta_y_1024_points,
            }),
            client_motion_envelope::Payload::TouchMotion(input) => {
                validate_contact(input.normalized_x, input.normalized_y, input.pressure)
                    .map_err(|_| NativeMotionError::InvalidContactGeometry)?;
                Ok(Self::Touch {
                    contact_id: input.contact_id,
                    normalized_x: input.normalized_x,
                    normalized_y: input.normalized_y,
                    pressure: input.pressure,
                })
            }
            client_motion_envelope::Payload::PenMotion(input) => {
                validate_contact(input.normalized_x, input.normalized_y, input.pressure)
                    .map_err(|_| NativeMotionError::InvalidContactGeometry)?;
                if ![
                    input.tilt_x_degrees,
                    input.tilt_y_degrees,
                    input.rotation_degrees,
                ]
                .into_iter()
                .all(f32::is_finite)
                {
                    return Err(NativeMotionError::InvalidMotionVector);
                }
                Ok(Self::Pen {
                    pointer_id: input.pointer_id,
                    normalized_x: input.normalized_x,
                    normalized_y: input.normalized_y,
                    pressure: input.pressure,
                    tilt_x_degrees: input.tilt_x_degrees,
                    tilt_y_degrees: input.tilt_y_degrees,
                    rotation_degrees: input.rotation_degrees,
                })
            }
            client_motion_envelope::Payload::GamepadMotion(input) => {
                let axes = [
                    input.left_stick_x,
                    input.left_stick_y,
                    input.right_stick_x,
                    input.right_stick_y,
                ];
                let invalid_axis = axes
                    .into_iter()
                    .find(|value| i16::try_from(*value).is_err());
                if let Some(value) = invalid_axis {
                    return Err(NativeMotionError::InvalidGamepadAxis(value));
                }
                if input.left_trigger > MAXIMUM_ANALOG_VALUE {
                    return Err(NativeMotionError::InvalidAnalogValue(input.left_trigger));
                }
                if input.right_trigger > MAXIMUM_ANALOG_VALUE {
                    return Err(NativeMotionError::InvalidAnalogValue(input.right_trigger));
                }
                let vectors = [
                    input.gyro_x,
                    input.gyro_y,
                    input.gyro_z,
                    input.acceleration_x,
                    input.acceleration_y,
                    input.acceleration_z,
                ];
                if !vectors.into_iter().all(f32::is_finite) {
                    return Err(NativeMotionError::InvalidMotionVector);
                }
                Ok(Self::Gamepad {
                    gamepad_id: gamepad_id(input.gamepad_id)
                        .map_err(|_| NativeMotionError::InvalidGamepad(input.gamepad_id))?,
                    left_stick_x: input.left_stick_x as i16,
                    left_stick_y: input.left_stick_y as i16,
                    right_stick_x: input.right_stick_x as i16,
                    right_stick_y: input.right_stick_y as i16,
                    left_trigger: input.left_trigger as u16,
                    right_trigger: input.right_trigger as u16,
                    gyro_x: input.gyro_x,
                    gyro_y: input.gyro_y,
                    gyro_z: input.gyro_z,
                    acceleration_x: input.acceleration_x,
                    acceleration_y: input.acceleration_y,
                    acceleration_z: input.acceleration_z,
                })
            }
        }
    }
}

fn gamepad_id(value: u32) -> Result<u8, NativeInputError> {
    if value >= MAXIMUM_GAMEPADS {
        return Err(NativeInputError::InvalidGamepad(value));
    }
    u8::try_from(value).map_err(|_| NativeInputError::InvalidGamepad(value))
}

fn contact_phase(value: i32) -> Result<NativeContactPhase, NativeInputError> {
    NativeContactPhase::try_from(value)
        .ok()
        .filter(|phase| *phase != NativeContactPhase::Unspecified)
        .ok_or(NativeInputError::InvalidContactPhase(value))
}

fn validate_contact(x: f32, y: f32, pressure: f32) -> Result<(), NativeInputError> {
    if [x, y, pressure]
        .into_iter()
        .all(|value| value.is_finite() && (0.0..=1.0).contains(&value))
    {
        Ok(())
    } else {
        Err(NativeInputError::InvalidContactGeometry)
    }
}

fn normalized_pair(x: f32, y: f32) -> bool {
    [x, y]
        .into_iter()
        .all(|value| value.is_finite() && (0.0..=1.0).contains(&value))
}

#[cfg(test)]
mod tests {
    use lumen_engine::{client_input_envelope, NativeTextInput};

    use super::*;

    #[test]
    fn sequence_accepts_multilingual_utf8_boundaries_and_rejects_gaps() {
        let mut sequence = NativeInputSequence::new(7);
        let event = sequence
            .accept(ClientInputEnvelope {
                session_epoch: 7,
                event_sequence: 1,
                payload: Some(client_input_envelope::Payload::Text(NativeTextInput {
                    text_utf8: "한글abc".to_owned(),
                    composition_id: 9,
                    commit: false,
                    selection_start_utf8: 3,
                    selection_length_utf8: 3,
                })),
            })
            .unwrap();
        assert!(matches!(
            event,
            PlatformNativeInputEvent::Text {
                selection_start_utf8: 3,
                selection_length_utf8: 3,
                ..
            }
        ));
        assert_eq!(sequence.highest_contiguous_event_sequence(), 1);

        assert_eq!(
            sequence.accept(ClientInputEnvelope {
                session_epoch: 7,
                event_sequence: 3,
                payload: Some(client_input_envelope::Payload::Text(NativeTextInput {
                    text_utf8: "a".to_owned(),
                    composition_id: 9,
                    commit: true,
                    selection_start_utf8: 1,
                    selection_length_utf8: 0,
                })),
            }),
            Err(NativeInputError::EventSequenceMismatch {
                expected: 2,
                received: 3,
            })
        );
    }

    #[test]
    fn text_selection_rejects_mid_scalar_offsets() {
        let mut sequence = NativeInputSequence::new(1);
        assert_eq!(
            sequence.accept(ClientInputEnvelope {
                session_epoch: 1,
                event_sequence: 1,
                payload: Some(client_input_envelope::Payload::Text(NativeTextInput {
                    text_utf8: "한".to_owned(),
                    composition_id: 1,
                    commit: false,
                    selection_start_utf8: 1,
                    selection_length_utf8: 0,
                })),
            }),
            Err(NativeInputError::InvalidTextSelection)
        );
    }
}
