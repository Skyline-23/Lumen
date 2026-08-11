import Foundation
import LumenEngineBridge
import OSLog
import Synchronization

@objcMembers
public final class LumenBridgeObjCFacade: NSObject {
    private static let logger = Logger(subsystem: "dev.skyline23.lumen", category: "MacBridgeObjCFacade")
    private static let keyFrameRequestTimeout: DispatchTimeInterval = .milliseconds(250)
    private let runtime: LumenBridgeRuntime

    public static func runtimeStatusDidChangeNotificationName() -> String {
        LumenBridgeRuntime.statusDidChangeNotification.rawValue
    }

    public override init() {
        self.runtime = LumenBridgeRuntime.shared
        super.init()
    }

    public static func requestImmediateCaptureKeyFrameSharedSync() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer {
                semaphore.signal()
            }
            await LumenBridgeRuntime.shared.requestImmediateCaptureKeyFrame()
        }
        if semaphore.wait(timeout: .now() + keyFrameRequestTimeout) == .timedOut {
            logger.warning(
                """
                Timed out waiting for immediate ScreenCaptureKit keyframe request; \
                continuing without blocking video teardown
                """
            )
        }
    }

    public static func requestPeriodicCaptureKeyFrameSharedSync() -> Bool {
        LumenBridgeObjCFacade().requestPeriodicCaptureKeyFrameSync()
    }

    public static func resumeVideoEncodingAfterCodecAckSharedSync() -> Bool {
        LumenBridgeObjCFacade().resumeVideoEncodingAfterCodecAckSync()
    }

    public static func setVideoBitRateKbpsSharedSync(
        _ bitrateKbps: UInt32
    ) -> Bool {
        LumenBridgeObjCFacade().setVideoBitRateKbpsSync(bitrateKbps)
    }

    public static func setVideoDeliveryPolicySharedSync(
        _ sessionEpoch: UInt32,
        policyRevision: UInt32,
        bitrateKbps: UInt32,
        admissionDivisor: UInt8
    ) -> Bool {
        LumenBridgeObjCFacade().setVideoDeliveryPolicySync(
            sessionEpoch,
            policyRevision: policyRevision,
            bitrateKbps: bitrateKbps,
            admissionDivisor: admissionDivisor
        )
    }

    public static func wakeUnchangedContentCadenceShared(
        _ sessionEpoch: UInt32
    ) -> Bool {
        LumenBridgeRuntime.shared.scheduleUnchangedContentCadenceWake(
            sessionEpoch: sessionEpoch
        )
    }

    public static func restartCaptureSharedSync(_ reason: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await LumenBridgeRuntime.shared.restartCapture(reason: reason)
            semaphore.signal()
        }
        semaphore.wait()
    }

    public func makePanelNativeConfiguration(displayID: UInt32) -> LumenBridgeConfigurationBox {
        LumenBridgeConfigurationBox(configuration: .panelNative(displayID: displayID))
    }

    public func makeDefaultMicrophoneAudioConfiguration() -> LumenBridgeAudioConfigurationBox {
        LumenBridgeAudioConfigurationBox(configuration: .microphone())
    }

    public func makeSystemOutputAudioConfiguration(displayID: UInt32) -> LumenBridgeAudioConfigurationBox {
        LumenBridgeAudioConfigurationBox(configuration: .systemOutput(displayID: displayID))
    }

    public func startCaptureSync(
        _ configuration: LumenBridgeConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        let runtime = runtime
        let configuration = configuration.swiftValue
        do {
            try blockingRun {
                try await runtime.startCapture(configuration: configuration)
            }
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func startCapturePairSync(
        _ videoConfiguration: LumenBridgeConfigurationBox,
        audioConfiguration: LumenBridgeAudioConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Int {
        let runtime = runtime
        let videoConfiguration = videoConfiguration.swiftValue
        let audioConfiguration = audioConfiguration.swiftValue
        do {
            try blockingRun {
                try await runtime.startCapture(
                    configuration: videoConfiguration,
                    preconfiguredSystemAudio: audioConfiguration
                )
            }
            return 0
        } catch let error as LumenBridgeCaptureStartupError {
            errorPointer?.pointee = error as NSError
            return error.source.rawValue
        } catch let error as LumenAudioCaptureError {
            errorPointer?.pointee = error as NSError
            return LumenBridgeCaptureStartupSource.audio.rawValue
        } catch {
            errorPointer?.pointee = error as NSError
            return LumenBridgeCaptureStartupSource.unknown.rawValue
        }
    }

    public func stopCaptureSync() {
        let runtime = runtime
        try? blockingRun {
            await runtime.stopCapture()
        }
    }

    public func requestImmediateCaptureKeyFrameSync() {
        let runtime = runtime
        try? blockingRun {
            await runtime.requestImmediateCaptureKeyFrame()
        }
    }

    public func requestPeriodicCaptureKeyFrameSync() -> Bool {
        let runtime = runtime
        return (try? blockingRun {
            await runtime.requestPeriodicCaptureKeyFrame()
        }) ?? false
    }

    public func resumeVideoEncodingAfterCodecAckSync() -> Bool {
        let runtime = runtime
        return (try? blockingRun {
            await runtime.resumeVideoEncodingAfterCodecAck()
        }) ?? false
    }

    public func setVideoBitRateKbpsSync(_ bitrateKbps: UInt32) -> Bool {
        let runtime = runtime
        return (try? blockingRun {
            await runtime.setVideoBitRateKbps(Int(bitrateKbps))
        }) ?? false
    }

    public func setVideoDeliveryPolicySync(
        _ sessionEpoch: UInt32,
        policyRevision: UInt32,
        bitrateKbps: UInt32,
        admissionDivisor: UInt8
    ) -> Bool {
        let runtime = runtime
        return (try? blockingRun {
            await runtime.setVideoDeliveryPolicy(
                sessionEpoch: sessionEpoch,
                policyRevision: policyRevision,
                bitrateKbps: Int(bitrateKbps),
                admissionDivisor: Int(admissionDivisor)
            )
        }) ?? false
    }

    public func restartCaptureSync(_ reason: String) {
        let runtime = runtime
        try? blockingRun {
            await runtime.restartCapture(reason: reason)
        }
    }

    public func startAudioCaptureSync(
        _ configuration: LumenBridgeAudioConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        startAudioCapture(configuration, startsAsynchronously: false, error: errorPointer)
    }

    public func startAudioCaptureAsynchronouslySync(
        _ configuration: LumenBridgeAudioConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        startAudioCapture(configuration, startsAsynchronously: true, error: errorPointer)
    }

    public func stopAudioCaptureSync() {
        let runtime = runtime
        try? blockingRun {
            await runtime.stopAudioCapture()
        }
    }

    private func startAudioCapture(
        _ configurationBox: LumenBridgeAudioConfigurationBox,
        startsAsynchronously: Bool,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        let runtime = runtime
        let configuration = configurationBox.swiftValue
        do {
            try blockingRun {
                if startsAsynchronously {
                    try await runtime.startAudioCaptureAsynchronously(configuration: configuration)
                } else {
                    try await runtime.startAudioCapture(configuration: configuration)
                }
            }
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    private func blockingRun<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Result<T, Error>?>(nil)
        Task {
            do {
                let value = try await operation()
                result.withLock { $0 = .success(value) }
            } catch {
                result.withLock { $0 = .failure(error) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.withLock { result in
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            case .none:
                fatalError("LumenBridgeObjCFacade blockingRun resolved without a result")
            }
        }
    }
}

extension LumenBridgeObjCFacade {
    public func copyStatusSnapshotSync() -> LumenBridgeStatusBox {
        let runtime = runtime
        let snapshot = try? blockingRun {
            await runtime.statusSnapshot()
        }
        return snapshot.map(LumenBridgeStatusBox.init(snapshot:)) ?? makeUnavailableStatusBox()
    }

    public func configureVideoForwardingSync(frameCapacity: Int, eventCapacity: Int) {
        runtime.configureVideoForwarding(
            frameCapacity: frameCapacity,
            eventCapacity: eventCapacity
        )
    }

    public func copyVideoForwardingSnapshotSync() -> LumenBridgeVideoForwardingSnapshotBox {
        LumenBridgeVideoForwardingSnapshotBox(
            snapshot: runtime.videoForwardingSnapshot()
        )
    }

    public func copyCaptureDiagnosticsSync() -> NSString {
        let runtime = runtime
        return ((try? blockingRun {
            await runtime.captureDiagnosticsString()
        }) ?? "n/a") as NSString
    }

    public func configureAudioForwardingSync(frameCapacity: Int, eventCapacity: Int) {
        runtime.configureAudioForwarding(
            frameCapacity: frameCapacity,
            eventCapacity: eventCapacity
        )
    }

    public func resetMediaQueuesSync() {
        runtime.resetMediaQueues()
    }

    public func copyAudioForwardingSnapshotSync() -> LumenBridgeAudioForwardingSnapshotBox {
        LumenBridgeAudioForwardingSnapshotBox(
            snapshot: runtime.audioForwardingSnapshot()
        )
    }

    public func popNextVideoForwardedFrameSync() -> LumenBridgeDrainedFrameBox? {
        runtime.drainNextVideoForwardedFrame()
            .map(LumenBridgeDrainedFrameBox.init(frame:))
    }

    public func popNextVideoForwardedEventSync() -> LumenBridgeDrainedEventBox? {
        runtime.drainNextVideoForwardedEvent()
            .map(LumenBridgeDrainedEventBox.init(event:))
    }

    public func popNextVideoForwardedAudioFrameSync() -> LumenBridgeDrainedAudioFrameBox? {
        runtime.drainNextVideoForwardedAudioFrame()
            .map(LumenBridgeDrainedAudioFrameBox.init(frame:))
    }

    public func popNextVideoForwardedAudioEventSync() -> LumenBridgeDrainedAudioEventBox? {
        runtime.drainNextVideoForwardedAudioEvent()
            .map(LumenBridgeDrainedAudioEventBox.init(event:))
    }

    private func makeUnavailableStatusBox() -> LumenBridgeStatusBox {
        LumenBridgeStatusBox(
            snapshot: LumenBridgeStatus(
                coreVersion: "Rust ABI \(LumenEngineBridgeABIVersion())",
                runtimeDescription: "Rust host with Swift macOS capture adapters",
                integrationStatus: "LumenBridgeObjCFacade failed to read the actor-backed status snapshot.",
                captureSessionRunning: false,
                audioCaptureSessionRunning: false,
                automaticCaptureOrchestrationRunning: false
            )
        )
    }

}
