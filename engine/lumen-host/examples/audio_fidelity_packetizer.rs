use std::env;
use std::fs;
use std::path::Path;

use lumen_engine::NativeMediaKind;
use lumen_host::media::native_packet::{
    NativeMediaPacketizer, NativeMediaPacketizerConfig, NativePacketizedUnit,
};
use lumen_host::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};
use serde::Serialize;

const MAXIMUM_DATAGRAM_PAYLOAD: usize = 1_200;
const VIDEO_GENERATION_ID: u32 = 7;
const VIDEO_FRAME_COUNT: u32 = 1_200;
const VIDEO_FRAME_DURATION_90KHZ: u64 = 750;
const VIDEO_PAYLOAD_BYTES: usize = 12 * 1_024;

#[derive(Debug)]
struct AudioPacket {
    object_id: u32,
    presentation_time_48khz: u32,
    duration_frames: u32,
    payload: Vec<u8>,
}

#[derive(Serialize)]
struct PacketizerReport {
    schema_version: u32,
    maximum_datagram_payload: usize,
    audio_objects: usize,
    video_objects: u32,
    audio_datagrams: usize,
    video_datagrams: usize,
    total_datagrams: usize,
    video_payload_bytes_per_frame: usize,
}

fn main() -> Result<(), String> {
    let mut arguments = env::args_os().skip(1);
    let input = arguments
        .next()
        .ok_or_else(|| "usage: audio_fidelity_packetizer <input.laf> <output.lad>".to_owned())?;
    let output = arguments
        .next()
        .ok_or_else(|| "usage: audio_fidelity_packetizer <input.laf> <output.lad>".to_owned())?;
    if arguments.next().is_some() {
        return Err("audio fidelity packetizer received unexpected arguments".to_owned());
    }

    let audio_packets = read_audio_packets(Path::new(&input))?;
    let mut audio_packetizer = NativeMediaPacketizer::new(
        NativeMediaPacketizerConfig {
            kind: NativeMediaKind::Audio,
            maximum_datagram_payload: MAXIMUM_DATAGRAM_PAYLOAD,
            generation_id: 0,
        },
        0,
    )?;
    let mut video_packetizer = NativeMediaPacketizer::new(
        NativeMediaPacketizerConfig {
            kind: NativeMediaKind::VideoDelta,
            maximum_datagram_payload: MAXIMUM_DATAGRAM_PAYLOAD,
            generation_id: VIDEO_GENERATION_ID,
        },
        0,
    )?;
    let mut wire_datagrams = Vec::new();
    let mut audio_datagrams = 0;
    let mut video_datagrams = 0;
    let mut audio_index = 0_usize;
    let mut video_index = 0_u32;
    while audio_index < audio_packets.len() || video_index < VIDEO_FRAME_COUNT {
        let audio_is_next = if audio_index >= audio_packets.len() {
            false
        } else if video_index >= VIDEO_FRAME_COUNT {
            true
        } else {
            u64::from(audio_packets[audio_index].presentation_time_48khz).saturating_mul(90_000_u64)
                <= u64::from(video_index)
                    .saturating_mul(VIDEO_FRAME_DURATION_90KHZ)
                    .saturating_mul(48_000)
        };
        if audio_is_next {
            let packet = &audio_packets[audio_index];
            let packetized = audio_packetizer.packetize_audio(
                &PlatformEncodedAudioPacket {
                    payload: packet.payload.clone(),
                    presentation_time_48khz: packet.presentation_time_48khz,
                    duration_frames: packet.duration_frames,
                },
                packet.object_id,
            )?;
            audio_datagrams += packetized.datagrams.len();
            append_packetized(&mut wire_datagrams, packetized);
            audio_index += 1;
        } else {
            let frame_id = video_index
                .checked_add(2)
                .ok_or_else(|| "video frame id overflowed".to_owned())?;
            let presentation_time_90khz =
                u32::try_from(u64::from(video_index).saturating_mul(VIDEO_FRAME_DURATION_90KHZ))
                    .map_err(|_| "video presentation timestamp overflowed".to_owned())?;
            let mut payload = vec![0_u8; VIDEO_PAYLOAD_BYTES];
            for (offset, byte) in payload.iter_mut().enumerate() {
                *byte = (u64::from(frame_id)
                    .wrapping_mul(31)
                    .wrapping_add(offset as u64 * 17)
                    & 0xff) as u8;
            }
            let packetized = video_packetizer.packetize_video_delta(
                &PlatformEncodedVideoFrame {
                    payload,
                    decoder_configuration_record: None,
                    presentation_time_90khz: u64::from(presentation_time_90khz),
                    key_frame: false,
                    requires_bootstrap_acknowledgement: false,
                    repair_keyframe: false,
                },
                frame_id,
                0,
            )?;
            video_datagrams += packetized.datagrams.len();
            append_packetized(&mut wire_datagrams, packetized);
            video_index += 1;
        }
    }
    write_datagrams(Path::new(&output), &wire_datagrams)?;
    let report = PacketizerReport {
        schema_version: 1,
        maximum_datagram_payload: MAXIMUM_DATAGRAM_PAYLOAD,
        audio_objects: audio_packets.len(),
        video_objects: VIDEO_FRAME_COUNT,
        audio_datagrams,
        video_datagrams,
        total_datagrams: wire_datagrams.len(),
        video_payload_bytes_per_frame: VIDEO_PAYLOAD_BYTES,
    };
    println!(
        "{}",
        serde_json::to_string(&report)
            .map_err(|error| format!("packetizer report serialization failed: {error}"))?
    );
    Ok(())
}

