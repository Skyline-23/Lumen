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
                value: 1,
                timescale: CMTimeScale(
                    configuration.effectiveTargetFrameRate
                )
            ),
            sequenceNumber: sequenceNumber
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
            if shouldAdmitAdaptiveSource() {
                submitSource(source, forceKeyFrame: false)
            } else {
                recordPendingAdmissionDrop(source)
            }
        }
    }

    func shouldAdmitAdaptiveSource() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return adaptiveAdmissionCadence.shouldAdmit()
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
