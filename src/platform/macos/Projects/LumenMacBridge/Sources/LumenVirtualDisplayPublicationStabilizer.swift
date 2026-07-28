struct LumenMacVirtualDisplayPublicationTiming: Equatable, Sendable {
    let overallDeadlineNanoseconds: UInt64
    let stableWindowNanoseconds: UInt64
    let pollNanoseconds: UInt64

    static let production = Self(
        overallDeadlineNanoseconds: 8_000_000_000,
        // Mode publication can enqueue a later independent-output change.
        // Hold the exact retained display at its content-specific safety boundary
        // until the published state remains quiet.
        stableWindowNanoseconds: 3_000_000_000,
        pollNanoseconds: 50_000_000
    )
}

// The established test seam keeps its descriptive name and injected clock contract.
// swiftlint:disable:next type_name
enum LumenMacVirtualDisplayPublicationStabilizer {
    typealias MonotonicNow = @Sendable () async -> UInt64
    typealias MonotonicSleep = @Sendable (UInt64) async throws -> Void
    typealias Snapshot = @Sendable () async -> LumenCaptureDisplayReadinessSnapshot

    // Six explicit arguments are retained as the established deterministic test seam.
    // swiftlint:disable:next function_parameter_count
    static func wait(
        displayID: UInt32,
        expectedOwnerToken: UInt,
        timing: LumenMacVirtualDisplayPublicationTiming,
        now: @escaping MonotonicNow,
        sleepUntil: @escaping MonotonicSleep,
        snapshot: @escaping Snapshot
    ) async throws {
        try await waitForStableSnapshot(
            expectedOwnerToken: expectedOwnerToken,
            timing: timing,
            unavailableError: .virtualDisplayPublicationUnavailable(displayID),
            now: now,
            sleepUntil: sleepUntil,
            snapshot: snapshot,
            isReady: {
                $0.isModeReady(for: .retained(ownerToken: expectedOwnerToken))
            }
        )
    }

    // Six explicit arguments are retained as the established deterministic test seam.
    // swiftlint:disable:next function_parameter_count
    static func waitForModeSettlement(
        displayID: UInt32,
        expectedOwnerToken: UInt,
        timing: LumenMacVirtualDisplayPublicationTiming,
        now: @escaping MonotonicNow,
        sleepUntil: @escaping MonotonicSleep,
        snapshot: @escaping Snapshot
    ) async throws {
        try await waitForStableSnapshot(
            expectedOwnerToken: expectedOwnerToken,
            timing: timing,
            unavailableError: .virtualDisplayModeSettlementUnavailable(displayID),
            now: now,
            sleepUntil: sleepUntil,
            snapshot: snapshot,
            isReady: {
                // CGVirtualDisplay can hold its accepted mode while the output
                // is not yet part of the public active topology. Stabilize that
                // retained contract before the separate activation transaction.
                $0.hasCurrentMode ||
                    ($0.pixelWidth > 0 && $0.pixelHeight > 0) ||
                    (
                        $0.configuredPixelWidth > 0 &&
                            $0.configuredPixelHeight > 0
                    )
            }
        )
    }

    // The predicate is deliberately injected with the clock and snapshot seam.
    // swiftlint:disable:next function_parameter_count
    private static func waitForStableSnapshot(
        expectedOwnerToken: UInt,
        timing: LumenMacVirtualDisplayPublicationTiming,
        unavailableError: LumenMacWorkspaceSessionError,
        now: @escaping MonotonicNow,
        sleepUntil: @escaping MonotonicSleep,
        snapshot: @escaping Snapshot,
        isReady: @escaping @Sendable (LumenCaptureDisplayReadinessSnapshot) -> Bool
    ) async throws {
        let startedAt = await now()
        let deadline = addingClamped(startedAt, timing.overallDeadlineNanoseconds)
        var stableSnapshot: LumenCaptureDisplayReadinessSnapshot?
        var stableSince: UInt64?

        while true {
            try Task.checkCancellation()
            let currentTime = await now()
            guard currentTime <= deadline else {
                throw unavailableError
            }

            let currentSnapshot = await snapshot()
            guard currentSnapshot.ownerToken == expectedOwnerToken else {
                throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
            }

            if isReady(currentSnapshot) {
                if stableSnapshot != currentSnapshot {
                    stableSnapshot = currentSnapshot
                    stableSince = currentTime
                }
                if let stableSince,
                   currentTime >= stableSince,
                   currentTime - stableSince >= timing.stableWindowNanoseconds {
                    return
                }
            } else {
                stableSnapshot = nil
                stableSince = nil
            }

            guard currentTime < deadline else {
                throw unavailableError
            }
            let pollDeadline = addingClamped(currentTime, timing.pollNanoseconds)
            let stableDeadline = stableSince.map {
                addingClamped($0, timing.stableWindowNanoseconds)
            } ?? UInt64.max
            try await sleepUntil(min(pollDeadline, stableDeadline, deadline))
        }
    }

    private static func addingClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }
}
