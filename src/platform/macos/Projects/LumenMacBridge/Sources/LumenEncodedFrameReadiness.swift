import Foundation

public enum LumenFirstEncodedFrameReadinessError: Error, Equatable, LocalizedError, Sendable {
    case captureNotRunning
    case captureSuperseded
    case captureStopped
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .captureNotRunning: return "No encoded capture is running."
        case .captureSuperseded: return "A newer encoded capture superseded this wait."
        case .captureStopped: return "Encoded capture stopped before a matching frame arrived."
        case .timedOut: return "Timed out waiting for a successful encoded frame."
        }
    }
}

actor LumenFirstEncodedFrameGate {
    private struct Waiter {
        let generation: UInt64
        let sequenceNumber: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var generation: UInt64 = 0
    private var isActive = false
    private var latestSequenceNumber: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]

    func beginCapture() -> UInt64 {
        resumeAll(with: LumenFirstEncodedFrameReadinessError.captureSuperseded)
        generation &+= 1
        if generation == 0 { generation = 1 }
        isActive = true
        latestSequenceNumber = 0
        return generation
    }

    func resolve(generation: UInt64, sequenceNumber: UInt64? = nil) {
        guard isActive, generation == self.generation else { return }
        let resolvedSequenceNumber = sequenceNumber ?? (latestSequenceNumber &+ 1)
        latestSequenceNumber = max(latestSequenceNumber, resolvedSequenceNumber)
        let readyIDs = waiters.compactMap { id, waiter in
            waiter.generation == generation && latestSequenceNumber > waiter.sequenceNumber ? id : nil
        }
        for id in readyIDs {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func stop(generation: UInt64) {
        guard generation == self.generation else { return }
        isActive = false
        resumeAll(with: LumenFirstEncodedFrameReadinessError.captureStopped)
    }

    func wait(
        for generation: UInt64,
        after sequenceNumber: UInt64 = 0,
        timeoutNanoseconds: UInt64
    ) async throws {
        guard isActive else {
            throw LumenFirstEncodedFrameReadinessError.captureNotRunning
        }
        guard generation == self.generation else {
            throw LumenFirstEncodedFrameReadinessError.captureSuperseded
        }
        if latestSequenceNumber > sequenceNumber { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = Waiter(
                    generation: generation,
                    sequenceNumber: sequenceNumber,
                    continuation: continuation
                )
                Task {
                    try? await Task.sleep(nanoseconds: max(timeoutNanoseconds, 1))
                    self.expire(id: id)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func expire(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: LumenFirstEncodedFrameReadinessError.timedOut
        )
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func resumeAll(with error: Error) {
        let pending = waiters.values
        waiters.removeAll(keepingCapacity: true)
        for waiter in pending {
            waiter.continuation.resume(throwing: error)
        }
    }
}
