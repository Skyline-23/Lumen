import Foundation
import LumenEngineBridge

public struct LumenHDRStaticMetadata: Equatable, Sendable {
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

    init(bridgeValue: LumenMacHDRStaticMetadata) {
        self.init(
            redPrimaryX: Int(bridgeValue.red_primary_x),
            redPrimaryY: Int(bridgeValue.red_primary_y),
            greenPrimaryX: Int(bridgeValue.green_primary_x),
            greenPrimaryY: Int(bridgeValue.green_primary_y),
            bluePrimaryX: Int(bridgeValue.blue_primary_x),
            bluePrimaryY: Int(bridgeValue.blue_primary_y),
            whitePointX: Int(bridgeValue.white_point_x),
            whitePointY: Int(bridgeValue.white_point_y),
            maxDisplayLuminance: Int(bridgeValue.max_display_luminance),
            minDisplayLuminance: Int(bridgeValue.min_display_luminance),
            maxContentLightLevel: Int(bridgeValue.max_content_light_level),
            maxFrameAverageLightLevel: Int(bridgeValue.max_frame_average_light_level),
            maxFullFrameLuminance: Int(bridgeValue.max_full_frame_luminance)
        )
    }

    var bridgeValue: LumenMacHDRStaticMetadata {
        var metadata = LumenMacHDRStaticMetadata()
        metadata.red_primary_x = Int32(redPrimaryX)
        metadata.red_primary_y = Int32(redPrimaryY)
        metadata.green_primary_x = Int32(greenPrimaryX)
        metadata.green_primary_y = Int32(greenPrimaryY)
        metadata.blue_primary_x = Int32(bluePrimaryX)
        metadata.blue_primary_y = Int32(bluePrimaryY)
        metadata.white_point_x = Int32(whitePointX)
        metadata.white_point_y = Int32(whitePointY)
        metadata.max_display_luminance = Int32(maxDisplayLuminance)
        metadata.min_display_luminance = Int32(minDisplayLuminance)
        metadata.max_content_light_level = Int32(maxContentLightLevel)
        metadata.max_frame_average_light_level = Int32(maxFrameAverageLightLevel)
        metadata.max_full_frame_luminance = Int32(maxFullFrameLuminance)
        return metadata
    }

    var hdrDisplayMetadata: LumenVideoHDRDisplayMetadata {
        LumenVideoHDRDisplayMetadata(
            redPrimary: Self.chromaticityPoint(
                xCoordinate: redPrimaryX,
                yCoordinate: redPrimaryY
            ),
            greenPrimary: Self.chromaticityPoint(
                xCoordinate: greenPrimaryX,
                yCoordinate: greenPrimaryY
            ),
            bluePrimary: Self.chromaticityPoint(
                xCoordinate: bluePrimaryX,
                yCoordinate: bluePrimaryY
            ),
            whitePoint: Self.chromaticityPoint(
                xCoordinate: whitePointX,
                yCoordinate: whitePointY
            ),
            maxLuminance: Double(maxDisplayLuminance),
            minLuminance: Double(minDisplayLuminance) / 10_000.0
        )
    }

    var contentLightLevelInfo: LumenVideoContentLightLevelInfo? {
        guard maxContentLightLevel > 0 || maxFrameAverageLightLevel > 0 else {
            return nil
        }
        return LumenVideoContentLightLevelInfo(
            maximumContentLightLevel: maxContentLightLevel,
            maximumFrameAverageLightLevel: maxFrameAverageLightLevel
        )
    }

    private static func chromaticityPoint(
        xCoordinate: Int,
        yCoordinate: Int
    ) -> LumenVideoChromaticityPoint {
        LumenVideoChromaticityPoint(
            xCoordinate: Double(xCoordinate) / 50_000.0,
            yCoordinate: Double(yCoordinate) / 50_000.0
        )
    }
}

