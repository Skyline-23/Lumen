use super::{
    LumenExternalIngressPacketAdmission, LumenExternalIngressPacketAllocation,
    LumenExternalIngressPacketDecision, EXTERNAL_INGRESS_PACKET_ACCEPT,
    EXTERNAL_INGRESS_PACKET_DROP_CODEC_MISMATCH, EXTERNAL_INGRESS_PACKET_DROP_UNSUPPORTED_CODEC,
    EXTERNAL_INGRESS_PACKET_DROP_WAITING_FOR_IDR,
};

const VIDEO_FORMAT_H264: i32 = 0;
const VIDEO_FORMAT_HEVC: i32 = 1;

#[derive(Debug)]
pub(super) struct PacketState {
    adopted_video_format: Option<i32>,
    has_packetized_packet: bool,
    next_frame_index: i64,
    waiting_for_initial_idr: bool,
    logged_codec_mismatch: bool,
    logged_waiting_for_initial_idr: bool,
}

impl Default for PacketState {
    fn default() -> Self {
        Self {
            adopted_video_format: None,
            has_packetized_packet: false,
            next_frame_index: 1,
            waiting_for_initial_idr: true,
            logged_codec_mismatch: false,
            logged_waiting_for_initial_idr: false,
        }
    }
}

impl PacketState {
    fn video_format(frame_codec: i32) -> Option<i32> {
        match frame_codec {
            VIDEO_FORMAT_H264 => Some(VIDEO_FORMAT_H264),
            VIDEO_FORMAT_HEVC => Some(VIDEO_FORMAT_HEVC),
            _ => None,
        }
    }

    pub(super) fn admit(
        &mut self,
        packet: LumenExternalIngressPacketAdmission,
    ) -> LumenExternalIngressPacketDecision {
        let Some(frame_video_format) = Self::video_format(packet.frame_codec) else {
            return LumenExternalIngressPacketDecision {
                action: EXTERNAL_INGRESS_PACKET_DROP_UNSUPPORTED_CODEC,
                effective_video_format: packet.requested_video_format,
                ..Default::default()
            };
        };

        let expected_video_format = self
            .adopted_video_format
            .unwrap_or(packet.requested_video_format);
        let mut decision = LumenExternalIngressPacketDecision {
            action: EXTERNAL_INGRESS_PACKET_ACCEPT,
            effective_video_format: expected_video_format,
            ..Default::default()
        };
        if frame_video_format != expected_video_format {
            if self.has_packetized_packet {
                decision.action = EXTERNAL_INGRESS_PACKET_DROP_CODEC_MISMATCH;
                decision.should_log_codec_mismatch = !self.logged_codec_mismatch;
                self.logged_codec_mismatch = true;
                return decision;
            }
            self.adopted_video_format = Some(frame_video_format);
            decision.effective_video_format = frame_video_format;
            decision.codec_adopted = true;
        }

        if self.waiting_for_initial_idr && !packet.is_idr {
            decision.action = EXTERNAL_INGRESS_PACKET_DROP_WAITING_FOR_IDR;
            decision.should_log_waiting_for_idr = !self.logged_waiting_for_initial_idr;
            self.logged_waiting_for_initial_idr = true;
            return decision;
        }

        self.waiting_for_initial_idr = false;
        decision
    }

    pub(super) fn allocate(&mut self) -> LumenExternalIngressPacketAllocation {
        let allocation = LumenExternalIngressPacketAllocation {
            frame_index: self.next_frame_index,
            is_first_packet: !self.has_packetized_packet,
        };
        self.next_frame_index = self.next_frame_index.saturating_add(1);
        self.has_packetized_packet = true;
        allocation
    }

    pub(super) fn reset_session(&mut self) {
        let next_frame_index = self.next_frame_index;
        *self = Self::default();
        self.next_frame_index = next_frame_index;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adopts_before_first_packet_then_locks_codec() {
        let mut state = PacketState::default();
        let adopted = state.admit(LumenExternalIngressPacketAdmission {
            frame_codec: VIDEO_FORMAT_H264,
            requested_video_format: VIDEO_FORMAT_HEVC,
            is_idr: true,
        });
        assert_eq!(adopted.action, EXTERNAL_INGRESS_PACKET_ACCEPT);
        assert_eq!(adopted.effective_video_format, VIDEO_FORMAT_H264);
        assert!(adopted.codec_adopted);

        state.allocate();
        let mismatch = state.admit(LumenExternalIngressPacketAdmission {
            frame_codec: VIDEO_FORMAT_HEVC,
            requested_video_format: VIDEO_FORMAT_HEVC,
            is_idr: true,
        });
        assert_eq!(mismatch.action, EXTERNAL_INGRESS_PACKET_DROP_CODEC_MISMATCH);
        assert!(mismatch.should_log_codec_mismatch);
        assert!(
            !state
                .admit(LumenExternalIngressPacketAdmission {
                    frame_codec: VIDEO_FORMAT_HEVC,
                    requested_video_format: VIDEO_FORMAT_HEVC,
                    is_idr: true,
                })
                .should_log_codec_mismatch
        );
    }

    #[test]
    fn waits_for_idr_and_resets_the_one_shot_report() {
        let mut state = PacketState::default();
        let inter = LumenExternalIngressPacketAdmission {
            frame_codec: VIDEO_FORMAT_HEVC,
            requested_video_format: VIDEO_FORMAT_HEVC,
            is_idr: false,
        };
        let first = state.admit(inter);
        assert_eq!(first.action, EXTERNAL_INGRESS_PACKET_DROP_WAITING_FOR_IDR);
        assert!(first.should_log_waiting_for_idr);
        assert!(!state.admit(inter).should_log_waiting_for_idr);

        let idr = state.admit(LumenExternalIngressPacketAdmission {
            is_idr: true,
            ..inter
        });
        assert_eq!(idr.action, EXTERNAL_INGRESS_PACKET_ACCEPT);
        assert_eq!(state.admit(inter).action, EXTERNAL_INGRESS_PACKET_ACCEPT);

        state.reset_session();
        assert!(state.admit(inter).should_log_waiting_for_idr);
    }

    #[test]
    fn allocation_preserves_indices_and_reopens_first_packet_after_reset() {
        let mut state = PacketState::default();
        assert_eq!(
            state.allocate(),
            LumenExternalIngressPacketAllocation {
                frame_index: 1,
                is_first_packet: true,
            }
        );
        assert_eq!(state.allocate().frame_index, 2);
        assert!(!state.allocate().is_first_packet);

        state.reset_session();
        assert_eq!(
            state.allocate(),
            LumenExternalIngressPacketAllocation {
                frame_index: 4,
                is_first_packet: true,
            }
        );
    }
}
