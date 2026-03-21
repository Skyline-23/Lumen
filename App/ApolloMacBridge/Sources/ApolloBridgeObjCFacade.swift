import CoreMedia
import Foundation

@objcMembers
public final class ApolloBridgeConfigurationBox: NSObject {
    public let displayID: UInt32
    public let codecRawValue: Int
    public let preprocessStrategyRawValue: Int
    public let queueProfileRawValue: Int
    public let showCursor: Bool
    public let targetFrameRate: Int

    public init(
        displayID: UInt32,
        codecRawValue: Int,
        preprocessStrategyRawValue: Int,
        queueProfileRawValue: Int,
        showCursor: Bool,
        targetFrameRate: Int
    ) {
        self.displayID = displayID
        self.codecRawValue = codecRawValue
        self.preprocessStrategyRawValue = preprocessStrategyRawValue
        self.queueProfileRawValue = queueProfileRawValue
        self.showCursor = showCursor
        self.targetFrameRate = targetFrameRate
    }

    convenience init(configuration: ApolloMacDisplayKitCaptureConfiguration) {
        self.init(
            displayID: configuration.displayID,
            codecRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.codec),
            preprocessStrategyRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.preprocessStrategy),
            queueProfileRawValue: ApolloBridgeObjCFacade.rawValue(for: configuration.queueProfile),
            showCursor: configuration.showCursor,
            targetFrameRate: configuration.targetFrameRate
        )
    }

    var swiftValue: ApolloMacDisplayKitCaptureConfiguration {
        ApolloMacDisplayKitCaptureConfiguration(
            displayID: displayID,
            codec: ApolloBridgeObjCFacade.codec(fromRawValue: codecRawValue),
            preprocessStrategy: ApolloBridgeObjCFacade.preprocessStrategy(fromRawValue: preprocessStrategyRawValue),
            queueProfile: ApolloBridgeObjCFacade.queueProfile(fromRawValue: queueProfileRawValue),
            showCursor: showCursor,
            targetFrameRate: targetFrameRate
        )
    }
}

@objcMembers
public final class ApolloBridgeStatusBox: NSObject {
    public let coreVersion: String
    public let runtimeDescription: String
    public let preferredCaptureBackendRawValue: Int
    public let integrationStatus: String

    init(snapshot: ApolloBridgeStatus) {
        self.coreVersion = snapshot.coreVersion
        self.runtimeDescription = snapshot.runtimeDescription
        self.preferredCaptureBackendRawValue = ApolloBridgeObjCFacade.rawValue(for: snapshot.preferredCaptureBackend)
        self.integrationStatus = snapshot.integrationStatus
    }
}

@objcMembers
public final class ApolloBridgeCoreForwardingSnapshotBox: NSObject {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let hasLastSampleBuffer: Bool
    public let lastFrameCodecRawValue: Int
    public let lastFramePayloadSize: Int
    public let hasLastFrameSourceSequenceNumber: Bool
    public let lastFrameSourceSequenceNumber: UInt64
    public let hasLastFrameSourceDisplayTime: Bool
    public let lastFrameSourceDisplayTime: UInt64
    public let lastFrameIsKeyFrame: Bool
    public let lastFrameIsHDRSignaled: Bool
    public let lastEventKindRawValue: Int

    init(snapshot: ApolloBridgeCoreForwardingSnapshot) {
        self.frameCount = snapshot.frameCount
        self.eventCount = snapshot.eventCount
        self.queuedFrameCount = snapshot.queuedFrameCount
        self.queuedEventCount = snapshot.queuedEventCount
        self.droppedFrameCount = snapshot.droppedFrameCount
        self.droppedEventCount = snapshot.droppedEventCount
        self.hasLastSampleBuffer = snapshot.hasLastSampleBuffer
        self.lastFrameCodecRawValue = snapshot.lastFrameCodec.map(ApolloBridgeObjCFacade.rawValue(for:)) ?? -1
        self.lastFramePayloadSize = snapshot.lastFramePayloadSize
        self.hasLastFrameSourceSequenceNumber = snapshot.lastFrameSourceSequenceNumber != nil
        self.lastFrameSourceSequenceNumber = snapshot.lastFrameSourceSequenceNumber ?? 0
        self.hasLastFrameSourceDisplayTime = snapshot.lastFrameSourceDisplayTime != nil
        self.lastFrameSourceDisplayTime = snapshot.lastFrameSourceDisplayTime ?? 0
        self.lastFrameIsKeyFrame = snapshot.lastFrameIsKeyFrame
        self.lastFrameIsHDRSignaled = snapshot.lastFrameIsHDRSignaled
        self.lastEventKindRawValue = snapshot.lastEventKind.map(ApolloBridgeObjCFacade.rawValue(for:)) ?? -1
    }
}

