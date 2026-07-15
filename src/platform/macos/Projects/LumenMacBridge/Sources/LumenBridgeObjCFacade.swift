import CoreGraphics
import CoreMedia
import Foundation
import LumenEngineBridge
import OSLog
import Synchronization

@objcMembers
public final class LumenBridgeSinkModeBox: NSObject {
    public let hidpi: Bool
    public let scaleExplicit: Bool
    public let modeIsLogical: Bool
    public let scalePercent: Int

    public init(
        hidpi: Bool,
        scaleExplicit: Bool,
        modeIsLogical: Bool,
        scalePercent: Int
    ) {
        self.hidpi = hidpi
        self.scaleExplicit = scaleExplicit
        self.modeIsLogical = modeIsLogical
        self.scalePercent = scalePercent
    }
}

@objcMembers
public final class LumenBridgeSinkCapabilityBox: NSObject {
    public let gamutRawValue: Int
    public let transferRawValue: Int
    public let currentEDRHeadroom: Float
    public let potentialEDRHeadroom: Float
    public let currentPeakLuminanceNits: Int
    public let potentialPeakLuminanceNits: Int
    public let supportsFrameGatedHDR: Bool
    public let supportsHDRTileOverlay: Bool
    public let supportsPerFrameHDRMetadata: Bool

    public init(
        gamutRawValue: Int,
        transferRawValue: Int,
        currentEDRHeadroom: Float,
        potentialEDRHeadroom: Float,
        currentPeakLuminanceNits: Int,
        potentialPeakLuminanceNits: Int,
        supportsFrameGatedHDR: Bool,
        supportsHDRTileOverlay: Bool,
        supportsPerFrameHDRMetadata: Bool
    ) {
        self.gamutRawValue = gamutRawValue
        self.transferRawValue = transferRawValue
        self.currentEDRHeadroom = currentEDRHeadroom
        self.potentialEDRHeadroom = potentialEDRHeadroom
        self.currentPeakLuminanceNits = currentPeakLuminanceNits
        self.potentialPeakLuminanceNits = potentialPeakLuminanceNits
        self.supportsFrameGatedHDR = supportsFrameGatedHDR
        self.supportsHDRTileOverlay = supportsHDRTileOverlay
        self.supportsPerFrameHDRMetadata = supportsPerFrameHDRMetadata
    }
}

@objcMembers
public final class LumenBridgeHDRStaticMetadataBox: NSObject {
    public let redPrimaryX: Int
    public let redPrimaryY: Int
    public let greenPrimaryX: Int
    public let greenPrimaryY: Int
    public let bluePrimaryX: Int
    public let bluePrimaryY: Int
    public let whitePointX: Int
    public let whitePointY: Int
    public let maxDisplayLuminance: Int
    public let minDisplayLuminance: Int
    public let maxContentLightLevel: Int
    public let maxFrameAverageLightLevel: Int
    public let maxFullFrameLuminance: Int

    public init(
        redPrimaryX: Int,
        redPrimaryY: Int,
        greenPrimaryX: Int,
        greenPrimaryY: Int,
        bluePrimaryX: Int,
        bluePrimaryY: Int,
        whitePointX: Int,
        whitePointY: Int,
        maxDisplayLuminance: Int,
        minDisplayLuminance: Int,
        maxContentLightLevel: Int,
        maxFrameAverageLightLevel: Int,
        maxFullFrameLuminance: Int
    ) {
        self.redPrimaryX = redPrimaryX
        self.redPrimaryY = redPrimaryY
        self.greenPrimaryX = greenPrimaryX
        self.greenPrimaryY = greenPrimaryY
        self.bluePrimaryX = bluePrimaryX
        self.bluePrimaryY = bluePrimaryY
        self.whitePointX = whitePointX
        self.whitePointY = whitePointY
        self.maxDisplayLuminance = maxDisplayLuminance
        self.minDisplayLuminance = minDisplayLuminance
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
        self.maxFullFrameLuminance = maxFullFrameLuminance
    }
}

@objcMembers
public final class LumenBridgeSinkRequestBox: NSObject {
    public let mode: LumenBridgeSinkModeBox
    public let capability: LumenBridgeSinkCapabilityBox
    public let dynamicRangeTransportRawValue: Int

    public init(
        mode: LumenBridgeSinkModeBox,
        capability: LumenBridgeSinkCapabilityBox,
        dynamicRangeTransportRawValue: Int
    ) {
        self.mode = mode
        self.capability = capability
        self.dynamicRangeTransportRawValue = dynamicRangeTransportRawValue
    }
}

