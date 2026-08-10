import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization
import VideoToolbox

struct LumenAdaptiveVideoDeliveryPolicyState: Equatable, Sendable {
    private(set) var appliedBitrateKbps: Int?
    private(set) var framePacer = LumenAdaptiveVideoFramePacer()
    /// Target selected by the Rust engine.  This is independent from the
    /// legacy client admission divisor so both controls compose into one
    /// source-PTS target instead of running two drop loops.
    private(set) var engineTargetFrameRate: Int
    private(set) var clientAdmissionDivisor = 1
    private(set) var acceptsUpdates = false

    init() {
        engineTargetFrameRate = framePacer.frameRateCeiling
    }

    var admissionDivisor: Int { clientAdmissionDivisor }
    var frameRateCeiling: Int { framePacer.frameRateCeiling }
    var targetFrameRate: Int { framePacer.targetFrameRate }

    private var effectiveTargetFrameRate: Int {
        min(
            engineTargetFrameRate,
            max(frameRateCeiling / clientAdmissionDivisor, 1)
        )
    }

    mutating func beginRunning(
        bitrateKbps: Int,
        targetFrameRate: Int = 120
    ) {
        appliedBitrateKbps = bitrateKbps
        framePacer = LumenAdaptiveVideoFramePacer(
            frameRateCeiling: targetFrameRate
        )
        engineTargetFrameRate = framePacer.frameRateCeiling
        clientAdmissionDivisor = 1
        acceptsUpdates = true
    }

    mutating func beginStopping() {
        acceptsUpdates = false
    }

    mutating func apply(
        bitrateKbps: Int,
        admissionDivisor: Int,
        targetFrameRate: Int? = nil,
        applyBitrate: () throws -> Void
    ) -> Bool {
        let requestedFrameRate = targetFrameRate ?? self.targetFrameRate
        guard acceptsUpdates,
              bitrateKbps > 0,
              (1 ... 4).contains(admissionDivisor),
              (1 ... frameRateCeiling).contains(requestedFrameRate) else {
            return false
        }

        // Build all value-type policy changes before touching the live state.
        // This makes invalid target/cadence combinations a true no-op even
        // when the bitrate application closure is supplied by VideoToolbox.
        var nextFramePacer = framePacer
        let nextEngineTargetFrameRate = targetFrameRate ?? engineTargetFrameRate
        let nextClientAdmissionDivisor = admissionDivisor
        let nextEffectiveTargetFrameRate = min(
            nextEngineTargetFrameRate,
            max(frameRateCeiling / nextClientAdmissionDivisor, 1)
        )
        guard nextFramePacer.configure(
            targetFrameRate: nextEffectiveTargetFrameRate
        ) else {
            return false
        }
        do {
            if appliedBitrateKbps != bitrateKbps {
                try applyBitrate()
            }
            framePacer = nextFramePacer
            engineTargetFrameRate = nextEngineTargetFrameRate
            clientAdmissionDivisor = nextClientAdmissionDivisor
            appliedBitrateKbps = bitrateKbps
            return true
        } catch {
            return false
        }
    }

    /// Applies an engine-selected cadence without changing the negotiated
    /// ScreenCaptureKit ceiling.  The Rust adaptive controller can call this
    /// on the encoder queue when a new observation produces a target.
    @discardableResult
    mutating func setTargetFrameRate(_ targetFrameRate: Int) -> Bool {
        guard acceptsUpdates else { return false }
        guard (1 ... frameRateCeiling).contains(targetFrameRate) else {
            return false
        }
        var nextFramePacer = framePacer
        let nextEffectiveTargetFrameRate = min(
            targetFrameRate,
            max(frameRateCeiling / clientAdmissionDivisor, 1)
        )
        guard nextFramePacer.configure(
            targetFrameRate: nextEffectiveTargetFrameRate
        ) else {
            return false
        }
        engineTargetFrameRate = targetFrameRate
        framePacer = nextFramePacer
        return true
    }

    mutating func admit(
        sourcePresentationTime: CMTime,
        forceKeyFrame: Bool
    ) -> LumenAdaptiveVideoFrameAdmissionDecision {
        if forceKeyFrame {
            return framePacer.admit(
                sourcePresentationTime: sourcePresentationTime,
                forceKeyFrame: true
            )
        }
        guard acceptsUpdates else {
            return .drop
        }

        // The engine target and client divisor have already been composed
        // into one effective PTS target.  Do not run the legacy divisor as a
        // second admission loop: 120 + divisor 2 is 60, while target 60 +
        // divisor 2 remains 60 rather than becoming 30.
        return framePacer.admit(
            sourcePresentationTime: sourcePresentationTime,
            forceKeyFrame: false
        )
    }
}

