import XCTest
@testable import LumenMacBridge

final class LumenScreenCaptureDisplayAuthorityTests: XCTestCase {
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
                environment: .init(
                    now: { await clock.currentTime() },
                    sleepUntil: { await clock.sleep(until: $0) },
                    readiness: { await state.snapshot() },
                    lookup: { _ in
                        await state.replaceOwner(with: 8)
                        return 22
                    }
                )
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

        try await assertRetainedConfiguredGeometryResolves(
            clock: clock,
            state: state,
            lookupCount: lookupCount
        )
        assertInactiveMirrorSinkIsNotReady()
        try await assertExternalDisplayStillRequiresPublicMode(clock: clock)
    }

    func testRetainedAndExactExternalResolversNeverFallBackToAnotherDisplay() async throws {
        let clock = DisplayReadinessVirtualClock()
        let lookupCount = DisplayReadinessCounter()

        await assertMissingRetainedOwnershipFailsClosed(
            clock: clock,
            lookupCount: lookupCount
        )
        await assertMissingExactExternalDisplayFailsClosed(
            clock: clock,
            lookupCount: lookupCount
        )
        let exactExternal = try await resolveExactExternalDisplay(
            clock: clock,
            lookupCount: lookupCount
        )

        let finalLookupCount = await lookupCount.value()
        XCTAssertEqual(exactExternal, 22)
        XCTAssertEqual(finalLookupCount, 2)
    }
}

private extension LumenScreenCaptureDisplayAuthorityTests {
    static var externalReadySnapshot: LumenCaptureDisplayReadinessSnapshot {
        .init(
            ownerToken: nil,
            isOnline: true,
            isActive: true,
            hasCurrentMode: true
        )
    }

    func assertRetainedConfiguredGeometryResolves(
        clock: DisplayReadinessVirtualClock,
        state: DisplayReadinessState,
        lookupCount: DisplayReadinessCounter
    ) async throws {
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
                environment: .init(
                    now: { await clock.currentTime() },
                    sleepUntil: { await clock.sleep(until: $0) },
                    readiness: { await state.snapshot() },
                    lookup: { _ in
                        await lookupCount.increment()
                        return UInt32(22)
                    }
                )
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
    }

    func assertInactiveMirrorSinkIsNotReady() {
        let inactiveMirrorSink = LumenCaptureDisplayReadinessSnapshot(
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
        XCTAssertFalse(
            inactiveMirrorSink.isPreparedHandleReady(
                for: .retained(ownerToken: 7)
            )
        )
        XCTAssertFalse(
            inactiveMirrorSink.isPreparedHandleReady(
                for: .exactExternal
            )
        )
    }

    func assertExternalDisplayStillRequiresPublicMode(
        clock: DisplayReadinessVirtualClock
    ) async throws {
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
                environment: .init(
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
                        XCTFail(
                            "external displays must ignore retained configured geometry"
                        )
                        return UInt32(22)
                    }
                )
            )
            XCTFail("expected a mode-less external display to fail closed")
        } catch LumenScreenCaptureError.displayUnavailable(22) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private extension LumenScreenCaptureDisplayAuthorityTests {
    func assertMissingRetainedOwnershipFailsClosed(
        clock: DisplayReadinessVirtualClock,
        lookupCount: DisplayReadinessCounter
    ) async {
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
                environment: .init(
                    now: { await clock.currentTime() },
                    sleepUntil: { await clock.sleep(until: $0) },
                    readiness: { Self.externalReadySnapshot },
                    lookup: { _ in
                        await lookupCount.increment()
                        return 3
                    }
                )
            )
            XCTFail("expected missing retained ownership to fail closed")
        } catch LumenScreenCaptureError.displayOwnershipLost(22) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func assertMissingExactExternalDisplayFailsClosed(
        clock: DisplayReadinessVirtualClock,
        lookupCount: DisplayReadinessCounter
    ) async {
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
                environment: .init(
                    now: { await clock.currentTime() },
                    sleepUntil: { await clock.sleep(until: $0) },
                    readiness: { Self.externalReadySnapshot },
                    lookup: { _ in
                        await lookupCount.increment()
                        return nil
                    }
                )
            )
            XCTFail("expected exact external display lookup to reject display 3")
        } catch LumenScreenCaptureError.displayUnavailable(22) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func resolveExactExternalDisplay(
        clock: DisplayReadinessVirtualClock,
        lookupCount: DisplayReadinessCounter
    ) async throws -> UInt32 {
        try await LumenScreenCaptureDisplayResolver.resolve(
            displayID: 22,
            authority: .exactExternal,
            timing: .init(
                overallDeadlineNanoseconds: 0,
                queryTimeoutNanoseconds: 0,
                retryDelayNanoseconds: 0
            ),
            queryBudget: LumenScreenCaptureQueryBudget(maximumOutstandingQueries: 2),
            environment: .init(
                now: { await clock.currentTime() },
                sleepUntil: { await clock.sleep(until: $0) },
                readiness: { Self.externalReadySnapshot },
                lookup: { _ in
                    await lookupCount.increment()
                    return 22
                }
            )
        )
    }
}
