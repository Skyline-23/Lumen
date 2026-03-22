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
public final class ApolloBridgeAudioConfigurationBox: NSObject {
    public let sourceKindRawValue: Int
    public let displayID: UInt32
    public let excludesCurrentProcessAudio: Bool
    public let inputID: String?
    public let sampleRate: Int
    public let channelCount: Int
    public let frameSize: Int

    public init(
        sourceKindRawValue: Int,
        displayID: UInt32,
        excludesCurrentProcessAudio: Bool,
        inputID: String?,
        sampleRate: Int,
        channelCount: Int,
        frameSize: Int
    ) {
        self.sourceKindRawValue = sourceKindRawValue
        self.displayID = displayID
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.inputID = inputID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameSize = frameSize
    }

    convenience init(configuration: ApolloMacDisplayKitAudioCaptureConfiguration) {
        switch configuration.source {
        case .microphone(let inputID):
            self.init(
                sourceKindRawValue: ApolloBridgeObjCFacade.rawValue(for: ApolloAudioCaptureSourceKind.microphone),
                displayID: 0,
                excludesCurrentProcessAudio: false,
                inputID: inputID,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                frameSize: configuration.frameSize
            )
        case .systemOutput(let displayID, let excludesCurrentProcessAudio):
            self.init(
                sourceKindRawValue: ApolloBridgeObjCFacade.rawValue(for: ApolloAudioCaptureSourceKind.systemOutput),
                displayID: displayID,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio,
                inputID: nil,
                sampleRate: configuration.sampleRate,
                channelCount: configuration.channelCount,
                frameSize: configuration.frameSize
            )
        }
    }

    var swiftValue: ApolloMacDisplayKitAudioCaptureConfiguration {
        let sourceKind = ApolloBridgeObjCFacade.audioSourceKind(fromRawValue: sourceKindRawValue)
        switch sourceKind {
        case .microphone:
            return .microphone(
                inputID: inputID?.isEmpty == false ? inputID : nil,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameSize: frameSize
            )
        case .systemOutput:
            return .systemOutput(
                displayID: displayID,
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameSize: frameSize,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio
            )
        }
    }
}

@objcMembers
public final class ApolloBridgeStatusBox: NSObject {
    public let coreVersion: String
    public let runtimeDescription: String
    public let integrationStatus: String

    init(snapshot: ApolloBridgeStatus) {
        self.coreVersion = snapshot.coreVersion
        self.runtimeDescription = snapshot.runtimeDescription
        self.integrationStatus = snapshot.integrationStatus
    }
}

@objcMembers
public final class ApolloBridgeCoreAudioForwardingSnapshotBox: NSObject {
    public let frameCount: UInt64
    public let eventCount: UInt64
    public let queuedFrameCount: UInt64
    public let queuedEventCount: UInt64
    public let droppedFrameCount: UInt64
    public let droppedEventCount: UInt64
    public let hasLastFrame: Bool
    public let lastFrameSequenceNumber: UInt64
    public let lastFrameHostTimeNanoseconds: UInt64
    public let lastFrameSampleRate: Int
    public let lastFrameChannelCount: Int
    public let lastFrameFrameCount: Int
    public let lastFramePCMByteCount: Int
    public let lastEventKindRawValue: Int

