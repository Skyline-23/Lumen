import AVFoundation
import CoreAudio
import Foundation
import Synchronization

enum LumenSystemAudioPlaybackSuppressionMuteBehavior: Equatable, Sendable {
    case muted
}

enum LumenSystemAudioPlaybackSuppressionStage:
    String,
    Equatable,
    Hashable,
    Sendable
{
    case createProcessTap = "create-process-tap"
    case readTapStreamFormat = "read-tap-stream-format"
    case configurePCMConversion = "configure-pcm-conversion"
    case createAggregateDevice = "create-aggregate-device"
    case createIOProc = "create-io-proc"
    case startIO = "start-io"
    case stopIO = "stop-io"
    case destroyIOProc = "destroy-io-proc"
    case destroyAggregateDevice = "destroy-aggregate-device"
    case destroyProcessTap = "destroy-process-tap"
}

struct LumenSystemAudioPlaybackSuppressionTap: Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
}

struct LumenSystemAudioPlaybackSuppressionStreamFormat:
    Equatable,
    Sendable
{
    let sampleRate: Int
    let channelCount: Int
    let isInterleaved: Bool
    let bytesPerFrame: Int
    let bytesPerPacket: Int
    let framesPerPacket: Int
    let bitsPerChannel: Int
    let formatFlags: UInt32

    init(
        sampleRate: Int,
        channelCount: Int,
        isInterleaved: Bool,
        bytesPerFrame: Int = 0,
        bytesPerPacket: Int = 0,
        framesPerPacket: Int = 0,
        bitsPerChannel: Int = 0,
        formatFlags: UInt32 = 0
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isInterleaved = isInterleaved
        self.bytesPerFrame = bytesPerFrame
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bitsPerChannel = bitsPerChannel
        self.formatFlags = formatFlags
    }

    var hasLayoutMetadata: Bool {
        bytesPerFrame > 0 || bytesPerPacket > 0 || framesPerPacket > 0 ||
            bitsPerChannel > 0 || formatFlags != 0
    }
}

struct LumenSystemAudioPlaybackSuppressionPCMBuffer:
    Equatable,
    Sendable
{
    let hostTimeNanoseconds: UInt64
    let sampleRate: Int
    let channelCount: Int
    let frameCount: Int
    let pcmFloat32LE: Data
}

enum LumenSystemAudioPlaybackSuppressionIOEvent: Equatable, Sendable {
    case pcm(LumenSystemAudioPlaybackSuppressionPCMBuffer)
    case dropped(message: String)
}

struct LumenSystemAudioPlaybackSuppressionIOProc: @unchecked Sendable {
    let id: UInt
    fileprivate let coreAudioValue: AudioDeviceIOProcID?
    private let stopDelivering: @Sendable () -> Void

    init(
        id: UInt,
        stopDelivering: @escaping @Sendable () -> Void = {}
    ) {
        self.id = id
        coreAudioValue = nil
        self.stopDelivering = stopDelivering
    }

    fileprivate init(
        id: UInt,
        coreAudioValue: AudioDeviceIOProcID,
        stopDelivering: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.coreAudioValue = coreAudioValue
        self.stopDelivering = stopDelivering
    }

    fileprivate func invalidateDelivery() {
        stopDelivering()
    }
}

struct LumenSystemAudioPlaybackSuppressionHALOperationError:
    Error,
    Equatable,
    Sendable
{
    let status: OSStatus
    let message: String?

    init(
        status: OSStatus,
        message: String? = nil
    ) {
        self.status = status
        self.message = message
    }
}

struct LumenSystemAudioPlaybackSuppressionCleanupFailure:
    Error,
    Equatable,
    Sendable
{
    let stage: LumenSystemAudioPlaybackSuppressionStage
    let status: OSStatus
}

enum LumenSystemAudioPlaybackSuppressionError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case activationFailed(
        stage: LumenSystemAudioPlaybackSuppressionStage,
        status: OSStatus?,
        message: String,
        cleanupFailures: [LumenSystemAudioPlaybackSuppressionCleanupFailure]
    )
    case cancelled(
        cleanupFailures: [LumenSystemAudioPlaybackSuppressionCleanupFailure]
    )

    var errorDescription: String? {
        switch self {
        case .activationFailed(
            let stage,
            let status,
            let message,
            let cleanupFailures
        ):
            let statusDescription = status.map { " OSStatus \($0)." } ?? ""
            let cleanupDescription = cleanupFailures.isEmpty
                ? ""
                : " Cleanup failures: \(Self.cleanupDescription(cleanupFailures))."
            return "Unable to start the Core Audio system-audio source at \(stage.rawValue).\(statusDescription) \(message)\(cleanupDescription)"
        case .cancelled(let cleanupFailures):
            guard !cleanupFailures.isEmpty else {
                return "Core Audio system-audio source activation was cancelled."
            }
            return "Core Audio system-audio source activation was cancelled. Cleanup failures: \(Self.cleanupDescription(cleanupFailures))."
        }
    }

    private static func cleanupDescription(
        _ failures: [LumenSystemAudioPlaybackSuppressionCleanupFailure]
    ) -> String {
        failures
            .map { "\($0.stage.rawValue)=\($0.status)" }
            .joined(separator: ",")
    }
}

