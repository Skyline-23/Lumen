import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

struct LumenAudioFrame: Equatable, Sendable {
    let sequenceNumber: UInt64
    let hostTimeNanoseconds: UInt64
    let sampleRate: Int
    let channelCount: Int
    let frameCount: Int
    let pcmFloat32LE: Data
}

enum LumenAudioCaptureSessionEventKind: String, Equatable, Sendable {
    case started
    case stopped
    case restarted
    case failed
    case droppedFrame
}

struct LumenAudioCaptureSessionEvent: Equatable, Sendable {
    let kind: LumenAudioCaptureSessionEventKind
    let message: String?
    let stopStatus: Int32?
    let automaticRestartCount: UInt64?
    let sourceSequenceNumber: UInt64?

    init(
        kind: LumenAudioCaptureSessionEventKind,
        message: String? = nil,
        stopStatus: Int32? = nil,
        automaticRestartCount: UInt64? = nil,
        sourceSequenceNumber: UInt64? = nil
    ) {
        self.kind = kind
        self.message = message
        self.stopStatus = stopStatus
        self.automaticRestartCount = automaticRestartCount
        self.sourceSequenceNumber = sourceSequenceNumber
    }
}

struct LumenAudioCaptureCallbacks: Sendable {
    let frameHandler: @Sendable (LumenAudioFrame) -> Void
    let eventHandler: (@Sendable (LumenAudioCaptureSessionEvent) -> Void)?
}

protocol LumenAudioCaptureRuntime: AnyObject, Sendable {
    func start() async throws
    func stop() async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure]
}

private actor LumenSystemAudioTapCaptureRuntime: LumenAudioCaptureRuntime {
    private let configuration: LumenMacAudioCaptureConfiguration
    private let source: LumenSystemAudioPlaybackSuppression
    private let callbacks: LumenAudioCaptureCallbacks

    init(
        configuration: LumenMacAudioCaptureConfiguration,
        source: LumenSystemAudioPlaybackSuppression,
        callbacks: LumenAudioCaptureCallbacks
    ) {
        self.configuration = configuration
        self.source = source
        self.callbacks = callbacks
    }

    func start() async throws {
        do {
            try await source.activate(
                configuration: configuration,
                callbacks: callbacks
            )
        } catch let error as LumenSystemAudioPlaybackSuppressionError {
            throw LumenAudioCaptureError
                .systemAudioPlaybackSuppressionUnavailable(error)
        }
    }

    func stop() async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        return await source.deactivate()
    }
}

enum LumenSystemAudioCaptureRoute: Equatable, Sendable {
    case sharedVideoStream
    case standaloneStream

    static func resolve(
        configuration: LumenMacAudioCaptureConfiguration,
        activeVideoDisplayID: UInt32?
    ) throws -> Self {
        guard case .systemOutput(let displayID, _) = configuration.source else {
            return .standaloneStream
        }
        guard let activeVideoDisplayID else {
            return .standaloneStream
        }
        guard displayID == activeVideoDisplayID else {
            throw LumenAudioCaptureError.activeVideoDisplayMismatch(
                audioDisplayID: displayID,
                videoDisplayID: activeVideoDisplayID
            )
        }
        return .sharedVideoStream
    }
}

private actor LumenSharedSystemAudioCaptureRuntime: LumenAudioCaptureRuntime {
    private let videoSession: LumenEncodedCaptureSession
    private let configuration: LumenMacAudioCaptureConfiguration
    private let callbacks: LumenAudioCaptureCallbacks

    init(
        videoSession: LumenEncodedCaptureSession,
        configuration: LumenMacAudioCaptureConfiguration,
        callbacks: LumenAudioCaptureCallbacks
    ) {
        self.videoSession = videoSession
        self.configuration = configuration
        self.callbacks = callbacks
    }

    func start() async throws {
        try await videoSession.attachSystemAudio(
            configuration: configuration,
            callbacks: callbacks
        )
    }

    func stop() async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        return await videoSession.detachSystemAudio()
    }
}

