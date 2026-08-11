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

extension LumenScreenCaptureVideoRuntime {
    @discardableResult
    func submitSource(
        _ source: LumenPendingVideoBootstrapSource,
        bootstrapReason: LumenVideoBootstrapReason?
    ) -> Bool {
        guard !stopping else {
            return false
        }
        guard compressionSessionAvailable else {
            reportTerminalContractFailure(
                .invalidFormat(
                    "VideoToolbox compression session is unavailable"
                ),
                sourceDisplayTime: source.displayTime
            )
            return false
        }

        guard validateEncoderSourceOrdering(source) else {
            return false
        }

        sourceColorContractStatus = "verified"
        let submission = LumenVideoEncoderSubmission(
            source: source,
            forceKeyFrame: bootstrapReason != nil,
            bootstrapReason: bootstrapReason,
            mediaEpoch: mediaEpoch,
            offeredMachTime: mach_absolute_time()
        )
        if let replacedSubmission = encoderAdmission.offer(submission) {
            recordPendingAdmissionDrop(replacedSubmission.source)
        }
        return true
    }

    func validateEncoderSourceOrdering(
        _ source: LumenPendingVideoBootstrapSource
    ) -> Bool {
        if let lastQueuedEncoderSequenceNumber,
           source.sequenceNumber <= lastQueuedEncoderSequenceNumber {
            let message = [
                "VideoToolbox source sequence must increase",
                "previous=\(lastQueuedEncoderSequenceNumber)",
                "current=\(source.sequenceNumber)"
            ].joined(separator: " ")
            reportTerminalContractFailure(
                .invalidFormat(message),
                sourceDisplayTime: source.displayTime
            )
            return false
        }
        if let lastQueuedEncoderPresentationTime,
           CMTimeCompare(
               source.presentationTime,
               lastQueuedEncoderPresentationTime
           ) <= 0 {
            let previous = lastQueuedEncoderPresentationTime
            let current = source.presentationTime
            let message = [
                "VideoToolbox presentation timestamp must increase",
                "previous=\(previous.value)/\(previous.timescale)",
                "current=\(current.value)/\(current.timescale)"
            ].joined(separator: " ")
            reportTerminalContractFailure(
                .invalidFormat(message),
                sourceDisplayTime: source.displayTime
            )
            return false
        }
        lastQueuedEncoderSequenceNumber = source.sequenceNumber
        lastQueuedEncoderPresentationTime = source.presentationTime
        return true
    }

    func willSubmitToVideoToolbox(_ submission: LumenVideoEncoderSubmission) {
        let source = submission.source
        let submissionMachTime = mach_absolute_time()
        encoderAdmissionWaitTiming.observe(
            LumenMachTime.milliseconds(
                from: submission.offeredMachTime,
                to: submissionMachTime
            )
        )
        outputLifecycle.registerSubmission(
            id: source.sequenceNumber,
            context: .init(
                sequenceNumber: source.sequenceNumber,
                displayTime: source.displayTime,
                submissionMachTime: submissionMachTime,
                mediaEpoch: submission.mediaEpoch,
                bootstrapReason: submission.bootstrapReason
            )
        )
        inflightFrameCount += 1
        statistics.maximumInflightFrameCount = max(
            statistics.maximumInflightFrameCount,
            inflightFrameCount
        )
    }