fn append_packetized(destination: &mut Vec<Vec<u8>>, packetized: NativePacketizedUnit) {
    destination.extend(packetized.datagrams);
}

fn read_audio_packets(path: &Path) -> Result<Vec<AudioPacket>, String> {
    let bytes = fs::read(path).map_err(|error| format!("audio fixture read failed: {error}"))?;
    let mut cursor = FixtureCursor::new(&bytes);
    if cursor.read_bytes(4)? != b"LAF1" {
        return Err("audio fixture magic is invalid".to_owned());
    }
    let sample_rate = cursor.read_u32()?;
    let channel_count = cursor.read_u16()?;
    let frames_per_packet = cursor.read_u16()?;
    let packet_count = cursor.read_u32()?;
    if sample_rate != 48_000 || channel_count != 2 || frames_per_packet != 240 {
        return Err("audio fixture contract is invalid".to_owned());
    }
    let mut packets = Vec::with_capacity(packet_count as usize);
    for _ in 0..packet_count {
        let object_id = cursor.read_u32()?;
        let presentation_time_48khz = u32::try_from(cursor.read_u64()?)
            .map_err(|_| "audio presentation timestamp overflowed".to_owned())?;
        let duration_frames = cursor.read_u32()?;
        let payload_bytes = cursor.read_u32()? as usize;
        if payload_bytes == 0 || payload_bytes > 1_400 {
            return Err("audio fixture packet length is invalid".to_owned());
        }
        packets.push(AudioPacket {
            object_id,
            presentation_time_48khz,
            duration_frames,
            payload: cursor.read_bytes(payload_bytes)?.to_vec(),
        });
    }
    if !cursor.is_at_end() {
        return Err("audio fixture has trailing bytes".to_owned());
    }
    Ok(packets)
}

fn write_datagrams(path: &Path, datagrams: &[Vec<u8>]) -> Result<(), String> {
    let mut bytes = Vec::with_capacity(
        8 + datagrams
            .iter()
            .map(|datagram| datagram.len() + 4)
            .sum::<usize>(),
    );
    bytes.extend_from_slice(b"LAD1");
    bytes.extend_from_slice(
        &u32::try_from(datagrams.len())
            .map_err(|_| "datagram count overflowed".to_owned())?
            .to_le_bytes(),
    );
    for datagram in datagrams {
        bytes.extend_from_slice(
            &u32::try_from(datagram.len())
                .map_err(|_| "datagram length overflowed".to_owned())?
                .to_le_bytes(),
        );
        bytes.extend_from_slice(datagram);
    }
    fs::write(path, bytes).map_err(|error| format!("packetized fixture write failed: {error}"))
}

struct FixtureCursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> FixtureCursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn read_bytes(&mut self, count: usize) -> Result<&'a [u8], String> {
        let end = self
            .offset
            .checked_add(count)
            .filter(|end| *end <= self.bytes.len())
            .ok_or_else(|| "audio fixture is truncated".to_owned())?;
        let result = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(result)
    }

    fn read_u16(&mut self) -> Result<u16, String> {
        let bytes: [u8; 2] = self
            .read_bytes(2)?
            .try_into()
            .map_err(|_| "audio fixture u16 is truncated".to_owned())?;
        Ok(u16::from_le_bytes(bytes))
    }

    fn read_u32(&mut self) -> Result<u32, String> {
        let bytes: [u8; 4] = self
            .read_bytes(4)?
            .try_into()
            .map_err(|_| "audio fixture u32 is truncated".to_owned())?;
        Ok(u32::from_le_bytes(bytes))
    }

    fn read_u64(&mut self) -> Result<u64, String> {
        let bytes: [u8; 8] = self
            .read_bytes(8)?
            .try_into()
            .map_err(|_| "audio fixture u64 is truncated".to_owned())?;
        Ok(u64::from_le_bytes(bytes))
    }

    fn is_at_end(&self) -> bool {
        self.offset == self.bytes.len()
    }
}