struct LumenSystemAudioCaptureLifecycleError:
    Error,
    LocalizedError,
    @unchecked Sendable
{
    let underlyingError: any Error
    let cleanupFailures:
        [LumenSystemAudioPlaybackSuppressionCleanupFailure]

    var errorDescription: String? {
        let cleanup = cleanupFailures
            .map { "\($0.stage.rawValue)=\($0.status)" }
            .joined(separator: ",")
        return "\(underlyingError.localizedDescription) Cleanup failures: \(cleanup)."
    }
}

protocol LumenSystemAudioPlaybackSuppressionHAL: Sendable {
    func resolveCurrentProcessObjectID() throws -> AudioObjectID?
    func createProcessTap(
        muteBehavior: LumenSystemAudioPlaybackSuppressionMuteBehavior,
        isPrivate: Bool,
        excludedProcessObjectIDs: [AudioObjectID]
    ) throws -> LumenSystemAudioPlaybackSuppressionTap
    func readTapStreamFormat(
        tapID: AudioObjectID
    ) throws -> LumenSystemAudioPlaybackSuppressionStreamFormat
    func createAggregateDevice(tapUID: String) throws -> AudioObjectID
    func validateAggregateDevice(
        deviceID: AudioObjectID,
        tapUID: String
    ) throws
    func createIOProc(
        deviceID: AudioObjectID,
        streamFormat:
            LumenSystemAudioPlaybackSuppressionStreamFormat,
        eventHandler: @escaping @Sendable (
            LumenSystemAudioPlaybackSuppressionIOEvent
        ) -> Void
    ) throws -> LumenSystemAudioPlaybackSuppressionIOProc
    func startIO(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) throws
    func stopIO(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) -> OSStatus
    func destroyIOProc(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) -> OSStatus
    func destroyAggregateDevice(deviceID: AudioObjectID) -> OSStatus
    func destroyProcessTap(tapID: AudioObjectID) -> OSStatus
}

/// Converts and chunks copied tap PCM on the HAL drain queue. The Core Audio
/// IO callback itself only writes into a bounded preallocated SPSC ring.
private final class LumenSystemAudioFrameEmitter: @unchecked Sendable {
    private let callbacks: LumenAudioCaptureCallbacks
    private let sourceFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let frameSize: Int
    private let isAcceptingFrames = Atomic(true)
    private var pendingPCM = Data()
    private var pendingHostTimeNanoseconds: UInt64?
    private var sequenceNumber: UInt64 = 0

    init(
        streamFormat: LumenSystemAudioPlaybackSuppressionStreamFormat,
        configuration: LumenMacAudioCaptureConfiguration,
        callbacks: LumenAudioCaptureCallbacks
    ) throws {
        guard configuration.channelCount <= 2 ||
            streamFormat.channelCount >= configuration.channelCount else {
            throw LumenAudioCaptureError.unsupportedChannelConversion(
                source: streamFormat.channelCount,
                requested: configuration.channelCount
            )
        }
        guard let sourceFormat = Self.makeAudioFormat(
            sampleRate: streamFormat.sampleRate,
            channelCount: streamFormat.channelCount
        ),
        let outputFormat = Self.makeAudioFormat(
            sampleRate: configuration.sampleRate,
            channelCount: configuration.channelCount
        ) else {
            throw LumenAudioCaptureError.audioConversionUnavailable
        }
        self.callbacks = callbacks
        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        frameSize = configuration.frameSize
        if streamFormat.sampleRate == configuration.sampleRate,
           streamFormat.channelCount == configuration.channelCount {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(
                from: sourceFormat,
                to: outputFormat
            ) else {
                throw LumenAudioCaptureError.audioConversionUnavailable
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm =
                AVSampleRateConverterAlgorithm_Normal
            self.converter = converter
        }
    }

    private static func makeAudioFormat(
        sampleRate: Int,
        channelCount: Int
    ) -> AVAudioFormat? {
        let layoutTag: AudioChannelLayoutTag
        switch channelCount {
        case 1:
            layoutTag = kAudioChannelLayoutTag_Mono
        case 2:
            layoutTag = kAudioChannelLayoutTag_Stereo
        case 6:
            layoutTag = kAudioChannelLayoutTag_WAVE_5_1_A
        case 8:
            layoutTag = kAudioChannelLayoutTag_WAVE_7_1
        default:
            return nil
        }
        guard let channelLayout = AVAudioChannelLayout(
            layoutTag: layoutTag
        ) else {
            return nil
        }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            interleaved: true,
            channelLayout: channelLayout
        )
        guard format.channelCount == channelCount,
              format.isInterleaved else {
            return nil
        }
        return format
    }

