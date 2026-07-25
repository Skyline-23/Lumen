import XCTest
import Synchronization
@testable import LumenMacBridge

final class LumenWorkspaceRegistryRecoveryTests: XCTestCase {
    func testRegistryStopRejectsMismatchedKeyWithoutJoiningTeardown() async throws {
        let effects = WorkspaceRegistryEffects(ownerToken: 0x16)
        let stopSuspension = WorkspaceRegistrySuspension(
            honorsCancellation: false
        )
        let registry = makeWorkspaceSessionRegistry(
            effects: effects,
            stopSuspension: stopSuspension
        )
        _ = try await registry.prepare(
            workspaceRegistrySnapshot(displayKey: "teardown-display")
        )

        let teardown = Task {
            try await registry.recoverPendingWorkspace()
        }
        try await waitForWorkspaceRegistryCondition("active teardown stop") {
            await stopSuspension.hasEntered()
        }
        let mismatchedStopResult = Mutex<Bool?>(nil)
        let mismatchedStop = Task {
            let result = try await registry.stop(displayKey: "unrelated-display")
            mismatchedStopResult.withLock { $0 = result }
            return result
        }
        var rejectionWaitError: (any Error)?
        do {
            try await waitForWorkspaceRegistryCondition("mismatched stop rejection") {
                mismatchedStopResult.withLock { $0 != nil }
            }
        } catch {
            rejectionWaitError = error
        }

        await stopSuspension.release()
        let stoppedMismatchedKey = try await mismatchedStop.value
        let recovered = try await teardown.value
        XCTAssertNil(
            rejectionWaitError,
            "a mismatched stop must return without joining an unrelated teardown"
        )
        XCTAssertFalse(stoppedMismatchedKey)
        XCTAssertTrue(recovered)
        let effectsSnapshot = await effects.snapshot()
        XCTAssertEqual(effectsSnapshot.stopCallCount, 1)
        XCTAssertEqual(effectsSnapshot.journalClearCount, 1)
    }

    func testRegistryPrepareCannotEnterDuringStopOrStopAll() async throws {
        for usesStopAll in [false, true] {
            let ownerToken: UInt = usesStopAll ? 0x17 : 0x16
            let effects = WorkspaceRegistryEffects(ownerToken: ownerToken)
            let stopSuspension = WorkspaceRegistrySuspension(
                honorsCancellation: false
            )
            let registry = makeWorkspaceSessionRegistry(
                effects: effects,
                stopSuspension: stopSuspension
            )
            let displayKey = usesStopAll ? "stop-all-display" : "stop-display"
            _ = try await registry.prepare(
                workspaceRegistrySnapshot(displayKey: displayKey)
            )

            let stopTask: Task<Void, Error>
            if usesStopAll {
                stopTask = Task {
                    await registry.stopAll()
                }
            } else {
                stopTask = Task {
                    _ = try await registry.stop(displayKey: displayKey)
                }
            }
            try await waitForWorkspaceRegistryCondition("stop suspension") {
                await stopSuspension.hasEntered()
            }
            do {
                _ = try await registry.prepare(
                    workspaceRegistrySnapshot(displayKey: "overlap-\(displayKey)")
                )
                XCTFail("prepare must remain blocked while cleanup owns the journal")
            } catch LumenMacWorkspaceSessionError.sessionAlreadyStarted {
            }
            await stopSuspension.release()
            try await stopTask.value

            let effectsSnapshot = await effects.snapshot()
            XCTAssertEqual(effectsSnapshot.releasedOwnerTokens, [ownerToken])
            XCTAssertEqual(effectsSnapshot.journalClearCount, 1)
            XCTAssertEqual(effectsSnapshot.stopCallCount, 1)
        }
    }

    func testRegistryCleanupFailureRetainsActiveSessionForExactRecoveryRetry() async throws {
        let ownerToken: UInt = 0x16
        let effects = WorkspaceRegistryEffects(
            ownerToken: ownerToken,
            stopFailures: 1,
            recoveryFailures: 1
        )
        let registry = makeWorkspaceSessionRegistry(effects: effects)
        _ = try await registry.prepare(
            workspaceRegistrySnapshot(displayKey: "retry-display")
        )

        do {
            _ = try await registry.recoverPendingWorkspace()
            XCTFail("expected the first exact stop and durable recovery to fail")
        } catch is LumenWorkspaceStopRecoveryError {
        }
        var effectsSnapshot = await effects.snapshot()
        XCTAssertTrue(effectsSnapshot.releasedOwnerTokens.isEmpty)
        XCTAssertEqual(effectsSnapshot.journalClearCount, 0)

        let retriedRecovery = try await registry.recoverPendingWorkspace()
        XCTAssertTrue(retriedRecovery)
        effectsSnapshot = await effects.snapshot()
        XCTAssertEqual(effectsSnapshot.releasedOwnerTokens, [ownerToken])
        XCTAssertEqual(effectsSnapshot.journalClearCount, 1)
        XCTAssertEqual(effectsSnapshot.stopCallCount, 2)
        let stoppedRecoveredSession = try await registry.stop(
            displayKey: "retry-display"
        )
        XCTAssertFalse(stoppedRecoveredSession)
    }