enum LumenBridgeConfigurationPreferences {
    static let configurationFileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Lumen", directoryHint: .isDirectory)
            .appending(path: "lumen.conf", directoryHint: .notDirectory)
    }()

    static func preferredEncoderInputStrategy() -> LumenCaptureEncoderInputStrategy {
        preferredEncoderInputStrategy(
            contents: try? String(
                contentsOf: configurationFileURL,
                encoding: .utf8
            )
        )
    }

    static func preferredEncoderInputStrategy(
        contents: String?
    ) -> LumenCaptureEncoderInputStrategy {
        switch configuredValue(
            forKey: "macos_bridge_encoder_input",
            contents: contents
        ) {
        case LumenCaptureEncoderInputStrategy.bgra.rawValue:
            return .bgra
        case LumenCaptureEncoderInputStrategy.yuv420v8.rawValue, "420", "nv12":
            return .yuv420v8
        case LumenCaptureEncoderInputStrategy.yuv420v10.rawValue, "x420", "p010":
            return .yuv420v10
        default:
            return .auto
        }
    }

    private static func configuredValue(
        forKey key: String,
        contents: String?
    ) -> String? {
        guard let contents else {
            return nil
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let separatorIndex = line.firstIndex(of: "=") else {
                continue
            }

            let candidateKey = String(line[..<separatorIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidateKey == key else {
                continue
            }

            return String(line[line.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        return nil
    }
}

public struct LumenBridgeSinkMode: Equatable, Sendable {
    public let hidpi: Bool
    public let scaleExplicit: Bool
    public let modeIsLogical: Bool
    public let scalePercent: Int

    public init(
        hidpi: Bool = false,
        scaleExplicit: Bool = false,
        modeIsLogical: Bool = false,
        scalePercent: Int = 100
    ) {
        self.hidpi = hidpi
        self.scaleExplicit = scaleExplicit
        self.modeIsLogical = modeIsLogical
        self.scalePercent = max(scalePercent, 1)
    }
}

public struct LumenBridgeSinkCapability: Equatable, Sendable {
    public let gamut: LumenClientSinkGamut
    public let transfer: LumenClientSinkTransfer
    public let currentEDRHeadroom: Float
    public let potentialEDRHeadroom: Float
    public let currentPeakLuminanceNits: Int
    public let potentialPeakLuminanceNits: Int
    public let supportsFrameGatedHDR: Bool
    public let supportsHDRTileOverlay: Bool
    public let supportsPerFrameHDRMetadata: Bool

    public init(
        gamut: LumenClientSinkGamut = .unknown,
        transfer: LumenClientSinkTransfer = .unknown,
        currentEDRHeadroom: Float = 0,
        potentialEDRHeadroom: Float = 0,
        currentPeakLuminanceNits: Int = 0,
        potentialPeakLuminanceNits: Int = 0,
        supportsFrameGatedHDR: Bool = false,
        supportsHDRTileOverlay: Bool = false,
        supportsPerFrameHDRMetadata: Bool = false
    ) {
        self.gamut = gamut
        self.transfer = transfer
        self.currentEDRHeadroom = max(currentEDRHeadroom, 0)
        self.potentialEDRHeadroom = max(potentialEDRHeadroom, 0)
        self.currentPeakLuminanceNits = max(currentPeakLuminanceNits, 0)
        self.potentialPeakLuminanceNits = max(potentialPeakLuminanceNits, 0)
        self.supportsFrameGatedHDR = supportsFrameGatedHDR
        self.supportsHDRTileOverlay = supportsHDRTileOverlay
        self.supportsPerFrameHDRMetadata = supportsPerFrameHDRMetadata
    }
}

public struct LumenBridgeSinkRequest: Equatable, Sendable {
    public let mode: LumenBridgeSinkMode
    public let capability: LumenBridgeSinkCapability
    public let dynamicRangeTransport: LumenMacDynamicRangeTransport

    public init(
        mode: LumenBridgeSinkMode = LumenBridgeSinkMode(),
        capability: LumenBridgeSinkCapability = LumenBridgeSinkCapability(),
        dynamicRangeTransport: LumenMacDynamicRangeTransport =
            LumenMacDynamicRangeTransportUnknown
    ) {
        self.mode = mode
        self.capability = capability
        self.dynamicRangeTransport = dynamicRangeTransport
    }
}

public struct LumenBridgeEffectiveDisplayState: Equatable, Sendable {
    public let gamut: LumenClientSinkGamut
    public let transfer: LumenClientSinkTransfer
    public let hdrStaticMetadata: LumenHDRStaticMetadata?

    public init(
        gamut: LumenClientSinkGamut = .unknown,
        transfer: LumenClientSinkTransfer = .unknown,
        hdrStaticMetadata: LumenHDRStaticMetadata? = nil
    ) {
        self.gamut = gamut
        self.transfer = transfer
        self.hdrStaticMetadata = hdrStaticMetadata
    }
}

public struct LumenMacProtocolAdapter: LumenProtocolAdapter, Equatable, Sendable {
    public let output: LumenProtocolAdapterOutput

    public var requestedTransport: LumenProtocolDynamicRangeTransport {
        output.requestedTransport
    }

    public var negotiatedTransport: LumenProtocolDynamicRangeTransport {
        output.negotiatedTransport
    }

    public var sinkCapability: LumenProtocolSinkCapability {
        output.sinkCapability
    }

    public init(
        requestedTransport: LumenProtocolDynamicRangeTransport,
        negotiatedTransport: LumenProtocolDynamicRangeTransport,
        sinkCapability: LumenProtocolSinkCapability
    ) {
        self.init(
            output: LumenProtocolAdapterOutput(
                requestedTransport: requestedTransport,
                negotiatedTransport: negotiatedTransport,
                sinkCapability: sinkCapability
            )
        )
    }

    public init(output: LumenProtocolAdapterOutput) {
        self.output = output
    }
}