private final class LumenAudioSequenceCounter: Sendable {
    private let value = Mutex<UInt64>(0)

    func next() -> UInt64 {
        value.withLock { value in
            value &+= 1
            return value
        }
    }
}

private actor LumenMicrophoneCaptureRuntime: LumenAudioCaptureRuntime {
    private let configuration: LumenMacAudioCaptureConfiguration
    private let callbacks: LumenAudioCaptureCallbacks
    private let engine = AVAudioEngine()
    private let sequenceNumber = LumenAudioSequenceCounter()

    init(configuration: LumenMacAudioCaptureConfiguration, callbacks: LumenAudioCaptureCallbacks) {
        self.configuration = configuration
        self.callbacks = callbacks
    }

    func start() async throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LumenAudioCaptureError.microphoneUnavailable
        }
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(configuration.sampleRate),
            channels: AVAudioChannelCount(configuration.channelCount),
            interleaved: true
        )
        guard let outputFormat,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw LumenAudioCaptureError.audioConversionUnavailable
        }
        let callbacks = callbacks
        let sequenceNumber = sequenceNumber

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(configuration.frameSize), format: inputFormat) { buffer, time in
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            do {
                try converter.convert(to: converted, from: buffer)
            } catch {
                callbacks.eventHandler?(.init(kind: .droppedFrame, message: error.localizedDescription))
                return
            }
            guard let data = converted.interleavedFloat32Data else {
                callbacks.eventHandler?(.init(kind: .droppedFrame, message: "Converted audio has no interleaved Float32 payload"))
                return
            }
            let nextSequenceNumber = sequenceNumber.next()
            callbacks.frameHandler(
                LumenAudioFrame(
                    sequenceNumber: nextSequenceNumber,
                    hostTimeNanoseconds: time.hostTime == 0 ? systemUptimeNanoseconds() : AVAudioTime.seconds(forHostTime: time.hostTime).nanoseconds,
                    sampleRate: Int(outputFormat.sampleRate),
                    channelCount: Int(outputFormat.channelCount),
                    frameCount: Int(converted.frameLength),
                    pcmFloat32LE: data
                )
            )
        }
        try engine.start()
        callbacks.eventHandler?(.init(kind: .started, message: "AVAudioEngine microphone capture started"))
    }

    func stop() async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        callbacks.eventHandler?(.init(kind: .stopped, message: "AVAudioEngine microphone capture stopped", stopStatus: 0))
        return []
    }
}