    func testDurableRecoveryClearsCaptureStateAndNeverRemovesAReplacementOwner() async throws {
        let fixture = try await makeDurableRecoveryFixture()

        try await assertReplacementOwnerFailsClosed(fixture)
        try await assertTopologyReleaseFailureRetainsOwner(fixture)
        try await assertDurableRecoveryCleansState(fixture)
    }

}

private final class DurableRecoveryState: @unchecked Sendable {
    private let storage: Mutex<WorkspaceVirtualDisplayRegistryState>

    init(_ initialState: WorkspaceVirtualDisplayRegistryState) {
        storage = Mutex(initialState)
    }

    func replaceOwner(with display: LumenMacVirtualDisplay) {
        storage.withLock {
            $0.currentOwner = LumenRetainedVirtualDisplayReference(display: display)
        }
    }

    func prepareOriginalOwner(
        _ display: LumenMacVirtualDisplay,
        topologyReleaseFailures: Int
    ) {
        storage.withLock {
            $0.currentOwner = LumenRetainedVirtualDisplayReference(display: display)
            $0.topologyReleaseFailuresRemaining = topologyReleaseFailures
        }
    }

    func currentOwner() -> LumenRetainedVirtualDisplayReference? {
        storage.withLock { $0.currentOwner }
    }

    func releaseTopology(displayID: UInt32) throws {
        try storage.withLock {
            $0.releasedTopologyDisplayIDs.append(displayID)
            $0.cleanupEvents.append(.releaseTopology(displayID))
            guard $0.topologyReleaseFailuresRemaining == 0 else {
                $0.topologyReleaseFailuresRemaining -= 1
                throw WorkspaceVirtualDisplayCleanupFailure.releaseTopology
            }
        }
    }

    func discardCapture(displayID: UInt32) {
        storage.withLock {
            $0.discardedCaptureDisplayIDs.append(displayID)
            $0.cleanupEvents.append(.discardCapture(displayID))
        }
    }

    func removeMatchingOwner(
        _ expectedOwner: LumenRetainedVirtualDisplayReference
    ) -> Bool {
        storage.withLock { current in
            guard current.currentOwner?.display === expectedOwner.display else {
                return false
            }
            current.removedOwnerTokens.append(expectedOwner.ownerToken)
            current.cleanupEvents.append(.removeOwner)
            current.currentOwner = nil
            return true
        }
    }

    func ownerMatches(_ display: LumenMacVirtualDisplay) -> Bool {
        storage.withLock { $0.currentOwner?.display === display }
    }

    func hasOwner() -> Bool {
        storage.withLock { $0.currentOwner != nil }
    }

    func releasedTopologyDisplayIDs() -> [UInt32] {
        storage.withLock { $0.releasedTopologyDisplayIDs }
    }

    func removedOwnerTokens() -> [UInt] {
        storage.withLock { $0.removedOwnerTokens }
    }

    func discardedCaptureDisplayIDs() -> [UInt32] {
        storage.withLock { $0.discardedCaptureDisplayIDs }
    }

    func cleanupEvents() -> [WorkspaceVirtualDisplayCleanupEvent] {
        storage.withLock { $0.cleanupEvents }
    }
}

private struct DurableRecoveryFixture {
    let key: String
    let original: LumenMacVirtualDisplay
    let replacement: LumenMacVirtualDisplay
    let state: DurableRecoveryState
    let expectedOwners: LumenExpectedDisplayOwnerStore<UInt>
    let preparedDisplays: LumenPreparedDisplayStore<UInt32>
    let registry: LumenMacOwnedVirtualDisplayRegistry
    let retryOwner: LumenMacVirtualDisplayOwner
}

