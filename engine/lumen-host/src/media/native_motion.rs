use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce, Tag};
use lumen_engine::{decode_native_media_datagram, ClientMotionEnvelope, NativeMediaKind};
use prost::Message;

use super::native_packet::{direct_udp_nonce, DIRECT_UDP_TAG_BYTES};
use crate::{NativeMotionError, PlatformNativeMotionEvent};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativeMotionIdentity {
    pub(crate) session_epoch: u32,
    pub(crate) path_id: u16,
    pub(crate) policy_revision: u16,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct AcceptedNativeMotion {
    pub(crate) identity: NativeMotionIdentity,
    pub(crate) packet_sequence: u32,
    pub(crate) motion_sequence: u32,
    pub(crate) capture_timestamp_us: u32,
    pub(crate) event: PlatformNativeMotionEvent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum NativeMotionDatagramError {
    InvalidTransport,
    NotMotion,
    IdentityMismatch,
    TruncatedAuthenticationTag,
    AuthenticationFailed,
    InvalidFrameLength,
    InvalidEnvelope,
    InvalidPayload(NativeMotionError),
    ReplayedPacketSequence,
    ReplayedMotionSequence,
}

#[derive(Default)]
pub(crate) struct NativeMotionReceiver {
    identity: Option<NativeMotionIdentity>,
    highest_packet_sequence: Option<u32>,
    highest_motion_sequence: Option<u32>,
}

impl NativeMotionReceiver {
    pub(crate) fn accept(
        &mut self,
        datagram: &[u8],
        identity: NativeMotionIdentity,
        key: &[u8; 16],
    ) -> Result<AcceptedNativeMotion, NativeMotionDatagramError> {
        let decoded = decode_native_media_datagram(datagram)
            .map_err(|_| NativeMotionDatagramError::InvalidTransport)?;
        if decoded.header.kind != NativeMediaKind::InputMotion {
            return Err(NativeMotionDatagramError::NotMotion);
        }
        if decoded.header.session_epoch != identity.session_epoch
            || decoded.header.path_id != identity.path_id
            || decoded.header.policy_revision != identity.policy_revision
        {
            return Err(NativeMotionDatagramError::IdentityMismatch);
        }

        if self.identity != Some(identity) {
            self.identity = Some(identity);
            self.highest_packet_sequence = None;
            self.highest_motion_sequence = None;
        }
        if self
            .highest_packet_sequence
            .is_some_and(|highest| !is_newer_sequence(decoded.header.packet_sequence, highest))
        {
            return Err(NativeMotionDatagramError::ReplayedPacketSequence);
        }

        let payload = datagram
            .get(decoded.payload_offset..)
            .ok_or(NativeMotionDatagramError::TruncatedAuthenticationTag)?;
        let tag_offset = payload
            .len()
            .checked_sub(DIRECT_UDP_TAG_BYTES)
            .ok_or(NativeMotionDatagramError::TruncatedAuthenticationTag)?;
        let (ciphertext, tag) = payload.split_at(tag_offset);
        let mut plaintext = ciphertext.to_vec();
        Aes128Gcm::new_from_slice(key)
            .map_err(|_| NativeMotionDatagramError::AuthenticationFailed)?
            .decrypt_in_place_detached(
                Nonce::from_slice(&direct_udp_nonce(&decoded.header)),
                &datagram[..decoded.payload_offset],
                &mut plaintext,
                Tag::from_slice(tag),
            )
            .map_err(|_| NativeMotionDatagramError::AuthenticationFailed)?;
        let frame_bytes = usize::try_from(decoded.header.frame_bytes)
            .map_err(|_| NativeMotionDatagramError::InvalidFrameLength)?;
        if frame_bytes > plaintext.len() {
            return Err(NativeMotionDatagramError::InvalidFrameLength);
        }
        let envelope = ClientMotionEnvelope::decode(&plaintext[..frame_bytes])
            .map_err(|_| NativeMotionDatagramError::InvalidEnvelope)?;
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
        self.highest_packet_sequence = Some(decoded.header.packet_sequence);
        self.highest_motion_sequence = Some(envelope.motion_sequence);
        Ok(AcceptedNativeMotion {
            identity,
            packet_sequence: decoded.header.packet_sequence,
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
    identity: NativeMotionIdentity,
    key: &[u8; 16],
    packet_sequence: u32,
    motion_sequence: u32,
) -> Vec<u8> {
    use lumen_engine::{
        client_motion_envelope, encode_native_media_header, NativeMediaHeader,
        NativePointerMotionInput, NativePointerMotionMode, NATIVE_INPUT_MOTION_STREAM_ID,
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
    let mut payload = envelope.encode_to_vec();
    let header = NativeMediaHeader {
        kind: NativeMediaKind::InputMotion,
        flags: 0,
        session_epoch: identity.session_epoch,
        path_id: identity.path_id,
        policy_revision: identity.policy_revision,
        stream_id: NATIVE_INPUT_MOTION_STREAM_ID,
        shard_index: 0,
        data_shards: 1,
        parity_shards: 0,
        packet_sequence,
        frame_id: motion_sequence,
        frame_bytes: payload.len() as u32,
        capture_timestamp_us: 42,
    };
    let header_bytes = encode_native_media_header(header).unwrap();
    let tag = Aes128Gcm::new_from_slice(key)
        .unwrap()
        .encrypt_in_place_detached(
            Nonce::from_slice(&direct_udp_nonce(&header)),
            &header_bytes,
            &mut payload,
        )
        .unwrap();
    [header_bytes.as_slice(), payload.as_slice(), tag.as_slice()].concat()
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; 16] = [0x5a; 16];
    const IDENTITY: NativeMotionIdentity = NativeMotionIdentity {
        session_epoch: 7,
        path_id: 3,
        policy_revision: 2,
    };

    fn datagram(packet_sequence: u32, motion_sequence: u32) -> Vec<u8> {
        test_pointer_motion_datagram(IDENTITY, &KEY, packet_sequence, motion_sequence)
    }

    #[test]
    fn authenticates_decodes_and_accepts_monotonic_motion_with_wraparound() {
        let mut receiver = NativeMotionReceiver::default();
        let accepted = receiver
            .accept(&datagram(u32::MAX, u32::MAX), IDENTITY, &KEY)
            .unwrap();
        assert_eq!(accepted.motion_sequence, u32::MAX);
        assert!(matches!(
            accepted.event,
            PlatformNativeMotionEvent::Pointer {
                delta_x: 4,
                delta_y: -2,
                ..
            }
        ));
        assert_eq!(
            receiver
                .accept(&datagram(0, 0), IDENTITY, &KEY)
                .unwrap()
                .motion_sequence,
            0
        );
    }

    #[test]
    fn rejects_tampering_duplicate_and_out_of_order_motion() {
        let mut receiver = NativeMotionReceiver::default();
        receiver.accept(&datagram(10, 10), IDENTITY, &KEY).unwrap();
        assert_eq!(
            receiver.accept(&datagram(10, 11), IDENTITY, &KEY),
            Err(NativeMotionDatagramError::ReplayedPacketSequence)
        );
        assert_eq!(
            receiver.accept(&datagram(11, 9), IDENTITY, &KEY),
            Err(NativeMotionDatagramError::ReplayedMotionSequence)
        );
        let mut tampered = datagram(12, 12);
        let payload_index = 40;
        tampered[payload_index] ^= 0x80;
        assert_eq!(
            receiver.accept(&tampered, IDENTITY, &KEY),
            Err(NativeMotionDatagramError::AuthenticationFailed)
        );
    }
}