@objcMembers
public final class LumenBridgeEffectiveDisplayStateBox: NSObject {
    public let gamutRawValue: Int
    public let transferRawValue: Int
    public let hdrStaticMetadata: LumenBridgeHDRStaticMetadataBox?

    public init(
        gamutRawValue: Int,
        transferRawValue: Int,
        hdrStaticMetadata: LumenBridgeHDRStaticMetadataBox?
    ) {
        self.gamutRawValue = gamutRawValue
        self.transferRawValue = transferRawValue
        self.hdrStaticMetadata = hdrStaticMetadata
    }
}

@objcMembers
public final class LumenBridgeConfigurationBox: NSObject {
    public let displayID: UInt32
    public let codecRawValue: Int
    public let preprocessStrategyRawValue: Int
    public let queueProfileRawValue: Int
    public let targetFrameRate: Int
    public let targetVideoBitRateKbps: Int
    public let requestedWidth: Int
    public let requestedHeight: Int
    public let sinkRequest: LumenBridgeSinkRequestBox
    public let effectiveDisplayState: LumenBridgeEffectiveDisplayStateBox

    public init(
        displayID: UInt32,
        codecRawValue: Int,
        preprocessStrategyRawValue: Int,
        queueProfileRawValue: Int,
        targetFrameRate: Int,
        targetVideoBitRateKbps: Int,
        requestedWidth: Int,
        requestedHeight: Int,
        sinkRequest: LumenBridgeSinkRequestBox,
        effectiveDisplayState: LumenBridgeEffectiveDisplayStateBox
    ) {
        self.displayID = displayID
        self.codecRawValue = codecRawValue
        self.preprocessStrategyRawValue = preprocessStrategyRawValue
        self.queueProfileRawValue = queueProfileRawValue
        self.targetFrameRate = targetFrameRate
        self.targetVideoBitRateKbps = targetVideoBitRateKbps
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.sinkRequest = sinkRequest
        self.effectiveDisplayState = effectiveDisplayState
    }

