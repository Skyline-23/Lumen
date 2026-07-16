pub const NATIVE_MEDIA_MAGIC: u16 = 0x4c33;
pub const NATIVE_MEDIA_VERSION: u8 = 3;
pub const NATIVE_MEDIA_HEADER_BYTES: usize = 40;
pub const NATIVE_VIDEO_STREAM_ID: u16 = 1;
pub const NATIVE_AUDIO_STREAM_ID: u16 = 2;
pub const NATIVE_INPUT_MOTION_STREAM_ID: u16 = 3;
pub const NATIVE_INITIAL_CONFIGURATION_ID: u32 = 1;
pub const NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES: usize = 8;

pub const NATIVE_MEDIA_FLAG_KEYFRAME: u16 = 1 << 0;
pub const NATIVE_MEDIA_FLAG_CONFIGURATION_BOUNDARY: u16 = 1 << 1;
pub const NATIVE_MEDIA_FLAG_DISCONTINUITY: u16 = 1 << 2;
pub const NATIVE_MEDIA_FLAG_END_OF_STREAM: u16 = 1 << 3;
pub const NATIVE_MEDIA_FLAG_PARITY_SHARD: u16 = 1 << 4;
pub const NATIVE_MEDIA_FLAG_FEC_BLOCK: u16 = 1 << 5;
pub const NATIVE_FEC_BLOCK_EXTENSION_BYTES: usize = 8;
pub const NATIVE_FEC_BLOCK_HEADER_BYTES: usize =
    NATIVE_MEDIA_HEADER_BYTES + NATIVE_FEC_BLOCK_EXTENSION_BYTES;

const NATIVE_MEDIA_ALLOWED_FLAGS: u16 = NATIVE_MEDIA_FLAG_KEYFRAME
    | NATIVE_MEDIA_FLAG_CONFIGURATION_BOUNDARY
    | NATIVE_MEDIA_FLAG_DISCONTINUITY
    | NATIVE_MEDIA_FLAG_END_OF_STREAM
    | NATIVE_MEDIA_FLAG_PARITY_SHARD
    | NATIVE_MEDIA_FLAG_FEC_BLOCK;

#[repr(u8)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeMediaKind {
    Video = 1,
    Audio = 2,
    InputMotion = 3,
}

