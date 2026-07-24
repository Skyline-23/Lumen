import XCTest
@testable import LumenMacBridge

private enum DisplayReadinessTestError: Error {
    case timedOut(String)
}

final class LumenScreenCaptureDisplayReadinessTests: XCTestCase {
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

    func testPerQueryTimeoutBoundsOrphansAndIgnoresLateSuccess() async throws {
        let clock = DisplayReadinessVirtualClock()
        let queries = DisplayReadinessQueryControl<UInt32>()
        let competingQueries = DisplayReadinessQueryControl<UInt32>()
        let sharedBudget = LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 2)
        let timing = LumenScreenCaptureDisplayReadinessTiming(
            overallDeadlineNanoseconds: 30,
            queryTimeoutNanoseconds: 5,
            retryDelayNanoseconds: 1,
            maximumOutstandingQueries: 2
        )
        let task = Task.detached { @Sendable in
            try await Self.resolve(
                clock: clock,
                queries: queries,
                timing: timing,
                queryBudget: sharedBudget
            )
        }
        defer { task.cancel() }

        try await queries.waitForQuery(generation: 1)
        await clock.advance(to: 6)
        try await clock.waitForSleeper(at: 7)
        await clock.advance(to: 7)
        try await queries.waitForQuery(generation: 2)
        await clock.advance(to: 13)
        try await clock.waitForSleeper(at: 14)

        var generations = await queries.startedGenerations()
        XCTAssertEqual(generations, [1, 2])

        let competingTask = Task.detached { @Sendable in
            try await Self.resolve(
                clock: clock,
                queries: competingQueries,
                timing: timing,
                queryBudget: sharedBudget
            )
        }
        try await clock.waitForSleeper(at: 14, count: 2)
        let competingGenerations = await competingQueries.startedGenerations()
        XCTAssertTrue(competingGenerations.isEmpty)
        competingTask.cancel()
        do {
            _ = try await competingTask.value
            XCTFail("expected the competing resolver to cancel while globally budgeted")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected competing resolver error: \(error)")
        }

        await queries.complete(generation: 1, value: 999)
        try await waitForDisplayReadinessCondition("orphan query budget release") {
            await sharedBudget.outstandingCount() <= 1
        }
        await clock.advance(to: 14)
        try await queries.waitForQuery(generation: 3)
        await queries.complete(generation: 3, value: 22)

        let resolved = try await task.value
        XCTAssertEqual(resolved, 22)
        await queries.complete(generation: 2, value: 999)
        generations = await queries.startedGenerations()
        XCTAssertEqual(generations, [1, 2, 3])