    convenience init(configuration: LumenMacCaptureConfiguration) {
        let hdrStaticMetadata = configuration.effectiveDisplayState.hdrStaticMetadata.map {
            LumenBridgeHDRStaticMetadataBox(
                redPrimaryX: $0.redPrimaryX,
                redPrimaryY: $0.redPrimaryY,
                greenPrimaryX: $0.greenPrimaryX,
                greenPrimaryY: $0.greenPrimaryY,
                bluePrimaryX: $0.bluePrimaryX,
                bluePrimaryY: $0.bluePrimaryY,
                whitePointX: $0.whitePointX,
                whitePointY: $0.whitePointY,
                maxDisplayLuminance: $0.maxDisplayLuminance,
                minDisplayLuminance: $0.minDisplayLuminance,
                maxContentLightLevel: $0.maxContentLightLevel,
                maxFrameAverageLightLevel: $0.maxFrameAverageLightLevel,
                maxFullFrameLuminance: $0.maxFullFrameLuminance
            )
        }
        let sinkRequest = LumenBridgeSinkRequestBox(
            mode: LumenBridgeSinkModeBox(
                hidpi: configuration.sinkRequest.mode.hidpi,
                scaleExplicit: configuration.sinkRequest.mode.scaleExplicit,
                modeIsLogical: configuration.sinkRequest.mode.modeIsLogical,
                scalePercent: configuration.sinkRequest.mode.scalePercent
            ),
            capability: LumenBridgeSinkCapabilityBox(
                gamutRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.sinkRequest.capability.gamut),
                transferRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.sinkRequest.capability.transfer),
                currentEDRHeadroom: configuration.sinkRequest.capability.currentEDRHeadroom,
                potentialEDRHeadroom: configuration.sinkRequest.capability.potentialEDRHeadroom,
                currentPeakLuminanceNits: configuration.sinkRequest.capability.currentPeakLuminanceNits,
                potentialPeakLuminanceNits: configuration.sinkRequest.capability.potentialPeakLuminanceNits,
                supportsFrameGatedHDR: configuration.sinkRequest.capability.supportsFrameGatedHDR,
                supportsHDRTileOverlay: configuration.sinkRequest.capability.supportsHDRTileOverlay,
                supportsPerFrameHDRMetadata: configuration.sinkRequest.capability.supportsPerFrameHDRMetadata
            ),
            dynamicRangeTransportRawValue: Int(configuration.sinkRequest.dynamicRangeTransport.rawValue)
        )
        self.init(
            displayID: configuration.displayID,
            codecRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.codec),
            preprocessStrategyRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.preprocessStrategy),
            queueProfileRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.queueProfile),
            targetFrameRate: configuration.targetFrameRate,
            targetVideoBitRateKbps: configuration.targetVideoBitRateKbps,
            requestedWidth: configuration.requestedWidth ?? 0,
            requestedHeight: configuration.requestedHeight ?? 0,
            sinkRequest: sinkRequest,
            effectiveDisplayState: LumenBridgeEffectiveDisplayStateBox(
                gamutRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.effectiveDisplayState.gamut),
                transferRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.effectiveDisplayState.transfer),
                hdrStaticMetadata: hdrStaticMetadata
            )
        )
    }

    var swiftValue: LumenMacCaptureConfiguration {
        let hdrStaticMetadata = effectiveDisplayState.hdrStaticMetadata.map {
            LumenHDRStaticMetadata(
                redPrimaryX: $0.redPrimaryX,
                redPrimaryY: $0.redPrimaryY,
                greenPrimaryX: $0.greenPrimaryX,
                greenPrimaryY: $0.greenPrimaryY,
                bluePrimaryX: $0.bluePrimaryX,
                bluePrimaryY: $0.bluePrimaryY,
                whitePointX: $0.whitePointX,
                whitePointY: $0.whitePointY,
                maxDisplayLuminance: $0.maxDisplayLuminance,
                minDisplayLuminance: $0.minDisplayLuminance,
                maxContentLightLevel: $0.maxContentLightLevel,
                maxFrameAverageLightLevel: $0.maxFrameAverageLightLevel,
                maxFullFrameLuminance: $0.maxFullFrameLuminance
            )
        }
        return LumenMacCaptureConfiguration(
            displayID: displayID,
            codec: LumenBridgeObjCFacade.codec(fromRawValue: codecRawValue),
            preprocessStrategy: LumenBridgeObjCFacade.preprocessStrategy(fromRawValue: preprocessStrategyRawValue),
            queueProfile: LumenBridgeObjCFacade.queueProfile(fromRawValue: queueProfileRawValue),
            targetFrameRate: targetFrameRate,
            targetVideoBitRateKbps: targetVideoBitRateKbps,
            requestedWidth: requestedWidth,
            requestedHeight: requestedHeight,
            sinkRequest: LumenBridgeSinkRequest(
                mode: LumenBridgeSinkMode(
                    hidpi: sinkRequest.mode.hidpi,
                    scaleExplicit: sinkRequest.mode.scaleExplicit,
                    modeIsLogical: sinkRequest.mode.modeIsLogical,
                    scalePercent: sinkRequest.mode.scalePercent
                ),
                capability: LumenBridgeSinkCapability(
                    gamut: LumenBridgeObjCFacade.clientSinkGamut(fromRawValue: sinkRequest.capability.gamutRawValue),
                    transfer: LumenBridgeObjCFacade.clientSinkTransfer(fromRawValue: sinkRequest.capability.transferRawValue),
                    currentEDRHeadroom: sinkRequest.capability.currentEDRHeadroom,
                    potentialEDRHeadroom: sinkRequest.capability.potentialEDRHeadroom,
                    currentPeakLuminanceNits: sinkRequest.capability.currentPeakLuminanceNits,
                    potentialPeakLuminanceNits: sinkRequest.capability.potentialPeakLuminanceNits,
                    supportsFrameGatedHDR: sinkRequest.capability.supportsFrameGatedHDR,
                    supportsHDRTileOverlay: sinkRequest.capability.supportsHDRTileOverlay,
                    supportsPerFrameHDRMetadata: sinkRequest.capability.supportsPerFrameHDRMetadata
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransport(
                    rawValue: UInt32(sinkRequest.dynamicRangeTransportRawValue)
                )
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: LumenBridgeObjCFacade.clientSinkGamut(fromRawValue: effectiveDisplayState.gamutRawValue),
                transfer: LumenBridgeObjCFacade.clientSinkTransfer(fromRawValue: effectiveDisplayState.transferRawValue),
                hdrStaticMetadata: hdrStaticMetadata
            )
        )
    }
}

