#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FeedbackStream {
    Audio,
    Video,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CongestionSource {
    None,
    Audio,
    Video,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct MediaFeedbackSample {
    pub(crate) stream: FeedbackStream,
    pub(crate) expected_datagrams: u32,
    pub(crate) received_datagrams: u32,
    pub(crate) unrecoverable_objects: u32,
    pub(crate) late_objects: u32,
    pub(crate) estimated_jitter_us: u32,
    pub(crate) decoder_queue_depth: u32,
    pub(crate) presentation_drops: u32,
    pub(crate) decoder_submissions: u32,
    pub(crate) decoded_frames: u32,
    pub(crate) presented_frames: u32,
    pub(crate) decoder_drops: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct AdaptiveVideoDecision {
    pub(crate) wire_budget_kbps: u32,
    pub(crate) encoder_bitrate_kbps: u32,
    pub(crate) fec_percentage: u16,
    pub(crate) congestion_source: CongestionSource,
    pub(crate) changed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CongestionSeverity {
    Clean,
    Transport,
    Severe,
}

#[derive(Clone, Debug)]
pub(crate) struct AdaptiveVideoDeliveryController {
    ceiling_wire_kbps: u32,
    floor_wire_kbps: u32,
    wire_budget_kbps: u32,
    fec_percentage: u16,
    maximum_decoder_queue_depth: u32,
    clean_video_windows: u8,
}

impl AdaptiveVideoDeliveryController {
    const MINIMUM_FEC_PERCENTAGE: u16 = 5;
    const MAXIMUM_FEC_PERCENTAGE: u16 = 30;
    const CLEAN_WINDOWS_BEFORE_INCREASE: u8 = 8;
    const TRANSPORT_LOSS_PARTS_PER_MILLION: u64 = 20_000;
    const HIGH_JITTER_MICROSECONDS: u32 = 10_000;

    pub(crate) fn new(
        ceiling_wire_kbps: u32,
        initial_wire_kbps: u32,
        initial_fec_percentage: u16,
        maximum_decoder_queue_depth: u32,
    ) -> Self {
        let ceiling_wire_kbps = ceiling_wire_kbps.max(1);
        let floor_wire_kbps = ceiling_wire_kbps.div_ceil(4);
        Self {
            ceiling_wire_kbps,
            floor_wire_kbps,
            wire_budget_kbps: initial_wire_kbps.clamp(floor_wire_kbps, ceiling_wire_kbps),
            fec_percentage: initial_fec_percentage
                .clamp(Self::MINIMUM_FEC_PERCENTAGE, Self::MAXIMUM_FEC_PERCENTAGE),
            maximum_decoder_queue_depth: maximum_decoder_queue_depth.max(1),
            clean_video_windows: 0,
        }
    }

    pub(crate) fn observe(&mut self, sample: MediaFeedbackSample) -> AdaptiveVideoDecision {
        let previous_wire_budget = self.wire_budget_kbps;
        let previous_fec = self.fec_percentage;
        let severity = self.classify(sample);
        let source = match severity {
            CongestionSeverity::Clean => CongestionSource::None,
            CongestionSeverity::Transport | CongestionSeverity::Severe => match sample.stream {
                FeedbackStream::Audio => CongestionSource::Audio,
                FeedbackStream::Video => CongestionSource::Video,
            },
        };

        match severity {
            CongestionSeverity::Severe => {
                self.clean_video_windows = 0;
                self.wire_budget_kbps = self
                    .wire_budget_kbps
                    .saturating_mul(80)
                    .div_ceil(100)
                    .max(self.floor_wire_kbps);
                self.increase_fec_for_loss(sample);
            }
            CongestionSeverity::Transport => {
                self.clean_video_windows = 0;
                self.wire_budget_kbps = self
                    .wire_budget_kbps
                    .saturating_mul(90)
                    .div_ceil(100)
                    .max(self.floor_wire_kbps);
                self.increase_fec_for_loss(sample);
            }
            CongestionSeverity::Clean if sample.stream == FeedbackStream::Video => {
                self.clean_video_windows = self.clean_video_windows.saturating_add(1);
                if self.clean_video_windows >= Self::CLEAN_WINDOWS_BEFORE_INCREASE {
                    self.clean_video_windows = 0;
                    let increase = self.ceiling_wire_kbps.div_ceil(20).max(1);
                    self.wire_budget_kbps = self
                        .wire_budget_kbps
                        .saturating_add(increase)
                        .min(self.ceiling_wire_kbps);
                    self.fec_percentage = self
                        .fec_percentage
                        .saturating_sub(5)
                        .max(Self::MINIMUM_FEC_PERCENTAGE);
                }
            }
            CongestionSeverity::Clean => {}
        }

        self.decision(
            source,
            self.wire_budget_kbps != previous_wire_budget || self.fec_percentage != previous_fec,
        )
    }

    pub(crate) fn snapshot(&self) -> AdaptiveVideoDecision {
        self.decision(CongestionSource::None, false)
    }

    fn classify(&self, sample: MediaFeedbackSample) -> CongestionSeverity {
        if sample.unrecoverable_objects > 0
            || sample.late_objects > 0
            || sample.presentation_drops > 0
            || sample.decoder_drops > 0
            || sample.decoder_queue_depth > self.maximum_decoder_queue_depth
        {
            return CongestionSeverity::Severe;
        }
        if Self::loss_parts_per_million(sample) >= Self::TRANSPORT_LOSS_PARTS_PER_MILLION
            || sample.estimated_jitter_us >= Self::HIGH_JITTER_MICROSECONDS
        {
            return CongestionSeverity::Transport;
        }
        CongestionSeverity::Clean
    }

    fn increase_fec_for_loss(&mut self, sample: MediaFeedbackSample) {
        if Self::loss_parts_per_million(sample) >= Self::TRANSPORT_LOSS_PARTS_PER_MILLION {
            self.fec_percentage = self
                .fec_percentage
                .saturating_add(5)
                .min(Self::MAXIMUM_FEC_PERCENTAGE);
        }
    }

    fn loss_parts_per_million(sample: MediaFeedbackSample) -> u64 {
        if sample.expected_datagrams == 0 {
            return 0;
        }
        let lost = sample
            .expected_datagrams
            .saturating_sub(sample.received_datagrams);
        u64::from(lost).saturating_mul(1_000_000) / u64::from(sample.expected_datagrams)
    }

    fn decision(
        &self,
        congestion_source: CongestionSource,
        changed: bool,
    ) -> AdaptiveVideoDecision {
        AdaptiveVideoDecision {
            wire_budget_kbps: self.wire_budget_kbps,
            encoder_bitrate_kbps: self.wire_budget_kbps.saturating_mul(100)
                / u32::from(100 + self.fec_percentage),
            fec_percentage: self.fec_percentage,
            congestion_source,
            changed,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clean(stream: FeedbackStream) -> MediaFeedbackSample {
        MediaFeedbackSample {
            stream,
            expected_datagrams: 100,
            received_datagrams: 100,
            unrecoverable_objects: 0,
            late_objects: 0,
            estimated_jitter_us: 500,
            decoder_queue_depth: 0,
            presentation_drops: 0,
            decoder_submissions: 100,
            decoded_frames: 100,
            presented_frames: 100,
            decoder_drops: 0,
        }
    }

    #[test]
    fn severe_audio_pressure_reduces_the_global_video_wire_budget_by_twenty_percent() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let decision = controller.observe(MediaFeedbackSample {
            presentation_drops: 1,
            ..clean(FeedbackStream::Audio)
        });

        assert_eq!(decision.wire_budget_kbps, 64_000);
        assert_eq!(decision.encoder_bitrate_kbps, 60_952);
        assert_eq!(decision.fec_percentage, 5);
        assert_eq!(decision.congestion_source, CongestionSource::Audio);
        assert!(decision.changed);
    }

    #[test]
    fn decoder_drop_reduces_budget_without_misclassifying_it_as_transport_loss() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let decision = controller.observe(MediaFeedbackSample {
            decoder_submissions: 100,
            decoded_frames: 99,
            presented_frames: 99,
            decoder_drops: 1,
            ..clean(FeedbackStream::Video)
        });

        assert_eq!(decision.wire_budget_kbps, 64_000);
        assert_eq!(decision.fec_percentage, 5);
        assert_eq!(decision.congestion_source, CongestionSource::Video);
        assert!(decision.changed);
    }

    #[test]
    fn datagram_loss_reduces_wire_budget_without_mixing_object_units() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let decision = controller.observe(MediaFeedbackSample {
            received_datagrams: 95,
            ..clean(FeedbackStream::Video)
        });

        assert_eq!(decision.wire_budget_kbps, 72_000);
        assert_eq!(decision.encoder_bitrate_kbps, 65_454);
        assert_eq!(decision.fec_percentage, 10);
        assert_eq!(decision.congestion_source, CongestionSource::Video);
        assert!(decision.changed);
    }

    #[test]
    fn eight_clean_video_windows_add_five_percent_of_the_ceiling() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let mut decision = controller.snapshot();

        for _ in 0..8 {
            decision = controller.observe(clean(FeedbackStream::Video));
        }

        assert_eq!(decision.wire_budget_kbps, 85_000);
        assert_eq!(decision.encoder_bitrate_kbps, 80_952);
        assert_eq!(decision.fec_percentage, 5);
        assert_eq!(decision.congestion_source, CongestionSource::None);
        assert!(decision.changed);
    }

    #[test]
    fn budget_and_fec_remain_inside_negotiated_bounds() {
        let mut controller = AdaptiveVideoDeliveryController::new(80_000, 20_000, 30, 3);

        for _ in 0..20 {
            _ = controller.observe(MediaFeedbackSample {
                expected_datagrams: 100,
                received_datagrams: 0,
                presentation_drops: 1,
                ..clean(FeedbackStream::Audio)
            });
        }
        let floor = controller.snapshot();
        assert_eq!(floor.wire_budget_kbps, 20_000);
        assert_eq!(floor.fec_percentage, 30);

        for _ in 0..200 {
            _ = controller.observe(clean(FeedbackStream::Video));
        }
        let ceiling = controller.snapshot();
        assert_eq!(ceiling.wire_budget_kbps, 80_000);
        assert_eq!(ceiling.fec_percentage, 5);
    }
}
