import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization
import VideoToolbox

enum LumenCaptureOutputRegistrationStage: String, Equatable, Sendable {
    case unregistered
    case screenRegistered = "screen-registered"
    case captureStarted = "capture-started"
    case stopped
}

struct LumenScreenCaptureOutputOwnership: Equatable, Sendable {
    private(set) var streamIdentity: UInt?
    private(set) var stage: LumenCaptureOutputRegistrationStage = .unregistered
    private(set) var screenSampleCount: UInt64 = 0

    mutating func registerScreenOutput(streamIdentity: UInt) {
        self.streamIdentity = streamIdentity
        stage = .screenRegistered
    }

    mutating func markCaptureStarted(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        stage = .captureStarted
    }

    mutating func recordScreenSample(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        screenSampleCount &+= 1
    }

    mutating func stop(streamIdentity: UInt) throws {
        try requireOwner(streamIdentity)
        stage = .stopped
        self.streamIdentity = nil
    }

    private func requireOwner(_ streamIdentity: UInt) throws {
        guard self.streamIdentity == streamIdentity else {
            throw LumenScreenCaptureOutputOwnershipError.streamIdentityMismatch
        }
    }
}

enum LumenScreenCaptureOutputOwnershipError: Error, Equatable {
    case streamIdentityMismatch
}

protocol LumenEncodedCaptureRuntime: AnyObject, Sendable {
    func start() async throws
    func stop() async
    /// Retire queued media and bootstrap admission ownership at a park/resume
    /// boundary while leaving capture and encoding alive.
    func resetMediaEpoch()
    func requestImmediateKeyFrame()
    func requestPeriodicKeyFrame() async -> Bool
    func resumeVideoEncodingAfterCodecAck() async -> Bool
    func setVideoBitRateKbps(_ bitrateKbps: Int) async -> Bool
    func setVideoDeliveryPolicy(
        bitrateKbps: Int,
        admissionDivisor: Int
    ) async -> Bool
    /// Reopen unchanged-content cadence after validated host input or motion.
    /// This is a source-pacer target update, not a codec/configuration reset.
    func wakeUnchangedContentCadence(sessionEpoch: UInt32) -> Bool
}

extension LumenEncodedCaptureRuntime {
    func requestPeriodicKeyFrame() async -> Bool {
        false
    }

    func setVideoBitRateKbps(_: Int) async -> Bool {
        false
    }

    func setVideoDeliveryPolicy(
        bitrateKbps _: Int,
        admissionDivisor _: Int
    ) async -> Bool {
        false
    }

    func wakeUnchangedContentCadence(sessionEpoch _: UInt32) -> Bool {
        false
    }
}

struct LumenEncodedCaptureRuntimeContext: Sendable {
    let configuration: LumenMacCaptureConfiguration
    let callbacks: LumenEncodedCaptureCallbacks
    let statisticsHandler:
        @Sendable (LumenEncodedCaptureSessionStatistics) -> Void
    let terminationHandler: @Sendable (any Error) -> Void
}

actor LumenCaptureStartFlight {
    struct Completion {
        let terminationError: (any Error)?
        let startError: (any Error)?
    }

    private var startCompleted = false
    private var startError: (any Error)?
    private var stopRequested = false
    private var settled = false
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []

    func finishStart(
        terminationError: (any Error)?,
        error: (any Error)? = nil
    ) -> Completion {
        if !startCompleted {
            startCompleted = true
            startError = error
        }
        return Completion(
            terminationError: terminationError,
            startError: startError
        )
    }

    func requestStop() {
        stopRequested = true
    }

    func isStopRequested() -> Bool {
        stopRequested
    }

    func settle() {
        guard !settled else {
            return
        }
        settled = true
        let waiters = settlementWaiters
        settlementWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func waitUntilSettled() async {
        guard !settled else {
            return
        }
        await withCheckedContinuation { continuation in
            if settled {
                continuation.resume()
            } else {
                settlementWaiters.append(continuation)
            }
        }
    }
}

final class LumenCaptureTerminationLatch: @unchecked Sendable {
    private struct State {
        var startCompleted = false
        var terminationError: (any Error)?
    }

    private let state = Mutex(State())

    func record(_ error: any Error) -> Bool {
        state.withLock { state in
            guard !state.startCompleted else {
                return false
            }
            if state.terminationError == nil {
                state.terminationError = error
            }
            return true
        }
    }

    func complete() -> (any Error)? {
        state.withLock { state in
            state.startCompleted = true
            return state.terminationError
        }
    }
}

final class LumenCaptureCallbackGate: @unchecked Sendable {
    private let accepting = Atomic(true)

    func close() {
        accepting.store(false, ordering: .releasing)
    }

    func isOpen() -> Bool {
        accepting.load(ordering: .acquiring)
    }
}

protocol LumenEncodedCaptureRuntimeFactory: Sendable {
    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime
}

struct LumenProductionCaptureRuntimeFactory:
    LumenEncodedCaptureRuntimeFactory {
    var shadowVCModelDirectory: URL? = nil
    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime {
        if context.configuration.codec == .shadowVC {
            guard #available(macOS 27, *), let shadowVCModelDirectory else {
                throw LumenExactCaptureError.invalidFormat("ShadowVC requires macOS 27 and a verified model bundle")
            }
            return LumenShadowVCCaptureRuntime(context: context, modelDirectory: shadowVCModelDirectory)
        }
        return try LumenScreenCaptureVideoRuntime(
            configuration: context.configuration,
            callbacks: context.callbacks,
            statisticsHandler: context.statisticsHandler,
            terminationHandler: context.terminationHandler
        )
    }
}

/// Safety: ScreenCaptureKit, AVFoundation, and VideoToolbox callbacks enter
/// through `queue`.
/// Mutable encode state is initialized before capture starts and is otherwise
/// read or mutated only on that serial queue. The separate `encoderQueue` owns
/// ordered synchronous C/VideoToolbox admission calls, which can block in XPC;
/// teardown drains those calls and their queued outputs before invalidation.