    func consume(
        _ event: LumenSystemAudioPlaybackSuppressionIOEvent
    ) {
        guard isAcceptingFrames.load(ordering: .acquiring) else {
            return
        }
        switch event {
        case .dropped(let message):
            pendingPCM.removeAll(keepingCapacity: true)
            pendingHostTimeNanoseconds = nil
            callbacks.eventHandler?(.init(
                kind: .droppedFrame,
                message: message
            ))
        case .pcm(let buffer):
            do {
                let converted = try convert(buffer)
                append(
                    converted,
                    hostTimeNanoseconds: buffer.hostTimeNanoseconds
                )
            } catch {
                callbacks.eventHandler?(.init(
                    kind: .droppedFrame,
                    message: error.localizedDescription
                ))
            }
        }
    }

    func stop() {
        isAcceptingFrames.store(false, ordering: .releasing)
    }

    private func convert(
        _ buffer: LumenSystemAudioPlaybackSuppressionPCMBuffer
    ) throws -> Data {
        guard buffer.sampleRate == Int(sourceFormat.sampleRate.rounded()),
              buffer.channelCount == Int(sourceFormat.channelCount),
              buffer.frameCount > 0,
              buffer.pcmFloat32LE.count ==
                buffer.frameCount *
                buffer.channelCount *
                MemoryLayout<Float>.size else {
            throw LumenAudioCaptureError.unsupportedPCM
        }
        guard converter != nil else {
            return buffer.pcmFloat32LE
        }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(buffer.frameCount)
        ) else {
            throw LumenAudioCaptureError.unsupportedPCM
        }
        input.frameLength = AVAudioFrameCount(buffer.frameCount)
        guard let inputBytes =
            input.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw LumenAudioCaptureError.unsupportedPCM
        }
        buffer.pcmFloat32LE.copyBytes(
            to: inputBytes.assumingMemoryBound(to: UInt8.self),
            count: buffer.pcmFloat32LE.count
        )

        guard let converter else { return buffer.pcmFloat32LE }
        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(
            max(Int(ceil(Double(buffer.frameCount) * ratio)) + 32, 1)
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw LumenAudioCaptureError.audioConversionUnavailable
        }
        let inputProvider = LumenAudioConverterInputProvider(input: input)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            inputProvider.provide(inputStatus)
        }
        if status == .error {
            throw conversionError ??
                LumenAudioCaptureError.audioConversionUnavailable
        }
        guard let outputBytes =
            output.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw LumenAudioCaptureError.unsupportedPCM
        }
        let byteCount =
            Int(output.frameLength) *
            Int(outputFormat.channelCount) *
            MemoryLayout<Float>.size
        return Data(bytes: outputBytes, count: byteCount)
    }

    private func append(
        _ pcm: Data,
        hostTimeNanoseconds: UInt64
    ) {
        guard !pcm.isEmpty else {
            return
        }
        if pendingPCM.isEmpty {
            pendingHostTimeNanoseconds = hostTimeNanoseconds
        }
        pendingPCM.append(pcm)
        let channelCount = Int(outputFormat.channelCount)
        let frameByteCount =
            frameSize * channelCount * MemoryLayout<Float>.size
        while pendingPCM.count >= frameByteCount {
            sequenceNumber &+= 1
            let frameHostTime =
                pendingHostTimeNanoseconds ?? hostTimeNanoseconds
            callbacks.frameHandler(.init(
                sequenceNumber: sequenceNumber,
                hostTimeNanoseconds: frameHostTime,
                sampleRate: Int(outputFormat.sampleRate.rounded()),
                channelCount: channelCount,
                frameCount: frameSize,
                pcmFloat32LE: Data(pendingPCM.prefix(frameByteCount))
            ))
            pendingPCM.removeFirst(frameByteCount)
            pendingHostTimeNanoseconds =
                frameHostTime +
                UInt64(
                    (Double(frameSize) / outputFormat.sampleRate) *
                    1_000_000_000
                )
        }
    }
}

/// Safety: AVAudioConverter invokes this provider synchronously while the
/// conversion call is active. The unchecked wrapper keeps the non-Sendable
/// PCM buffer and one-shot status together at that AVFoundation callback
/// boundary; no reference escapes the conversion operation.
private final class LumenAudioConverterInputProvider: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private let hasProvidedInput = Atomic(false)

    init(input: AVAudioPCMBuffer) {
        self.input = input
    }

    func provide(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioPCMBuffer? {
        guard !hasProvidedInput.exchange(
            true,
            ordering: .acquiringAndReleasing
        ) else {
            status.pointee = .noDataNow
            return nil
        }
        status.pointee = .haveData
        return input
    }
}

