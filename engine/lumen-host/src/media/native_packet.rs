use lumen_engine::{
    encode_native_media_header, encode_native_media_header_with_fec_block, NativeFecBlockExtension,
    NativeMediaHeader, NativeMediaKind, NATIVE_FEC_BLOCK_HEADER_BYTES, NATIVE_MEDIA_FLAG_FEC_BLOCK,
    NATIVE_MEDIA_FLAG_PARITY_SHARD, NATIVE_MEDIA_HEADER_BYTES,
};
use reed_solomon_erasure::galois_8::ReedSolomon;

use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};

const REQUIRED_AUDIO_DURATION_FRAMES: u32 = 240;
const MAXIMUM_AUDIO_PAYLOAD_BYTES: usize = 1_400;
const MAXIMUM_REED_SOLOMON_SHARDS: usize = 256;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeMediaPacketizerConfig {
    pub kind: NativeMediaKind,
    pub maximum_datagram_payload: usize,
    pub generation_id: u32,
}

#[derive(Debug, Eq, PartialEq)]
pub struct NativePacketizedUnit {
    pub datagrams: Vec<Vec<u8>>,
    pub next_sequence: u32,
}

#[derive(Clone, Copy)]
struct NativeUnitMetadata {
    object_id: u32,
    capture_timestamp_us: u32,
    parity_percentage: u16,
}

pub struct NativeMediaPacketizer {
    config: NativeMediaPacketizerConfig,
    next_sequence: u32,
}

impl NativeMediaPacketizer {
    pub fn new(config: NativeMediaPacketizerConfig, initial_sequence: u32) -> Result<Self, String> {
        if !valid_datagram_payload(config.maximum_datagram_payload)
            || (config.kind == NativeMediaKind::VideoDelta) != (config.generation_id != 0)
        {
            return Err("native media packetizer configuration is invalid".to_owned());
        }
        Ok(Self {
            config,
            next_sequence: initial_sequence,
        })
    }

    pub fn reconfigure(&mut self, maximum_datagram_payload: usize) -> Result<(), String> {
        if !valid_datagram_payload(maximum_datagram_payload) {
            return Err("native media packetizer configuration is invalid".to_owned());
        }
        self.config.maximum_datagram_payload = maximum_datagram_payload;
        Ok(())
    }

    pub fn update_video_generation(&mut self, generation_id: u32) -> Result<(), String> {
        if self.config.kind != NativeMediaKind::VideoDelta || generation_id == 0 {
            return Err("native video generation id is invalid".to_owned());
        }
        self.config.generation_id = generation_id;
        Ok(())
    }

    pub fn packetize_video_delta(
        &mut self,
        frame: &PlatformEncodedVideoFrame,
        frame_id: u32,
        parity_percentage: u16,
    ) -> Result<NativePacketizedUnit, String> {
        if frame.key_frame {
            return Err("video keyframes must use the reliable bootstrap stream".to_owned());
        }
        self.packetize_unit(
            &frame.payload,
            NativeUnitMetadata {
                object_id: frame_id,
                capture_timestamp_us: timestamp_to_microseconds(
                    frame.presentation_time_90khz,
                    90_000,
                ),
                parity_percentage,
            },
        )
    }

    pub fn packetize_audio(
        &mut self,
        packet: &PlatformEncodedAudioPacket,
        unit_id: u32,
    ) -> Result<NativePacketizedUnit, String> {
        if self.config.kind != NativeMediaKind::Audio {
            return Err("native audio packetizer flow is invalid".to_owned());
        }
        if packet.duration_frames != REQUIRED_AUDIO_DURATION_FRAMES {
            return Err("Opus packet duration must be 5 ms at 48 kHz".to_owned());
        }
        if packet.payload.len() > MAXIMUM_AUDIO_PAYLOAD_BYTES {
            return Err("Opus packet size is invalid".to_owned());
        }
        self.packetize_unit(
            &packet.payload,
            NativeUnitMetadata {
                object_id: unit_id,
                capture_timestamp_us: timestamp_to_microseconds(
                    packet.presentation_time_48khz,
                    48_000,
                ),
                parity_percentage: 0,
            },
        )
    }

