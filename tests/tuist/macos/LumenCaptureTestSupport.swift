@testable import LumenMacBridge
import CoreMedia
import Dispatch
import Foundation

enum LumenConcurrentCaptureStartupTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "test failure"
    }
}

final class LumenEncoderSubmissionRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.tests.encoder-recorder")
    private var values: [Int] = []
    private var invalidated = false

    func append(_ value: Int) {
        queue.sync {
            values.append(value)
        }
    }

    var snapshot: [Int] {
        queue.sync {
            values
        }
    }

    func markInvalidated() {
        queue.sync {
            invalidated = true
        }
    }

    var isInvalidated: Bool {
        queue.sync {
            invalidated
        }
    }
}

final class LumenEncoderCapacityGate: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.encoder-capacity"
    )
    private var available: Bool

    init(available: Bool) {
        self.available = available
    }

    func setAvailable(_ available: Bool) {
        queue.sync {
            self.available = available
        }
    }

    var isAvailable: Bool {
        queue.sync {
            available
        }
    }
}

final class LumenStopLifecycleRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.skyline23.lumen.tests.stop-recorder")
    private var values: [String] = []

    func append(_ value: String) {
        queue.sync {
            values.append(value)
        }
    }

    var snapshot: [String] {
        queue.sync {
            values
        }
    }
}

final class LumenEncodedCaptureEventRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.capture-event-recorder"
    )
    private var events: [LumenEncodedCaptureSessionEvent] = []

    func append(_ event: LumenEncodedCaptureSessionEvent) {
        queue.sync {
            events.append(event)
        }
    }

    var snapshot: [LumenEncodedCaptureSessionEvent] {
        queue.sync {
            events
        }
    }
}

final class LumenReentrantTerminationRuntimeFactory:
    LumenEncodedCaptureRuntimeFactory,
    @unchecked Sendable {
    static let completeFramesFailureStatus = OSStatus(-12903)

    private struct State {
        var makeCount = 0
        var startCounts: [Int: Int] = [:]
        var stopCounts: [Int: Int] = [:]
        var contexts: [Int: LumenEncodedCaptureRuntimeContext] = [:]
        var didEmitTeardownFailure = false
        var runningRuntimeIDs: Set<Int> = []
    }

    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.reentrant-runtime-factory"
    )
    private let replacementStarted: @Sendable () -> Void
    private let replacementStartGate: LumenCaptureRuntimeStartGate?
    private let lateStartedRuntimeStopped: @Sendable () -> Void
    private let runtimeStartedLatch = LumenCaptureRuntimeStartedLatch()
    private var state = State()

    init(
        replacementStarted: @escaping @Sendable () -> Void,
        replacementStartGate: LumenCaptureRuntimeStartGate? = nil,
        lateStartedRuntimeStopped: @escaping @Sendable () -> Void = {}
    ) {
        self.replacementStarted = replacementStarted
        self.replacementStartGate = replacementStartGate
        self.lateStartedRuntimeStopped = lateStartedRuntimeStopped
    }

    var makeCount: Int {
        queue.sync {
            state.makeCount
        }
    }

    func startCount(for runtimeID: Int) -> Int {
        queue.sync {
            state.startCounts[runtimeID, default: 0]
        }
    }

    func stopCount(for runtimeID: Int) -> Int {
        queue.sync {
            state.stopCounts[runtimeID, default: 0]
        }
    }

    func isRunning(runtimeID: Int) -> Bool {
        queue.sync {
            state.runningRuntimeIDs.contains(runtimeID)
        }
    }

    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime {
        let runtimeID = queue.sync {
            state.makeCount += 1
            let runtimeID = state.makeCount
            state.contexts[runtimeID] = context
            return runtimeID
        }
        return LumenReentrantTerminationRuntime(
            runtimeID: runtimeID,
            factory: self
        )
    }

    func terminateOriginalRuntime() {
        let handler = queue.sync {
            state.contexts[1]?.terminationHandler
        }
        handler?(LumenCaptureRecoveryTestError.originalTermination)
    }

    fileprivate func start(runtimeID: Int) async {
        queue.sync {
            state.startCounts[runtimeID, default: 0] += 1
        }
        if runtimeID > 1 {
            replacementStarted()
            if let replacementStartGate {
                await replacementStartGate.wait()
            }
        }
        _ = queue.sync {
            state.runningRuntimeIDs.insert(runtimeID)
        }
        await runtimeStartedLatch.markStarted(runtimeID: runtimeID)
    }

    fileprivate func stop(runtimeID: Int) async {
        let mustWaitForStartedRuntime = queue.sync {
            state.startCounts[runtimeID, default: 0] > 0 &&
                !state.runningRuntimeIDs.contains(runtimeID)
        }
        if mustWaitForStartedRuntime {
            await runtimeStartedLatch.waitUntilStarted(
                runtimeID: runtimeID
            )
        }
        let (
            failureContext,
            stoppedRunningRuntime
        ): (LumenEncodedCaptureRuntimeContext?, Bool) = queue.sync {
            state.stopCounts[runtimeID, default: 0] += 1
            let stoppedRunningRuntime =
                state.runningRuntimeIDs.remove(runtimeID) != nil
            guard runtimeID == 1,
                  !state.didEmitTeardownFailure else {
                return (nil, stoppedRunningRuntime)
            }
            state.didEmitTeardownFailure = true
            return (state.contexts[runtimeID], stoppedRunningRuntime)
        }
        if runtimeID > 1, stoppedRunningRuntime {
            lateStartedRuntimeStopped()
        }
        guard let failureContext else {
            return
        }

        let error = LumenScreenCaptureError
            .compressionFrameCompletionFailed(
                Self.completeFramesFailureStatus
            )
        failureContext.callbacks.eventHandler?(.init(
            kind: .failed,
            message: error.localizedDescription,
            stopStatus: Self.completeFramesFailureStatus
        ))
        failureContext.terminationHandler(error)
        for _ in 0..<256 {
            await Task.yield()
        }
    }
}