actor LumenSystemAudioPlaybackSuppression {
    private struct Resources {
        var tap: LumenSystemAudioPlaybackSuppressionTap?
        var aggregateDeviceID: AudioObjectID?
        var ioProc: LumenSystemAudioPlaybackSuppressionIOProc?
        var ioStarted = false

        var isEmpty: Bool {
            tap == nil &&
            aggregateDeviceID == nil &&
            ioProc == nil &&
            !ioStarted
        }
    }

    private enum State {
        case inactive
        case active(
            resources: Resources,
            callbacks: LumenAudioCaptureCallbacks
        )
        case pendingCleanup(Resources)
    }

    private let hal: any LumenSystemAudioPlaybackSuppressionHAL
    private var state = State.inactive

    init(hal: any LumenSystemAudioPlaybackSuppressionHAL) {
        self.hal = hal
    }

    func activate(
        configuration: LumenMacAudioCaptureConfiguration,
        callbacks: LumenAudioCaptureCallbacks
    ) throws {
        guard case .systemOutput(
            _,
            let excludesCurrentProcessAudio
        ) = configuration.source else {
            throw LumenAudioCaptureError.invalidSource
        }

        switch state {
        case .active:
            throw LumenSystemAudioPlaybackSuppressionError.activationFailed(
                stage: .createProcessTap,
                status: nil,
                message: "Another session already owns the Core Audio tap.",
                cleanupFailures: []
            )
        case .pendingCleanup(var resources):
            let failures = cleanup(&resources)
            state = resources.isEmpty
                ? .inactive
                : .pendingCleanup(resources)
            guard failures.isEmpty else {
                let failure = failures[0]
                throw LumenSystemAudioPlaybackSuppressionError
                    .activationFailed(
                        stage: failure.stage,
                        status: failure.status,
                        message: "A retained Core Audio resource must be released before another tap can start.",
                        cleanupFailures: failures
                    )
            }
        case .inactive:
            break
        }

        var resources = Resources()
        var stage = LumenSystemAudioPlaybackSuppressionStage
            .createProcessTap
        do {
            try Task.checkCancellation()
            let excludedProcessObjectIDs: [AudioObjectID]
            if excludesCurrentProcessAudio {
                guard let processObjectID =
                    try hal.resolveCurrentProcessObjectID() else {
                    throw LumenSystemAudioPlaybackSuppressionError
                        .activationFailed(
                            stage: .createProcessTap,
                            status: nil,
                            message: "Unable to resolve the current process audio identity for exclusion.",
                            cleanupFailures: []
                        )
                }
                excludedProcessObjectIDs = [processObjectID]
            } else {
                excludedProcessObjectIDs = []
            }
            let tap = try hal.createProcessTap(
                muteBehavior: .muted,
                isPrivate: true,
                excludedProcessObjectIDs: excludedProcessObjectIDs
            )
            resources.tap = tap

            try Task.checkCancellation()
            stage = .readTapStreamFormat
            let streamFormat = try hal.readTapStreamFormat(
                tapID: tap.id
            )
            stage = .configurePCMConversion
            let emitter = try LumenSystemAudioFrameEmitter(
                streamFormat: streamFormat,
                configuration: configuration,
                callbacks: callbacks
            )

            try Task.checkCancellation()
            stage = .createAggregateDevice
            let aggregateDeviceID = try hal.createAggregateDevice(
                tapUID: tap.uid
            )
            resources.aggregateDeviceID = aggregateDeviceID
            try hal.validateAggregateDevice(
                deviceID: aggregateDeviceID,
                tapUID: tap.uid
            )

            try Task.checkCancellation()
            stage = .createIOProc
            let ioProc = try hal.createIOProc(
                deviceID: aggregateDeviceID,
                streamFormat: streamFormat,
                eventHandler: { event in
                    emitter.consume(event)
                }
            )
            resources.ioProc = ioProc

            try Task.checkCancellation()
            stage = .startIO
            try hal.startIO(
                deviceID: aggregateDeviceID,
                ioProc: ioProc
            )
            resources.ioStarted = true
            try Task.checkCancellation()
            state = .active(
                resources: resources,
                callbacks: callbacks
            )
            callbacks.eventHandler?(.init(
                kind: .started,
                message: "Core Audio process tap system-audio capture started mute=muted"
            ))
        } catch is CancellationError {
            resources.ioProc?.invalidateDelivery()
            let failures = cleanup(&resources)
            state = resources.isEmpty
                ? .inactive
                : .pendingCleanup(resources)
            throw LumenSystemAudioPlaybackSuppressionError.cancelled(
                cleanupFailures: failures
            )
        } catch let error
            as LumenSystemAudioPlaybackSuppressionHALOperationError {
            resources.ioProc?.invalidateDelivery()
            let failures = cleanup(&resources)
            state = resources.isEmpty
                ? .inactive
                : .pendingCleanup(resources)
            throw LumenSystemAudioPlaybackSuppressionError
                .activationFailed(
                    stage: stage,
                    status: error.status,
                    message: error.message ??
                        "Core Audio rejected the session-scoped tap boundary.",
                    cleanupFailures: failures
                )
        } catch {
            resources.ioProc?.invalidateDelivery()
            let failures = cleanup(&resources)
            state = resources.isEmpty
                ? .inactive
                : .pendingCleanup(resources)
            throw LumenSystemAudioPlaybackSuppressionError
                .activationFailed(
                    stage: stage,
                    status: nil,
                    message: error.localizedDescription,
                    cleanupFailures: failures
                )
        }
    }

    @discardableResult
    func deactivate()
        -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        switch state {
        case .inactive:
            return []
        case .pendingCleanup(var resources):
            let failures = cleanup(&resources)
            state = resources.isEmpty
                ? .inactive
                : .pendingCleanup(resources)
            return failures
        case .active(var resources, let callbacks):
            resources.ioProc?.invalidateDelivery()
            let failures = cleanup(&resources)
            state = resources.isEmpty
                ? .inactive
                : .pendingCleanup(resources)
            callbacks.eventHandler?(.init(
                kind: .stopped,
                message: "Core Audio process tap system-audio capture stopped",
                stopStatus: failures.first?.status ?? noErr
            ))
            return failures
        }
    }

    private func cleanup(
        _ resources: inout Resources
    ) -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        if resources.ioStarted,
           let aggregateDeviceID = resources.aggregateDeviceID,
           let ioProc = resources.ioProc {
            let status = hal.stopIO(
                deviceID: aggregateDeviceID,
                ioProc: ioProc
            )
            guard status == noErr else {
                return [.init(stage: .stopIO, status: status)]
            }
            resources.ioStarted = false
        }
        if let aggregateDeviceID = resources.aggregateDeviceID,
           let ioProc = resources.ioProc {
            let status = hal.destroyIOProc(
                deviceID: aggregateDeviceID,
                ioProc: ioProc
            )
            guard status == noErr else {
                return [.init(stage: .destroyIOProc, status: status)]
            }
            resources.ioProc = nil
        }
        if let aggregateDeviceID = resources.aggregateDeviceID {
            let status = hal.destroyAggregateDevice(
                deviceID: aggregateDeviceID
            )
            guard status == noErr else {
                return [
                    .init(
                        stage: .destroyAggregateDevice,
                        status: status
                    ),
                ]
            }
            resources.aggregateDeviceID = nil
        }
        if let tap = resources.tap {
            let status = hal.destroyProcessTap(tapID: tap.id)
            guard status == noErr else {
                return [
                    .init(
                        stage: .destroyProcessTap,
                        status: status
                    ),
                ]
            }
            resources.tap = nil
        }
        return []
    }
}

