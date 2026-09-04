import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
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
    /// Target selected by the host unchanged-content controller.  It is kept
    /// separate from encoder-pressure adaptation so a content wake can rebase
    /// without erasing the pressure controller's observation history.
    private(set) var contentTargetFrameRate: Int
    private(set) var clientAdmissionDivisor = 1
    private(set) var acceptsUpdates = false

    init() {
        engineTargetFrameRate = framePacer.frameRateCeiling
        contentTargetFrameRate = framePacer.frameRateCeiling
    }

    var admissionDivisor: Int { clientAdmissionDivisor }
    var frameRateCeiling: Int { framePacer.frameRateCeiling }
    var targetFrameRate: Int { framePacer.targetFrameRate }

    private var effectiveTargetFrameRate: Int {
        min(
            min(engineTargetFrameRate, contentTargetFrameRate),
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
        contentTargetFrameRate = framePacer.frameRateCeiling
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
        let nextContentTargetFrameRate = contentTargetFrameRate
        let nextClientAdmissionDivisor = admissionDivisor
        let nextEffectiveTargetFrameRate = min(
            min(nextEngineTargetFrameRate, nextContentTargetFrameRate),
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
            contentTargetFrameRate = nextContentTargetFrameRate
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

    /// Applies the unchanged-content target without changing the negotiated
    /// ScreenCaptureKit ceiling.  The two controller targets are composed in
    /// one value update so a stale asynchronous callback cannot accidentally
    /// restore a target above the other controller's bound.
    @discardableResult
    mutating func setContentTargetFrameRate(_ targetFrameRate: Int) -> Bool {
        guard acceptsUpdates else { return false }
        guard (1 ... frameRateCeiling).contains(targetFrameRate) else {
            return false
        }
        var nextFramePacer = framePacer
        let nextEffectiveTargetFrameRate = min(
            min(engineTargetFrameRate, targetFrameRate),
            max(frameRateCeiling / clientAdmissionDivisor, 1)
        )
        guard nextFramePacer.configure(
            targetFrameRate: nextEffectiveTargetFrameRate
        ) else {
            return false
        }
        contentTargetFrameRate = targetFrameRate
        framePacer = nextFramePacer
        return true
    }

    /// Atomically applies both host targets. This is used when independent
    /// Rust controllers report changes on the capture queue and the pacer is
    /// mutated later on the VideoToolbox admission queue.
    @discardableResult
    mutating func setTargetFrameRates(
        engineTargetFrameRate: Int,
        contentTargetFrameRate: Int
    ) -> Bool {
        guard acceptsUpdates,
              (1 ... frameRateCeiling).contains(engineTargetFrameRate),
              (1 ... frameRateCeiling).contains(contentTargetFrameRate) else {
            return false
        }
        var nextFramePacer = framePacer
        let nextEffectiveTargetFrameRate = min(
            min(engineTargetFrameRate, contentTargetFrameRate),
            max(frameRateCeiling / clientAdmissionDivisor, 1)
        )
        guard nextFramePacer.configure(
            targetFrameRate: nextEffectiveTargetFrameRate
        ) else {
            return false
        }
        self.engineTargetFrameRate = engineTargetFrameRate
        self.contentTargetFrameRate = contentTargetFrameRate
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
        guard type == .screen else {
            return
        }
        processCapturedSampleBuffer(
            sampleBuffer,
            screenCaptureStream: stream
        )
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        guard let avCaptureHandle,
              avCaptureHandle.output === output else {
            return
        }
        processCapturedSampleBuffer(
            sampleBuffer,
            screenCaptureStream: nil
        )
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop _: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        guard let avCaptureHandle,
              avCaptureHandle.output === output else {
            return
        }
        statistics.droppedFrameCount &+= 1
        refreshStatisticsNotesIfNeeded()
    }

    func processSkyLightFrame(
        status: CGDisplayStreamFrameStatus,
        displayTime: UInt64,
        pixelBuffer: CVPixelBuffer?,
        pixelBufferStatus: CVReturn
    ) {
        guard !stopping,
              compressionSessionAvailable else {
            return
        }

        let callbackEntryMachTime = mach_absolute_time()
        defer {
            finishSourceCallback(startedAt: callbackEntryMachTime)
        }
        captureIngressTimings.observe(
            displayedMachTime: displayTime,
            callbackMachTime: callbackEntryMachTime
        )

        if status == .stopped {
            reportSkyLightCaptureFailure(
                .skyLightStreamStopped(configuration.displayID),
                sourceDisplayTime: displayTime
            )
            return
        }
        // FrameIdle and FrameBlank carry no fresh compositor surface. They are
        // the desired cheap path for a static display, not dropped video.
        guard status == .frameComplete else {
            return
        }

        guard pixelBufferStatus == kCVReturnSuccess,
              let pixelBuffer else {
            reportSkyLightCaptureFailure(
                .skyLightFrameUnavailable(
                    configuration.displayID,
                    Int32(pixelBufferStatus)
                ),
                sourceDisplayTime: displayTime
            )
            return
        }

        // CGDisplayStream's IOSurface is only callback-owned by default.  The
        // lease below is held by the Metal completion context until the GPU
        // reports completion, never through a CPU copy or a VT queue wait.
        guard let sourceSurfaceLease =
                LumenMacSkyLightDisplayStreamFrameLease
                    .lease(withPixelBuffer: pixelBuffer) else {
            reportSkyLightCaptureFailure(
                .skyLightFrameUnavailable(
                    configuration.displayID,
                    Int32(kCVReturnInvalidArgument)
                ),
                sourceDisplayTime: displayTime
            )
            return
        }

        guard let streamIdentity = skyLightDisplayStreamIdentity else {
            return
        }

        if !didLogSkyLightFirstFrame {
            didLogSkyLightFirstFrame = true
            Self.startupLogger.notice(
                "stage=skylight-first-frame status=complete display-time=\(displayTime, privacy: .public) surface=\(CVPixelBufferGetWidth(pixelBuffer), privacy: .public)x\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public) pixel-format=\(auditFourCC(CVPixelBufferGetPixelFormatType(pixelBuffer)), privacy: .public) zero-copy-wrap-status=\(pixelBufferStatus, privacy: .public)"
            )
        }
        do {
            try outputOwnership.recordScreenSample(
                streamIdentity: streamIdentity
            )
        } catch {
            reportSkyLightCaptureFailure(
                .outputOwnershipLost,
                sourceDisplayTime: displayTime
            )
            return
        }

        applySkyLightSourceColorAttachments(to: pixelBuffer)
        recordSourceTiming(callbackEntryMachTime)

        guard let resources = skyLightMetalStagingResources else {
            recordSkyLightMetalStagingDrop(
                sourceDisplayTime: displayTime,
                reason: "resources-missing"
            )
            return
        }
        if let mismatch = resources.format.mismatchDescription(
            for: pixelBuffer,
            width: outputWidth,
            height: outputHeight
        ) {
            skyLightMetalStageValidationFailureCount &+= 1
            recordSkyLightMetalStagingValidationFailure(
                sourceDisplayTime: displayTime,
                reason: "source-shape-\(mismatch)"
            )
            reportTerminalContractFailure(
                .sourceContractMismatch(mismatch),
                sourceDisplayTime: displayTime
            )
            return
        }

        let presentationTime = resolvedSkyLightPresentationTime(
            displayTime: displayTime
        )
        guard skyLightMetalStagingAdmission.beginCopy() else {
            // The queue is serial, but keep the admission helper as the
            // authoritative bounded in-flight guard for future callback paths.
            recordSkyLightMetalStagingDrop(
                sourceDisplayTime: displayTime,
                reason: "busy"
            )
            return
        }
        let metalStageStartedMachTime = mach_absolute_time()

        let (destination, allocationStatus) = resources.allocateDestination()
        guard allocationStatus == kCVReturnSuccess,
              let destination else {
            _ = skyLightMetalStagingAdmission.completeCopy()
            skyLightMetalStagePoolAllocationFailureCount &+= 1
            recordSkyLightMetalStagingDrop(
                sourceDisplayTime: displayTime,
                reason: "pool-allocation-status-\(allocationStatus)"
            )
            return
        }

        // Attachments are metadata-only and do not touch the pixel planes.
        // Propagate them before the blit so the completion-side exact contract
        // sees the same HDR/source description as the compositor buffer.
        CVBufferPropagateAttachments(pixelBuffer, destination)

        let (sourceLumaTexture, sourceLumaStatus) = resources.makeTexture(
            from: pixelBuffer,
            plane: 0
        )
        let (sourceChromaTexture, sourceChromaStatus) = resources.makeTexture(
            from: pixelBuffer,
            plane: 1
        )
        let (destinationLumaTexture, destinationLumaStatus) = resources.makeTexture(
            from: destination,
            plane: 0
        )
        let (destinationChromaTexture, destinationChromaStatus) = resources.makeTexture(
            from: destination,
            plane: 1
        )
        guard let sourceLumaTexture,
              let sourceChromaTexture,
              let destinationLumaTexture,
              let destinationChromaTexture else {
            _ = skyLightMetalStagingAdmission.completeCopy()
            skyLightMetalStageTextureFailureCount &+= 1
            let status = [
                sourceLumaStatus,
                sourceChromaStatus,
                destinationLumaStatus,
                destinationChromaStatus
            ].first(where: { $0 != kCVReturnSuccess }) ?? kCVReturnInvalidArgument
            recordSkyLightMetalStagingDrop(
                sourceDisplayTime: displayTime,
                reason: "texture-creation-status-\(status)"
            )
            return
        }

        guard let commandBuffer = resources.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            _ = skyLightMetalStagingAdmission.completeCopy()
            skyLightMetalStageCommandBufferFailureCount &+= 1
            recordSkyLightMetalStagingDrop(
                sourceDisplayTime: displayTime,
                reason: "command-buffer-creation"
            )
            return
        }

        guard let sourceLumaMetalTexture = CVMetalTextureGetTexture(
                  sourceLumaTexture
              ),
              let sourceChromaMetalTexture = CVMetalTextureGetTexture(
                  sourceChromaTexture
              ),
              let destinationLumaMetalTexture = CVMetalTextureGetTexture(
                  destinationLumaTexture
              ),
              let destinationChromaMetalTexture = CVMetalTextureGetTexture(
                  destinationChromaTexture
              ) else {
            blit.endEncoding()
            _ = skyLightMetalStagingAdmission.completeCopy()
            skyLightMetalStageTextureFailureCount &+= 1
            recordSkyLightMetalStagingDrop(
                sourceDisplayTime: displayTime,
                reason: "texture-resolution"
            )
            return
        }

        // Copy the two bi-planar planes without locking the source or waiting
        // for the GPU.  The command buffer owns the actual transfer lifetime.
        blit.copy(
            from: sourceLumaMetalTexture,
            to: destinationLumaMetalTexture
        )
        blit.copy(
            from: sourceChromaMetalTexture,
            to: destinationChromaMetalTexture
        )
        blit.endEncoding()

        let copyContext = LumenSkyLightMetalCopyContext(
            destination: destination,
            presentationTime: presentationTime,
            sourceDisplayTime: displayTime,
            streamIdentity: streamIdentity,
            mediaEpoch: mediaEpoch,
            stagingGeneration: skyLightMetalStagingGeneration.value,
            startedMachTime: metalStageStartedMachTime,
            sourceSurfaceLease: sourceSurfaceLease,
            sourceLumaTexture: sourceLumaTexture,
            sourceChromaTexture: sourceChromaTexture,
            destinationLumaTexture: destinationLumaTexture,
            destinationChromaTexture: destinationChromaTexture
        )
        commandBuffer.addCompletedHandler { [self, copyContext] buffer in
            let status = buffer.status
            let errorDescription = buffer.error?.localizedDescription
            self.queue.async { [self, copyContext] in
                self.completeSkyLightMetalStaging(
                    copyContext,
                    status: status,
                    errorDescription: errorDescription
                )
            }
        }
        skyLightMetalStageSubmissionCount &+= 1
        commandBuffer.commit()
    }

    func completeSkyLightMetalStaging(
        _ copyContext: LumenSkyLightMetalCopyContext,
        status: MTLCommandBufferStatus,
        errorDescription: String?
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        // Metal has finished reading the compositor surface.  Release its
        // use-count lease and source texture wrappers before inspecting the
        // encoder-owned destination or entering VideoToolbox admission.
        copyContext.releaseGPUOwnedSourceResources()
        guard skyLightMetalStagingGeneration.accepts(
            copyContext.stagingGeneration
        ) else {
            skyLightMetalStageLastError = "stale-staging-generation"
            Self.pipelineLogger.notice(
                "stage=skylight-metal-staging-completion-retired copy-generation=\(copyContext.stagingGeneration, privacy: .public) current-generation=\(self.skyLightMetalStagingGeneration.value, privacy: .public) stream=\(copyContext.streamIdentity, privacy: .public)"
            )
            return
        }
        _ = skyLightMetalStagingAdmission.completeCopy()
        skyLightMetalStageCompletionCount &+= 1
        skyLightMetalStageTiming.observe(
            LumenMachTime.milliseconds(
                from: copyContext.startedMachTime,
                to: mach_absolute_time()
            )
        )
        defer {
            resumeSkyLightMetalStagingDrainWaitersIfNeeded()
            if skyLightMetalStagingReleaseRequested,
               skyLightMetalStagingAdmission.canDrain {
                releaseSkyLightMetalStaging()
            }
        }

        guard status == .completed else {
            skyLightMetalStageCommandBufferFailureCount &+= 1
            recordSkyLightMetalStagingDrop(
                sourceDisplayTime: copyContext.sourceDisplayTime,
                reason: "command-buffer-status-\(status)-\(errorDescription ?? "none")"
            )
            return
        }
        guard !stopping,
              compressionSessionAvailable,
              copyContext.mediaEpoch == mediaEpoch,
              copyContext.streamIdentity == skyLightDisplayStreamIdentity else {
            return
        }

        guard let resources = skyLightMetalStagingResources else {
            recordSkyLightMetalStagingDrop(
                sourceDisplayTime: copyContext.sourceDisplayTime,
                reason: "resources-missing-at-completion"
            )
            return
        }
        guard resources.format.mismatchDescription(
            for: copyContext.destination,
            width: outputWidth,
            height: outputHeight
        ) == nil else {
            let mismatch = resources.format.mismatchDescription(
                for: copyContext.destination,
                width: outputWidth,
                height: outputHeight
            ) ?? "unknown"
            skyLightMetalStageValidationFailureCount &+= 1
            recordSkyLightMetalStagingValidationFailure(
                sourceDisplayTime: copyContext.sourceDisplayTime,
                reason: "destination-shape-\(mismatch)"
            )
            reportTerminalContractFailure(
                .sourceContractMismatch(mismatch),
                sourceDisplayTime: copyContext.sourceDisplayTime
            )
            return
        }
        if let mismatch = sourceContract?.mismatchDescription(
            for: copyContext.destination
        ) {
            skyLightMetalStageValidationFailureCount &+= 1
            recordSkyLightMetalStagingValidationFailure(
                sourceDisplayTime: copyContext.sourceDisplayTime,
                reason: "destination-contract-\(mismatch)"
            )
            reportTerminalContractFailure(
                .sourceContractMismatch(mismatch),
                sourceDisplayTime: copyContext.sourceDisplayTime
            )
            return
        }

        recordSourceAudit(
            imageBuffer: copyContext.destination,
            sampleBuffer: nil
        )
        statistics.completeSourceFrameCount &+= 1
        admitPendingSource(
            makePendingSource(
                imageBuffer: copyContext.destination,
                presentationTime: copyContext.presentationTime,
                sourceDisplayTime: copyContext.sourceDisplayTime
            )
        )
    }

    func recordSkyLightMetalStagingDrop(
        sourceDisplayTime: UInt64,
        reason: String
    ) {
        skyLightMetalStageLastError = reason
        let isPressureDrop = reason == "busy"
        if isPressureDrop {
            skyLightMetalStageBusyDropCount &+= 1
        }
        statistics.droppedFrameCount &+= 1
        if isPressureDrop {
            statistics.pendingAdmissionDropCount &+= 1
            encoderPendingDropCount &+= 1
        }
        refreshStatisticsNotesIfNeeded()
        let count = statistics.pendingAdmissionDropCount
        guard count == 1 || count % 120 == 0 else { return }
        Self.pipelineLogger.notice(
            "stage=skylight-metal-staging-drop source-display-time=\(sourceDisplayTime, privacy: .public) reason=\(reason, privacy: .public) gpu-copy-inflight=\(self.skyLightMetalStagingAdmission.isCopyInFlight, privacy: .public) pool-capacity=\(LumenSkyLightMetalStagingPolicy.poolCapacity, privacy: .public)"
        )
    }

    func recordSkyLightMetalStagingValidationFailure(
        sourceDisplayTime: UInt64,
        reason: String
    ) {
        skyLightMetalStageLastError = reason
        Self.pipelineLogger.error(
            "stage=skylight-metal-staging-validation-failure source-display-time=\(sourceDisplayTime, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    func resumeSkyLightMetalStagingDrainWaitersIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard skyLightMetalStagingAdmission.canDrain,
              !skyLightMetalCopyDrainWaiters.isEmpty else {
            return
        }
        let waiters = skyLightMetalCopyDrainWaiters
        skyLightMetalCopyDrainWaiters.removeAll(keepingCapacity: false)
        // Resume after this queue block has returned.  The continuation then
        // cannot race the tail of completionSkyLightMetalStaging, where the
        // destination is audited and handed to the normal admission path.
        queue.async {
            waiters.forEach { $0.resume() }
        }
    }

    /*
     * The remainder of this extension intentionally stays below the hot-path
     * helpers.  The previous source-contract check/admission block is removed
     * from the callback: it now runs in completeSkyLightMetalStaging after the
     * destination has been filled by Metal.
     */

    func applySkyLightSourceColorAttachments(to imageBuffer: CVImageBuffer) {
        guard configuration.dynamicRange == .hdr10,
              let color = configuration.encodedColorConfiguration else {
            return
        }
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferColorPrimariesKey,
            color.colorPrimaries.imageBufferValue,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferTransferFunctionKey,
            color.transferFunction.imageBufferValue,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            imageBuffer,
            kCVImageBufferYCbCrMatrixKey,
            color.yCbCrMatrix.imageBufferValue,
            .shouldPropagate
        )
    }

    func reportSkyLightCaptureFailure(
        _ error: LumenScreenCaptureError,
        sourceDisplayTime: UInt64
    ) {
        guard !skyLightCaptureFailureReported else {
            return
        }
        skyLightCaptureFailureReported = true
        // Fence callback and queued admission immediately. The asynchronous
        // owner teardown may not run until after this callback returns, and
        // no later compositor surface may enter VideoToolbox once the private
        // source has reported a terminal failure.
        stopping = true
        compressionSessionAvailable = false
        pendingVideoBootstrapSource = nil
        encoderAdmission.beginStopping()
        statistics.isRunning = false
        statistics.processingFailureCount &+= 1
        statistics.lastErrorDescription = error.localizedDescription
        refreshStatisticsNotes()
        statisticsHandler(statistics)
        eventHandler(.init(
            kind: .failed,
            message: error.localizedDescription,
            sourceDisplayTime: sourceDisplayTime
        ))
        terminationHandler(error)
    }

    func processCapturedSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        screenCaptureStream: SCStream?
    ) {
        guard !stopping,
              CMSampleBufferIsValid(sampleBuffer),
              compressionSessionAvailable else {
            return
        }

        let callbackEntryMachTime = beginSourceCallback(sampleBuffer)
        defer {
            finishSourceCallback(startedAt: callbackEntryMachTime)
        }

        if let screenCaptureStream {
            guard acceptOwnedScreenSample(
                stream: screenCaptureStream,
                sampleBuffer: sampleBuffer
            ) else {
                return
            }
            if let imageBuffer = sampleBuffer.imageBuffer {
                logScreenFrameGeometryIfNeeded(
                    sampleBuffer,
                    imageBuffer: imageBuffer
                )
            }
        }

        recordSourceTiming(callbackEntryMachTime)
        observeUnchangedContentCadence(
            signal: unchangedContentCadenceSignal(for: sampleBuffer)
        )

        guard let imageBuffer = sampleBuffer.imageBuffer else {
            // SCFrameStatusIdle samples are metadata-only on some macOS
            // releases. They still confirm unchanged content, but cannot be
            // submitted to VideoToolbox and must not synthesize a pixel frame.
            return
        }

        guard isCompleteScreenFrame(sampleBuffer) else {
            statistics.droppedFrameCount &+= 1
            statistics.incompleteSourceFrameCount &+= 1
            refreshStatisticsNotesIfNeeded()
            return
        }
        statistics.completeSourceFrameCount &+= 1

        // Once bootstrap admission is open, the capture-queue gate prevents
        // unchanged high-refresh samples from reaching source-contract audit,
        // pending-source allocation, or the encoder queue. Bootstrap and
        // reconfiguration samples remain untouched so the reliable key-frame
        // boundary cannot be starved.
        let presentationTime = resolvedPresentationTime(sampleBuffer)
        let sourceDisplayTime = LumenMachTime.ticks(for: presentationTime)
            ?? callbackEntryMachTime
        if videoBootstrapAdmission.isOpen,
           !unchangedContentIngressPacer.admit(
               sourcePresentationTime: presentationTime,
               forceKeyFrame: false
           ).isAdmitted {
            recordIntentionalFrameCadenceDrop(
                sourceDisplayTime: sourceDisplayTime
            )
            return
        }
        // The complete-source counter above includes intentional content
        // drops. Observing only admitted static samples preserves that source
        // delta while avoiding a Rust controller lock on every 120 Hz callback.
        observeAdaptiveFrameCadence()
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
        let source = makePendingSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            sourceDisplayTime: sourceDisplayTime
        )
        // Both observers run before handing the source to the encoder so an
        // activity callback after idle can restore a lowered target before
        // this first frame reaches the pacer. Neither observer synthesizes an
        // idle frame.
        admitPendingSource(source)
    }

    /// Applies the metadata-driven target on the encoder queue. A missing or
    /// malformed attachment is fail-open in the Rust controller and therefore
    /// leaves the negotiated target unchanged.
    func observeUnchangedContentCadence(
        signal: LumenUnchangedContentCadenceController.Signal
    ) {
        let pipelineStable = videoBootstrapAdmission.isOpen
        guard !stopping else {
            return
        }
        if pipelineStable,
           unchangedContentTargetFrameRate <= 2,
           signal == .idle || signal == .unchanged {
            return
        }
        guard let controller = unchangedContentCadenceController else {
            return
        }
        let decision = controller.observe(
            monotonicTimeSeconds: ProcessInfo.processInfo.systemUptime,
            signal: signal,
            pipelineStable: pipelineStable
        )
        guard let decision else {
            return
        }
        unchangedContentTargetFrameRate = decision.targetFrameRate
        _ = unchangedContentIngressPacer.configure(
            targetFrameRate: decision.targetFrameRate
        )
        guard decision.changed else {
            return
        }
        scheduleAdaptiveFrameCadenceTargetUpdate()
    }

    /// Wakes unchanged-content cadence after a validated reliable host input
    /// or motion event. This only changes the source pacer target; it does not
    /// request a key frame or reset decoder/configuration generation.
    @discardableResult
    func wakeUnchangedContentCadence(sessionEpoch: UInt32) -> Bool {
        guard Self.isCurrentSessionEpoch(
            requested: sessionEpoch,
            active: configuration.sessionEpoch
        ) else {
            Self.startupLogger.notice(
                "Ignoring stale unchanged-content cadence wake session-epoch=\(sessionEpoch, privacy: .public) active-session-epoch=\(self.configuration.sessionEpoch, privacy: .public)"
            )
            return false
        }
        queue.async { [weak self] in
            guard let self,
                  !self.stopping,
                  let controller = self.unchangedContentCadenceController,
                  let decision = controller.wake(
                      monotonicTimeSeconds: ProcessInfo.processInfo.systemUptime
                  ) else {
                return
            }
            self.unchangedContentTargetFrameRate = decision.targetFrameRate
            _ = self.unchangedContentIngressPacer.configure(
                targetFrameRate: decision.targetFrameRate
            )
            if decision.changed {
                self.scheduleAdaptiveFrameCadenceTargetUpdate()
            }
        }
        return true
    }

    static func isCurrentSessionEpoch(
        requested: UInt32,
        active: UInt32
    ) -> Bool {
        requested == active
    }

    func scheduleAdaptiveFrameCadenceTargetUpdate() {
        encoderQueue.async { [weak self] in
            guard let self else {
                return
            }
            // Read both thread-safe Rust targets at the point of application,
            // not when this closure is enqueued. A wake/content callback that
            // races an older queued update therefore cannot reapply a stale
            // target pair after this serial encoder boundary.
            let engineTargetFrameRate = self.adaptiveFrameCadenceController?
                .targetFrameRate
                ?? self.configuration.effectiveTargetFrameRate
            let contentTargetFrameRate = self.unchangedContentCadenceController?
                .targetFrameRate
                ?? self.configuration.effectiveTargetFrameRate
            guard self.adaptiveVideoDeliveryPolicy.setTargetFrameRates(
                engineTargetFrameRate: engineTargetFrameRate,
                contentTargetFrameRate: contentTargetFrameRate
            ) else {
                return
            }
            let effectiveTargetFrameRate =
                self.adaptiveVideoDeliveryPolicy.targetFrameRate
            self.queue.async { [weak self] in
                guard let self else { return }
                self.statistics.adaptiveTargetFrameRate =
                    effectiveTargetFrameRate
                self.publishStatistics(reason: .immediate)
            }
        }
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
        scheduleAdaptiveFrameCadenceTargetUpdate()
    }

    func unchangedContentCadenceSignal(
        for sampleBuffer: CMSampleBuffer
    ) -> LumenUnchangedContentCadenceController.Signal {
        guard let attachments = screenFrameAttachments(sampleBuffer),
              let value = attachments[.status] as? NSNumber,
              let status = SCFrameStatus(rawValue: value.intValue) else {
            return .unknown
        }
        let dirtyRectCount: Int?
        if status == .complete {
            if let dirtyRects = attachments[.dirtyRects] as? [NSValue] {
                dirtyRectCount = dirtyRects.count
            } else {
                dirtyRectCount = nil
            }
        } else {
            dirtyRectCount = nil
        }
        return Self.unchangedContentCadenceSignal(
            status: status,
            dirtyRectCount: dirtyRectCount
        )
    }

    /// Pure metadata classification kept separate from CMSampleBuffer access
    /// so malformed/missing ScreenCaptureKit attachments can be tested without
    /// constructing a pixel buffer. Unknown states always fail open.
    static func unchangedContentCadenceSignal(
        status: SCFrameStatus?,
        dirtyRectCount: Int?
    ) -> LumenUnchangedContentCadenceController.Signal {
        guard let status else {
            return .unknown
        }
        switch status {
        case .idle:
            return .idle
        case .complete:
            guard let dirtyRectCount,
                  dirtyRectCount >= 0 else {
                return .unknown
            }
            return dirtyRectCount == 0 ? .unchanged : .changed
        default:
            return .unknown
        }
    }

    func screenFrameAttachments(
        _ sampleBuffer: CMSampleBuffer
    ) -> [SCStreamFrameInfo: Any]? {
        (CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]])?.first
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
            publishStatistics(reason: .terminal)
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
    }

    func makePendingSource(
        imageBuffer: CVImageBuffer,
        presentationTime: CMTime,
        sourceDisplayTime: UInt64,
        sourceSurfaceLease: LumenMacSkyLightDisplayStreamFrameLease? = nil
    ) -> LumenPendingVideoBootstrapSource {
        sequenceNumber &+= 1
        return LumenPendingVideoBootstrapSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            displayTime: sourceDisplayTime,
            duration: CMTime(
                seconds: LumenAdaptiveVideoFrameTiming
                    .fallbackDurationSeconds(
                        targetFrameRate: configuration.effectiveTargetFrameRate
                    ),
                preferredTimescale: LumenAdaptiveVideoFrameTiming.preferredTimescale
            ),
            sequenceNumber: sequenceNumber,
            sourceSurfaceLease: sourceSurfaceLease,
            hasValidatedEncoderOrdering: false
        )
    }

    func makePendingSource(
        imageBuffer: CVImageBuffer,
        displayTime: UInt64,
        sourceMachTime _: UInt64,
        sourceSurfaceLease: LumenMacSkyLightDisplayStreamFrameLease? = nil
    ) -> LumenPendingVideoBootstrapSource {
        let presentationTime = resolvedSkyLightPresentationTime(
            displayTime: displayTime
        )
        return makePendingSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            sourceDisplayTime: displayTime,
            sourceSurfaceLease: sourceSurfaceLease
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
        sampleBuffer: CMSampleBuffer?
    ) {
        guard statistics.exactCaptureAudit.inputFourCC == nil else {
            return
        }
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
        let extensions = sampleBuffer?.formatDescription.flatMap {
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

    func logScreenFrameGeometryIfNeeded(
        _ sampleBuffer: CMSampleBuffer,
        imageBuffer: CVImageBuffer
    ) {
        guard !didLogScreenFrameGeometry else { return }
        didLogScreenFrameGeometry = true
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachment = attachmentArray.first else {
            Self.startupLogger.notice(
                "stage=first-frame-geometry attachments=missing"
            )
            return
        }
        let rawContentRect = attachment[.contentRect]
        let contentRect = LumenScreenCaptureGeometry.contentRect(
            from: rawContentRect
        )
        let contentScale = (attachment[.contentScale] as? NSNumber)?.doubleValue
        let scaleFactor = (attachment[.scaleFactor] as? NSNumber)?.doubleValue
        let rectDescription = contentRect.map {
            "\($0.origin.x),\($0.origin.y),\($0.size.width)x\($0.size.height)"
        } ?? "missing"
        let contentScaleDescription = contentScale.map {
            String(describing: $0)
        } ?? "missing"
        let scaleFactorDescription = scaleFactor.map {
            String(describing: $0)
        } ?? "missing"
        Self.startupLogger.notice(
            "stage=first-frame-geometry content-rect=\(rectDescription, privacy: .public) content-scale=\(contentScaleDescription, privacy: .public) scale-factor=\(scaleFactorDescription, privacy: .public) surface=\(CVPixelBufferGetWidth(imageBuffer), privacy: .public)x\(CVPixelBufferGetHeight(imageBuffer), privacy: .public)"
        )
        let attachmentKeys = attachment.keys
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let rawContentRectType = rawContentRect.map {
            String(reflecting: type(of: $0))
        } ?? "missing"
        let rawContentRectDescription = rawContentRect.map {
            String(reflecting: $0)
        } ?? "missing"
        Self.startupLogger.notice(
            "stage=first-frame-attachments keys=\(attachmentKeys, privacy: .public) content-rect-type=\(rawContentRectType, privacy: .public) content-rect-raw=\(rawContentRectDescription, privacy: .public)"
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

    func resolvedSkyLightPresentationTime(displayTime: UInt64) -> CMTime {
        let fallbackStep = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.effectiveTargetFrameRate)
        )

        guard let firstDisplayTime = skyLightFirstDisplayTime else {
            skyLightFirstDisplayTime = displayTime
            let firstPresentationTime = CMTime.zero
            skyLightLastPresentationTime = firstPresentationTime
            return firstPresentationTime
        }

        let actualPresentationTime = LumenMachTime.relativeTime(
            from: firstDisplayTime,
            to: displayTime
        )
        let presentationTime: CMTime
        if let lastPresentationTime = skyLightLastPresentationTime,
           !actualPresentationTime.isValid ||
            CMTimeCompare(actualPresentationTime, lastPresentationTime) <= 0 {
            presentationTime = CMTimeAdd(lastPresentationTime, fallbackStep)
        } else {
            presentationTime = actualPresentationTime
        }
        skyLightLastPresentationTime = presentationTime
        return presentationTime
    }
}