actor LumenAudioCaptureSession {
    let configuration: LumenMacAudioCaptureConfiguration
    private let sharedVideoSession: LumenEncodedCaptureSession?
    private let systemAudioPlaybackSuppression:
        LumenSystemAudioPlaybackSuppression
    private var runtime: (any LumenAudioCaptureRuntime)?
    private var startFlight: LumenCaptureStartFlight?
    private var callbackGate: LumenCaptureCallbackGate?
    private var generation: UInt64 = 0
    private var isStopping = false
    private struct RuntimeStopRecord {
        let runtime: any LumenAudioCaptureRuntime
        let task: Task<[LumenSystemAudioPlaybackSuppressionCleanupFailure], Never>
    }
    private var runtimeStopRecords: [ObjectIdentifier: RuntimeStopRecord] = [:]

    init(
        configuration: LumenMacAudioCaptureConfiguration,
        sharedVideoSession: LumenEncodedCaptureSession?,
        systemAudioPlaybackSuppression:
            LumenSystemAudioPlaybackSuppression
    ) {
        self.configuration = configuration
        self.sharedVideoSession = sharedVideoSession
        self.systemAudioPlaybackSuppression = systemAudioPlaybackSuppression
    }

    func start(callbacks: LumenAudioCaptureCallbacks) async throws {
        guard runtime == nil else {
            throw LumenAudioCaptureError.captureAlreadyRunning
        }
        callbackGate?.close()
        let gate = LumenCaptureCallbackGate()
        let flight = LumenCaptureStartFlight()
        callbackGate = gate
        startFlight = flight
        isStopping = false
        generation &+= 1
        let startGeneration = generation
        let guardedCallbacks = LumenAudioCaptureCallbacks(
            frameHandler: { frame in
                guard gate.isOpen() else { return }
                callbacks.frameHandler(frame)
            },
            eventHandler: { event in
                guard gate.isOpen() else { return }
                callbacks.eventHandler?(event)
            }
        )
        let runtime: any LumenAudioCaptureRuntime
        switch configuration.source {
        case .microphone:
            runtime = LumenMicrophoneCaptureRuntime(
                configuration: configuration,
                callbacks: guardedCallbacks
            )
        case .systemOutput:
            if let sharedVideoSession {
                runtime = LumenSharedSystemAudioCaptureRuntime(
                    videoSession: sharedVideoSession,
                    configuration: configuration,
                    callbacks: guardedCallbacks
                )
            } else {
                runtime = LumenSystemAudioTapCaptureRuntime(
                    configuration: configuration,
                    source: systemAudioPlaybackSuppression,
                    callbacks: guardedCallbacks
                )
            }
        }
        self.runtime = runtime
        var runtimeStartWasAttempted = false
        var failureHandled = false
        do {
            guard !isStopping,
                  generation == startGeneration,
                  !(await flight.isStopRequested()) else {
                failureHandled = true
                _ = await stopRuntimeAfterStartFailure(
                    runtime: runtime,
                    flight: flight,
                    gate: gate,
                    stopRuntime: true
                )
                throw LumenAudioCaptureError.captureStartCancelled
            }
            runtimeStartWasAttempted = true
            try await runtime.start()
            let completion = await flight.finishStart(terminationError: nil)
            guard !isStopping,
                  generation == startGeneration,
                  !(await flight.isStopRequested()) else {
                failureHandled = true
                _ = await stopRuntimeAfterStartFailure(
                    runtime: runtime,
                    flight: flight,
                    gate: gate,
                    stopRuntime: true
                )
                throw LumenAudioCaptureError.captureStartCancelled
            }
            _ = completion
            await finishStartFlight(flight)
        } catch {
            let completion = await flight.finishStart(
                terminationError: nil,
                error: error
            )
            if !failureHandled {
                let stopRequested = await flight.isStopRequested()
                let cleanupFailures = await stopRuntimeAfterStartFailure(
                    runtime: runtime,
                    flight: flight,
                    gate: gate,
                    stopRuntime: runtimeStartWasAttempted || stopRequested
                )
                if !cleanupFailures.isEmpty {
                    throw LumenSystemAudioCaptureLifecycleError(
                        underlyingError: completion.startError ?? error,
                        cleanupFailures: cleanupFailures
                    )
                }
            }
            throw completion.startError ?? error
        }
    }

    func stop() async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        isStopping = true
        generation &+= 1
        let inFlight = startFlight
        let runtime = self.runtime
        await inFlight?.requestStop()
        let runtimeStopTask = runtime.map { runtime in
            Task { await self.stopRuntimeOnce(runtime) }
        }
        await inFlight?.waitUntilSettled()
        let cleanupFailures = await runtimeStopTask?.value ?? []
        if cleanupFailures.isEmpty {
            self.runtime = nil
        }
        callbackGate?.close()
        return cleanupFailures
    }

    private func finishStartFlight(_ flight: LumenCaptureStartFlight) async {
        if startFlight === flight {
            startFlight = nil
        }
        await flight.settle()
    }

    private func stopRuntimeAfterStartFailure(
        runtime: any LumenAudioCaptureRuntime,
        flight: LumenCaptureStartFlight,
        gate: LumenCaptureCallbackGate,
        stopRuntime: Bool
    ) async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        var cleanupFailures: [LumenSystemAudioPlaybackSuppressionCleanupFailure] = []
        if stopRuntime {
            cleanupFailures = await stopRuntimeOnce(runtime)
        }
        gate.close()
        if cleanupFailures.isEmpty {
            self.runtime = nil
        }
        await finishStartFlight(flight)
        return cleanupFailures
    }

    private func stopRuntimeOnce(
        _ runtime: any LumenAudioCaptureRuntime
    ) async -> [LumenSystemAudioPlaybackSuppressionCleanupFailure] {
        let identity = ObjectIdentifier(runtime)
        if let existing = runtimeStopRecords[identity],
           existing.runtime === runtime {
            let failures = await existing.task.value
            if !failures.isEmpty {
                runtimeStopRecords.removeValue(forKey: identity)
            }
            return failures
        }
        let task = Task { await runtime.stop() }
        runtimeStopRecords[identity] = .init(runtime: runtime, task: task)
        let failures = await task.value
        if !failures.isEmpty {
            runtimeStopRecords.removeValue(forKey: identity)
        }
        return failures
    }
}

