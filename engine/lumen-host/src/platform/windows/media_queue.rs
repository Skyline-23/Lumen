use std::collections::VecDeque;

use crate::{PlatformEncodedAudioPacket, PlatformEncodedVideoFrame};

const VIDEO_PACKET_CAPACITY: usize = 8;
const DEFAULT_AUDIO_PACKET_CAPACITY: usize = 8;
const OPUS_PACKET_DURATION_FRAMES: u32 = 240;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct VideoQueuePushResult {
    pub(super) request_key_frame: bool,
    pub(super) dropped_frames: u64,
}

pub(super) struct WindowsMediaPacketQueues {
    video: VecDeque<PlatformEncodedVideoFrame>,
    audio: VecDeque<PlatformEncodedAudioPacket>,
    audio_capacity: usize,
    awaiting_key_frame: bool,
    awaiting_bootstrap_acknowledgement: bool,
    next_audio_timestamp: u32,
}

impl Default for WindowsMediaPacketQueues {
    fn default() -> Self {
        Self {
            video: VecDeque::new(),
            audio: VecDeque::new(),
            audio_capacity: DEFAULT_AUDIO_PACKET_CAPACITY,
            awaiting_key_frame: false,
            awaiting_bootstrap_acknowledgement: false,
            next_audio_timestamp: 0,
        }
    }
}

impl WindowsMediaPacketQueues {
    /// Starts a new platform media epoch without changing the negotiated audio
    /// queue capacity. Any encoded media admitted before this boundary is
    /// discarded, and video remains fenced until the next key frame arrives.
    pub(super) fn reset_media_epoch(&mut self) {
        self.video.clear();
        self.audio.clear();
        self.awaiting_key_frame = true;
        self.awaiting_bootstrap_acknowledgement = true;
        self.next_audio_timestamp = 0;
    }

    #[cfg(test)]
    pub(super) fn push_video(&mut self, frame: PlatformEncodedVideoFrame) -> bool {
        self.push_video_with_result(frame).request_key_frame
    }

    pub(super) fn push_video_with_result(
        &mut self,
        frame: PlatformEncodedVideoFrame,
    ) -> VideoQueuePushResult {
        if self.awaiting_key_frame
            && (!frame.key_frame
                || self.awaiting_bootstrap_acknowledgement
                    && !frame.requires_bootstrap_acknowledgement)
        {
            return VideoQueuePushResult {
                request_key_frame: false,
                dropped_frames: 1,
            };
        }
        let mut dropped_frames = 0;
        if self.video.len() == VIDEO_PACKET_CAPACITY {
            dropped_frames = self.video.len() as u64;
            self.video.clear();
            if !frame.key_frame {
                self.awaiting_key_frame = true;
                self.awaiting_bootstrap_acknowledgement = false;
                return VideoQueuePushResult {
                    request_key_frame: true,
                    dropped_frames: dropped_frames + 1,
                };
            }
        }
        self.awaiting_key_frame = false;
        self.awaiting_bootstrap_acknowledgement = false;
        self.video.push_back(frame);
        VideoQueuePushResult {
            request_key_frame: false,
            dropped_frames,
        }
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
    fn video_overflow_reports_only_pending_queue_drops() {
        let mut queues = WindowsMediaPacketQueues::default();
        for index in 0..VIDEO_PACKET_CAPACITY {
            assert_eq!(
                queues.push_video_with_result(frame(index as u8, index == 0)),
                VideoQueuePushResult::default()
            );
        }

        let overflow = queues.push_video_with_result(frame(9, false));
        assert_eq!(overflow.dropped_frames, VIDEO_PACKET_CAPACITY as u64 + 1);
        assert!(overflow.request_key_frame);

        let stale_delta = queues.push_video_with_result(frame(10, false));
        assert_eq!(stale_delta.dropped_frames, 1);
        assert!(!stale_delta.request_key_frame);

        let repair = queues.push_video_with_result(frame(11, true));
        assert_eq!(repair.dropped_frames, 0);
        assert!(!repair.request_key_frame);
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

    #[test]
    fn media_epoch_reset_discards_queued_media_and_requires_a_fresh_key_frame() {
        let mut queues = WindowsMediaPacketQueues::default();
        queues.configure_audio_capacity(4);
        queues.push_video(frame(1, true));
        queues.push_audio(vec![1]);

        queues.reset_media_epoch();

        assert!(queues.pop_video().is_none());
        assert!(queues.pop_audio().is_none());
        assert_eq!(
            queues.push_video_with_result(frame(2, false)),
            VideoQueuePushResult {
                request_key_frame: false,
                dropped_frames: 1,
            }
        );
        assert!(queues.pop_video().is_none());
        assert_eq!(
            queues.push_video_with_result(frame(3, true)),
            VideoQueuePushResult {
                request_key_frame: false,
                dropped_frames: 1,
            }
        );
        assert!(queues.pop_video().is_none());
        assert_eq!(
            queues.push_video_with_result(frame_with_bootstrap_ack(4)),
            VideoQueuePushResult::default()
        );
        assert_eq!(queues.pop_video().unwrap().payload, vec![4]);
    }

    #[test]
    fn media_epoch_reset_preserves_negotiated_audio_capacity() {
        let mut queues = WindowsMediaPacketQueues::default();
        queues.configure_audio_capacity(2);
        queues.push_audio(vec![1]);
        queues.push_audio(vec![2]);
        queues.reset_media_epoch();

        queues.push_audio(vec![3]);
        queues.push_audio(vec![4]);
        queues.push_audio(vec![5]);
        assert_eq!(queues.pop_audio().unwrap().payload, vec![4]);
        assert_eq!(queues.pop_audio().unwrap().payload, vec![5]);
        assert!(queues.pop_audio().is_none());
    }

    fn frame(value: u8, key_frame: bool) -> PlatformEncodedVideoFrame {
        frame_with_metadata(value, key_frame, false)
    }

    fn frame_with_bootstrap_ack(value: u8) -> PlatformEncodedVideoFrame {
        frame_with_metadata(value, true, true)
    }

    fn frame_with_metadata(
        value: u8,
        key_frame: bool,
        requires_bootstrap_acknowledgement: bool,
    ) -> PlatformEncodedVideoFrame {
        PlatformEncodedVideoFrame {
            payload: vec![value],
            decoder_configuration_record: None,
            presentation_time_90khz: u64::from(value),
            key_frame,
            requires_bootstrap_acknowledgement,
            repair_keyframe: false,
        }
    }
}