    init(snapshot: ApolloBridgeAudioForwardingSnapshot) {
        self.frameCount = snapshot.frameCount
        self.eventCount = snapshot.eventCount
        self.queuedFrameCount = snapshot.queuedFrameCount
        self.queuedEventCount = snapshot.queuedEventCount
        self.droppedFrameCount = snapshot.droppedFrameCount
        self.droppedEventCount = snapshot.droppedEventCount
        self.hasLastFrame = snapshot.lastFrameSequenceNumber != nil
        self.lastFrameSequenceNumber = snapshot.lastFrameSequenceNumber ?? 0
        self.lastFrameHostTimeNanoseconds = snapshot.lastFrameHostTimeNanoseconds ?? 0
        self.lastFrameSampleRate = snapshot.lastFrameSampleRate ?? 0
        self.lastFrameChannelCount = snapshot.lastFrameChannelCount ?? 0
        self.lastFrameFrameCount = snapshot.lastFrameFrameCount ?? 0
        self.lastFramePCMByteCount = snapshot.lastFramePCMByteCount
        self.lastEventKindRawValue = snapshot.lastEventKind.map(ApolloBridgeObjCFacade.rawValue(for:)) ?? -1
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
public final class ApolloBridgeDrainedAudioFrameBox: NSObject {
    public let sequenceNumber: UInt64
    public let hostTimeNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let pcmFloat32LE: NSData

    init(frame: ApolloBridgeDrainedAudioFrame) {
        self.sequenceNumber = frame.sequenceNumber
        self.hostTimeNanoseconds = frame.hostTimeNanoseconds
        self.sampleRate = frame.sampleRate
        self.channelCount = frame.channelCount
        self.frameCount = frame.frameCount
        self.pcmFloat32LE = frame.pcmFloat32LE as NSData
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
public final class ApolloBridgeDrainedAudioEventBox: NSObject {
    public let kindRawValue: Int
    public let message: String?
    public let hasStopStatus: Bool
    public let stopStatus: Int32
    public let hasAutomaticRestartCount: Bool
    public let automaticRestartCount: UInt64
    public let hasSourceSequenceNumber: Bool
    public let sourceSequenceNumber: UInt64

    init(event: ApolloBridgeDrainedAudioEvent) {
        self.kindRawValue = ApolloBridgeObjCFacade.rawValue(for: event.kind)
        self.message = event.message
        self.hasStopStatus = event.stopStatus != nil
        self.stopStatus = event.stopStatus ?? 0
        self.hasAutomaticRestartCount = event.automaticRestartCount != nil
        self.automaticRestartCount = event.automaticRestartCount ?? 0
        self.hasSourceSequenceNumber = event.sourceSequenceNumber != nil
        self.sourceSequenceNumber = event.sourceSequenceNumber ?? 0
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

    public func makePanelNativeConfiguration(displayID: UInt32) -> ApolloBridgeConfigurationBox {
        ApolloBridgeConfigurationBox(configuration: .panelNative(displayID: displayID))
    }

    public func makeDefaultMicrophoneAudioConfiguration() -> ApolloBridgeAudioConfigurationBox {
        ApolloBridgeAudioConfigurationBox(configuration: .microphone())
    }

    public func makeSystemOutputAudioConfiguration(displayID: UInt32) -> ApolloBridgeAudioConfigurationBox {
        ApolloBridgeAudioConfigurationBox(configuration: .systemOutput(displayID: displayID))
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

    public func startMacDisplayKitAudioCaptureSync(
        _ configuration: ApolloBridgeAudioConfigurationBox,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        do {
            try blockingRun { [self] in
                try await self.runtime.startMacDisplayKitAudioCapture(configuration: configuration.swiftValue)
            }
            return true
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func stopMacDisplayKitAudioCaptureSync() {
        try? blockingRun { [self] in
            await self.runtime.stopMacDisplayKitAudioCapture()
        }
    }

    public func copyStatusSnapshotSync() -> ApolloBridgeStatusBox {
        (try? blockingRun { [self] in
            ApolloBridgeStatusBox(snapshot: await self.runtime.statusSnapshot())
        }) ?? ApolloBridgeStatusBox(
            snapshot: ApolloBridgeStatus(
                coreVersion: String(cString: ApolloCoreBootstrapVersionString()),
                runtimeDescription: String(cString: ApolloCoreBootstrapRuntimeDescription()),
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

    public func configureAudioForwardingSync(frameCapacity: Int, eventCapacity: Int) {
        try? blockingRun { [self] in
            await self.runtime.configureAudioForwarding(
                frameCapacity: frameCapacity,
                eventCapacity: eventCapacity
            )
        }
    }

    public func copyAudioForwardingSnapshotSync() -> ApolloBridgeCoreAudioForwardingSnapshotBox {
        (try? blockingRun { [self] in
            ApolloBridgeCoreAudioForwardingSnapshotBox(
                snapshot: await self.runtime.audioForwardingSnapshot()
            )
        }) ?? ApolloBridgeCoreAudioForwardingSnapshotBox(
            snapshot: ApolloBridgeAudioForwardingSnapshot(
                frameCount: 0,
                eventCount: 0,
                queuedFrameCount: 0,
                queuedEventCount: 0,
                droppedFrameCount: 0,
                droppedEventCount: 0,
                lastFrameSequenceNumber: nil,
                lastFrameHostTimeNanoseconds: nil,
                lastFrameSampleRate: nil,
                lastFrameChannelCount: nil,
                lastFrameFrameCount: nil,
                lastFramePCMByteCount: 0,
                lastEventKind: nil
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

    public func popNextCoreForwardedAudioFrameSync() -> ApolloBridgeDrainedAudioFrameBox? {
        try? blockingRun { [self] in
            await self.runtime.drainNextCoreForwardedAudioFrame().map {
                ApolloBridgeDrainedAudioFrameBox(frame: $0)
            }
        }
    }

    public func popNextCoreForwardedAudioEventSync() -> ApolloBridgeDrainedAudioEventBox? {
        try? blockingRun { [self] in
            await self.runtime.drainNextCoreForwardedAudioEvent().map {
                ApolloBridgeDrainedAudioEventBox(event: $0)
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

    static func audioSourceKind(fromRawValue rawValue: Int) -> ApolloAudioCaptureSourceKind {
        switch rawValue {
        case 1:
            return .systemOutput
        default:
            return .microphone
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

    static func rawValue(for audioSourceKind: ApolloAudioCaptureSourceKind) -> Int {
        switch audioSourceKind {
        case .microphone:
            return 0
        case .systemOutput:
            return 1
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
