import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import LumenEngineBridge
import OSLog

public enum LumenCaptureCodec: String, CaseIterable, Codable, Sendable {
    case h264
    case hevc
}

public enum LumenCapturePreprocessStrategy: String, CaseIterable, Codable, Sendable {
    case none
    case downscale2x = "downscale-2x"

}

public enum LumenCaptureQueueProfile: String, CaseIterable, Codable, Sendable {
    case auto
    case q1
    case q2
    case q3
    case q4

    var queueDepthHint: Int {
        switch self {
        case .auto:
            // Keep enough source slack without reviving large stale-frame queues.
            return 3
        case .q1:
            return 1
        case .q2:
            return 2
        case .q3:
            return 3
        case .q4:
            return 4
        }
    }
}

public enum LumenCaptureEncoderInputStrategy: String, CaseIterable, Codable, Sendable {
    case auto
    case bgra
    case yuv420v8 = "420v8"
    case yuv420v10 = "420v10"

}

public enum LumenClientSinkGamut: String, CaseIterable, Codable, Sendable {
    case unknown
    case srgb
    case displayP3 = "display-p3"
    case rec2020

    init(environmentValue: String?) {
        switch environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "display-p3", "display_p3", "p3":
            self = .displayP3
        case "rec2020", "bt2020", "2020":
            self = .rec2020
        case "srgb", "rec709", "709":
            self = .srgb
        default:
            self = .unknown
        }
    }
}

public enum LumenClientSinkTransfer: String, CaseIterable, Codable, Sendable {
    case unknown
    case sdr
    case pq
    case hlg

    init(environmentValue: String?) {
        switch environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pq", "hdr-pq", "st2084", "smpte2084":
            self = .pq
        case "hlg", "hdr-hlg":
            self = .hlg
        case "sdr", "gamma":
            self = .sdr
        default:
            self = .unknown
        }
    }
}

private func lumenDynamicRangeTransportName(_ transport: LumenMacDynamicRangeTransport) -> String {
    switch transport {
    case LumenMacDynamicRangeTransportSDR:
        return "sdr"
    case LumenMacDynamicRangeTransportFullFrameHDR:
        return "full-frame-hdr"
    case LumenMacDynamicRangeTransportFrameGatedHDR:
        return "frame-gated-hdr"
    case LumenMacDynamicRangeTransportSDRBaseHDROverlay:
        return "sdr-base-hdr-overlay"
    default:
        return "unknown"
    }
}

