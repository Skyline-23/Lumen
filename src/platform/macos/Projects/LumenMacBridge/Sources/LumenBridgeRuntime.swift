import LumenCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import MacDisplayCaptureKit
import OSLog

public enum LumenCaptureCodec: String, CaseIterable, Codable, Sendable {
    case h264
    case hevc
    case proResProxy = "prores-proxy"

    var mdkValue: MDKVideoEncoderCodec {
        switch self {
        case .h264:
            return .h264
        case .hevc:
            return .hevc
        case .proResProxy:
            return .proResProxy
        }
    }
}

public enum LumenCapturePreprocessStrategy: String, CaseIterable, Codable, Sendable {
    case none
    case downscale2x = "downscale-2x"

    var mdkValue: MDKVideoPreprocessStrategy {
        switch self {
        case .none:
            return .none
        case .downscale2x:
            return .downscale2x
        }
    }
}

public enum LumenCaptureQueueProfile: String, CaseIterable, Codable, Sendable {
    case auto
    case q1
    case q2
    case q3
    case q4

    var mdkQueueProfile: MDKSkyLightDisplayStreamQueueProfile? {
        switch self {
        case .auto:
            return nil
        case .q1:
            return .q1
        case .q2:
            return .q2
        case .q3:
            return .q3
        case .q4:
            return .q4
        }
    }

