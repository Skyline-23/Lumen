import CoreMedia
import Foundation

/// The result of applying the source-PTS pacing policy to one frame.
///
/// A dropped frame never updates the admitted PTS.  This is important when a
/// source briefly runs ahead of the encoder: a later frame can still recover
/// from the last frame that actually entered VideoToolbox instead of inheriting
/// a gap from a frame that was never encoded.
enum LumenAdaptiveVideoFrameAdmissionDecision: Equatable, Sendable {
    case drop
    case admit(durationSeconds: Double)

    var isAdmitted: Bool {
        switch self {
        case .drop:
            false
        case .admit:
            true
        }
    }

    var durationSeconds: Double? {
        switch self {
        case .drop:
            nil
        case .admit(let durationSeconds):
            durationSeconds
        }
    }
}

/// Timing rules shared by source pacing and the VideoToolbox submission
/// boundary.  Source timestamps are allowed to be irregular, but an invalid,
/// zero, or extremely long delta must not turn into an unbounded encoder
/// duration.
enum LumenAdaptiveVideoFrameTiming {
    static let preferredTimescale: CMTimeScale = 60_000
    static let minimumDurationSeconds = 1.0 / 240.0
    static let maximumDurationSeconds = 1.0 / 15.0
    // Rust owns the one-second activity-driven periodic refresh. VideoToolbox
    // retains only a watchdog interval so it cannot race every controlled IDR.
    static let keyFrameIntervalDurationSeconds = 10.0

    static func fallbackDurationSeconds(targetFrameRate: Int) -> Double {
        1.0 / Double(max(targetFrameRate, 1))
    }

    static func durationSeconds(
        from deltaSeconds: Double?,
        targetFrameRate: Int
    ) -> Double {
        let fallback = fallbackDurationSeconds(targetFrameRate: targetFrameRate)
        guard let deltaSeconds,
              deltaSeconds.isFinite,
              deltaSeconds > 0 else {
            return fallback
        }
        return min(
            max(deltaSeconds, minimumDurationSeconds),
            maximumDurationSeconds
        )
    }

    static func cmTime(seconds: Double) -> CMTime {
        CMTime(
            seconds: seconds,
            preferredTimescale: preferredTimescale
        )
    }
}

/// Paces source frames against an adaptive target while preserving the
/// negotiated source ceiling.  The target can be lowered by the engine's
/// adaptive controller, but it can never exceed the ceiling supplied when the
/// capture session starts.
struct LumenAdaptiveVideoFramePacer: Equatable, Sendable {
    private(set) var frameRateCeiling: Int
    private(set) var targetFrameRate: Int
    private(set) var lastAdmittedPresentationTimeSeconds: Double?
    private(set) var nextAdmissionDeadlineSeconds: Double?

    init(frameRateCeiling: Int = 120) {
        let sanitizedCeiling = max(frameRateCeiling, 1)
        self.frameRateCeiling = sanitizedCeiling
        targetFrameRate = sanitizedCeiling
        lastAdmittedPresentationTimeSeconds = nil
        nextAdmissionDeadlineSeconds = nil
    }

    mutating func configure(targetFrameRate: Int) -> Bool {
        guard (1 ... frameRateCeiling).contains(targetFrameRate) else {
            return false
        }
        self.targetFrameRate = targetFrameRate
        if let lastAdmittedPresentationTimeSeconds {
            nextAdmissionDeadlineSeconds = lastAdmittedPresentationTimeSeconds
                + LumenAdaptiveVideoFrameTiming
                    .fallbackDurationSeconds(targetFrameRate: targetFrameRate)
        }
        return true
    }

    mutating func admit(
        sourcePresentationTime: CMTime,
        forceKeyFrame: Bool
    ) -> LumenAdaptiveVideoFrameAdmissionDecision {
        let sourceSeconds = sourcePresentationTime.isValid &&
            sourcePresentationTime.timescale != 0 &&
            sourcePresentationTime.seconds.isFinite
            ? sourcePresentationTime.seconds
            : nil

        guard let sourceSeconds else {
            // An invalid source timestamp should not stall the live encoder.
            // The caller still supplies the source PTS to VideoToolbox, while
            // this fallback keeps the duration finite and predictable.
            return .admit(
                durationSeconds: LumenAdaptiveVideoFrameTiming
                    .fallbackDurationSeconds(targetFrameRate: targetFrameRate)
            )
        }

        if forceKeyFrame {
            let delta = lastAdmittedPresentationTimeSeconds.map {
                sourceSeconds - $0
            }
            if lastAdmittedPresentationTimeSeconds == nil ||
                sourceSeconds > lastAdmittedPresentationTimeSeconds! {
                lastAdmittedPresentationTimeSeconds = sourceSeconds
                nextAdmissionDeadlineSeconds = sourceSeconds
                    + LumenAdaptiveVideoFrameTiming
                        .fallbackDurationSeconds(
                            targetFrameRate: targetFrameRate
                        )
            }
            return .admit(
                durationSeconds: LumenAdaptiveVideoFrameTiming.durationSeconds(
                    from: delta,
                    targetFrameRate: targetFrameRate
                )
            )
        }

        guard let lastAdmittedPresentationTimeSeconds else {
            self.lastAdmittedPresentationTimeSeconds = sourceSeconds
            nextAdmissionDeadlineSeconds = sourceSeconds
                + LumenAdaptiveVideoFrameTiming
                    .fallbackDurationSeconds(targetFrameRate: targetFrameRate)
            return .admit(
                durationSeconds: LumenAdaptiveVideoFrameTiming
                    .fallbackDurationSeconds(targetFrameRate: targetFrameRate)
            )
        }

        let delta = sourceSeconds - lastAdmittedPresentationTimeSeconds
        let targetInterval = LumenAdaptiveVideoFrameTiming
            .fallbackDurationSeconds(targetFrameRate: targetFrameRate)
        let deadline = nextAdmissionDeadlineSeconds
            ?? (lastAdmittedPresentationTimeSeconds + targetInterval)
        // A tiny epsilon avoids rejecting a timestamp that differs from the
        // target interval only because of CMTime's rational-to-double
        // conversion.  Advancing a fractional deadline (rather than simply
        // waiting for one full target interval after every admitted frame)
        // preserves the cadence phase: 120 Hz -> 58 Hz alternates two- and
        // three-source-frame gaps instead of drifting to roughly 40 Hz.
        guard delta.isFinite,
              sourceSeconds + 0.000001 >= deadline else {
            return .drop
        }

        self.lastAdmittedPresentationTimeSeconds = sourceSeconds
        let elapsedSinceDeadline = max(sourceSeconds - deadline, 0)
        let intervalsToAdvance = floor(elapsedSinceDeadline / targetInterval)
            + 1
        nextAdmissionDeadlineSeconds = deadline
            + intervalsToAdvance * targetInterval
        return .admit(
            durationSeconds: LumenAdaptiveVideoFrameTiming.durationSeconds(
                from: delta,
                targetFrameRate: targetFrameRate
            )
        )
    }
}
