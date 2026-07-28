import XCTest
@testable import LumenMacBridge

final class LumenScreenCaptureDisplayReadinessTests: XCTestCase {
    func testProductionQueryOrderWaitsForCompletionBeforeNextGeneration() async throws {
        let clock = DisplayReadinessVirtualClock()
        let queries = DisplayReadinessQueryControl<UInt32>()
        let timing = LumenScreenCaptureDisplayReadinessTiming(
            overallDeadlineNanoseconds: 30,
            queryTimeoutNanoseconds: 5,
            retryDelayNanoseconds: 1,
            maximumOutstandingQueries: 1
        )
        let queryBudget = LumenScreenCaptureQueryBudget(
            maximumOutstandingQueries: timing.maximumOutstandingQueries
        )
        let task = Task.detached { @Sendable in
            try await Self.resolve(
                clock: clock,
                queries: queries,
                timing: timing,
                queryBudget: queryBudget
            )
        }
        defer { task.cancel() }

        try await queries.waitForQuery(generation: 1)
        await clock.advance(to: 6)
        try await clock.waitForSleeper(at: 7)
        await clock.advance(to: 7)
        try await clock.waitForSleeper(at: 8)
        let timedOutGenerations = await queries.startedGenerations()
        XCTAssertEqual(timedOutGenerations, [1])

        await queries.complete(generation: 1, value: nil)
        try await waitForDisplayReadinessCondition("generation one completion") {
            await queryBudget.outstandingCount() == 0
        }
        await clock.advance(to: 9)
        try await queries.waitForQuery(generation: 2)
        let completedGenerations = await queries.startedGenerations()
        XCTAssertEqual(completedGenerations, [1, 2])

        await queries.complete(generation: 2, value: 22)
        let resolved = try await task.value
        XCTAssertEqual(resolved, 22)
    }

    func testFortyTwoSecondQueryCannotOutliveTheOverallDeadline() async throws {
        let clock = DisplayReadinessVirtualClock()
        let queries = DisplayReadinessQueryControl<UInt32>()
        let task = Task.detached { @Sendable in
            try await Self.resolve(
                clock: clock,
                queries: queries,
                timing: .init(
                    overallDeadlineNanoseconds: 15,
                    queryTimeoutNanoseconds: 12,
                    retryDelayNanoseconds: 0
                )
            )
        }
        defer { task.cancel() }

        try await queries.waitForQuery(generation: 1)
        await clock.advance(to: 42)

        do {
            _ = try await task.value
            XCTFail("expected the absolute display publication deadline")
        } catch LumenScreenCaptureError.displayUnavailable(22) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // The uncooperative query completes after its timeout. Its generation is no
        // longer eligible to publish a result into the completed resolver.
        await queries.complete(generation: 1, value: 22)
        let completedTime = await clock.currentTime()
        XCTAssertEqual(completedTime, 42)
    }

    func testPerQueryTimeoutBoundsOrphansAndAcceptsLateSuccessBeforeOverallDeadline() async throws {
        let timing = LumenScreenCaptureDisplayReadinessTiming(
            overallDeadlineNanoseconds: 30,
            queryTimeoutNanoseconds: 5,
            retryDelayNanoseconds: 1,
            maximumOutstandingQueries: 2
        )

        try await assertLateSuccessWinsWithinOverallDeadline(timing: timing)
        try await assertOutstandingQueryCancels(timing: timing)
    }

    func testSlowNilQueryCanResolveExactDisplayAtFinalDeadlineBoundary() async throws {
        let clock = DisplayReadinessVirtualClock()
        let queries = DisplayReadinessQueryControl<UInt32>()
        let task = Task.detached { @Sendable in
            try await Self.resolve(
                clock: clock,
                queries: queries,
                timing: .init(
                    overallDeadlineNanoseconds: 10,
                    queryTimeoutNanoseconds: 10,
                    retryDelayNanoseconds: 1
                )
            )
        }
        defer { task.cancel() }

        try await queries.waitForQuery(generation: 1)
        await clock.advance(to: 4)
        await queries.complete(generation: 1, value: nil)
        try await clock.waitForSleeper(at: 5)
        await clock.advance(to: 5)
        try await queries.waitForQuery(generation: 2)
        await clock.advance(to: 10)
        await queries.complete(generation: 2, value: 22)

        let resolved = try await task.value
        XCTAssertEqual(resolved, 22)
    }