/// A bounded single-producer/single-consumer ring keeps allocation and actor
/// hops out of the Core Audio IO block. The high-QoS drain queue performs the
/// `Data` copy and high-quality sample conversion.
private final class LumenCoreAudioPCMInputRing: @unchecked Sendable {
    private struct Slot {
        let samples: UnsafeMutablePointer<Float>
        var frameCount: Int = 0
        var hostTimeNanoseconds: UInt64 = 0
    }

    private let streamFormat:
        LumenSystemAudioPlaybackSuppressionStreamFormat
    private let slotCount = 8
    private let slotFrameCapacity: Int
    private let writeIndex = Atomic(0)
    private let readIndex = Atomic(0)
    private let acceptingInput = Atomic(true)
    private let droppedInputCount = Atomic(0)
    private let drainQueue = DispatchQueue(
        label: "dev.skyline23.lumen.core-audio.tap-drain",
        qos: .userInteractive
    )
    private let eventHandler: @Sendable (
        LumenSystemAudioPlaybackSuppressionIOEvent
    ) -> Void
    private let slots: UnsafeMutablePointer<Slot>
    private lazy var drainSource: DispatchSourceUserDataAdd = {
        let source = DispatchSource.makeUserDataAddSource(
            queue: drainQueue
        )
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.activate()
        return source
    }()

