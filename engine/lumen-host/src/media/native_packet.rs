use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use lumen_engine::{
    encode_native_media_header, encode_native_media_header_with_fec_block,
    encode_native_video_access_unit_descriptor, NativeFecBlockExtension, NativeMediaHeader,
    NativeMediaKind, NativeVideoAccessUnitDescriptor, NATIVE_FEC_BLOCK_HEADER_BYTES,
    NATIVE_MEDIA_FLAG_CONFIGURATION_BOUNDARY, NATIVE_MEDIA_FLAG_FEC_BLOCK,
    NATIVE_MEDIA_FLAG_KEYFRAME, NATIVE_MEDIA_FLAG_PARITY_SHARD, NATIVE_MEDIA_HEADER_BYTES,
};
use reed_solomon_erasure::galois_8::ReedSolomon;

use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};

pub(crate) const DIRECT_UDP_TAG_BYTES: usize = 16;
const REQUIRED_AUDIO_DURATION_FRAMES: u32 = 240;
const MAXIMUM_AUDIO_PAYLOAD_BYTES: usize = 1_400;
const MAXIMUM_REED_SOLOMON_SHARDS: usize = 256;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeMediaPacketizerConfig {
    pub session_epoch: u32,
    pub path_id: u16,
    pub policy_revision: u16,
    pub stream_id: u16,
    pub configuration_id: u32,
    pub maximum_datagram_payload: usize,
    pub direct_udp_key: [u8; 16],
}

#[derive(Debug, Eq, PartialEq)]
pub struct NativePacketizedUnit {
    pub datagrams: Vec<Vec<u8>>,
    pub next_sequence: u32,
}

#[derive(Clone, Copy)]
struct NativeUnitMetadata {
    kind: NativeMediaKind,
    unit_id: u32,
    capture_timestamp_us: u32,
    flags: u16,
    parity_percentage: u16,
}

pub struct NativeMediaPacketizer {
    config: NativeMediaPacketizerConfig,
    cipher: Aes128Gcm,
    next_sequence: u32,
    configuration_boundary_pending: bool,
}

impl NativeMediaPacketizer {
    pub fn new(config: NativeMediaPacketizerConfig, initial_sequence: u32) -> Result<Self, String> {
        if config.session_epoch == 0
            || config.path_id == 0
            || config.policy_revision == 0
            || config.stream_id == 0
            || config.configuration_id == 0
            || !valid_datagram_payload(config.maximum_datagram_payload)
        {
            return Err("native media packetizer configuration is invalid".to_owned());
        }
        let cipher = Aes128Gcm::new_from_slice(&config.direct_udp_key)
            .map_err(|_| "native media key is invalid".to_owned())?;
        Ok(Self {
            config,
            cipher,
            next_sequence: initial_sequence,
            configuration_boundary_pending: true,
        })
    }

    pub fn reconfigure(
        &mut self,
        policy_revision: u16,
        maximum_datagram_payload: usize,
    ) -> Result<(), String> {
        if policy_revision == 0 || !valid_datagram_payload(maximum_datagram_payload) {
            return Err("native media packetizer configuration is invalid".to_owned());
        }
        self.config.policy_revision = policy_revision;
        self.config.maximum_datagram_payload = maximum_datagram_payload;
        Ok(())
    }

    pub fn update_video_configuration(&mut self, configuration_id: u32) -> Result<(), String> {
        if self.config.stream_id != lumen_engine::NATIVE_VIDEO_STREAM_ID || configuration_id == 0 {
            return Err("native video configuration id is invalid".to_owned());
        }
        if self.config.configuration_id != configuration_id {
            self.config.configuration_id = configuration_id;
            self.configuration_boundary_pending = true;
        }
        Ok(())
    }

    pub fn packetize_video(
        &mut self,
        frame: &PlatformEncodedVideoFrame,
        frame_id: u32,
        parity_percentage: u16,
    ) -> Result<NativePacketizedUnit, String> {
        if self.configuration_boundary_pending && !frame.key_frame {
            return Err("first frame for a video configuration must be a key frame".to_owned());
        }
        let descriptor =
            encode_native_video_access_unit_descriptor(NativeVideoAccessUnitDescriptor {
                configuration_id: self.config.configuration_id,
                access_unit_bytes: u32::try_from(frame.payload.len())
                    .map_err(|_| "native video access unit is too large".to_owned())?,
            })
            .map_err(|_| "native video access unit descriptor is invalid".to_owned())?;
        let mut payload = Vec::with_capacity(descriptor.len() + frame.payload.len());
        payload.extend_from_slice(&descriptor);
        payload.extend_from_slice(&frame.payload);
        let packetized = self.packetize_unit(
            &payload,
            NativeUnitMetadata {
                kind: NativeMediaKind::Video,
                unit_id: frame_id,
                capture_timestamp_us: timestamp_to_microseconds(
                    frame.presentation_time_90khz,
                    90_000,
                ),
                flags: if frame.key_frame {
                    NATIVE_MEDIA_FLAG_KEYFRAME
                } else {
                    0
                } | if self.configuration_boundary_pending {
                    NATIVE_MEDIA_FLAG_CONFIGURATION_BOUNDARY
                } else {
                    0
                },
                parity_percentage,
            },
        )?;
        self.configuration_boundary_pending = false;
        Ok(packetized)
    }