    func testQueryWinnerIsRejectedWhenCancellationWinsBeforePublication() async throws {
        try await assertResolvedQueryWinnerIsCancelled()
        try await assertPreparedQueryWinnerIsCancelled()
    }

    func testStalePrefetchFallsThroughToFreshExactDisplayQuery() async throws {
        let store = LumenPreparedDisplayStore<UInt32>()
        let staleGeneration = try await prepareStaleDisplay(in: store)
        let freshQueries = DisplayReadinessCounter()

        let admission: LumenScreenCaptureDisplayAdmissionResult<UInt32> = try await
            LumenScreenCaptureDisplayAdmission.resolve(
                displayID: 22,
                prefetched: {
                    await store.take(displayID: 22, ownerToken: 8, now: 10)
                },
                enumerateShareableContent: {
                    await freshQueries.increment()
                    return LumenScreenCaptureDisplayAdmissionResult(
                        value: 22,
                        mode: .retainedShareableContent
                    )
                }
            )

        XCTAssertEqual(admission.value, 22)
        XCTAssertEqual(admission.mode, .retainedShareableContent)
        let freshQueryCount = await freshQueries.value()
        let staleValueAfterMismatch = await store.take(
            displayID: 22,
            ownerToken: 7,
            now: 10
        )
        let currentPreparedValue = try await prepareCurrentDisplay(
            in: store,
            staleGeneration: staleGeneration
        )
        XCTAssertEqual(freshQueryCount, 1)
        XCTAssertNil(staleValueAfterMismatch)
        XCTAssertEqual(currentPreparedValue, 22)
    }
}

private extension LumenScreenCaptureDisplayReadinessTests {
    func assertLateSuccessWinsWithinOverallDeadline(
        timing: LumenScreenCaptureDisplayReadinessTiming
    ) async throws {
        let clock = DisplayReadinessVirtualClock()
        let queries = DisplayReadinessQueryControl<UInt32>()
        let sharedBudget = LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 2)
        let completions = DisplayReadinessCounter()
        let task = Task.detached { @Sendable in
            let value = try await Self.resolve(
                clock: clock,
                queries: queries,
                timing: timing,
                queryBudget: sharedBudget
            )
            await completions.increment()
            return value
        }
        defer { task.cancel() }

        try await queries.waitForQuery(generation: 1)
        await clock.advance(to: 6)
        try await clock.waitForSleeper(at: 7)
        await clock.advance(to: 7)
        try await queries.waitForQuery(generation: 2)
        await clock.advance(to: 13)
        try await clock.waitForSleeper(at: 14)
        let startedGenerations = await queries.startedGenerations()
        XCTAssertEqual(startedGenerations, [1, 2])

        await queries.complete(generation: 1, value: 22)
        try await waitForDisplayReadinessCondition("orphan query budget release") {
            await sharedBudget.outstandingCount() <= 1
        }
        await clock.advance(to: 14)
        try await waitForDisplayReadinessCondition("late result or next query") {
            if await completions.value() > 0 {
                return true
            }
            return await queries.startedGenerations().contains(3)
        }
        let finalGenerations = await queries.startedGenerations()
        XCTAssertEqual(finalGenerations, [1, 2])
        if finalGenerations.contains(3) {
            await queries.complete(generation: 3, value: 999)
        }
        let resolved = try await task.value
        XCTAssertEqual(resolved, 22)
        await queries.complete(generation: 2, value: 999)
    }

    func assertOutstandingQueryCancels(
        timing: LumenScreenCaptureDisplayReadinessTiming
    ) async throws {
        let clock = DisplayReadinessVirtualClock()
        let queries = DisplayReadinessQueryControl<UInt32>(
            honorsCancellation: true
        )
        let budget = LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 1)
        let task = Task.detached { @Sendable in
            try await Self.resolve(
                clock: clock,
                queries: queries,
                timing: timing,
                queryBudget: budget
            )
        }
        try await queries.waitForQuery(generation: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected an outstanding display query to cancel")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        await queries.complete(generation: 1, value: 22)
        try await waitForDisplayReadinessCondition("cancelled query budget release") {
            await budget.outstandingCount() == 0
        }
    }
}

