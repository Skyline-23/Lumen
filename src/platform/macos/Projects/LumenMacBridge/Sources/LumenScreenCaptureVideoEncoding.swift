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

struct LumenVideoToolboxRateControl: Equatable, Sendable {
    let averageBitrateBitsPerSecond: Int
    let dataRateLimitBytesPerSecond: Int
    let dataRateLimitSeconds: Int

    init?(bitrateKbps: Int) {
        guard bitrateKbps > 0,
              bitrateKbps <= Int.max / 1_000 else {
            return nil
        }
        let averageBitrateBitsPerSecond = bitrateKbps * 1_000
        self.averageBitrateBitsPerSecond = averageBitrateBitsPerSecond
        dataRateLimitBytesPerSecond = averageBitrateBitsPerSecond / 8
        dataRateLimitSeconds = 1
    }

    func apply(to session: VTCompressionSession) throws {
        try setProperty(
            kVTCompressionPropertyKey_AverageBitRate,
            value: averageBitrateBitsPerSecond as CFNumber,
            on: session
        )
        try setProperty(
            kVTCompressionPropertyKey_DataRateLimits,
            value: [
                dataRateLimitBytesPerSecond as NSNumber,
                dataRateLimitSeconds as NSNumber,
            ] as CFArray,
            on: session
        )
    }

    private func setProperty(
        _ key: CFString,
        value: CFTypeRef,
        on session: VTCompressionSession
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw LumenScreenCaptureError.compressionPropertyFailed(
                String(describing: key),
                status
            )
        }
    }
}

/// Resolves the optional macOS 26+ VideoToolbox throughput-mode extension
/// from the encoder's own runtime advertisement.  The mode is intentionally
/// not represented by a public SDK constant: only an advertised `turbo` entry
/// with one consistent numeric ID is eligible for use.
enum LumenVideoToolboxThroughputModeResolver {
    static func modePropertyKey() -> CFString {
        "ThroughputMode" as CFString
    }

    static func supportedModesPropertyKey() -> CFString {
        "SupportedThroughputModes" as CFString
    }

    static func advertisedTurboModeID(
        from supportedModesValue: CFTypeRef
    ) -> Int? {
        guard let supportedModes = supportedModesValue as? NSDictionary,
              let turboModes = supportedModes.object(forKey: "turbo") as? NSArray else {
            return nil
        }

        let modeIDs = turboModes.compactMap { mode -> Int? in
            guard let mode = mode as? NSDictionary,
                  let modeID = mode.object(forKey: "ThroughputModeID") as? NSNumber,
                  modeID.intValue > 0 else {
                return nil
            }
            return modeID.intValue
        }
        guard let firstModeID = modeIDs.first,
              modeIDs.count == turboModes.count,
              modeIDs.allSatisfy({ $0 == firstModeID }) else {
            return nil
        }
        return firstModeID
    }
}

extension LumenScreenCaptureVideoRuntime {
    func createCompressionSession(width: Int, height: Int) throws {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let encodingPlan else {
            throw LumenExactCaptureError.invalidFormat("encoding plan was not resolved")
        }
        let session = try makeCompressionSession(width: width, height: height)
        compressionSession = session
        try configureCompressionSession(encodingPlan: encodingPlan)
        try prepareCompressionSession(session)
        try validateClosedGOP(session)
        try validateHardwareEncoder(session)
        adaptiveVideoDeliveryPolicy.beginRunning(
            bitrateKbps: configuration.targetVideoBitRateKbps,
            targetFrameRate: configuration.effectiveTargetFrameRate
        )
        statistics.adaptiveTargetFrameRate =
            configuration.effectiveTargetFrameRate
        statistics.exactCaptureAudit.profile = encodingPlan.profile
        statistics.exactCaptureAudit.hardwareUsed = true
    }