@objcMembers
public final class LumenBridgeAudioConfigurationBox: NSObject {
    public let sourceKindRawValue: Int
    public let displayID: UInt32
    public let excludesCurrentProcessAudio: Bool
    public let inputID: String?
    public let sampleRate: Int
    public let channelCount: Int
    public let frameSize: Int

    public init(
        sourceKindRawValue: Int,
        displayID: UInt32,
        excludesCurrentProcessAudio: Bool,
        inputID: String?,
        sampleRate: Int,
        channelCount: Int,
        frameSize: Int
    ) {
        self.sourceKindRawValue = sourceKindRawValue
        self.displayID = displayID
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.inputID = inputID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameSize = frameSize
    }

    convenience init(configuration: LumenMacAudioCaptureConfiguration) {
        switch configuration.source {
        case .microphone(let inputID):
            self.init(
                sourceKindRawValue: LumenBridgeObjCFacade.rawValue(for: LumenAudioCaptureSourceKind.microphone),
                displayID: 0,
                excludesCurrentProcessAudio: false,
                inputID: inputID,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                frameSize: configuration.frameSize
            )
        case .systemOutput(let displayID, let excludesCurrentProcessAudio):
            self.init(
                sourceKindRawValue: LumenBridgeObjCFacade.rawValue(for: LumenAudioCaptureSourceKind.systemOutput),
                displayID: displayID,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio,
                inputID: nil,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                frameSize: configuration.frameSize
            )
        }
    }

    var swiftValue: LumenMacAudioCaptureConfiguration {
        let sourceKind = LumenBridgeObjCFacade.audioSourceKind(fromRawValue: sourceKindRawValue)
        switch sourceKind {
        case .microphone:
            return .microphone(
                inputID: inputID?.isEmpty == false ? inputID : nil,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameSize: frameSize
            )
        case .systemOutput:
            return .systemOutput(
                displayID: displayID,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameSize: frameSize,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio
            )
        }
    }
}

@objcMembers
public final class LumenBridgeStatusBox: NSObject {
    public let coreVersion: String
    public let runtimeDescription: String
    public let integrationStatus: String
    public let captureSessionRunning: Bool
    public let audioCaptureSessionRunning: Bool
    public let automaticCaptureOrchestrationRunning: Bool

    init(snapshot: LumenBridgeStatus) {
        self.coreVersion = snapshot.coreVersion
        self.runtimeDescription = snapshot.runtimeDescription
        self.integrationStatus = snapshot.integrationStatus
        self.captureSessionRunning = snapshot.captureSessionRunning
        self.audioCaptureSessionRunning = snapshot.audioCaptureSessionRunning
        self.automaticCaptureOrchestrationRunning = snapshot.automaticCaptureOrchestrationRunning
    }
}

@objcMembers
public final class LumenBridgeAudioForwardingSnapshotBox: NSObject {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let hasLastFrame: Bool
    public let lastFrameSequenceNumber: UInt64
    public let lastFrameHostTimeNanoseconds: UInt64
    public let lastFrameSampleRate: Int
    public let lastFrameChannelCount: Int
    public let lastFrameFrameCount: Int
    public let lastFramePCMByteCount: Int
    public let lastEventKindRawValue: Int

    init(snapshot: LumenBridgeAudioForwardingSnapshot) {
        self.frameCount = snapshot.frameCount
        self.eventCount = snapshot.eventCount
        self.queuedFrameCount = snapshot.queuedFrameCount
        self.queuedEventCount = snapshot.queuedEventCount
        self.droppedFrameCount = snapshot.droppedFrameCount
        self.droppedEventCount = snapshot.droppedEventCount
        self.hasLastFrame = snapshot.lastFrameSequenceNumber != nil
        self.lastFrameSequenceNumber = snapshot.lastFrameSequenceNumber ?? 0
        self.lastFrameHostTimeNanoseconds = snapshot.lastFrameHostTimeNanoseconds ?? 0
        self.lastFrameSampleRate = snapshot.lastFrameSampleRate ?? 0
        self.lastFrameChannelCount = snapshot.lastFrameChannelCount ?? 0
        self.lastFrameFrameCount = snapshot.lastFrameFrameCount ?? 0
        self.lastFramePCMByteCount = snapshot.lastFramePCMByteCount
        self.lastEventKindRawValue = snapshot.lastEventKind.map(LumenBridgeObjCFacade.rawValue(for:)) ?? -1
    }
}

