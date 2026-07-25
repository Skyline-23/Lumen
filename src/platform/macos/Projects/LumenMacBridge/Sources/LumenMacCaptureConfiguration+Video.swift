import CoreVideo
import Foundation

extension LumenMacCaptureConfiguration {
    public static func panelNative(displayID: UInt32) -> Self {
        let environment = ProcessInfo.processInfo.environment
        let transport = LumenClientSinkTransfer(
            environmentValue: environment["SHADOW_CLIENT_SINK_TRANSFER"]
        )
        return Self(
            displayID: displayID,
            codec: .hevc,
            queueProfile: .auto,
            encoderInputStrategy:
                LumenBridgeConfigurationPreferences
                    .preferredEncoderInputStrategy(),
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: LumenClientSinkGamut(
                        environmentValue:
                            environment["SHADOW_CLIENT_SINK_GAMUT"]
                    ),
                    transfer: LumenClientSinkTransfer(
                        environmentValue:
                            environment["SHADOW_CLIENT_SINK_TRANSFER"]
                    ),
                    supportsFrameGatedHDR: true,
                    supportsHDRTileOverlay: false,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport:
                    transport == .pq || transport == .hlg
                        ? LumenMacDynamicRangeTransportFrameGatedHDR
                        : LumenMacDynamicRangeTransportSDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: LumenClientSinkGamut(
                    environmentValue: environment["SHADOW_CLIENT_SINK_GAMUT"]
                ),
                transfer: LumenClientSinkTransfer(
                    environmentValue:
                        environment["SHADOW_CLIENT_SINK_TRANSFER"]
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

        if usesHDRTransport ||
            negotiatedDynamicRangeTransport ==
                LumenMacDynamicRangeTransportSDRBaseHDROverlay {
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
            return usesHDRTransport
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
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

    var usesHighResolutionWorkload: Bool {
        guard let effectivePixelCount else {
            return false
        }
        return effectivePixelCount >= Self.highResolutionPixelCountThreshold
    }

    var usesVeryHighResolutionWorkload: Bool {
        guard let effectivePixelCount else {
            return false
        }
        return effectivePixelCount >=
            Self.veryHighResolutionPixelCountThreshold
    }

    private var effectivePixelCount: Int? {
        guard let width = requestedWidth, let height = requestedHeight else {
            return nil
        }
        return width * height
    }
}
