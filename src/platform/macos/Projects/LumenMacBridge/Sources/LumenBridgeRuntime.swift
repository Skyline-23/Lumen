import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import LumenEngineBridge
import OSLog

private enum LumenMacBridgeCompositionRoot {
    static func makeRuntime() -> LumenBridgeRuntime {
        LumenBridgeRuntime(
            systemAudioPlaybackSuppression:
                makeSystemAudioCaptureSource(),
            encodedCaptureRuntimeFactory:
                LumenProductionCaptureRuntimeFactory()
        )
    }

    static func makeSystemAudioCaptureSource()
        -> LumenSystemAudioPlaybackSuppression {
        LumenSystemAudioPlaybackSuppression(
            hal: LumenCoreAudioSystemAudioPlaybackSuppressionHAL()
        )
    }
}

public actor LumenBridgeRuntime {
    public static let shared =
        LumenMacBridgeCompositionRoot.makeRuntime()
    public nonisolated static let statusDidChangeNotification = Notification.Name("LumenBridgeRuntimeStatusDidChange")
    nonisolated static let statusNotificationCoalescingNanoseconds: UInt64 = 100_000_000
    nonisolated static let diagnosticsIntervalNanoseconds: UInt64 = 3_000_000_000
    nonisolated static let captureRestartCooldownNanoseconds: UInt64 = 2_000_000_000
    nonisolated static let automaticVideoForwardingEventCapacity = 64
    nonisolated static func postStatusDidChangeNotificationAsync() {
        Task { @MainActor in
            NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
        }
    }

    nonisolated static func displayTimeDeltaMilliseconds(_ delta: UInt64) -> Double {
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

    public func preferredCaptureConfiguration(
        displayID: UInt32
    ) -> LumenMacCaptureConfiguration {
        preferredCaptureConfigurationImpl(displayID: displayID)
    }

    public func startCapture(
        configuration: LumenMacCaptureConfiguration
    ) async throws {
        try await startCaptureImpl(configuration: configuration)
    }

    public func startCapture(
        configuration: LumenMacCaptureConfiguration,
        preconfiguredSystemAudio: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startCaptureImpl(
            configuration: configuration,
            preconfiguredSystemAudio: preconfiguredSystemAudio
        )
    }

    public func stopCapture() async {
        await stopCaptureImpl()
    }

    public func restartCapture(reason: String) async {
        await restartCaptureImpl(reason: reason)
    }

    public func waitForFirstEncodedFrame(
        timeoutNanoseconds: UInt64
    ) async throws {
        try await waitForFirstEncodedFrameImpl(
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public func currentEncodedFrameSequenceNumber() -> UInt64? {
        currentEncodedFrameSequenceNumberImpl()
    }

    public func waitForEncodedFrame(
        after sequenceNumber: UInt64,
        timeoutNanoseconds: UInt64
    ) async throws {
        try await waitForEncodedFrameImpl(
            after: sequenceNumber,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public func verifyEncodedFrameContinuity(
        timeoutNanoseconds: UInt64
    ) async throws {
        try await verifyEncodedFrameContinuityImpl(
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public func requestImmediateCaptureKeyFrame() async {
        await requestImmediateCaptureKeyFrameImpl()
    }

    public func resumeVideoEncodingAfterCodecAck() async -> Bool {
        await resumeVideoEncodingAfterCodecAckImpl()
    }

    public func makeDefaultMicrophoneAudioConfiguration()
        -> LumenMacAudioCaptureConfiguration {
        makeDefaultMicrophoneAudioConfigurationImpl()
    }

    public func makeSystemOutputAudioConfiguration(
        displayID: UInt32
    ) -> LumenMacAudioCaptureConfiguration {
        makeSystemOutputAudioConfigurationImpl(displayID: displayID)
    }

    public func startAudioCapture(
        configuration: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startAudioCaptureImpl(configuration: configuration)
    }

    public func startAudioCaptureAsynchronously(
        configuration: LumenMacAudioCaptureConfiguration
    ) async throws {
        try await startAudioCaptureAsynchronouslyImpl(
            configuration: configuration
        )
    }

    public func stopAudioCapture() async {
        await stopAudioCaptureImpl()
    }

    public func captureSnapshot() async -> LumenBridgeCaptureSnapshot? {
        await captureSnapshotImpl()
    }

    public func videoForwardingSnapshot() -> LumenBridgeVideoForwardingSnapshot {
        videoForwardingSnapshotImpl()
    }

    public func captureDiagnosticsString() async -> String {
        await captureDiagnosticsStringImpl()
    }

    public func configureVideoForwarding(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        configureVideoForwardingImpl(
            frameCapacity: frameCapacity,
            eventCapacity: eventCapacity
        )
    }

    public func configureAudioForwarding(
        frameCapacity: Int,
        eventCapacity: Int
    ) {
        configureAudioForwardingImpl(
            frameCapacity: frameCapacity,
            eventCapacity: eventCapacity
        )
    }

    public func drainNextVideoForwardedFrame() -> LumenBridgeDrainedVideoFrame? {
        drainNextVideoForwardedFrameImpl()
    }

    public func drainNextVideoForwardedEvent() -> LumenBridgeDrainedVideoEvent? {
        drainNextVideoForwardedEventImpl()
    }

    public func audioForwardingSnapshot() -> LumenBridgeAudioForwardingSnapshot {
        audioForwardingSnapshotImpl()
    }

    public func drainNextVideoForwardedAudioFrame()
        -> LumenBridgeDrainedAudioFrame? {
        drainNextVideoForwardedAudioFrameImpl()
    }

    public func drainNextVideoForwardedAudioEvent()
        -> LumenBridgeDrainedAudioEvent? {
        drainNextVideoForwardedAudioEventImpl()
    }

    public func statusSnapshot() -> LumenBridgeStatus {
        statusSnapshotImpl()
    }

    let videoForwarder = LumenVideoCaptureForwarder()
    let audioForwarder = LumenAudioCaptureForwarder()
    let logger = Logger(subsystem: "dev.skyline23.lumen", category: "MacBridgeRuntime")
    let captureLifecycle = LumenBridgeCaptureLifecycle()
    let encodedFrameReadiness = LumenFirstEncodedFrameGate()
    let systemAudioPlaybackSuppression:
        LumenSystemAudioPlaybackSuppression
    let encodedCaptureRuntimeFactory:
        any LumenEncodedCaptureRuntimeFactory
    var encodedCaptureSession: LumenEncodedCaptureSession?
    var encodedCaptureStartupTask: Task<Void, Error>?
    var activeCaptureConfiguration: LumenMacCaptureConfiguration?
    var activePreconfiguredSystemAudio: LumenMacAudioCaptureConfiguration?
    var latestFrame: LumenBridgeEncodedFrameSnapshot?
    var recentEvents: [LumenEncodedCaptureSessionEvent] = []
    var audioCaptureSession: LumenAudioCaptureSession?
    var audioCaptureStartupTask: Task<Void, Error>?
    var activeAudioCaptureConfiguration: LumenMacAudioCaptureConfiguration?
    var audioCaptureIsHostedByEncodedSession = false
    var audioCaptureGeneration: UInt64 = 0
    var lastStatusNotificationUptimeNanoseconds: UInt64 = 0
    var hasPendingStatusNotification = false
    var lastDiagnosticsUptimeNanoseconds: UInt64 = 0
    var lastEncodedFrameSourceSequenceNumber: UInt64?
    var lastEncodedFrameSourceDisplayTime: UInt64?
    var lastRestartUptimeNanoseconds: UInt64 = 0
    var activeCaptureGeneration: UInt64?

    init(
        systemAudioPlaybackSuppression:
            LumenSystemAudioPlaybackSuppression,
        encodedCaptureRuntimeFactory:
            any LumenEncodedCaptureRuntimeFactory
    ) {
        self.systemAudioPlaybackSuppression =
            systemAudioPlaybackSuppression
        self.encodedCaptureRuntimeFactory =
            encodedCaptureRuntimeFactory
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
