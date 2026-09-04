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

struct LumenAdaptiveVideoAdmissionCadence: Equatable, Sendable {
    private(set) var divisor = 1
    private var admissionsUntilNext = 0

    mutating func configure(divisor: Int) -> Bool {
        guard (1 ... 4).contains(divisor) else { return false }
        self.divisor = divisor
        admissionsUntilNext = 0
        return true
    }

    mutating func shouldAdmit() -> Bool {
        guard divisor > 1 else { return true }
        guard admissionsUntilNext > 0 else {
            admissionsUntilNext = divisor - 1
            return true
        }
        admissionsUntilNext -= 1
        return false
    }
}

struct LumenAdaptiveVideoDeliveryPolicyState: Equatable, Sendable {
    private(set) var appliedBitrateKbps: Int?
    private(set) var admissionCadence = LumenAdaptiveVideoAdmissionCadence()
    private(set) var acceptsUpdates = false

    var admissionDivisor: Int { admissionCadence.divisor }

    mutating func beginRunning(bitrateKbps: Int) {
        appliedBitrateKbps = bitrateKbps
        admissionCadence = LumenAdaptiveVideoAdmissionCadence()
        acceptsUpdates = true
    }

    mutating func beginStopping() {
        acceptsUpdates = false
    }

    mutating func apply(
        bitrateKbps: Int,
        admissionDivisor: Int,
        applyBitrate: () throws -> Void
    ) -> Bool {
        guard acceptsUpdates,
              bitrateKbps > 0,
              (1 ... 4).contains(admissionDivisor) else {
            return false
        }
        do {
            if appliedBitrateKbps != bitrateKbps {
                try applyBitrate()
            }
            guard admissionCadence.configure(divisor: admissionDivisor) else {
                return false
            }
            appliedBitrateKbps = bitrateKbps
            return true
        } catch {
            return false
        }
    }

    mutating func shouldAdmit(forceKeyFrame: Bool) -> Bool {
        forceKeyFrame || (acceptsUpdates && admissionCadence.shouldAdmit())
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

        // CGDisplayStream's IOSurface is only callback-owned by default. Take
        // a retained surface/use-count lease before handing the pixel buffer
        // to the asynchronous VideoToolbox admission path; the lease is then
        // carried by LumenEncodedFrameContext until output or cancellation.
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

        if let mismatch = sourceContract?.mismatchDescription(
            for: pixelBuffer
        ) {
            reportTerminalContractFailure(
                .sourceContractMismatch(mismatch),
                sourceDisplayTime: displayTime
            )
            return
        }
        recordSourceAudit(
            imageBuffer: pixelBuffer,
            sampleBuffer: nil
        )
        statistics.completeSourceFrameCount &+= 1

        let source = makePendingSource(
            imageBuffer: pixelBuffer,
            displayTime: displayTime,
            sourceMachTime: callbackEntryMachTime,
            sourceSurfaceLease: sourceSurfaceLease
        )
        admitPendingSource(source)
    }

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
              let imageBuffer = sampleBuffer.imageBuffer,
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
            logScreenFrameGeometryIfNeeded(
                sampleBuffer,
                imageBuffer: imageBuffer
            )
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
        admitPendingSource(source)
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
    }

    func makePendingSource(
        imageBuffer: CVImageBuffer,
        sampleBuffer: CMSampleBuffer,
        sourceMachTime: UInt64
    ) -> LumenPendingVideoBootstrapSource {
        sequenceNumber &+= 1
        let presentationTime = resolvedPresentationTime(sampleBuffer)
        return makePendingSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            displayTime: LumenMachTime.ticks(for: presentationTime)
                ?? sourceMachTime
        )
    }

    func makePendingSource(
        imageBuffer: CVImageBuffer,
        displayTime: UInt64,
        sourceMachTime _: UInt64,
        sourceSurfaceLease: LumenMacSkyLightDisplayStreamFrameLease? = nil
    ) -> LumenPendingVideoBootstrapSource {
        sequenceNumber &+= 1
        let presentationTime = resolvedSkyLightPresentationTime(
            displayTime: displayTime
        )
        return makePendingSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            displayTime: displayTime,
            sourceSurfaceLease: sourceSurfaceLease
        )
    }

    func makePendingSource(
        imageBuffer: CVImageBuffer,
        presentationTime: CMTime,
        displayTime: UInt64,
        sourceSurfaceLease: LumenMacSkyLightDisplayStreamFrameLease? = nil
    ) -> LumenPendingVideoBootstrapSource {
        return LumenPendingVideoBootstrapSource(
            imageBuffer: imageBuffer,
            presentationTime: presentationTime,
            displayTime: displayTime,
            duration: CMTime(
                value: 1,
                timescale: CMTimeScale(
                    configuration.effectiveTargetFrameRate
                )
            ),
            sequenceNumber: sequenceNumber,
            sourceSurfaceLease: sourceSurfaceLease
        )
    }

    func admitPendingSource(_ source: LumenPendingVideoBootstrapSource) {
        switch videoBootstrapAdmission.admitSourceFrame() {
        case .submitInitialKeyFrame:
            if !submitSource(source, forceKeyFrame: true) {
                videoBootstrapAdmission.cancelBootstrapSubmission()
            }
        case .coalesceUntilAcknowledged:
            pendingVideoBootstrapSource = source
            statistics.pendingAdmissionDropCount &+= 1
            refreshStatisticsNotesIfNeeded()
        case .submit:
            submitSource(source, forceKeyFrame: false)
        }
    }

    func recordSourceAudit(
        imageBuffer: CVImageBuffer,
        sampleBuffer: CMSampleBuffer?
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