        let cancellationClock = DisplayReadinessVirtualClock()
        let cancellationQueries = DisplayReadinessQueryControl<UInt32>(
            honorsCancellation: true
        )
        let cancellationBudget = LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 1)
        let cancellationTask = Task.detached { @Sendable in
            try await Self.resolve(
                clock: cancellationClock,
                queries: cancellationQueries,
                timing: timing,
                queryBudget: cancellationBudget
            )
        }
        try await cancellationQueries.waitForQuery(generation: 1)
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            XCTFail("expected an outstanding display query to cancel")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        await cancellationQueries.complete(generation: 1, value: 22)
        try await waitForDisplayReadinessCondition("cancelled query budget release") {
            await cancellationBudget.outstandingCount() == 0
        }
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

        let preparedStore = LumenPreparedDisplayStore<UInt32>()
        let generation = await preparedStore.begin(
            displayID: 22,
            ownerToken: 7
        )
        let publicationGate = DisplayReadinessNowControl(blockingCall: 1)
        let publicationTask = Task {
            _ = await publicationGate.now()
            try await preparedStore.complete(
                displayID: 22,
                ownerToken: 7,
                generation: generation,
                value: 22,
                expiresAt: 10
            )
        }
        try await publicationGate.waitUntilBlocked()
        publicationTask.cancel()
        await publicationGate.release()
        do {
            try await publicationTask.value
            XCTFail("a cancelled prefetch generation must not publish")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected prefetch cancellation error: \(error)")
        }
        let cancelledPreparedValue = await preparedStore.take(
            displayID: 22,
            ownerToken: 7,
            now: 0
        )
        XCTAssertNil(cancelledPreparedValue)
    }

    func testStalePrefetchFallsThroughToFreshExactDisplayQuery() async throws {
        let store = LumenPreparedDisplayStore<UInt32>()
        let staleGeneration = await store.begin(displayID: 22, ownerToken: 7)
        try await store.complete(
            displayID: 22,
            ownerToken: 7,
            generation: staleGeneration,
            value: 999,
            expiresAt: 100
        )
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
        let currentPreparedValue = await store.take(
            displayID: 22,
            ownerToken: 8,
            now: 10
        )
        XCTAssertEqual(freshQueryCount, 1)
        XCTAssertNil(staleValueAfterMismatch)
        XCTAssertEqual(currentPreparedValue, 22)
    }

    func testRetainedObjectReplacementAfterQueryFailsClosed() async {
        let clock = DisplayReadinessVirtualClock()
        let state = DisplayReadinessState(ownerToken: 7, modeReady: true)

        do {
            let _: UInt32 = try await LumenScreenCaptureDisplayResolver.resolve(
                displayID: 22,
                authority: .retained(ownerToken: 7),
                timing: .init(
                    overallDeadlineNanoseconds: 10,
                    queryTimeoutNanoseconds: 5,
                    retryDelayNanoseconds: 1
                ),
                queryBudget: LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 2),
                now: { await clock.currentTime() },
                sleepUntil: { await clock.sleep(until: $0) },
                readiness: { await state.snapshot() },
                lookup: { _ in
                    await state.replaceOwner(with: 8)
                    return 22
                }
            )
            XCTFail("expected exact retained object replacement to fail closed")
        } catch LumenScreenCaptureError.displayOwnershipLost(22) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRetainedConfiguredGeometryAdmitsQueryWhenPublicModeIsHidden() async throws {
        let clock = DisplayReadinessVirtualClock()
        let state = DisplayReadinessState(ownerToken: 7, modeReady: false)
        let lookupCount = DisplayReadinessCounter()
        let task = Task.detached { @Sendable in
            try await LumenScreenCaptureDisplayResolver.resolve(
                displayID: 22,
                authority: .retained(ownerToken: 7),
                timing: .init(
                    overallDeadlineNanoseconds: 10,
                    queryTimeoutNanoseconds: 5,
                    retryDelayNanoseconds: 1
                ),
                queryBudget: LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 2),
                now: { await clock.currentTime() },
                sleepUntil: { await clock.sleep(until: $0) },
                readiness: { await state.snapshot() },
                lookup: { _ in
                    await lookupCount.increment()
                    return UInt32(22)
                }
            )
        }
        defer { task.cancel() }

        try await clock.waitForSleeper(at: 1)
        let lookupCountBeforeReadiness = await lookupCount.value()
        XCTAssertEqual(lookupCountBeforeReadiness, 0)
        await state.publishRetainedConfiguredGeometry(width: 320, height: 180)
        await clock.advance(to: 1)

        let resolved = try await task.value
        let lookupCountAfterReadiness = await lookupCount.value()
        XCTAssertEqual(resolved, 22)
        XCTAssertEqual(lookupCountAfterReadiness, 1)

        let inactiveMirrorSink = LumenScreenCaptureDisplayReadinessSnapshot(
            ownerToken: 7,
            isOnline: true,
            isActive: false,
            hasCurrentMode: false,
            configuredPixelWidth: 320,
            configuredPixelHeight: 180
        )
        XCTAssertFalse(
            inactiveMirrorSink.isModeReady(
                for: .retained(ownerToken: 7)
            )
        )
        XCTAssertTrue(
            inactiveMirrorSink.isPreparedHandleReady(
                for: .retained(ownerToken: 7)
            )
        )
        XCTAssertFalse(
            inactiveMirrorSink.isPreparedHandleReady(
                for: .exactExternal
            )
        )

        do {
            let _: UInt32 = try await LumenScreenCaptureDisplayResolver.resolve(
                displayID: 22,
                authority: .exactExternal,
                timing: .init(
                    overallDeadlineNanoseconds: 0,
                    queryTimeoutNanoseconds: 0,
                    retryDelayNanoseconds: 0
                ),
                queryBudget: LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 1),
                now: { await clock.currentTime() },
                sleepUntil: { await clock.sleep(until: $0) },
                readiness: {
                    .init(
                        ownerToken: nil,
                        isOnline: true,
                        isActive: true,
                        hasCurrentMode: false,
                        configuredPixelWidth: 320,
                        configuredPixelHeight: 180
                    )
                },
                lookup: { _ in
                    XCTFail("external displays must ignore retained configured geometry")
                    return UInt32(22)
                }
            )
            XCTFail("expected a mode-less external display to fail closed")
        } catch LumenScreenCaptureError.displayUnavailable(22) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRetainedAndExactExternalResolversNeverFallBackToAnotherDisplay() async throws {
        let clock = DisplayReadinessVirtualClock()
        let lookupCount = DisplayReadinessCounter()

        do {
            let _: UInt32 = try await LumenScreenCaptureDisplayResolver.resolve(
                displayID: 22,
                authority: .retained(ownerToken: 7),
                timing: .init(
                    overallDeadlineNanoseconds: 10,
                    queryTimeoutNanoseconds: 5,
                    retryDelayNanoseconds: 1
                ),
                queryBudget: LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 2),
                now: { await clock.currentTime() },
                sleepUntil: { await clock.sleep(until: $0) },
                readiness: { Self.externalReadySnapshot },
                lookup: { _ in
                    await lookupCount.increment()
                    return 3
                }
            )
            XCTFail("expected missing retained ownership to fail closed")
        } catch LumenScreenCaptureError.displayOwnershipLost(22) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            let _: UInt32 = try await LumenScreenCaptureDisplayResolver.resolve(
                displayID: 22,
                authority: .exactExternal,
                timing: .init(
                    overallDeadlineNanoseconds: 0,
                    queryTimeoutNanoseconds: 0,
                    retryDelayNanoseconds: 0
                ),
                queryBudget: LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 2),
                now: { await clock.currentTime() },
                sleepUntil: { await clock.sleep(until: $0) },
                readiness: { Self.externalReadySnapshot },
                lookup: { _ in
                    await lookupCount.increment()
                    // Enumeration contained display 3, but not the requested 22.
                    return nil
                }
            )
            XCTFail("expected exact external display lookup to reject display 3")
        } catch LumenScreenCaptureError.displayUnavailable(22) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let exactExternal: UInt32 = try await LumenScreenCaptureDisplayResolver.resolve(
            displayID: 22,
            authority: .exactExternal,
            timing: .init(
                overallDeadlineNanoseconds: 0,
                queryTimeoutNanoseconds: 0,
                retryDelayNanoseconds: 0
            ),
            queryBudget: LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 2),
            now: { await clock.currentTime() },
            sleepUntil: { await clock.sleep(until: $0) },
            readiness: { Self.externalReadySnapshot },
            lookup: { _ in
                await lookupCount.increment()
                return 22
            }
        )

        let finalLookupCount = await lookupCount.value()
        XCTAssertEqual(exactExternal, 22)
        XCTAssertEqual(finalLookupCount, 2)
    }

    private static var externalReadySnapshot: LumenScreenCaptureDisplayReadinessSnapshot {
        .init(
            ownerToken: nil,
            isOnline: true,
            isActive: true,
            hasCurrentMode: true
        )
    }

    private static func resolve(
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
    }
}

private actor DisplayReadinessVirtualClock {
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

private actor DisplayReadinessQueryControl<Value: Sendable> {
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

    private func cancel(generation: UInt64) {
        pending.removeValue(forKey: generation)?.resume(returning: nil)
    }

    func startedGenerations() -> [UInt64] {
        generations
    }
}

private actor DisplayReadinessState {
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

    func snapshot() -> LumenScreenCaptureDisplayReadinessSnapshot {
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

private actor DisplayReadinessCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private func waitForDisplayReadinessCondition(
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

private actor DisplayReadinessNowControl {
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