private func lumenDynamicRangeTransportUsesHDR(_ transport: LumenMacDynamicRangeTransport) -> Bool {
    switch transport {
    case LumenMacDynamicRangeTransportFullFrameHDR, LumenMacDynamicRangeTransportFrameGatedHDR:
        return true
    default:
        return false
    }
}

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

    var masteringDisplayColorVolume: LumenVideoMasteringDisplayColorVolume {
        LumenVideoMasteringDisplayColorVolume(
            redPrimary: Self.chromaticityPoint(x: redPrimaryX, y: redPrimaryY),
            greenPrimary: Self.chromaticityPoint(x: greenPrimaryX, y: greenPrimaryY),
            bluePrimary: Self.chromaticityPoint(x: bluePrimaryX, y: bluePrimaryY),
            whitePoint: Self.chromaticityPoint(x: whitePointX, y: whitePointY),
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

    private static func chromaticityPoint(x: Int, y: Int) -> LumenVideoChromaticityPoint {
        LumenVideoChromaticityPoint(
            x: Double(x) / 50_000.0,
            y: Double(y) / 50_000.0
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
        preferredEncoderInputStrategy(contents: try? String(contentsOf: configurationFileURL, encoding: .utf8))
    }

    static func preferredEncoderInputStrategy(contents: String?) -> LumenCaptureEncoderInputStrategy {
        switch configuredValue(forKey: "macos_bridge_encoder_input", contents: contents) {
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

    private static func configuredValue(forKey key: String, contents: String?) -> String? {
        guard let contents else {
            return nil
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let separatorIndex = line.firstIndex(of: "=") else {
                continue
            }

            let candidateKey = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
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
        dynamicRangeTransport: LumenMacDynamicRangeTransport = LumenMacDynamicRangeTransportUnknown
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

public struct LumenMacCaptureConfiguration: Equatable, Sendable {
    private static let supportsPartialHDROverlayProducer = true
    private static let highResolutionPixelCountThreshold = 5_000_000
    private static let veryHighResolutionPixelCountThreshold = 7_000_000

    public let displayID: UInt32
    public let codec: LumenCaptureCodec
    public let videoProfile: LumenCaptureVideoProfile
    public let chromaSubsampling: LumenCaptureChromaSubsampling
    public let bitDepth: Int
    public let dynamicRange: LumenCaptureDynamicRange
    public let colorRange: LumenCaptureColorRange
    public let preprocessStrategy: LumenCapturePreprocessStrategy
    public let queueProfile: LumenCaptureQueueProfile
    public let encoderInputStrategy: LumenCaptureEncoderInputStrategy
    public let targetFrameRate: Int
    public let targetVideoBitRateKbps: Int
    public let requestedWidth: Int?
    public let requestedHeight: Int?
    public let sinkRequest: LumenBridgeSinkRequest
    public let effectiveDisplayState: LumenBridgeEffectiveDisplayState

    public init(
        displayID: UInt32,
        codec: LumenCaptureCodec = .hevc,
        videoProfile: LumenCaptureVideoProfile? = nil,
        chromaSubsampling: LumenCaptureChromaSubsampling? = nil,
        bitDepth: Int? = nil,
        dynamicRange: LumenCaptureDynamicRange? = nil,
        colorRange: LumenCaptureColorRange? = nil,
        preprocessStrategy: LumenCapturePreprocessStrategy = .none,
        queueProfile: LumenCaptureQueueProfile = .auto,
        encoderInputStrategy: LumenCaptureEncoderInputStrategy = .auto,
        targetFrameRate: Int = 120,
        targetVideoBitRateKbps: Int = 0,
        requestedWidth: Int? = nil,
        requestedHeight: Int? = nil,
        sinkRequest: LumenBridgeSinkRequest = LumenBridgeSinkRequest(),
        effectiveDisplayState: LumenBridgeEffectiveDisplayState = LumenBridgeEffectiveDisplayState()
    ) {
        let defaultsToHDR = codec == .hevc &&
            lumenDynamicRangeTransportUsesHDR(sinkRequest.dynamicRangeTransport)
        self.displayID = displayID
        self.codec = codec
        self.videoProfile = videoProfile ?? (codec == .h264 ? .h264High : (defaultsToHDR ? .hevcMain10 : .hevcMain))
        self.chromaSubsampling = chromaSubsampling ?? .yuv420
        self.bitDepth = bitDepth ?? (defaultsToHDR ? 10 : 8)
        self.dynamicRange = dynamicRange ?? (defaultsToHDR ? .hdr10 : .sdr)
        self.colorRange = colorRange ?? .limited
        self.preprocessStrategy = preprocessStrategy
        self.queueProfile = queueProfile
        self.encoderInputStrategy = encoderInputStrategy
        self.targetFrameRate = max(targetFrameRate, 1)
        self.targetVideoBitRateKbps = max(targetVideoBitRateKbps, 0)
        self.requestedWidth = Self.sanitizedDimension(requestedWidth)
        self.requestedHeight = Self.sanitizedDimension(requestedHeight)
        self.sinkRequest = sinkRequest
        self.effectiveDisplayState = effectiveDisplayState
    }

    public func replacingDisplayID(_ displayID: UInt32) -> Self {
        Self(
            displayID: displayID,
            codec: codec,
            videoProfile: videoProfile,
            chromaSubsampling: chromaSubsampling,
            bitDepth: bitDepth,
            dynamicRange: dynamicRange,
            colorRange: colorRange,
            preprocessStrategy: preprocessStrategy,
            queueProfile: queueProfile,
            encoderInputStrategy: encoderInputStrategy,
            targetFrameRate: targetFrameRate,
            targetVideoBitRateKbps: targetVideoBitRateKbps,
            requestedWidth: requestedWidth,
            requestedHeight: requestedHeight,
            sinkRequest: sinkRequest,
            effectiveDisplayState: effectiveDisplayState
        )
    }

    public var virtualDisplayGamut: LumenClientSinkGamut {
        resolvedDisplayGamut
    }

    public var virtualDisplayTransfer: LumenClientSinkTransfer {
        resolvedDisplayTransfer
    }

    public var usesHDRTransport: Bool {
        lumenDynamicRangeTransportUsesHDR(negotiatedDynamicRangeTransport)
    }

    public var sinkPrefersHDRPresentation: Bool {
        switch resolvedDisplayTransfer {
        case .pq, .hlg:
            return true
        case .sdr, .unknown:
            return false
        }
    }

    public var negotiatedDynamicRangeTransport: LumenMacDynamicRangeTransport {
        switch sinkRequest.dynamicRangeTransport {
        case LumenMacDynamicRangeTransportFullFrameHDR:
            guard sinkPrefersHDRPresentation else {
                return LumenMacDynamicRangeTransportSDR
            }
            return codec == .h264 ? LumenMacDynamicRangeTransportSDR : LumenMacDynamicRangeTransportFullFrameHDR
        case LumenMacDynamicRangeTransportFrameGatedHDR:
            guard sinkPrefersHDRPresentation else {
                return LumenMacDynamicRangeTransportSDR
            }
            guard codec != .h264,
                  sinkRequest.capability.supportsFrameGatedHDR else {
                return LumenMacDynamicRangeTransportSDR
            }
            return LumenMacDynamicRangeTransportFrameGatedHDR
        case LumenMacDynamicRangeTransportSDRBaseHDROverlay:
            guard sinkPrefersHDRPresentation else {
                return LumenMacDynamicRangeTransportSDR
            }
            guard codec != .h264 else {
                return LumenMacDynamicRangeTransportSDR
            }
            if Self.supportsPartialHDROverlayProducer,
               sinkRequest.capability.supportsHDRTileOverlay,
               sinkRequest.capability.supportsPerFrameHDRMetadata {
                return LumenMacDynamicRangeTransportSDRBaseHDROverlay
            }
            if sinkRequest.capability.supportsFrameGatedHDR {
                return LumenMacDynamicRangeTransportFrameGatedHDR
            }
            return LumenMacDynamicRangeTransportSDR
        case LumenMacDynamicRangeTransportSDR, LumenMacDynamicRangeTransportUnknown:
            return LumenMacDynamicRangeTransportSDR
        default:
            return LumenMacDynamicRangeTransportSDR
        }
    }

    public var negotiatedQueueProfile: LumenCaptureQueueProfile {
        guard queueProfile == .auto else {
            return queueProfile
        }

        if effectiveTargetFrameRate >= 120 {
            // ScreenCaptureKit needs one surface in delivery, one potentially
            // retained by VideoToolbox, and one free surface for WindowServer.
            // A two-surface pool can freeze after the first frame at 120 Hz.
            return .q3
        }

        if negotiatedDynamicRangeTransport == LumenMacDynamicRangeTransportSDRBaseHDROverlay {
            return usesHighResolutionWorkload ? .q2 : .q4
        }

        if usesHighResolutionWorkload {
            return .q2
        }

        if usesHDRTransport || effectiveTargetFrameRate >= 90 {
            return .q3
        }

        return .q2
    }

    public var prefersRealtimeHDRMetadata: Bool {
        negotiatedDynamicRangeTransport != LumenMacDynamicRangeTransportSDR &&
            sinkRequest.capability.supportsPerFrameHDRMetadata
    }

    var forwardingQueueDepthReserve: Int {
        guard queueProfile == .auto else {
            return queueProfile.queueDepthHint
        }

        // ScreenCaptureKit source surfaces and the downstream freshness mailbox
        // have different ownership constraints. Keep the source pool at three for
        // 120 Hz, while the forwarding side stays shallow unless large/HDR frames
        // need one additional metadata slot.
        return usesHighResolutionWorkload || prefersRealtimeHDRMetadata ? 2 : 1
    }

    public var lumenProtocolAdapter: LumenMacProtocolAdapter {
        LumenMacProtocolAdapter(output: lumenProtocolAdapterOutput)
    }

    public var lumenProtocolAdapterOutput: LumenProtocolAdapterOutput {
        LumenProtocolAdapterOutput(
            requestedTransport: lumenProtocolRequestedDynamicRangeTransport,
            negotiatedTransport: lumenProtocolNegotiatedDynamicRangeTransport,
            sinkCapability: lumenProtocolSinkCapability
        )
    }

    public var lumenProtocolPresentationContract: LumenProtocolPresentationContract {
        lumenProtocolAdapter.presentationContract
    }

    public var presentationContractName: String {
        lumenProtocolAdapter.presentationContractName
    }

    public var presentationCompletionName: String {
        lumenProtocolAdapter.presentationCompletionName
    }

    private var lumenProtocolRequestedDynamicRangeTransport: LumenProtocolDynamicRangeTransport {
        switch sinkRequest.dynamicRangeTransport {
        case LumenMacDynamicRangeTransportFullFrameHDR:
            return .fullFrameHDR
        case LumenMacDynamicRangeTransportFrameGatedHDR:
            return .frameGatedHDR
        case LumenMacDynamicRangeTransportSDRBaseHDROverlay:
            return .sdrBaseHDROverlay
        default:
            return .sdr
        }
    }

    private var lumenProtocolNegotiatedDynamicRangeTransport: LumenProtocolDynamicRangeTransport {
        switch negotiatedDynamicRangeTransport {
        case LumenMacDynamicRangeTransportFullFrameHDR:
            return .fullFrameHDR
        case LumenMacDynamicRangeTransportFrameGatedHDR:
            return .frameGatedHDR
        case LumenMacDynamicRangeTransportSDRBaseHDROverlay:
            return .sdrBaseHDROverlay
        default:
            return .sdr
        }
    }

    private var lumenProtocolSinkCapability: LumenProtocolSinkCapability {
        LumenProtocolSinkCapability(
            prefersHDR: sinkPrefersHDRPresentation,
            supportsHDRTileOverlay: sinkRequest.capability.supportsHDRTileOverlay,
            supportsPerFrameHDRMetadata: sinkRequest.capability.supportsPerFrameHDRMetadata
        )
    }

    struct EncodedHDRConfigurationSnapshot: Equatable, Sendable {
        let signalColorPrimaries: String
        let transferFunction: String
        let signalYCbCrMatrix: String
        let staticMetadataSource: String
    }

    public static func panelNative(displayID: UInt32) -> Self {
        let environment = ProcessInfo.processInfo.environment
        let transport = LumenClientSinkTransfer(
            environmentValue: environment["SHADOW_CLIENT_SINK_TRANSFER"]
        )
        return Self(
            displayID: displayID,
            codec: .hevc,
            queueProfile: .auto,
            encoderInputStrategy: LumenBridgeConfigurationPreferences.preferredEncoderInputStrategy(),
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: LumenClientSinkGamut(
                        environmentValue: environment["SHADOW_CLIENT_SINK_GAMUT"]
                    ),
                    transfer: LumenClientSinkTransfer(
                        environmentValue: environment["SHADOW_CLIENT_SINK_TRANSFER"]
                    ),
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: false,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: transport == .pq || transport == .hlg ?
                    LumenMacDynamicRangeTransportFrameGatedHDR :
                    LumenMacDynamicRangeTransportSDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: LumenClientSinkGamut(
                    environmentValue: environment["SHADOW_CLIENT_SINK_GAMUT"]
                ),
                transfer: LumenClientSinkTransfer(
                    environmentValue: environment["SHADOW_CLIENT_SINK_TRANSFER"]
                )
            )
        )
    }

    public var effectiveTargetFrameRate: Int {
        targetFrameRate
    }

    public var effectivePreprocessStrategy: LumenCapturePreprocessStrategy {
        if preprocessStrategy != .none {
            return preprocessStrategy
        }

        return .none
    }

    public var effectiveEncoderInputStrategy: LumenCaptureEncoderInputStrategy {
        if encoderInputStrategy != .auto {
            return encoderInputStrategy
        }

        if usesHDRTransport || negotiatedDynamicRangeTransport == LumenMacDynamicRangeTransportSDRBaseHDROverlay {
            return .yuv420v10
        }

        if usesHighResolutionWorkload || targetFrameRate >= 120 {
            return .yuv420v8
        }

        return .auto
    }

    public var effectiveCapturePixelFormat: UInt32 {
        if chromaSubsampling == .yuv444 {
            return bitDepth == 10
                ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        }
        if codec == .hevc {
            return kCVPixelFormatType_32BGRA
        }
        switch codec {
        case .h264:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .hevc:
            return usesHDRTransport ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    var directCapturePixelFormat: OSType {
        if chromaSubsampling == .yuv444 {
            return bitDepth == 10
                ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        }
        return bitDepth == 10
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private var effectivePixelCount: Int? {
        guard let width = requestedWidth, let height = requestedHeight else {
            return nil
        }

        return width * height
    }

    private var usesHighResolutionWorkload: Bool {
        guard let effectivePixelCount else {
            return false
        }

        return effectivePixelCount >= Self.highResolutionPixelCountThreshold
    }

    private var usesVeryHighResolutionWorkload: Bool {
        guard let effectivePixelCount else {
            return false
        }

        return effectivePixelCount >= Self.veryHighResolutionPixelCountThreshold
    }

    var encodedColorConfiguration: LumenVideoHDRConfiguration? {
        if (usesHDRTransport || negotiatedDynamicRangeTransport == LumenMacDynamicRangeTransportSDRBaseHDROverlay),
           codec != .h264 {
            let colorPrimaries = resolvedHDRSignalColorPrimaries
            let yCbCrMatrix = resolvedHDRSignalYCbCrMatrix
            let metadata = resolvedHDRStaticMetadata
            return LumenVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: colorPrimaries,
                transferFunction: resolvedHDRTransferFunction,
                yCbCrMatrix: yCbCrMatrix,
                metadataInsertionMode: .automatic,
                masteringDisplayColorVolume: metadata.masteringDisplayColorVolume,
                contentLightLevelInfo: metadata.contentLightLevelInfo
            )
        }

        switch resolvedDisplayGamut {
        case .displayP3:
            return LumenVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .p3D65,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: .automatic
            )
        case .rec2020:
            return LumenVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .ituR2020,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR2020,
                metadataInsertionMode: .automatic
            )
        case .srgb, .unknown:
            return LumenVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .ituR709,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: .automatic
            )
        }
    }

    private var resolvedSourceColorPrimaries: LumenVideoColorPrimaries {
        switch resolvedDisplayGamut {
        case .displayP3:
            return .p3D65
        case .rec2020:
            return .ituR2020
        case .srgb, .unknown:
            return .ituR709
        }
    }

    private var resolvedDisplayGamut: LumenClientSinkGamut {
        effectiveDisplayState.gamut == .unknown ? sinkRequest.capability.gamut : effectiveDisplayState.gamut
    }

    private var resolvedDisplayTransfer: LumenClientSinkTransfer {
        effectiveDisplayState.transfer == .unknown ? sinkRequest.capability.transfer : effectiveDisplayState.transfer
    }

    private var resolvedHDRTransferFunction: LumenVideoTransferFunction {
        switch resolvedDisplayTransfer {
        case .hlg:
            return .ituR2100HLG
        case .sdr:
            return .ituR709
        case .pq, .unknown:
            return .smpteSt2084PQ
        }
    }

    var encodedHDRConfigurationSnapshot: EncodedHDRConfigurationSnapshot? {
        guard (usesHDRTransport || negotiatedDynamicRangeTransport == LumenMacDynamicRangeTransportSDRBaseHDROverlay),
              codec != .h264 else {
            return nil
        }

        return EncodedHDRConfigurationSnapshot(
            signalColorPrimaries: resolvedHDRSignalColorPrimaries.rawValue,
            transferFunction: resolvedHDRTransferFunction.rawValue,
            signalYCbCrMatrix: resolvedHDRSignalYCbCrMatrix.rawValue,
            staticMetadataSource: resolvedHDRStaticMetadataSource
        )
    }

    private var resolvedHDRSignalColorPrimaries: LumenVideoColorPrimaries {
        switch resolvedHDRTransferFunction {
        case .smpteSt2084PQ, .ituR2100HLG:
            return .ituR2020
        case .ituR709:
            switch resolvedDisplayGamut {
            case .displayP3:
                return .p3D65
            case .rec2020:
                return .ituR2020
            case .srgb, .unknown:
                return .ituR709
            }
        }
    }

    private var resolvedHDRSignalYCbCrMatrix: LumenVideoYCbCrMatrix {
        switch resolvedHDRTransferFunction {
        case .smpteSt2084PQ, .ituR2100HLG:
            return .ituR2020
        case .ituR709:
            return .ituR709
        }
    }

    private var resolvedHDRStaticMetadata: (
        masteringDisplayColorVolume: LumenVideoMasteringDisplayColorVolume?,
        contentLightLevelInfo: LumenVideoContentLightLevelInfo?
    ) {
        if let hdrStaticMetadata = effectiveDisplayState.hdrStaticMetadata {
            return (
                hdrStaticMetadata.masteringDisplayColorVolume,
                hdrStaticMetadata.contentLightLevelInfo
            )
        }

        switch resolvedHDRTransferFunction {
        case .ituR2100HLG:
            return (nil, nil)
        case .smpteSt2084PQ:
            switch resolvedDisplayGamut {
            case .displayP3:
                return (Self.hdrP3MasteringDisplayColorVolume, Self.hdrP3ContentLightLevelInfo)
            case .rec2020:
                return (
                    LumenVideoMasteringDisplayColorVolume.hdr10Default(),
                    LumenVideoContentLightLevelInfo.hdr10Default()
                )
            case .srgb, .unknown:
                return (Self.hdr709MasteringDisplayColorVolume, Self.hdr709ContentLightLevelInfo)
            }
        case .ituR709:
            return (nil, nil)
        }
    }

    private var resolvedHDRStaticMetadataSource: String {
        if effectiveDisplayState.hdrStaticMetadata != nil {
            return "explicit"
        }

        switch resolvedHDRTransferFunction {
        case .ituR2100HLG:
            return "none"
        case .smpteSt2084PQ:
            switch resolvedDisplayGamut {
            case .displayP3:
                return "display-p3-default"
            case .rec2020:
                return "rec2020-default"
            case .srgb, .unknown:
                return "rec709-default"
            }
        case .ituR709:
            return "none"
        }
    }

    private static func sanitizedDimension(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }
        return value
    }

    private static let hdr709MasteringDisplayColorVolume = LumenVideoMasteringDisplayColorVolume(
        redPrimary: LumenVideoChromaticityPoint(x: 0.6400, y: 0.3300),
        greenPrimary: LumenVideoChromaticityPoint(x: 0.3000, y: 0.6000),
        bluePrimary: LumenVideoChromaticityPoint(x: 0.1500, y: 0.0600),
        whitePoint: LumenVideoChromaticityPoint(x: 0.3127, y: 0.3290),
        maxLuminance: 600.0,
        minLuminance: 0.001
    )

    private static let hdr709ContentLightLevelInfo = LumenVideoContentLightLevelInfo(
        maximumContentLightLevel: 600,
        maximumFrameAverageLightLevel: 250
    )

    private static let hdrP3MasteringDisplayColorVolume = LumenVideoMasteringDisplayColorVolume(
        redPrimary: LumenVideoChromaticityPoint(x: 0.6800, y: 0.3200),
        greenPrimary: LumenVideoChromaticityPoint(x: 0.2650, y: 0.6900),
        bluePrimary: LumenVideoChromaticityPoint(x: 0.1500, y: 0.0600),
        whitePoint: LumenVideoChromaticityPoint(x: 0.3127, y: 0.3290),
        maxLuminance: 1000.0,
        minLuminance: 0.001
    )

    private static let hdrP3ContentLightLevelInfo = LumenVideoContentLightLevelInfo(
        maximumContentLightLevel: 1000,
                maximumFrameAverageLightLevel: 400
    )

    var hdrConfigurationDebugSummary: String {
        "uses-hdr-transport=\(usesHDRTransport) requested-transport=\(lumenDynamicRangeTransportName(sinkRequest.dynamicRangeTransport)) negotiated-transport=\(lumenDynamicRangeTransportName(negotiatedDynamicRangeTransport)) requested-queue=\(queueProfile.rawValue) negotiated-queue=\(negotiatedQueueProfile.rawValue) effective-gamut=\(resolvedDisplayGamut.rawValue) effective-transfer=\(resolvedDisplayTransfer.rawValue) negotiated-static-metadata=\(effectiveDisplayState.hdrStaticMetadata != nil) current-edr-headroom=\(sinkRequest.capability.currentEDRHeadroom) potential-edr-headroom=\(sinkRequest.capability.potentialEDRHeadroom) current-peak-nits=\(sinkRequest.capability.currentPeakLuminanceNits) potential-peak-nits=\(sinkRequest.capability.potentialPeakLuminanceNits) supports-frame-gated-hdr=\(sinkRequest.capability.supportsFrameGatedHDR) supports-hdr-tile-overlay=\(sinkRequest.capability.supportsHDRTileOverlay) supports-per-frame-hdr-metadata=\(sinkRequest.capability.supportsPerFrameHDRMetadata) presentation-contract=\(presentationContractName)"
    }
}

public struct LumenBridgeEncodedFrameSnapshot: Equatable, Sendable {
    public let codec: LumenCaptureCodec
    public let sourceDisplayTime: UInt64
    public let sourceSequenceNumber: UInt64
    public let outputCallbackLatencyMilliseconds: Double?
    public let isKeyFrame: Bool
    public let isHDRSignaled: Bool

    init(frame: LumenEncodedFrame) {
        self.codec = frame.codec
        self.sourceDisplayTime = frame.sourceDisplayTime
        self.sourceSequenceNumber = frame.sourceSequenceNumber
        self.outputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds
        self.isKeyFrame = frame.isKeyFrame
        self.isHDRSignaled = frame.isHDRSignaled
    }
}

public enum LumenBridgeCaptureEventKind: String, Codable, Equatable, Sendable {
    case started
    case stopped
    case restarted
    case failed
    case droppedFrame
    case coalescedFrame
}

public struct LumenBridgeCaptureSnapshot: Equatable, Sendable {
    public let configuration: LumenMacCaptureConfiguration
    public let statistics: LumenEncodedCaptureSessionStatistics
    public let latestFrame: LumenBridgeEncodedFrameSnapshot?
    public let recentEvents: [LumenEncodedCaptureSessionEvent]
    public let videoForwarding: LumenBridgeVideoForwardingSnapshot
}

public struct LumenBridgeStatus: Equatable, Sendable {
    public let coreVersion: String
    public let runtimeDescription: String
    public let integrationStatus: String
    public let captureSessionRunning: Bool
    public let audioCaptureSessionRunning: Bool
    public let automaticCaptureOrchestrationRunning: Bool

    public init(
        coreVersion: String,
        runtimeDescription: String,
        integrationStatus: String,
        captureSessionRunning: Bool,
        audioCaptureSessionRunning: Bool,
        automaticCaptureOrchestrationRunning: Bool
    ) {
        self.coreVersion = coreVersion
        self.runtimeDescription = runtimeDescription
        self.integrationStatus = integrationStatus
        self.captureSessionRunning = captureSessionRunning
        self.audioCaptureSessionRunning = audioCaptureSessionRunning
        self.automaticCaptureOrchestrationRunning = automaticCaptureOrchestrationRunning
    }
}

public enum LumenAudioCaptureSourceKind: String, Codable, Equatable, Sendable {
    case microphone
    case systemOutput = "system-output"
}

public enum LumenAudioCaptureSource: Codable, Equatable, Sendable {
    case microphone(inputID: String?)
    case systemOutput(displayID: UInt32, excludesCurrentProcessAudio: Bool)

    public var kind: LumenAudioCaptureSourceKind {
        switch self {
        case .microphone:
            return .microphone
        case .systemOutput:
            return .systemOutput
        }
    }
}

public struct LumenMacAudioCaptureConfiguration: Codable, Equatable, Sendable {
    public let source: LumenAudioCaptureSource
    public let sampleRate: Int
    public let channelCount: Int
    public let frameSize: Int

    public init(
        source: LumenAudioCaptureSource,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        frameSize: Int = 480
    ) {
        self.source = source
        self.sampleRate = max(sampleRate, 1)
        self.channelCount = max(channelCount, 1)
        self.frameSize = max(frameSize, 1)
    }

    public static func microphone(
        inputID: String? = nil,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        frameSize: Int = 480
    ) -> Self {
        Self(
            source: .microphone(inputID: inputID),
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameSize: frameSize
        )
    }

    public static func systemOutput(
        displayID: UInt32,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        frameSize: Int = 480,
        excludesCurrentProcessAudio: Bool = false
    ) -> Self {
        Self(
            source: .systemOutput(
                displayID: displayID,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio
            ),
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameSize: frameSize
        )
    }

}

public struct LumenBridgeAudioForwardingSnapshot: Equatable, Sendable {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let lastFrameSequenceNumber: UInt64?
    public let lastFrameHostTimeNanoseconds: UInt64?
    public let lastFrameSampleRate: Int?
    public let lastFrameChannelCount: Int?
    public let lastFrameFrameCount: Int?
    public let lastFramePCMByteCount: Int
    public let lastEventKind: LumenBridgeCaptureEventKind?
}

public struct LumenBridgeDrainedAudioFrame: Equatable, Sendable {
    public let sequenceNumber: UInt64
    public let hostTimeNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let pcmFloat32LE: Data
}

public struct LumenBridgeDrainedAudioEvent: Equatable, Sendable {
    public let kind: LumenBridgeCaptureEventKind
    public let message: String?
    public let stopStatus: Int32?
    public let automaticRestartCount: UInt64?
    public let sourceSequenceNumber: UInt64?
}

public actor LumenBridgeRuntime {
    public static let shared = LumenBridgeRuntime()
    public nonisolated static let statusDidChangeNotification = Notification.Name("LumenBridgeRuntimeStatusDidChange")
    private nonisolated static let statusNotificationCoalescingNanoseconds: UInt64 = 100_000_000
    private nonisolated static let encodedFrameDiagnosticsIntervalNanoseconds: UInt64 = 3_000_000_000
    private nonisolated static let captureRestartCooldownNanoseconds: UInt64 = 2_000_000_000
    private nonisolated static let automaticVideoForwardingEventCapacity = 64
    private nonisolated static func postStatusDidChangeNotificationAsync() {
        Task { @MainActor in
            NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
        }
    }

    private nonisolated static func displayTimeDeltaMilliseconds(_ delta: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom != 0 else {
            return 0
        }

        let nanoseconds = (Double(delta) * Double(timebase.numer)) / Double(timebase.denom)
        return nanoseconds / 1_000_000
    }

    static func recommendedVideoForwardingFrameCapacity(
        for configuration: LumenMacCaptureConfiguration
    ) -> Int {
        // Favor freshness over throughput. Deep forwarding queues translate directly into
        // input lag when the producer starts missing cadence.
        let queueDepthReserve = max(configuration.forwardingQueueDepthReserve, 1)
        let hdrMetadataSlack = configuration.prefersRealtimeHDRMetadata ? 1 : 0
        let targetFrameRate = configuration.effectiveTargetFrameRate

        if targetFrameRate >= 120 {
            return min(max(queueDepthReserve + hdrMetadataSlack, 2), 3)
        }

        if targetFrameRate >= 90 {
            return min(max(queueDepthReserve + hdrMetadataSlack, 2), 4)
        }

        if targetFrameRate >= 60 {
            return min(max(queueDepthReserve + hdrMetadataSlack, 2), 4)
        }

        return min(max(queueDepthReserve + hdrMetadataSlack, 2), 4)
    }

    private let videoForwarder = LumenVideoCaptureForwarder()
    private let audioForwarder = LumenAudioCaptureForwarder()
    private let logger = Logger(subsystem: "dev.skyline23.lumen", category: "MacBridgeRuntime")
    private let captureLifecycle = LumenBridgeCaptureLifecycle()
    private let encodedFrameReadiness = LumenFirstEncodedFrameGate()
    private var encodedCaptureSession: LumenEncodedCaptureSession?
    private var encodedCaptureStartupTask: Task<Void, Error>?
    private var activeCaptureConfiguration: LumenMacCaptureConfiguration?
    private var activePreconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?
    private var latestFrame: LumenBridgeEncodedFrameSnapshot?
    private var recentEvents: [LumenEncodedCaptureSessionEvent] = []
    private var audioCaptureSession: LumenAudioCaptureSession?
    private var audioCaptureStartupTask: Task<Void, Error>?
    private var activeAudioCaptureConfiguration: LumenMacAudioCaptureConfiguration?
    private var audioCaptureIsHostedByEncodedSession = false
    private var lastStatusNotificationUptimeNanoseconds: UInt64 = 0
    private var hasPendingStatusNotification = false
    private var lastEncodedFrameDiagnosticsUptimeNanoseconds: UInt64 = 0
    private var lastEncodedFrameSourceSequenceNumber: UInt64?
    private var lastEncodedFrameSourceDisplayTime: UInt64?
    private var lastCaptureRestartRequestUptimeNanoseconds: UInt64 = 0
    private var activeCaptureGeneration: UInt64?

    public init() {}

    public func preferredCaptureConfiguration(
        displayID: UInt32
    ) -> LumenMacCaptureConfiguration {
        .panelNative(displayID: displayID)
    }

    public func startCapture(
        configuration: LumenMacCaptureConfiguration
    ) async throws {
        try await startCapture(
            configuration: configuration,
            preconfiguredSystemAudio: nil,
            waitForStartupCompletion: true
        )
    }

    public func startCapture(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startCapture(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio,
            waitForStartupCompletion: true
        )
    }

    private func startCapture(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?,
        waitForStartupCompletion: Bool
    ) async throws {
        if preconfiguredSystemAudio != nil {
            await stopAudioCapture(resetRequestGeneration: false)
        }
        await stopCapture(resetRequestGeneration: false)
        let captureGeneration = await encodedFrameReadiness.beginCapture()
        activeCaptureGeneration = captureGeneration

        let frameCapacity = Self.recommendedVideoForwardingFrameCapacity(for: configuration)
        videoForwarder.reset()
        videoForwarder.setFrameCapacity(frameCapacity)
        videoForwarder.setEventCapacity(Self.automaticVideoForwardingEventCapacity)
        videoForwarder.setProducerActive(false)
        await captureLifecycle.beginStartup()
        latestFrame = nil
        recentEvents = []
        lastEncodedFrameDiagnosticsUptimeNanoseconds = 0
        lastEncodedFrameSourceSequenceNumber = nil
        lastEncodedFrameSourceDisplayTime = nil

        logger.notice(
            "Starting ScreenCaptureKit capture \(configuration.hdrConfigurationDebugSummary, privacy: .public) forwarding-frame-capacity=\(frameCapacity, privacy: .public)"
        )

        let preconfiguredSystemAudioCallbacks: LumenAudioCaptureCallbacks?
        if let preconfiguredSystemAudio {
            audioForwarder.reset()
            audioForwarder.setProducerActive(true)
            activeAudioCaptureConfiguration = preconfiguredSystemAudio
            audioCaptureIsHostedByEncodedSession = true
            preconfiguredSystemAudioCallbacks = makeAudioCaptureCallbacks()
        } else {
            preconfiguredSystemAudioCallbacks = nil
        }

        let session = LumenEncodedCaptureSession(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio,
            preconfiguredSystemAudioCallbacks: preconfiguredSystemAudioCallbacks
        )
        let runtime = self
        let videoForwarder = self.videoForwarder
        let callbacks = LumenEncodedCaptureCallbacks(
            frameHandler: { frame in
                let admission = videoForwarder.consume(frame: frame)
                Task {
                    if admission == .recoveryKeyFrameRequired {
                        await runtime.requestImmediateCaptureKeyFrame()
                    }
                    await runtime.recordEncodedFrame(frame, generation: captureGeneration)
                }
            },
            eventHandler: { event in
                videoForwarder.consume(event: event)
                Task {
                    await runtime.recordEncodedCaptureEvent(event)
                }
            }
        )

        activeCaptureConfiguration = configuration
        activePreconfiguredSystemAudio = preconfiguredSystemAudio
        encodedCaptureSession = session
        publishStatusDidChange(immediate: true)

        let startupTask = Task<Void, Error> {
            do {
                try await session.start(callbacks: callbacks)
                await runtime.handleEncodedCaptureStartupFinished(for: session)
            } catch {
                await runtime.handleEncodedCaptureStartupFailure(for: session, error: error)
                throw error
            }
        }
        encodedCaptureStartupTask = startupTask

        if waitForStartupCompletion {
            do {
                try await startupTask.value
            } catch {
                if encodedCaptureStartupTask?.isCancelled == true {
                    encodedCaptureStartupTask = nil
                }
                throw error
            }
        }
    }

    public func stopCapture() async {
        await stopCapture(resetRequestGeneration: true)
    }

    public func waitForFirstEncodedFrame(timeoutNanoseconds: UInt64) async throws {
        guard let activeCaptureGeneration else {
            throw LumenFirstEncodedFrameReadinessError.captureNotRunning
        }
        try await encodedFrameReadiness.wait(
            for: activeCaptureGeneration,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public func currentEncodedFrameSequenceNumber() -> UInt64? {
        latestFrame?.sourceSequenceNumber
    }

    public func waitForEncodedFrame(
        after sequenceNumber: UInt64,
        timeoutNanoseconds: UInt64
    ) async throws {
        guard let activeCaptureGeneration else {
            throw LumenFirstEncodedFrameReadinessError.captureNotRunning
        }
        try await encodedFrameReadiness.wait(
            for: activeCaptureGeneration,
            after: sequenceNumber,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public func verifyEncodedFrameContinuity(timeoutNanoseconds: UInt64) async throws {
        guard let sequenceNumber = latestFrame?.sourceSequenceNumber else {
            try await waitForFirstEncodedFrame(timeoutNanoseconds: timeoutNanoseconds)
            return
        }
        try await waitForEncodedFrame(
            after: sequenceNumber,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public func requestImmediateCaptureKeyFrame() async {
        guard await captureLifecycle.shouldRequestImmediateKeyFrame else {
            logger.debug("Ignoring immediate keyframe request because ScreenCaptureKit capture is not running")
            return
        }

        guard let encodedCaptureSession else {
            logger.debug("Ignoring immediate keyframe request because no ScreenCaptureKit capture session is active")
            return
        }

        logger.notice("Requesting an immediate ScreenCaptureKit keyframe for external encoded capture resync")
        await encodedCaptureSession.requestImmediateKeyFrame()
    }

    public func resumeVideoEncodingAfterCodecAck() async -> Bool {
        guard await captureLifecycle.shouldRequestImmediateKeyFrame,
              let encodedCaptureSession else {
            logger.error("Rejecting codec acknowledgement because ScreenCaptureKit capture is not running")
            return false
        }
        let resumed = await encodedCaptureSession.resumeVideoEncodingAfterCodecAck()
        if resumed {
            logger.notice("Resumed VideoToolbox encoding after codec configuration acknowledgement")
        } else {
            logger.error("Codec acknowledgement did not match a paused VideoToolbox admission boundary")
        }
        return resumed
    }

    public func restartCapture(reason: String) async {
        guard let configuration = activeCaptureConfiguration else {
            logger.debug("Ignoring ScreenCaptureKit capture restart because no capture session is active reason=\(reason, privacy: .public)")
            return
        }
        let preconfiguredSystemAudio = activePreconfiguredSystemAudio

        let now = DispatchTime.now().uptimeNanoseconds
        if lastCaptureRestartRequestUptimeNanoseconds != 0 &&
            now - lastCaptureRestartRequestUptimeNanoseconds < Self.captureRestartCooldownNanoseconds {
            logger.notice(
                "Suppressing ScreenCaptureKit capture restart because the cooldown is active reason=\(reason, privacy: .public)"
            )
            return
        }

        lastCaptureRestartRequestUptimeNanoseconds = now
        logger.notice(
            "Restarting ScreenCaptureKit capture to recover stale external encoded frames reason=\(reason, privacy: .public)"
        )
        await stopCapture(resetRequestGeneration: false)
        try? await startCapture(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio,
            waitForStartupCompletion: false
        )
    }

    private func stopCapture(resetRequestGeneration: Bool) async {
        encodedCaptureStartupTask?.cancel()
        encodedCaptureStartupTask = nil
        if let activeCaptureGeneration {
            await encodedFrameReadiness.stop(generation: activeCaptureGeneration)
            self.activeCaptureGeneration = nil
        }
        videoForwarder.setProducerActive(false)
        await captureLifecycle.beginStop()
        guard let session = encodedCaptureSession else {
            encodedCaptureSession = nil
            activeCaptureConfiguration = nil
            activePreconfiguredSystemAudio = nil
            latestFrame = nil
            recentEvents = []
            lastEncodedFrameDiagnosticsUptimeNanoseconds = 0
            lastEncodedFrameSourceSequenceNumber = nil
            lastEncodedFrameSourceDisplayTime = nil
            await captureLifecycle.finishStop()
            clearEncodedSessionHostedAudioState()
            if resetRequestGeneration {
            }
            return
        }

        await session.stop()
        encodedCaptureSession = nil
        activeCaptureConfiguration = nil
        activePreconfiguredSystemAudio = nil
        lastEncodedFrameDiagnosticsUptimeNanoseconds = 0
        lastEncodedFrameSourceSequenceNumber = nil
        lastEncodedFrameSourceDisplayTime = nil
        await captureLifecycle.finishStop()
        clearEncodedSessionHostedAudioState()
        if resetRequestGeneration {
        }
        publishStatusDidChange(immediate: true)
    }

    public func makeDefaultMicrophoneAudioConfiguration() -> LumenMacAudioCaptureConfiguration {
        .microphone()
    }

    public func makeSystemOutputAudioConfiguration(
        displayID: UInt32
    ) -> LumenMacAudioCaptureConfiguration {
        .systemOutput(displayID: displayID)
    }

    public func startAudioCapture(
        configuration: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startAudioCapture(
            configuration: configuration,
            waitForStartupCompletion: true
        )
    }

    public func startAudioCaptureAsynchronously(
        configuration: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startAudioCapture(
            configuration: configuration,
            waitForStartupCompletion: false
        )
    }

    private func startAudioCapture(
        configuration: LumenMacAudioCaptureConfiguration,
        waitForStartupCompletion: Bool
    ) async throws {
        await stopAudioCapture(resetRequestGeneration: false)

        audioForwarder.reset()
        audioForwarder.setProducerActive(false)
        let runtime = self
        let activeVideoDisplayID = encodedCaptureSession == nil
            ? nil
            : activeCaptureConfiguration?.displayID
        let audioRoute = try LumenSystemAudioCaptureRoute.resolve(
            configuration: configuration,
            activeVideoDisplayID: activeVideoDisplayID
        )
        let sharedVideoSession: LumenEncodedCaptureSession? = switch audioRoute {
        case .sharedVideoStream:
            encodedCaptureSession
        case .standaloneStream:
            nil
        }
        let session = LumenAudioCaptureSession(
            configuration: configuration,
            sharedVideoSession: sharedVideoSession
        )
        logger.notice(
            "Starting ScreenCaptureKit audio capture source=\(configuration.source.kind.rawValue, privacy: .public) route=\(String(describing: audioRoute), privacy: .public) sample-rate=\(configuration.sampleRate, privacy: .public) channels=\(configuration.channelCount, privacy: .public) frame-size=\(configuration.frameSize, privacy: .public)"
        )
        let callbacks = makeAudioCaptureCallbacks()

        activeAudioCaptureConfiguration = configuration
        audioCaptureSession = session
        audioForwarder.setProducerActive(true)
        publishStatusDidChange(immediate: true)

        let startupTask = Task<Void, Error> {
            do {
                try await session.start(callbacks: callbacks)
                await runtime.handleAudioCaptureStartupFinished(for: session)
            } catch {
                await runtime.handleAudioCaptureStartupFailure(for: session, error: error)
                throw error
            }
        }
        audioCaptureStartupTask = startupTask

        if waitForStartupCompletion {
            do {
                try await startupTask.value
            } catch {
                if audioCaptureStartupTask?.isCancelled == true {
                    audioCaptureStartupTask = nil
                }
                throw error
            }
        }
    }

    private func makeAudioCaptureCallbacks() -> LumenAudioCaptureCallbacks {
        let runtime = self
        return LumenAudioCaptureCallbacks(
            frameHandler: { frame in
                Task {
                    await runtime.recordAudioFrame(frame)
                }
            },
            eventHandler: { event in
                Task {
                    await runtime.recordAudioCaptureEvent(event)
                }
            }
        )
    }

    public func stopAudioCapture() async {
        await stopAudioCapture(resetRequestGeneration: true)
    }

    private func stopAudioCapture(resetRequestGeneration: Bool) async {
        audioCaptureStartupTask?.cancel()
        audioCaptureStartupTask = nil
        if audioCaptureIsHostedByEncodedSession {
            await encodedCaptureSession?.detachSystemAudio()
            clearEncodedSessionHostedAudioState()
            publishStatusDidChange(immediate: true)
            return
        }
        guard let session = audioCaptureSession else {
            audioCaptureSession = nil
            activeAudioCaptureConfiguration = nil
            audioForwarder.reset()
            audioForwarder.setProducerActive(false)
            if resetRequestGeneration {
            }
            return
        }

        await session.stop()
        audioForwarder.setProducerActive(false)
        audioCaptureSession = nil
        activeAudioCaptureConfiguration = nil
        if resetRequestGeneration {
        }
        publishStatusDidChange(immediate: true)
    }

    private func handleEncodedCaptureStartupFinished(for session: LumenEncodedCaptureSession) async {
        guard encodedCaptureSession === session else {
            return
        }
        await captureLifecycle.finishStartup()
        guard encodedCaptureSession === session else {
            await captureLifecycle.finishStop()
            return
        }
        encodedCaptureStartupTask = nil
        videoForwarder.setProducerActive(true)
        publishStatusDidChange(immediate: true)
    }

    private func handleEncodedCaptureStartupFailure(for session: LumenEncodedCaptureSession, error: Error) async {
        guard encodedCaptureSession === session else {
            return
        }
        encodedCaptureStartupTask = nil
        encodedCaptureSession = nil
        activeCaptureConfiguration = nil
        activePreconfiguredSystemAudio = nil
        if let activeCaptureGeneration {
            await encodedFrameReadiness.stop(generation: activeCaptureGeneration)
            self.activeCaptureGeneration = nil
        }
        videoForwarder.setProducerActive(false)
        await captureLifecycle.failStartup()
        clearEncodedSessionHostedAudioState()
        latestFrame = nil
        recentEvents = []
        lastEncodedFrameDiagnosticsUptimeNanoseconds = 0
        lastEncodedFrameSourceSequenceNumber = nil
        lastEncodedFrameSourceDisplayTime = nil
        logger.error("ScreenCaptureKit video startup failed: \(String(describing: error), privacy: .public)")
        publishStatusDidChange(immediate: true)
    }

    private func clearEncodedSessionHostedAudioState() {
        guard audioCaptureIsHostedByEncodedSession else { return }
        audioCaptureIsHostedByEncodedSession = false
        activeAudioCaptureConfiguration = nil
        audioForwarder.setProducerActive(false)
        audioForwarder.reset()
    }

    private func handleAudioCaptureStartupFinished(for session: LumenAudioCaptureSession) {
        guard audioCaptureSession === session else {
            return
        }
        audioCaptureStartupTask = nil
    }

    private func handleAudioCaptureStartupFailure(for session: LumenAudioCaptureSession, error: Error) {
        guard audioCaptureSession === session else {
            return
        }
        audioCaptureStartupTask = nil
        audioCaptureSession = nil
        activeAudioCaptureConfiguration = nil
        recordAudioCaptureEvent(.init(
            kind: .failed,
            message: error.localizedDescription
        ))
        audioForwarder.setProducerActive(false)
        logger.error("ScreenCaptureKit audio startup failed: \(String(describing: error), privacy: .public)")
        publishStatusDidChange(immediate: true)
    }

    public func captureSnapshot() async -> LumenBridgeCaptureSnapshot? {
        guard let session = encodedCaptureSession,
              let configuration = activeCaptureConfiguration else {
            return nil
        }

        return LumenBridgeCaptureSnapshot(
            configuration: configuration,
            statistics: await session.statisticsSnapshot(),
            latestFrame: latestFrame,
            recentEvents: recentEvents,
            videoForwarding: videoForwarder.snapshot()
        )
    }

    public func videoForwardingSnapshot() -> LumenBridgeVideoForwardingSnapshot {
        videoForwarder.snapshot()
    }

    public func captureDiagnosticsString() async -> String {
        guard let session = encodedCaptureSession else {
            return "n/a"
        }

        return Self.captureDiagnosticsSnippet(
            from: await session.statisticsSnapshot(),
            configuration: activeCaptureConfiguration
        )
    }

    public func configureVideoForwarding(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        videoForwarder.setFrameCapacity(frameCapacity)
        videoForwarder.setEventCapacity(eventCapacity)
    }

    public func configureAudioForwarding(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        audioForwarder.setFrameCapacity(frameCapacity)
        audioForwarder.setEventCapacity(eventCapacity)
    }

    public func drainNextVideoForwardedFrame() -> LumenBridgeDrainedVideoFrame? {
        videoForwarder.popNextFrame()
    }

    public func drainNextVideoForwardedEvent() -> LumenBridgeDrainedVideoEvent? {
        videoForwarder.popNextEvent()
    }

    public func audioForwardingSnapshot() -> LumenBridgeAudioForwardingSnapshot {
        audioForwarder.snapshot()
    }

    public func drainNextVideoForwardedAudioFrame() -> LumenBridgeDrainedAudioFrame? {
        audioForwarder.popNextFrame()
    }

    public func drainNextVideoForwardedAudioEvent() -> LumenBridgeDrainedAudioEvent? {
        audioForwarder.popNextEvent()
    }

    public func statusSnapshot() -> LumenBridgeStatus {
        LumenBridgeStatus(
            coreVersion: "Rust ABI \(LumenEngineBridgeABIVersion())",
            runtimeDescription: "Rust host with Swift macOS capture adapters",
            integrationStatus: "ScreenCaptureKit and VideoToolbox feed bounded Swift ingress queues while Rust owns session, transport, packetization, and encryption.",
            captureSessionRunning: encodedCaptureSession != nil,
            audioCaptureSessionRunning: audioCaptureSession != nil || audioCaptureIsHostedByEncodedSession,
            automaticCaptureOrchestrationRunning: false
        )
    }

    private func recordEncodedFrame(_ frame: LumenEncodedFrame, generation: UInt64) async {
        guard activeCaptureGeneration == generation else { return }
        latestFrame = LumenBridgeEncodedFrameSnapshot(frame: frame)
        await encodedFrameReadiness.resolve(
            generation: generation,
            sequenceNumber: frame.sourceSequenceNumber
        )
        logEncodedFrameDiagnosticsIfNeeded(frame, captureStatistics: nil)
    }

    private func recordEncodedCaptureEvent(_ event: LumenEncodedCaptureSessionEvent) async {
        recentEvents.append(event)
        if recentEvents.count > 16 {
            recentEvents.removeFirst(recentEvents.count - 16)
        }
        let captureStatistics = await encodedCaptureSession?.statisticsSnapshot()
        let captureMinCallbackLatency = formattedLatency(captureStatistics?.minOutputCallbackLatencyMilliseconds)
        let captureMaxCallbackLatency = formattedLatency(captureStatistics?.maxOutputCallbackLatencyMilliseconds)
        let captureDiagnostics = Self.captureDiagnosticsSnippet(
            from: captureStatistics,
            configuration: activeCaptureConfiguration
        )
        logger.notice(
            "Mac bridge capture event kind=\(event.kind.rawValue, privacy: .public) message=\(event.message ?? "n/a", privacy: .public) stop-status=\(event.stopStatus ?? 0, privacy: .public) automatic-restarts=\(event.automaticRestartCount ?? 0, privacy: .public) source-display-time=\(event.sourceDisplayTime ?? 0, privacy: .public) capture-emitted=\(captureStatistics?.emittedFrameCount ?? 0, privacy: .public) capture-dropped=\(captureStatistics?.droppedFrameCount ?? 0, privacy: .public) capture-processing-failures=\(captureStatistics?.processingFailureCount ?? 0, privacy: .public) capture-running=\(captureStatistics?.isRunning ?? false, privacy: .public) capture-last-error=\(captureStatistics?.lastErrorDescription ?? "n/a", privacy: .public) capture-min-callback-latency-ms=\(captureMinCallbackLatency, privacy: .public) capture-max-callback-latency-ms=\(captureMaxCallbackLatency, privacy: .public) capture-vt=\(captureDiagnostics, privacy: .public)"
        )
        publishStatusDidChange()
    }

    private func logEncodedFrameDiagnosticsIfNeeded(
        _ frame: LumenEncodedFrame,
        captureStatistics: LumenEncodedCaptureSessionStatistics?
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let previousSequenceNumber = lastEncodedFrameSourceSequenceNumber
        let previousDisplayTime = lastEncodedFrameSourceDisplayTime

        let sequenceDelta = previousSequenceNumber.map { frame.sourceSequenceNumber >= $0 ? frame.sourceSequenceNumber - $0 : 0 }
        let displayTimeDelta = previousDisplayTime.map { frame.sourceDisplayTime >= $0 ? frame.sourceDisplayTime - $0 : 0 }
        let displayTimeDeltaMilliseconds = displayTimeDelta.map(Self.displayTimeDeltaMilliseconds)

        let shouldLogAnomaly =
            displayTimeDelta != nil && displayTimeDelta == 0
        let shouldLogInterval =
            lastEncodedFrameDiagnosticsUptimeNanoseconds == 0 ||
            now - lastEncodedFrameDiagnosticsUptimeNanoseconds >= Self.encodedFrameDiagnosticsIntervalNanoseconds

        if shouldLogAnomaly || shouldLogInterval {
            let targetWidth = activeCaptureConfiguration?.requestedWidth ?? 0
            let targetHeight = activeCaptureConfiguration?.requestedHeight ?? 0
            let targetFrameRate = activeCaptureConfiguration?.effectiveTargetFrameRate ?? 0
            let queueProfile = activeCaptureConfiguration?.queueProfile.rawValue ?? "unknown"
            let displayID = activeCaptureConfiguration?.displayID ?? 0
            let codec = frame.codec.rawValue
            let ingressSnapshot = videoForwarder.snapshot()
            let hdrValidation = frame.hdrValidationReport
            let callbackLatencyText: String
            if let latency = frame.outputCallbackLatencyMilliseconds {
                callbackLatencyText = String(format: "%.3f", latency)
            } else {
                callbackLatencyText = "n/a"
            }
            let displayDeltaText: String
            if let displayTimeDeltaMilliseconds {
                displayDeltaText = String(format: "%.3f", displayTimeDeltaMilliseconds)
            } else {
                displayDeltaText = "n/a"
            }
            let colorPrimaries = hdrValidation.colorPrimaries ?? "n/a"
            let transferFunction = hdrValidation.transferFunction ?? "n/a"
            let yCbCrMatrix = hdrValidation.yCbCrMatrix ?? "n/a"
            let captureLastError = captureStatistics?.lastErrorDescription ?? "n/a"
            let captureMinCallbackLatency = formattedLatency(captureStatistics?.minOutputCallbackLatencyMilliseconds)
            let captureMaxCallbackLatency = formattedLatency(captureStatistics?.maxOutputCallbackLatencyMilliseconds)
            let captureDiagnostics = Self.captureDiagnosticsSnippet(
                from: captureStatistics,
                configuration: activeCaptureConfiguration
            )

            logger.notice(
                "Mac bridge frame callback display-id=\(displayID, privacy: .public) codec=\(codec, privacy: .public) seq=\(frame.sourceSequenceNumber, privacy: .public) seq-delta=\(sequenceDelta ?? 0, privacy: .public) display-time=\(frame.sourceDisplayTime, privacy: .public) display-delta-ms=\(displayDeltaText, privacy: .public) callback-latency-ms=\(callbackLatencyText, privacy: .public) key=\(frame.isKeyFrame, privacy: .public) hdr=\(frame.isHDRSignaled, privacy: .public) hdr-primaries=\(colorPrimaries, privacy: .public) hdr-transfer=\(transferFunction, privacy: .public) hdr-matrix=\(yCbCrMatrix, privacy: .public) hdr-mastering=\(hdrValidation.hasMasteringDisplayColorVolume, privacy: .public) hdr-cll=\(hdrValidation.hasContentLightLevelInfo, privacy: .public) target-fps=\(targetFrameRate, privacy: .public) target-size=\(targetWidth, privacy: .public)x\(targetHeight, privacy: .public) queue=\(queueProfile, privacy: .public) capture-emitted=\(captureStatistics?.emittedFrameCount ?? 0, privacy: .public) capture-dropped=\(captureStatistics?.droppedFrameCount ?? 0, privacy: .public) capture-processing-failures=\(captureStatistics?.processingFailureCount ?? 0, privacy: .public) capture-restarts=\(captureStatistics?.automaticRestartCount ?? 0, privacy: .public) capture-running=\(captureStatistics?.isRunning ?? false, privacy: .public) capture-last-error=\(captureLastError, privacy: .public) capture-min-callback-latency-ms=\(captureMinCallbackLatency, privacy: .public) capture-max-callback-latency-ms=\(captureMaxCallbackLatency, privacy: .public) capture-vt=\(captureDiagnostics, privacy: .public) core-frame-count=\(ingressSnapshot.frameCount, privacy: .public) core-queued=\(ingressSnapshot.queuedFrameCount, privacy: .public) core-dropped=\(ingressSnapshot.droppedFrameCount, privacy: .public) core-last-seq=\(ingressSnapshot.lastFrameSourceSequenceNumber ?? 0, privacy: .public)"
            )
            lastEncodedFrameDiagnosticsUptimeNanoseconds = now
        }

        lastEncodedFrameSourceSequenceNumber = frame.sourceSequenceNumber
        lastEncodedFrameSourceDisplayTime = frame.sourceDisplayTime
    }

    private func formattedLatency(_ value: Double?) -> String {
        guard let value else {
            return "n/a"
        }
        return String(format: "%.3f", value)
    }

    private nonisolated static func captureDiagnosticsSnippet(
        from statistics: LumenEncodedCaptureSessionStatistics?,
        configuration: LumenMacCaptureConfiguration? = nil
    ) -> String {
        guard let statistics else {
            return "n/a"
        }

        let interestingPrefixes = [
            "screenCaptureOutputRegistrationStage=",
            "screenCaptureOwnedSampleCount=",
            "sourceBackend=",
            "skyLightAutotuningSource=",
            "skyLightCandidateResult=",
            "skyLightTuningCandidate=",
            "skyLightTuningQueueDepth=",
            "skyLightTuningMinimumFrameTime=",
            "skyLightTuningEffectiveOutputFrameRate=",
            "skyLightTuningCadence=",
            "skyLightDisplayRefreshRate=",
            "rawPrivateDisplayStream=",
            "rawPrivateDisplayStreamRequestedPixelFormat=",
            "rawPrivateDisplayStreamRequestedMatrix=",
            "skyLightSyntheticIdleReplay=",
            "skyLightSyntheticIdleReplayIntervalMilliseconds=",
            "skyLightPendingPolicy=",
            "skyLightRecommendedPendingFrameCount=",
            "skyLightPreflightWarmupMode=",
            "skyLightPreflightWarmupStatus=",
            "skyLightPreflightWarmupStopStatus=",
            "skyLightPreflightWarmupCallbackCount=",
            "skyLightPreflightWarmupCompleteFrameCount=",
            "skyLightPreflightWarmupObservedFrameRate=",
            "skyLightPreflightWarmupCadence=",
            "skyLightPreflightWarmupError=",
            "sourceHotPathDiagnostics=",
            "sourceFrameCount=",
            "sourceDisplayDeltaCount=",
            "sourceLastDisplayDeltaMilliseconds=",
            "sourceMinDisplayDeltaMilliseconds=",
            "sourceMaxDisplayDeltaMilliseconds=",
            "sourceAverageDisplayDeltaMilliseconds=",
            "sourceApproxFrameRate=",
            "sourceCadenceClassification=",
            "sourceReducedDirtySampleCount=",
            "sourceAverageReducedDirtyCoverageRatio=",
            "sourceMaxReducedDirtyCoverageRatio=",
            "sourceAverageReducedDirtyRectCount=",
            "sourceMaxReducedDirtyRectCount=",
            "sourceUpdateDropSampleCount=",
            "sourceAverageUpdateDropCount=",
            "sourceMaxUpdateDropCount=",
            "privateCaptureSourcePixelFormat=",
            "privateCaptureRequestedPixelFormat=",
            "privateCaptureExtendedRange=",
            "privateCaptureCursorComposition=",
            "privateCaptureSourceColorTransform=",
            "sourceCaptureSampleCount=",
            "sourceMinCaptureMilliseconds=",
            "sourceMaxCaptureMilliseconds=",
            "sourceAverageCaptureMilliseconds=",
            "sourceCursorCompositeSampleCount=",
            "sourceMinCursorCompositeMilliseconds=",
            "sourceMaxCursorCompositeMilliseconds=",
            "sourceAverageCursorCompositeMilliseconds=",
            "videoToolboxUsingHardwareEncoder=",
            "videoToolboxActiveMaxFrameDelayCount=",
            "videoToolboxActiveNumberOfSlices=",
            "videoToolboxActiveNumberOfSubFrameSections=",
            "videoToolboxEncoderMaxPixelRate=",
            "videoToolboxEncoderCoreCount=",
            "videoToolboxEncoderMotionEstimationSearchMode=",
            "videoToolboxSupportedPresetDictionaries=",
            "videoToolboxRecommendedParallelizationLimit=",
            "videoToolboxRecommendedParallelizedSubdivisionMinimumFrameCount=",
            "videoToolboxRecommendedParallelizedSubdivisionMinimumDuration=",
            "videoToolboxPixelBufferPoolIsShared=",
            "videoToolboxStagingMode=",
            "videoToolboxStagedSourceReleaseMode=",
            "videoToolboxEncoderInputStrategy=",
            "videoToolboxEncoderInputPixelFormat=",
            "videoToolboxSourcePixelFormat=",
            "videoToolboxSourceColorPrimaries=",
            "videoToolboxSignalColorPrimaries=",
            "videoToolboxColorConversionMode=",
            "videoToolboxTargetFrameRateHint=",
            "videoToolboxConfiguredAverageBitRate=",
            "videoToolboxConfiguredAverageBitRateSource=",
            "videoToolboxConfiguredDataRateLimits=",
            "videoToolboxConfiguredDataRateLimitsSource=",
            "videoToolboxConfiguredVariableBitRate=",
            "videoToolboxConfiguredVBVMaxBitRate=",
            "videoToolboxConfiguredRateControlMode=",
            "videoToolboxConfiguredVBVBufferDurationSeconds=",
            "videoToolboxConfiguredVBVInitialDelayPercentage=",
            "videoToolboxConfiguredProfileLevel=",
            "videoToolboxConfiguredMaximumRealTimeFrameRate=",
            "videoToolboxConfiguredMaxFrameDelayCount=",
            "videoToolboxConfiguredPrioritizeEncodingSpeedOverQuality=",
            "videoToolboxConfiguredNumberOfSlices=",
            "videoToolboxConfiguredInputQueueMaxCount=",
            "videoToolboxConfiguredSourceFrameCount=",
            "videoToolboxAllowTemporalCompression=",
            "videoToolboxHighRefreshLowLatencyMode=",
            "videoToolboxLowLatencyRateControl=",
            "videoToolboxDirectSubmissionFrameCount=",
            "videoToolboxStagedSubmissionFrameCount=",
            "videoToolboxSubmittedFrameCount=",
            "videoToolboxImmediateReplaySubmissionCount=",
            "videoToolboxSuppressedImmediateReplayCount=",
            "videoToolboxMaxInflightStagingSlots=",
            "videoToolboxPixelBufferCacheSize=",
            "videoToolboxEncodeQueueWait",
            "videoToolboxEncodeInvocation",
            "videoToolboxMetalStage",
            "videoToolboxVTEncodeCall",
            "videoToolboxOutputCallbackInterval",
            "videoToolboxSubmittedOutputBacklogMax=",
            "videoToolboxProperty."
        ]
        let notes = statistics.notes.filter { note in
            interestingPrefixes.contains { note.hasPrefix($0) }
        }

        guard !notes.isEmpty else {
            return "n/a"
        }
        return notes.joined(separator: ";")
    }

    private func recordAudioFrame(_ frame: LumenAudioFrame) {
        audioForwarder.consume(frame: frame)
        publishStatusDidChange()
    }

    private func recordAudioCaptureEvent(_ event: LumenAudioCaptureSessionEvent) {
        audioForwarder.consume(event: event)
        logger.notice(
            "Mac bridge audio capture event kind=\(event.kind.rawValue, privacy: .public) message=\(event.message ?? "n/a", privacy: .public) automatic-restarts=\(event.automaticRestartCount ?? 0, privacy: .public) source-sequence=\(event.sourceSequenceNumber ?? 0, privacy: .public)"
        )
        publishStatusDidChange()
    }

    private func publishStatusDidChange(immediate: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        if immediate || now - lastStatusNotificationUptimeNanoseconds >= Self.statusNotificationCoalescingNanoseconds {
            hasPendingStatusNotification = false
            lastStatusNotificationUptimeNanoseconds = now
            Self.postStatusDidChangeNotificationAsync()
            return
        }

        guard !hasPendingStatusNotification else {
            return
        }

        hasPendingStatusNotification = true
        let delay = Self.statusNotificationCoalescingNanoseconds - (now - lastStatusNotificationUptimeNanoseconds)
        Task { [delay] in
            try? await Task.sleep(nanoseconds: delay)
            self.flushPendingStatusDidChange()
        }
    }

    private func flushPendingStatusDidChange() {
        guard hasPendingStatusNotification else {
            return
        }

        hasPendingStatusNotification = false
        lastStatusNotificationUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        Self.postStatusDidChangeNotificationAsync()
    }

    func debugResetVideoForwarding() {
        videoForwarder.reset()
    }

    func debugSetVideoForwardingCapacities(frameCapacity: Int, eventCapacity: Int) {
        configureVideoForwarding(frameCapacity: frameCapacity, eventCapacity: eventCapacity)
    }

    func debugForwardSyntheticFrame(
        sampleBuffer: CMSampleBuffer,
        codec: LumenCaptureCodec = .hevc,
        sourceSequenceNumber: UInt64 = 1,
        sourceDisplayTime: UInt64 = 1,
        outputCallbackLatencyMilliseconds: Double? = nil,
        isKeyFrame: Bool = true,
        requiresBootstrapAcknowledgement: Bool = false,
        isRepairKeyFrame: Bool = false,
        isHDRSignaled: Bool = false
    ) {
        videoForwarder.consume(
            sampleBuffer: sampleBuffer,
            codec: codec,
            sourceSequenceNumber: sourceSequenceNumber,
            sourceDisplayTime: sourceDisplayTime,
            outputCallbackLatencyMilliseconds: outputCallbackLatencyMilliseconds,
            isKeyFrame: isKeyFrame,
            requiresBootstrapAcknowledgement: requiresBootstrapAcknowledgement,
            isRepairKeyFrame: isRepairKeyFrame,
            isHDRSignaled: isHDRSignaled
        )
    }

    func debugForwardSyntheticEvent(
        kind: LumenEncodedCaptureSessionEventKind,
        message: String? = nil,
        stopStatus: Int32? = nil,
        automaticRestartCount: UInt64? = nil,
        sourceDisplayTime: UInt64? = nil
    ) {
        let event = LumenEncodedCaptureSessionEvent(
            kind: kind,
            message: message,
            stopStatus: stopStatus,
            automaticRestartCount: automaticRestartCount,
            sourceDisplayTime: sourceDisplayTime
        )
        videoForwarder.consume(event: event)
    }

    func debugDrainNextForwardedFrame() -> LumenBridgeDrainedVideoFrame? {
        drainNextVideoForwardedFrame()
    }

    func debugDrainNextForwardedEvent() -> LumenBridgeDrainedVideoEvent? {
        drainNextVideoForwardedEvent()
    }

}

private extension LumenBridgeCaptureEventKind {
    init(_ kind: LumenAudioCaptureSessionEventKind) {
        switch kind {
        case .started:
            self = .started
        case .stopped:
            self = .stopped
        case .restarted:
            self = .restarted
        case .failed:
            self = .failed
        case .droppedFrame:
            self = .droppedFrame
        }
    }
}