    init(
        streamFormat:
            LumenSystemAudioPlaybackSuppressionStreamFormat,
        slotFrameCapacity: Int,
        eventHandler: @escaping @Sendable (
            LumenSystemAudioPlaybackSuppressionIOEvent
        ) -> Void
    ) {
        self.streamFormat = streamFormat
        self.slotFrameCapacity = max(slotFrameCapacity, 1)
        self.eventHandler = eventHandler
        slots = .allocate(capacity: slotCount)
        for index in 0..<slotCount {
            slots.advanced(by: index).initialize(to: Slot(
                samples: .allocate(
                    capacity:
                        max(slotFrameCapacity, 1) *
                        streamFormat.channelCount
                )
            ))
        }
        _ = drainSource
    }

    deinit {
        acceptingInput.store(false, ordering: .releasing)
        drainSource.cancel()
        for index in 0..<slotCount {
            let slot = slots.advanced(by: index)
            slot.pointee.samples.deallocate()
            slot.deinitialize(count: 1)
        }
        slots.deallocate()
    }

    func stop(callbackQueue: DispatchQueue) {
        acceptingInput.store(false, ordering: .releasing)
        callbackQueue.sync {}
        drainSource.add(data: 1)
        drainQueue.sync {
            drain()
        }
    }

    func enqueue(
        audioBufferList: UnsafePointer<AudioBufferList>,
        hostTimeNanoseconds: UInt64
    ) {
        guard acceptingInput.load(ordering: .acquiring) else {
            return
        }
        let currentWrite = writeIndex.load(ordering: .relaxed)
        let nextWrite = (currentWrite + 1) % slotCount
        guard nextWrite != readIndex.load(ordering: .acquiring) else {
            _ = droppedInputCount.wrappingAdd(1, ordering: .relaxed)
            drainSource.add(data: 1)
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        guard !buffers.isEmpty else {
            _ = droppedInputCount.wrappingAdd(1, ordering: .relaxed)
            drainSource.add(data: 1)
            return
        }
        var availableFrameCount = Int.max
        var availableChannelCount = 0
        for buffer in buffers {
            let channels = max(Int(buffer.mNumberChannels), 1)
            availableChannelCount += channels
            availableFrameCount = min(
                availableFrameCount,
                Int(buffer.mDataByteSize) /
                    (channels * MemoryLayout<Float>.size)
            )
        }
        guard availableFrameCount > 0,
              availableFrameCount <= slotFrameCapacity,
              availableChannelCount >= streamFormat.channelCount else {
            _ = droppedInputCount.wrappingAdd(1, ordering: .relaxed)
            drainSource.add(data: 1)
            return
        }

        let slot = slots.advanced(by: currentWrite)
        let target = slot.pointee.samples
        var channelOffset = 0
        for buffer in buffers {
            let bufferChannelCount = Int(buffer.mNumberChannels)
            guard let data = buffer.mData else {
                _ = droppedInputCount.wrappingAdd(
                    1,
                    ordering: .relaxed
                )
                drainSource.add(data: 1)
                return
            }
            let source = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<availableFrameCount {
                for channel in 0..<bufferChannelCount
                where channelOffset + channel <
                    streamFormat.channelCount {
                    target[
                        frame * streamFormat.channelCount +
                        channelOffset +
                        channel
                    ] = source[frame * bufferChannelCount + channel]
                }
            }
            channelOffset += bufferChannelCount
        }
        slot.pointee.frameCount = availableFrameCount
        slot.pointee.hostTimeNanoseconds = hostTimeNanoseconds
        writeIndex.store(nextWrite, ordering: .releasing)
        drainSource.add(data: 1)
    }

    private func drain() {
        let dropped = droppedInputCount.exchange(
            0,
            ordering: .acquiringAndReleasing
        )
        if dropped > 0 {
            eventHandler(.dropped(
                message: "Core Audio tap input ring dropped \(dropped) callback buffer(s)"
            ))
        }
        while true {
            let currentRead = readIndex.load(ordering: .relaxed)
            guard currentRead != writeIndex.load(ordering: .acquiring)
            else {
                return
            }
            let slot = slots.advanced(by: currentRead).pointee
            let byteCount =
                slot.frameCount *
                streamFormat.channelCount *
                MemoryLayout<Float>.size
            eventHandler(.pcm(.init(
                hostTimeNanoseconds: slot.hostTimeNanoseconds,
                sampleRate: streamFormat.sampleRate,
                channelCount: streamFormat.channelCount,
                frameCount: slot.frameCount,
                pcmFloat32LE: Data(
                    bytes: slot.samples,
                    count: byteCount
                )
            )))
            readIndex.store(
                (currentRead + 1) % slotCount,
                ordering: .releasing
            )
        }
    }
}

/// Safety: one long-lived instance is injected into the Core Audio source
/// actor. Core Audio owns the IO block until the matching destroy call. The IO
/// block itself only writes to the bounded SPSC ring above.
final class LumenCoreAudioSystemAudioPlaybackSuppressionHAL:
    LumenSystemAudioPlaybackSuppressionHAL,
    @unchecked Sendable
{
    private static let machTimebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()

    func resolveCurrentProcessObjectID() throws -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector:
                kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout.size(ofValue: processObjectID))
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout.size(ofValue: pid)),
            &pid,
            &dataSize,
            &processObjectID
        )
        try requireSuccess(status)
        return processObjectID == kAudioObjectUnknown
            ? nil
            : processObjectID
    }

    func createProcessTap(
        muteBehavior: LumenSystemAudioPlaybackSuppressionMuteBehavior,
        isPrivate: Bool,
        excludedProcessObjectIDs: [AudioObjectID]
    ) throws -> LumenSystemAudioPlaybackSuppressionTap {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses:
                excludedProcessObjectIDs
        )
        description.name = "Lumen session system audio"
        description.isPrivate = isPrivate
        switch muteBehavior {
        case .muted:
            description.muteBehavior =
                CATapMuteBehavior.muted
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try requireSuccess(
            AudioHardwareCreateProcessTap(description, &tapID)
        )
        return .init(
            id: tapID,
            uid: description.uuid.uuidString
        )
    }

    func readTapStreamFormat(
        tapID: AudioObjectID
    ) throws -> LumenSystemAudioPlaybackSuppressionStreamFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout.size(ofValue: format))
        try requireSuccess(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &dataSize,
                &format
            )
        )
        let isFloat32 =
            format.mFormatID == kAudioFormatLinearPCM &&
            format.mBitsPerChannel == 32 &&
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
            format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
            format.mFormatFlags & kAudioFormatFlagIsPacked != 0 &&
            format.mFramesPerPacket == 1
        let isInterleaved =
            format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let expectedBytesPerFrame = isInterleaved
            ? Int(format.mChannelsPerFrame) * MemoryLayout<Float>.size
            : MemoryLayout<Float>.size
        let hasTightlyPackedLayout =
            Int(format.mBytesPerFrame) == expectedBytesPerFrame &&
            Int(format.mBytesPerPacket) == expectedBytesPerFrame
        guard isFloat32,
              isInterleaved,
              hasTightlyPackedLayout,
              format.mSampleRate > 0,
              format.mChannelsPerFrame > 0 else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: kAudioDeviceUnsupportedFormatError
            )
        }
        return .init(
            sampleRate: Int(format.mSampleRate.rounded()),
            channelCount: Int(format.mChannelsPerFrame),
            isInterleaved: isInterleaved,
            bytesPerFrame: Int(format.mBytesPerFrame),
            bytesPerPacket: Int(format.mBytesPerPacket),
            framesPerPacket: Int(format.mFramesPerPacket),
            bitsPerChannel: Int(format.mBitsPerChannel),
            formatFlags: format.mFormatFlags
        )
    }

    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateUID =
            "dev.skyline23.lumen.session-audio.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey:
                "Lumen Session System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try requireSuccess(
            AudioHardwareCreateAggregateDevice(
                description as CFDictionary,
                &deviceID
            )
        )
        return deviceID
    }

    func validateAggregateDevice(
        deviceID: AudioObjectID,
        tapUID: String
    ) throws {
        let retainedTapUIDs = try aggregateTapUIDs(deviceID: deviceID)
        guard retainedTapUIDs == [tapUID] else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: kAudioHardwareBadDeviceError,
                message: "The private aggregate did not retain the exact session process tap."
            )
        }
        let inputStreamIDs = try inputStreamIDs(deviceID: deviceID)
        guard !inputStreamIDs.isEmpty else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: kAudioHardwareBadDeviceError,
                message: "The private aggregate published no input stream for the session process tap."
            )
        }
    }

    func createIOProc(
        deviceID: AudioObjectID,
        streamFormat:
            LumenSystemAudioPlaybackSuppressionStreamFormat,
        eventHandler: @escaping @Sendable (
            LumenSystemAudioPlaybackSuppressionIOEvent
        ) -> Void
    ) throws -> LumenSystemAudioPlaybackSuppressionIOProc {
        let callbackQueue = DispatchQueue(
            label: "dev.skyline23.lumen.core-audio.tap-io",
            qos: .userInteractive
        )
        let ring = LumenCoreAudioPCMInputRing(
            streamFormat: streamFormat,
            slotFrameCapacity: max(
                try deviceBufferFrameSize(deviceID: deviceID),
                4_096
            ),
            eventHandler: eventHandler
        )
        var ioProc: AudioDeviceIOProcID?
        try requireSuccess(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProc,
                deviceID,
                callbackQueue
            ) { _, inputData, inputTime, _, _ in
                let hostTimeNanoseconds: UInt64
                if inputTime.pointee.mFlags.contains(
                    .hostTimeValid
                ) {
                    hostTimeNanoseconds = Self.nanoseconds(
                        fromHostTime: inputTime.pointee.mHostTime
                    )
                } else {
                    hostTimeNanoseconds =
                        DispatchTime.now().uptimeNanoseconds
                }
                ring.enqueue(
                    audioBufferList: inputData,
                    hostTimeNanoseconds: hostTimeNanoseconds
                )
            }
        )
        guard let ioProc else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: kAudioHardwareUnspecifiedError
            )
        }
        return .init(
            id: 1,
            coreAudioValue: ioProc,
            stopDelivering: {
                ring.stop(callbackQueue: callbackQueue)
            }
        )
    }

    func startIO(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) throws {
        guard let coreAudioValue = ioProc.coreAudioValue else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: kAudioHardwareIllegalOperationError
            )
        }
        try requireSuccess(
            AudioDeviceStart(deviceID, coreAudioValue)
        )
    }

    func stopIO(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) -> OSStatus {
        guard let coreAudioValue = ioProc.coreAudioValue else {
            return kAudioHardwareIllegalOperationError
        }
        return AudioDeviceStop(deviceID, coreAudioValue)
    }

    func destroyIOProc(
        deviceID: AudioObjectID,
        ioProc: LumenSystemAudioPlaybackSuppressionIOProc
    ) -> OSStatus {
        guard let coreAudioValue = ioProc.coreAudioValue else {
            return kAudioHardwareIllegalOperationError
        }
        return AudioDeviceDestroyIOProcID(deviceID, coreAudioValue)
    }

    func destroyAggregateDevice(deviceID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    func destroyProcessTap(tapID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tapID)
    }

    private func aggregateTapUIDs(
        deviceID: AudioObjectID
    ) throws -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var retainedTapList: Unmanaged<CFArray>?
        var dataSize = UInt32(MemoryLayout.size(ofValue: retainedTapList))
        try requireSuccess(
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &retainedTapList
            )
        )
        guard let retainedTapList else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: kAudioHardwareBadPropertySizeError
            )
        }
        let tapList = retainedTapList.takeRetainedValue() as NSArray
        var tapUIDs = [String]()
        tapUIDs.reserveCapacity(tapList.count)
        for value in tapList {
            guard let tapUID = value as? String else {
                throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                    status: kAudioHardwareBadPropertySizeError
                )
            }
            tapUIDs.append(tapUID)
        }
        return tapUIDs
    }

    private func inputStreamIDs(
        deviceID: AudioObjectID
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try requireSuccess(
            AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &dataSize
            )
        )
        let elementSize = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard dataSize % elementSize == 0 else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: kAudioHardwareBadPropertySizeError
            )
        }
        let elementCount = Int(dataSize / elementSize)
        guard elementCount > 0 else {
            return []
        }
        var streamIDs = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: elementCount
        )
        var returnedDataSize = dataSize
        try streamIDs.withUnsafeMutableBufferPointer { buffer in
            try requireSuccess(
                AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &returnedDataSize,
                    buffer.baseAddress!
                )
            )
        }
        return try lumenAudioObjectIDs(
            from: streamIDs,
            returnedDataSize: returnedDataSize
        )
    }

    private func deviceBufferFrameSize(
        deviceID: AudioObjectID
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frameSize: UInt32 = 0
        var dataSize = UInt32(MemoryLayout.size(ofValue: frameSize))
        try requireSuccess(
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &frameSize
            )
        )
        return Int(frameSize)
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status == noErr else {
            throw LumenSystemAudioPlaybackSuppressionHALOperationError(
                status: status
            )
        }
    }

    private static func nanoseconds(
        fromHostTime hostTime: UInt64
    ) -> UInt64 {
        let timebase = machTimebase
        guard timebase.denom != 0 else {
            return hostTime
        }
        return UInt64(
            (Double(hostTime) * Double(timebase.numer)) /
            Double(timebase.denom)
        )
    }
}

func lumenAudioObjectIDs(
    from storage: [AudioObjectID],
    returnedDataSize: UInt32
) throws -> [AudioObjectID] {
    let elementSize = UInt32(MemoryLayout<AudioObjectID>.stride)
    guard returnedDataSize % elementSize == 0 else {
        throw LumenSystemAudioPlaybackSuppressionHALOperationError(
            status: kAudioHardwareBadPropertySizeError
        )
    }
    let returnedCount = Int(returnedDataSize / elementSize)
    guard returnedCount <= storage.count else {
        throw LumenSystemAudioPlaybackSuppressionHALOperationError(
            status: kAudioHardwareBadPropertySizeError
        )
    }
    let result = Array(storage.prefix(returnedCount))
    guard result.allSatisfy({ $0 != kAudioObjectUnknown }) else {
        throw LumenSystemAudioPlaybackSuppressionHALOperationError(
            status: kAudioHardwareBadDeviceError
        )
    }
    return result
}
