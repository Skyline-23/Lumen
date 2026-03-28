import ApolloCore
import CoreMedia
import Foundation

@objcMembers
public final class ApolloBridgeSinkModeBox: NSObject {
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
public final class ApolloBridgeSinkCapabilityBox: NSObject {
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
public final class ApolloBridgeHDRStaticMetadataBox: NSObject {
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
public final class ApolloBridgeSinkRequestBox: NSObject {
    public let mode: ApolloBridgeSinkModeBox
    public let capability: ApolloBridgeSinkCapabilityBox
    public let dynamicRangeTransportRawValue: Int

    public init(
        mode: ApolloBridgeSinkModeBox,
        capability: ApolloBridgeSinkCapabilityBox,
        dynamicRangeTransportRawValue: Int
    ) {
        self.mode = mode
        self.capability = capability
        self.dynamicRangeTransportRawValue = dynamicRangeTransportRawValue
    }
}

@objcMembers
public final class ApolloBridgeEffectiveDisplayStateBox: NSObject {
    public let gamutRawValue: Int
    public let transferRawValue: Int
    public let hdrStaticMetadata: ApolloBridgeHDRStaticMetadataBox?

    public init(
        gamutRawValue: Int,
        transferRawValue: Int,
        hdrStaticMetadata: ApolloBridgeHDRStaticMetadataBox?
    ) {
        self.gamutRawValue = gamutRawValue
        self.transferRawValue = transferRawValue
        self.hdrStaticMetadata = hdrStaticMetadata
    }
}

@objcMembers
public final class ApolloBridgeConfigurationBox: NSObject {
    public let displayID: UInt32
    public let codecRawValue: Int
    public let preprocessStrategyRawValue: Int
    public let queueProfileRawValue: Int
    public let showCursor: Bool
    public let targetFrameRate: Int
    public let targetVideoBitRateKbps: Int
    public let requestedWidth: Int
    public let requestedHeight: Int
    public let sinkRequest: ApolloBridgeSinkRequestBox
    public let effectiveDisplayState: ApolloBridgeEffectiveDisplayStateBox

    public init(
        displayID: UInt32,
        codecRawValue: Int,
        preprocessStrategyRawValue: Int,
        queueProfileRawValue: Int,
        showCursor: Bool,
        targetFrameRate: Int,
        targetVideoBitRateKbps: Int,
        requestedWidth: Int,
        requestedHeight: Int,
        sinkRequest: ApolloBridgeSinkRequestBox,
        effectiveDisplayState: ApolloBridgeEffectiveDisplayStateBox
    ) {
        self.displayID = displayID
        self.codecRawValue = codecRawValue
        self.preprocessStrategyRawValue = preprocessStrategyRawValue
        self.queueProfileRawValue = queueProfileRawValue
        self.showCursor = showCursor
        self.targetFrameRate = targetFrameRate
        self.targetVideoBitRateKbps = targetVideoBitRateKbps
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.sinkRequest = sinkRequest
        self.effectiveDisplayState = effectiveDisplayState
    }