    fn packetize_unit(
        &mut self,
        payload: &[u8],
        metadata: NativeUnitMetadata,
    ) -> Result<NativePacketizedUnit, String> {
        if payload.is_empty() || metadata.object_id == 0 {
            return Err("native media payload is empty or has no object id".to_owned());
        }
        let object_bytes = u32::try_from(payload.len())
            .map_err(|_| "native media payload exceeds the object length field".to_owned())?;
        if metadata.parity_percentage > 255 {
            return Err("native media parity percentage is invalid".to_owned());
        }
        let maximum_data_shards = maximum_data_shards(metadata.parity_percentage);
        let base_shard_bytes = self.config.maximum_datagram_payload - NATIVE_MEDIA_HEADER_BYTES;
        let base_data_shards = payload.len().div_ceil(base_shard_bytes);
        let uses_fec_blocks = base_data_shards
            .checked_add(parity_shards(base_data_shards, metadata.parity_percentage))
            .is_none_or(|total| total > MAXIMUM_REED_SOLOMON_SHARDS);
        let header_bytes = if uses_fec_blocks {
            NATIVE_FEC_BLOCK_HEADER_BYTES
        } else {
            NATIVE_MEDIA_HEADER_BYTES
        };
        let shard_bytes = self.config.maximum_datagram_payload - header_bytes;
        let block_payload_bytes = maximum_data_shards
            .checked_mul(shard_bytes)
            .ok_or_else(|| "native media FEC block size overflowed".to_owned())?;
        let block_count = payload.len().div_ceil(block_payload_bytes);
        let block_count_u8 = u8::try_from(block_count)
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
            .ok_or_else(|| "native media datagram sequence exhausted".to_owned())?;

        let mut datagrams = Vec::with_capacity(total_shards);
        let base_flags = if uses_fec_blocks {
            NATIVE_MEDIA_FLAG_FEC_BLOCK
        } else {
            0
        };
        for (block_index, block) in payload.chunks(block_payload_bytes).enumerate() {
            let data_shards = block.len().div_ceil(shard_bytes);
            let parity_shards = parity_shards(data_shards, metadata.parity_percentage);
            let data_shards_u8 = u8::try_from(data_shards)
                .map_err(|_| "native media data shard count overflowed".to_owned())?;
            let parity_shards_u8 = u8::try_from(parity_shards)
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
            let object_payload_offset = u32::try_from(block_index * block_payload_bytes)
                .map_err(|_| "native media FEC block offset overflowed".to_owned())?;
            for (index, shard) in shards.into_iter().enumerate() {
                let header = NativeMediaHeader {
                    kind: self.config.kind,
                    flags: base_flags
                        | if index >= data_shards {
                            NATIVE_MEDIA_FLAG_PARITY_SHARD
                        } else {
                            0
                        },
                    generation_id: self.config.generation_id,
                    datagram_sequence: self.next_sequence + datagrams.len() as u32,
                    object_id: metadata.object_id,
                    object_bytes,
                    capture_timestamp_us: metadata.capture_timestamp_us,
                    shard_index: u8::try_from(index)
                        .map_err(|_| "native media shard index overflowed".to_owned())?,
                    data_shards: data_shards_u8,
                    parity_shards: parity_shards_u8,
                };
                let encoded_header = if uses_fec_blocks {
                    encode_native_media_header_with_fec_block(
                        header,
                        NativeFecBlockExtension {
                            block_index: u8::try_from(block_index).map_err(|_| {
                                "native media FEC block index overflowed".to_owned()
                            })?,
                            block_count: block_count_u8,
                            object_payload_offset,
                        },
                    )
                    .map_err(|error| format!("native media header is invalid: {error:?}"))?
                    .to_vec()
                } else {
                    encode_native_media_header(header)
                        .map_err(|error| format!("native media header is invalid: {error:?}"))?
                        .to_vec()
                };
                let mut datagram = Vec::with_capacity(self.config.maximum_datagram_payload);
                datagram.extend_from_slice(&encoded_header);
                datagram.extend_from_slice(&shard);
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

fn timestamp_to_microseconds(timestamp: u32, clock_rate: u64) -> u32 {
    ((u64::from(timestamp) * 1_000_000) / clock_rate) as u32
}

fn valid_datagram_payload(maximum_datagram_payload: usize) -> bool {
    maximum_datagram_payload > NATIVE_FEC_BLOCK_HEADER_BYTES
}

fn parity_shards(data_shards: usize, parity_percentage: u16) -> usize {
    if parity_percentage == 0 {
        0
    } else {
        (data_shards * usize::from(parity_percentage)).div_ceil(100)
    }
}

fn maximum_data_shards(parity_percentage: u16) -> usize {
    (1..=255)
        .rev()
        .find(|data_shards| {
            data_shards + parity_shards(*data_shards, parity_percentage)
                <= MAXIMUM_REED_SOLOMON_SHARDS
        })
        .expect("one data shard always fits the configured parity range")
}
