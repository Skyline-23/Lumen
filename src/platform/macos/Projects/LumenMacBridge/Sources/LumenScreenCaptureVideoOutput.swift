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
    func didEncode(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        context: LumenEncodedFrameContext,
        rawCallbackMachTime: UInt64
    ) {
        let outputServiceStartedMachTime = beginEncodedOutput(
            context: context,
            rawCallbackMachTime: rawCallbackMachTime
        )
        defer {
            finishEncodedOutput(startedAt: outputServiceStartedMachTime)
        }
        inflightFrameCount = max(inflightFrameCount - 1, 0)

        guard let sampleBuffer = validatedCompressionOutput(
            status: status,
            infoFlags: infoFlags,
            sampleBuffer: sampleBuffer,
            context: context
        ) else {
            return
        }
        let configurationData = exactCodecConfigurationData(from: sampleBuffer)
        guard acceptEncodedOutputContract(
            configurationData: configurationData,
            context: context
        ) else {
            return
        }
        recordCodecConfigurationAudit(configurationData)
        statisticsHandler(statistics)

        let latency = recordSuccessfulOutput(
            context: context,
            sampleBuffer: sampleBuffer
        )
        let isKeyFrame = isKeyFrame(sampleBuffer)
        guard acceptRequiredKeyFrame(isKeyFrame, context: context) else {
            return
        }
        encoderAdmission.resumePendingIfPossible()
        deliverEncodedFrame(
            sampleBuffer,
            context: context,
            latency: latency,
            isKeyFrame: isKeyFrame
        )
    }

    func beginEncodedOutput(
        context: LumenEncodedFrameContext,
        rawCallbackMachTime: UInt64
    ) -> UInt64 {
        let startedAt = mach_absolute_time()
        videoToolboxCallbackTiming.observe(
            LumenMachTime.milliseconds(
                from: context.submissionMachTime,
                to: rawCallbackMachTime
            )
        )
        outputOwnerQueueWaitTiming.observe(
            LumenMachTime.milliseconds(
                from: rawCallbackMachTime,
                to: startedAt
            )
        )
        return startedAt
    }

    func finishEncodedOutput(startedAt: UInt64) {
        outputServiceTiming.observe(
            LumenMachTime.milliseconds(
                from: startedAt,
                to: mach_absolute_time()
            )
        )
    }

    func validatedCompressionOutput(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        context: LumenEncodedFrameContext
    ) -> CMSampleBuffer? {
        guard status == noErr,
              !infoFlags.contains(.frameDropped),
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            recordDroppedCompressionOutput(status: status, context: context)
            return nil
        }
        return sampleBuffer
    }

    func recordDroppedCompressionOutput(
        status: OSStatus,
        context: LumenEncodedFrameContext
    ) {
        if context.requiresBootstrapAcknowledgement {
            videoBootstrapAdmission.cancelBootstrapSubmission()
            pendingVideoBootstrapSource = nil
        }
        statistics.droppedFrameCount &+= 1
        statistics.lastErrorDescription = status == noErr
            ? "VideoToolbox dropped frame"
            : "VideoToolbox callback OSStatus \(status)"
        statisticsHandler(statistics)
        eventHandler(.init(
            kind: .droppedFrame,
            message: statistics.lastErrorDescription,
            stopStatus: status,
            sourceDisplayTime: context.displayTime
        ))
        encoderAdmission.resumePendingIfPossible()
    }

    func acceptEncodedOutputContract(
        configurationData: Data?,
        context: LumenEncodedFrameContext
    ) -> Bool {
        guard let mismatch = outputContract?.mismatchDescription(
            codecConfigurationData: configurationData
        ) else {
            return true
        }
        reportTerminalContractFailure(
            .encodedOutputContractMismatch(mismatch),
            sourceDisplayTime: context.displayTime
        )
        return false
    }

    func recordCodecConfigurationAudit(_ configurationData: Data?) {
        switch configuration.codec {
        case .h264:
            let parsed = configurationData.flatMap(
                LumenVideoToolboxCodecConfigurationParser.parseAVCC
            )
            statistics.exactCaptureAudit.configurationAtom = "avcC"
            statistics.exactCaptureAudit.profileIdc = parsed?.profileIdc
        case .hevc:
            let parsed = configurationData.flatMap(
                LumenVideoToolboxCodecConfigurationParser.parseHVCC
            )
            statistics.exactCaptureAudit.configurationAtom = "hvcC"
            statistics.exactCaptureAudit.chromaFormatIdc = parsed?.chromaFormatIdc
            statistics.exactCaptureAudit.lumaBitDepth = parsed?.lumaBitDepth
            statistics.exactCaptureAudit.chromaBitDepth = parsed?.chromaBitDepth
        }
    }

    func recordSuccessfulOutput(
        context: LumenEncodedFrameContext,
        sampleBuffer: CMSampleBuffer
    ) -> Double {
        let latency = LumenMachTime.milliseconds(
            from: context.submissionMachTime,
            to: mach_absolute_time()
        )
        statistics.emittedFrameCount &+= 1
        encodedBitrateTelemetry.observe(
            encodedByteCount: CMSampleBufferGetTotalSampleSize(sampleBuffer),
            atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        statistics.encodedByteCount =
            encodedBitrateTelemetry.totalEncodedBytes
        statistics.estimatedOutputBitrateKbps =
            encodedBitrateTelemetry.latestWindowBitrateKbps
        statistics.minOutputCallbackLatencyMilliseconds = min(
            statistics.minOutputCallbackLatencyMilliseconds ?? latency,
            latency
        )
        statistics.maxOutputCallbackLatencyMilliseconds = max(
            statistics.maxOutputCallbackLatencyMilliseconds ?? latency,
            latency
        )
        refreshStatisticsNotesIfNeeded()
        return latency
    }

    func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        return (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    func acceptRequiredKeyFrame(
        _ isKeyFrame: Bool,
        context: LumenEncodedFrameContext
    ) -> Bool {
        if context.requiresBootstrapAcknowledgement, !isKeyFrame {
            videoBootstrapAdmission.cancelBootstrapSubmission()
            pendingVideoBootstrapSource = nil
            reportTerminalContractFailure(
                .requiredKeyFrameNotProduced,
                sourceDisplayTime: context.displayTime
            )
            return false
        }
        return true
    }

    func deliverEncodedFrame(
        _ sampleBuffer: CMSampleBuffer,
        context: LumenEncodedFrameContext,
        latency: Double,
        isKeyFrame: Bool
    ) {
        let hdr = configuration.encodedColorConfiguration
        let formatExtensions = sampleBuffer.formatDescription.flatMap {
            CMFormatDescriptionGetExtensions($0) as? [String: Any]
        }
        let frameHandlerStartedMachTime = mach_absolute_time()
        frameHandler(
            LumenEncodedFrame(
                sampleBuffer: sampleBuffer,
                codec: configuration.codec,
                sourceSequenceNumber: context.sequenceNumber,
                sourceDisplayTime: context.displayTime,
                outputCallbackLatencyMilliseconds: latency,
                isKeyFrame: isKeyFrame,
                requiresBootstrapAcknowledgement: context.requiresBootstrapAcknowledgement,
                isRepairKeyFrame: context.requiresBootstrapAcknowledgement,
                isHDRSignaled: hdr.map { $0.transferFunction != .ituR709 } ?? false,
                hdrValidationReport: makeHDRValidationReport(
                    formatExtensions: formatExtensions,
                    configuration: hdr
                )
            )
        )
        frameHandlerTiming.observe(
            LumenMachTime.milliseconds(
                from: frameHandlerStartedMachTime,
                to: mach_absolute_time()
            )
        )
    }

    func makeHDRValidationReport(
        formatExtensions: [String: Any]?,
        configuration: LumenVideoHDRConfiguration?
    ) -> LumenHDRValidationReport {
        LumenHDRValidationReport(
            colorPrimaries: formatExtensions?[
                kCMFormatDescriptionExtension_ColorPrimaries as String
            ] as? String ?? configuration?.colorPrimaries.rawValue,
            transferFunction: formatExtensions?[
                kCMFormatDescriptionExtension_TransferFunction as String
            ] as? String ?? configuration?.transferFunction.rawValue,
            yCbCrMatrix: formatExtensions?[
                kCMFormatDescriptionExtension_YCbCrMatrix as String
            ] as? String ?? configuration?.yCbCrMatrix.rawValue,
            hasHDRDisplayMetadata: formatExtensions?[
                kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String
            ] != nil,
            hasContentLightLevelInfo: formatExtensions?[
                kCMFormatDescriptionExtension_ContentLightLevelInfo as String
            ] != nil
        )
    }
}
