import ApolloCore
import CoreMedia
import Foundation
import MacDisplayCaptureKit

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
    public let integrationStatus: String

    public init(
        coreVersion: String,
        runtimeDescription: String,
        integrationStatus: String
    ) {
        self.coreVersion = coreVersion
        self.runtimeDescription = runtimeDescription
        self.integrationStatus = integrationStatus
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

private struct ApolloAudioForwardingState: Sendable {
    private(set) var frameCount: UInt64 = 0
    private(set) var eventCount: UInt64 = 0
    private(set) var droppedFrameCount: UInt64 = 0
    private(set) var droppedEventCount: UInt64 = 0
    private var frameCapacity: Int = 8
    private var eventCapacity: Int = 32
    private var lastFrame: ApolloBridgeDrainedAudioFrame?
    private var lastEvent: ApolloBridgeDrainedAudioEvent?
    private var pendingFrames: [ApolloBridgeDrainedAudioFrame] = []
    private var pendingEvents: [ApolloBridgeDrainedAudioEvent] = []

    mutating func reset() {
        frameCount = 0
        eventCount = 0
        droppedFrameCount = 0
        droppedEventCount = 0
        lastFrame = nil
        lastEvent = nil
        pendingFrames.removeAll(keepingCapacity: false)
        pendingEvents.removeAll(keepingCapacity: false)
    }

    mutating func setFrameCapacity(_ capacity: Int) {
        frameCapacity = max(capacity, 1)
        while pendingFrames.count > frameCapacity {
            pendingFrames.removeFirst()
            droppedFrameCount += 1
        }
    }

    mutating func setEventCapacity(_ capacity: Int) {
        eventCapacity = max(capacity, 1)
        while pendingEvents.count > eventCapacity {
            pendingEvents.removeFirst()
            droppedEventCount += 1
        }
    }

    mutating func consume(frame: MDKAudioFrame) {
        let drainedFrame = ApolloBridgeDrainedAudioFrame(
            sequenceNumber: frame.sequenceNumber,
            hostTimeNanoseconds: frame.hostTimeNanoseconds,
            sampleRate: frame.sampleRate,
            channelCount: frame.channelCount,
            frameCount: frame.frameCount,
            pcmFloat32LE: frame.pcmFloat32LE
        )

        frameCount += 1
        lastFrame = drainedFrame
        pendingFrames.append(drainedFrame)
        while pendingFrames.count > frameCapacity {
            pendingFrames.removeFirst()
            droppedFrameCount += 1
        }
    }

    mutating func consume(event: MDKAudioCaptureSessionEvent) {
        let drainedEvent = ApolloBridgeDrainedAudioEvent(
            kind: ApolloBridgeCaptureEventKind(event.kind),
            message: event.message,
            stopStatus: event.stopStatus,
            automaticRestartCount: event.automaticRestartCount,
            sourceSequenceNumber: event.sourceSequenceNumber
        )

        eventCount += 1
        lastEvent = drainedEvent
        pendingEvents.append(drainedEvent)
        while pendingEvents.count > eventCapacity {
            pendingEvents.removeFirst()
            droppedEventCount += 1
        }
    }

    mutating func popNextFrame() -> ApolloBridgeDrainedAudioFrame? {
        guard !pendingFrames.isEmpty else {
            return nil
        }
        return pendingFrames.removeFirst()
    }

    mutating func popNextEvent() -> ApolloBridgeDrainedAudioEvent? {
        guard !pendingEvents.isEmpty else {
            return nil
        }
        return pendingEvents.removeFirst()
    }

    func snapshot() -> ApolloBridgeAudioForwardingSnapshot {
        ApolloBridgeAudioForwardingSnapshot(
            frameCount: frameCount,
            eventCount: eventCount,
            queuedFrameCount: UInt64(pendingFrames.count),
            queuedEventCount: UInt64(pendingEvents.count),
            droppedFrameCount: droppedFrameCount,
            droppedEventCount: droppedEventCount,
            lastFrameSequenceNumber: lastFrame?.sequenceNumber,
            lastFrameHostTimeNanoseconds: lastFrame?.hostTimeNanoseconds,
            lastFrameSampleRate: lastFrame?.sampleRate,
            lastFrameChannelCount: lastFrame?.channelCount,
            lastFrameFrameCount: lastFrame?.frameCount,
            lastFramePCMByteCount: lastFrame?.pcmFloat32LE.count ?? 0,
            lastEventKind: lastEvent?.kind
        )
    }
}

public actor ApolloBridgeRuntime {
    public static let shared = ApolloBridgeRuntime()

    private let coreForwarder = ApolloCoreCaptureForwarder()
    private var encodedCaptureSession: MDKEncodedCaptureSession?
    private var activeCaptureConfiguration: ApolloMacDisplayKitCaptureConfiguration?
    private var latestFrame: ApolloBridgeEncodedFrameSnapshot?
    private var recentEvents: [MDKEncodedCaptureSessionEvent] = []
    private var audioCaptureSession: MDKAudioCaptureSession?
    private var activeAudioCaptureConfiguration: ApolloMacDisplayKitAudioCaptureConfiguration?
    private var audioForwarding = ApolloAudioForwardingState()

    public init() {}

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
        await stopMacDisplayKitAudioCapture()

        audioForwarding.reset()
        let runtime = self
        let session = MDKAudioCaptureSession(configuration: configuration.mdkValue)
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

        try await session.start(callbacks: callbacks)
        audioCaptureSession = session
        activeAudioCaptureConfiguration = configuration
    }

    public func stopMacDisplayKitAudioCapture() async {
        guard let session = audioCaptureSession else {
            audioCaptureSession = nil
            activeAudioCaptureConfiguration = nil
            audioForwarding.reset()
            return
        }

        await session.stop()
        audioCaptureSession = nil
        activeAudioCaptureConfiguration = nil
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
        audioForwarding.setFrameCapacity(frameCapacity)
        audioForwarding.setEventCapacity(eventCapacity)
    }

    public func drainNextCoreForwardedFrame() -> ApolloBridgeCoreDrainedFrame? {
        coreForwarder.popNextFrame()
    }

    public func drainNextCoreForwardedEvent() -> ApolloBridgeCoreDrainedEvent? {
        coreForwarder.popNextEvent()
    }

    public func audioForwardingSnapshot() -> ApolloBridgeAudioForwardingSnapshot {
        audioForwarding.snapshot()
    }

    public func drainNextCoreForwardedAudioFrame() -> ApolloBridgeDrainedAudioFrame? {
        audioForwarding.popNextFrame()
    }

    public func drainNextCoreForwardedAudioEvent() -> ApolloBridgeDrainedAudioEvent? {
        audioForwarding.popNextEvent()
    }

    public func statusSnapshot() -> ApolloBridgeStatus {
        ApolloBridgeStatus(
            coreVersion: String(cString: ApolloCoreBootstrapVersionString()),
            runtimeDescription: String(cString: ApolloCoreBootstrapRuntimeDescription()),
            integrationStatus: "Swift shell, C/C++ core, and bridge targets are ready. ApolloMacBridge now links MacDisplayCaptureKit, owns callback-only encoded video and audio capture sessions, forwards encoded video sample buffers into ApolloCore's ingress surface, and exposes raw PCM audio through the bridge C ABI."
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

    private func recordAudioFrame(_ frame: MDKAudioFrame) {
        audioForwarding.consume(frame: frame)
    }

    private func recordAudioCaptureEvent(_ event: MDKAudioCaptureSessionEvent) {
        audioForwarding.consume(event: event)
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
