import LumenEngineBridge

public struct LumenMacCaptureConfiguration: Equatable, Sendable {
    static let supportsPartialHDROverlayProducer = true
    static let highResolutionPixelCountThreshold = 5_000_000
    static let veryHighResolutionPixelCountThreshold = 7_000_000

    public let displayID: UInt32
    public let sessionEpoch: UInt32
    public let policyRevision: UInt32
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
        sessionEpoch: UInt32 = 0,
        policyRevision: UInt32 = 0,
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
        effectiveDisplayState: LumenBridgeEffectiveDisplayState =
            LumenBridgeEffectiveDisplayState()
    ) {
        let defaultsToHDR = codec == .hevc &&
            lumenDynamicRangeTransportUsesHDR(
                sinkRequest.dynamicRangeTransport
            )
        self.displayID = displayID
        self.sessionEpoch = sessionEpoch
        self.policyRevision = policyRevision
        self.codec = codec
        self.videoProfile = videoProfile ?? (
            codec == .h264
                ? .h264High
                : (defaultsToHDR ? .hevcMain10 : .hevcMain)
        )
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
            sessionEpoch: sessionEpoch,
            policyRevision: policyRevision,
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
}

extension LumenMacCaptureConfiguration {
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
            return codec == .h264
                ? LumenMacDynamicRangeTransportSDR
                : LumenMacDynamicRangeTransportFullFrameHDR
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
        case LumenMacDynamicRangeTransportSDR,
             LumenMacDynamicRangeTransportUnknown:
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

        if negotiatedDynamicRangeTransport ==
            LumenMacDynamicRangeTransportSDRBaseHDROverlay {
            return usesHighResolutionWorkload
                ? .q2
                : .q4
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
            requestedTransport: protocolRequestedRange,
            negotiatedTransport: protocolNegotiatedRange,
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

    private var protocolRequestedRange: LumenProtocolDynamicRangeTransport {
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

    private var protocolNegotiatedRange: LumenProtocolDynamicRangeTransport {
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
            supportsHDRTileOverlay:
                sinkRequest.capability.supportsHDRTileOverlay,
            supportsPerFrameHDRMetadata:
                sinkRequest.capability.supportsPerFrameHDRMetadata
        )
    }

    struct EncodedHDRConfigurationSnapshot: Equatable, Sendable {
        let signalColorPrimaries: String
        let transferFunction: String
        let signalYCbCrMatrix: String
        let staticMetadataSource: String
    }
}