private extension LumenWorkspaceRegistryRecoveryTests {
    func makeDurableRecoveryFixture() async throws -> DurableRecoveryFixture {
        let key = "failed-prepare-retry-owner"
        let original = try makeUninitializedVirtualDisplay()
        let replacement = try makeUninitializedVirtualDisplay()
        let state = DurableRecoveryState(
            WorkspaceVirtualDisplayRegistryState(
                currentOwner: LumenRetainedVirtualDisplayReference(display: original)
            )
        )
        let expectedOwners = LumenExpectedDisplayOwnerStore<UInt>()
        let preparedDisplays = LumenPreparedDisplayStore<UInt32>()
        await expectedOwners.set(7, displayID: 22)
        let generation = await preparedDisplays.begin(displayID: 22, ownerToken: 7)
        try await preparedDisplays.complete(
            displayID: 22,
            ownerToken: 7,
            generation: generation,
            value: 22,
            expiresAt: 100
        )
        let registry = LumenMacOwnedVirtualDisplayRegistry(
            access: makeRegistryAccess(
                key: key,
                state: state,
                expectedOwners: expectedOwners,
                preparedDisplays: preparedDisplays
            )
        )
        try await registry.register(
            LumenRetainedVirtualDisplayReference(display: original),
            forKey: key
        )
        state.replaceOwner(with: replacement)
        return DurableRecoveryFixture(
            key: key,
            original: original,
            replacement: replacement,
            state: state,
            expectedOwners: expectedOwners,
            preparedDisplays: preparedDisplays,
            registry: registry,
            retryOwner: LumenMacVirtualDisplayOwner(ownershipRegistry: registry)
        )
    }

    func makeUninitializedVirtualDisplay() throws -> LumenMacVirtualDisplay {
        try XCTUnwrap(
            (LumenMacVirtualDisplay.self as AnyObject)
                .perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue() as? LumenMacVirtualDisplay
        )
    }

    func makeRegistryAccess(
        key: String,
        state: DurableRecoveryState,
        expectedOwners: LumenExpectedDisplayOwnerStore<UInt>,
        preparedDisplays: LumenPreparedDisplayStore<UInt32>
    ) -> LumenMacVirtualDisplayRegistryAccess {
        LumenMacVirtualDisplayRegistryAccess(
            currentOwner: { requestedKey in
                guard requestedKey == key else { return nil }
                return state.currentOwner()
            },
            displayID: { _ in 22 },
            releaseDisplayTopology: { displayID in
                try state.releaseTopology(displayID: displayID)
            },
            discardCaptureState: { displayID in
                await preparedDisplays.discard(displayID: displayID)
                await expectedOwners.discard(displayID: displayID)
                state.discardCapture(displayID: displayID)
            },
            removeMatchingOwner: { requestedKey, expectedOwner in
                guard requestedKey == key else { return false }
                return state.removeMatchingOwner(expectedOwner)
            }
        )
    }

    func assertReplacementOwnerFailsClosed(
        _ fixture: DurableRecoveryFixture
    ) async throws {
        do {
            try await fixture.retryOwner.destroy(
                identity: LumenMacVirtualDisplayIdentity(id: fixture.key)
            )
            XCTFail("expected replacement ownership to fail closed")
        } catch LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch {
        }
        XCTAssertTrue(fixture.state.ownerMatches(fixture.replacement))
        XCTAssertTrue(fixture.state.releasedTopologyDisplayIDs().isEmpty)
        XCTAssertTrue(fixture.state.removedOwnerTokens().isEmpty)
        XCTAssertTrue(fixture.state.discardedCaptureDisplayIDs().isEmpty)
        XCTAssertTrue(fixture.state.cleanupEvents().isEmpty)
    }

    func assertTopologyReleaseFailureRetainsOwner(
        _ fixture: DurableRecoveryFixture
    ) async throws {
        fixture.state.prepareOriginalOwner(
            fixture.original,
            topologyReleaseFailures: 1
        )
        do {
            try await fixture.retryOwner.destroy(
                identity: LumenMacVirtualDisplayIdentity(id: fixture.key)
            )
            XCTFail("failed topology release must retain the exact owner")
        } catch WorkspaceVirtualDisplayCleanupFailure.releaseTopology {
        }
        XCTAssertTrue(fixture.state.ownerMatches(fixture.original))
        XCTAssertTrue(fixture.state.removedOwnerTokens().isEmpty)
        XCTAssertTrue(fixture.state.discardedCaptureDisplayIDs().isEmpty)
    }

    func assertDurableRecoveryCleansState(
        _ fixture: DurableRecoveryFixture
    ) async throws {
        try await fixture.registry.recoverDisplay(forKey: fixture.key)
        XCTAssertFalse(fixture.state.hasOwner())
        XCTAssertEqual(
            fixture.state.releasedTopologyDisplayIDs(),
            [22, 22]
        )
        XCTAssertEqual(
            fixture.state.removedOwnerTokens(),
            [UInt(bitPattern: ObjectIdentifier(fixture.original))]
        )
        XCTAssertEqual(fixture.state.discardedCaptureDisplayIDs(), [22])
        XCTAssertEqual(fixture.state.cleanupEvents(), [
            .releaseTopology(22),
            .releaseTopology(22),
            .discardCapture(22),
            .removeOwner
        ])
        let expectedOwner = await fixture.expectedOwners.owner(displayID: 22)
        let preparedDisplay = await fixture.preparedDisplays.take(
            displayID: 22,
            ownerToken: 7,
            now: 10
        )
        XCTAssertNil(expectedOwner)
        XCTAssertNil(preparedDisplay)
    }
}
