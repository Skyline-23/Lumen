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
    func makeStatisticsNotes(width: Int, height: Int) -> [String] {
        let utilization = LumenCapturePipelineUtilization(
            statistics: statistics
        )
        let sourceApproxFrameRate = averageFrameRate(
            intervalTotalMilliseconds: sourceIntervalTotalMilliseconds,
            sampleCount: sourceIntervalSampleCount
        )
        let outputApproxFrameRate = averageFrameRate(
            intervalTotalMilliseconds: outputIntervalTotalMilliseconds,
            sampleCount: outputIntervalSampleCount
        )
        var notes = [
            "captureBackend=screen-capture-kit",
            "screenCaptureOutputRegistrationStage=\(outputOwnership.stage.rawValue)",
            "screenCaptureDisplayAdmissionMode=\(displayAdmissionMode.rawValue)",
            "screenCaptureDisplayAdmissionMilliseconds=\(displayAdmissionDurationMilliseconds)",
            "screenCaptureStreamStartMilliseconds=\(streamStartDurationMilliseconds)",
            "screenCaptureOwnedSampleCount=\(outputOwnership.screenSampleCount)",
            "sourceCaptureSampleCount=\(statistics.sourceFrameCount)",
            "screenCaptureCompleteFrameCount=\(statistics.completeSourceFrameCount)",
            "screenCaptureIncompleteFrameCount=\(statistics.incompleteSourceFrameCount)",
            "sourceApproxFrameRate=\(sourceApproxFrameRate)",
            "sourceCallbackApproxFrameRate=\(sourceApproxFrameRate)",
            "videoToolboxTargetFrameRateHint=\(configuration.effectiveTargetFrameRate)",
            "videoToolboxEncoderInputPixelFormat=\(capturePixelFormat)",
            "videoToolboxSourcePixelFormat=\(capturePixelFormat)",
            "sourceColorContract=\(sourceColorContractStatus)",
            "videoToolboxStagingMode=direct-cvpixelbuffer",
            "videoToolboxAdmissionMode=serial-offloaded-latest",
            "videoToolboxPendingSourceBound=1",
            "videoToolboxConversionCount=0",
            "videoToolboxProfile=\(encodingPlan?.profile ?? "unresolved")",
            "videoToolboxHardwareRequired=true",
            "videoToolboxAllowOpenGOP=\(statistics.exactCaptureAudit.allowOpenGOP.map { String($0) } ?? "n/a")",
            "videoToolboxConfiguredSourceFrameCount=\(width)x\(height)",
            "videoToolboxSubmittedFrameCount=\(statistics.submittedFrameCount)",
            "videoToolboxAdmissionUtilizationPercent=\(formattedPercent(utilization.videoToolboxAdmissionPercent))",
            "videoToolboxOutputUtilizationPercent=\(formattedPercent(utilization.videoToolboxOutputPercent))",
            "videoToolboxPendingAdmissionDropCount=\(statistics.pendingAdmissionDropCount)",
            "videoToolboxBootstrapGateOpen=\(videoBootstrapAdmission.isOpen)",
            "videoToolboxBootstrapPendingSource=\(pendingVideoBootstrapSource != nil)",
            "videoToolboxCurrentInflightStagingSlots=\(inflightFrameCount)",
            "videoToolboxMaxInflightStagingSlots=\(statistics.maximumInflightFrameCount)",
            "videoToolboxOutputApproxFrameRate=\(outputApproxFrameRate)"
        ]
        notes.append(contentsOf: captureStageTimingNotes())
        return notes
    }

    static func identity(of stream: SCStream) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(stream).toOpaque())
    }

    static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func captureStageTimingNotes() -> [String] {
        captureIngressTimings.diagnosticNotes
            + lumenCaptureTimingNotes(
                prefix: "sourceCallbackService",
                timing: sourceCallbackServiceTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxAdmissionWait",
                timing: encoderAdmissionWaitTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxEncodeInvocation",
                timing: encoderInvocationTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxEncodeToCallback",
                timing: videoToolboxCallbackTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxOutputOwnerQueueWait",
                timing: outputOwnerQueueWaitTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxOutputService",
                timing: outputServiceTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxFrameHandler",
                timing: frameHandlerTiming
            )
    }

    func refreshStatisticsNotesIfNeeded() {
        if statistics.sourceFrameCount == 1
            || statistics.sourceFrameCount % 120 == 0 {
            refreshStatisticsNotes()
            statisticsHandler(statistics)
        }
    }

    func refreshStatisticsNotes() {
        statistics.notes = makeStatisticsNotes(
            width: outputWidth,
            height: outputHeight
        )
    }

    func averageFrameRate(
        intervalTotalMilliseconds: Double,
        sampleCount: UInt64
    ) -> String {
        guard sampleCount > 0, intervalTotalMilliseconds > 0 else {
            return "0.0"
        }
        return String(
            format: "%.2f",
            Double(sampleCount) * 1_000 / intervalTotalMilliseconds
        )
    }

    func formattedPercent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
    }

    func enqueueCompressionOutput(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        contextPointer: UnsafeMutableRawPointer?,
        rawCallbackMachTime: UInt64
    ) {
        let sampleBufferAddress = sampleBuffer.map {
            UInt(bitPattern: Unmanaged.passRetained($0).toOpaque())
        }
        let contextID = contextPointer.map {
            UInt64(UInt(bitPattern: $0))
        }
        outputLifecycle.enqueueOutput(id: contextID) { [weak self] context in
            let retainedSampleBuffer = sampleBufferAddress.flatMap { address
                -> CMSampleBuffer? in
                guard let pointer = UnsafeRawPointer(bitPattern: address) else {
                    return nil
                }
                return Unmanaged<CMSampleBuffer>
                    .fromOpaque(pointer)
                    .takeRetainedValue()
            }
            guard let self,
                  let context else {
                return
            }
            self.didEncode(
                status: status,
                infoFlags: infoFlags,
                sampleBuffer: retainedSampleBuffer,
                context: context,
                rawCallbackMachTime: rawCallbackMachTime
            )
        }
    }
}