@objcMembers
public final class LumenBridgeVideoForwardingSnapshotBox: NSObject {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let hasLastSampleBuffer: Bool
    public let lastFrameCodecRawValue: Int
    public let lastFramePayloadSize: Int
    public let hasLastFrameSourceSequenceNumber: Bool
    public let lastFrameSourceSequenceNumber: UInt64
    public let hasLastFrameSourceDisplayTime: Bool
    public let lastFrameSourceDisplayTime: UInt64
    public let lastFrameIsKeyFrame: Bool
    public let lastFrameIsHDRSignaled: Bool
    public let lastEventKindRawValue: Int

    init(snapshot: LumenBridgeVideoForwardingSnapshot) {
        self.frameCount = snapshot.frameCount
        self.eventCount = snapshot.eventCount
        self.queuedFrameCount = snapshot.queuedFrameCount
        self.queuedEventCount = snapshot.queuedEventCount
        self.droppedFrameCount = snapshot.droppedFrameCount
        self.droppedEventCount = snapshot.droppedEventCount
        self.hasLastSampleBuffer = snapshot.hasLastSampleBuffer
        self.lastFrameCodecRawValue = snapshot.lastFrameCodec.map(LumenBridgeObjCFacade.rawValue(for:)) ?? -1
        self.lastFramePayloadSize = snapshot.lastFramePayloadSize
        self.hasLastFrameSourceSequenceNumber = snapshot.lastFrameSourceSequenceNumber != nil
        self.lastFrameSourceSequenceNumber = snapshot.lastFrameSourceSequenceNumber ?? 0
        self.hasLastFrameSourceDisplayTime = snapshot.lastFrameSourceDisplayTime != nil
        self.lastFrameSourceDisplayTime = snapshot.lastFrameSourceDisplayTime ?? 0
        self.lastFrameIsKeyFrame = snapshot.lastFrameIsKeyFrame
        self.lastFrameIsHDRSignaled = snapshot.lastFrameIsHDRSignaled
        self.lastEventKindRawValue = snapshot.lastEventKind.map(LumenBridgeObjCFacade.rawValue(for:)) ?? -1
    }
}

@objcMembers
public final class LumenBridgeDrainedAudioFrameBox: NSObject {
    public let sequenceNumber: UInt64
    public let hostTimeNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let pcmFloat32LE: NSData

    init(frame: LumenBridgeDrainedAudioFrame) {
        self.sequenceNumber = frame.sequenceNumber
        self.hostTimeNanoseconds = frame.hostTimeNanoseconds
        self.sampleRate = frame.sampleRate
        self.channelCount = frame.channelCount
        self.frameCount = frame.frameCount
        self.pcmFloat32LE = frame.pcmFloat32LE as NSData
    }
}

@objcMembers
public final class LumenBridgeDrainedFrameBox: NSObject {
    public let codecRawValue: Int
    public let payloadSize: Int
    public let sourceSequenceNumber: UInt64
    public let sourceDisplayTime: UInt64
    public let hasOutputCallbackLatencyMilliseconds: Bool
    public let outputCallbackLatencyMilliseconds: Double
    public let isKeyFrame: Bool
    public let isHDRSignaled: Bool
    public let isReplay: Bool
    public let sampleBuffer: CMSampleBuffer

    init(frame: LumenBridgeDrainedVideoFrame) {
        self.codecRawValue = LumenBridgeObjCFacade.rawValue(for: frame.codec)
        self.payloadSize = frame.payloadSize
        self.sourceSequenceNumber = frame.sourceSequenceNumber
        self.sourceDisplayTime = frame.sourceDisplayTime
        self.hasOutputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds != nil
        self.outputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds ?? 0
        self.isKeyFrame = frame.isKeyFrame
        self.isHDRSignaled = frame.isHDRSignaled
        self.isReplay = frame.isReplay
        self.sampleBuffer = frame.sampleBuffer
    }
}

@objcMembers
public final class LumenBridgeDrainedAudioEventBox: NSObject {
    public let kindRawValue: Int
    public let message: String?
    public let hasStopStatus: Bool
    public let stopStatus: Int32
    public let hasAutomaticRestartCount: Bool
    public let automaticRestartCount: UInt64
    public let hasSourceSequenceNumber: Bool
    public let sourceSequenceNumber: UInt64

    init(event: LumenBridgeDrainedAudioEvent) {
        self.kindRawValue = LumenBridgeObjCFacade.rawValue(for: event.kind)
        self.message = event.message
        self.hasStopStatus = event.stopStatus != nil
        self.stopStatus = event.stopStatus ?? 0
        self.hasAutomaticRestartCount = event.automaticRestartCount != nil
        self.automaticRestartCount = event.automaticRestartCount ?? 0
        self.hasSourceSequenceNumber = event.sourceSequenceNumber != nil
        self.sourceSequenceNumber = event.sourceSequenceNumber ?? 0
    }
}

