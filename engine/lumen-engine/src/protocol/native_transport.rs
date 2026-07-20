pub const NATIVE_MEDIA_HEADER_BYTES: usize = 28;
pub const NATIVE_VIDEO_STREAM_ID: u16 = 1;
pub const NATIVE_AUDIO_STREAM_ID: u16 = 2;
pub const NATIVE_INPUT_MOTION_STREAM_ID: u16 = 3;
pub const NATIVE_INITIAL_CONFIGURATION_ID: u32 = 1;

pub const NATIVE_MEDIA_FLAG_PARITY_SHARD: u8 = 1 << 4;
pub const NATIVE_MEDIA_FLAG_FEC_BLOCK: u8 = 1 << 5;
pub const NATIVE_FEC_BLOCK_EXTENSION_BYTES: usize = 8;
pub const NATIVE_FEC_BLOCK_HEADER_BYTES: usize =
    NATIVE_MEDIA_HEADER_BYTES + NATIVE_FEC_BLOCK_EXTENSION_BYTES;

const NATIVE_MEDIA_ALLOWED_FLAGS: u8 = NATIVE_MEDIA_FLAG_PARITY_SHARD | NATIVE_MEDIA_FLAG_FEC_BLOCK;

#[repr(u8)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeMediaKind {
    VideoDelta = 1,
    Audio = 2,
    InputMotion = 3,
}