@objcMembers
public final class ApolloBridgeDrainedFrameBox: NSObject {
    public let codecRawValue: Int
    public let payloadSize: Int
    public let sourceSequenceNumber: UInt64
    public let sourceDisplayTime: UInt64
    public let hasOutputCallbackLatencyMilliseconds: Bool
    public let outputCallbackLatencyMilliseconds: Double
    public let isKeyFrame: Bool
    public let isHDRSignaled: Bool
    public let sampleBuffer: CMSampleBuffer

    init(frame: ApolloBridgeCoreDrainedFrame) {
        self.codecRawValue = ApolloBridgeObjCFacade.rawValue(for: frame.codec)
        self.payloadSize = frame.payloadSize
        self.sourceSequenceNumber = frame.sourceSequenceNumber
        self.sourceDisplayTime = frame.sourceDisplayTime
        self.hasOutputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds != nil
        self.outputCallbackLatencyMilliseconds = frame.outputCallbackLatencyMilliseconds ?? 0
        self.isKeyFrame = frame.isKeyFrame
        self.isHDRSignaled = frame.isHDRSignaled
        self.sampleBuffer = frame.sampleBuffer
    }
}

@objcMembers
public final class ApolloBridgeDrainedEventBox: NSObject {
    public let kindRawValue: Int
    public let message: String?
    public let hasStopStatus: Bool
    public let stopStatus: Int32
    public let hasAutomaticRestartCount: Bool
    public let automaticRestartCount: UInt64
    public let hasSourceDisplayTime: Bool
    public let sourceDisplayTime: UInt64

    init(event: ApolloBridgeCoreDrainedEvent) {
        self.kindRawValue = ApolloBridgeObjCFacade.rawValue(for: event.kind)
        self.message = event.message
        self.hasStopStatus = event.stopStatus != nil
        self.stopStatus = event.stopStatus ?? 0
        self.hasAutomaticRestartCount = event.automaticRestartCount != nil
        self.automaticRestartCount = event.automaticRestartCount ?? 0
        self.hasSourceDisplayTime = event.sourceDisplayTime != nil
        self.sourceDisplayTime = event.sourceDisplayTime ?? 0
    }
}

@objcMembers
public final class ApolloBridgeObjCFacade: NSObject {
    private let runtime: ApolloBridgeRuntime

    public override init() {
        self.runtime = ApolloBridgeRuntime()
        super.init()
    }

    public func setPreferredCaptureBackendRawValue(_ rawValue: Int) {
        let backend = Self.backend(fromRawValue: rawValue)
        Task {
            await runtime.setPreferredCaptureBackend(backend)
        }
    }

    public func makePanelNativeConfiguration(displayID: UInt32) -> ApolloBridgeConfigurationBox {
        ApolloBridgeConfigurationBox(configuration: .panelNative(displayID: displayID))
    }

