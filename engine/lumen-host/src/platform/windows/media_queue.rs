use std::collections::VecDeque;

use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};

const VIDEO_PACKET_CAPACITY: usize = 8;
const DEFAULT_AUDIO_PACKET_CAPACITY: usize = 8;
const OPUS_PACKET_DURATION_FRAMES: u32 = 240;

pub(super) struct WindowsMediaPacketQueues {
    video: VecDeque<PlatformEncodedVideoFrame>,
    audio: VecDeque<PlatformEncodedAudioPacket>,
    audio_capacity: usize,
    awaiting_key_frame: bool,
    next_audio_timestamp: u32,
}

impl Default for WindowsMediaPacketQueues {
    fn default() -> Self {
        Self {
            video: VecDeque::new(),
            audio: VecDeque::new(),
            audio_capacity: DEFAULT_AUDIO_PACKET_CAPACITY,
            awaiting_key_frame: false,
            next_audio_timestamp: 0,
        }
    }
}

impl WindowsMediaPacketQueues {
    pub(super) fn push_video(&mut self, frame: PlatformEncodedVideoFrame) -> bool {
        if self.awaiting_key_frame && !frame.key_frame {
            return false;
        }
        if self.video.len() == VIDEO_PACKET_CAPACITY {
            self.video.clear();
            if !frame.key_frame {
                self.awaiting_key_frame = true;
                return true;
            }
        }
        self.awaiting_key_frame = false;
        self.video.push_back(frame);
        false
    }

    pub(super) fn push_audio(&mut self, payload: Vec<u8>) {
        if self.audio.len() == self.audio_capacity {
            self.audio.pop_front();
        }
        let timestamp = self.next_audio_timestamp;
        self.next_audio_timestamp = timestamp.wrapping_add(OPUS_PACKET_DURATION_FRAMES);
        self.audio.push_back(PlatformEncodedAudioPacket {
            payload,
            presentation_time_48khz: timestamp,
            duration_frames: OPUS_PACKET_DURATION_FRAMES,
        });
    }

    pub(super) fn configure_audio_capacity(&mut self, capacity: usize) {
        self.audio.clear();
        self.audio_capacity = capacity.max(1);
        self.next_audio_timestamp = 0;
    }

    pub(super) fn pop_video(&mut self) -> Option<PlatformEncodedVideoFrame> {
        self.video.pop_front()
    }

    pub(super) fn pop_audio(&mut self) -> Option<PlatformEncodedAudioPacket> {
        self.audio.pop_front()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_overflow_requests_one_key_frame_and_reopens_on_idr() {
        let mut queues = WindowsMediaPacketQueues::default();
        for index in 0..VIDEO_PACKET_CAPACITY {
            assert!(!queues.push_video(frame(index as u8, index == 0)));
        }
        assert!(queues.push_video(frame(9, false)));
        assert!(!queues.push_video(frame(10, false)));
        assert!(queues.pop_video().is_none());
        assert!(!queues.push_video(frame(11, true)));
        assert_eq!(queues.pop_video().unwrap().payload, vec![11]);
    }

    #[test]
    fn audio_queue_is_bounded_and_preserves_monotonic_packet_timestamps() {
        let mut queues = WindowsMediaPacketQueues::default();
        queues.configure_audio_capacity(4);
        for index in 0..=4 {
            queues.push_audio(vec![index as u8]);
        }
        let first = queues.pop_audio().unwrap();
        assert_eq!(first.payload, vec![1]);
        assert_eq!(first.presentation_time_48khz, OPUS_PACKET_DURATION_FRAMES);
        let mut last = first;
        while let Some(packet) = queues.pop_audio() {
            assert_eq!(
                packet.presentation_time_48khz,
                last.presentation_time_48khz + OPUS_PACKET_DURATION_FRAMES
            );
            last = packet;
        }
        assert_eq!(last.payload, vec![4]);
    }

    fn frame(value: u8, key_frame: bool) -> PlatformEncodedVideoFrame {
        PlatformEncodedVideoFrame {
            payload: vec![value],
            decoder_configuration_record: None,
            presentation_time_90khz: u32::from(value),
            key_frame,
            requires_bootstrap_acknowledgement: false,
            repair_keyframe: false,
        }
    }
}
