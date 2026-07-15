use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce, Tag};

const PATH_MAGIC: u16 = 0x4c50;
const PATH_VERSION: u8 = 2;
const PATH_HEADER_BYTES: usize = 44;
const PATH_TAG_BYTES: usize = 16;
pub(crate) const PATH_DATAGRAM_BYTES: usize = PATH_HEADER_BYTES + PATH_TAG_BYTES;

#[repr(u8)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativePathProbeKind {
    Request = 1,
    Response = 2,
}

impl TryFrom<u8> for NativePathProbeKind {
    type Error = String;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Request),
            2 => Ok(Self::Response),
            _ => Err("native path probe kind is invalid".to_owned()),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativePathProbe {
    pub(crate) kind: NativePathProbeKind,
    pub(crate) session_epoch: u32,
    pub(crate) path_id: u16,
    pub(crate) challenge: [u8; 32],
}

pub(crate) fn native_path_probe_identity(bytes: &[u8]) -> Option<(u32, u16)> {
    valid_shape(bytes).then(|| {
        (
            u32::from_be_bytes(bytes[4..8].try_into().unwrap()),
            u16::from_be_bytes(bytes[8..10].try_into().unwrap()),
        )
    })
}

pub(crate) fn encode_native_path_probe(
    probe: NativePathProbe,
    key: &[u8; 16],
) -> Result<[u8; PATH_DATAGRAM_BYTES], String> {
    if probe.session_epoch == 0 || probe.path_id == 0 {
        return Err("native path probe identity is invalid".to_owned());
    }
    let mut bytes = [0_u8; PATH_DATAGRAM_BYTES];
    bytes[0..2].copy_from_slice(&PATH_MAGIC.to_be_bytes());
    bytes[2] = PATH_VERSION;
    bytes[3] = probe.kind as u8;
    bytes[4..8].copy_from_slice(&probe.session_epoch.to_be_bytes());
    bytes[8..10].copy_from_slice(&probe.path_id.to_be_bytes());
    bytes[12..44].copy_from_slice(&probe.challenge);
    let tag = Aes128Gcm::new_from_slice(key)
        .map_err(|_| "native path probe key is invalid".to_owned())?
        .encrypt_in_place_detached(
            Nonce::from_slice(&path_nonce(probe)),
            &bytes[..PATH_HEADER_BYTES],
            &mut [],
        )
        .map_err(|_| "native path probe authentication failed".to_owned())?;
    bytes[PATH_HEADER_BYTES..].copy_from_slice(tag.as_slice());
    Ok(bytes)
}

pub(crate) fn decode_native_path_probe(
    bytes: &[u8],
    key: &[u8; 16],
) -> Result<NativePathProbe, String> {
    if !valid_shape(bytes) {
        return Err("native path probe shape is invalid".to_owned());
    }
    let probe = NativePathProbe {
        kind: NativePathProbeKind::try_from(bytes[3])?,
        session_epoch: u32::from_be_bytes(bytes[4..8].try_into().unwrap()),
        path_id: u16::from_be_bytes(bytes[8..10].try_into().unwrap()),
        challenge: bytes[12..44].try_into().unwrap(),
    };
    if probe.session_epoch == 0 || probe.path_id == 0 {
        return Err("native path probe identity is invalid".to_owned());
    }
    Aes128Gcm::new_from_slice(key)
        .map_err(|_| "native path probe key is invalid".to_owned())?
        .decrypt_in_place_detached(
            Nonce::from_slice(&path_nonce(probe)),
            &bytes[..PATH_HEADER_BYTES],
            &mut [],
            Tag::from_slice(&bytes[PATH_HEADER_BYTES..]),
        )
        .map_err(|_| "native path probe authentication failed".to_owned())?;
    Ok(probe)
}

fn valid_shape(bytes: &[u8]) -> bool {
    bytes.len() == PATH_DATAGRAM_BYTES
        && u16::from_be_bytes(bytes[0..2].try_into().unwrap()) == PATH_MAGIC
        && bytes[2] == PATH_VERSION
        && bytes[10..12] == [0, 0]
        && matches!(bytes[3], 1 | 2)
}

fn path_nonce(probe: NativePathProbe) -> [u8; 12] {
    let mut nonce = [0_u8; 12];
    nonce[0..4].copy_from_slice(&probe.session_epoch.to_be_bytes());
    nonce[4..6].copy_from_slice(&probe.path_id.to_be_bytes());
    nonce[6] = probe.kind as u8;
    nonce
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> NativePathProbe {
        NativePathProbe {
            kind: NativePathProbeKind::Request,
            session_epoch: 0x0102_0304,
            path_id: 7,
            challenge: [0x55; 32],
        }
    }

    #[test]
    fn path_probe_has_one_exact_authenticated_layout() {
        let key = [0x42; 16];
        let encoded = encode_native_path_probe(request(), &key).unwrap();

        assert_eq!(encoded.len(), 60);
        assert_eq!(&encoded[..12], &[0x4c, 0x50, 2, 1, 1, 2, 3, 4, 0, 7, 0, 0]);
        assert_eq!(&encoded[12..44], &[0x55; 32]);
        assert_eq!(native_path_probe_identity(&encoded), Some((0x0102_0304, 7)));
        assert_eq!(decode_native_path_probe(&encoded, &key).unwrap(), request());
    }

    #[test]
    fn path_probe_rejects_header_token_and_tag_tampering() {
        let key = [0x42; 16];
        for index in [4, 12, 59] {
            let mut encoded = encode_native_path_probe(request(), &key).unwrap();
            encoded[index] ^= 1;
            assert!(decode_native_path_probe(&encoded, &key).is_err());
        }
    }

    #[test]
    fn request_and_response_use_distinct_authenticated_nonces() {
        let key = [0x42; 16];
        let request = request();
        let response = NativePathProbe {
            kind: NativePathProbeKind::Response,
            ..request
        };
        let request_bytes = encode_native_path_probe(request, &key).unwrap();
        let response_bytes = encode_native_path_probe(response, &key).unwrap();

        assert_ne!(&request_bytes[44..], &response_bytes[44..]);
        assert_eq!(
            decode_native_path_probe(&response_bytes, &key).unwrap(),
            response
        );
    }
}
