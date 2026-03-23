import ApolloCore
import CoreGraphics
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
        case "q1":
            return .q1
        case "q2":
            return .q2
        case "q4":
            return .q4
        default:
            return .q3
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
    public let showCursor: Bool
    public let targetFrameRate: Int
    public let requestedWidth: Int?
    public let requestedHeight: Int?
    public let enableHDR: Bool

    public init(
        displayID: UInt32,
        codec: ApolloCaptureCodec = .hevc,
        preprocessStrategy: ApolloCapturePreprocessStrategy = .none,
        queueProfile: ApolloCaptureQueueProfile = .q3,
        showCursor: Bool = false,
        targetFrameRate: Int = 120,
        requestedWidth: Int? = nil,
        requestedHeight: Int? = nil,
        enableHDR: Bool = false
    ) {
        self.displayID = displayID
        self.codec = codec
        self.preprocessStrategy = preprocessStrategy
        self.queueProfile = queueProfile
        self.showCursor = showCursor
        self.targetFrameRate = max(targetFrameRate, 1)
        self.requestedWidth = Self.sanitizedDimension(requestedWidth)
        self.requestedHeight = Self.sanitizedDimension(requestedHeight)
        self.enableHDR = enableHDR
    }

    public static func panelNative(displayID: UInt32) -> Self {
        Self(
            displayID: displayID,
            codec: ApolloBridgeConfigurationPreferences.preferredCodec(),
            queueProfile: ApolloBridgeConfigurationPreferences.preferredQueueProfile()
        )
    }

    var mdkValue: MDKEncodedCaptureConfiguration {
        let streamConfiguration = MDKSkyLightDisplayStreamConfiguration(
            queueDepth: queueProfile.mdkValue.queueDepth,
            queueProfile: queueProfile.mdkValue,
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
            hdrConfiguration: hdrConfiguration
        )
    }

    private var hdrConfiguration: MDKVideoHDRConfiguration? {
        guard enableHDR, codec != .h264 else {
            return nil
        }
        return .hdr10()
    }

    private static func sanitizedDimension(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }
        return value
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
    let videoConfiguration: ApolloMacDisplayKitCaptureConfiguration?
    let audioConfiguration: ApolloMacDisplayKitAudioCaptureConfiguration?

    init(snapshot: ApolloCoreCaptureRequestSnapshot) {
        generation = snapshot.generation

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
                enableHDR: snapshot.dynamic_range > 0
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
}

public actor ApolloBridgeRuntime {
    public static let shared = ApolloBridgeRuntime()
    public nonisolated static let statusDidChangeNotification = Notification.Name("ApolloBridgeRuntimeStatusDidChange")
    private nonisolated static let statusNotificationCoalescingNanoseconds: UInt64 = 100_000_000
    private nonisolated static func postStatusDidChangeNotificationAsync() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
        }
    }

    private let coreForwarder = ApolloCoreCaptureForwarder()
    private let audioForwarder = ApolloCoreAudioCaptureForwarder()
    private var encodedCaptureSession: MDKEncodedCaptureSession?
    private var activeCaptureConfiguration: ApolloMacDisplayKitCaptureConfiguration?
    private var latestFrame: ApolloBridgeEncodedFrameSnapshot?
    private var recentEvents: [MDKEncodedCaptureSessionEvent] = []
    private var audioCaptureSession: MDKAudioCaptureSession?
    private var activeAudioCaptureConfiguration: ApolloMacDisplayKitAudioCaptureConfiguration?
    private var captureAutomationTask: Task<Void, Never>?
    private var mirroredCaptureRequestTask: Task<Void, Never>?
    private var lastStatusNotificationUptimeNanoseconds: UInt64 = 0
    private var hasPendingStatusNotification = false

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
        coreForwarder.setProducerActive(false)
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
        coreForwarder.setProducerActive(true)
        encodedCaptureSession = session
        activeCaptureConfiguration = configuration
        publishStatusDidChange(immediate: true)
    }

    public func stopMacDisplayKitCapture() async {
        guard let session = encodedCaptureSession else {
            encodedCaptureSession = nil
            activeCaptureConfiguration = nil
            coreForwarder.setProducerActive(false)
            latestFrame = nil
            recentEvents = []
            return
        }

        await session.stop()
        coreForwarder.setProducerActive(false)
        encodedCaptureSession = nil
        activeCaptureConfiguration = nil
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
        await stopMacDisplayKitAudioCapture()

        audioForwarder.reset()
        audioForwarder.setProducerActive(false)
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
        audioForwarder.setProducerActive(true)
        audioCaptureSession = session
        activeAudioCaptureConfiguration = configuration
        publishStatusDidChange(immediate: true)
    }

    public func stopMacDisplayKitAudioCapture() async {
        guard let session = audioCaptureSession else {
            audioCaptureSession = nil
            activeAudioCaptureConfiguration = nil
            audioForwarder.reset()
            audioForwarder.setProducerActive(false)
            return
        }

        await session.stop()
        audioForwarder.setProducerActive(false)
        audioCaptureSession = nil
        activeAudioCaptureConfiguration = nil
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
        if request.videoConfiguration != activeCaptureConfiguration || (request.videoConfiguration == nil) != (encodedCaptureSession == nil) {
            if let configuration = request.videoConfiguration {
                try? await startMacDisplayKitCapture(configuration: configuration)
            } else {
                await stopMacDisplayKitCapture()
            }
        }

        if request.audioConfiguration != activeAudioCaptureConfiguration || (request.audioConfiguration == nil) != (audioCaptureSession == nil) {
            if let configuration = request.audioConfiguration {
                try? await startMacDisplayKitAudioCapture(configuration: configuration)
            } else {
                await stopMacDisplayKitAudioCapture()
            }
        }
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

    private func recordEncodedFrame(_ frame: MDKEncodedFrame) {
        latestFrame = ApolloBridgeEncodedFrameSnapshot(frame: frame)
        publishStatusDidChange()
    }

    private func recordEncodedCaptureEvent(_ event: MDKEncodedCaptureSessionEvent) {
        recentEvents.append(event)
        if recentEvents.count > 16 {
            recentEvents.removeFirst(recentEvents.count - 16)
        }
        publishStatusDidChange()
    }

    private func recordAudioFrame(_ frame: MDKAudioFrame) {
        audioForwarder.consume(frame: frame)
        publishStatusDidChange()
    }

    private func recordAudioCaptureEvent(_ event: MDKAudioCaptureSessionEvent) {
        audioForwarder.consume(event: event)
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
