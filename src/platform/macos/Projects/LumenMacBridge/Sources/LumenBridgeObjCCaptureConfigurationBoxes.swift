import Foundation

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
    public let sessionEpoch: UInt32
    public let policyRevision: UInt32
    public let codecRawValue: Int
    public let videoProfileRawValue: Int
    public let chromaSubsamplingRawValue: Int
    public let bitDepth: Int
    public let dynamicRangeRawValue: Int
    public let colorRangeRawValue: Int
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
        sessionEpoch: UInt32,
        policyRevision: UInt32,
        codecRawValue: Int,
        videoProfileRawValue: Int,
        chromaSubsamplingRawValue: Int,
        bitDepth: Int,
        dynamicRangeRawValue: Int,
        colorRangeRawValue: Int,
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
        self.sessionEpoch = sessionEpoch
        self.policyRevision = policyRevision
        self.codecRawValue = codecRawValue
        self.videoProfileRawValue = videoProfileRawValue
        self.chromaSubsamplingRawValue = chromaSubsamplingRawValue
        self.bitDepth = bitDepth
        self.dynamicRangeRawValue = dynamicRangeRawValue
        self.colorRangeRawValue = colorRangeRawValue
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
        let effectiveDisplayState = Self.makeEffectiveDisplayStateBox(
            from: configuration.effectiveDisplayState
        )
        self.init(
            displayID: configuration.displayID,
            sessionEpoch: configuration.sessionEpoch,
            policyRevision: configuration.policyRevision,
            codecRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.codec),
            videoProfileRawValue: configuration.videoProfile.rawValue,
            chromaSubsamplingRawValue: configuration.chromaSubsampling.rawValue,
            bitDepth: configuration.bitDepth,
            dynamicRangeRawValue: configuration.dynamicRange.rawValue,
            colorRangeRawValue: configuration.colorRange.rawValue,
            preprocessStrategyRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.preprocessStrategy),
            queueProfileRawValue: LumenBridgeObjCFacade.rawValue(for: configuration.queueProfile),
            targetFrameRate: configuration.targetFrameRate,
            targetVideoBitRateKbps: configuration.targetVideoBitRateKbps,
            requestedWidth: configuration.requestedWidth ?? 0,
            requestedHeight: configuration.requestedHeight ?? 0,
            sinkRequest: Self.makeSinkRequestBox(from: configuration.sinkRequest),
            effectiveDisplayState: effectiveDisplayState
        )
    }

    var swiftValue: LumenMacCaptureConfiguration {
        LumenMacCaptureConfiguration(
            displayID: displayID,
            sessionEpoch: sessionEpoch,
            policyRevision: policyRevision,
            codec: LumenBridgeObjCFacade.codec(fromRawValue: codecRawValue),
            videoProfile: LumenCaptureVideoProfile(rawValue: videoProfileRawValue),
            chromaSubsampling: LumenCaptureChromaSubsampling(rawValue: chromaSubsamplingRawValue),
            bitDepth: bitDepth,
            dynamicRange: LumenCaptureDynamicRange(rawValue: dynamicRangeRawValue),
            colorRange: LumenCaptureColorRange(rawValue: colorRangeRawValue),
            preprocessStrategy: LumenBridgeObjCFacade.preprocessStrategy(fromRawValue: preprocessStrategyRawValue),
            queueProfile: LumenBridgeObjCFacade.queueProfile(fromRawValue: queueProfileRawValue),
            targetFrameRate: targetFrameRate,
            targetVideoBitRateKbps: targetVideoBitRateKbps,
            requestedWidth: requestedWidth,
            requestedHeight: requestedHeight,
            sinkRequest: makeSinkRequest(),
            effectiveDisplayState: makeEffectiveDisplayState()
        )
    }

    private static func makeSinkRequestBox(
        from request: LumenBridgeSinkRequest
    ) -> LumenBridgeSinkRequestBox {
        LumenBridgeSinkRequestBox(
            mode: LumenBridgeSinkModeBox(
                hidpi: request.mode.hidpi,
                scaleExplicit: request.mode.scaleExplicit,
                modeIsLogical: request.mode.modeIsLogical,
                scalePercent: request.mode.scalePercent
            ),
            capability: LumenBridgeSinkCapabilityBox(
                gamutRawValue: LumenBridgeObjCFacade.rawValue(for: request.capability.gamut),
                transferRawValue: LumenBridgeObjCFacade.rawValue(for: request.capability.transfer),
                currentEDRHeadroom: request.capability.currentEDRHeadroom,
                potentialEDRHeadroom: request.capability.potentialEDRHeadroom,
                currentPeakLuminanceNits: request.capability.currentPeakLuminanceNits,
                potentialPeakLuminanceNits: request.capability.potentialPeakLuminanceNits,
                supportsFrameGatedHDR: request.capability.supportsFrameGatedHDR,
                supportsHDRTileOverlay: request.capability.supportsHDRTileOverlay,
                supportsPerFrameHDRMetadata: request.capability.supportsPerFrameHDRMetadata
            ),
            dynamicRangeTransportRawValue: Int(request.dynamicRangeTransport.rawValue)
        )
    }

    private static func makeEffectiveDisplayStateBox(
        from state: LumenBridgeEffectiveDisplayState
    ) -> LumenBridgeEffectiveDisplayStateBox {
        LumenBridgeEffectiveDisplayStateBox(
            gamutRawValue: LumenBridgeObjCFacade.rawValue(for: state.gamut),
            transferRawValue: LumenBridgeObjCFacade.rawValue(for: state.transfer),
            hdrStaticMetadata: state.hdrStaticMetadata.map(makeHDRStaticMetadataBox(from:))
        )
    }

    private static func makeHDRStaticMetadataBox(
        from metadata: LumenHDRStaticMetadata
    ) -> LumenBridgeHDRStaticMetadataBox {
        LumenBridgeHDRStaticMetadataBox(
            redPrimaryX: metadata.redPrimaryX,
            redPrimaryY: metadata.redPrimaryY,
            greenPrimaryX: metadata.greenPrimaryX,
            greenPrimaryY: metadata.greenPrimaryY,
            bluePrimaryX: metadata.bluePrimaryX,
            bluePrimaryY: metadata.bluePrimaryY,
            whitePointX: metadata.whitePointX,
            whitePointY: metadata.whitePointY,
            maxDisplayLuminance: metadata.maxDisplayLuminance,
            minDisplayLuminance: metadata.minDisplayLuminance,
            maxContentLightLevel: metadata.maxContentLightLevel,
            maxFrameAverageLightLevel: metadata.maxFrameAverageLightLevel,
            maxFullFrameLuminance: metadata.maxFullFrameLuminance
        )
    }

    private func makeSinkRequest() -> LumenBridgeSinkRequest {
        LumenBridgeSinkRequest(
            mode: LumenBridgeSinkMode(
                hidpi: sinkRequest.mode.hidpi,
                scaleExplicit: sinkRequest.mode.scaleExplicit,
                modeIsLogical: sinkRequest.mode.modeIsLogical,
                scalePercent: sinkRequest.mode.scalePercent
            ),
            capability: makeSinkCapability(),
            dynamicRangeTransport: LumenMacDynamicRangeTransport(
                rawValue: UInt32(sinkRequest.dynamicRangeTransportRawValue)
            )
        )
    }

    private func makeSinkCapability() -> LumenBridgeSinkCapability {
        LumenBridgeSinkCapability(
            gamut: LumenBridgeObjCFacade.clientSinkGamut(
                fromRawValue: sinkRequest.capability.gamutRawValue
            ),
            transfer: LumenBridgeObjCFacade.clientSinkTransfer(
                fromRawValue: sinkRequest.capability.transferRawValue
            ),
            currentEDRHeadroom: sinkRequest.capability.currentEDRHeadroom,
            potentialEDRHeadroom: sinkRequest.capability.potentialEDRHeadroom,
            currentPeakLuminanceNits: sinkRequest.capability.currentPeakLuminanceNits,
            potentialPeakLuminanceNits: sinkRequest.capability.potentialPeakLuminanceNits,
            supportsFrameGatedHDR: sinkRequest.capability.supportsFrameGatedHDR,
            supportsHDRTileOverlay: sinkRequest.capability.supportsHDRTileOverlay,
            supportsPerFrameHDRMetadata: sinkRequest.capability.supportsPerFrameHDRMetadata
        )
    }

    private func makeEffectiveDisplayState() -> LumenBridgeEffectiveDisplayState {
        LumenBridgeEffectiveDisplayState(
            gamut: LumenBridgeObjCFacade.clientSinkGamut(
                fromRawValue: effectiveDisplayState.gamutRawValue
            ),
            transfer: LumenBridgeObjCFacade.clientSinkTransfer(
                fromRawValue: effectiveDisplayState.transferRawValue
            ),
            hdrStaticMetadata: effectiveDisplayState.hdrStaticMetadata.map {
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
        )
    }
}
