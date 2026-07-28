import XCTest
@testable import LumenMacBridge

final class LumenScreenCaptureCallbackBoundaryTests: XCTestCase {
    func testCallbackCompletedAtDeadlineIsAcceptedAfterResolverWakeup() async throws {
        let clock = DisplayReadinessBoundaryNowControl()
        let queries = DisplayReadinessQueryControl<UInt32>()
        let budget = LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 1)
        let task = Task.detached { @Sendable in
            try await LumenScreenCaptureDisplayResolver.resolve(
                displayID: 22,
                authority: .retained(ownerToken: 7),
                timing: .init(
                    overallDeadlineNanoseconds: 10,
                    queryTimeoutNanoseconds: 5,
                    retryDelayNanoseconds: 1,
                    maximumOutstandingQueries: 1
                ),
                queryBudget: budget,
                environment: .init(
                    now: { await clock.now() },
                    sleepUntil: { _ in },
                    readiness: {
                        .init(
                            ownerToken: 7,
                            isOnline: true,
                            isActive: true,
                            hasCurrentMode: true
                        )
                    },
                    stampedLookup: { generation in
                        let value = await queries.lookup(generation: generation)
                        return LumenScreenCaptureQueryCompletion(
                            value: value,
                            completedAtNanoseconds: 10
                        )
                    }
                )
            )
        }
        defer { task.cancel() }

        try await queries.waitForQuery(generation: 1)
        try await clock.waitUntilBoundaryCheckIsBlocked()
        await queries.complete(generation: 1, value: 22)
        try await waitForDisplayReadinessCondition("stamped callback publication") {
            await budget.outstandingCount() == 0
        }

        // The SCK callback met the absolute deadline. The resolver actor wakes
        // afterward, so admission must use the callback timestamp rather than
        // the delayed task-resumption timestamp.
        await clock.releaseBoundaryCheck()
        let resolved = try await task.value
        XCTAssertEqual(resolved, 22)
    }
}

private actor DisplayReadinessBoundaryNowControl {
    private var calls = 0
    private var boundaryCheckIsBlocked = false
    private var boundaryContinuation: CheckedContinuation<Void, Never>?

    func now() async -> UInt64 {
        calls += 1
        if calls == 4 {
            boundaryCheckIsBlocked = true
            await withCheckedContinuation { continuation in
                boundaryContinuation = continuation
            }
        }
        switch calls {
        case 1, 2:
            return 0
        case 3:
            return 6
        default:
            return 11
        }
    }

    func waitUntilBoundaryCheckIsBlocked() async throws {
        try await waitForDisplayReadinessCondition("deadline boundary check") {
            await self.boundaryCheckIsBlocked
        }
    }

    func releaseBoundaryCheck() {
        boundaryContinuation?.resume()
        boundaryContinuation = nil
    }
}
