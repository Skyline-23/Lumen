import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

/// Synchronous signals at the SCK callback boundary. The capture actor owns
/// lifecycle decisions; these methods only read or consume its atomic signals.
protocol LumenShadowVCCaptureSignals: AnyObject, Sendable {
    func currentCaptureEpoch() -> UInt64
    func capturePipelineIsStable() -> Bool
    func takeCaptureWakeRequest(epoch: UInt64) -> Bool
}

struct LumenShadowVCCapturedFrame: Sendable {
    let sample: LumenSampleBufferHandle
    let epoch: UInt64
}

// SCK serializes this output's callbacks. The controller is thread-safe for the
// actor's target reads; all other cross-boundary state uses the existing atomics.
final class LumenShadowVCStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<LumenShadowVCCapturedFrame, Error>.Continuation
    let contentCadence: LumenUnchangedContentCadenceController
    private weak var signals: (any LumenShadowVCCaptureSignals)?
    let completeFrames = Atomic<UInt64>(0)
    let idleFrames = Atomic<UInt64>(0)
    let droppedFrames = Atomic<UInt64>(0)
    init(
        continuation: AsyncThrowingStream<LumenShadowVCCapturedFrame, Error>.Continuation,
        contentCadence: LumenUnchangedContentCadenceController,
        signals: any LumenShadowVCCaptureSignals
    ) {
        self.continuation = continuation
        self.contentCadence = contentCadence
        self.signals = signals
    }

    func finish() { continuation.finish() }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish(throwing: error)
    }
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        process(sampleBuffer, monotonicTimeSeconds: ProcessInfo.processInfo.systemUptime)
    }
    func process(_ sampleBuffer: CMSampleBuffer, monotonicTimeSeconds: Double) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let signals else { return }
        let generation = signals.currentCaptureEpoch()
        let metadata = LumenScreenCaptureContentMetadata(sampleBuffer: sampleBuffer)
        let woke = signals.takeCaptureWakeRequest(epoch: generation)
        if woke, let decision = contentCadence.wake(monotonicTimeSeconds: monotonicTimeSeconds) {
            reportCadence(decision, reason: "input", monotonicTimeSeconds: monotonicTimeSeconds)
        }
        if let decision = contentCadence.observe(
            monotonicTimeSeconds: monotonicTimeSeconds,
            signal: metadata.signal, pipelineStable: signals.capturePipelineIsStable())
        {
            reportCadence(
                decision, reason: String(describing: metadata.signal),
                monotonicTimeSeconds: monotonicTimeSeconds)
        }
        // Idle metadata must not evict the last complete image in the newest-
        // source slot. Observe it here and only hand real images to the actor.
        if metadata.status == .idle { _ = idleFrames.wrappingAdd(1, ordering: .relaxed) }
        guard metadata.status == .complete, sampleBuffer.imageBuffer != nil else { return }
        _ = completeFrames.wrappingAdd(1, ordering: .relaxed)
        if case .dropped = continuation.yield(
            .init(sample: LumenSampleBufferHandle(retaining: sampleBuffer), epoch: generation))
        {
            _ = droppedFrames.wrappingAdd(1, ordering: .relaxed)
        }
    }
    private func reportCadence(
        _ decision: LumenUnchangedContentCadenceController.Decision,
        reason: String, monotonicTimeSeconds: Double
    ) {
        guard decision.changed else { return }
        let message =
            "Lumen ShadowVC stage=content-cadence target-fps=\(decision.targetFrameRate) low-rate=\(decision.lowRateActive) reason=\(reason) uptime-seconds=\(monotonicTimeSeconds)\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }
}