    pub fn packetize_audio(
        &mut self,
        packet: &PlatformEncodedAudioPacket,
        unit_id: u32,
    ) -> Result<NativePacketizedUnit, String> {
        if packet.duration_frames != REQUIRED_AUDIO_DURATION_FRAMES {
            return Err("Opus packet duration must be 5 ms at 48 kHz".to_owned());
        }
        if packet.payload.len() > MAXIMUM_AUDIO_PAYLOAD_BYTES {
            return Err("Opus packet size is invalid".to_owned());
        }
        self.packetize_unit(
            &packet.payload,
            NativeUnitMetadata {
                kind: NativeMediaKind::Audio,
                unit_id,
                capture_timestamp_us: timestamp_to_microseconds(
                    packet.presentation_time_48khz,
                    48_000,
                ),
                flags: 0,
                parity_percentage: 0,
            },
        )
    }

    fn packetize_unit(
        &mut self,
        payload: &[u8],
        metadata: NativeUnitMetadata,
    ) -> Result<NativePacketizedUnit, String> {
        if payload.is_empty() {
            return Err("native media payload is empty".to_owned());
        }
        let frame_bytes = u32::try_from(payload.len())
            .map_err(|_| "native media payload exceeds the frame length field".to_owned())?;
        if metadata.parity_percentage > 255 {
            return Err("native media parity percentage is invalid".to_owned());
        }
        let maximum_data_shards = maximum_data_shards(metadata.parity_percentage);
        let base_shard_bytes =
            self.config.maximum_datagram_payload - NATIVE_MEDIA_HEADER_BYTES - DIRECT_UDP_TAG_BYTES;
        let base_data_shards = payload.len().div_ceil(base_shard_bytes);
        let uses_fec_blocks = base_data_shards
            .checked_add(parity_shards(base_data_shards, metadata.parity_percentage))
            .is_none_or(|total| total > MAXIMUM_REED_SOLOMON_SHARDS);
        let header_bytes = if uses_fec_blocks {
            NATIVE_FEC_BLOCK_HEADER_BYTES
        } else {
            NATIVE_MEDIA_HEADER_BYTES
        };
        let shard_bytes =
            self.config.maximum_datagram_payload - header_bytes - DIRECT_UDP_TAG_BYTES;
        let block_payload_bytes = maximum_data_shards
            .checked_mul(shard_bytes)
            .ok_or_else(|| "native media FEC block size overflowed".to_owned())?;
        let block_count = payload.len().div_ceil(block_payload_bytes);
        let block_count_u16 = u16::try_from(block_count)
            .map_err(|_| "native media FEC block count overflowed".to_owned())?;
        let total_shards = payload
            .chunks(block_payload_bytes)
            .try_fold(0_usize, |total, block| {
                let data_shards = block.len().div_ceil(shard_bytes);
                total.checked_add(
                    data_shards + parity_shards(data_shards, metadata.parity_percentage),
                )
            })
            .ok_or_else(|| "native media packet count overflowed".to_owned())?;
        let next_sequence = self
            .next_sequence
            .checked_add(
                u32::try_from(total_shards)
                    .map_err(|_| "native media packet count overflowed".to_owned())?,
            )
            .ok_or_else(|| "native media packet sequence exhausted".to_owned())?;

        let mut datagrams = Vec::with_capacity(total_shards);
        let base_flags = metadata.flags
            | if uses_fec_blocks {
                NATIVE_MEDIA_FLAG_FEC_BLOCK
            } else {
                0
            };
        for (block_index, block) in payload.chunks(block_payload_bytes).enumerate() {
            let data_shards = block.len().div_ceil(shard_bytes);
            let parity_shards = parity_shards(data_shards, metadata.parity_percentage);
            let data_shards_u16 = u16::try_from(data_shards)
                .map_err(|_| "native media data shard count overflowed".to_owned())?;
            let parity_shards_u16 = u16::try_from(parity_shards)
                .map_err(|_| "native media parity shard count overflowed".to_owned())?;
            let mut shards = block
                .chunks(shard_bytes)
                .map(|chunk| {
                    let mut shard = vec![0_u8; shard_bytes];
                    shard[..chunk.len()].copy_from_slice(chunk);
                    shard
                })
                .collect::<Vec<_>>();
            shards.extend((0..parity_shards).map(|_| vec![0_u8; shard_bytes]));
            if parity_shards != 0 {
                ReedSolomon::new(data_shards, parity_shards)
                    .and_then(|codec| codec.encode(&mut shards))
                    .map_err(|error| format!("native media parity encoding failed: {error}"))?;
            }
            let frame_payload_offset = u32::try_from(block_index * block_payload_bytes)
                .map_err(|_| "native media FEC block offset overflowed".to_owned())?;
            for (index, mut shard) in shards.into_iter().enumerate() {
                let packet_sequence = self.next_sequence + datagrams.len() as u32;
                let header = NativeMediaHeader {
                    kind: metadata.kind,
                    flags: base_flags
                        | if index >= data_shards {
                            NATIVE_MEDIA_FLAG_PARITY_SHARD
                        } else {
                            0
                        },
                    session_epoch: self.config.session_epoch,
                    path_id: self.config.path_id,
                    policy_revision: self.config.policy_revision,
                    stream_id: self.config.stream_id,
                    shard_index: index as u16,
                    data_shards: data_shards_u16,
                    parity_shards: parity_shards_u16,
                    packet_sequence,
                    frame_id: metadata.unit_id,
                    frame_bytes,
                    capture_timestamp_us: metadata.capture_timestamp_us,
                };
                let encoded_header = if uses_fec_blocks {
                    encode_native_media_header_with_fec_block(
                        header,
                        NativeFecBlockExtension {
                            block_index: block_index as u16,
                            block_count: block_count_u16,
                            frame_payload_offset,
                        },
                    )
                    .map_err(|error| format!("native media header is invalid: {error:?}"))?
                    .to_vec()
                } else {
                    encode_native_media_header(header)
                        .map_err(|error| format!("native media header is invalid: {error:?}"))?
                        .to_vec()
                };
                let tag = self
                    .cipher
                    .encrypt_in_place_detached(
                        Nonce::from_slice(&direct_udp_nonce(&header)),
                        &encoded_header,
                        &mut shard,
                    )
                    .map_err(|_| "native media payload encryption failed".to_owned())?;
                let mut datagram = Vec::with_capacity(self.config.maximum_datagram_payload);
                datagram.extend_from_slice(&encoded_header);
                datagram.extend_from_slice(&shard);
                datagram.extend_from_slice(tag.as_slice());
                datagrams.push(datagram);
            }
        }
        self.next_sequence = next_sequence;
        Ok(NativePacketizedUnit {
            datagrams,
            next_sequence,
        })
    }
}