    public func startMacDisplayKitCaptureSync(
        _ configuration: ApolloBridgeConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        do {
            try blockingRun { [self] in
                try await self.runtime.startMacDisplayKitCapture(configuration: configuration.swiftValue)
            }
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func stopMacDisplayKitCaptureSync() {
        try? blockingRun { [self] in
            await self.runtime.stopMacDisplayKitCapture()
        }
    }

    public func copyStatusSnapshotSync() -> ApolloBridgeStatusBox {
        (try? blockingRun { [self] in
            ApolloBridgeStatusBox(snapshot: await self.runtime.statusSnapshot())
        }) ?? ApolloBridgeStatusBox(
            snapshot: ApolloBridgeStatus(
                coreVersion: String(cString: ApolloCoreBootstrapVersionString()),
                runtimeDescription: String(cString: ApolloCoreBootstrapRuntimeDescription()),
                preferredCaptureBackend: .macDisplayKit,
                integrationStatus: "ApolloBridgeObjCFacade failed to read the actor-backed status snapshot."
            )
        )
    }

    public func configureCoreForwardingSync(frameCapacity: Int, eventCapacity: Int) {
        try? blockingRun { [self] in
            await self.runtime.configureCoreForwarding(
                frameCapacity: frameCapacity,
                eventCapacity: eventCapacity
            )
        }
    }

    public func copyCoreForwardingSnapshotSync() -> ApolloBridgeCoreForwardingSnapshotBox {
        (try? blockingRun { [self] in
            ApolloBridgeCoreForwardingSnapshotBox(
                snapshot: await self.runtime.coreForwardingSnapshot()
            )
        }) ?? ApolloBridgeCoreForwardingSnapshotBox(
            snapshot: ApolloBridgeCoreForwardingSnapshot(
                snapshot: ApolloCoreEncodedCaptureIngressSnapshot()
            )
        )
    }

    public func popNextCoreForwardedFrameSync() -> ApolloBridgeDrainedFrameBox? {
        try? blockingRun { [self] in
            await self.runtime.drainNextCoreForwardedFrame().map {
                ApolloBridgeDrainedFrameBox(frame: $0)
            }
        }
    }

    public func popNextCoreForwardedEventSync() -> ApolloBridgeDrainedEventBox? {
        try? blockingRun { [self] in
            await self.runtime.drainNextCoreForwardedEvent().map {
                ApolloBridgeDrainedEventBox(event: $0)
            }
        }
    }

    private func blockingRun<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let state = BlockingResultBox<T>()
        Task {
            do {
                state.store(result: .success(try await operation()))
            } catch {
                state.store(result: .failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try state.resolve()
    }

    private final class BlockingResultBox<T>: @unchecked Sendable {
        private var result: Result<T, Error>?

        func store(result: Result<T, Error>) {
            self.result = result
        }

        func resolve() throws -> T {
            let result = self.result

            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            case .none:
                fatalError("ApolloBridgeObjCFacade blockingRun resolved without a result")
            }
        }
    }
}

extension ApolloBridgeObjCFacade {
    static func backend(fromRawValue rawValue: Int) -> ApolloCaptureBackend {
        switch rawValue {
        case 0:
            return .legacyApollo
        case 1:
            return .macDisplayKit
        default:
            return .macDisplayKit
        }
    }

    static func codec(fromRawValue rawValue: Int) -> ApolloCaptureCodec {
        switch rawValue {
        case Int(ApolloCoreCaptureCodecH264.rawValue):
            return .h264
        case Int(ApolloCoreCaptureCodecProResProxy.rawValue):
            return .proResProxy
        case Int(ApolloCoreCaptureCodecHEVC.rawValue):
            return .hevc
        default:
            return .hevc
        }
    }

    static func preprocessStrategy(fromRawValue rawValue: Int) -> ApolloCapturePreprocessStrategy {
        switch rawValue {
        case 1:
            return .downscale2x
        default:
            return .none
        }
    }

    static func queueProfile(fromRawValue rawValue: Int) -> ApolloCaptureQueueProfile {
        switch rawValue {
        case 0:
            return .q1
        case 1:
            return .q2
        case 2:
            return .q3
        case 3:
            return .q4
        default:
            return .q2
        }
    }

    static func rawValue(for backend: ApolloCaptureBackend) -> Int {
        switch backend {
        case .legacyApollo:
            return 0
        case .macDisplayKit:
            return 1
        }
    }

    static func rawValue(for codec: ApolloCaptureCodec) -> Int {
        switch codec {
        case .h264:
            return Int(ApolloCoreCaptureCodecH264.rawValue)
        case .hevc:
            return Int(ApolloCoreCaptureCodecHEVC.rawValue)
        case .proResProxy:
            return Int(ApolloCoreCaptureCodecProResProxy.rawValue)
        }
    }

    static func rawValue(for strategy: ApolloCapturePreprocessStrategy) -> Int {
        switch strategy {
        case .none:
            return 0
        case .downscale2x:
            return 1
        }
    }

    static func rawValue(for queueProfile: ApolloCaptureQueueProfile) -> Int {
        switch queueProfile {
        case .q1:
            return 0
        case .q2:
            return 1
        case .q3:
            return 2
        case .q4:
            return 3
        }
    }

    static func rawValue(for eventKind: ApolloBridgeCaptureEventKind) -> Int {
        switch eventKind {
        case .started:
            return Int(ApolloCoreCaptureEventKindStarted.rawValue)
        case .stopped:
            return Int(ApolloCoreCaptureEventKindStopped.rawValue)
        case .restarted:
            return Int(ApolloCoreCaptureEventKindRestarted.rawValue)
        case .failed:
            return Int(ApolloCoreCaptureEventKindFailed.rawValue)
        case .droppedFrame:
            return Int(ApolloCoreCaptureEventKindDroppedFrame.rawValue)
        }
    }
}