@objcMembers
public final class LumenBridgeDrainedEventBox: NSObject {
    public let kindRawValue: Int
    public let message: String?
    public let hasStopStatus: Bool
    public let stopStatus: Int32
    public let hasAutomaticRestartCount: Bool
    public let automaticRestartCount: UInt64
    public let hasSourceDisplayTime: Bool
    public let sourceDisplayTime: UInt64

    init(event: LumenBridgeDrainedVideoEvent) {
        self.kindRawValue = LumenBridgeObjCFacade.rawValue(for: event.kind)
        self.message = event.message
        self.hasStopStatus = event.stopStatus != nil
        self.stopStatus = event.stopStatus ?? 0
        self.hasAutomaticRestartCount = event.automaticRestartCount != nil
        self.automaticRestartCount = event.automaticRestartCount ?? 0
        self.hasSourceDisplayTime = event.sourceDisplayTime != nil
        self.sourceDisplayTime = event.sourceDisplayTime ?? 0
    }
}

@objcMembers
public final class LumenBridgeObjCFacade: NSObject {
    private static let logger = Logger(subsystem: "dev.skyline23.lumen", category: "MacBridgeObjCFacade")
    private static let keyFrameRequestTimeout: DispatchTimeInterval = .milliseconds(250)
    private let runtime: LumenBridgeRuntime

    @objc public static func runtimeStatusDidChangeNotificationName() -> String {
        LumenBridgeRuntime.statusDidChangeNotification.rawValue
    }

    public override init() {
        self.runtime = LumenBridgeRuntime.shared
        super.init()
    }

