import Synchronization

/// Coalesces the hot native-input wake path without blocking the input thread.
///
/// Active generation, opaque session epoch, and pending state share one atomic
/// word. A stale producer therefore cannot publish over a newer activation.
final class LumenUnchangedContentCadenceWakeRelay: Sendable {
    private static let pendingMask: UInt64 = 1
    private static let epochShift: UInt64 = 1
    private static let generationShift: UInt64 = 33
    private static let generationMask: UInt64 = 0x7FFF_FFFF

    private let activationCounter = Atomic<UInt64>(0)
    private let state = Atomic<UInt64>(0)
    private let workerScheduled = Atomic(false)

    func activate(sessionEpoch: UInt32) {
        state.store(
            Self.makeState(
                generation: nextActivationGeneration(),
                sessionEpoch: sessionEpoch,
                pending: false
            ),
            ordering: .releasing
        )
    }

    func deactivate() {
        state.store(0, ordering: .releasing)
    }

    func schedule(
        sessionEpoch: UInt32,
        operation: @escaping @Sendable (UInt64, UInt32) async -> Void
    ) -> Bool {
        while true {
            let observed = state.load(ordering: .acquiring)
            guard Self.generation(from: observed) != 0,
                  Self.sessionEpoch(from: observed) == sessionEpoch else {
                return false
            }
            if Self.isPending(observed) {
                break
            }
            let published = state.compareExchange(
                expected: observed,
                desired: observed | Self.pendingMask,
                successOrdering: .acquiringAndReleasing,
                failureOrdering: .acquiring
            )
            if published.exchanged {
                break
            }
        }

        guard !workerScheduled.exchange(
            true,
            ordering: .acquiringAndReleasing
        ) else {
            return true
        }

        Task { [self] in
            await drain(operation: operation)
        }
        return true
    }

    func isActive(generation: UInt64, sessionEpoch: UInt32) -> Bool {
        let observed = state.load(ordering: .acquiring)
        return Self.generation(from: observed) == generation &&
            Self.sessionEpoch(from: observed) == sessionEpoch
    }

    private func nextActivationGeneration() -> UInt64 {
        while true {
            let observed = activationCounter.load(ordering: .acquiring)
            let desired = observed >= Self.generationMask ? 1 : observed + 1
            let exchanged = activationCounter.compareExchange(
                expected: observed,
                desired: desired,
                successOrdering: .acquiringAndReleasing,
                failureOrdering: .acquiring
            )
            if exchanged.exchanged {
                return desired
            }
        }
    }

    private func drain(
        operation: @escaping @Sendable (UInt64, UInt32) async -> Void
    ) async {
        while true {
            var claimedState: UInt64 = 0
            while true {
                let observed = state.load(ordering: .acquiring)
                guard Self.isPending(observed) else {
                    break
                }
                let claimed = state.compareExchange(
                    expected: observed,
                    desired: observed & ~Self.pendingMask,
                    successOrdering: .acquiringAndReleasing,
                    failureOrdering: .acquiring
                )
                if claimed.exchanged {
                    claimedState = observed
                    break
                }
            }
            if claimedState != 0 {
                await operation(
                    Self.generation(from: claimedState),
                    Self.sessionEpoch(from: claimedState)
                )
            }

            workerScheduled.store(false, ordering: .releasing)
            guard Self.isPending(state.load(ordering: .acquiring)) else {
                return
            }
            let reclaimed = workerScheduled.compareExchange(
                expected: false,
                desired: true,
                successOrdering: .acquiringAndReleasing,
                failureOrdering: .acquiring
            )
            guard reclaimed.exchanged else {
                return
            }
        }
    }

    private static func makeState(
        generation: UInt64,
        sessionEpoch: UInt32,
        pending: Bool
    ) -> UInt64 {
        ((generation & generationMask) << generationShift) |
            (UInt64(sessionEpoch) << epochShift) |
            (pending ? pendingMask : 0)
    }

    private static func generation(from state: UInt64) -> UInt64 {
        state >> generationShift
    }

    private static func sessionEpoch(from state: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: state >> epochShift)
    }

    private static func isPending(_ state: UInt64) -> Bool {
        state & pendingMask != 0
    }
}
