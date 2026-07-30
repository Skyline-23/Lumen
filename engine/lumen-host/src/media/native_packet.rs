use lumen_engine::{
    encode_native_media_header, encode_native_media_header_with_fec_block,
    native_video_packetization_plan, NativeFecBlockExtension, NativeMediaHeader, NativeMediaKind,
    NATIVE_FEC_BLOCK_HEADER_BYTES, NATIVE_MEDIA_FLAG_FEC_BLOCK, NATIVE_MEDIA_FLAG_KEYFRAME,
    NATIVE_MEDIA_FLAG_PARITY_SHARD,
};
use reed_solomon_erasure::galois_8::ReedSolomon;

use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};

const REQUIRED_AUDIO_DURATION_FRAMES: u32 = 240;
const MAXIMUM_AUDIO_PAYLOAD_BYTES: usize = 1_400;

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
    keyframe: bool,
}

struct CachedFecCodec {
    data_shards: usize,
    parity_shards: usize,
    codec: ReedSolomon,
}

pub struct NativeMediaPacketizer {
    config: NativeMediaPacketizerConfig,
    next_sequence: u32,
    full_fec_codec: Option<CachedFecCodec>,
    tail_fec_codec: Option<CachedFecCodec>,
    #[cfg(test)]
    fec_codec_construction_count: usize,
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
            full_fec_codec: None,
            tail_fec_codec: None,
            #[cfg(test)]
            fec_codec_construction_count: 0,
        })
    }

    #[cfg(test)]
    pub(crate) fn fec_codec_construction_count(&self) -> usize {
        self.fec_codec_construction_count
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

    fn encode_fec_shards(
        &mut self,
        data_shards: usize,
        parity_shards: usize,
        full_block: bool,
        shards: &mut [Vec<u8>],
    ) -> Result<(), String> {
        let codec_matches = |cached: &CachedFecCodec| {
            cached.data_shards == data_shards && cached.parity_shards == parity_shards
        };
        let cache_hit = if full_block {
            self.full_fec_codec.as_ref().is_some_and(codec_matches)
        } else {
            self.tail_fec_codec.as_ref().is_some_and(codec_matches)
        };
        if !cache_hit {
            let codec = ReedSolomon::new(data_shards, parity_shards)
                .map_err(|error| format!("native media parity encoding failed: {error}"))?;
            let cached = CachedFecCodec {
                data_shards,
                parity_shards,
                codec,
            };
            if full_block {
                self.full_fec_codec = Some(cached);
            } else {
                self.tail_fec_codec = Some(cached);
            }
            #[cfg(test)]
            {
                self.fec_codec_construction_count += 1;
            }
        }
        let cached = if full_block {
            self.full_fec_codec.as_ref()
        } else {
            self.tail_fec_codec.as_ref()
        };
        cached
            .expect("FEC codec cache contains the requested codec")
            .codec
            .encode(shards)
            .map_err(|error| format!("native media parity encoding failed: {error}"))
    }

    pub fn packetize_video_delta(
        &mut self,
        frame: &PlatformEncodedVideoFrame,
        frame_id: u32,
        parity_percentage: u16,
    ) -> Result<NativePacketizedUnit, String> {
        self.packetize_unit(
            &frame.payload,
            NativeUnitMetadata {
                object_id: frame_id,
                capture_timestamp_us: timestamp_to_microseconds(
                    frame.presentation_time_90khz,
                    90_000,
                ),
                parity_percentage,
                keyframe: frame.key_frame,
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
                    u64::from(packet.presentation_time_48khz),
                    48_000,
                ),
                parity_percentage: 0,
                keyframe: false,
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
        let plan = native_video_packetization_plan(
            payload.len(),
            self.config.maximum_datagram_payload,
            metadata.parity_percentage,
        )
        .ok_or_else(|| "native media packetization plan is invalid".to_owned())?;
        let block_count_u8 = u8::try_from(plan.block_count)
            .map_err(|_| "native media FEC block count overflowed".to_owned())?;
        let next_sequence = self
            .next_sequence
            .checked_add(
                u32::try_from(plan.total_shards)
                    .map_err(|_| "native media packet count overflowed".to_owned())?,
            )
            .ok_or_else(|| "native media datagram sequence exhausted".to_owned())?;

        let mut datagrams = Vec::with_capacity(plan.total_shards);
        let base_flags = (if plan.uses_fec_blocks {
            NATIVE_MEDIA_FLAG_FEC_BLOCK
        } else {
            0
        }) | if metadata.keyframe {
            NATIVE_MEDIA_FLAG_KEYFRAME
        } else {
            0
        };
        for (block_index, block) in payload.chunks(plan.block_payload_bytes).enumerate() {
            let data_shards = block.len().div_ceil(plan.shard_bytes);
            let parity_shards = parity_shards(data_shards, metadata.parity_percentage);
            let data_shards_u8 = u8::try_from(data_shards)
                .map_err(|_| "native media data shard count overflowed".to_owned())?;
            let parity_shards_u8 = u8::try_from(parity_shards)
                .map_err(|_| "native media parity shard count overflowed".to_owned())?;
            let mut shards = block
                .chunks(plan.shard_bytes)
                .map(|chunk| {
                    let mut shard = vec![0_u8; plan.shard_bytes];
                    shard[..chunk.len()].copy_from_slice(chunk);
                    shard
                })
                .collect::<Vec<_>>();
            shards.extend((0..parity_shards).map(|_| vec![0_u8; plan.shard_bytes]));
            if parity_shards != 0 {
                self.encode_fec_shards(
                    data_shards,
                    parity_shards,
                    plan.uses_fec_blocks && block.len() == plan.block_payload_bytes,
                    &mut shards,
                )?;
            }
            let object_payload_offset = u32::try_from(block_index * plan.block_payload_bytes)
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
                let encoded_header = if plan.uses_fec_blocks {
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
        debug_assert_eq!(
            datagrams.iter().map(Vec::len).sum::<usize>(),
            plan.total_wire_bytes
        );
        self.next_sequence = next_sequence;
        Ok(NativePacketizedUnit {
            datagrams,
            next_sequence,
        })
    }
}

fn timestamp_to_microseconds(timestamp: u64, clock_rate: u64) -> u32 {
    ((u128::from(timestamp) * 1_000_000) / u128::from(clock_rate)) as u32
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
