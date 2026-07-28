import CoreGraphics
import Foundation

protocol LumenDisplayReconfigurationObserving: Sendable {
    func generation(for displayID: UInt32) async -> UInt64
    func waitForPostChange(
        displayID: UInt32,
        after generation: UInt64,
        timeoutNanoseconds: UInt64
    ) async throws
}

enum LumenDisplayReconfigurationObservationError: Error, Equatable {
    case registrationFailed(Int32)
    case timedOut(UInt32)
}

actor LumenDisplayReconfigurationEventHub {
    private struct Waiter {
        let displayID: UInt32
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var generations: [UInt32: UInt64] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledWaiters: Set<UUID> = []

    func generation(for displayID: UInt32) -> UInt64 {
        generations[displayID, default: 0]
    }

    func publish(displayID: UInt32, flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else {
            return
        }
        let generation = generations[displayID, default: 0] &+ 1
        generations[displayID] = generation
        let completed = waiters.filter { _, waiter in
            waiter.displayID == displayID && generation > waiter.generation
        }
        for (id, waiter) in completed {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    func wait(
        id: UUID,
        displayID: UInt32,
        after generation: UInt64,
        timeoutNanoseconds: UInt64
    ) async throws {
        if self.generation(for: displayID) > generation {
            return
        }
        if cancelledWaiters.remove(id) != nil {
            throw CancellationError()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(
                    displayID: displayID,
                    generation: generation,
                    continuation: continuation
                )
                Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self.timeout(id: id, displayID: displayID)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            cancelledWaiters.insert(id)
            return
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func timeout(id: UUID, displayID: UInt32) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return
        }
        waiter.continuation.resume(
            throwing: LumenDisplayReconfigurationObservationError.timedOut(
                displayID
            )
        )
    }
}

private final class LumenDisplayReconfigurationCallbackBridge: @unchecked Sendable {
    let hub: LumenDisplayReconfigurationEventHub
    private(set) var registrationResult: CGError = .failure

    init(hub: LumenDisplayReconfigurationEventHub) {
        self.hub = hub
        registrationResult = CGDisplayRegisterReconfigurationCallback(
            lumenDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        guard registrationResult == .success else {
            return
        }
        CGDisplayRemoveReconfigurationCallback(
            lumenDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}

private func lumenDisplayReconfigurationCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else {
        return
    }
    let hub = Unmanaged<LumenDisplayReconfigurationCallbackBridge>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
        .hub
    Task {
        await hub.publish(displayID: displayID, flags: flags)
    }
}

final class LumenCoreGraphicsDisplayReconfigurationObserver:
    LumenDisplayReconfigurationObserving,
    @unchecked Sendable
{
    private let hub = LumenDisplayReconfigurationEventHub()
    private let bridge: LumenDisplayReconfigurationCallbackBridge

    init() {
        bridge = LumenDisplayReconfigurationCallbackBridge(hub: hub)
    }

    func generation(for displayID: UInt32) async -> UInt64 {
        await hub.generation(for: displayID)
    }

    func waitForPostChange(
        displayID: UInt32,
        after generation: UInt64,
        timeoutNanoseconds: UInt64
    ) async throws {
        guard bridge.registrationResult == .success else {
            throw LumenDisplayReconfigurationObservationError
                .registrationFailed(bridge.registrationResult.rawValue)
        }
        let id = UUID()
        try await hub.wait(
            id: id,
            displayID: displayID,
            after: generation,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }
}

struct LumenImmediateDisplayReconfigurationObserver:
    LumenDisplayReconfigurationObserving
{
    func generation(for displayID: UInt32) async -> UInt64 { 0 }

    func waitForPostChange(
        displayID: UInt32,
        after generation: UInt64,
        timeoutNanoseconds: UInt64
    ) async throws {}
}
