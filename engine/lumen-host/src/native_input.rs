use std::fmt;

use lumen_engine::{
    client_input_envelope, ClientInputEnvelope, NativeContactPhase, NativeGamepadButton,
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
