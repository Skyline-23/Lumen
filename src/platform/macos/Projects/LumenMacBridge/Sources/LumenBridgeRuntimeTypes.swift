import Foundation
import LumenEngineBridge

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
    // These public cases are ABI and source compatibility surface.
    // swiftlint:disable identifier_name
    case q1
    case q2
    case q3
    case q4
    // swiftlint:enable identifier_name

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
    // This public case is ABI and source compatibility surface.
    // swiftlint:disable:next identifier_name
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

func lumenDynamicRangeTransportName(_ transport: LumenMacDynamicRangeTransport) -> String {
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

func lumenDynamicRangeTransportUsesHDR(_ transport: LumenMacDynamicRangeTransport) -> Bool {
    switch transport {
    case LumenMacDynamicRangeTransportFullFrameHDR, LumenMacDynamicRangeTransportFrameGatedHDR:
        return true
    default:
        return false
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
        frameSize: Int = 240,
        excludesCurrentProcessAudio: Bool = true
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

struct LumenCaptureLatencyDiagnostics {
    let callbackLatency: String
    let lastError: String
    let minimumLatency: String
    let maximumLatency: String
    let details: String
}