    @objc public static func requestImmediateCaptureKeyFrameSharedSync() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer {
                semaphore.signal()
            }
            await LumenBridgeRuntime.shared.requestImmediateCaptureKeyFrame()
        }
        if semaphore.wait(timeout: .now() + keyFrameRequestTimeout) == .timedOut {
            logger.warning("Timed out waiting for immediate ScreenCaptureKit keyframe request; continuing without blocking video teardown")
        }
    }

    @objc public static func restartCaptureSharedSync(_ reason: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await LumenBridgeRuntime.shared.restartCapture(reason: reason)
            semaphore.signal()
        }
        semaphore.wait()
    }

    public func makePanelNativeConfiguration(displayID: UInt32) -> LumenBridgeConfigurationBox {
        LumenBridgeConfigurationBox(configuration: .panelNative(displayID: displayID))
    }

    public func makeDefaultMicrophoneAudioConfiguration() -> LumenBridgeAudioConfigurationBox {
        LumenBridgeAudioConfigurationBox(configuration: .microphone())
    }

    public func makeSystemOutputAudioConfiguration(displayID: UInt32) -> LumenBridgeAudioConfigurationBox {
        LumenBridgeAudioConfigurationBox(configuration: .systemOutput(displayID: displayID))
    }

    public func startCaptureSync(
        _ configuration: LumenBridgeConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        let runtime = runtime
        let configuration = configuration.swiftValue
        do {
            try blockingRun {
                try await runtime.startCapture(configuration: configuration)
            }
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func stopCaptureSync() {
        let runtime = runtime
        try? blockingRun {
            await runtime.stopCapture()
        }
    }

    public func requestImmediateCaptureKeyFrameSync() {
        let runtime = runtime
        try? blockingRun {
            await runtime.requestImmediateCaptureKeyFrame()
        }
    }

    public func restartCaptureSync(_ reason: String) {
        let runtime = runtime
        try? blockingRun {
            await runtime.restartCapture(reason: reason)
        }
    }

    public func startAudioCaptureSync(
        _ configuration: LumenBridgeAudioConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        let runtime = runtime
        let configuration = configuration.swiftValue
        do {
            try blockingRun {
                try await runtime.startAudioCapture(configuration: configuration)
            }
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func stopAudioCaptureSync() {
        let runtime = runtime
        try? blockingRun {
            await runtime.stopAudioCapture()
        }
    }

    public func copyStatusSnapshotSync() -> LumenBridgeStatusBox {
        let runtime = runtime
        let snapshot = try? blockingRun {
            await runtime.statusSnapshot()
        }
        return snapshot.map(LumenBridgeStatusBox.init(snapshot:)) ?? LumenBridgeStatusBox(
            snapshot: LumenBridgeStatus(
                coreVersion: "Rust ABI \(LumenEngineBridgeABIVersion())",
                runtimeDescription: "Rust host with Swift macOS capture adapters",
                integrationStatus: "LumenBridgeObjCFacade failed to read the actor-backed status snapshot.",
                captureSessionRunning: false,
                audioCaptureSessionRunning: false,
                automaticCaptureOrchestrationRunning: false
            )
        )
    }

    public func configureVideoForwardingSync(frameCapacity: Int, eventCapacity: Int) {
        let runtime = runtime
        try? blockingRun {
            await runtime.configureVideoForwarding(
                frameCapacity: frameCapacity,
                eventCapacity: eventCapacity
            )
        }
    }

    public func copyVideoForwardingSnapshotSync() -> LumenBridgeVideoForwardingSnapshotBox {
        let runtime = runtime
        let snapshot = try? blockingRun {
            await runtime.videoForwardingSnapshot()
        }
        return snapshot.map(LumenBridgeVideoForwardingSnapshotBox.init(snapshot:)) ?? LumenBridgeVideoForwardingSnapshotBox(
            snapshot: LumenBridgeVideoForwardingSnapshot(
                frameCount: 0,
                eventCount: 0,
                queuedFrameCount: 0,
                queuedEventCount: 0,
                droppedFrameCount: 0,
                droppedEventCount: 0,
                hasLastSampleBuffer: false,
                lastFrameCodec: nil,
                lastFramePayloadSize: 0,
                lastFrameSourceSequenceNumber: nil,
                lastFrameSourceDisplayTime: nil,
                lastFrameIsKeyFrame: false,
                lastFrameIsHDRSignaled: false,
                lastEventKind: nil
            )
        )
    }

    public func copyCaptureDiagnosticsSync() -> NSString {
        let runtime = runtime
        return ((try? blockingRun {
            await runtime.captureDiagnosticsString()
        }) ?? "n/a") as NSString
    }

    public func configureAudioForwardingSync(frameCapacity: Int, eventCapacity: Int) {
        let runtime = runtime
        try? blockingRun {
            await runtime.configureAudioForwarding(
                frameCapacity: frameCapacity,
                eventCapacity: eventCapacity
            )
        }
    }

    public func copyAudioForwardingSnapshotSync() -> LumenBridgeAudioForwardingSnapshotBox {
        let runtime = runtime
        let snapshot = try? blockingRun {
            await runtime.audioForwardingSnapshot()
        }
        return snapshot.map(LumenBridgeAudioForwardingSnapshotBox.init(snapshot:)) ?? LumenBridgeAudioForwardingSnapshotBox(
            snapshot: LumenBridgeAudioForwardingSnapshot(
                frameCount: 0,
                eventCount: 0,
                queuedFrameCount: 0,
                queuedEventCount: 0,
                droppedFrameCount: 0,
                droppedEventCount: 0,
                lastFrameSequenceNumber: nil,
                lastFrameHostTimeNanoseconds: nil,
                lastFrameSampleRate: nil,
                lastFrameChannelCount: nil,
                lastFrameFrameCount: nil,
                lastFramePCMByteCount: 0,
                lastEventKind: nil
            )
        )
    }

    public func popNextVideoForwardedFrameSync() -> LumenBridgeDrainedFrameBox? {
        let runtime = runtime
        let frame = try? blockingRun { await runtime.drainNextVideoForwardedFrame() }
        return frame.flatMap { $0 }.map(LumenBridgeDrainedFrameBox.init(frame:))
    }

    public func popNextVideoForwardedEventSync() -> LumenBridgeDrainedEventBox? {
        let runtime = runtime
        let event = try? blockingRun { await runtime.drainNextVideoForwardedEvent() }
        return event.flatMap { $0 }.map(LumenBridgeDrainedEventBox.init(event:))
    }

    public func popNextVideoForwardedAudioFrameSync() -> LumenBridgeDrainedAudioFrameBox? {
        let runtime = runtime
        let frame = try? blockingRun { await runtime.drainNextVideoForwardedAudioFrame() }
        return frame.flatMap { $0 }.map(LumenBridgeDrainedAudioFrameBox.init(frame:))
    }

    public func popNextVideoForwardedAudioEventSync() -> LumenBridgeDrainedAudioEventBox? {
        let runtime = runtime
        let event = try? blockingRun { await runtime.drainNextVideoForwardedAudioEvent() }
        return event.flatMap { $0 }.map(LumenBridgeDrainedAudioEventBox.init(event:))
    }

    private func blockingRun<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Result<T, Error>?>(nil)
        Task {
            do {
                let value = try await operation()
                result.withLock { $0 = .success(value) }
            } catch {
                result.withLock { $0 = .failure(error) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.withLock { result in
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            case .none:
                fatalError("LumenBridgeObjCFacade blockingRun resolved without a result")
            }
        }
    }
}

extension LumenBridgeObjCFacade {
    static func codec(fromRawValue rawValue: Int) -> LumenCaptureCodec {
        switch rawValue {
        case Int(LumenMacCaptureCodecH264.rawValue):
            return .h264
        case Int(LumenMacCaptureCodecHEVC.rawValue):
            return .hevc
        default:
            return .hevc
        }
    }

    static func preprocessStrategy(fromRawValue rawValue: Int) -> LumenCapturePreprocessStrategy {
        switch rawValue {
        case 1:
            return .downscale2x
        default:
            return .none
        }
    }

    static func queueProfile(fromRawValue rawValue: Int) -> LumenCaptureQueueProfile {
        switch rawValue {
        case 4:
            return .auto
        case 0:
            return .q1
        case 1:
            return .q2
        case 2:
            return .q3
        case 3:
            return .q4
        default:
            return .q2
        }
    }

    static func clientSinkGamut(fromRawValue rawValue: Int) -> LumenClientSinkGamut {
        switch rawValue {
        case 1:
            return .srgb
        case 2:
            return .displayP3
        case 3:
            return .rec2020
        default:
            return .unknown
        }
    }

    static func clientSinkTransfer(fromRawValue rawValue: Int) -> LumenClientSinkTransfer {
        switch rawValue {
        case 1:
            return .sdr
        case 2:
            return .pq
        case 3:
            return .hlg
        default:
            return .unknown
        }
    }

    static func audioSourceKind(fromRawValue rawValue: Int) -> LumenAudioCaptureSourceKind {
        switch rawValue {
        case 1:
            return .systemOutput
        default:
            return .microphone
        }
    }

    static func rawValue(for codec: LumenCaptureCodec) -> Int {
        switch codec {
        case .h264:
            return Int(LumenMacCaptureCodecH264.rawValue)
        case .hevc:
            return Int(LumenMacCaptureCodecHEVC.rawValue)
        }
    }

    static func rawValue(for strategy: LumenCapturePreprocessStrategy) -> Int {
        switch strategy {
        case .none:
            return 0
        case .downscale2x:
            return 1
        }
    }

    static func rawValue(for queueProfile: LumenCaptureQueueProfile) -> Int {
        switch queueProfile {
        case .auto:
            return 4
        case .q1:
            return 0
        case .q2:
            return 1
        case .q3:
            return 2
        case .q4:
            return 3
        }
    }

    static func rawValue(for clientSinkGamut: LumenClientSinkGamut) -> Int {
        switch clientSinkGamut {
        case .unknown:
            return 0
        case .srgb:
            return 1
        case .displayP3:
            return 2
        case .rec2020:
            return 3
        }
    }

    static func rawValue(for clientSinkTransfer: LumenClientSinkTransfer) -> Int {
        switch clientSinkTransfer {
        case .unknown:
            return 0
        case .sdr:
            return 1
        case .pq:
            return 2
        case .hlg:
            return 3
        }
    }

    static func rawValue(for audioSourceKind: LumenAudioCaptureSourceKind) -> Int {
        switch audioSourceKind {
        case .microphone:
            return 0
        case .systemOutput:
            return 1
        }
    }

    static func rawValue(for eventKind: LumenBridgeCaptureEventKind) -> Int {
        switch eventKind {
        case .started:
            return Int(LumenMacCaptureEventKindStarted.rawValue)
        case .stopped:
            return Int(LumenMacCaptureEventKindStopped.rawValue)
        case .restarted:
            return Int(LumenMacCaptureEventKindRestarted.rawValue)
        case .failed:
            return Int(LumenMacCaptureEventKindFailed.rawValue)
        case .droppedFrame:
            return Int(LumenMacCaptureEventKindDroppedFrame.rawValue)
        case .coalescedFrame:
            return Int(LumenMacCaptureEventKindCoalescedFrame.rawValue)
        }
    }
}
