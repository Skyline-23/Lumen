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
        let sourceApproxFrameRate = formattedRate(
            captureCadenceTelemetry.sourceCallbacksPerSecond
        )
        let submissionApproxFrameRate = formattedRate(
            captureCadenceTelemetry.videoToolboxSubmissionsPerSecond
        )
        let outputApproxFrameRate = formattedRate(
            captureCadenceTelemetry.videoToolboxOutputsPerSecond
        )
        let pendingAdmissionDropRate = formattedRate(
            captureCadenceTelemetry.pendingAdmissionDropsPerSecond
        )
        let cadenceWindowMilliseconds = formattedRate(
            captureCadenceTelemetry.windowDurationMilliseconds
        )
        let appliedBitrateKbps = statistics.appliedVideoBitRateKbps
        let appliedBitrateDescription =
            appliedBitrateKbps.map(String.init) ?? "n/a"
        let outputBitrateKbps = statistics.estimatedOutputBitrateKbps
        let outputToTargetPercent = outputBitrateKbps.flatMap { output in
            appliedBitrateKbps.flatMap { target in
                target > 0 ? output * 100 / Double(target) : nil
            }
        }
        let contentStream = skyLightDisplayStream
        var notes = [
            "captureBackend=\(captureBackend.rawValue)",
            "sourceBackend=\(captureBackend.rawValue)",
            "privateContentStream=\(captureBackend == .skyLightDisplayStream)",
            "privateContentStreamBackend=\(contentStream?.backendName ?? "unavailable")",
            "privateContentStreamClass=\(contentStream?.contentStreamClassName ?? "unavailable")",
            "privateContentStreamSessionClass=\(contentStream?.contentStreamSessionClassName ?? "unavailable")",
            "privateContentStreamUnderlyingCGDisplayStream=\(contentStream?.underlyingDisplayStreamAvailable ?? false)",
            "privateContentStreamUnderlyingCGDisplayStreamTypeID=\(contentStream?.underlyingDisplayStreamTypeID ?? 0)",
            "privateContentStreamFirstFrameDropCount=\(contentStream?.firstFrameDropCount ?? 0)",
            "privateContentStreamCumulativeDropCount=\(contentStream?.cumulativeDropCount ?? 0)",
            "privateContentStreamRequestedPixelFormat=\(auditFourCC(capturePixelFormat))",
            "privateContentStreamRequestedMatrix=\(configuration.encodedColorConfiguration.map { $0.yCbCrMatrix.imageBufferValue as String } ?? "unset")",
            "privateContentStreamDynamicRangeMode=\(configuration.usesHDRTransport ? 2 : 0)",
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
            "sourceCallbackWindowFrameRate=\(sourceApproxFrameRate)",
            "captureCadenceWindowMilliseconds=\(cadenceWindowMilliseconds)",
            "videoToolboxTargetFrameRateHint=\(configuration.effectiveTargetFrameRate)",
            "videoToolboxAdaptiveTargetFrameRate=\(statistics.adaptiveTargetFrameRate.map(String.init) ?? "n/a")",
            "videoToolboxEncoderInputPixelFormat=\(capturePixelFormat)",
            "videoToolboxSourcePixelFormat=\(capturePixelFormat)",
            "sourceColorContract=\(sourceColorContractStatus)",
            "videoToolboxStagingMode=\(captureBackend == .skyLightDisplayStream ? "async-metal-blit" : "direct-cvpixelbuffer")",
            "videoToolboxStagedSourceReleaseMode=\(captureBackend == .skyLightDisplayStream ? "gpu-completion" : "callback")",
            "videoToolboxMetalStagePoolCapacity=\(LumenSkyLightMetalStagingPolicy.poolCapacity)",
            "videoToolboxMetalStageGPUCopyInFlight=\(skyLightMetalStagingAdmission.isCopyInFlight)",
            "videoToolboxMetalStageGPUCopyInFlightCount=\(skyLightMetalStagingAdmission.inFlightCopyCount)",
            "videoToolboxMetalStageGeneration=\(skyLightMetalStagingGeneration.value)",
            "videoToolboxMetalStageReleaseRequested=\(skyLightMetalStagingReleaseRequested)",
            "videoToolboxMetalStageSubmissionCount=\(skyLightMetalStageSubmissionCount)",
            "videoToolboxMetalStageCompletionCount=\(skyLightMetalStageCompletionCount)",
            "videoToolboxMetalStageBusyDropCount=\(skyLightMetalStageBusyDropCount)",
            "videoToolboxMetalStagePoolAllocationFailureCount=\(skyLightMetalStagePoolAllocationFailureCount)",
            "videoToolboxMetalStageTextureFailureCount=\(skyLightMetalStageTextureFailureCount)",
            "videoToolboxMetalStageCommandBufferFailureCount=\(skyLightMetalStageCommandBufferFailureCount)",
            "videoToolboxMetalStageValidationFailureCount=\(skyLightMetalStageValidationFailureCount)",
            "videoToolboxMetalStageLastError=\(skyLightMetalStageLastError ?? "none")",
            "videoToolboxAdmissionMode=serial-offloaded-latest",
            "videoToolboxPendingSourceBound=1",
            "videoToolboxInflightSourceBound=\(LumenRealtimeVideoEncoderAdmissionPolicy.maximumInflightFrameCount)",
            "videoToolboxConversionCount=0",
            "videoToolboxProfile=\(encodingPlan?.profile ?? "unresolved")",
            "videoToolboxHardwareRequired=true",
            "videoToolboxAllowOpenGOP=\(statistics.exactCaptureAudit.allowOpenGOP.map { String($0) } ?? "n/a")",
            "videoToolboxConfiguredPrioritizeEncodingSpeedOverQuality=\(prioritizesEncodingSpeedOverQuality)",
            "videoToolboxConfiguredThroughputMode=\(configuredThroughputMode.map(String.init) ?? "n/a")",
            "videoToolboxConfiguredSourceFrameCount=\(width)x\(height)",
            "videoToolboxSubmittedFrameCount=\(statistics.submittedFrameCount)",
            "videoToolboxSubmissionWindowFrameRate=\(submissionApproxFrameRate)",
            "videoToolboxAdmissionUtilizationPercent=\(formattedPercent(utilization.videoToolboxAdmissionPercent))",
            "videoToolboxOutputUtilizationPercent=\(formattedPercent(utilization.videoToolboxOutputPercent))",
            "videoToolboxPendingAdmissionDropCount=\(statistics.pendingAdmissionDropCount)",
            "videoToolboxIntentionalFrameCadenceDropCount=\(statistics.intentionalFrameCadenceDropCount)",
            "videoToolboxPendingAdmissionDropWindowRate=\(pendingAdmissionDropRate)",
            "videoToolboxAppliedBitrateKbps=\(appliedBitrateDescription)",
            "videoToolboxEncodedByteCount=\(statistics.encodedByteCount)",
            "videoToolboxEstimatedOutputBitrateKbps=\(formattedPercent(outputBitrateKbps))",
            "videoToolboxOutputToAppliedBitratePercent=\(formattedPercent(outputToTargetPercent))",
            "videoToolboxBootstrapGateOpen=\(videoBootstrapAdmission.isOpen)",
            "videoToolboxBootstrapPendingSource=\(pendingVideoBootstrapSource != nil)",
            "videoToolboxCurrentInflightStagingSlots=\(inflightFrameCount)",
            "videoToolboxMaxInflightStagingSlots=\(statistics.maximumInflightFrameCount)",
            "videoToolboxOutputApproxFrameRate=\(outputApproxFrameRate)",
            "videoToolboxOutputWindowFrameRate=\(outputApproxFrameRate)"
        ]
        notes.append(contentsOf: captureStageTimingNotes())
        return notes
    }

    static func identity(of stream: SCStream) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(stream).toOpaque())
    }

    static func identity(of stream: LumenSkyLightDisplayStream) -> UInt {
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
                prefix: "videoToolboxMetalStage",
                timing: skyLightMetalStageTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "metalGPUExecution",
                timing: skyLightMetalGPUExecutionTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "metalGPUToCallback",
                timing: skyLightMetalGPUCallbackTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "metalCompletionOwnerQueue",
                timing: skyLightMetalCompletionQueueTiming
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
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxBitrateUpdateQueueWait",
                timing: bitrateUpdateQueueWaitTiming
            )
            + lumenCaptureTimingNotes(
                prefix: "videoToolboxBitrateUpdateApply",
                timing: bitrateUpdateApplyTiming
            )
    }

    func refreshStatisticsNotesIfNeeded() {
        let didCompleteCadenceWindow = captureCadenceTelemetry.observe(
            statistics: statistics,
            atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        let shouldRefreshNotes = statisticsNotesRefreshGate.shouldRefresh(
            sourceFrameCount: statistics.sourceFrameCount
        )
        if shouldRefreshNotes || didCompleteCadenceWindow {
            publishStatistics(reason: .forced)
        }
        if didCompleteCadenceWindow {
            logCompactPipelineTiming()
        }
    }

    @discardableResult
    func publishStatistics(
        reason: LumenEncodedCaptureStatisticsPublicationPolicy.PublicationReason,
        rebuildingNotes: Bool = true,
        atUptimeNanoseconds uptimeNanoseconds: UInt64 =
            DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard statisticsPublicationPolicy.shouldPublish(
            reason: reason,
            atUptimeNanoseconds: uptimeNanoseconds
        ) else {
            return false
        }
        if rebuildingNotes {
            refreshStatisticsNotes()
        }
        statisticsHandler(statistics)
        return true
    }

    func publishSuccessfulOutputStatisticsIfNeeded(
        atUptimeNanoseconds uptimeNanoseconds: UInt64 =
            DispatchTime.now().uptimeNanoseconds
    ) {
        publishStatistics(
            reason: .highRateUpdate,
            atUptimeNanoseconds: uptimeNanoseconds
        )
    }

    func logCompactPipelineTiming() {
#if DEBUG
        if recordsLiveSourceArrivals, liveSourceArrivalOffsets.count < 768 {
            // Diagnostic selection only: do not change production admission.
            // Sample the observed slow-output state, not a startup timer that
            // can accidentally select the faster state. Reject interrupted runs.
            if let source = captureCadenceTelemetry.sourceCallbacksPerSecond,
               let output = captureCadenceTelemetry.videoToolboxOutputsPerSecond,
               source >= 50, (30 ..< 50).contains(output) {
                liveSourceSlowWindows = min(liveSourceSlowWindows + 1, 3)
            } else {
                liveSourceSlowWindows = 0
                liveSourceArrivalOrigin = nil
                liveSourceArrivalOffsets.removeAll(keepingCapacity: true)
                liveSourcePresentationOrigin = nil
                liveSourcePresentationOffsets.removeAll(keepingCapacity: true)
            }
        }
#endif
        let sourceFrameRate = formattedRate(
            captureCadenceTelemetry.sourceCallbacksPerSecond
        )
        let submissionFrameRate = formattedRate(
            captureCadenceTelemetry.videoToolboxSubmissionsPerSecond
        )
        let outputFrameRate = formattedRate(
            captureCadenceTelemetry.videoToolboxOutputsPerSecond
        )
        let pendingDropFrameRate = formattedRate(
            captureCadenceTelemetry.pendingAdmissionDropsPerSecond
        )
        let displayToCallback = compactTiming(
            captureIngressTimings.displayToCallback
        )
        let sourceService = compactTiming(sourceCallbackServiceTiming)
        let admissionWait = compactTiming(encoderAdmissionWaitTiming)
        let metalStage = compactTiming(skyLightMetalStageTiming)
        let metalGPU = compactTiming(skyLightMetalGPUExecutionTiming)
        let metalCallback = compactTiming(skyLightMetalGPUCallbackTiming)
        let metalOwnerQueue = compactTiming(skyLightMetalCompletionQueueTiming)
        let encodeCall = compactTiming(encoderInvocationTiming)
        let encodeCallback = compactTiming(videoToolboxCallbackTiming)
        let outputQueueWait = compactTiming(outputOwnerQueueWaitTiming)
        let outputService = compactTiming(outputServiceTiming)
        let frameHandler = compactTiming(frameHandlerTiming)
        let sourceGap = compactTiming(captureIngressTimings.callbackInterval)
        let displayGap = compactTiming(captureIngressTimings.displayInterval)
        let displayLead = compactTiming(captureIngressTimings.scheduledDisplayLead)
        let outputGap = compactTiming(outputOccupancyTimings.interval)
        let cadenceTarget = statistics.adaptiveTargetFrameRate.map(String.init) ?? "n/a"
        Self.pipelineLogger.notice(
            "stage=occupancy source-gap-ms=\(sourceGap, privacy: .public) display-gap-ms=\(displayGap, privacy: .public) display-lead-ms=\(displayLead, privacy: .public) output-gap-ms=\(outputGap, privacy: .public) single-flight-outputs=\(self.outputOccupancyTimings.singleFlightOutputs, privacy: .public)/\(self.outputOccupancyTimings.outputs, privacy: .public) cadence-drops=\(self.statistics.intentionalFrameCadenceDropCount, privacy: .public) target-fps=\(cadenceTarget, privacy: .public)"
        )
        Self.pipelineLogger.notice(
            "stage=window src-fps=\(sourceFrameRate, privacy: .public) submit-fps=\(submissionFrameRate, privacy: .public) output-fps=\(outputFrameRate, privacy: .public) pending-drop-fps=\(pendingDropFrameRate, privacy: .public) display-callback-ms=\(displayToCallback, privacy: .public) source-service-ms=\(sourceService, privacy: .public) metal-stage-ms=\(metalStage, privacy: .public) metal-gpu-ms=\(metalGPU, privacy: .public) metal-callback-ms=\(metalCallback, privacy: .public) metal-owner-queue-ms=\(metalOwnerQueue, privacy: .public) admission-wait-ms=\(admissionWait, privacy: .public) encode-call-ms=\(encodeCall, privacy: .public) encode-callback-ms=\(encodeCallback, privacy: .public) output-queue-ms=\(outputQueueWait, privacy: .public) output-service-ms=\(outputService, privacy: .public) frame-handler-ms=\(frameHandler, privacy: .public)"
        )
    }

    func compactTiming(_ timing: LumenCaptureStageTimingAccumulator) -> String {
        "\(formattedRate(timing.averageMilliseconds))/\(formattedRate(timing.maximumMilliseconds))"
    }

    func refreshStatisticsNotes() {
        statistics.notes = makeStatisticsNotes(
            width: outputWidth,
            height: outputHeight
        )
    }

    func formattedRate(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
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