    convenience init(configuration: ApolloMacDisplayKitCaptureConfiguration) {
        let hdrStaticMetadata = configuration.effectiveDisplayState.hdrStaticMetadata.map {
            ApolloBridgeHDRStaticMetadataBox(
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
        let sinkRequest = ApolloBridgeSinkRequestBox(
            mode: ApolloBridgeSinkModeBox(
                hidpi: configuration.sinkRequest.mode.hidpi,
                scaleExplicit: configuration.sinkRequest.mode.scaleExplicit,
                modeIsLogical: configuration.sinkRequest.mode.modeIsLogical,
                scalePercent: configuration.sinkRequest.mode.scalePercent
            ),
            capability: ApolloBridgeSinkCapabilityBox(
                gamutRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.sinkRequest.capability.gamut),
                transferRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.sinkRequest.capability.transfer),
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
            codecRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.codec),
            preprocessStrategyRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.preprocessStrategy),
            queueProfileRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.queueProfile),
            showCursor: configuration.showCursor,
            targetFrameRate: configuration.targetFrameRate,
            targetVideoBitRateKbps: configuration.targetVideoBitRateKbps,
            requestedWidth: configuration.requestedWidth ?? 0,
            requestedHeight: configuration.requestedHeight ?? 0,
            sinkRequest: sinkRequest,
            effectiveDisplayState: ApolloBridgeEffectiveDisplayStateBox(
                gamutRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.effectiveDisplayState.gamut),
                transferRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.effectiveDisplayState.transfer),
                hdrStaticMetadata: hdrStaticMetadata
            )
        )
    }

    var swiftValue: ApolloMacDisplayKitCaptureConfiguration {
        let hdrStaticMetadata = effectiveDisplayState.hdrStaticMetadata.map {
            ApolloHDRStaticMetadata(
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
        return ApolloMacDisplayKitCaptureConfiguration(
            displayID: displayID,
            codec: ApolloBridgeObjCFacade.codec(fromRawValue: codecRawValue),
            preprocessStrategy: ApolloBridgeObjCFacade.preprocessStrategy(fromRawValue: preprocessStrategyRawValue),
            queueProfile: ApolloBridgeObjCFacade.queueProfile(fromRawValue: queueProfileRawValue),
            showCursor: showCursor,
            targetFrameRate: targetFrameRate,
            targetVideoBitRateKbps: targetVideoBitRateKbps,
            requestedWidth: requestedWidth,
            requestedHeight: requestedHeight,
            sinkRequest: ApolloBridgeSinkRequest(
                mode: ApolloBridgeSinkMode(
                    hidpi: sinkRequest.mode.hidpi,
                    scaleExplicit: sinkRequest.mode.scaleExplicit,
                    modeIsLogical: sinkRequest.mode.modeIsLogical,
                    scalePercent: sinkRequest.mode.scalePercent
                ),
                capability: ApolloBridgeSinkCapability(
                    gamut: ApolloBridgeObjCFacade.clientSinkGamut(fromRawValue: sinkRequest.capability.gamutRawValue),
                    transfer: ApolloBridgeObjCFacade.clientSinkTransfer(fromRawValue: sinkRequest.capability.transferRawValue),
                    currentEDRHeadroom: sinkRequest.capability.currentEDRHeadroom,
                    potentialEDRHeadroom: sinkRequest.capability.potentialEDRHeadroom,
                    currentPeakLuminanceNits: sinkRequest.capability.currentPeakLuminanceNits,
                    potentialPeakLuminanceNits: sinkRequest.capability.potentialPeakLuminanceNits,
                    supportsFrameGatedHDR: sinkRequest.capability.supportsFrameGatedHDR,
                    supportsHDRTileOverlay: sinkRequest.capability.supportsHDRTileOverlay,
                    supportsPerFrameHDRMetadata: sinkRequest.capability.supportsPerFrameHDRMetadata
                ),
                dynamicRangeTransport: ApolloCoreDynamicRangeTransport(
                    rawValue: UInt32(sinkRequest.dynamicRangeTransportRawValue)
                )
            ),
            effectiveDisplayState: ApolloBridgeEffectiveDisplayState(
                gamut: ApolloBridgeObjCFacade.clientSinkGamut(fromRawValue: effectiveDisplayState.gamutRawValue),
                transfer: ApolloBridgeObjCFacade.clientSinkTransfer(fromRawValue: effectiveDisplayState.transferRawValue),
                hdrStaticMetadata: hdrStaticMetadata
            )
        )
    }
}

@objcMembers
public final class ApolloBridgeAudioConfigurationBox: NSObject {
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

    convenience init(configuration: ApolloMacDisplayKitAudioCaptureConfiguration) {
        switch configuration.source {
        case .microphone(let inputID):
            self.init(
                sourceKindRawValue: ApolloBridgeObjCFacade.rawValue(for: ApolloAudioCaptureSourceKind.microphone),
                displayID: 0,
                excludesCurrentProcessAudio: false,
                inputID: inputID,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                frameSize: configuration.frameSize
            )
        case .systemOutput(let displayID, let excludesCurrentProcessAudio):
            self.init(
                sourceKindRawValue: ApolloBridgeObjCFacade.rawValue(for: ApolloAudioCaptureSourceKind.systemOutput),
                displayID: displayID,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio,
                inputID: nil,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                frameSize: configuration.frameSize
            )
        }
    }

    var swiftValue: ApolloMacDisplayKitAudioCaptureConfiguration {
        let sourceKind = ApolloBridgeObjCFacade.audioSourceKind(fromRawValue: sourceKindRawValue)
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
public final class ApolloBridgeStatusBox: NSObject {
    public let coreVersion: String
    public let runtimeDescription: String
    public let integrationStatus: String
    public let captureSessionRunning: Bool
    public let audioCaptureSessionRunning: Bool
    public let automaticCaptureOrchestrationRunning: Bool

    init(snapshot: ApolloBridgeStatus) {
        self.coreVersion = snapshot.coreVersion
        self.runtimeDescription = snapshot.runtimeDescription
        self.integrationStatus = snapshot.integrationStatus
        self.captureSessionRunning = snapshot.captureSessionRunning
        self.audioCaptureSessionRunning = snapshot.audioCaptureSessionRunning
        self.automaticCaptureOrchestrationRunning = snapshot.automaticCaptureOrchestrationRunning
    }
}

@objcMembers
public final class ApolloBridgeCoreAudioForwardingSnapshotBox: NSObject {
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

    init(snapshot: ApolloBridgeAudioForwardingSnapshot) {
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
        self.lastEventKindRawValue = snapshot.lastEventKind.map(ApolloBridgeObjCFacade.rawValue(for:)) ?? -1
    }
}

@objcMembers
public final class ApolloBridgeCoreForwardingSnapshotBox: NSObject {
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

    init(snapshot: ApolloBridgeCoreForwardingSnapshot) {
        self.frameCount = snapshot.frameCount
        self.eventCount = snapshot.eventCount
        self.queuedFrameCount = snapshot.queuedFrameCount
        self.queuedEventCount = snapshot.queuedEventCount
        self.droppedFrameCount = snapshot.droppedFrameCount
        self.droppedEventCount = snapshot.droppedEventCount
        self.hasLastSampleBuffer = snapshot.hasLastSampleBuffer
        self.lastFrameCodecRawValue = snapshot.lastFrameCodec.map(ApolloBridgeObjCFacade.rawValue(for:)) ?? -1
        self.lastFramePayloadSize = snapshot.lastFramePayloadSize
        self.hasLastFrameSourceSequenceNumber = snapshot.lastFrameSourceSequenceNumber != nil
        self.lastFrameSourceSequenceNumber = snapshot.lastFrameSourceSequenceNumber ?? 0
        self.hasLastFrameSourceDisplayTime = snapshot.lastFrameSourceDisplayTime != nil
        self.lastFrameSourceDisplayTime = snapshot.lastFrameSourceDisplayTime ?? 0
        self.lastFrameIsKeyFrame = snapshot.lastFrameIsKeyFrame
        self.lastFrameIsHDRSignaled = snapshot.lastFrameIsHDRSignaled
        self.lastEventKindRawValue = snapshot.lastEventKind.map(ApolloBridgeObjCFacade.rawValue(for:)) ?? -1
    }
}

@objcMembers
public final class ApolloBridgeDrainedAudioFrameBox: NSObject {
    public let sequenceNumber: UInt64
    public let hostTimeNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let pcmFloat32LE: NSData

    init(frame: ApolloBridgeDrainedAudioFrame) {
        self.sequenceNumber = frame.sequenceNumber
        self.hostTimeNanoseconds = frame.hostTimeNanoseconds
        self.sampleRate = frame.sampleRate
        self.channelCount = frame.channelCount
        self.frameCount = frame.frameCount
        self.pcmFloat32LE = frame.pcmFloat32LE as NSData
    }
}

@objcMembers
public final class ApolloBridgeDrainedFrameBox: NSObject {
    public let codecRawValue: Int
    public let payloadSize: Int
    public let sourceSequenceNumber: UInt64
    public let sourceDisplayTime: UInt64
    public let hasOutputCallbackLatencyMilliseconds: Bool
    public let outputCallbackLatencyMilliseconds: Double
    public let isKeyFrame: Bool
    public let isHDRSignaled: Bool
    public let sampleBuffer: CMSampleBuffer

    init(frame: ApolloBridgeCoreDrainedFrame) {
        self.codecRawValue = ApolloBridgeObjCFacade.rawValue(for: frame.codec)
        self.payloadSize = frame.payloadSize
        self.sourceSequenceNumber = frame.sourceSequenceNumber
        self.sourceDisplayTime = frame.sourceDisplayTime
        self.hasOutputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds != nil
        self.outputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds ?? 0
        self.isKeyFrame = frame.isKeyFrame
        self.isHDRSignaled = frame.isHDRSignaled
        self.sampleBuffer = frame.sampleBuffer
    }
}

@objcMembers
public final class ApolloBridgeDrainedAudioEventBox: NSObject {
    public let kindRawValue: Int
    public let message: String?
    public let hasStopStatus: Bool
    public let stopStatus: Int32
    public let hasAutomaticRestartCount: Bool
    public let automaticRestartCount: UInt64
    public let hasSourceSequenceNumber: Bool
    public let sourceSequenceNumber: UInt64

    init(event: ApolloBridgeDrainedAudioEvent) {
        self.kindRawValue = ApolloBridgeObjCFacade.rawValue(for: event.kind)
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
public final class ApolloBridgeDrainedEventBox: NSObject {
    public let kindRawValue: Int
    public let message: String?
    public let hasStopStatus: Bool
    public let stopStatus: Int32
    public let hasAutomaticRestartCount: Bool
    public let automaticRestartCount: UInt64
    public let hasSourceDisplayTime: Bool
    public let sourceDisplayTime: UInt64

    init(event: ApolloBridgeCoreDrainedEvent) {
        self.kindRawValue = ApolloBridgeObjCFacade.rawValue(for: event.kind)
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
public final class ApolloBridgeObjCFacade: NSObject {
    private let runtime: ApolloBridgeRuntime

    @objc public static func runtimeStatusDidChangeNotificationName() -> String {
        ApolloBridgeRuntime.statusDidChangeNotification.rawValue
    }

    public override init() {
        self.runtime = ApolloBridgeRuntime.shared
        super.init()
    }

    @objc public static func requestImmediateCaptureKeyFrameSharedSync() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await ApolloBridgeRuntime.shared.requestImmediateCaptureKeyFrame()
            semaphore.signal()
        }
        semaphore.wait()
    }

    public func makePanelNativeConfiguration(displayID: UInt32) -> ApolloBridgeConfigurationBox {
        ApolloBridgeConfigurationBox(configuration: .panelNative(displayID: displayID))
    }

    public func makeDefaultMicrophoneAudioConfiguration() -> ApolloBridgeAudioConfigurationBox {
        ApolloBridgeAudioConfigurationBox(configuration: .microphone())
    }

    public func makeSystemOutputAudioConfiguration(displayID: UInt32) -> ApolloBridgeAudioConfigurationBox {
        ApolloBridgeAudioConfigurationBox(configuration: .systemOutput(displayID: displayID))
    }

    public func startMacDisplayKitCaptureSync(
        _ configuration: ApolloBridgeConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        do {
            try blockingRun { [self] in
                try await self.runtime.startMacDisplayKitCapture(configuration: configuration.swiftValue)
            }
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func stopMacDisplayKitCaptureSync() {
        try? blockingRun { [self] in
            await self.runtime.stopMacDisplayKitCapture()
        }
    }

    public func requestImmediateCaptureKeyFrameSync() {
        try? blockingRun { [self] in
            await self.runtime.requestImmediateCaptureKeyFrame()
        }
    }

    public func startMacDisplayKitAudioCaptureSync(
        _ configuration: ApolloBridgeAudioConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        do {
            try blockingRun { [self] in
                try await self.runtime.startMacDisplayKitAudioCapture(configuration: configuration.swiftValue)
            }
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func stopMacDisplayKitAudioCaptureSync() {
        try? blockingRun { [self] in
            await self.runtime.stopMacDisplayKitAudioCapture()
        }
    }

    public func startApolloCoreCaptureAutomationSync() {
        try? blockingRun { [self] in
            await self.runtime.startApolloCoreCaptureAutomation()
        }
    }

    public func stopApolloCoreCaptureAutomationSync() {
        try? blockingRun { [self] in
            await self.runtime.stopApolloCoreCaptureAutomation()
        }
    }

    public func isApolloCoreCaptureAutomationRunningSync() -> Bool {
        (try? blockingRun { [self] in
            await self.runtime.isApolloCoreCaptureAutomationRunning()
        }) ?? false
    }

    public func copyStatusSnapshotSync() -> ApolloBridgeStatusBox {
        (try? blockingRun { [self] in
            ApolloBridgeStatusBox(snapshot: await self.runtime.statusSnapshot())
        }) ?? ApolloBridgeStatusBox(
            snapshot: ApolloBridgeStatus(
                coreVersion: String(cString: ApolloCoreBootstrapVersionString()),
                runtimeDescription: String(cString: ApolloCoreBootstrapRuntimeDescription()),
                integrationStatus: "ApolloBridgeObjCFacade failed to read the actor-backed status snapshot.",
                captureSessionRunning: false,
                audioCaptureSessionRunning: false,
                automaticCaptureOrchestrationRunning: false
            )
        )
    }

    public func configureCoreForwardingSync(frameCapacity: Int, eventCapacity: Int) {
        try? blockingRun { [self] in
            await self.runtime.configureCoreForwarding(
                frameCapacity: frameCapacity,
                eventCapacity: eventCapacity
            )
        }
    }

    public func copyCoreForwardingSnapshotSync() -> ApolloBridgeCoreForwardingSnapshotBox {
        (try? blockingRun { [self] in
            ApolloBridgeCoreForwardingSnapshotBox(
                snapshot: await self.runtime.coreForwardingSnapshot()
            )
        }) ?? ApolloBridgeCoreForwardingSnapshotBox(
            snapshot: ApolloBridgeCoreForwardingSnapshot(
                snapshot: ApolloCoreEncodedCaptureIngressSnapshot()
            )
        )
    }

    public func configureAudioForwardingSync(frameCapacity: Int, eventCapacity: Int) {
        try? blockingRun { [self] in
            await self.runtime.configureAudioForwarding(
                frameCapacity: frameCapacity,
                eventCapacity: eventCapacity
            )
        }
    }

    public func copyAudioForwardingSnapshotSync() -> ApolloBridgeCoreAudioForwardingSnapshotBox {
        (try? blockingRun { [self] in
            ApolloBridgeCoreAudioForwardingSnapshotBox(
                snapshot: await self.runtime.audioForwardingSnapshot()
            )
        }) ?? ApolloBridgeCoreAudioForwardingSnapshotBox(
            snapshot: ApolloBridgeAudioForwardingSnapshot(
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

    public func popNextCoreForwardedFrameSync() -> ApolloBridgeDrainedFrameBox? {
        try? blockingRun { [self] in
            await self.runtime.drainNextCoreForwardedFrame().map {
                ApolloBridgeDrainedFrameBox(frame: $0)
            }
        }
    }

    public func popNextCoreForwardedEventSync() -> ApolloBridgeDrainedEventBox? {
        try? blockingRun { [self] in
            await self.runtime.drainNextCoreForwardedEvent().map {
                ApolloBridgeDrainedEventBox(event: $0)
            }
        }
    }

    public func popNextCoreForwardedAudioFrameSync() -> ApolloBridgeDrainedAudioFrameBox? {
        try? blockingRun { [self] in
            await self.runtime.drainNextCoreForwardedAudioFrame().map {
                ApolloBridgeDrainedAudioFrameBox(frame: $0)
            }
        }
    }

    public func popNextCoreForwardedAudioEventSync() -> ApolloBridgeDrainedAudioEventBox? {
        try? blockingRun { [self] in
            await self.runtime.drainNextCoreForwardedAudioEvent().map {
                ApolloBridgeDrainedAudioEventBox(event: $0)
            }
        }
    }

    private func blockingRun<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let state = BlockingResultBox<T>()
        Task {
            do {
                state.store(result: .success(try await operation()))
            } catch {
                state.store(result: .failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try state.resolve()
    }

    private final class BlockingResultBox<T>: @unchecked Sendable {
        private var result: Result<T, Error>?

        func store(result: Result<T, Error>) {
            self.result = result
        }

        func resolve() throws -> T {
            let result = self.result

            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            case .none:
                fatalError("ApolloBridgeObjCFacade blockingRun resolved without a result")
            }
        }
    }
}

extension ApolloBridgeObjCFacade {
    static func codec(fromRawValue rawValue: Int) -> ApolloCaptureCodec {
        switch rawValue {
        case Int(ApolloCoreCaptureCodecH264.rawValue):
            return .h264
        case Int(ApolloCoreCaptureCodecProResProxy.rawValue):
            return .proResProxy
        case Int(ApolloCoreCaptureCodecHEVC.rawValue):
            return .hevc
        default:
            return .hevc
        }
    }

    static func preprocessStrategy(fromRawValue rawValue: Int) -> ApolloCapturePreprocessStrategy {
        switch rawValue {
        case 1:
            return .downscale2x
        default:
            return .none
        }
    }

    static func queueProfile(fromRawValue rawValue: Int) -> ApolloCaptureQueueProfile {
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

    static func clientSinkGamut(fromRawValue rawValue: Int) -> ApolloClientSinkGamut {
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

    static func clientSinkTransfer(fromRawValue rawValue: Int) -> ApolloClientSinkTransfer {
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

    static func audioSourceKind(fromRawValue rawValue: Int) -> ApolloAudioCaptureSourceKind {
        switch rawValue {
        case 1:
            return .systemOutput
        default:
            return .microphone
        }
    }

    static func rawValue(for codec: ApolloCaptureCodec) -> Int {
        switch codec {
        case .h264:
            return Int(ApolloCoreCaptureCodecH264.rawValue)
        case .hevc:
            return Int(ApolloCoreCaptureCodecHEVC.rawValue)
        case .proResProxy:
            return Int(ApolloCoreCaptureCodecProResProxy.rawValue)
        }
    }

    static func rawValue(for strategy: ApolloCapturePreprocessStrategy) -> Int {
        switch strategy {
        case .none:
            return 0
        case .downscale2x:
            return 1
        }
    }

    static func rawValue(for queueProfile: ApolloCaptureQueueProfile) -> Int {
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

    static func rawValue(for clientSinkGamut: ApolloClientSinkGamut) -> Int {
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

    static func rawValue(for clientSinkTransfer: ApolloClientSinkTransfer) -> Int {
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

    static func rawValue(for audioSourceKind: ApolloAudioCaptureSourceKind) -> Int {
        switch audioSourceKind {
        case .microphone:
            return 0
        case .systemOutput:
            return 1
        }
    }

    static func rawValue(for eventKind: ApolloBridgeCaptureEventKind) -> Int {
        switch eventKind {
        case .started:
            return Int(ApolloCoreCaptureEventKindStarted.rawValue)
        case .stopped:
            return Int(ApolloCoreCaptureEventKindStopped.rawValue)
        case .restarted:
            return Int(ApolloCoreCaptureEventKindRestarted.rawValue)
        case .failed:
            return Int(ApolloCoreCaptureEventKindFailed.rawValue)
        case .droppedFrame:
            return Int(ApolloCoreCaptureEventKindDroppedFrame.rawValue)
        }
    }
}