final class LumenReentrantTerminationRuntime:
    LumenEncodedCaptureRuntime,
    @unchecked Sendable {
    private let runtimeID: Int
    private let factory: LumenReentrantTerminationRuntimeFactory

    init(
        runtimeID: Int,
        factory: LumenReentrantTerminationRuntimeFactory
    ) {
        self.runtimeID = runtimeID
        self.factory = factory
    }

    func start() async throws {
        await factory.start(runtimeID: runtimeID)
    }

    func stop() async {
        await factory.stop(runtimeID: runtimeID)
    }

    func requestImmediateKeyFrame() {}

    func resumeVideoEncodingAfterCodecAck() async -> Bool {
        true
    }
}

enum LumenCaptureRecoveryTestError: Error {
    case originalTermination
}

actor LumenCaptureRuntimeStartedLatch {
    private var startedRuntimeIDs: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func markStarted(runtimeID: Int) {
        startedRuntimeIDs.insert(runtimeID)
        let continuations = waiters.removeValue(forKey: runtimeID) ?? []
        continuations.forEach { $0.resume() }
    }

    func waitUntilStarted(runtimeID: Int) async {
        guard !startedRuntimeIDs.contains(runtimeID) else {
            return
        }
        await withCheckedContinuation { continuation in
            if startedRuntimeIDs.contains(runtimeID) {
                continuation.resume()
            } else {
                waiters[runtimeID, default: []].append(continuation)
            }
        }
    }
}

actor LumenCaptureRuntimeStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

enum LumenCaptureStartupOrderEvent: Equatable {
    case videoStarted
    case videoReady
    case audioScheduled
}

actor LumenCaptureStartupOrderProbe {
    private(set) var events: [LumenCaptureStartupOrderEvent] = []

    func append(_ event: LumenCaptureStartupOrderEvent) {
        events.append(event)
    }
}