enum LumenAudioCaptureError: Error, LocalizedError {
    case invalidSource
    case captureAlreadyRunning
    case captureStartCancelled
    case displayUnavailable(UInt32)
    case displayOwnershipLost(UInt32)
    case activeVideoDisplayMismatch(audioDisplayID: UInt32, videoDisplayID: UInt32)
    case microphoneUnavailable
    case audioConversionUnavailable
    case unsupportedChannelConversion(source: Int, requested: Int)
    case invalidSampleBuffer
    case unsupportedPCM
    case systemAudioPlaybackSuppressionDependencyMissing
    case systemAudioPlaybackSuppressionUnavailable(
        LumenSystemAudioPlaybackSuppressionError
    )
    case systemAudioPlaybackSuppressionCancelled
    case systemAudioPlaybackSuppressionCleanupFailed(
        [LumenSystemAudioPlaybackSuppressionCleanupFailure]
    )

    var errorDescription: String? {
        switch self {
        case .invalidSource: return "Invalid audio capture source."
        case .captureAlreadyRunning: return "Audio capture is already starting or running."
        case .captureStartCancelled: return "Audio capture startup was cancelled by a newer lifecycle transition."
        case .displayUnavailable(let displayID): return "ScreenCaptureKit display \(displayID) is unavailable for audio capture."
        case .displayOwnershipLost(let displayID):
            return "Retained virtual display \(displayID) was released before audio capture could start."
        case .activeVideoDisplayMismatch(let audioDisplayID, let videoDisplayID):
            return "System audio display \(audioDisplayID) does not match active video display \(videoDisplayID)."
        case .microphoneUnavailable: return "The default microphone is unavailable."
        case .audioConversionUnavailable:
            return "The requested audio PCM conversion is unavailable."
        case let .unsupportedChannelConversion(source, requested):
            return "The system-audio source exposes \(source) channels, but the selected mode requires \(requested); automatic upmix is not permitted."
        case .invalidSampleBuffer: return "The audio sample buffer is invalid."
        case .unsupportedPCM: return "The audio sample buffer uses an unsupported PCM layout."
        case .systemAudioPlaybackSuppressionDependencyMissing:
            return "System-audio capture is missing its session playback-suppression dependency."
        case .systemAudioPlaybackSuppressionUnavailable(let error):
            return error.localizedDescription
        case .systemAudioPlaybackSuppressionCancelled:
            return "System-audio playback suppression was cancelled before the exclusive capture boundary became active."
        case .systemAudioPlaybackSuppressionCleanupFailed(let failures):
            let details = failures
                .map { "\($0.stage.rawValue)=\($0.status)" }
                .joined(separator: ",")
            return "System-audio playback suppression cleanup failed: \(details)."
        }
    }
}

private func systemUptimeNanoseconds() -> UInt64 {
    ProcessInfo.processInfo.systemUptime.nanoseconds
}

private extension Double {
    var nanoseconds: UInt64 { UInt64(max(self, 0) * 1_000_000_000) }
}

private extension AVAudioPCMBuffer {
    var interleavedFloat32Data: Data? {
        guard format.commonFormat == .pcmFormatFloat32,
              format.isInterleaved,
              let audioBuffer = mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        return Data(bytes: audioBuffer, count: Int(mutableAudioBufferList.pointee.mBuffers.mDataByteSize))
    }
}