impl TryFrom<u8> for NativeMediaKind {
    type Error = NativeTransportError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::VideoDelta),
            2 => Ok(Self::Audio),
            3 => Ok(Self::InputMotion),
            _ => Err(NativeTransportError::InvalidMediaKind),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeMediaHeader {
    pub kind: NativeMediaKind,
    pub flags: u8,
    pub generation_id: u32,
    pub datagram_sequence: u32,
    pub object_id: u32,
    pub object_bytes: u32,
    pub capture_timestamp_us: u32,
    pub shard_index: u8,
    pub data_shards: u8,
    pub parity_shards: u8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DecodedNativeMediaDatagram {
    pub header: NativeMediaHeader,
    pub payload_offset: usize,
    pub fec_block: Option<NativeFecBlockExtension>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeFecBlockExtension {
    pub block_index: u8,
    pub block_count: u8,
    pub object_payload_offset: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeTransportError {
    HeaderTooShort,
    InvalidHeaderLength,
    InvalidMediaKind,
    ReservedFlags,
    ReservedField,
    InvalidGeneration,
    InvalidObjectLength,
    InvalidShardPlan,
    InvalidParityFlag,
    MissingFecBlockExtension,
    InvalidFecBlockExtension,
    InvalidMotionContract,
}

pub fn encode_native_media_header(
    header: NativeMediaHeader,
) -> Result<[u8; NATIVE_MEDIA_HEADER_BYTES], NativeTransportError> {
    validate_header(header)?;
    if header.flags & NATIVE_MEDIA_FLAG_FEC_BLOCK != 0 {
        return Err(NativeTransportError::MissingFecBlockExtension);
    }
    let mut bytes = [0_u8; NATIVE_MEDIA_HEADER_BYTES];
    write_header(&mut bytes, header, NATIVE_MEDIA_HEADER_BYTES);
    Ok(bytes)
}

pub fn encode_native_media_header_with_fec_block(
    header: NativeMediaHeader,
    fec_block: NativeFecBlockExtension,
) -> Result<[u8; NATIVE_FEC_BLOCK_HEADER_BYTES], NativeTransportError> {
    validate_header(header)?;
    if header.flags & NATIVE_MEDIA_FLAG_FEC_BLOCK == 0 {
        return Err(NativeTransportError::MissingFecBlockExtension);
    }
    validate_fec_block(fec_block, header.object_bytes)?;
    let mut bytes = [0_u8; NATIVE_FEC_BLOCK_HEADER_BYTES];
    write_header(&mut bytes, header, NATIVE_FEC_BLOCK_HEADER_BYTES);
    bytes[28] = fec_block.block_index;
    bytes[29] = fec_block.block_count;
    write_u16(&mut bytes, 30, 0);
    write_u32(&mut bytes, 32, fec_block.object_payload_offset);
    Ok(bytes)
}

fn write_header(bytes: &mut [u8], header: NativeMediaHeader, header_bytes: usize) {
    bytes[0] = header.kind as u8;
    bytes[1] = header.flags;
    write_u16(bytes, 2, header_bytes as u16);
    write_u32(bytes, 4, header.generation_id);
    write_u32(bytes, 8, header.datagram_sequence);
    write_u32(bytes, 12, header.object_id);
    write_u32(bytes, 16, header.object_bytes);
    write_u32(bytes, 20, header.capture_timestamp_us);
    bytes[24] = header.shard_index;
    bytes[25] = header.data_shards;
    bytes[26] = header.parity_shards;
    bytes[27] = 0;
}

pub fn decode_native_media_datagram(
    bytes: &[u8],
) -> Result<DecodedNativeMediaDatagram, NativeTransportError> {
    if bytes.len() < NATIVE_MEDIA_HEADER_BYTES {
        return Err(NativeTransportError::HeaderTooShort);
    }
    if bytes[27] != 0 {
        return Err(NativeTransportError::ReservedField);
    }
    let payload_offset = usize::from(read_u16(bytes, 2));
    if !(NATIVE_MEDIA_HEADER_BYTES..=bytes.len()).contains(&payload_offset) {
        return Err(NativeTransportError::InvalidHeaderLength);
    }
    let header = NativeMediaHeader {
        kind: NativeMediaKind::try_from(bytes[0])?,
        flags: bytes[1],
        generation_id: read_u32(bytes, 4),
        datagram_sequence: read_u32(bytes, 8),
        object_id: read_u32(bytes, 12),
        object_bytes: read_u32(bytes, 16),
        capture_timestamp_us: read_u32(bytes, 20),
        shard_index: bytes[24],
        data_shards: bytes[25],
        parity_shards: bytes[26],
    };
    validate_header(header)?;
    let expected_header_bytes = if header.flags & NATIVE_MEDIA_FLAG_FEC_BLOCK != 0 {
        NATIVE_FEC_BLOCK_HEADER_BYTES
    } else {
        NATIVE_MEDIA_HEADER_BYTES
    };
    if payload_offset != expected_header_bytes {
        return Err(NativeTransportError::InvalidHeaderLength);
    }
    let fec_block = if header.flags & NATIVE_MEDIA_FLAG_FEC_BLOCK != 0 {
        if read_u16(bytes, 30) != 0 {
            return Err(NativeTransportError::ReservedField);
        }
        let extension = NativeFecBlockExtension {
            block_index: bytes[28],
            block_count: bytes[29],
            object_payload_offset: read_u32(bytes, 32),
        };
        validate_fec_block(extension, header.object_bytes)?;
        Some(extension)
    } else {
        None
    };
    Ok(DecodedNativeMediaDatagram {
        header,
        payload_offset,
        fec_block,
    })
}

fn validate_header(header: NativeMediaHeader) -> Result<(), NativeTransportError> {
    if header.flags & !NATIVE_MEDIA_ALLOWED_FLAGS != 0 {
        return Err(NativeTransportError::ReservedFlags);
    }
    if (header.kind == NativeMediaKind::VideoDelta) != (header.generation_id != 0) {
        return Err(NativeTransportError::InvalidGeneration);
    }
    if header.object_id == 0 || header.object_bytes == 0 {
        return Err(NativeTransportError::InvalidObjectLength);
    }
    let total_shards = u16::from(header.data_shards)
        .checked_add(u16::from(header.parity_shards))
        .filter(|total| {
            header.data_shards > 0 && u16::from(header.shard_index) < *total && *total <= 256
        })
        .ok_or(NativeTransportError::InvalidShardPlan)?;
    let is_parity_index = header.shard_index >= header.data_shards;
    let has_parity_flag = header.flags & NATIVE_MEDIA_FLAG_PARITY_SHARD != 0;
    if is_parity_index != has_parity_flag || total_shards == 0 {
        return Err(NativeTransportError::InvalidParityFlag);
    }
    if header.kind == NativeMediaKind::InputMotion
        && (header.flags != 0
            || header.shard_index != 0
            || header.data_shards != 1
            || header.parity_shards != 0)
    {
        return Err(NativeTransportError::InvalidMotionContract);
    }
    Ok(())
}

fn validate_fec_block(
    fec_block: NativeFecBlockExtension,
    object_bytes: u32,
) -> Result<(), NativeTransportError> {
    if fec_block.block_count < 2
        || fec_block.block_index >= fec_block.block_count
        || fec_block.object_payload_offset >= object_bytes
        || (fec_block.block_index == 0) != (fec_block.object_payload_offset == 0)
    {
        Err(NativeTransportError::InvalidFecBlockExtension)
    } else {
        Ok(())
    }
}

fn read_u16(bytes: &[u8], offset: usize) -> u16 {
    u16::from_be_bytes(bytes[offset..offset + 2].try_into().unwrap())
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

fn write_u16(bytes: &mut [u8], offset: usize, value: u16) {
    bytes[offset..offset + 2].copy_from_slice(&value.to_be_bytes());
}

fn write_u32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
}