    func makeCompressionSession(
        width: Int,
        height: Int
    ) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: compressionCodecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: capturePixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: lumenScreenCaptureCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw LumenScreenCaptureError.compressionSessionCreationFailed(status)
        }
        return session
    }

    var compressionCodecType: CMVideoCodecType {
        switch configuration.codec {
        case .h264:
            kCMVideoCodecType_H264
        case .hevc:
            kCMVideoCodecType_HEVC
        case .shadowVC:
            0x53435631
        }
    }

    func configureCompressionSession(
        encodingPlan: LumenVideoToolboxEncodingPlan
    ) throws {
        try setProperty(
            kVTCompressionPropertyKey_RealTime,
            value: true as CFBoolean
        )
        try setProperty(
            kVTCompressionPropertyKey_AllowFrameReordering,
            value: false as CFBoolean
        )
        // Remote presentation values encoder service time over offline visual
        // optimization. This public VideoToolbox hint preserves the codec and
        // GOP contract while selecting the hardware encoder's faster path.
        prioritizesEncodingSpeedOverQuality = try setOptionalProperty(
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: true as CFBoolean
        )
        configureAdvertisedTurboThroughputMode()
        if configuration.codec == .hevc {
            try setProperty(
                kVTCompressionPropertyKey_AllowOpenGOP,
                value: false as CFBoolean
            )
        }
        let targetFrameRate = configuration.effectiveTargetFrameRate as CFNumber
        try setProperty(
            kVTCompressionPropertyKey_ExpectedFrameRate,
            value: targetFrameRate
        )
        // ScreenCaptureKit and the Rust cadence controllers may lower the
        // admitted source rate, but neither is allowed to raise the
        // negotiated ceiling for this compression session.  These keys are
        // optional across VideoToolbox encoder implementations; an encoder
        // that does not advertise one keeps the required expected-frame-rate
        // contract above and continues with source-PTS pacing.
        try setOptionalProperty(
            kVTCompressionPropertyKey_MaximumRealTimeFrameRate,
            value: targetFrameRate
        )
        try setOptionalProperty(
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: LumenAdaptiveVideoFrameTiming
                .keyFrameIntervalDurationSeconds as CFNumber
        )
        try setOptionalProperty(
            kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: 1 as CFNumber
        )
        // Do not force EnableLowLatencyRateControl here.  Some HEVC Main10
        // implementations reject it together with the required closed-GOP
        // contract; real-time mode, frame-reordering disabled, bounded frame
        // delay, and source-PTS pacing provide the portable low-latency path.
        if let rateControl = LumenVideoToolboxRateControl(
            bitrateKbps: configuration.targetVideoBitRateKbps
        ) {
            try applyVideoRateControl(rateControl)
        }
        try setProperty(
            kVTCompressionPropertyKey_ProfileLevel,
            value: encodingPlan.profile as CFString
        )
        if let color = configuration.encodedColorConfiguration {
            try configureColorProperties(color)
        }
    }

    func configureColorProperties(
        _ color: LumenVideoHDRConfiguration
    ) throws {
        try setProperty(
            kVTCompressionPropertyKey_ColorPrimaries,
            value: color.colorPrimaries.coreMediaValue
        )
        try setProperty(
            kVTCompressionPropertyKey_TransferFunction,
            value: color.transferFunction.coreMediaValue
        )
        try setProperty(
            kVTCompressionPropertyKey_YCbCrMatrix,
            value: color.yCbCrMatrix.coreMediaValue
        )
        if color.transferFunction != .ituR709 {
            try setProperty(
                kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                value: kVTHDRMetadataInsertionMode_Auto
            )
        }
        if let hdrDisplayMetadata = color.hdrDisplayMetadata {
            try setProperty(
                kVTCompressionPropertyKey_MasteringDisplayColorVolume,
                value: hdrDisplayMetadata.encodedData as CFData
            )
        }
        if let contentLightLevelInfo = color.contentLightLevelInfo {
            try setProperty(
                kVTCompressionPropertyKey_ContentLightLevelInfo,
                value: contentLightLevelInfo.encodedData as CFData
            )
        }
    }

    func setVideoBitRateKbps(_ bitrateKbps: Int) async -> Bool {
        await enqueueVideoDeliveryPolicy(
            bitrateKbps: bitrateKbps,
            admissionDivisor: nil
        )
    }

    func setVideoDeliveryPolicy(
        bitrateKbps: Int,
        admissionDivisor: Int
    ) async -> Bool {
        await enqueueVideoDeliveryPolicy(
            bitrateKbps: bitrateKbps,
            admissionDivisor: admissionDivisor
        )
    }

    func enqueueVideoDeliveryPolicy(
        bitrateKbps: Int,
        admissionDivisor: Int?
    ) async -> Bool {
        guard let rateControl = LumenVideoToolboxRateControl(
            bitrateKbps: bitrateKbps
        ) else {
            return false
        }
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        return await withCheckedContinuation { continuation in
            encoderQueue.async { [weak self] in
                guard let self,
                      self.compressionSession != nil else {
                    continuation.resume(returning: false)
                    return
                }
                let queueWaitMilliseconds =
                    Self.elapsedMilliseconds(since: requestedAt)
                let applyStartedAt = DispatchTime.now().uptimeNanoseconds
                let divisor = admissionDivisor
                    ?? self.adaptiveVideoDeliveryPolicy.admissionDivisor
                let applied = self.adaptiveVideoDeliveryPolicy.apply(
                    bitrateKbps: bitrateKbps,
                    admissionDivisor: divisor
                ) {
                    try self.applyVideoRateControl(rateControl)
                }
                self.publishBitrateUpdateTelemetry(
                    appliedBitrateKbps: applied ? bitrateKbps : nil,
                    queueWaitMilliseconds: queueWaitMilliseconds,
                    applyMilliseconds: Self.elapsedMilliseconds(
                        since: applyStartedAt
                    )
                )
                continuation.resume(returning: applied)
            }
        }
    }

    func publishBitrateUpdateTelemetry(
        appliedBitrateKbps: Int?,
        queueWaitMilliseconds: Double,
        applyMilliseconds: Double?
    ) {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        queue.async { [weak self] in
            guard let self else { return }
            self.bitrateUpdateQueueWaitTiming.observe(
                queueWaitMilliseconds
            )
            if let applyMilliseconds {
                self.bitrateUpdateApplyTiming.observe(applyMilliseconds)
            }
            if let appliedBitrateKbps {
                self.statistics.appliedVideoBitRateKbps =
                    appliedBitrateKbps
            }
            self.publishStatistics(reason: .immediate)
        }
    }

    func applyVideoRateControl(
        _ rateControl: LumenVideoToolboxRateControl
    ) throws {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return }
        try rateControl.apply(to: compressionSession)
        appliedVideoBitRateKbps =
            rateControl.averageBitrateBitsPerSecond / 1_000
    }

    func prepareCompressionSession(_ session: VTCompressionSession) throws {
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            throw LumenScreenCaptureError.compressionSessionPreparationFailed(prepareStatus)
        }
    }

    func validateClosedGOP(_ session: VTCompressionSession) throws {
        guard configuration.codec == .hevc else {
            return
        }
        let openGOPProperty = copiedBooleanProperty(
            kVTCompressionPropertyKey_AllowOpenGOP,
            from: session
        )
        guard openGOPProperty.status == noErr,
              openGOPProperty.value == false else {
            throw LumenExactCaptureError.invalidFormat(
                "VideoToolbox did not retain the required closed-GOP HEVC contract"
            )
        }
        statistics.exactCaptureAudit.allowOpenGOP = false
    }

    func validateHardwareEncoder(_ session: VTCompressionSession) throws {
        let hardwareProperty = copiedBooleanProperty(
            kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            from: session
        )
        guard hardwareProperty.status == noErr,
              hardwareProperty.value == true else {
            throw LumenExactCaptureError.requiredHardwareEncoderUnavailable
        }
    }

    func copiedBooleanProperty(
        _ key: CFString,
        from session: VTCompressionSession
    ) -> (status: OSStatus, value: Bool?) {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session,
                key: key,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        return (status, value as? Bool)
    }

    func configureAdvertisedTurboThroughputMode() {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return }

        var supportedProperties: CFDictionary?
        let supportedPropertiesStatus =
            VTSessionCopySupportedPropertyDictionary(
                compressionSession,
                supportedPropertyDictionaryOut: &supportedProperties
            )
        guard supportedPropertiesStatus == noErr,
              let properties = supportedProperties as NSDictionary?,
              properties.object(
                  forKey: LumenVideoToolboxThroughputModeResolver.modePropertyKey()
              ) != nil,
              properties.object(
                  forKey: LumenVideoToolboxThroughputModeResolver.supportedModesPropertyKey()
              ) != nil else {
            return
        }

        var supportedModes: CFTypeRef?
        let supportedModesStatus = withUnsafeMutablePointer(to: &supportedModes) {
            pointer in
            VTSessionCopyProperty(
                compressionSession,
                key: LumenVideoToolboxThroughputModeResolver.supportedModesPropertyKey(),
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        guard supportedModesStatus == noErr,
              let supportedModes else {
            return
        }
        guard let modeID =
                LumenVideoToolboxThroughputModeResolver.advertisedTurboModeID(
                    from: supportedModes
                ) else {
            return
        }

        do {
            guard try setOptionalProperty(
                LumenVideoToolboxThroughputModeResolver.modePropertyKey(),
                value: modeID as CFNumber
            ) else {
                return
            }
            configuredThroughputMode = modeID
        } catch {
            // ThroughputMode is an optional runtime extension. Keep the
            // existing public VideoToolbox path when an advertised value is
            // rejected by this particular encoder instance.
        }
    }

    func resolveEncodingPlan() async throws -> LumenVideoToolboxEncodingPlan {
        var profiles: [LumenVideoToolboxProbeTarget: String] = [:]
        if configuration.requiredHardware444ProbeTarget != nil {
            let rows = await LumenVideoToolboxCapabilityProbe.advertisedRequiredHardware444()
            for row in rows {
                guard let target = LumenVideoToolboxProbeTarget(rawValue: row.requestedProfileFamily),
                      let profile = row.profile else {
                    continue
                }
                profiles[target] = profile
            }
        }
        return try LumenVideoToolboxEncodingPlanResolver.resolve(
            configuration: configuration,
            availableHardware444Profiles: profiles
        )
    }

    func reportTerminalContractFailure(
        _ error: LumenExactCaptureError,
        sourceDisplayTime: UInt64?
    ) {
        statistics.droppedFrameCount &+= 1
        statistics.processingFailureCount &+= 1
        sourceColorContractStatus = "rejected:\(error.localizedDescription)"
        statistics.lastErrorDescription = error.localizedDescription
        publishStatistics(reason: .terminal)
        guard !terminalContractFailureReported else { return }
        terminalContractFailureReported = true
        sourceColorContractFailureReported = true
        eventHandler(.init(
            kind: .failed,
            message: error.localizedDescription,
            sourceDisplayTime: sourceDisplayTime
        ))
        terminationHandler(error)
    }

    func setProperty(_ key: CFString, value: CFTypeRef) throws {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return }
        let status = VTSessionSetProperty(compressionSession, key: key, value: value)
        guard status == noErr else {
            throw LumenScreenCaptureError.compressionPropertyFailed(String(describing: key), status)
        }
    }

    /// VideoToolbox exposes these latency/ceiling hints on different encoder
    /// implementations and OS releases.  They must never turn an otherwise
    /// valid hardware encoder into a terminal capture failure when a property
    /// is simply unsupported.  Unexpected errors still fail the exact capture
    /// contract so the caller does not silently run with a broken session.
    @discardableResult
    func setOptionalProperty(_ key: CFString, value: CFTypeRef) throws -> Bool {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return false }
        let status = VTSessionSetProperty(compressionSession, key: key, value: value)
        guard status == noErr
            || status == kVTPropertyNotSupportedErr
            || status == kVTParameterErr else {
            throw LumenScreenCaptureError.compressionPropertyFailed(
                String(describing: key),
                status
            )
        }
        return status == noErr
    }

    func completeCompressionFrames() -> OSStatus {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return noErr }
        return VTCompressionSessionCompleteFrames(
            compressionSession,
            untilPresentationTimeStamp: .invalid
        )
    }

    func reportCompressionFrameCompletionFailure(
        status: OSStatus,
        cancelledContexts: [LumenEncodedFrameContext]
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let error = LumenScreenCaptureError
            .compressionFrameCompletionFailed(status)
        inflightFrameCount = max(
            inflightFrameCount - cancelledContexts.count,
            0
        )
        statistics.droppedFrameCount &+= UInt64(cancelledContexts.count)
        statistics.processingFailureCount &+= 1
        statistics.lastErrorDescription = error.localizedDescription
        if cancelledContexts.contains(where: { $0.bootstrapReason != nil }) {
            videoBootstrapAdmission.cancelBootstrapSubmission()
            pendingVideoBootstrapSource = nil
        }
        publishStatistics(reason: .terminal)
        eventHandler(.init(
            kind: .failed,
            message: error.localizedDescription,
            stopStatus: status
        ))
        terminationHandler(error)
    }

    func invalidateCompressionSession() {
        dispatchPrecondition(condition: .onQueue(encoderQueue))
        guard let compressionSession else { return }
        adaptiveVideoDeliveryPolicy.beginStopping()
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
        appliedVideoBitRateKbps = nil
    }

}