private extension LumenScreenCaptureDisplayReadinessTests {
    func assertResolvedQueryWinnerIsCancelled() async throws {
        let nowControl = DisplayReadinessNowControl(blockingCall: 4)
        let task = Task.detached { @Sendable in
            try await LumenScreenCaptureDisplayResolver.resolve(
                displayID: 22,
                authority: .retained(ownerToken: 7),
                timing: .init(
                    overallDeadlineNanoseconds: 10,
                    queryTimeoutNanoseconds: 5,
                    retryDelayNanoseconds: 1
                ),
                queryBudget: LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 1),
                environment: .init(
                    now: { await nowControl.now() },
                    sleepUntil: { _ in },
                    readiness: {
                        .init(
                            ownerToken: 7,
                            isOnline: true,
                            isActive: true,
                            hasCurrentMode: true
                        )
                    },
                    lookup: { _ in UInt32(22) }
                )
            )
        }
        defer {
            task.cancel()
            Task { await nowControl.release() }
        }
        try await nowControl.waitUntilBlocked()
        task.cancel()
        await nowControl.release()

        do {
            _ = try await task.value
            XCTFail("a cancelled query winner must not publish")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }

    func assertPreparedQueryWinnerIsCancelled() async throws {
        let store = LumenPreparedDisplayStore<UInt32>()
        let generation = await store.begin(displayID: 22, ownerToken: 7)
        let publicationGate = DisplayReadinessNowControl(blockingCall: 1)
        let task = Task {
            _ = await publicationGate.now()
            try await store.complete(
                displayID: 22,
                ownerToken: 7,
                generation: generation,
                value: 22,
                expiresAt: 10
            )
        }
        try await publicationGate.waitUntilBlocked()
        task.cancel()
        await publicationGate.release()
        do {
            try await task.value
            XCTFail("a cancelled prefetch generation must not publish")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected prefetch cancellation error: \(error)")
        }
        let cancelledValue = await store.take(
            displayID: 22,
            ownerToken: 7,
            now: 0
        )
        XCTAssertNil(cancelledValue)
    }

    func prepareStaleDisplay(
        in store: LumenPreparedDisplayStore<UInt32>
    ) async throws -> UInt64 {
        let generation = await store.begin(displayID: 22, ownerToken: 7)
        try await store.complete(
            displayID: 22,
            ownerToken: 7,
            generation: generation,
            value: 999,
            expiresAt: 100
        )
        return generation
    }

    func prepareCurrentDisplay(
        in store: LumenPreparedDisplayStore<UInt32>,
        staleGeneration: UInt64
    ) async throws -> UInt32? {
        let currentGeneration = await store.begin(displayID: 22, ownerToken: 8)
        try await store.complete(
            displayID: 22,
            ownerToken: 7,
            generation: staleGeneration,
            value: 999,
            expiresAt: 100
        )
        try await store.complete(
            displayID: 22,
            ownerToken: 8,
            generation: currentGeneration,
            value: 22,
            expiresAt: 100
        )
        return await store.take(displayID: 22, ownerToken: 8, now: 10)
    }

    static func resolve(
        clock: DisplayReadinessVirtualClock,
        queries: DisplayReadinessQueryControl<UInt32>,
        timing: LumenScreenCaptureDisplayReadinessTiming,
        queryBudget: LumenScreenCaptureQueryBudget? = nil
    ) async throws -> UInt32 {
        let queryBudget = queryBudget ?? LumenScreenCaptureQueryBudget(
            maximumOutstandingQueries: timing.maximumOutstandingQueries
        )
        return try await LumenScreenCaptureDisplayResolver.resolve(
            displayID: 22,
            authority: .retained(ownerToken: 7),
            timing: timing,
            queryBudget: queryBudget,
            environment: .init(
                now: { await clock.currentTime() },
                sleepUntil: { await clock.sleep(until: $0) },
                readiness: {
                    .init(
                        ownerToken: 7,
                        isOnline: true,
                        isActive: true,
                        hasCurrentMode: true
                    )
                },
                lookup: { generation in
                    await queries.lookup(generation: generation)
                }
            )
        )
    }
}