impl TryFrom<u8> for NativeMediaKind {
    type Error = NativeTransportError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Video),
            2 => Ok(Self::Audio),
            3 => Ok(Self::InputMotion),
            _ => Err(NativeTransportError::InvalidMediaKind),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeMediaHeader {
    pub kind: NativeMediaKind,
    pub flags: u16,
    pub session_epoch: u32,
    pub path_id: u16,
    pub policy_revision: u16,
    pub stream_id: u16,
    pub shard_index: u16,
    pub data_shards: u16,
    pub parity_shards: u16,
    pub packet_sequence: u32,
    pub frame_id: u32,
    pub frame_bytes: u32,
    pub capture_timestamp_us: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DecodedNativeMediaDatagram {
    pub header: NativeMediaHeader,
    pub payload_offset: usize,
    pub fec_block: Option<NativeFecBlockExtension>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeFecBlockExtension {
    pub block_index: u16,
    pub block_count: u16,
    pub frame_payload_offset: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeVideoAccessUnitDescriptor {
    pub configuration_id: u32,
    pub access_unit_bytes: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeTransportError {
    HeaderTooShort,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeaderLength,
    InvalidMediaKind,
    ReservedFlags,
    InvalidSessionEpoch,
    InvalidPathId,
    InvalidPolicyRevision,
    InvalidStreamId,
    InvalidFrameLength,
    InvalidShardPlan,
    InvalidParityFlag,
    MissingFecBlockExtension,
    InvalidFecBlockExtension,
    InvalidMotionContract,
    InvalidVideoAccessUnitDescriptor,
}

pub fn encode_native_video_access_unit_descriptor(
    descriptor: NativeVideoAccessUnitDescriptor,
) -> Result<[u8; NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES], NativeTransportError> {
    validate_video_access_unit_descriptor(descriptor)?;
    let mut bytes = [0_u8; NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES];
    write_u32(&mut bytes, 0, descriptor.configuration_id);
    write_u32(&mut bytes, 4, descriptor.access_unit_bytes);
    Ok(bytes)
}

pub fn decode_native_video_access_unit(
    bytes: &[u8],
) -> Result<(NativeVideoAccessUnitDescriptor, &[u8]), NativeTransportError> {
    if bytes.len() < NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES {
        return Err(NativeTransportError::InvalidVideoAccessUnitDescriptor);
    }
    let descriptor = NativeVideoAccessUnitDescriptor {
        configuration_id: read_u32(bytes, 0),
        access_unit_bytes: read_u32(bytes, 4),
    };
    validate_video_access_unit_descriptor(descriptor)?;
    let access_unit_bytes = usize::try_from(descriptor.access_unit_bytes)
        .map_err(|_| NativeTransportError::InvalidVideoAccessUnitDescriptor)?;
    let payload = bytes
        .get(NATIVE_VIDEO_ACCESS_UNIT_DESCRIPTOR_BYTES..)
        .filter(|payload| payload.len() == access_unit_bytes)
        .ok_or(NativeTransportError::InvalidVideoAccessUnitDescriptor)?;
    Ok((descriptor, payload))
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
    validate_fec_block(fec_block, header.frame_bytes)?;

    let mut bytes = [0_u8; NATIVE_FEC_BLOCK_HEADER_BYTES];
    write_header(&mut bytes, header, NATIVE_FEC_BLOCK_HEADER_BYTES);
    write_u16(&mut bytes, 40, fec_block.block_index);
    write_u16(&mut bytes, 42, fec_block.block_count);
    write_u32(&mut bytes, 44, fec_block.frame_payload_offset);
    Ok(bytes)
}

fn write_header(bytes: &mut [u8], header: NativeMediaHeader, header_bytes: usize) {
    write_u16(bytes, 0, NATIVE_MEDIA_MAGIC);
    bytes[2] = NATIVE_MEDIA_VERSION;
    bytes[3] = header.kind as u8;
    write_u16(bytes, 4, header.flags);
    write_u16(bytes, 6, header_bytes as u16);
    write_u32(bytes, 8, header.session_epoch);
    write_u16(bytes, 12, header.path_id);
    write_u16(bytes, 14, header.policy_revision);
    write_u16(bytes, 16, header.stream_id);
    write_u16(bytes, 18, header.shard_index);
    write_u16(bytes, 20, header.data_shards);
    write_u16(bytes, 22, header.parity_shards);
    write_u32(bytes, 24, header.packet_sequence);
    write_u32(bytes, 28, header.frame_id);
    write_u32(bytes, 32, header.frame_bytes);
    write_u32(bytes, 36, header.capture_timestamp_us);
}

pub fn decode_native_media_datagram(
    bytes: &[u8],
) -> Result<DecodedNativeMediaDatagram, NativeTransportError> {
    if bytes.len() < NATIVE_MEDIA_HEADER_BYTES {
        return Err(NativeTransportError::HeaderTooShort);
    }
    if read_u16(bytes, 0) != NATIVE_MEDIA_MAGIC {
        return Err(NativeTransportError::InvalidMagic);
    }
    if bytes[2] != NATIVE_MEDIA_VERSION {
        return Err(NativeTransportError::UnsupportedVersion);
    }

    let payload_offset = usize::from(read_u16(bytes, 6));
    if !(NATIVE_MEDIA_HEADER_BYTES..=bytes.len()).contains(&payload_offset) {
        return Err(NativeTransportError::InvalidHeaderLength);
    }

    let header = NativeMediaHeader {
        kind: NativeMediaKind::try_from(bytes[3])?,
        flags: read_u16(bytes, 4),
        session_epoch: read_u32(bytes, 8),
        path_id: read_u16(bytes, 12),
        policy_revision: read_u16(bytes, 14),
        stream_id: read_u16(bytes, 16),
        shard_index: read_u16(bytes, 18),
        data_shards: read_u16(bytes, 20),
        parity_shards: read_u16(bytes, 22),
        packet_sequence: read_u32(bytes, 24),
        frame_id: read_u32(bytes, 28),
        frame_bytes: read_u32(bytes, 32),
        capture_timestamp_us: read_u32(bytes, 36),
    };
    validate_header(header)?;
    let fec_block = if header.flags & NATIVE_MEDIA_FLAG_FEC_BLOCK != 0 {
        if payload_offset < NATIVE_FEC_BLOCK_HEADER_BYTES {
            return Err(NativeTransportError::MissingFecBlockExtension);
        }
        let extension = NativeFecBlockExtension {
            block_index: read_u16(bytes, 40),
            block_count: read_u16(bytes, 42),
            frame_payload_offset: read_u32(bytes, 44),
        };
        validate_fec_block(extension, header.frame_bytes)?;
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
    if header.session_epoch == 0 {
        return Err(NativeTransportError::InvalidSessionEpoch);
    }
    if header.path_id == 0 {
        return Err(NativeTransportError::InvalidPathId);
    }
    if header.policy_revision == 0 {
        return Err(NativeTransportError::InvalidPolicyRevision);
    }
    if header.stream_id == 0 {
        return Err(NativeTransportError::InvalidStreamId);
    }
    if header.frame_bytes == 0 {
        return Err(NativeTransportError::InvalidFrameLength);
    }

    let total_shards = header
        .data_shards
        .checked_add(header.parity_shards)
        .filter(|total| header.data_shards > 0 && header.shard_index < *total)
        .ok_or(NativeTransportError::InvalidShardPlan)?;
    let is_parity_index = header.shard_index >= header.data_shards;
    let has_parity_flag = header.flags & NATIVE_MEDIA_FLAG_PARITY_SHARD != 0;
    if is_parity_index != has_parity_flag || total_shards == 0 {
        return Err(NativeTransportError::InvalidParityFlag);
    }
    if header.kind == NativeMediaKind::Audio && header.flags & NATIVE_MEDIA_FLAG_KEYFRAME != 0 {
        return Err(NativeTransportError::ReservedFlags);
    }
    if header.kind == NativeMediaKind::InputMotion
        && (header.stream_id != NATIVE_INPUT_MOTION_STREAM_ID
            || header.flags != 0
            || header.shard_index != 0
            || header.data_shards != 1
            || header.parity_shards != 0)
    {
        return Err(NativeTransportError::InvalidMotionContract);
    }
    Ok(())
}

fn validate_video_access_unit_descriptor(
    descriptor: NativeVideoAccessUnitDescriptor,
) -> Result<(), NativeTransportError> {
    if descriptor.configuration_id == 0 || descriptor.access_unit_bytes == 0 {
        Err(NativeTransportError::InvalidVideoAccessUnitDescriptor)
    } else {
        Ok(())
    }
}

fn validate_fec_block(
    fec_block: NativeFecBlockExtension,
    frame_bytes: u32,
) -> Result<(), NativeTransportError> {
    if fec_block.block_count < 2
        || fec_block.block_index >= fec_block.block_count
        || fec_block.frame_payload_offset >= frame_bytes
        || (fec_block.block_index == 0) != (fec_block.frame_payload_offset == 0)
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
