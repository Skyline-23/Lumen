#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FeedbackStream {
    Audio,
    Video,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CongestionSource {
    None,
    AudioNetwork,
    VideoNetwork,
    AudioPipeline,
    VideoPipeline,
    VideoPresentation,
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

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum NetworkCongestionSeverity {
    Neutral,
    Clean,
    Transport,
    Severe,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum PipelinePressureSeverity {
    Neutral,
    Clean,
    Presentation,
    Congested,
}

#[derive(Clone, Debug)]
pub(crate) struct AdaptiveVideoDeliveryController {
    // Packet-path evidence owns the wire budget and FEC state.
    ceiling_wire_kbps: u32,
    floor_wire_kbps: u32,
    wire_budget_kbps: u32,
    // Decode/playback pressure may cap encoder work, but never rewrites B_net.
    ceiling_encoder_kbps: u32,
    floor_encoder_kbps: u32,
    pipeline_encoder_budget_kbps: u32,
    fec_percentage: u16,
    maximum_decoder_queue_depth: u32,
    clean_network_windows: u32,
    clean_pipeline_windows: u32,
    pipeline_pressure_armed: bool,
}

impl AdaptiveVideoDeliveryController {
    const MINIMUM_FEC_PERCENTAGE: u16 = 5;
    const MAXIMUM_FEC_PERCENTAGE: u16 = 30;
    const CLEAN_WINDOWS_BEFORE_INCREASE: u32 = 8;
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
        let initial_fec_percentage = initial_fec_percentage
            .clamp(Self::MINIMUM_FEC_PERCENTAGE, Self::MAXIMUM_FEC_PERCENTAGE);
        let wire_budget_kbps = initial_wire_kbps.clamp(floor_wire_kbps, ceiling_wire_kbps);
        let ceiling_encoder_kbps =
            ceiling_wire_kbps.saturating_mul(100) / u32::from(100 + Self::MINIMUM_FEC_PERCENTAGE);
        let floor_encoder_kbps = ceiling_encoder_kbps.div_ceil(4).max(1);
        let pipeline_encoder_budget_kbps =
            wire_budget_kbps.saturating_mul(100) / u32::from(100 + initial_fec_percentage);
        Self {
            ceiling_wire_kbps,
            floor_wire_kbps,
            wire_budget_kbps,
            ceiling_encoder_kbps,
            floor_encoder_kbps,
            pipeline_encoder_budget_kbps,
            fec_percentage: initial_fec_percentage,
            maximum_decoder_queue_depth: maximum_decoder_queue_depth.max(1),
            clean_network_windows: 0,
            clean_pipeline_windows: 0,
            pipeline_pressure_armed: true,
        }
    }

    #[cfg(test)]
    pub(crate) fn observe(&mut self, sample: MediaFeedbackSample) -> AdaptiveVideoDecision {
        let network_severity = self.classify_network(sample);
        let network_source = match network_severity {
            NetworkCongestionSeverity::Neutral | NetworkCongestionSeverity::Clean => {
                CongestionSource::None
            }
            NetworkCongestionSeverity::Transport | NetworkCongestionSeverity::Severe => {
                match sample.stream {
                    FeedbackStream::Audio => CongestionSource::AudioNetwork,
                    FeedbackStream::Video => CongestionSource::VideoNetwork,
                }
            }
        };
        let pipeline_severity = self.classify_pipeline(sample);
        let pipeline_source = match pipeline_severity {
            PipelinePressureSeverity::Neutral | PipelinePressureSeverity::Clean => {
                CongestionSource::None
            }
            PipelinePressureSeverity::Presentation => CongestionSource::VideoPresentation,
            PipelinePressureSeverity::Congested => match sample.stream {
                FeedbackStream::Audio => CongestionSource::AudioPipeline,
                FeedbackStream::Video => CongestionSource::VideoPipeline,
            },
        };
        self.apply_observation(
            network_severity,
            network_source,
            pipeline_severity,
            pipeline_source,
            Some(sample),
            1,
        )
    }

    pub(crate) fn observe_window(
        &mut self,
        video: MediaFeedbackSample,
        audio: MediaFeedbackSample,
        clean_window_units: u32,
    ) -> AdaptiveVideoDecision {
        debug_assert_eq!(video.stream, FeedbackStream::Video);
        debug_assert_eq!(audio.stream, FeedbackStream::Audio);

        let video_network = self.classify_network(video);
        let audio_network = self.classify_network(audio);
        let (network_severity, network_stream) = if video_network >= audio_network {
            (video_network, FeedbackStream::Video)
        } else {
            (audio_network, FeedbackStream::Audio)
        };
        let network_severity = if network_severity == NetworkCongestionSeverity::Clean
            && video_network != NetworkCongestionSeverity::Clean
        {
            NetworkCongestionSeverity::Neutral
        } else {
            network_severity
        };
        let network_source = match network_severity {
            NetworkCongestionSeverity::Neutral | NetworkCongestionSeverity::Clean => {
                CongestionSource::None
            }
            NetworkCongestionSeverity::Transport | NetworkCongestionSeverity::Severe => {
                match network_stream {
                    FeedbackStream::Audio => CongestionSource::AudioNetwork,
                    FeedbackStream::Video => CongestionSource::VideoNetwork,
                }
            }
        };

        let video_pipeline = self.classify_pipeline(video);
        let audio_pipeline = self.classify_pipeline(audio);
        let (pipeline_severity, pipeline_stream) = if video_pipeline >= audio_pipeline {
            (video_pipeline, FeedbackStream::Video)
        } else {
            (audio_pipeline, FeedbackStream::Audio)
        };
        let pipeline_severity = if pipeline_severity == PipelinePressureSeverity::Clean
            && video_pipeline != PipelinePressureSeverity::Clean
        {
            PipelinePressureSeverity::Neutral
        } else {
            pipeline_severity
        };
        let pipeline_source = match pipeline_severity {
            PipelinePressureSeverity::Neutral | PipelinePressureSeverity::Clean => {
                CongestionSource::None
            }
            PipelinePressureSeverity::Presentation => CongestionSource::VideoPresentation,
            PipelinePressureSeverity::Congested => match pipeline_stream {
                FeedbackStream::Audio => CongestionSource::AudioPipeline,
                FeedbackStream::Video => CongestionSource::VideoPipeline,
            },
        };
        self.apply_observation(
            network_severity,
            network_source,
            pipeline_severity,
            pipeline_source,
            Some(video),
            clean_window_units.max(1),
        )
    }

    fn apply_observation(
        &mut self,
        network_severity: NetworkCongestionSeverity,
        network_source: CongestionSource,
        pipeline_severity: PipelinePressureSeverity,
        pipeline_source: CongestionSource,
        video_sample: Option<MediaFeedbackSample>,
        clean_window_units: u32,
    ) -> AdaptiveVideoDecision {
        let previous = self.snapshot();
        let previous_pipeline_budget = self.pipeline_encoder_budget_kbps;

        match network_severity {
            NetworkCongestionSeverity::Neutral => {}
            NetworkCongestionSeverity::Severe => {
                self.clean_network_windows = 0;
                self.wire_budget_kbps = self
                    .wire_budget_kbps
                    .saturating_mul(80)
                    .div_ceil(100)
                    .max(self.floor_wire_kbps);
                if let Some(video_sample) = video_sample {
                    self.increase_fec_for_video_loss(video_sample);
                }
            }
            NetworkCongestionSeverity::Transport => {
                self.clean_network_windows = 0;
                self.wire_budget_kbps = self
                    .wire_budget_kbps
                    .saturating_mul(90)
                    .div_ceil(100)
                    .max(self.floor_wire_kbps);
                if let Some(video_sample) = video_sample {
                    self.increase_fec_for_video_loss(video_sample);
                }
            }
            NetworkCongestionSeverity::Clean => {
                let accumulated = self
                    .clean_network_windows
                    .saturating_add(clean_window_units);
                self.clean_network_windows = accumulated % Self::CLEAN_WINDOWS_BEFORE_INCREASE;
                let mut recovery_probes = accumulated / Self::CLEAN_WINDOWS_BEFORE_INCREASE;
                while recovery_probes > 0
                    && (self.wire_budget_kbps < self.ceiling_wire_kbps
                        || self.fec_percentage > Self::MINIMUM_FEC_PERCENTAGE)
                {
                    let increase = self.wire_budget_kbps.div_ceil(5).max(250);
                    self.wire_budget_kbps = self
                        .wire_budget_kbps
                        .saturating_add(increase)
                        .min(self.ceiling_wire_kbps);
                    self.fec_percentage = self
                        .fec_percentage
                        .saturating_sub(5)
                        .max(Self::MINIMUM_FEC_PERCENTAGE);
                    recovery_probes -= 1;
                }
            }
        }

        match pipeline_severity {
            PipelinePressureSeverity::Neutral => {}
            PipelinePressureSeverity::Presentation => {
                self.clean_pipeline_windows = 0;
            }
            PipelinePressureSeverity::Congested => {
                self.clean_pipeline_windows = 0;
                if self.pipeline_pressure_armed {
                    self.pipeline_pressure_armed = false;
                    self.pipeline_encoder_budget_kbps = self
                        .pipeline_encoder_budget_kbps
                        .saturating_mul(80)
                        .div_ceil(100)
                        .max(self.floor_encoder_kbps);
                }
            }
            PipelinePressureSeverity::Clean => {
                let accumulated = self
                    .clean_pipeline_windows
                    .saturating_add(clean_window_units);
                self.clean_pipeline_windows = accumulated % Self::CLEAN_WINDOWS_BEFORE_INCREASE;
                let mut recovery_probes = accumulated / Self::CLEAN_WINDOWS_BEFORE_INCREASE;
                if recovery_probes > 0 {
                    self.pipeline_pressure_armed = true;
                }
                while recovery_probes > 0
                    && self.pipeline_encoder_budget_kbps < self.ceiling_encoder_kbps
                {
                    let increase = self.pipeline_encoder_budget_kbps.div_ceil(5).max(250);
                    self.pipeline_encoder_budget_kbps = self
                        .pipeline_encoder_budget_kbps
                        .saturating_add(increase)
                        .min(self.ceiling_encoder_kbps);
                    recovery_probes -= 1;
                }
            }
        }

        let current = self.decision(CongestionSource::None, false);
        let network_changed = current.wire_budget_kbps != previous.wire_budget_kbps
            || current.fec_percentage != previous.fec_percentage;
        let pipeline_changed = self.pipeline_encoder_budget_kbps != previous_pipeline_budget;
        let changed = current.wire_budget_kbps != previous.wire_budget_kbps
            || current.encoder_bitrate_kbps != previous.encoder_bitrate_kbps
            || current.fec_percentage != previous.fec_percentage;
        let source = if network_changed && network_source != CongestionSource::None {
            network_source
        } else if pipeline_changed && pipeline_source != CongestionSource::None {
            pipeline_source
        } else if !changed && pipeline_severity == PipelinePressureSeverity::Presentation {
            CongestionSource::VideoPresentation
        } else {
            CongestionSource::None
        };
        self.decision(source, changed)
    }

    pub(crate) fn snapshot(&self) -> AdaptiveVideoDecision {
        self.decision(CongestionSource::None, false)
    }

    fn classify_network(&self, sample: MediaFeedbackSample) -> NetworkCongestionSeverity {
        if sample.unrecoverable_objects > 0 || sample.late_objects > 0 {
            return NetworkCongestionSeverity::Severe;
        }
        if Self::loss_parts_per_million(sample) >= Self::TRANSPORT_LOSS_PARTS_PER_MILLION
            || sample.estimated_jitter_us >= Self::HIGH_JITTER_MICROSECONDS
        {
            return NetworkCongestionSeverity::Transport;
        }
        if sample.expected_datagrams == 0 && sample.received_datagrams == 0 {
            return NetworkCongestionSeverity::Neutral;
        }
        NetworkCongestionSeverity::Clean
    }

    fn classify_pipeline(&self, sample: MediaFeedbackSample) -> PipelinePressureSeverity {
        if sample.decoder_drops > 0 || sample.decoder_queue_depth > self.maximum_decoder_queue_depth
        {
            return PipelinePressureSeverity::Congested;
        }
        if sample.presentation_drops > 0 {
            return if sample.stream == FeedbackStream::Video {
                PipelinePressureSeverity::Presentation
            } else {
                PipelinePressureSeverity::Congested
            };
        }
        if sample.expected_datagrams == 0
            && sample.received_datagrams == 0
            && sample.decoder_submissions == 0
            && sample.decoded_frames == 0
            && sample.presented_frames == 0
        {
            return PipelinePressureSeverity::Neutral;
        }
        PipelinePressureSeverity::Clean
    }

    fn increase_fec_for_video_loss(&mut self, sample: MediaFeedbackSample) {
        if sample.stream == FeedbackStream::Video
            && Self::loss_parts_per_million(sample) >= Self::TRANSPORT_LOSS_PARTS_PER_MILLION
        {
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
            encoder_bitrate_kbps: (self.wire_budget_kbps.saturating_mul(100)
                / u32::from(100 + self.fec_percentage))
            .min(self.pipeline_encoder_budget_kbps),
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
    fn audio_playback_pressure_reduces_only_the_encoder_pipeline_cap() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let decision = controller.observe(MediaFeedbackSample {
            presentation_drops: 1,
            ..clean(FeedbackStream::Audio)
        });

        assert_eq!(decision.wire_budget_kbps, 80_000);
        assert_eq!(decision.encoder_bitrate_kbps, 60_952);
        assert_eq!(decision.fec_percentage, 5);
        assert_eq!(decision.congestion_source, CongestionSource::AudioPipeline);
        assert!(decision.changed);
    }

    #[test]
    fn one_feedback_window_applies_only_one_pipeline_reduction_for_two_lanes() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let decision = controller.observe_window(
            MediaFeedbackSample {
                decoder_drops: 1,
                ..clean(FeedbackStream::Video)
            },
            MediaFeedbackSample {
                decoder_drops: 1,
                ..clean(FeedbackStream::Audio)
            },
            1,
        );

        assert_eq!(decision.wire_budget_kbps, 80_000);
        assert_eq!(decision.encoder_bitrate_kbps, 60_952);
        assert_eq!(decision.congestion_source, CongestionSource::VideoPipeline);
        assert!(decision.changed);
    }

    #[test]
    fn one_feedback_window_applies_only_one_network_backoff_for_two_streams() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let decision = controller.observe_window(
            MediaFeedbackSample {
                unrecoverable_objects: 1,
                ..clean(FeedbackStream::Video)
            },
            MediaFeedbackSample {
                unrecoverable_objects: 1,
                ..clean(FeedbackStream::Audio)
            },
            1,
        );

        assert_eq!(decision.wire_budget_kbps, 64_000);
        assert_eq!(decision.encoder_bitrate_kbps, 60_952);
        assert_eq!(decision.congestion_source, CongestionSource::VideoNetwork);
        assert!(decision.changed);
    }

    #[test]
    fn transport_empty_processing_windows_do_not_count_as_clean_recovery() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 10, 3);
        let congested = controller.observe(MediaFeedbackSample {
            expected_datagrams: 100,
            received_datagrams: 90,
            ..clean(FeedbackStream::Video)
        });
        assert!(congested.changed);

        let processing_only_video = MediaFeedbackSample {
            stream: FeedbackStream::Video,
            expected_datagrams: 0,
            received_datagrams: 0,
            decoder_submissions: 3,
            decoded_frames: 3,
            presented_frames: 3,
            ..clean(FeedbackStream::Video)
        };
        let processing_only_audio = MediaFeedbackSample {
            stream: FeedbackStream::Audio,
            expected_datagrams: 0,
            received_datagrams: 0,
            ..clean(FeedbackStream::Audio)
        };

        for _ in 0..AdaptiveVideoDeliveryController::CLEAN_WINDOWS_BEFORE_INCREASE {
            let decision =
                controller.observe_window(processing_only_video, processing_only_audio, 1);
            assert!(!decision.changed);
            assert_eq!(decision.wire_budget_kbps, congested.wire_budget_kbps);
            assert_eq!(decision.fec_percentage, congested.fec_percentage);
            assert_eq!(decision.congestion_source, CongestionSource::None);
        }
    }

    #[test]
    fn clean_audio_cannot_probe_up_without_clean_video_transport() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 10, 3);
        let congested = controller.observe(MediaFeedbackSample {
            expected_datagrams: 100,
            received_datagrams: 90,
            ..clean(FeedbackStream::Video)
        });
        let neutral_video = MediaFeedbackSample {
            expected_datagrams: 0,
            received_datagrams: 0,
            ..clean(FeedbackStream::Video)
        };

        for _ in 0..AdaptiveVideoDeliveryController::CLEAN_WINDOWS_BEFORE_INCREASE {
            let decision =
                controller.observe_window(neutral_video, clean(FeedbackStream::Audio), 1);
            assert!(!decision.changed);
            assert_eq!(decision.wire_budget_kbps, congested.wire_budget_kbps);
            assert_eq!(decision.fec_percentage, congested.fec_percentage);
            assert_eq!(decision.congestion_source, CongestionSource::None);
        }
    }

    #[test]
    fn processing_only_decoder_failure_still_reduces_delivery_budget() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let decision = controller.observe_window(
            MediaFeedbackSample {
                expected_datagrams: 0,
                received_datagrams: 0,
                decoder_drops: 1,
                ..clean(FeedbackStream::Video)
            },
            MediaFeedbackSample {
                expected_datagrams: 0,
                received_datagrams: 0,
                ..clean(FeedbackStream::Audio)
            },
            1,
        );

        assert!(decision.changed);
        assert_eq!(decision.wire_budget_kbps, 80_000);
        assert_eq!(decision.encoder_bitrate_kbps, 60_952);
        assert_eq!(decision.congestion_source, CongestionSource::VideoPipeline);
    }

    #[test]
    fn decoder_drop_reduces_pipeline_cap_without_mutating_network_state() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let decision = controller.observe(MediaFeedbackSample {
            decoder_submissions: 100,
            decoded_frames: 99,
            presented_frames: 99,
            decoder_drops: 1,
            ..clean(FeedbackStream::Video)
        });

        assert_eq!(decision.wire_budget_kbps, 80_000);
        assert_eq!(decision.encoder_bitrate_kbps, 60_952);
        assert_eq!(decision.fec_percentage, 5);
        assert_eq!(decision.congestion_source, CongestionSource::VideoPipeline);
        assert!(decision.changed);
    }

    #[test]
    fn repeated_decoder_pressure_reduces_pipeline_cap_once_per_clean_epoch() {
        let mut controller = AdaptiveVideoDeliveryController::new(48_000, 48_000, 5, 3);
        let decoder_pressure = MediaFeedbackSample {
            decoder_drops: 1,
            ..clean(FeedbackStream::Video)
        };

        let first = controller.observe(decoder_pressure);
        assert_eq!(first.wire_budget_kbps, 48_000);
        assert_eq!(first.encoder_bitrate_kbps, 36_572);
        assert!(first.changed);

        for _ in 0..16 {
            let repeated = controller.observe(decoder_pressure);
            assert_eq!(repeated.wire_budget_kbps, 48_000);
            assert_eq!(repeated.encoder_bitrate_kbps, 36_572);
            assert!(!repeated.changed);
        }

        for _ in 0..AdaptiveVideoDeliveryController::CLEAN_WINDOWS_BEFORE_INCREASE {
            _ = controller.observe(clean(FeedbackStream::Video));
        }
        assert_eq!(controller.snapshot().encoder_bitrate_kbps, 43_887);

        let new_epoch = controller.observe(decoder_pressure);
        assert_eq!(new_epoch.wire_budget_kbps, 48_000);
        assert_eq!(new_epoch.encoder_bitrate_kbps, 35_110);
        assert!(new_epoch.changed);
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
        assert_eq!(decision.congestion_source, CongestionSource::VideoNetwork);
        assert!(decision.changed);
    }

    #[test]
    fn eight_clean_video_windows_probe_up_from_the_current_budget() {
        let mut controller = AdaptiveVideoDeliveryController::new(100_000, 80_000, 5, 3);
        let mut decision = controller.snapshot();

        for _ in 0..8 {
            decision = controller.observe(clean(FeedbackStream::Video));
        }

        assert_eq!(decision.wire_budget_kbps, 96_000);
        assert_eq!(decision.encoder_bitrate_kbps, 91_428);
        assert_eq!(decision.fec_percentage, 5);
        assert_eq!(decision.congestion_source, CongestionSource::None);
        assert!(decision.changed);
    }

    #[test]
    fn one_coalesced_clean_window_recovers_by_its_base_window_duration() {
        let mut controller = AdaptiveVideoDeliveryController::new(80_000, 80_000, 5, 3);
        let congested = controller.observe(MediaFeedbackSample {
            decoder_drops: 1,
            ..clean(FeedbackStream::Video)
        });
        assert_eq!(congested.wire_budget_kbps, 80_000);
        assert_eq!(congested.encoder_bitrate_kbps, 60_952);

        let recovered = controller.observe_window(
            clean(FeedbackStream::Video),
            clean(FeedbackStream::Audio),
            AdaptiveVideoDeliveryController::CLEAN_WINDOWS_BEFORE_INCREASE,
        );

        assert_eq!(recovered.wire_budget_kbps, 80_000);
        assert_eq!(recovered.encoder_bitrate_kbps, 73_143);
        assert!(recovered.changed);
    }

    #[test]
    fn presentation_only_pressure_never_mutates_network_or_pipeline_budgets() {
        let mut controller = AdaptiveVideoDeliveryController::new(48_000, 48_000, 5, 3);
        let presentation_only = MediaFeedbackSample {
            presentation_drops: 1,
            ..clean(FeedbackStream::Video)
        };

        let first = controller.observe(presentation_only);
        assert_eq!(first.wire_budget_kbps, 48_000);
        assert_eq!(first.encoder_bitrate_kbps, 45_714);
        assert_eq!(first.congestion_source, CongestionSource::VideoPresentation);
        assert!(!first.changed);

        for _ in 0..16 {
            let repeated = controller.observe(presentation_only);
            assert_eq!(repeated.wire_budget_kbps, 48_000);
            assert_eq!(repeated.encoder_bitrate_kbps, 45_714);
            assert!(!repeated.changed);
        }

        for _ in 0..AdaptiveVideoDeliveryController::CLEAN_WINDOWS_BEFORE_INCREASE {
            _ = controller.observe(clean(FeedbackStream::Video));
        }
        assert_eq!(controller.snapshot().wire_budget_kbps, 48_000);

        let new_episode = controller.observe(presentation_only);
        assert_eq!(new_episode.wire_budget_kbps, 48_000);
        assert_eq!(new_episode.encoder_bitrate_kbps, 45_714);
        assert!(!new_episode.changed);
    }

    #[test]
    fn sustained_transport_pressure_remains_actionable_each_window() {
        let mut controller = AdaptiveVideoDeliveryController::new(48_000, 48_000, 5, 3);
        let transport_pressure = MediaFeedbackSample {
            received_datagrams: 95,
            ..clean(FeedbackStream::Video)
        };

        let first = controller.observe(transport_pressure);
        let second = controller.observe(transport_pressure);

        assert_eq!(first.wire_budget_kbps, 43_200);
        assert_eq!(second.wire_budget_kbps, 38_880);
        assert!(first.changed);
        assert!(second.changed);
    }

    #[test]
    fn sustained_audio_loss_preserves_the_negotiated_quarter_quality_floor() {
        let mut controller = AdaptiveVideoDeliveryController::new(48_000, 48_000, 20, 3);
        let mut decision = controller.snapshot();
        let mut observed_audio_backoff = false;

        for _ in 0..32 {
            decision = controller.observe(MediaFeedbackSample {
                expected_datagrams: 320,
                received_datagrams: 168,
                estimated_jitter_us: 12_000,
                ..clean(FeedbackStream::Audio)
            });
            if decision.changed {
                assert_eq!(decision.congestion_source, CongestionSource::AudioNetwork);
                observed_audio_backoff = true;
            }
        }

        assert!(observed_audio_backoff);
        assert_eq!(decision.wire_budget_kbps, 12_000);
        assert_eq!(decision.fec_percentage, 20);
    }

    #[test]
    fn quarter_floor_recovers_to_the_negotiated_ceiling_within_sixteen_seconds() {
        let mut controller = AdaptiveVideoDeliveryController::new(48_000, 48_000, 20, 3);
        for _ in 0..32 {
            _ = controller.observe(MediaFeedbackSample {
                unrecoverable_objects: 1,
                ..clean(FeedbackStream::Audio)
            });
        }
        assert_eq!(controller.snapshot().wire_budget_kbps, 12_000);

        for _ in 0..64 {
            _ = controller.observe(clean(FeedbackStream::Video));
        }

        let recovered = controller.snapshot();
        assert_eq!(recovered.wire_budget_kbps, 48_000);
        assert_eq!(recovered.fec_percentage, 5);
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