pub(crate) fn direct_udp_nonce(header: &NativeMediaHeader) -> [u8; 12] {
    let mut nonce = [0_u8; 12];
    nonce[0..4].copy_from_slice(&header.session_epoch.to_be_bytes());
    nonce[4..6].copy_from_slice(&header.path_id.to_be_bytes());
    nonce[6..8].copy_from_slice(&header.stream_id.to_be_bytes());
    nonce[8..12].copy_from_slice(&header.packet_sequence.to_be_bytes());
    nonce
}

fn timestamp_to_microseconds(timestamp: u32, clock_rate: u64) -> u32 {
    ((u64::from(timestamp) * 1_000_000) / clock_rate) as u32
}

fn valid_datagram_payload(maximum_datagram_payload: usize) -> bool {
    maximum_datagram_payload > NATIVE_FEC_BLOCK_HEADER_BYTES + DIRECT_UDP_TAG_BYTES
}

fn parity_shards(data_shards: usize, parity_percentage: u16) -> usize {
    if parity_percentage == 0 {
        0
    } else {
        (data_shards * usize::from(parity_percentage)).div_ceil(100)
    }
}

fn maximum_data_shards(parity_percentage: u16) -> usize {
    (1..=MAXIMUM_REED_SOLOMON_SHARDS)
        .rev()
        .find(|data_shards| {
            data_shards + parity_shards(*data_shards, parity_percentage)
                <= MAXIMUM_REED_SOLOMON_SHARDS
        })
        .expect("one data shard always fits the configured parity range")
}
