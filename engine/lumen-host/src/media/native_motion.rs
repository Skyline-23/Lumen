use lumen_engine::{decode_native_media_datagram, ClientMotionEnvelope, NativeMediaKind};
use prost::Message;

use crate::{NativeMotionError, PlatformNativeMotionEvent};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativeMotionIdentity {
    pub(crate) session_epoch: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct AcceptedNativeMotion {
    pub(crate) identity: NativeMotionIdentity,
    pub(crate) datagram_sequence: u32,
    pub(crate) motion_sequence: u32,
    pub(crate) capture_timestamp_us: u32,
    pub(crate) event: PlatformNativeMotionEvent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum NativeMotionDatagramError {
    InvalidTransport,
    NotMotion,
    InvalidObjectLength,
    InvalidEnvelope,
    InvalidPayload(NativeMotionError),
    ReplayedDatagramSequence,
    ReplayedMotionSequence,
}

#[derive(Default)]
pub(crate) struct NativeMotionReceiver {
    identity: Option<NativeMotionIdentity>,
    highest_datagram_sequence: Option<u32>,
    highest_motion_sequence: Option<u32>,
}

impl NativeMotionReceiver {
    pub(crate) fn accept(
        &mut self,
        datagram: &[u8],
        identity: NativeMotionIdentity,
    ) -> Result<AcceptedNativeMotion, NativeMotionDatagramError> {
        let decoded = decode_native_media_datagram(datagram)
            .map_err(|_| NativeMotionDatagramError::InvalidTransport)?;
        if decoded.header.kind != NativeMediaKind::InputMotion {
            return Err(NativeMotionDatagramError::NotMotion);
        }
        if self.identity != Some(identity) {
            self.identity = Some(identity);
            self.highest_datagram_sequence = None;
            self.highest_motion_sequence = None;
        }
        if self
            .highest_datagram_sequence
            .is_some_and(|highest| !is_newer_sequence(decoded.header.datagram_sequence, highest))
        {
            return Err(NativeMotionDatagramError::ReplayedDatagramSequence);
        }
        let payload = datagram
            .get(decoded.payload_offset..)
            .ok_or(NativeMotionDatagramError::InvalidObjectLength)?;
        let object_bytes = usize::try_from(decoded.header.object_bytes)
            .map_err(|_| NativeMotionDatagramError::InvalidObjectLength)?;
        if object_bytes != payload.len() {
            return Err(NativeMotionDatagramError::InvalidObjectLength);
        }
        let envelope = ClientMotionEnvelope::decode(&payload[..object_bytes])
            .map_err(|_| NativeMotionDatagramError::InvalidEnvelope)?;
        if envelope.motion_sequence != decoded.header.object_id {
            return Err(NativeMotionDatagramError::InvalidEnvelope);
        }
        if self
            .highest_motion_sequence
            .is_some_and(|highest| !is_newer_sequence(envelope.motion_sequence, highest))
        {
            return Err(NativeMotionDatagramError::ReplayedMotionSequence);
        }
        let event = PlatformNativeMotionEvent::try_from(
            envelope
                .payload
                .ok_or(NativeMotionDatagramError::InvalidEnvelope)?,
        )
        .map_err(NativeMotionDatagramError::InvalidPayload)?;
        self.highest_datagram_sequence = Some(decoded.header.datagram_sequence);
        self.highest_motion_sequence = Some(envelope.motion_sequence);
        Ok(AcceptedNativeMotion {
            identity,
            datagram_sequence: decoded.header.datagram_sequence,
            motion_sequence: envelope.motion_sequence,
            capture_timestamp_us: decoded.header.capture_timestamp_us,
            event,
        })
    }
}

fn is_newer_sequence(candidate: u32, current: u32) -> bool {
    let distance = candidate.wrapping_sub(current);
    distance != 0 && distance < (1_u32 << 31)
}

#[cfg(test)]
pub(crate) fn test_pointer_motion_datagram(
    datagram_sequence: u32,
    motion_sequence: u32,
) -> Vec<u8> {
    use lumen_engine::{
        client_motion_envelope, encode_native_media_header, NativeMediaHeader,
        NativePointerMotionInput, NativePointerMotionMode,
    };

    let envelope = ClientMotionEnvelope {
        motion_sequence,
        payload: Some(client_motion_envelope::Payload::PointerMotion(
            NativePointerMotionInput {
                pointer_id: 1,
                mode: NativePointerMotionMode::Relative as i32,
                delta_x: 4,
                delta_y: -2,
                normalized_x: 0.0,
                normalized_y: 0.0,
            },
        )),
    };
    let payload = envelope.encode_to_vec();
    let header = encode_native_media_header(NativeMediaHeader {
        kind: NativeMediaKind::InputMotion,
        flags: 0,
        generation_id: 0,
        datagram_sequence,
        object_id: motion_sequence,
        object_bytes: payload.len() as u32,
        capture_timestamp_us: 42,
        shard_index: 0,
        data_shards: 1,
        parity_shards: 0,
    })
    .unwrap();
    [header.as_slice(), payload.as_slice()].concat()
}

#[cfg(test)]
mod tests {
    use super::*;

    const IDENTITY: NativeMotionIdentity = NativeMotionIdentity { session_epoch: 7 };

    #[test]
    fn accepts_plain_quic_motion_datagrams() {
        let mut receiver = NativeMotionReceiver::default();
        let accepted = receiver
            .accept(&test_pointer_motion_datagram(0, 1), IDENTITY)
            .unwrap();
        assert_eq!(accepted.datagram_sequence, 0);
        assert_eq!(accepted.motion_sequence, 1);
    }

    #[test]
    fn rejects_replayed_motion_sequence() {
        let mut receiver = NativeMotionReceiver::default();
        receiver
            .accept(&test_pointer_motion_datagram(0, 1), IDENTITY)
            .unwrap();
        assert_eq!(
            receiver.accept(&test_pointer_motion_datagram(1, 1), IDENTITY),
            Err(NativeMotionDatagramError::ReplayedMotionSequence)
        );
    }

    #[test]
    fn rejects_trailing_bytes_after_a_compact_motion_object() {
        let mut datagram = test_pointer_motion_datagram(0, 1);
        datagram.push(0);
        assert_eq!(
            NativeMotionReceiver::default().accept(&datagram, IDENTITY),
            Err(NativeMotionDatagramError::InvalidObjectLength)
        );
    }
}
