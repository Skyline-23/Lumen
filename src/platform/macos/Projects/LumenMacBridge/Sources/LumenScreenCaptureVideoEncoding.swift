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
        try setProperty(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: targetFrameRate
        )
        if configuration.targetVideoBitRateKbps > 0 {
            try setProperty(
                kVTCompressionPropertyKey_AverageBitRate,
                value: (configuration.targetVideoBitRateKbps * 1_000) as CFNumber
            )
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
        refreshStatisticsNotes()
        statisticsHandler(statistics)
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
        if cancelledContexts.contains(where: \.requiresBootstrapAcknowledgement) {
            videoBootstrapAdmission.cancelBootstrapSubmission()
            pendingVideoBootstrapSource = nil
        }
        refreshStatisticsNotes()
        statisticsHandler(statistics)
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
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
    }

}
