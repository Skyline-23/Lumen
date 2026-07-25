import CoreGraphics
import CoreMedia
import CoreVideo
@testable import LumenMacBridge
import XCTest

actor LumenMac444CaptureRuntimeStartGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

actor LumenMac444CaptureRuntimeStartedLatch {
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

final class LumenMac444CaptureEventRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.mac444-event-recorder"
    )
    private var events: [LumenEncodedCaptureSessionEvent] = []

    func append(_ event: LumenEncodedCaptureSessionEvent) {
        queue.sync {
            events.append(event)
        }
    }

    var snapshot: [LumenEncodedCaptureSessionEvent] {
        queue.sync { events }
    }
}

final class LumenMac444CaptureRuntimeFactory:
    LumenEncodedCaptureRuntimeFactory,
    @unchecked Sendable {
    private struct State {
        var makeCount = 0
        var startCounts: [Int: Int] = [:]
        var stopCounts: [Int: Int] = [:]
        var contexts: [Int: LumenEncodedCaptureRuntimeContext] = [:]
        var runningRuntimeIDs: Set<Int> = []
    }

    private let queue = DispatchQueue(
        label: "dev.skyline23.lumen.tests.mac444-runtime-factory"
    )
    private let replacementStartGate: LumenMac444CaptureRuntimeStartGate
    private let gatedRuntimeID: Int?
    private let replacementStartEntered: @Sendable () -> Void
    private let runtimeStartCompleted: @Sendable () -> Void
    private let runtimeCreated: @Sendable (Int) -> Void
    private let lateStartedRuntimeStopped: @Sendable () -> Void
    private let runtimeStartedLatch =
        LumenMac444CaptureRuntimeStartedLatch()
    private var state = State()

    init(
        gatedRuntimeID: Int? = 2,
        replacementStartGate: LumenMac444CaptureRuntimeStartGate,
        replacementStartEntered: @escaping @Sendable () -> Void,
        runtimeStartCompleted: @escaping @Sendable () -> Void = {},
        runtimeCreated: @escaping @Sendable (Int) -> Void = { _ in },
        lateStartedRuntimeStopped: @escaping @Sendable () -> Void = {}
    ) {
        self.gatedRuntimeID = gatedRuntimeID
        self.replacementStartGate = replacementStartGate
        self.replacementStartEntered = replacementStartEntered
        self.runtimeStartCompleted = runtimeStartCompleted
        self.runtimeCreated = runtimeCreated
        self.lateStartedRuntimeStopped = lateStartedRuntimeStopped
    }

    var makeCount: Int {
        queue.sync { state.makeCount }
    }

    func startCount(for runtimeID: Int) -> Int {
        queue.sync { state.startCounts[runtimeID, default: 0] }
    }

    func stopCount(for runtimeID: Int) -> Int {
        queue.sync { state.stopCounts[runtimeID, default: 0] }
    }

    func isRunning(runtimeID: Int) -> Bool {
        queue.sync { state.runningRuntimeIDs.contains(runtimeID) }
    }

    func makeRuntime(
        context: LumenEncodedCaptureRuntimeContext
    ) throws -> any LumenEncodedCaptureRuntime {
        let runtimeID = queue.sync {
            state.makeCount += 1
            state.contexts[state.makeCount] = context
            return state.makeCount
        }
        runtimeCreated(runtimeID)
        return LumenMac444CaptureRuntime(runtimeID: runtimeID, factory: self)
    }

    func terminate(
        runtimeID: Int,
        error: LumenMac444CaptureRuntimeError = .terminated
    ) {
        let handler = queue.sync { state.contexts[runtimeID]?.terminationHandler }
        handler?(error)
    }

    func emitLateStartedEvent(runtimeID: Int) {
        let handler = queue.sync { state.contexts[runtimeID]?.callbacks.eventHandler }
        handler?(.init(kind: .started, message: "late-started"))
    }

    fileprivate func start(runtimeID: Int) async {
        queue.sync {
            state.startCounts[runtimeID, default: 0] += 1
        }
        if runtimeID == gatedRuntimeID {
            replacementStartEntered()
            await replacementStartGate.wait()
        }
        _ = queue.sync {
            state.runningRuntimeIDs.insert(runtimeID)
        }
        await runtimeStartedLatch.markStarted(runtimeID: runtimeID)
        if runtimeID == gatedRuntimeID {
            runtimeStartCompleted()
        }
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
        let wasRunning = queue.sync {
            state.stopCounts[runtimeID, default: 0] += 1
            return state.runningRuntimeIDs.remove(runtimeID) != nil
        }
        if runtimeID > 1, wasRunning {
            lateStartedRuntimeStopped()
        }
    }
}

final class LumenMac444CaptureRuntime:
    LumenEncodedCaptureRuntime,
    @unchecked Sendable {
    private let runtimeID: Int
    private let factory: LumenMac444CaptureRuntimeFactory

    init(runtimeID: Int, factory: LumenMac444CaptureRuntimeFactory) {
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

enum LumenMac444CaptureRuntimeError: Error {
    case terminated
    case originalTermination
    case replacementTermination
    case startupTermination
}
