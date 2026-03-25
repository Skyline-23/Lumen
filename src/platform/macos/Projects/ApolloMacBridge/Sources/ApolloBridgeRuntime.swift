import ApolloCore
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import MacDisplayCaptureKit
import OSLog

public enum ApolloCaptureCodec: String, CaseIterable, Codable, Sendable {
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

public enum ApolloCapturePreprocessStrategy: String, CaseIterable, Codable, Sendable {
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

public enum ApolloCaptureQueueProfile: String, CaseIterable, Codable, Sendable {
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
            // depth here so ApolloCore forwarding keeps enough slack without reviving
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

public enum ApolloCaptureEncoderInputStrategy: String, CaseIterable, Codable, Sendable {
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

public enum ApolloClientDisplayGamut: String, CaseIterable, Codable, Sendable {
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

public enum ApolloClientDisplayTransfer: String, CaseIterable, Codable, Sendable {
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

public struct ApolloHDRStaticMetadata: Equatable, Sendable {
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

    init(coreValue: ApolloCoreHDRStaticMetadata) {
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

    var coreValue: ApolloCoreHDRStaticMetadata {
        var metadata = ApolloCoreHDRStaticMetadata()
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

enum ApolloBridgeConfigurationPreferences {
    static let configurationFileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Apollo", directoryHint: .isDirectory)
            .appending(path: "apollo.conf", directoryHint: .notDirectory)
    }()

    static func preferredCodec() -> ApolloCaptureCodec {
        preferredCodec(contents: try? String(contentsOf: configurationFileURL, encoding: .utf8))
    }

    static func preferredCodec(contents: String?) -> ApolloCaptureCodec {
        guard let value = configuredValue(forKey: "macos_bridge_codec", contents: contents) else {
            return .hevc
        }

        switch value {
        case ApolloCaptureCodec.h264.rawValue:
            return .h264
        case ApolloCaptureCodec.proResProxy.rawValue, "proresproxy", "prores_proxy":
            return .proResProxy
        default:
            return .hevc
        }
    }

    static func preferredQueueProfile() -> ApolloCaptureQueueProfile {
        preferredQueueProfile(contents: try? String(contentsOf: configurationFileURL, encoding: .utf8))
    }

    static func preferredQueueProfile(contents: String?) -> ApolloCaptureQueueProfile {
        switch configuredValue(forKey: "macos_bridge_queue_profile", contents: contents) {
        case "auto":
            return .auto
        case "q1":
            return .q1
        case "q2":
            return .q2
        case "q3":
            return .q3
        case "q4":
            return .q4
        default:
            return .auto
        }
    }

    static func preferredEncoderInputStrategy() -> ApolloCaptureEncoderInputStrategy {
        preferredEncoderInputStrategy(contents: try? String(contentsOf: configurationFileURL, encoding: .utf8))
    }

    static func preferredEncoderInputStrategy(contents: String?) -> ApolloCaptureEncoderInputStrategy {
        switch configuredValue(forKey: "macos_bridge_encoder_input", contents: contents) {
        case ApolloCaptureEncoderInputStrategy.bgra.rawValue:
            return .bgra
        case ApolloCaptureEncoderInputStrategy.yuv420v8.rawValue, "420", "nv12":
            return .yuv420v8
        case ApolloCaptureEncoderInputStrategy.yuv420v10.rawValue, "x420", "p010":
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

public struct ApolloMacDisplayKitCaptureConfiguration: Equatable, Sendable {
    public let displayID: UInt32
    public let codec: ApolloCaptureCodec
    public let preprocessStrategy: ApolloCapturePreprocessStrategy
    public let queueProfile: ApolloCaptureQueueProfile
    public let encoderInputStrategy: ApolloCaptureEncoderInputStrategy
    public let showCursor: Bool
    public let targetFrameRate: Int
    public let requestedWidth: Int?
    public let requestedHeight: Int?
    public let enableHDR: Bool
    public let clientDisplayGamut: ApolloClientDisplayGamut
    public let clientDisplayTransfer: ApolloClientDisplayTransfer
    public let effectiveDisplayGamut: ApolloClientDisplayGamut
    public let effectiveDisplayTransfer: ApolloClientDisplayTransfer
    public let hdrStaticMetadata: ApolloHDRStaticMetadata?
    public let clientDisplayCurrentEDRHeadroom: Float
    public let clientDisplayPotentialEDRHeadroom: Float
    public let clientDisplayCurrentPeakLuminanceNits: Int
    public let clientDisplayPotentialPeakLuminanceNits: Int

    public init(
        displayID: UInt32,
        codec: ApolloCaptureCodec = .hevc,
        preprocessStrategy: ApolloCapturePreprocessStrategy = .none,
        queueProfile: ApolloCaptureQueueProfile = .auto,
        encoderInputStrategy: ApolloCaptureEncoderInputStrategy = .auto,
        showCursor: Bool = false,
        targetFrameRate: Int = 120,
        requestedWidth: Int? = nil,
        requestedHeight: Int? = nil,
        enableHDR: Bool = false,
        clientDisplayGamut: ApolloClientDisplayGamut = .unknown,
        clientDisplayTransfer: ApolloClientDisplayTransfer = .unknown,
        effectiveDisplayGamut: ApolloClientDisplayGamut = .unknown,
        effectiveDisplayTransfer: ApolloClientDisplayTransfer = .unknown,
        hdrStaticMetadata: ApolloHDRStaticMetadata? = nil,
        clientDisplayCurrentEDRHeadroom: Float = 0,
        clientDisplayPotentialEDRHeadroom: Float = 0,
        clientDisplayCurrentPeakLuminanceNits: Int = 0,
        clientDisplayPotentialPeakLuminanceNits: Int = 0
    ) {
        self.displayID = displayID
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.queueProfile = queueProfile
        self.encoderInputStrategy = encoderInputStrategy
        self.showCursor = showCursor
        self.targetFrameRate = max(targetFrameRate, 1)
        self.requestedWidth = Self.sanitizedDimension(requestedWidth)
        self.requestedHeight = Self.sanitizedDimension(requestedHeight)
        self.enableHDR = enableHDR
        self.clientDisplayGamut = clientDisplayGamut
        self.clientDisplayTransfer = clientDisplayTransfer
        self.effectiveDisplayGamut = effectiveDisplayGamut
        self.effectiveDisplayTransfer = effectiveDisplayTransfer
        self.hdrStaticMetadata = hdrStaticMetadata
        self.clientDisplayCurrentEDRHeadroom = max(clientDisplayCurrentEDRHeadroom, 0)
        self.clientDisplayPotentialEDRHeadroom = max(clientDisplayPotentialEDRHeadroom, 0)
        self.clientDisplayCurrentPeakLuminanceNits = max(clientDisplayCurrentPeakLuminanceNits, 0)
        self.clientDisplayPotentialPeakLuminanceNits = max(clientDisplayPotentialPeakLuminanceNits, 0)
    }

    struct EncodedHDRConfigurationSnapshot: Equatable, Sendable {
        let signalColorPrimaries: String
        let transferFunction: String
        let signalYCbCrMatrix: String
        let staticMetadataSource: String
    }

    public static func panelNative(displayID: UInt32) -> Self {
        let environment = ProcessInfo.processInfo.environment
        return Self(
            displayID: displayID,
            codec: ApolloBridgeConfigurationPreferences.preferredCodec(),
            queueProfile: ApolloBridgeConfigurationPreferences.preferredQueueProfile(),
            encoderInputStrategy: ApolloBridgeConfigurationPreferences.preferredEncoderInputStrategy(),
            clientDisplayGamut: ApolloClientDisplayGamut(
                environmentValue: environment["APOLLO_CLIENT_DISPLAY_GAMUT"]
            ),
            clientDisplayTransfer: ApolloClientDisplayTransfer(
                environmentValue: environment["APOLLO_CLIENT_DISPLAY_TRANSFER"]
            ),
            effectiveDisplayGamut: ApolloClientDisplayGamut(
                environmentValue: environment["APOLLO_CLIENT_DISPLAY_GAMUT"]
            ),
            effectiveDisplayTransfer: ApolloClientDisplayTransfer(
                environmentValue: environment["APOLLO_CLIENT_DISPLAY_TRANSFER"]
            )
        )
    }

    var mdkValue: MDKEncodedCaptureConfiguration {
        let streamConfiguration = MDKSkyLightDisplayStreamConfiguration(
            queueDepth: queueProfile.queueDepthHint,
            queueProfile: queueProfile.mdkQueueProfile,
            showCursor: showCursor,
            outputWidth: requestedWidth,
            outputHeight: requestedHeight,
            pixelFormat: codec.mdkValue.preferredCapturePixelFormat
        )

        return MDKEncodedCaptureConfiguration(
            displayID: displayID,
            streamConfiguration: streamConfiguration,
            codec: codec.mdkValue,
            preprocessStrategy: preprocessStrategy.mdkValue,
            targetFrameRate: targetFrameRate,
            deliveryMode: .callbackOnly,
            encoderInputStrategy: encoderInputStrategy.mdkValue,
            hdrConfiguration: encodedColorConfiguration
        )
    }

    private var encodedColorConfiguration: MDKVideoHDRConfiguration? {
        if enableHDR, codec != .h264 {
            let colorPrimaries = resolvedHDRSignalColorPrimaries
            let yCbCrMatrix = resolvedHDRSignalYCbCrMatrix
            let metadata = resolvedHDRStaticMetadata
            return MDKVideoHDRConfiguration(
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
                colorPrimaries: .p3D65,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: .automatic
            )
        case .rec2020:
            return MDKVideoHDRConfiguration(
                colorPrimaries: .ituR2020,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR2020,
                metadataInsertionMode: .automatic
            )
        case .srgb, .unknown:
            return MDKVideoHDRConfiguration(
                colorPrimaries: .ituR709,
                transferFunction: .ituR709,
                yCbCrMatrix: .ituR709,
                metadataInsertionMode: .automatic
            )
        }
    }

    private var resolvedDisplayGamut: ApolloClientDisplayGamut {
        effectiveDisplayGamut == .unknown ? clientDisplayGamut : effectiveDisplayGamut
    }

    private var resolvedDisplayTransfer: ApolloClientDisplayTransfer {
        effectiveDisplayTransfer == .unknown ? clientDisplayTransfer : effectiveDisplayTransfer
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
        guard enableHDR, codec != .h264 else {
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
        if let hdrStaticMetadata {
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
        if hdrStaticMetadata != nil {
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
        "hdr=\(enableHDR) client-gamut=\(clientDisplayGamut.rawValue) client-transfer=\(clientDisplayTransfer.rawValue) effective-gamut=\(resolvedDisplayGamut.rawValue) effective-transfer=\(resolvedDisplayTransfer.rawValue) negotiated-static-metadata=\(hdrStaticMetadata != nil) current-edr-headroom=\(clientDisplayCurrentEDRHeadroom) potential-edr-headroom=\(clientDisplayPotentialEDRHeadroom) current-peak-nits=\(clientDisplayCurrentPeakLuminanceNits) potential-peak-nits=\(clientDisplayPotentialPeakLuminanceNits)"
    }
}

public struct ApolloBridgeEncodedFrameSnapshot: Equatable, Sendable {
    public let codec: ApolloCaptureCodec
    public let sourceDisplayTime: UInt64
    public let sourceSequenceNumber: UInt64
    public let outputCallbackLatencyMilliseconds: Double?
    public let isKeyFrame: Bool
    public let isHDRSignaled: Bool

    init(frame: MDKEncodedFrame) {
        self.codec = ApolloCaptureCodec(frame.codec)
        self.sourceDisplayTime = frame.sourceDisplayTime
        self.sourceSequenceNumber = frame.sourceSequenceNumber
        self.outputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds
        self.isKeyFrame = frame.isKeyFrame
        self.isHDRSignaled = frame.isHDRSignaled
    }
}

public enum ApolloBridgeCaptureEventKind: String, Codable, Equatable, Sendable {
    case started
    case stopped
    case restarted
    case failed
    case droppedFrame
}

public struct ApolloBridgeCaptureSnapshot: Equatable, Sendable {
    public let configuration: ApolloMacDisplayKitCaptureConfiguration
    public let statistics: MDKEncodedCaptureSessionStatistics
    public let latestFrame: ApolloBridgeEncodedFrameSnapshot?
    public let recentEvents: [MDKEncodedCaptureSessionEvent]
    public let coreForwarding: ApolloBridgeCoreForwardingSnapshot
}

public struct ApolloBridgeStatus: Equatable, Sendable {
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

public enum ApolloAudioCaptureSourceKind: String, Codable, Equatable, Sendable {
    case microphone
    case systemOutput = "system-output"
}

public enum ApolloAudioCaptureSource: Codable, Equatable, Sendable {
    case microphone(inputID: String?)
    case systemOutput(displayID: UInt32, excludesCurrentProcessAudio: Bool)

    public var kind: ApolloAudioCaptureSourceKind {
        switch self {
        case .microphone:
            return .microphone
        case .systemOutput:
            return .systemOutput
        }
    }
}

public struct ApolloMacDisplayKitAudioCaptureConfiguration: Codable, Equatable, Sendable {
    public let source: ApolloAudioCaptureSource
    public let sampleRate: Int
    public let channelCount: Int
    public let frameSize: Int

    public init(
        source: ApolloAudioCaptureSource,
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

public struct ApolloBridgeAudioForwardingSnapshot: Equatable, Sendable {
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
    public let lastEventKind: ApolloBridgeCaptureEventKind?
}

public struct ApolloBridgeDrainedAudioFrame: Equatable, Sendable {
    public let sequenceNumber: UInt64
    public let hostTimeNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let pcmFloat32LE: Data
}

public struct ApolloBridgeDrainedAudioEvent: Equatable, Sendable {
    public let kind: ApolloBridgeCaptureEventKind
    public let message: String?
    public let stopStatus: Int32?
    public let automaticRestartCount: UInt64?
    public let sourceSequenceNumber: UInt64?
}

private struct ApolloBridgeAutomationRequest: Equatable, Sendable {
    let generation: UInt64
    let videoGeneration: UInt64
    let audioGeneration: UInt64
    let videoConfiguration: ApolloMacDisplayKitCaptureConfiguration?
    let audioConfiguration: ApolloMacDisplayKitAudioCaptureConfiguration?

    init(snapshot: ApolloCoreCaptureRequestSnapshot) {
        generation = snapshot.generation
        videoGeneration = snapshot.video_generation
        audioGeneration = snapshot.audio_generation

        let resolvedDisplayID = snapshot.display_id == 0 ? CGMainDisplayID() : snapshot.display_id
        if snapshot.video_requested,
           let codec = ApolloBridgeAutomationRequest.codec(from: snapshot.codec) {
            videoConfiguration = ApolloMacDisplayKitCaptureConfiguration(
                displayID: resolvedDisplayID,
                codec: codec,
                preprocessStrategy: ApolloBridgeAutomationRequest.preprocessStrategy(from: snapshot.preprocess_strategy),
                queueProfile: ApolloBridgeAutomationRequest.queueProfile(from: snapshot.queue_profile),
                showCursor: snapshot.show_cursor,
                targetFrameRate: Int(snapshot.target_frame_rate),
                requestedWidth: Int(snapshot.requested_width),
                requestedHeight: Int(snapshot.requested_height),
                enableHDR: snapshot.dynamic_range > 0,
                clientDisplayGamut: ApolloBridgeAutomationRequest.clientDisplayGamut(from: snapshot.client_display_gamut),
                clientDisplayTransfer: ApolloBridgeAutomationRequest.clientDisplayTransfer(from: snapshot.client_display_transfer),
                effectiveDisplayGamut: ApolloBridgeAutomationRequest.clientDisplayGamut(from: snapshot.effective_display_gamut),
                effectiveDisplayTransfer: ApolloBridgeAutomationRequest.clientDisplayTransfer(from: snapshot.effective_display_transfer),
                hdrStaticMetadata: snapshot.has_effective_hdr_metadata ?
                    ApolloHDRStaticMetadata(coreValue: snapshot.effective_hdr_metadata) :
                    nil,
                clientDisplayCurrentEDRHeadroom: snapshot.client_display_current_edr_headroom,
                clientDisplayPotentialEDRHeadroom: snapshot.client_display_potential_edr_headroom,
                clientDisplayCurrentPeakLuminanceNits: Int(snapshot.client_display_current_peak_luminance_nits),
                clientDisplayPotentialPeakLuminanceNits: Int(snapshot.client_display_potential_peak_luminance_nits)
            )
        } else {
            videoConfiguration = nil
        }

        if snapshot.audio_requested {
            switch snapshot.audio_source_kind {
            case ApolloCoreAudioCaptureSourceKindSystemOutput:
                audioConfiguration = .systemOutput(
                    displayID: resolvedDisplayID,
                    sampleRate: Int(snapshot.audio_sample_rate),
                    channelCount: Int(snapshot.audio_channel_count),
                    frameSize: Int(snapshot.audio_frame_size),
                    excludesCurrentProcessAudio: snapshot.audio_excludes_current_process
                )
            case ApolloCoreAudioCaptureSourceKindMicrophone:
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

    private static func codec(from value: ApolloCoreCaptureCodec) -> ApolloCaptureCodec? {
        switch value {
        case ApolloCoreCaptureCodecH264:
            return .h264
        case ApolloCoreCaptureCodecHEVC:
            return .hevc
        case ApolloCoreCaptureCodecProResProxy:
            return .proResProxy
        default:
            return nil
        }
    }

    private static func preprocessStrategy(from value: ApolloCoreCapturePreprocessStrategy) -> ApolloCapturePreprocessStrategy {
        switch value {
        case ApolloCoreCapturePreprocessStrategyDownscale2x:
            return .downscale2x
        default:
            return .none
        }
    }

    private static func queueProfile(from value: ApolloCoreCaptureQueueProfile) -> ApolloCaptureQueueProfile {
        switch value {
        case ApolloCoreCaptureQueueProfileAuto:
            return .auto
        case ApolloCoreCaptureQueueProfileQ1:
            return .q1
        case ApolloCoreCaptureQueueProfileQ3:
            return .q3
        case ApolloCoreCaptureQueueProfileQ4:
            return .q4
        default:
            return .q2
        }
    }

    private static func clientDisplayGamut(from value: Int32) -> ApolloClientDisplayGamut {
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

    private static func clientDisplayTransfer(from value: Int32) -> ApolloClientDisplayTransfer {
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

public actor ApolloBridgeRuntime {
    public static let shared = ApolloBridgeRuntime()
    public nonisolated static let statusDidChangeNotification = Notification.Name("ApolloBridgeRuntimeStatusDidChange")
    private nonisolated static let statusNotificationCoalescingNanoseconds: UInt64 = 100_000_000
    private nonisolated static let encodedFrameDiagnosticsIntervalNanoseconds: UInt64 = 3_000_000_000
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
        for configuration: ApolloMacDisplayKitCaptureConfiguration
    ) -> Int {
        // MDK already applies source-side backpressure. The ApolloCore forwarder only needs
        // enough slack for cross-thread handoff; scaling this queue with frame rate just lets
        // stale encoded frames accumulate and shows up as host-side latency.
        let queueDepthReserve = max(configuration.queueProfile.queueDepthHint, 1)
        return min(max(queueDepthReserve + 2, 3), 8)
    }

    private let coreForwarder = ApolloCoreCaptureForwarder()
    private let audioForwarder = ApolloCoreAudioCaptureForwarder()
    private let logger = Logger(subsystem: "com.lizardbyte.apollo", category: "MacBridgeRuntime")
    private var encodedCaptureSession: MDKEncodedCaptureSession?
    private var encodedCaptureStartupTask: Task<Void, Error>?
    private var activeCaptureConfiguration: ApolloMacDisplayKitCaptureConfiguration?
    private var latestFrame: ApolloBridgeEncodedFrameSnapshot?
    private var recentEvents: [MDKEncodedCaptureSessionEvent] = []
    private var audioCaptureSession: MDKAudioCaptureSession?
    private var audioCaptureStartupTask: Task<Void, Error>?
    private var activeAudioCaptureConfiguration: ApolloMacDisplayKitAudioCaptureConfiguration?
    private var captureAutomationTask: Task<Void, Never>?
    private var mirroredCaptureRequestTask: Task<Void, Never>?
    private var lastStatusNotificationUptimeNanoseconds: UInt64 = 0
    private var hasPendingStatusNotification = false
    private var lastEncodedFrameDiagnosticsUptimeNanoseconds: UInt64 = 0
    private var lastEncodedFrameSourceSequenceNumber: UInt64?
    private var lastEncodedFrameSourceDisplayTime: UInt64?
    private var lastAppliedVideoRequestGeneration: UInt64?
    private var lastAppliedAudioRequestGeneration: UInt64?

    public init() {}

    public func preferredMacDisplayKitCaptureConfiguration(
        displayID: UInt32
    ) -> ApolloMacDisplayKitCaptureConfiguration {
        .panelNative(displayID: displayID)
    }

    public func startMacDisplayKitCapture(
        configuration: ApolloMacDisplayKitCaptureConfiguration
    ) async throws {
        try await startMacDisplayKitCapture(
            configuration: configuration,
            waitForStartupCompletion: true
        )
    }

    private func startMacDisplayKitCapture(
        configuration: ApolloMacDisplayKitCaptureConfiguration,
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
            "Starting MacDisplayKit capture \(configuration.hdrConfigurationDebugSummary, privacy: .public) queue=\(configuration.queueProfile.rawValue, privacy: .public) forwarding-frame-capacity=\(frameCapacity, privacy: .public)"
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

    public func makeDefaultMicrophoneAudioConfiguration() -> ApolloMacDisplayKitAudioCaptureConfiguration {
        .microphone()
    }

    public func makeSystemOutputAudioConfiguration(
        displayID: UInt32
    ) -> ApolloMacDisplayKitAudioCaptureConfiguration {
        .systemOutput(displayID: displayID)
    }

    public func startMacDisplayKitAudioCapture(
        configuration: ApolloMacDisplayKitAudioCaptureConfiguration
    ) async throws {
        try await startMacDisplayKitAudioCapture(
            configuration: configuration,
            waitForStartupCompletion: true
        )
    }

    private func startMacDisplayKitAudioCapture(
        configuration: ApolloMacDisplayKitAudioCaptureConfiguration,
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

    public func startApolloCoreCaptureAutomation() {
        guard captureAutomationTask == nil else {
            return
        }

        startMirroredApolloCoreCaptureRequestSync()
        captureAutomationTask = Task.detached(priority: .background) { [weak self] in
            var observedGeneration = UInt64.max
            while !Task.isCancelled {
                let changed = ApolloCoreCaptureRequestWaitForGenerationChange(observedGeneration, 250)
                if !changed && observedGeneration != UInt64.max {
                    continue
                }

                let snapshot = ApolloCoreCaptureRequestCopySnapshot()
                observedGeneration = snapshot.generation
                await self?.applyApolloCoreCaptureRequest(
                    ApolloBridgeAutomationRequest(snapshot: snapshot)
                )
            }
        }
        publishStatusDidChange(immediate: true)
    }

    public func stopApolloCoreCaptureAutomation() async {
        captureAutomationTask?.cancel()
        captureAutomationTask = nil
        mirroredCaptureRequestTask?.cancel()
        mirroredCaptureRequestTask = nil
        await stopMacDisplayKitAudioCapture()
        await stopMacDisplayKitCapture()
        publishStatusDidChange(immediate: true)
    }

    public func isApolloCoreCaptureAutomationRunning() -> Bool {
        captureAutomationTask != nil
    }

    public func captureSnapshot() async -> ApolloBridgeCaptureSnapshot? {
        guard let session = encodedCaptureSession,
              let configuration = activeCaptureConfiguration else {
            return nil
        }

        return ApolloBridgeCaptureSnapshot(
            configuration: configuration,
            statistics: await session.statisticsSnapshot(),
            latestFrame: latestFrame,
            recentEvents: recentEvents,
            coreForwarding: coreForwarder.snapshot()
        )
    }

    public func coreForwardingSnapshot() -> ApolloBridgeCoreForwardingSnapshot {
        coreForwarder.snapshot()
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

    public func drainNextCoreForwardedFrame() -> ApolloBridgeCoreDrainedFrame? {
        coreForwarder.popNextFrame()
    }

    public func drainNextCoreForwardedEvent() -> ApolloBridgeCoreDrainedEvent? {
        coreForwarder.popNextEvent()
    }

    public func audioForwardingSnapshot() -> ApolloBridgeAudioForwardingSnapshot {
        audioForwarder.snapshot()
    }

    public func drainNextCoreForwardedAudioFrame() -> ApolloBridgeDrainedAudioFrame? {
        audioForwarder.popNextFrame()
    }

    public func drainNextCoreForwardedAudioEvent() -> ApolloBridgeDrainedAudioEvent? {
        audioForwarder.popNextEvent()
    }

    public func statusSnapshot() -> ApolloBridgeStatus {
        ApolloBridgeStatus(
            coreVersion: String(cString: ApolloCoreBootstrapVersionString()),
            runtimeDescription: String(cString: ApolloCoreBootstrapRuntimeDescription()),
            integrationStatus: "MacDisplayKit owns macOS capture and encode. ApolloMacBridge forwards encoded video and PCM audio into ApolloCore ingress surfaces while Apollo keeps the web, session, and transport stack.",
            captureSessionRunning: encodedCaptureSession != nil,
            audioCaptureSessionRunning: audioCaptureSession != nil,
            automaticCaptureOrchestrationRunning: captureAutomationTask != nil
        )
    }

    private func applyApolloCoreCaptureRequest(_ request: ApolloBridgeAutomationRequest) async {
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
                    "Applying ApolloCore macOS bridge capture request display-id=\(configuration.displayID, privacy: .public) codec=\(configuration.codec.rawValue, privacy: .public) queue=\(configuration.queueProfile.rawValue, privacy: .public) fps=\(configuration.targetFrameRate, privacy: .public) forwarding-frame-capacity=\(frameCapacity, privacy: .public)"
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
                    "Stopping MacDisplayKit capture because ApolloCore video request resolved to nil video-generation=\(request.videoGeneration, privacy: .public) last-applied-video-generation=\(self.lastAppliedVideoRequestGeneration ?? 0, privacy: .public) session-active=\(self.encodedCaptureSession != nil, privacy: .public) active-configuration=\(activeConfigurationSummary, privacy: .public)"
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
                    "Stopping MacDisplayKit audio capture because ApolloCore audio request resolved to nil audio-generation=\(request.audioGeneration, privacy: .public) last-applied-audio-generation=\(self.lastAppliedAudioRequestGeneration ?? 0, privacy: .public) session-active=\(self.audioCaptureSession != nil, privacy: .public) active-configuration=\(activeAudioConfigurationSummary, privacy: .public)"
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

    private func startMirroredApolloCoreCaptureRequestSync() {
        guard mirroredCaptureRequestTask == nil else {
            return
        }

        mirroredCaptureRequestTask = Task.detached(priority: .background) {
            let coordinator = ApolloCaptureRequestMirrorCoordinator()
            await coordinator.syncCurrentState()

            let notificationCenter = DistributedNotificationCenter.default()
            let notifications = notificationCenter.notifications(
                named: ApolloBridgeMirroredCaptureRequestSnapshot.changedNotification
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
        latestFrame = ApolloBridgeEncodedFrameSnapshot(frame: frame)
        let captureStatistics = await encodedCaptureSession?.statisticsSnapshot()
        logEncodedFrameDiagnosticsIfNeeded(frame, captureStatistics: captureStatistics)
        publishStatusDidChange()
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
            (sequenceDelta != nil && sequenceDelta != 1) ||
            (displayTimeDelta != nil && displayTimeDelta == 0)
        let shouldLogInterval =
            lastEncodedFrameDiagnosticsUptimeNanoseconds == 0 ||
            now - lastEncodedFrameDiagnosticsUptimeNanoseconds >= Self.encodedFrameDiagnosticsIntervalNanoseconds

        if shouldLogAnomaly || shouldLogInterval {
            let targetWidth = activeCaptureConfiguration?.requestedWidth ?? 0
            let targetHeight = activeCaptureConfiguration?.requestedHeight ?? 0
            let targetFrameRate = activeCaptureConfiguration?.targetFrameRate ?? 0
            let queueProfile = activeCaptureConfiguration?.queueProfile.rawValue ?? "unknown"
            let displayID = activeCaptureConfiguration?.displayID ?? 0
            let codec = ApolloCaptureCodec(frame.codec).rawValue
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
            "skyLightAutotuningSource=",
            "skyLightCandidateResult=",
            "skyLightTuningCandidate=",
            "skyLightTuningQueueDepth=",
            "skyLightTuningMinimumFrameTime=",
            "skyLightTuningEffectiveOutputFrameRate=",
            "skyLightTuningCadence=",
            "skyLightDisplayRefreshRate=",
            "skyLightPendingPolicy=",
            "skyLightRecommendedPendingFrameCount=",
            "sourceFrameCount=",
            "sourceDisplayDeltaCount=",
            "sourceLastDisplayDeltaMilliseconds=",
            "sourceMinDisplayDeltaMilliseconds=",
            "sourceMaxDisplayDeltaMilliseconds=",
            "sourceAverageDisplayDeltaMilliseconds=",
            "sourceApproxFrameRate=",
            "sourceCadenceClassification=",
            "videoToolboxUsingHardwareEncoder=",
            "videoToolboxRecommendedParallelizationLimit=",
            "videoToolboxPixelBufferPoolIsShared=",
            "videoToolboxStagingMode=",
            "videoToolboxStagedSourceReleaseMode=",
            "videoToolboxEncoderInputStrategy=",
            "videoToolboxEncoderInputPixelFormat=",
            "videoToolboxColorConversionMode=",
            "videoToolboxTargetFrameRateHint=",
            "videoToolboxConfiguredAverageBitRate=",
            "videoToolboxConfiguredDataRateLimits=",
            "videoToolboxConfiguredProfileLevel=",
            "videoToolboxDirectSubmissionFrameCount=",
            "videoToolboxStagedSubmissionFrameCount=",
            "videoToolboxMaxInflightStagingSlots=",
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
        codec: ApolloCaptureCodec = .hevc,
        sourceSequenceNumber: UInt64 = 1,
        sourceDisplayTime: UInt64 = 1,
        outputCallbackLatencyMilliseconds: Double? = nil,
        isKeyFrame: Bool = true,
        isHDRSignaled: Bool = false
    ) {
        coreForwarder.consume(
            sampleBuffer: sampleBuffer,
            codec: codec,
            sourceSequenceNumber: sourceSequenceNumber,
            sourceDisplayTime: sourceDisplayTime,
            outputCallbackLatencyMilliseconds: outputCallbackLatencyMilliseconds,
            isKeyFrame: isKeyFrame,
            isHDRSignaled: isHDRSignaled
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

    func debugDrainNextForwardedFrame() -> ApolloBridgeCoreDrainedFrame? {
        drainNextCoreForwardedFrame()
    }

    func debugDrainNextForwardedEvent() -> ApolloBridgeCoreDrainedEvent? {
        drainNextCoreForwardedEvent()
    }

}

private extension ApolloCaptureCodec {
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

private extension ApolloBridgeCaptureEventKind {
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
