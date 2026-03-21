import ApolloCore
import Foundation
import MacDisplayCaptureKit

public enum ApolloCaptureBackend: String, CaseIterable, Codable, Sendable {
    case legacyApollo = "legacy-apollo"
    case macDisplayKit = "mac-display-kit"
}

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
    case q1
    case q2
    case q3
    case q4

    var mdkValue: MDKSkyLightDisplayStreamQueueProfile {
        switch self {
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
}

public struct ApolloMacDisplayKitCaptureConfiguration: Equatable, Sendable {
    public let displayID: UInt32
    public let codec: ApolloCaptureCodec
    public let preprocessStrategy: ApolloCapturePreprocessStrategy
    public let queueProfile: ApolloCaptureQueueProfile
    public let showCursor: Bool
    public let targetFrameRate: Int

    public init(
        displayID: UInt32,
        codec: ApolloCaptureCodec = .hevc,
        preprocessStrategy: ApolloCapturePreprocessStrategy = .none,
        queueProfile: ApolloCaptureQueueProfile = .q2,
        showCursor: Bool = false,
        targetFrameRate: Int = 120
    ) {
        self.displayID = displayID
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.queueProfile = queueProfile
        self.showCursor = showCursor
        self.targetFrameRate = max(targetFrameRate, 1)
    }

    public static func panelNative(displayID: UInt32) -> Self {
        Self(displayID: displayID)
    }

    var mdkValue: MDKEncodedCaptureConfiguration {
        .panelNative(
            displayID: displayID,
            queueProfile: queueProfile.mdkValue,
            showCursor: showCursor,
            codec: codec.mdkValue,
            preprocessStrategy: preprocessStrategy.mdkValue,
            targetFrameRate: targetFrameRate,
            deliveryMode: .callbackOnly
        )
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
    public let preferredCaptureBackend: ApolloCaptureBackend
    public let integrationStatus: String

    public init(
        coreVersion: String,
        runtimeDescription: String,
        preferredCaptureBackend: ApolloCaptureBackend,
        integrationStatus: String
    ) {
        self.coreVersion = coreVersion
        self.runtimeDescription = runtimeDescription
        self.preferredCaptureBackend = preferredCaptureBackend
        self.integrationStatus = integrationStatus
    }
}

public actor ApolloBridgeRuntime {
    public static let shared = ApolloBridgeRuntime()

    private var preferredCaptureBackend: ApolloCaptureBackend = .macDisplayKit
    private let coreForwarder = ApolloCoreCaptureForwarder()
    private var encodedCaptureSession: MDKEncodedCaptureSession?
    private var activeCaptureConfiguration: ApolloMacDisplayKitCaptureConfiguration?
    private var latestFrame: ApolloBridgeEncodedFrameSnapshot?
    private var recentEvents: [MDKEncodedCaptureSessionEvent] = []

    public init() {}

    public func setPreferredCaptureBackend(_ backend: ApolloCaptureBackend) {
        preferredCaptureBackend = backend
    }

    public func preferredMacDisplayKitCaptureConfiguration(
        displayID: UInt32
    ) -> ApolloMacDisplayKitCaptureConfiguration {
        .panelNative(displayID: displayID)
    }

    public func startMacDisplayKitCapture(
        configuration: ApolloMacDisplayKitCaptureConfiguration
    ) async throws {
        await stopMacDisplayKitCapture()

        coreForwarder.reset()
        latestFrame = nil
        recentEvents = []

        let session = MDKEncodedCaptureSession(configuration: configuration.mdkValue)
        let runtime = self
        let coreForwarder = self.coreForwarder
        let callbacks = MDKEncodedCaptureCallbacks(
            frameHandler: { frame in
                do {
                    try coreForwarder.consume(frame: frame)
                } catch {
                    coreForwarder.consume(
                        event: MDKEncodedCaptureSessionEvent(
                            kind: .failed,
                            message: "ApolloMacBridge failed to extract a contiguous encoded payload: \(error.localizedDescription)"
                        )
                    )
                }
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

        try await session.start(callbacks: callbacks)
        encodedCaptureSession = session
        activeCaptureConfiguration = configuration
    }

    public func stopMacDisplayKitCapture() async {
        guard let session = encodedCaptureSession else {
            encodedCaptureSession = nil
            activeCaptureConfiguration = nil
            latestFrame = nil
            recentEvents = []
            return
        }

        await session.stop()
        encodedCaptureSession = nil
        activeCaptureConfiguration = nil
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

    public func statusSnapshot() -> ApolloBridgeStatus {
        ApolloBridgeStatus(
            coreVersion: String(cString: ApolloCoreBootstrapVersionString()),
            runtimeDescription: String(cString: ApolloCoreBootstrapRuntimeDescription()),
            preferredCaptureBackend: preferredCaptureBackend,
            integrationStatus: "Swift shell, C/C++ core, and bridge targets are ready. ApolloMacBridge now links MacDisplayCaptureKit, owns callback-only encoded capture sessions, and forwards encoded payloads into ApolloCore's C ABI consumer surface."
        )
    }

    private func recordEncodedFrame(_ frame: MDKEncodedFrame) {
        latestFrame = ApolloBridgeEncodedFrameSnapshot(frame: frame)
    }

    private func recordEncodedCaptureEvent(_ event: MDKEncodedCaptureSessionEvent) {
        recentEvents.append(event)
        if recentEvents.count > 16 {
            recentEvents.removeFirst(recentEvents.count - 16)
        }
    }

    func debugResetCoreForwarding() {
        coreForwarder.reset()
    }

    func debugForwardSyntheticFrame(
        payload: Data,
        codec: ApolloCaptureCodec = .hevc,
        sourceSequenceNumber: UInt64 = 1,
        sourceDisplayTime: UInt64 = 1,
        outputCallbackLatencyMilliseconds: Double? = nil,
        isKeyFrame: Bool = true,
        isHDRSignaled: Bool = false
    ) {
        coreForwarder.consume(
            codec: codec,
            payload: payload,
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

    func debugLastForwardedPayload() -> Data {
        coreForwarder.copyLastFramePayload()
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