extension LumenScreenCaptureVideoRuntime {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              !stopping,
              CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = sampleBuffer.imageBuffer,
              compressionSessionAvailable else {
            return
        }

        let callbackEntryMachTime = beginSourceCallback(sampleBuffer)
        defer {
            finishSourceCallback(startedAt: callbackEntryMachTime)
        }

        guard acceptOwnedScreenSample(
            stream: stream,
            sampleBuffer: sampleBuffer
        ) else {
            return
        }

        recordSourceTiming(callbackEntryMachTime)

        if let mismatch = sourceContract?.mismatchDescription(
            for: imageBuffer,
            formatDescription: sampleBuffer.formatDescription
        ) {
            reportTerminalContractFailure(
                .sourceContractMismatch(mismatch),
                sourceDisplayTime: nil
            )
            return
        }
        recordSourceAudit(
            imageBuffer: imageBuffer,
            sampleBuffer: sampleBuffer
        )

        guard isCompleteScreenFrame(sampleBuffer) else {
            statistics.droppedFrameCount &+= 1
            statistics.incompleteSourceFrameCount &+= 1
            refreshStatisticsNotesIfNeeded()
            return
        }
        statistics.completeSourceFrameCount &+= 1

        let source = makePendingSource(
            imageBuffer: imageBuffer,
            sampleBuffer: sampleBuffer,
            sourceMachTime: callbackEntryMachTime
        )
        // Observe before handing the source to the encoder so an activity
        // callback after idle can restore a lowered target before this first
        // frame reaches the pacer.  The observer itself never synthesizes an
        // idle frame.
        observeAdaptiveFrameCadence()
        admitPendingSource(source)
    }

    /// Records every complete source callback without adding another task to
    /// the hot encoder queue.  The Rust controller owns its update window;
    /// only a changed target is handed back to `encoderQueue`, where the
    /// Swift pacer is mutated alongside VideoToolbox admission.
    func observeAdaptiveFrameCadence() {
        guard let controller = adaptiveFrameCadenceController else {
            return
        }
        let decision = controller.observe(
            monotonicTimeSeconds: ProcessInfo.processInfo.systemUptime,
            sourceFrameCount: statistics.completeSourceFrameCount,
            outputFrameCount: statistics.emittedFrameCount,
            pendingDropCount: encoderPendingDropCount,
            pipelineStable: videoBootstrapAdmission.isOpen,
            callbackLatencyMilliseconds:
                videoToolboxCallbackTiming.latestMilliseconds ?? 0
        )
        guard let decision, decision.changed else {
            return
        }
        encoderQueue.async { [weak self] in
            guard let self,
                  !self.stopping else {
                return
            }
            guard self.adaptiveVideoDeliveryPolicy.setTargetFrameRate(
                decision.targetFrameRate
            ) else {
                return
            }
            let effectiveTargetFrameRate =
                self.adaptiveVideoDeliveryPolicy.targetFrameRate
            self.queue.async { [weak self] in
                guard let self else { return }
                self.statistics.adaptiveTargetFrameRate =
                    effectiveTargetFrameRate
                self.refreshStatisticsNotesIfNeeded()
                self.statisticsHandler(self.statistics)
            }
        }
    }

    func acceptOwnedScreenSample(
        stream: SCStream,
        sampleBuffer: CMSampleBuffer
    ) -> Bool {
        do {
            try outputOwnership.recordScreenSample(
                streamIdentity: Self.identity(of: stream)
            )
            return true
        } catch {
            let ownershipError = LumenScreenCaptureError.outputOwnershipLost
            statistics.processingFailureCount &+= 1
            statistics.lastErrorDescription = ownershipError.localizedDescription
            refreshStatisticsNotes()
            statisticsHandler(statistics)
            eventHandler(.init(
                kind: .failed,
                message: ownershipError.localizedDescription,
                sourceDisplayTime: sampleBuffer.presentationTimeStamp.value >= 0
                    ? UInt64(sampleBuffer.presentationTimeStamp.value)
                    : 0
            ))
            terminationHandler(ownershipError)
            return false
        }
    }

    func recordSourceTiming(_ sourceMachTime: UInt64) {
        statistics.sourceFrameCount &+= 1
        if firstSourceMachTime == nil {
            firstSourceMachTime = sourceMachTime
        }
        if let lastSourceMachTime {
            sourceIntervalTotalMilliseconds += LumenMachTime.milliseconds(
                from: lastSourceMachTime,
                to: sourceMachTime
            )
            sourceIntervalSampleCount &+= 1
        }
        lastSourceMachTime = sourceMachTime
    }

    func makePendingSource(
        imageBuffer: CVImageBuffer,
        sampleBuffer: CMSampleBuffer,
        sourceMachTime: UInt64
    ) -> LumenPendingVideoBootstrapSource {
        sequenceNumber &+= 1
        let presentationTime = resolvedPresentationTime(sampleBuffer)
        return LumenPendingVideoBootstrapSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            displayTime: LumenMachTime.ticks(for: presentationTime)
                ?? sourceMachTime,
            duration: CMTime(
                seconds: LumenAdaptiveVideoFrameTiming
                    .fallbackDurationSeconds(
                        targetFrameRate: configuration.effectiveTargetFrameRate
                    ),
                preferredTimescale: LumenAdaptiveVideoFrameTiming.preferredTimescale
            ),
            sequenceNumber: sequenceNumber
        )
    }

    func admitPendingSource(_ source: LumenPendingVideoBootstrapSource) {
        switch videoBootstrapAdmission.admitSourceFrame() {
        case .submitInitialKeyFrame:
            if !submitSource(source, bootstrapReason: .initial) {
                videoBootstrapAdmission.cancelBootstrapSubmission()
            }
        case .coalesceUntilAcknowledged:
            pendingVideoBootstrapSource = source
            statistics.pendingAdmissionDropCount &+= 1
            refreshStatisticsNotesIfNeeded()
        case .submitControlledKeyFrame(let reason):
            if !submitSource(source, bootstrapReason: reason) {
                videoBootstrapAdmission.cancelBootstrapSubmission()
            }
        case .coalesceControlledKeyFrame:
            pendingVideoBootstrapSource = source
            statistics.pendingAdmissionDropCount &+= 1
            refreshStatisticsNotesIfNeeded()
        case .submit:
            submitSource(source, bootstrapReason: nil)
        }
    }

    func recordSourceAudit(
        imageBuffer: CVImageBuffer,
        sampleBuffer: CMSampleBuffer
    ) {
        statistics.exactCaptureAudit.inputFourCC = auditFourCC(
            CVPixelBufferGetPixelFormatType(imageBuffer)
        )
        statistics.exactCaptureAudit.lumaPlaneWidth =
            CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
        statistics.exactCaptureAudit.lumaPlaneHeight =
            CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        statistics.exactCaptureAudit.chromaPlaneWidth =
            CVPixelBufferGetWidthOfPlane(imageBuffer, 1)
        statistics.exactCaptureAudit.chromaPlaneHeight =
            CVPixelBufferGetHeightOfPlane(imageBuffer, 1)
        let extensions = sampleBuffer.formatDescription.flatMap {
            CMFormatDescriptionGetExtensions($0) as? [CFString: Any]
        }
        statistics.exactCaptureAudit.colorPrimaries = sourceAttachment(
            imageBuffer,
            key: kCVImageBufferColorPrimariesKey,
            fallback: extensions?[kCMFormatDescriptionExtension_ColorPrimaries]
        )
        statistics.exactCaptureAudit.transferFunction = sourceAttachment(
            imageBuffer,
            key: kCVImageBufferTransferFunctionKey,
            fallback: extensions?[
                kCMFormatDescriptionExtension_TransferFunction
            ]
        )
        statistics.exactCaptureAudit.yCbCrMatrix = sourceAttachment(
            imageBuffer,
            key: kCVImageBufferYCbCrMatrixKey,
            fallback: extensions?[kCMFormatDescriptionExtension_YCbCrMatrix]
        )
    }

    func sourceAttachment(
        _ imageBuffer: CVImageBuffer,
        key: CFString,
        fallback: Any?
    ) -> String? {
        (CVBufferCopyAttachment(imageBuffer, key, nil) as? String)
            ?? (fallback as? String)
    }

    func resolvedPresentationTime(
        _ sampleBuffer: CMSampleBuffer
    ) -> CMTime {
        guard sampleBuffer.presentationTimeStamp.isValid else {
            return CMTime(
                value: CMTimeValue(sequenceNumber),
                timescale: CMTimeScale(
                    configuration.effectiveTargetFrameRate
                )
            )
        }
        return sampleBuffer.presentationTimeStamp
    }
}