    func submitToVideoToolbox(
        _ submission: LumenVideoEncoderSubmission,
        entered: @Sendable () -> Bool
    ) -> LumenEncoderSubmissionAttempt<LumenVideoEncoderSubmissionResult> {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        let admission = adaptiveVideoDeliveryPolicy.admit(
            sourcePresentationTime: submission.source.presentationTime,
            forceKeyFrame: submission.forceKeyFrame
        )
        guard case .admit(let durationSeconds) = admission else {
            queue.async { [weak self] in
                guard let self else { return }
                switch admission {
                case .drop:
                    self.recordIntentionalFrameCadenceDrop(submission.source)
                case .admit:
                    break
                }
            }
            return .cancelled
        }
        guard let compressionSession else {
            guard entered() else {
                return .cancelled
            }
            return .submitted(.init(
                status: kVTInvalidSessionErr,
                infoFlags: [],
                invocationMilliseconds: 0
            ))
        }

        let source = submission.source
        let properties = submission.bootstrapReason != nil
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        guard entered() else {
            return .cancelled
        }
        var infoFlags: VTEncodeInfoFlags = []
        let invocationStartedMachTime = mach_absolute_time()
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: source.imageBuffer,
            presentationTimeStamp: source.presentationTime,
            duration: LumenAdaptiveVideoFrameTiming.cmTime(
                seconds: durationSeconds
            ),
            frameProperties: properties,
            sourceFrameRefcon: UnsafeMutableRawPointer(
                bitPattern: UInt(source.sequenceNumber)
            ),
            infoFlagsOut: &infoFlags
        )
        return .submitted(.init(
            status: status,
            infoFlags: infoFlags,
            invocationMilliseconds: LumenMachTime.milliseconds(
                from: invocationStartedMachTime,
                to: mach_absolute_time()
            )
        ))
    }

    func didSubmitToVideoToolbox(
        _ submission: LumenVideoEncoderSubmission,
        result: LumenVideoEncoderSubmissionResult
    ) {
        encoderInvocationTiming.observe(result.invocationMilliseconds)
        guard submission.mediaEpoch == mediaEpoch else {
            if result.status != noErr || result.infoFlags.contains(.frameDropped),
               outputLifecycle.cancelSubmission(id: submission.source.sequenceNumber) != nil {
                inflightFrameCount = max(inflightFrameCount - 1, 0)
            }
            return
        }
        if result.status != noErr {
            if outputLifecycle.cancelSubmission(
                id: submission.source.sequenceNumber
            ) != nil {
                inflightFrameCount = max(inflightFrameCount - 1, 0)
            }
            if submission.bootstrapReason != nil {
                videoBootstrapAdmission.cancelBootstrapSubmission()
                pendingVideoBootstrapSource = nil
            }
            statistics.processingFailureCount &+= 1
            statistics.lastErrorDescription = "VTCompressionSessionEncodeFrame failed with OSStatus \(result.status)"
            publishStatistics(reason: .terminal)
            eventHandler(.init(
                kind: .failed,
                message: statistics.lastErrorDescription,
                stopStatus: result.status,
                sourceDisplayTime: submission.source.displayTime
            ))
        } else if result.infoFlags.contains(.frameDropped) {
            if outputLifecycle.cancelSubmission(
                id: submission.source.sequenceNumber
            ) != nil {
                inflightFrameCount = max(inflightFrameCount - 1, 0)
            }
            if submission.bootstrapReason != nil {
                _ = videoBootstrapAdmission.retryBootstrapSubmission()
                pendingVideoBootstrapSource = nil
            }
            let sourceDisplayTime = submission.source.displayTime
            queue.async { [weak self] in
                self?.recordVideoToolboxDrop(
                    sourceDisplayTime: sourceDisplayTime,
                    message: "VideoToolbox dropped frame during synchronous admission"
                )
            }
        } else {
            statistics.submittedFrameCount &+= 1
            refreshStatisticsNotesIfNeeded()
        }
    }

    func recordPendingAdmissionDrop(_ source: LumenPendingVideoBootstrapSource) {
        statistics.droppedFrameCount &+= 1
        statistics.pendingAdmissionDropCount &+= 1
        encoderPendingDropCount &+= 1
        refreshStatisticsNotesIfNeeded()
        if statistics.pendingAdmissionDropCount == 1 || statistics.pendingAdmissionDropCount % 120 == 0 {
            eventHandler(.init(
                kind: .coalescedFrame,
                message: "Dropped fresh ScreenCaptureKit frame before VT admission to cap pending latency",
                sourceDisplayTime: source.displayTime
            ))
        }
    }

    func recordIntentionalFrameCadenceDrop(
        _ source: LumenPendingVideoBootstrapSource
    ) {
        statistics.droppedFrameCount &+= 1
        statistics.intentionalFrameCadenceDropCount &+= 1
        refreshStatisticsNotesIfNeeded()
        if statistics.intentionalFrameCadenceDropCount == 1
            || statistics.intentionalFrameCadenceDropCount % 120 == 0 {
            eventHandler(.init(
                kind: .coalescedFrame,
                message: "Dropped source frame intentionally to follow adaptive target cadence",
                sourceDisplayTime: source.displayTime
            ))
        }
    }

    func recordVideoToolboxDrop(
        _ source: LumenPendingVideoBootstrapSource,
        message: String
    ) {
        recordVideoToolboxDrop(
            sourceDisplayTime: source.displayTime,
            message: message
        )
    }

    func recordVideoToolboxDrop(
        sourceDisplayTime: UInt64,
        message: String
    ) {
        statistics.droppedFrameCount &+= 1
        statistics.pendingAdmissionDropCount &+= 1
        encoderPendingDropCount &+= 1
        statistics.lastErrorDescription = message
        let publicationUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        publishStatistics(
            reason: .highRateUpdate,
            rebuildingNotes: false,
            atUptimeNanoseconds: publicationUptimeNanoseconds
        )
        guard dropEventPublicationPolicy.shouldPublish(
            reason: .highRateUpdate,
            atUptimeNanoseconds: publicationUptimeNanoseconds
        ) else {
            return
        }
        eventHandler(.init(
            kind: .droppedFrame,
            message: message,
            sourceDisplayTime: sourceDisplayTime
        ))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.statistics.isRunning = false
            self.statistics.lastErrorDescription = error.localizedDescription
            self.publishStatistics(reason: .terminal)
            self.eventHandler(.init(kind: .failed, message: error.localizedDescription))
            self.terminationHandler(error)
        }
    }

    func beginSourceCallback(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
        let callbackEntryMachTime = mach_absolute_time()
        captureIngressTimings.observe(
            displayedMachTime: screenFrameDisplayTime(sampleBuffer),
            callbackMachTime: callbackEntryMachTime
        )
        return callbackEntryMachTime
    }

    func finishSourceCallback(startedAt callbackEntryMachTime: UInt64) {
        sourceCallbackServiceTiming.observe(
            LumenMachTime.milliseconds(
                from: callbackEntryMachTime,
                to: mach_absolute_time()
            )
        )
    }

    func screenFrameDisplayTime(_ sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let displayTime = attachments.first?[.displayTime] as? NSNumber else {
            return nil
        }
        return displayTime.uint64Value
    }

    func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let status = attachments.first?[.status] as? NSNumber else {
            return true
        }
        return status.intValue == SCFrameStatus.complete.rawValue
    }

    var capturePixelFormat: OSType {
        encodingPlan?.pixelFormat ?? configuration.directCapturePixelFormat
    }

    func sourceColorContractMismatch(for imageBuffer: CVImageBuffer) -> String? {
        guard let color = configuration.encodedColorConfiguration,
              color.transferFunction != .ituR709 else {
            sourceColorContractStatus = "not-required"
            return nil
        }

        let contract = LumenCaptureColorContract(pixelFormat: capturePixelFormat, color: color)
        if let mismatch = contract.mismatchDescription(for: imageBuffer) {
            return mismatch
        }
        sourceColorContractStatus = "verified"
        return nil
    }

}
