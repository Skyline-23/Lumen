import XCTest
@testable import LumenMacBridge

enum DisplayReadinessTestError: Error {
    case timedOut(String)
}

actor DisplayReadinessVirtualClock {
    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private var time: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]

    func currentTime() -> UInt64 {
        time
    }

    func sleep(until deadline: UInt64) async {
        guard deadline > time else { return }
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard deadline > time else {
                    continuation.resume()
                    return
                }
                waiters[identifier] = Waiter(
                    deadline: deadline,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(identifier) }
        }
    }

    func advance(to newTime: UInt64) {
        time = max(time, newTime)
        let ready = waiters.filter { $0.value.deadline <= time }
        for (identifier, waiter) in ready {
            waiters.removeValue(forKey: identifier)
            waiter.continuation.resume()
        }
    }

    func waitForSleeper(at deadline: UInt64, count: Int = 1) async throws {
        let expectedCount = max(count, 1)
        let clock = ContinuousClock()
        let timeout = clock.now.advanced(by: .seconds(2))
        while waiterCount(deadline: deadline) < expectedCount {
            guard clock.now < timeout else {
                throw DisplayReadinessTestError.timedOut(
                    "virtual sleeper at \(deadline)"
                )
            }
            await Task.yield()
        }
    }

    private func cancel(_ identifier: UUID) {
        waiters.removeValue(forKey: identifier)?.continuation.resume()
    }

    private func waiterCount(deadline: UInt64) -> Int {
        waiters.values.filter { $0.deadline == deadline }.count
    }
}

actor DisplayReadinessQueryControl<Value: Sendable> {
    private let honorsCancellation: Bool
    private var pending: [UInt64: CheckedContinuation<Value?, Never>] = [:]
    private var generations: [UInt64] = []

    init(honorsCancellation: Bool = false) {
        self.honorsCancellation = honorsCancellation
    }

    func lookup(generation: UInt64) async -> Value? {
        generations.append(generation)
        let honorsCancellation = self.honorsCancellation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if honorsCancellation && Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    pending[generation] = continuation
                }
            }
        } onCancel: {
            guard honorsCancellation else { return }
            Task { await self.cancel(generation: generation) }
        }
    }

    func waitForQuery(generation: UInt64) async throws {
        let clock = ContinuousClock()
        let timeout = clock.now.advanced(by: .seconds(2))
        while pending[generation] == nil {
            guard clock.now < timeout else {
                throw DisplayReadinessTestError.timedOut(
                    "display query generation \(generation)"
                )
            }
            await Task.yield()
        }
    }

    func complete(generation: UInt64, value: Value?) {
        pending.removeValue(forKey: generation)?.resume(returning: value)
    }

    func startedGenerations() -> [UInt64] {
        generations
    }

    private func cancel(generation: UInt64) {
        pending.removeValue(forKey: generation)?.resume(returning: nil)
    }
}

actor DisplayReadinessState {
    private var ownerToken: UInt?
    private var isOnline: Bool
    private var isActive: Bool
    private var hasCurrentMode: Bool
    private var pixelWidth: Int
    private var pixelHeight: Int
    private var configuredPixelWidth: Int
    private var configuredPixelHeight: Int

    init(ownerToken: UInt?, modeReady: Bool) {
        self.ownerToken = ownerToken
        isOnline = modeReady
        isActive = modeReady
        hasCurrentMode = modeReady
        pixelWidth = 0
        pixelHeight = 0
        configuredPixelWidth = 0
        configuredPixelHeight = 0
    }

    func snapshot() -> LumenCaptureDisplayReadinessSnapshot {
        .init(
            ownerToken: ownerToken,
            isOnline: isOnline,
            isActive: isActive,
            hasCurrentMode: hasCurrentMode,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            configuredPixelWidth: configuredPixelWidth,
            configuredPixelHeight: configuredPixelHeight
        )
    }

    func replaceOwner(with ownerToken: UInt?) {
        self.ownerToken = ownerToken
    }

    func publishRetainedConfiguredGeometry(width: Int, height: Int) {
        isOnline = true
        isActive = true
        hasCurrentMode = false
        pixelWidth = 0
        pixelHeight = 0
        configuredPixelWidth = width
        configuredPixelHeight = height
    }
}

actor DisplayReadinessCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

func waitForDisplayReadinessCondition(
    _ description: String,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let timeout = clock.now.advanced(by: .seconds(2))
    while clock.now < timeout {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw DisplayReadinessTestError.timedOut(description)
}

actor DisplayReadinessNowControl {
    private let blockingCall: Int
    private var calls = 0
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockingCall: Int) {
        self.blockingCall = blockingCall
    }

    func now() async -> UInt64 {
        calls += 1
        if calls == blockingCall {
            blocked = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return 0
    }

    func waitUntilBlocked() async throws {
        let clock = ContinuousClock()
        let timeout = clock.now.advanced(by: .seconds(2))
        while !blocked {
            guard clock.now < timeout else {
                throw DisplayReadinessTestError.timedOut(
                    "query winner publication boundary"
                )
            }
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