    var queueDepthHint: Int {
        switch self {
        case .auto:
            // MDK autotuning starts from its own candidate matrix; use the baseline-q3
            // depth here so LumenCore forwarding keeps enough slack without reviving
            // large stale-frame queues by default.
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

    var mdkValue: MDKEncodedCaptureEncoderInputStrategy {
        switch self {
        case .auto:
            return .auto
        case .bgra:
            return .bgra
        case .yuv420v8:
            return .yuv420v8
        case .yuv420v10:
            return .yuv420v10
        }
    }
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

private func lumenDynamicRangeTransportName(_ transport: LumenCoreDynamicRangeTransport) -> String {
    switch transport {
    case LumenCoreDynamicRangeTransportSDR:
        return "sdr"
    case LumenCoreDynamicRangeTransportFullFrameHDR:
        return "full-frame-hdr"
    case LumenCoreDynamicRangeTransportFrameGatedHDR:
        return "frame-gated-hdr"
    case LumenCoreDynamicRangeTransportSDRBaseHDROverlay:
        return "sdr-base-hdr-overlay"
    default:
        return "unknown"
    }
}

private func lumenDynamicRangeTransportUsesHDR(_ transport: LumenCoreDynamicRangeTransport) -> Bool {
    switch transport {
    case LumenCoreDynamicRangeTransportFullFrameHDR, LumenCoreDynamicRangeTransportFrameGatedHDR:
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

    init(coreValue: LumenCoreHDRStaticMetadata) {
        self.init(
            redPrimaryX: Int(coreValue.red_primary_x),
            redPrimaryY: Int(coreValue.red_primary_y),
            greenPrimaryX: Int(coreValue.green_primary_x),
            greenPrimaryY: Int(coreValue.green_primary_y),
            bluePrimaryX: Int(coreValue.blue_primary_x),
            bluePrimaryY: Int(coreValue.blue_primary_y),
            whitePointX: Int(coreValue.white_point_x),
            whitePointY: Int(coreValue.white_point_y),
            maxDisplayLuminance: Int(coreValue.max_display_luminance),
            minDisplayLuminance: Int(coreValue.min_display_luminance),
            maxContentLightLevel: Int(coreValue.max_content_light_level),
            maxFrameAverageLightLevel: Int(coreValue.max_frame_average_light_level),
            maxFullFrameLuminance: Int(coreValue.max_full_frame_luminance)
        )
    }

    var coreValue: LumenCoreHDRStaticMetadata {
        var metadata = LumenCoreHDRStaticMetadata()
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

    var masteringDisplayColorVolume: MDKVideoMasteringDisplayColorVolume {
        MDKVideoMasteringDisplayColorVolume(
            redPrimary: Self.chromaticityPoint(x: redPrimaryX, y: redPrimaryY),
            greenPrimary: Self.chromaticityPoint(x: greenPrimaryX, y: greenPrimaryY),
            bluePrimary: Self.chromaticityPoint(x: bluePrimaryX, y: bluePrimaryY),
            whitePoint: Self.chromaticityPoint(x: whitePointX, y: whitePointY),
            maxLuminance: Double(maxDisplayLuminance),
            minLuminance: Double(minDisplayLuminance) / 10_000.0
        )
    }

    var contentLightLevelInfo: MDKVideoContentLightLevelInfo? {
        guard maxContentLightLevel > 0 || maxFrameAverageLightLevel > 0 else {
            return nil
        }
        return MDKVideoContentLightLevelInfo(
            maximumContentLightLevel: UInt16(clamping: maxContentLightLevel),
            maximumFrameAverageLightLevel: UInt16(clamping: maxFrameAverageLightLevel)
        )
    }

    private static func chromaticityPoint(x: Int, y: Int) -> MDKVideoChromaticityPoint {
        MDKVideoChromaticityPoint(
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

    static func preferredCodec() -> LumenCaptureCodec {
        preferredCodec(contents: try? String(contentsOf: configurationFileURL, encoding: .utf8))
    }

    static func preferredCodec(contents: String?) -> LumenCaptureCodec {
        guard let value = configuredValue(forKey: "macos_bridge_codec", contents: contents) else {
            return .hevc
        }

        switch value {
        case LumenCaptureCodec.h264.rawValue:
            return .h264
        case LumenCaptureCodec.proResProxy.rawValue, "proresproxy", "prores_proxy":
            return .proResProxy
        default:
            return .hevc
        }
    }

    static func preferredQueueProfile() -> LumenCaptureQueueProfile {
        preferredQueueProfile(contents: try? String(contentsOf: configurationFileURL, encoding: .utf8))
    }

    static func preferredQueueProfile(contents: String?) -> LumenCaptureQueueProfile {
        switch configuredValue(forKey: "streaming_profile", contents: contents) {
        case "low-latency":
            return .q1
        case "max-quality":
            return .q4
        default:
            return .auto
        }
    }

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
    public let supportsEncodedTileStream: Bool

    public init(
        gamut: LumenClientSinkGamut = .unknown,
        transfer: LumenClientSinkTransfer = .unknown,
        currentEDRHeadroom: Float = 0,
        potentialEDRHeadroom: Float = 0,
        currentPeakLuminanceNits: Int = 0,
        potentialPeakLuminanceNits: Int = 0,
        supportsFrameGatedHDR: Bool = false,
        supportsHDRTileOverlay: Bool = false,
        supportsPerFrameHDRMetadata: Bool = false,
        supportsEncodedTileStream: Bool = false
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
        self.supportsEncodedTileStream = supportsEncodedTileStream
    }
}

public struct LumenBridgeSinkRequest: Equatable, Sendable {
    public let mode: LumenBridgeSinkMode
    public let capability: LumenBridgeSinkCapability
    public let dynamicRangeTransport: LumenCoreDynamicRangeTransport

    public init(
        mode: LumenBridgeSinkMode = LumenBridgeSinkMode(),
        capability: LumenBridgeSinkCapability = LumenBridgeSinkCapability(),
        dynamicRangeTransport: LumenCoreDynamicRangeTransport = LumenCoreDynamicRangeTransportUnknown
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

public struct LumenMacDisplayKitCaptureConfiguration: Equatable, Sendable {
    private static let supportsPartialHDROverlayProducer = true
    private static let highResolutionPixelCountThreshold = 5_000_000
    private static let veryHighResolutionPixelCountThreshold = 7_000_000

    public let displayID: UInt32
    public let codec: LumenCaptureCodec
    public let preprocessStrategy: LumenCapturePreprocessStrategy
    public let queueProfile: LumenCaptureQueueProfile
    public let encoderInputStrategy: LumenCaptureEncoderInputStrategy
    public let showCursor: Bool
    public let targetFrameRate: Int
    public let targetVideoBitRateKbps: Int
    public let requestedWidth: Int?
    public let requestedHeight: Int?
    public let sinkRequest: LumenBridgeSinkRequest
    public let effectiveDisplayState: LumenBridgeEffectiveDisplayState

    public init(
        displayID: UInt32,
        codec: LumenCaptureCodec = .hevc,
        preprocessStrategy: LumenCapturePreprocessStrategy = .none,
        queueProfile: LumenCaptureQueueProfile = .auto,
        encoderInputStrategy: LumenCaptureEncoderInputStrategy = .auto,
        showCursor: Bool = false,
        targetFrameRate: Int = 120,
        targetVideoBitRateKbps: Int = 0,
        requestedWidth: Int? = nil,
        requestedHeight: Int? = nil,
        sinkRequest: LumenBridgeSinkRequest = LumenBridgeSinkRequest(),
        effectiveDisplayState: LumenBridgeEffectiveDisplayState = LumenBridgeEffectiveDisplayState()
    ) {
        self.displayID = displayID
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.queueProfile = queueProfile
        self.encoderInputStrategy = encoderInputStrategy
        self.showCursor = showCursor
        self.targetFrameRate = max(targetFrameRate, 1)
        self.targetVideoBitRateKbps = max(targetVideoBitRateKbps, 0)
        self.requestedWidth = Self.sanitizedDimension(requestedWidth)
        self.requestedHeight = Self.sanitizedDimension(requestedHeight)
        self.sinkRequest = sinkRequest
        self.effectiveDisplayState = effectiveDisplayState
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

    public var negotiatedDynamicRangeTransport: LumenCoreDynamicRangeTransport {
        switch sinkRequest.dynamicRangeTransport {
        case LumenCoreDynamicRangeTransportFullFrameHDR:
            guard sinkPrefersHDRPresentation else {
                return LumenCoreDynamicRangeTransportSDR
            }
            return codec == .h264 ? LumenCoreDynamicRangeTransportSDR : LumenCoreDynamicRangeTransportFullFrameHDR
        case LumenCoreDynamicRangeTransportFrameGatedHDR:
            guard sinkPrefersHDRPresentation else {
                return LumenCoreDynamicRangeTransportSDR
            }
            guard codec != .h264,
                  sinkRequest.capability.supportsFrameGatedHDR else {
                return LumenCoreDynamicRangeTransportSDR
            }
            return LumenCoreDynamicRangeTransportFrameGatedHDR
        case LumenCoreDynamicRangeTransportSDRBaseHDROverlay:
            guard sinkPrefersHDRPresentation else {
                return LumenCoreDynamicRangeTransportSDR
            }
            guard codec != .h264 else {
                return LumenCoreDynamicRangeTransportSDR
            }
            if Self.supportsPartialHDROverlayProducer,
               sinkRequest.capability.supportsHDRTileOverlay,
               sinkRequest.capability.supportsPerFrameHDRMetadata {
                return LumenCoreDynamicRangeTransportSDRBaseHDROverlay
            }
            if sinkRequest.capability.supportsFrameGatedHDR {
                return LumenCoreDynamicRangeTransportFrameGatedHDR
            }
            return LumenCoreDynamicRangeTransportSDR
        case LumenCoreDynamicRangeTransportSDR, LumenCoreDynamicRangeTransportUnknown:
            return LumenCoreDynamicRangeTransportSDR
        default:
            return LumenCoreDynamicRangeTransportSDR
        }
    }

    public var negotiatedQueueProfile: LumenCaptureQueueProfile {
        guard queueProfile == .auto else {
            return queueProfile
        }

        if effectiveTargetFrameRate >= 120 {
            if codec == .proResProxy {
                return .q3
            }
            return .q1
        }

        if negotiatedDynamicRangeTransport == LumenCoreDynamicRangeTransportSDRBaseHDROverlay {
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
        negotiatedDynamicRangeTransport != LumenCoreDynamicRangeTransportSDR &&
            sinkRequest.capability.supportsPerFrameHDRMetadata
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
            codec: LumenBridgeConfigurationPreferences.preferredCodec(),
            queueProfile: LumenBridgeConfigurationPreferences.preferredQueueProfile(),
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
                    supportsPerFrameHDRMetadata: true,
                    supportsEncodedTileStream: false
                ),
                dynamicRangeTransport: transport == .pq || transport == .hlg ?
                    LumenCoreDynamicRangeTransportFrameGatedHDR :
                    LumenCoreDynamicRangeTransportSDR
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

    var mdkValue: MDKEncodedCaptureConfiguration {
        let capturePixelFormat = effectiveCapturePixelFormat
        let streamConfiguration = MDKSkyLightDisplayStreamConfiguration(
            queueDepth: negotiatedQueueProfile.queueDepthHint,
            queueProfile: negotiatedQueueProfile.mdkQueueProfile,
            showCursor: showCursor,
            outputWidth: requestedWidth,
            outputHeight: requestedHeight,
            pixelFormat: capturePixelFormat
        )

        return MDKEncodedCaptureConfiguration(
            displayID: displayID,
            streamConfiguration: streamConfiguration,
            codec: codec.mdkValue,
            preprocessStrategy: effectivePreprocessStrategy.mdkValue,
            targetFrameRate: effectiveTargetFrameRate,
            targetAverageBitRateBitsPerSecond: targetVideoBitRateKbps > 0 ? targetVideoBitRateKbps * 1_000 : nil,
            deliveryMode: .callbackOnly,
            capturePixelFormat: capturePixelFormat,
            encoderInputStrategy: effectiveEncoderInputStrategy.mdkValue,
            hdrConfiguration: encodedColorConfiguration,
            tileLayout: effectiveTileLayout
        )
    }

    var effectiveTileLayout: MDKEncodedCaptureTileLayout {
        guard codec == .hevc,
              sinkRequest.capability.supportsEncodedTileStream,
              negotiatedDynamicRangeTransport == LumenCoreDynamicRangeTransportSDRBaseHDROverlay,
              (requestedWidth ?? 0) > 0,
              (requestedHeight ?? 0) > 0 else {
            return .singleFrame
        }

        return MDKEncodedCaptureTileLayout(tileCount: 2, encodedLaneCount: 2)
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

        if usesHDRTransport || negotiatedDynamicRangeTransport == LumenCoreDynamicRangeTransportSDRBaseHDROverlay {
            return .yuv420v10
        }

        if usesHighResolutionWorkload || targetFrameRate >= 120 {
            return .yuv420v8
        }

        return .auto
    }

    public var effectiveCapturePixelFormat: UInt32 {
        if codec == .hevc {
            return kCVPixelFormatType_32BGRA
        }
        return codec.mdkValue.preferredCapturePixelFormat
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

    private var encodedColorConfiguration: MDKVideoHDRConfiguration? {
        if (usesHDRTransport || negotiatedDynamicRangeTransport == LumenCoreDynamicRangeTransportSDRBaseHDROverlay),
           codec != .h264 {
            let colorPrimaries = resolvedHDRSignalColorPrimaries
            let yCbCrMatrix = resolvedHDRSignalYCbCrMatrix
            let metadata = resolvedHDRStaticMetadata
            return MDKVideoHDRConfiguration(
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
            return MDKVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .p3D65,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: .automatic
            )
        case .rec2020:
            return MDKVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .ituR2020,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR2020,
                metadataInsertionMode: .automatic
            )
        case .srgb, .unknown:
            return MDKVideoHDRConfiguration(
                sourceColorPrimaries: resolvedSourceColorPrimaries,
                colorPrimaries: .ituR709,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: .automatic
            )
        }
    }

    private var resolvedSourceColorPrimaries: MDKVideoColorPrimaries {
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

    private var resolvedHDRTransferFunction: MDKVideoTransferFunction {
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
        guard (usesHDRTransport || negotiatedDynamicRangeTransport == LumenCoreDynamicRangeTransportSDRBaseHDROverlay),
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

    private var resolvedHDRSignalColorPrimaries: MDKVideoColorPrimaries {
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

    private var resolvedHDRSignalYCbCrMatrix: MDKVideoYCbCrMatrix {
        switch resolvedHDRTransferFunction {
        case .smpteSt2084PQ, .ituR2100HLG:
            return .ituR2020
        case .ituR709:
            return .ituR709
        }
    }

    private var resolvedHDRStaticMetadata: (
        masteringDisplayColorVolume: MDKVideoMasteringDisplayColorVolume?,
        contentLightLevelInfo: MDKVideoContentLightLevelInfo?
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
                    MDKVideoMasteringDisplayColorVolume.hdr10Default(),
                    MDKVideoContentLightLevelInfo.hdr10Default()
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

    private static let hdr709MasteringDisplayColorVolume = MDKVideoMasteringDisplayColorVolume(
        redPrimary: MDKVideoChromaticityPoint(x: 0.6400, y: 0.3300),
        greenPrimary: MDKVideoChromaticityPoint(x: 0.3000, y: 0.6000),
        bluePrimary: MDKVideoChromaticityPoint(x: 0.1500, y: 0.0600),
        whitePoint: MDKVideoChromaticityPoint(x: 0.3127, y: 0.3290),
        maxLuminance: 600.0,
        minLuminance: 0.001
    )

    private static let hdr709ContentLightLevelInfo = MDKVideoContentLightLevelInfo(
        maximumContentLightLevel: 600,
        maximumFrameAverageLightLevel: 250
    )

    private static let hdrP3MasteringDisplayColorVolume = MDKVideoMasteringDisplayColorVolume(
        redPrimary: MDKVideoChromaticityPoint(x: 0.6800, y: 0.3200),
        greenPrimary: MDKVideoChromaticityPoint(x: 0.2650, y: 0.6900),
        bluePrimary: MDKVideoChromaticityPoint(x: 0.1500, y: 0.0600),
        whitePoint: MDKVideoChromaticityPoint(x: 0.3127, y: 0.3290),
        maxLuminance: 1000.0,
        minLuminance: 0.001
    )

    private static let hdrP3ContentLightLevelInfo = MDKVideoContentLightLevelInfo(
        maximumContentLightLevel: 1000,
                maximumFrameAverageLightLevel: 400
    )

    var hdrConfigurationDebugSummary: String {
        "uses-hdr-transport=\(usesHDRTransport) requested-transport=\(lumenDynamicRangeTransportName(sinkRequest.dynamicRangeTransport)) negotiated-transport=\(lumenDynamicRangeTransportName(negotiatedDynamicRangeTransport)) requested-queue=\(queueProfile.rawValue) negotiated-queue=\(negotiatedQueueProfile.rawValue) effective-gamut=\(resolvedDisplayGamut.rawValue) effective-transfer=\(resolvedDisplayTransfer.rawValue) negotiated-static-metadata=\(effectiveDisplayState.hdrStaticMetadata != nil) current-edr-headroom=\(sinkRequest.capability.currentEDRHeadroom) potential-edr-headroom=\(sinkRequest.capability.potentialEDRHeadroom) current-peak-nits=\(sinkRequest.capability.currentPeakLuminanceNits) potential-peak-nits=\(sinkRequest.capability.potentialPeakLuminanceNits) supports-frame-gated-hdr=\(sinkRequest.capability.supportsFrameGatedHDR) supports-hdr-tile-overlay=\(sinkRequest.capability.supportsHDRTileOverlay) supports-per-frame-hdr-metadata=\(sinkRequest.capability.supportsPerFrameHDRMetadata) supports-encoded-tile-stream=\(sinkRequest.capability.supportsEncodedTileStream)"
    }
}

public struct LumenBridgeEncodedFrameSnapshot: Equatable, Sendable {
    public let codec: LumenCaptureCodec
    public let sourceDisplayTime: UInt64
    public let sourceSequenceNumber: UInt64
    public let outputCallbackLatencyMilliseconds: Double?
    public let isKeyFrame: Bool
    public let isHDRSignaled: Bool

    init(frame: MDKEncodedFrame) {
        self.codec = LumenCaptureCodec(frame.codec)
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
}

public struct LumenBridgeCaptureSnapshot: Equatable, Sendable {
    public let configuration: LumenMacDisplayKitCaptureConfiguration
    public let statistics: MDKEncodedCaptureSessionStatistics
    public let latestFrame: LumenBridgeEncodedFrameSnapshot?
    public let recentEvents: [MDKEncodedCaptureSessionEvent]
    public let coreForwarding: LumenBridgeCoreForwardingSnapshot
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

public struct LumenMacDisplayKitAudioCaptureConfiguration: Codable, Equatable, Sendable {
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

    var mdkValue: MDKAudioCaptureConfiguration {
        switch source {
        case .microphone(let inputID):
            return .microphone(
                inputID: inputID,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameSize: frameSize,
                deliveryMode: .callbackOnly
            )
        case .systemOutput(let displayID, let excludesCurrentProcessAudio):
            return .systemOutput(
                displayID: displayID,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameSize: frameSize,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio,
                deliveryMode: .callbackOnly
            )
        }
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

private struct LumenBridgeAutomationRequest: Equatable, Sendable {
    let generation: UInt64
    let videoGeneration: UInt64
    let audioGeneration: UInt64
    let videoConfiguration: LumenMacDisplayKitCaptureConfiguration?
    let audioConfiguration: LumenMacDisplayKitAudioCaptureConfiguration?

    init(snapshot: LumenCoreCaptureRequestSnapshot) {
        generation = snapshot.generation
        videoGeneration = snapshot.video_generation
        audioGeneration = snapshot.audio_generation

        let resolvedDisplayID = snapshot.display_id == 0 ? CGMainDisplayID() : snapshot.display_id
        if snapshot.video_requested,
           let codec = LumenBridgeAutomationRequest.codec(from: snapshot.codec) {
            videoConfiguration = LumenMacDisplayKitCaptureConfiguration(
                displayID: resolvedDisplayID,
                codec: codec,
                preprocessStrategy: LumenBridgeAutomationRequest.preprocessStrategy(from: snapshot.preprocess_strategy),
                queueProfile: LumenBridgeAutomationRequest.queueProfile(from: snapshot.queue_profile),
                showCursor: snapshot.show_cursor,
                targetFrameRate: Int(snapshot.target_frame_rate),
                targetVideoBitRateKbps: Int(snapshot.target_video_bitrate_kbps),
                requestedWidth: Int(snapshot.requested_width),
                requestedHeight: Int(snapshot.requested_height),
                sinkRequest: LumenBridgeSinkRequest(
                    mode: LumenBridgeSinkMode(
                        hidpi: snapshot.sink_request.mode.hidpi,
                        scaleExplicit: snapshot.sink_request.mode.scale_explicit,
                        modeIsLogical: snapshot.sink_request.mode.mode_is_logical,
                        scalePercent: Int(snapshot.sink_request.mode.scale_percent)
                    ),
                    capability: LumenBridgeSinkCapability(
                        gamut: LumenBridgeAutomationRequest.clientSinkGamut(from: snapshot.sink_request.capability.gamut),
                        transfer: LumenBridgeAutomationRequest.clientSinkTransfer(from: snapshot.sink_request.capability.transfer),
                        currentEDRHeadroom: snapshot.sink_request.capability.current_edr_headroom,
                        potentialEDRHeadroom: snapshot.sink_request.capability.potential_edr_headroom,
                        currentPeakLuminanceNits: Int(snapshot.sink_request.capability.current_peak_luminance_nits),
                        potentialPeakLuminanceNits: Int(snapshot.sink_request.capability.potential_peak_luminance_nits),
                        supportsFrameGatedHDR: snapshot.sink_request.capability.supports_frame_gated_hdr,
                        supportsHDRTileOverlay: snapshot.sink_request.capability.supports_hdr_tile_overlay,
                        supportsPerFrameHDRMetadata: snapshot.sink_request.capability.supports_per_frame_hdr_metadata,
                        supportsEncodedTileStream: snapshot.sink_request.capability.supports_encoded_tile_stream
                    ),
                    dynamicRangeTransport: snapshot.sink_request.dynamic_range_transport
                ),
                effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                    gamut: LumenBridgeAutomationRequest.clientSinkGamut(from: snapshot.effective_display_state.gamut),
                    transfer: LumenBridgeAutomationRequest.clientSinkTransfer(from: snapshot.effective_display_state.transfer),
                    hdrStaticMetadata: snapshot.effective_display_state.has_hdr_static_metadata ?
                        LumenHDRStaticMetadata(coreValue: snapshot.effective_display_state.hdr_static_metadata) :
                        nil
                )
            )
        } else {
            videoConfiguration = nil
        }

        if snapshot.audio_requested {
            switch snapshot.audio_source_kind {
            case LumenCoreAudioCaptureSourceKindSystemOutput:
                audioConfiguration = .systemOutput(
                    displayID: resolvedDisplayID,
                    sampleRate: Int(snapshot.audio_sample_rate),
                    channelCount: Int(snapshot.audio_channel_count),
                    frameSize: Int(snapshot.audio_frame_size),
                    excludesCurrentProcessAudio: snapshot.audio_excludes_current_process
                )
            case LumenCoreAudioCaptureSourceKindMicrophone:
                audioConfiguration = .microphone(
                    sampleRate: Int(snapshot.audio_sample_rate),
                    channelCount: Int(snapshot.audio_channel_count),
                    frameSize: Int(snapshot.audio_frame_size)
                )
            default:
                audioConfiguration = nil
            }
        } else {
            audioConfiguration = nil
        }
    }

    private static func codec(from value: LumenCoreCaptureCodec) -> LumenCaptureCodec? {
        switch value {
        case LumenCoreCaptureCodecH264:
            return .h264
        case LumenCoreCaptureCodecHEVC:
            return .hevc
        case LumenCoreCaptureCodecProResProxy:
            return .proResProxy
        default:
            return nil
        }
    }

    private static func preprocessStrategy(from value: LumenCoreCapturePreprocessStrategy) -> LumenCapturePreprocessStrategy {
        switch value {
        case LumenCoreCapturePreprocessStrategyDownscale2x:
            return .downscale2x
        default:
            return .none
        }
    }

    private static func queueProfile(from value: LumenCoreCaptureQueueProfile) -> LumenCaptureQueueProfile {
        switch value {
        case LumenCoreCaptureQueueProfileAuto:
            return .auto
        case LumenCoreCaptureQueueProfileQ1:
            return .q1
        case LumenCoreCaptureQueueProfileQ3:
            return .q3
        case LumenCoreCaptureQueueProfileQ4:
            return .q4
        default:
            return .q2
        }
    }

    private static func clientSinkGamut(from value: Int32) -> LumenClientSinkGamut {
        switch value {
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

    private static func clientSinkTransfer(from value: Int32) -> LumenClientSinkTransfer {
        switch value {
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
}

public actor LumenBridgeRuntime {
    public static let shared = LumenBridgeRuntime()
    public nonisolated static let statusDidChangeNotification = Notification.Name("LumenBridgeRuntimeStatusDidChange")
    private nonisolated static let statusNotificationCoalescingNanoseconds: UInt64 = 100_000_000
    private nonisolated static let encodedFrameDiagnosticsIntervalNanoseconds: UInt64 = 3_000_000_000
    private nonisolated static let captureRestartCooldownNanoseconds: UInt64 = 2_000_000_000
    private nonisolated static let automaticCoreForwardingEventCapacity = 64
    private nonisolated static func postStatusDidChangeNotificationAsync() {
        DispatchQueue.main.async {
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

    static func recommendedCoreForwardingFrameCapacity(
        for configuration: LumenMacDisplayKitCaptureConfiguration
    ) -> Int {
        // Favor freshness over throughput. Deep forwarding queues translate directly into
        // input lag when the producer starts missing cadence.
        let queueDepthReserve = max(configuration.negotiatedQueueProfile.queueDepthHint, 1)
        let hdrMetadataSlack = configuration.prefersRealtimeHDRMetadata ? 1 : 0
        let targetFrameRate = configuration.effectiveTargetFrameRate
        let tileRecordMultiplier = Int(
            max(configuration.effectiveTileLayout.tileCount, configuration.effectiveTileLayout.encodedLaneCount)
        )

        if !configuration.effectiveTileLayout.isSingleFrame {
            return min(max((queueDepthReserve + hdrMetadataSlack) * tileRecordMultiplier, tileRecordMultiplier * 2), 8)
        }

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

    private let coreForwarder = LumenCoreCaptureForwarder()
    private let audioForwarder = LumenCoreAudioCaptureForwarder()
    private let logger = Logger(subsystem: "dev.skyline23.lumen", category: "MacBridgeRuntime")
    private var encodedCaptureSession: MDKEncodedCaptureSession?
    private var encodedCaptureStartupTask: Task<Void, Error>?
    private var activeCaptureConfiguration: LumenMacDisplayKitCaptureConfiguration?
    private var latestFrame: LumenBridgeEncodedFrameSnapshot?
    private var recentEvents: [MDKEncodedCaptureSessionEvent] = []
    private var audioCaptureSession: MDKAudioCaptureSession?
    private var audioCaptureStartupTask: Task<Void, Error>?
    private var activeAudioCaptureConfiguration: LumenMacDisplayKitAudioCaptureConfiguration?
    private var captureAutomationTask: Task<Void, Never>?
    private var mirroredCaptureRequestTask: Task<Void, Never>?
    private var lastStatusNotificationUptimeNanoseconds: UInt64 = 0
    private var hasPendingStatusNotification = false
    private var lastEncodedFrameDiagnosticsUptimeNanoseconds: UInt64 = 0
    private var lastEncodedFrameSourceSequenceNumber: UInt64?
    private var lastEncodedFrameSourceDisplayTime: UInt64?
    private var lastAppliedVideoRequestGeneration: UInt64?
    private var lastAppliedAudioRequestGeneration: UInt64?
    private var lastCaptureRestartRequestUptimeNanoseconds: UInt64 = 0

    public init() {}

    public func preferredMacDisplayKitCaptureConfiguration(
        displayID: UInt32
    ) -> LumenMacDisplayKitCaptureConfiguration {
        .panelNative(displayID: displayID)
    }

    public func startMacDisplayKitCapture(
        configuration: LumenMacDisplayKitCaptureConfiguration
    ) async throws {
        try await startMacDisplayKitCapture(
            configuration: configuration,
            waitForStartupCompletion: true
        )
    }

    private func startMacDisplayKitCapture(
        configuration: LumenMacDisplayKitCaptureConfiguration,
        waitForStartupCompletion: Bool
    ) async throws {
        await stopMacDisplayKitCapture(resetRequestGeneration: false)

        let frameCapacity = Self.recommendedCoreForwardingFrameCapacity(for: configuration)
        coreForwarder.reset()
        coreForwarder.setFrameCapacity(frameCapacity)
        coreForwarder.setEventCapacity(Self.automaticCoreForwardingEventCapacity)
        coreForwarder.setProducerActive(false)
        latestFrame = nil
        recentEvents = []
        lastEncodedFrameDiagnosticsUptimeNanoseconds = 0
        lastEncodedFrameSourceSequenceNumber = nil
        lastEncodedFrameSourceDisplayTime = nil

        logger.notice(
            "Starting MacDisplayKit capture \(configuration.hdrConfigurationDebugSummary, privacy: .public) forwarding-frame-capacity=\(frameCapacity, privacy: .public)"
        )

        let session = MDKEncodedCaptureSession(configuration: configuration.mdkValue)
        let runtime = self
        let coreForwarder = self.coreForwarder
        let callbacks = MDKEncodedCaptureCallbacks(
            frameHandler: { frame in
                coreForwarder.consume(frame: frame)
                Task {
                    await runtime.recordEncodedFrame(frame)
                }
            },
            eventHandler: { event in
                coreForwarder.consume(event: event)
                Task {
                    await runtime.recordEncodedCaptureEvent(event)
                }
            }
        )

        activeCaptureConfiguration = configuration
        encodedCaptureSession = session
        coreForwarder.setProducerActive(true)
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

    public func stopMacDisplayKitCapture() async {
        await stopMacDisplayKitCapture(resetRequestGeneration: true)
    }

    public func requestImmediateCaptureKeyFrame() async {
        guard let encodedCaptureSession else {
            logger.debug("Ignoring immediate keyframe request because no MacDisplayKit capture session is active")
            return
        }

        logger.notice("Requesting an immediate MacDisplayKit keyframe for external encoded capture resync")
        await encodedCaptureSession.requestImmediateKeyFrame()
    }

    public func restartMacDisplayKitCapture(reason: String) async {
        guard let configuration = activeCaptureConfiguration else {
            logger.debug("Ignoring MacDisplayKit capture restart because no capture session is active reason=\(reason, privacy: .public)")
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if lastCaptureRestartRequestUptimeNanoseconds != 0 &&
            now - lastCaptureRestartRequestUptimeNanoseconds < Self.captureRestartCooldownNanoseconds {
            logger.notice(
                "Suppressing MacDisplayKit capture restart because the cooldown is active reason=\(reason, privacy: .public)"
            )
            return
        }

        lastCaptureRestartRequestUptimeNanoseconds = now
        logger.notice(
            "Restarting MacDisplayKit capture to recover stale external encoded frames reason=\(reason, privacy: .public)"
        )
        await stopMacDisplayKitCapture(resetRequestGeneration: false)
        try? await startMacDisplayKitCapture(
            configuration: configuration,
            waitForStartupCompletion: false
        )
    }

    private func stopMacDisplayKitCapture(resetRequestGeneration: Bool) async {
        encodedCaptureStartupTask?.cancel()
        encodedCaptureStartupTask = nil
        guard let session = encodedCaptureSession else {
            encodedCaptureSession = nil
            activeCaptureConfiguration = nil
            coreForwarder.setProducerActive(false)
            latestFrame = nil
            recentEvents = []
            lastEncodedFrameDiagnosticsUptimeNanoseconds = 0
            lastEncodedFrameSourceSequenceNumber = nil
            lastEncodedFrameSourceDisplayTime = nil
            if resetRequestGeneration {
                lastAppliedVideoRequestGeneration = nil
            }
            return
        }

        await session.stop()
        coreForwarder.setProducerActive(false)
        encodedCaptureSession = nil
        activeCaptureConfiguration = nil
        lastEncodedFrameDiagnosticsUptimeNanoseconds = 0
        lastEncodedFrameSourceSequenceNumber = nil
        lastEncodedFrameSourceDisplayTime = nil
        if resetRequestGeneration {
            lastAppliedVideoRequestGeneration = nil
        }
        publishStatusDidChange(immediate: true)
    }

    public func makeDefaultMicrophoneAudioConfiguration() -> LumenMacDisplayKitAudioCaptureConfiguration {
        .microphone()
    }

    public func makeSystemOutputAudioConfiguration(
        displayID: UInt32
    ) -> LumenMacDisplayKitAudioCaptureConfiguration {
        .systemOutput(displayID: displayID)
    }

    public func startMacDisplayKitAudioCapture(
        configuration: LumenMacDisplayKitAudioCaptureConfiguration
    ) async throws {
        try await startMacDisplayKitAudioCapture(
            configuration: configuration,
            waitForStartupCompletion: true
        )
    }

    private func startMacDisplayKitAudioCapture(
        configuration: LumenMacDisplayKitAudioCaptureConfiguration,
        waitForStartupCompletion: Bool
    ) async throws {
        await stopMacDisplayKitAudioCapture(resetRequestGeneration: false)

        audioForwarder.reset()
        audioForwarder.setProducerActive(false)
        let runtime = self
        let session = MDKAudioCaptureSession(configuration: configuration.mdkValue)
        logger.notice(
            "Starting MacDisplayKit audio capture source=\(configuration.source.kind.rawValue, privacy: .public) sample-rate=\(configuration.sampleRate, privacy: .public) channels=\(configuration.channelCount, privacy: .public) frame-size=\(configuration.frameSize, privacy: .public)"
        )
        let callbacks = MDKAudioCaptureCallbacks(
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

    public func stopMacDisplayKitAudioCapture() async {
        await stopMacDisplayKitAudioCapture(resetRequestGeneration: true)
    }

    private func stopMacDisplayKitAudioCapture(resetRequestGeneration: Bool) async {
        audioCaptureStartupTask?.cancel()
        audioCaptureStartupTask = nil
        guard let session = audioCaptureSession else {
            audioCaptureSession = nil
            activeAudioCaptureConfiguration = nil
            audioForwarder.reset()
            audioForwarder.setProducerActive(false)
            if resetRequestGeneration {
                lastAppliedAudioRequestGeneration = nil
            }
            return
        }

        await session.stop()
        audioForwarder.setProducerActive(false)
        audioCaptureSession = nil
        activeAudioCaptureConfiguration = nil
        if resetRequestGeneration {
            lastAppliedAudioRequestGeneration = nil
        }
        publishStatusDidChange(immediate: true)
    }

    private func handleEncodedCaptureStartupFinished(for session: MDKEncodedCaptureSession) {
        guard encodedCaptureSession === session else {
            return
        }
        encodedCaptureStartupTask = nil
    }

    private func handleEncodedCaptureStartupFailure(for session: MDKEncodedCaptureSession, error: Error) {
        guard encodedCaptureSession === session else {
            return
        }
        encodedCaptureStartupTask = nil
        encodedCaptureSession = nil
        activeCaptureConfiguration = nil
        coreForwarder.setProducerActive(false)
        latestFrame = nil
        recentEvents = []
        lastEncodedFrameDiagnosticsUptimeNanoseconds = 0
        lastEncodedFrameSourceSequenceNumber = nil
        lastEncodedFrameSourceDisplayTime = nil
        logger.error("MacDisplayKit video startup failed: \(String(describing: error), privacy: .public)")
        publishStatusDidChange(immediate: true)
    }

    private func handleAudioCaptureStartupFinished(for session: MDKAudioCaptureSession) {
        guard audioCaptureSession === session else {
            return
        }
        audioCaptureStartupTask = nil
    }

    private func handleAudioCaptureStartupFailure(for session: MDKAudioCaptureSession, error: Error) {
        guard audioCaptureSession === session else {
            return
        }
        audioCaptureStartupTask = nil
        audioCaptureSession = nil
        activeAudioCaptureConfiguration = nil
        audioForwarder.setProducerActive(false)
        logger.error("MacDisplayKit audio startup failed: \(String(describing: error), privacy: .public)")
        publishStatusDidChange(immediate: true)
    }

    public func startLumenCoreCaptureAutomation() {
        guard captureAutomationTask == nil else {
            return
        }

        startMirroredLumenCoreCaptureRequestSync()
        captureAutomationTask = Task.detached(priority: .background) { [weak self] in
            var observedGeneration = UInt64.max
            while !Task.isCancelled {
                let changed = LumenCoreCaptureRequestWaitForGenerationChange(observedGeneration, 250)
                if !changed && observedGeneration != UInt64.max {
                    continue
                }

                let snapshot = LumenCoreCaptureRequestCopySnapshot()
                observedGeneration = snapshot.generation
                await self?.applyLumenCoreCaptureRequest(
                    LumenBridgeAutomationRequest(snapshot: snapshot)
                )
            }
        }
        publishStatusDidChange(immediate: true)
    }

    public func stopLumenCoreCaptureAutomation() async {
        captureAutomationTask?.cancel()
        captureAutomationTask = nil
        mirroredCaptureRequestTask?.cancel()
        mirroredCaptureRequestTask = nil
        await stopMacDisplayKitAudioCapture()
        await stopMacDisplayKitCapture()
        publishStatusDidChange(immediate: true)
    }

    public func isLumenCoreCaptureAutomationRunning() -> Bool {
        captureAutomationTask != nil
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
            coreForwarding: coreForwarder.snapshot()
        )
    }

    public func coreForwardingSnapshot() -> LumenBridgeCoreForwardingSnapshot {
        coreForwarder.snapshot()
    }

    public func captureDiagnosticsString() async -> String {
        guard let session = encodedCaptureSession else {
            return "n/a"
        }

        return Self.captureDiagnosticsSnippet(from: await session.statisticsSnapshot())
    }

    public func configureCoreForwarding(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        coreForwarder.setFrameCapacity(frameCapacity)
        coreForwarder.setEventCapacity(eventCapacity)
    }

    public func configureAudioForwarding(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        audioForwarder.setFrameCapacity(frameCapacity)
        audioForwarder.setEventCapacity(eventCapacity)
    }

    public func drainNextCoreForwardedFrame() -> LumenBridgeCoreDrainedFrame? {
        coreForwarder.popNextFrame()
    }

    public func drainNextCoreForwardedEvent() -> LumenBridgeCoreDrainedEvent? {
        coreForwarder.popNextEvent()
    }

    public func audioForwardingSnapshot() -> LumenBridgeAudioForwardingSnapshot {
        audioForwarder.snapshot()
    }

    public func drainNextCoreForwardedAudioFrame() -> LumenBridgeDrainedAudioFrame? {
        audioForwarder.popNextFrame()
    }

    public func drainNextCoreForwardedAudioEvent() -> LumenBridgeDrainedAudioEvent? {
        audioForwarder.popNextEvent()
    }

    public func statusSnapshot() -> LumenBridgeStatus {
        LumenBridgeStatus(
            coreVersion: String(cString: LumenCoreBootstrapVersionString()),
            runtimeDescription: String(cString: LumenCoreBootstrapRuntimeDescription()),
            integrationStatus: "MacDisplayKit owns macOS capture and encode. LumenMacBridge forwards encoded video and PCM audio into LumenCore ingress surfaces while Lumen keeps the web, session, and transport stack.",
            captureSessionRunning: encodedCaptureSession != nil,
            audioCaptureSessionRunning: audioCaptureSession != nil,
            automaticCaptureOrchestrationRunning: captureAutomationTask != nil
        )
    }

    private func applyLumenCoreCaptureRequest(_ request: LumenBridgeAutomationRequest) async {
        if Self.shouldApplyAutomationRequest(
            requestedConfiguration: request.videoConfiguration,
            activeConfiguration: activeCaptureConfiguration,
            sessionIsActive: encodedCaptureSession != nil,
            lastAppliedGeneration: lastAppliedVideoRequestGeneration
        ) {
            lastAppliedVideoRequestGeneration = request.videoGeneration
            if let configuration = request.videoConfiguration {
                let frameCapacity = Self.recommendedCoreForwardingFrameCapacity(for: configuration)
                logger.notice(
                    "Applying LumenCore macOS bridge capture request display-id=\(configuration.displayID, privacy: .public) codec=\(configuration.codec.rawValue, privacy: .public) requested-queue=\(configuration.queueProfile.rawValue, privacy: .public) negotiated-queue=\(configuration.negotiatedQueueProfile.rawValue, privacy: .public) requested-transport=\(lumenDynamicRangeTransportName(configuration.sinkRequest.dynamicRangeTransport), privacy: .public) negotiated-transport=\(lumenDynamicRangeTransportName(configuration.negotiatedDynamicRangeTransport), privacy: .public) requested-fps=\(configuration.targetFrameRate, privacy: .public) effective-fps=\(configuration.effectiveTargetFrameRate, privacy: .public) bitrate-kbps=\(configuration.targetVideoBitRateKbps, privacy: .public) forwarding-frame-capacity=\(frameCapacity, privacy: .public)"
                )
                try? await startMacDisplayKitCapture(
                    configuration: configuration,
                    waitForStartupCompletion: false
                )
            } else {
                let activeConfigurationSummary: String
                if let activeConfiguration = activeCaptureConfiguration {
                    activeConfigurationSummary =
                        "display-id=\(activeConfiguration.displayID) codec=\(activeConfiguration.codec.rawValue) queue=\(activeConfiguration.queueProfile.rawValue) fps=\(activeConfiguration.targetFrameRate)"
                } else {
                    activeConfigurationSummary = "none"
                }
                logger.notice(
                    "Stopping MacDisplayKit capture because LumenCore video request resolved to nil video-generation=\(request.videoGeneration, privacy: .public) last-applied-video-generation=\(self.lastAppliedVideoRequestGeneration ?? 0, privacy: .public) session-active=\(self.encodedCaptureSession != nil, privacy: .public) active-configuration=\(activeConfigurationSummary, privacy: .public)"
                )
                await stopMacDisplayKitCapture()
            }
        }

        if Self.shouldApplyAutomationRequest(
            requestedConfiguration: request.audioConfiguration,
            activeConfiguration: activeAudioCaptureConfiguration,
            sessionIsActive: audioCaptureSession != nil,
            lastAppliedGeneration: lastAppliedAudioRequestGeneration
        ) {
            lastAppliedAudioRequestGeneration = request.audioGeneration
            if let configuration = request.audioConfiguration {
                try? await startMacDisplayKitAudioCapture(
                    configuration: configuration,
                    waitForStartupCompletion: false
                )
            } else {
                let activeAudioConfigurationSummary: String
                if let activeAudioCaptureConfiguration = self.activeAudioCaptureConfiguration {
                    let sourceDescription: String
                    switch activeAudioCaptureConfiguration.source {
                    case .microphone:
                        sourceDescription = "microphone"
                    case .systemOutput(let displayID, let excludesCurrentProcessAudio):
                        sourceDescription =
                            "system-output display-id=\(displayID) excludes-current-process=\(excludesCurrentProcessAudio)"
                    }
                    activeAudioConfigurationSummary =
                        "source=\(sourceDescription) sample-rate=\(activeAudioCaptureConfiguration.sampleRate) channels=\(activeAudioCaptureConfiguration.channelCount)"
                } else {
                    activeAudioConfigurationSummary = "none"
                }
                logger.notice(
                    "Stopping MacDisplayKit audio capture because LumenCore audio request resolved to nil audio-generation=\(request.audioGeneration, privacy: .public) last-applied-audio-generation=\(self.lastAppliedAudioRequestGeneration ?? 0, privacy: .public) session-active=\(self.audioCaptureSession != nil, privacy: .public) active-configuration=\(activeAudioConfigurationSummary, privacy: .public)"
                )
                await stopMacDisplayKitAudioCapture()
            }
        }
    }

    static func shouldApplyAutomationRequest<Configuration: Equatable>(
        requestedConfiguration: Configuration?,
        activeConfiguration: Configuration?,
        sessionIsActive: Bool,
        lastAppliedGeneration: UInt64?
    ) -> Bool {
        if requestedConfiguration != activeConfiguration {
            return true
        }

        guard requestedConfiguration != nil else {
            return false
        }

        if !sessionIsActive {
            return true
        }

        return lastAppliedGeneration == nil
    }

    private func startMirroredLumenCoreCaptureRequestSync() {
        guard mirroredCaptureRequestTask == nil else {
            return
        }

        mirroredCaptureRequestTask = Task.detached(priority: .background) {
            let coordinator = LumenCaptureRequestMirrorCoordinator()
            await coordinator.syncCurrentState()

            let notificationCenter = DistributedNotificationCenter.default()
            let notifications = notificationCenter.notifications(
                named: LumenBridgeMirroredCaptureRequestSnapshot.changedNotification
            )

            for await _ in notifications {
                if Task.isCancelled {
                    break
                }
                await coordinator.syncCurrentState()
            }
        }
    }

    private func recordEncodedFrame(_ frame: MDKEncodedFrame) async {
        latestFrame = LumenBridgeEncodedFrameSnapshot(frame: frame)
        logEncodedFrameDiagnosticsIfNeeded(frame, captureStatistics: nil)
    }

    private func recordEncodedCaptureEvent(_ event: MDKEncodedCaptureSessionEvent) async {
        recentEvents.append(event)
        if recentEvents.count > 16 {
            recentEvents.removeFirst(recentEvents.count - 16)
        }
        let captureStatistics = await encodedCaptureSession?.statisticsSnapshot()
        let captureMinCallbackLatency = formattedLatency(captureStatistics?.minOutputCallbackLatencyMilliseconds)
        let captureMaxCallbackLatency = formattedLatency(captureStatistics?.maxOutputCallbackLatencyMilliseconds)
        let captureDiagnostics = Self.captureDiagnosticsSnippet(from: captureStatistics)
        logger.notice(
            "Mac bridge capture event kind=\(event.kind.rawValue, privacy: .public) message=\(event.message ?? "n/a", privacy: .public) stop-status=\(event.stopStatus ?? 0, privacy: .public) automatic-restarts=\(event.automaticRestartCount ?? 0, privacy: .public) source-display-time=\(event.sourceDisplayTime ?? 0, privacy: .public) capture-emitted=\(captureStatistics?.emittedFrameCount ?? 0, privacy: .public) capture-dropped=\(captureStatistics?.droppedFrameCount ?? 0, privacy: .public) capture-processing-failures=\(captureStatistics?.processingFailureCount ?? 0, privacy: .public) capture-running=\(captureStatistics?.isRunning ?? false, privacy: .public) capture-last-error=\(captureStatistics?.lastErrorDescription ?? "n/a", privacy: .public) capture-min-callback-latency-ms=\(captureMinCallbackLatency, privacy: .public) capture-max-callback-latency-ms=\(captureMaxCallbackLatency, privacy: .public) capture-vt=\(captureDiagnostics, privacy: .public)"
        )
        publishStatusDidChange()
    }

    private func logEncodedFrameDiagnosticsIfNeeded(
        _ frame: MDKEncodedFrame,
        captureStatistics: MDKEncodedCaptureSessionStatistics?
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
            let codec = LumenCaptureCodec(frame.codec).rawValue
            let ingressSnapshot = coreForwarder.snapshot()
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
            let captureDiagnostics = Self.captureDiagnosticsSnippet(from: captureStatistics)

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

    private nonisolated static func captureDiagnosticsSnippet(from statistics: MDKEncodedCaptureSessionStatistics?) -> String {
        guard let statistics else {
            return "n/a"
        }

        let interestingPrefixes = [
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
            "videoToolboxRecommendedParallelizationLimit=",
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
            "videoToolboxConfiguredProfileLevel=",
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

    private func recordAudioFrame(_ frame: MDKAudioFrame) {
        audioForwarder.consume(frame: frame)
        publishStatusDidChange()
    }

    private func recordAudioCaptureEvent(_ event: MDKAudioCaptureSessionEvent) {
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

    func debugResetCoreForwarding() {
        coreForwarder.reset()
    }

    func debugSetCoreForwardingCapacities(frameCapacity: Int, eventCapacity: Int) {
        configureCoreForwarding(frameCapacity: frameCapacity, eventCapacity: eventCapacity)
    }

    func debugForwardSyntheticFrame(
        sampleBuffer: CMSampleBuffer,
        codec: LumenCaptureCodec = .hevc,
        sourceSequenceNumber: UInt64 = 1,
        sourceDisplayTime: UInt64 = 1,
        outputCallbackLatencyMilliseconds: Double? = nil,
        isKeyFrame: Bool = true,
        isHDRSignaled: Bool = false,
        tileMetadata: LumenBridgeEncodedTileMetadata = .singleFrame
    ) {
        coreForwarder.consume(
            sampleBuffer: sampleBuffer,
            codec: codec,
            sourceSequenceNumber: sourceSequenceNumber,
            sourceDisplayTime: sourceDisplayTime,
            outputCallbackLatencyMilliseconds: outputCallbackLatencyMilliseconds,
            isKeyFrame: isKeyFrame,
            isHDRSignaled: isHDRSignaled,
            tileMetadata: tileMetadata
        )
    }

    func debugForwardSyntheticEvent(
        kind: MDKEncodedCaptureSessionEventKind,
        message: String? = nil,
        stopStatus: Int32? = nil,
        automaticRestartCount: UInt64? = nil,
        sourceDisplayTime: UInt64? = nil
    ) {
        let event = MDKEncodedCaptureSessionEvent(
            kind: kind,
            message: message,
            stopStatus: stopStatus,
            automaticRestartCount: automaticRestartCount,
            sourceDisplayTime: sourceDisplayTime
        )
        coreForwarder.consume(event: event)
    }

    func debugDrainNextForwardedFrame() -> LumenBridgeCoreDrainedFrame? {
        drainNextCoreForwardedFrame()
    }

    func debugDrainNextForwardedEvent() -> LumenBridgeCoreDrainedEvent? {
        drainNextCoreForwardedEvent()
    }

}

private extension LumenCaptureCodec {
    init(_ codec: MDKVideoEncoderCodec) {
        switch codec {
        case .h264:
            self = .h264
        case .hevc:
            self = .hevc
        case .proResProxy:
            self = .proResProxy
        }
    }
}

private extension LumenBridgeCaptureEventKind {
    init(_ kind: MDKAudioCaptureSessionEventKind) {
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
