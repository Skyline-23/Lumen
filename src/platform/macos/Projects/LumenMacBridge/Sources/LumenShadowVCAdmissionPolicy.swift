import CoreMedia

/// Composes receiver pressure and content cadence before predictive encoding.
/// The transport owns the byte budget; this policy never changes quantization.
struct LumenShadowVCAdmissionPolicy {
    private var pacer: LumenAdaptiveVideoFramePacer
    private var admissionDivisor = 1
    private var contentFrameRate: Int

    init(frameRateCeiling: Int) {
        pacer = LumenAdaptiveVideoFramePacer(frameRateCeiling: frameRateCeiling)
        contentFrameRate = pacer.frameRateCeiling
    }

    var targetFrameRate: Int { pacer.targetFrameRate }

    mutating func apply(admissionDivisor: Int) -> Bool {
        guard (1 ... 4).contains(admissionDivisor) else { return false }
        self.admissionDivisor = admissionDivisor
        updateTarget()
        return true
    }

    mutating func setContentFrameRate(_ frameRate: Int) {
        guard (1 ... pacer.frameRateCeiling).contains(frameRate),
              frameRate != contentFrameRate else { return }
        contentFrameRate = frameRate
        updateTarget()
    }

    mutating func admit(sourcePresentationTime: CMTime, forceKeyFrame: Bool) -> Bool {
        // At the negotiated ceiling retain the compositor's native cadence;
        // small 120 Hz PTS deviations must not produce alternate-frame drops.
        guard forceKeyFrame || targetFrameRate < pacer.frameRateCeiling else { return true }
        return pacer.admit(
            sourcePresentationTime: sourcePresentationTime,
            forceKeyFrame: forceKeyFrame
        ).isAdmitted
    }

    private mutating func updateTarget() {
        let target = min(contentFrameRate, max(pacer.frameRateCeiling / admissionDivisor, 1))
        if target != pacer.targetFrameRate {
            _ = pacer.configure(targetFrameRate: target)
        }
    }
}
