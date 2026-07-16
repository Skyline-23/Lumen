use prost::{Enumeration, Message, Oneof};

use super::native_session::NATIVE_CONTROL_MESSAGE_LIMIT;

pub const NATIVE_INPUT_MESSAGE_LIMIT: usize = NATIVE_CONTROL_MESSAGE_LIMIT;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeInputWireError {
    InvalidEnvelope,
    TruncatedLength,
    LengthOverflow,
    MessageTooLarge,
    TruncatedMessage,
    TrailingBytes,
    InvalidMessage,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativePointerMotionMode {
    Unspecified = 0,
    Relative = 1,
    Absolute = 2,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeContactPhase {
    Unspecified = 0,
    Began = 1,
    Ended = 2,
    Cancelled = 3,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeGamepadButton {
    Unspecified = 0,
    South = 1,
    East = 2,
    West = 3,
    North = 4,
    LeftBumper = 5,
    RightBumper = 6,
    LeftStick = 7,
    RightStick = 8,
    Back = 9,
    Start = 10,
    Guide = 11,
    DpadUp = 12,
    DpadDown = 13,
    DpadLeft = 14,
    DpadRight = 15,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeKeyboardInput {
    #[prost(uint32, tag = "1")]
    pub hid_usage: u32,
    #[prost(bool, tag = "2")]
    pub pressed: bool,
    #[prost(uint32, tag = "3")]
    pub modifiers: u32,
    #[prost(bool, tag = "4")]
    pub repeat: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeTextInput {
    #[prost(string, tag = "1")]
    pub text_utf8: String,
    #[prost(uint64, tag = "2")]
    pub composition_id: u64,
    #[prost(bool, tag = "3")]
    pub commit: bool,
    #[prost(uint32, tag = "4")]
    pub selection_start_utf8: u32,
    #[prost(uint32, tag = "5")]
    pub selection_length_utf8: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativePointerButtonInput {
    #[prost(uint32, tag = "1")]
    pub pointer_id: u32,
    #[prost(uint32, tag = "2")]
    pub button: u32,
    #[prost(bool, tag = "3")]
    pub pressed: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeGamepadConnectionInput {
    #[prost(uint32, tag = "1")]
    pub gamepad_id: u32,
    #[prost(bool, tag = "2")]
    pub connected: bool,
    #[prost(uint32, tag = "3")]
    pub capabilities: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeGamepadButtonInput {
    #[prost(uint32, tag = "1")]
    pub gamepad_id: u32,
    #[prost(enumeration = "NativeGamepadButton", tag = "2")]
    pub button: i32,
    #[prost(bool, tag = "3")]
    pub pressed: bool,
    #[prost(uint32, tag = "4")]
    pub analog_value: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeTouchContactInput {
    #[prost(uint32, tag = "1")]
    pub contact_id: u32,
    #[prost(enumeration = "NativeContactPhase", tag = "2")]
    pub phase: i32,
    #[prost(float, tag = "3")]
    pub normalized_x: f32,
    #[prost(float, tag = "4")]
    pub normalized_y: f32,
    #[prost(float, tag = "5")]
    pub pressure: f32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativePenContactInput {
    #[prost(uint32, tag = "1")]
    pub pointer_id: u32,
    #[prost(enumeration = "NativeContactPhase", tag = "2")]
    pub phase: i32,
    #[prost(uint32, tag = "3")]
    pub buttons: u32,
    #[prost(float, tag = "4")]
    pub normalized_x: f32,
    #[prost(float, tag = "5")]
    pub normalized_y: f32,
    #[prost(float, tag = "6")]
    pub pressure: f32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeRumbleAck {
    #[prost(uint64, tag = "1")]
    pub command_sequence: u64,
    #[prost(uint32, tag = "2")]
    pub gamepad_id: u32,
    #[prost(bool, tag = "3")]
    pub accepted: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct ClientInputEnvelope {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
    #[prost(uint64, tag = "2")]
    pub event_sequence: u64,
    #[prost(
        oneof = "client_input_envelope::Payload",
        tags = "10, 11, 12, 13, 14, 15, 16, 17"
    )]
    pub payload: Option<client_input_envelope::Payload>,
}

pub mod client_input_envelope {
    use super::*;

    #[derive(Clone, PartialEq, Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        Keyboard(NativeKeyboardInput),
        #[prost(message, tag = "11")]
        Text(NativeTextInput),
        #[prost(message, tag = "12")]
        PointerButton(NativePointerButtonInput),
        #[prost(message, tag = "13")]
        GamepadConnection(NativeGamepadConnectionInput),
        #[prost(message, tag = "14")]
        GamepadButton(NativeGamepadButtonInput),
        #[prost(message, tag = "15")]
        TouchContact(NativeTouchContactInput),
        #[prost(message, tag = "16")]
        PenContact(NativePenContactInput),
        #[prost(message, tag = "17")]
        RumbleAck(NativeRumbleAck),
    }
}

#[derive(Clone, PartialEq, Message)]
pub struct NativePointerMotionInput {
    #[prost(uint32, tag = "1")]
    pub pointer_id: u32,
    #[prost(enumeration = "NativePointerMotionMode", tag = "2")]
    pub mode: i32,
    #[prost(sint32, tag = "3")]
    pub delta_x: i32,
    #[prost(sint32, tag = "4")]
    pub delta_y: i32,
    #[prost(float, tag = "5")]
    pub normalized_x: f32,
    #[prost(float, tag = "6")]
    pub normalized_y: f32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeScrollInput {
    #[prost(uint32, tag = "1")]
    pub pointer_id: u32,
    #[prost(sint32, tag = "2")]
    pub delta_x_1024_points: i32,
    #[prost(sint32, tag = "3")]
    pub delta_y_1024_points: i32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeTouchMotionInput {
    #[prost(uint32, tag = "1")]
    pub contact_id: u32,
    #[prost(float, tag = "2")]
    pub normalized_x: f32,
    #[prost(float, tag = "3")]
    pub normalized_y: f32,
    #[prost(float, tag = "4")]
    pub pressure: f32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativePenMotionInput {
    #[prost(uint32, tag = "1")]
    pub pointer_id: u32,
    #[prost(float, tag = "2")]
    pub normalized_x: f32,
    #[prost(float, tag = "3")]
    pub normalized_y: f32,
    #[prost(float, tag = "4")]
    pub pressure: f32,
    #[prost(float, tag = "5")]
    pub tilt_x_degrees: f32,
    #[prost(float, tag = "6")]
    pub tilt_y_degrees: f32,
    #[prost(float, tag = "7")]
    pub rotation_degrees: f32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeGamepadMotionInput {
    #[prost(uint32, tag = "1")]
    pub gamepad_id: u32,
    #[prost(sint32, tag = "2")]
    pub left_stick_x: i32,
    #[prost(sint32, tag = "3")]
    pub left_stick_y: i32,
    #[prost(sint32, tag = "4")]
    pub right_stick_x: i32,
    #[prost(sint32, tag = "5")]
    pub right_stick_y: i32,
    #[prost(uint32, tag = "6")]
    pub left_trigger: u32,
    #[prost(uint32, tag = "7")]
    pub right_trigger: u32,
    #[prost(float, tag = "8")]
    pub gyro_x: f32,
    #[prost(float, tag = "9")]
    pub gyro_y: f32,
    #[prost(float, tag = "10")]
    pub gyro_z: f32,
    #[prost(float, tag = "11")]
    pub acceleration_x: f32,
    #[prost(float, tag = "12")]
    pub acceleration_y: f32,
    #[prost(float, tag = "13")]
    pub acceleration_z: f32,
}

#[derive(Clone, PartialEq, Message)]
pub struct ClientMotionEnvelope {
    #[prost(uint32, tag = "1")]
    pub motion_sequence: u32,
    #[prost(oneof = "client_motion_envelope::Payload", tags = "10, 11, 12, 13, 14")]
    pub payload: Option<client_motion_envelope::Payload>,
}

pub mod client_motion_envelope {
    use super::*;

    #[derive(Clone, PartialEq, Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        PointerMotion(NativePointerMotionInput),
        #[prost(message, tag = "11")]
        Scroll(NativeScrollInput),
        #[prost(message, tag = "12")]
        TouchMotion(NativeTouchMotionInput),
        #[prost(message, tag = "13")]
        PenMotion(NativePenMotionInput),
        #[prost(message, tag = "14")]
        GamepadMotion(NativeGamepadMotionInput),
    }
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeInputAck {
    #[prost(uint64, tag = "1")]
    pub highest_contiguous_event_sequence: u64,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Enumeration)]
#[repr(i32)]
pub enum NativeInputFailureCode {
    Unspecified = 0,
    PlatformRejected = 1,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeInputFailure {
    #[prost(uint64, tag = "1")]
    pub event_sequence: u64,
    #[prost(enumeration = "NativeInputFailureCode", tag = "2")]
    pub code: i32,
    #[prost(string, tag = "3")]
    pub message: String,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeInputReset {
    #[prost(uint32, tag = "1")]
    pub reason: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct NativeRumbleCommand {
    #[prost(uint32, tag = "1")]
    pub gamepad_id: u32,
    #[prost(uint32, tag = "2")]
    pub low_frequency_motor: u32,
    #[prost(uint32, tag = "3")]
    pub high_frequency_motor: u32,
    #[prost(uint32, tag = "4")]
    pub left_trigger_motor: u32,
    #[prost(uint32, tag = "5")]
    pub right_trigger_motor: u32,
    #[prost(uint32, tag = "6")]
    pub duration_milliseconds: u32,
}

#[derive(Clone, PartialEq, Message)]
pub struct HostInputEnvelope {
    #[prost(uint32, tag = "1")]
    pub session_epoch: u32,
    #[prost(uint64, tag = "2")]
    pub command_sequence: u64,
    #[prost(oneof = "host_input_envelope::Payload", tags = "10, 11, 12, 13")]
    pub payload: Option<host_input_envelope::Payload>,
}

pub mod host_input_envelope {
    use super::*;

    #[derive(Clone, PartialEq, Oneof)]
    pub enum Payload {
        #[prost(message, tag = "10")]
        Ack(NativeInputAck),
        #[prost(message, tag = "11")]
        Reset(NativeInputReset),
        #[prost(message, tag = "12")]
        Rumble(NativeRumbleCommand),
        #[prost(message, tag = "13")]
        Failure(NativeInputFailure),
    }
}

pub fn encode_client_input_message(
    envelope: &ClientInputEnvelope,
) -> Result<Vec<u8>, NativeInputWireError> {
    validate_client_envelope(envelope)?;
    encode_input_message(envelope)
}

pub fn decode_client_input_message(
    bytes: &[u8],
) -> Result<ClientInputEnvelope, NativeInputWireError> {
    let envelope = ClientInputEnvelope::decode(input_body(bytes)?)
        .map_err(|_| NativeInputWireError::InvalidMessage)?;
    validate_client_envelope(&envelope)?;
    Ok(envelope)
}

pub fn encode_host_input_message(
    envelope: &HostInputEnvelope,
) -> Result<Vec<u8>, NativeInputWireError> {
    if envelope.session_epoch == 0 || envelope.command_sequence == 0 || envelope.payload.is_none() {
        return Err(NativeInputWireError::InvalidEnvelope);
    }
    encode_input_message(envelope)
}

pub fn decode_host_input_message(bytes: &[u8]) -> Result<HostInputEnvelope, NativeInputWireError> {
    let envelope = HostInputEnvelope::decode(input_body(bytes)?)
        .map_err(|_| NativeInputWireError::InvalidMessage)?;
    if envelope.session_epoch == 0 || envelope.command_sequence == 0 || envelope.payload.is_none() {
        return Err(NativeInputWireError::InvalidEnvelope);
    }
    Ok(envelope)
}

fn validate_client_envelope(envelope: &ClientInputEnvelope) -> Result<(), NativeInputWireError> {
    if envelope.session_epoch == 0 || envelope.event_sequence == 0 || envelope.payload.is_none() {
        Err(NativeInputWireError::InvalidEnvelope)
    } else {
        Ok(())
    }
}

fn encode_input_message<M: Message>(message: &M) -> Result<Vec<u8>, NativeInputWireError> {
    if message.encoded_len() > NATIVE_INPUT_MESSAGE_LIMIT {
        return Err(NativeInputWireError::MessageTooLarge);
    }
    let mut encoded = Vec::with_capacity(message.encoded_len() + 3);
    message
        .encode_length_delimited(&mut encoded)
        .map_err(|_| NativeInputWireError::InvalidMessage)?;
    Ok(encoded)
}

fn input_body(bytes: &[u8]) -> Result<&[u8], NativeInputWireError> {
    if bytes.is_empty() {
        return Err(NativeInputWireError::TruncatedLength);
    }
    let mut length = 0_usize;
    let mut shift = 0_u32;
    for (index, byte) in bytes.iter().copied().enumerate().take(10) {
        let value = usize::from(byte & 0x7f)
            .checked_shl(shift)
            .ok_or(NativeInputWireError::LengthOverflow)?;
        length = length
            .checked_add(value)
            .ok_or(NativeInputWireError::LengthOverflow)?;
        if byte & 0x80 == 0 {
            if length > NATIVE_INPUT_MESSAGE_LIMIT {
                return Err(NativeInputWireError::MessageTooLarge);
            }
            let body_start = index + 1;
            let body_end = body_start
                .checked_add(length)
                .ok_or(NativeInputWireError::LengthOverflow)?;
            if bytes.len() < body_end {
                return Err(NativeInputWireError::TruncatedMessage);
            }
            if bytes.len() > body_end {
                return Err(NativeInputWireError::TrailingBytes);
            }
            return Ok(&bytes[body_start..body_end]);
        }
        shift = shift
            .checked_add(7)
            .ok_or(NativeInputWireError::LengthOverflow)?;
    }
    if bytes.len() < 10 {
        Err(NativeInputWireError::TruncatedLength)
    } else {
        Err(NativeInputWireError::LengthOverflow)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_input_envelopes_round_trip_multilingual_text_and_rumble() {
        let input = ClientInputEnvelope {
            session_epoch: 7,
            event_sequence: 9,
            payload: Some(client_input_envelope::Payload::Text(NativeTextInput {
                text_utf8: "한글 日本語 العربية".to_owned(),
                composition_id: 11,
                commit: false,
                selection_start_utf8: 3,
                selection_length_utf8: 6,
            })),
        };
        let encoded = encode_client_input_message(&input).unwrap();
        assert!(encoded.contains(&0x5a));
        assert_eq!(
            decode_client_input_message(encoded.as_slice()).unwrap(),
            input
        );

        let output = HostInputEnvelope {
            session_epoch: 7,
            command_sequence: 12,
            payload: Some(host_input_envelope::Payload::Rumble(NativeRumbleCommand {
                gamepad_id: 2,
                low_frequency_motor: 65_535,
                high_frequency_motor: 32_768,
                left_trigger_motor: 1,
                right_trigger_motor: 2,
                duration_milliseconds: 80,
            })),
        };
        let encoded = encode_host_input_message(&output).unwrap();
        assert!(encoded.contains(&0x62));
        assert_eq!(
            decode_host_input_message(encoded.as_slice()).unwrap(),
            output
        );
    }

    #[test]
    fn native_input_failure_round_trips_the_rejected_event_identity() {
        let output = HostInputEnvelope {
            session_epoch: 7,
            command_sequence: 12,
            payload: Some(host_input_envelope::Payload::Failure(NativeInputFailure {
                event_sequence: 9,
                code: NativeInputFailureCode::PlatformRejected as i32,
                message: "virtual gamepad injection is unavailable".to_owned(),
            })),
        };

        let encoded = encode_host_input_message(&output).unwrap();

        assert_eq!(decode_host_input_message(&encoded).unwrap(), output);
    }

    #[test]
    fn native_input_wire_rejects_missing_identity_and_trailing_bytes() {
        let invalid = ClientInputEnvelope {
            session_epoch: 0,
            event_sequence: 0,
            payload: None,
        };
        assert_eq!(
            encode_client_input_message(&invalid),
            Err(NativeInputWireError::InvalidEnvelope)
        );

        let valid = ClientInputEnvelope {
            session_epoch: 1,
            event_sequence: 1,
            payload: Some(client_input_envelope::Payload::Keyboard(
                NativeKeyboardInput {
                    hid_usage: 4,
                    pressed: true,
                    modifiers: 0,
                    repeat: false,
                },
            )),
        };
        let mut encoded = encode_client_input_message(&valid).unwrap();
        encoded.push(0);
        assert_eq!(
            decode_client_input_message(&encoded),
            Err(NativeInputWireError::TrailingBytes)
        );
    }
}
