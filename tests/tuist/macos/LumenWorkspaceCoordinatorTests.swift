import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceCoordinatorTests: XCTestCase {
    func testRegistryCallerCancellationRollsBackProvisionalBeforePrepareReturns() async throws {
        let ownerToken: UInt = 0x16
        let effects = WorkspaceRegistryEffects(ownerToken: ownerToken)
        let prepareSuspension = WorkspaceRegistrySuspension(
            honorsCancellation: false
        )
        let registry = makeWorkspaceSessionRegistry(
            effects: effects,
            prepareSuspension: prepareSuspension
        )
        let prepareTask = Task {
            try await registry.prepare(
                workspaceRegistrySnapshot(displayKey: "caller-cancelled-display")
            )
        }
        try await waitForWorkspaceRegistryCondition("caller-cancelled prepare entry") {
            await prepareSuspension.hasEntered()
        }
        prepareTask.cancel()
        try await waitForWorkspaceRegistryCondition("caller cancellation propagation") {
            await prepareSuspension.hasObservedCancellation()
        }
        await prepareSuspension.release()

        do {
            _ = try await prepareTask.value
            XCTFail("cancelled prepare caller must await exact rollback")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected prepare cancellation error: \(error)")
        }
        let effectsSnapshot = await effects.snapshot()
        XCTAssertEqual(effectsSnapshot.releasedOwnerTokens, [ownerToken])
        XCTAssertEqual(effectsSnapshot.journalClearCount, 1)
        XCTAssertEqual(effectsSnapshot.prepareCommitCount, 0)
        XCTAssertEqual(effectsSnapshot.stopCallCount, 1)
        let acceptedCancelledSessionStop = try await registry.stop(
            displayKey: "caller-cancelled-display"
        )
        XCTAssertTrue(
            acceptedCancelledSessionStop,
            "a repeated stop must accept an already-rolled-back provisional session"
        )
    }

    func testRegistryCallerCancellationAfterChildSuccessStillRejectsPublication() async throws {
        let ownerToken: UInt = 0x16
        let effects = WorkspaceRegistryEffects(ownerToken: ownerToken)
        let publicationSuspension = WorkspaceRegistrySuspension(
            honorsCancellation: false
        )
        let registry = makeWorkspaceSessionRegistry(
            effects: effects,
            publicationSuspension: publicationSuspension
        )
        let prepareTask = Task {
            try await registry.prepare(
                workspaceRegistrySnapshot(displayKey: "publication-cancelled-display")
            )
        }
        try await waitForWorkspaceRegistryCondition("ready child publication boundary") {
            await publicationSuspension.hasEntered()
        }
        let readySnapshot = await effects.snapshot()
        XCTAssertEqual(readySnapshot.prepareCommitCount, 1)

        prepareTask.cancel()
        try await waitForWorkspaceRegistryCondition("publication cancellation") {
            await publicationSuspension.hasObservedCancellation()
        }
        await publicationSuspension.release()

        do {
            _ = try await prepareTask.value
            XCTFail("caller cancellation must fence a ready child before publication")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected ready-child cancellation error: \(error)")
        }
        let effectsSnapshot = await effects.snapshot()
        XCTAssertEqual(effectsSnapshot.releasedOwnerTokens, [ownerToken])
        XCTAssertEqual(effectsSnapshot.journalClearCount, 1)
        XCTAssertEqual(effectsSnapshot.stopCallCount, 1)
        let acceptedPublishedSessionStop = try await registry.stop(
            displayKey: "publication-cancelled-display"
        )
        XCTAssertTrue(
            acceptedPublishedSessionStop,
            "a repeated stop must accept an already-rolled-back publication"
        )
    }

    func testRegistryStopAllAndRecoveryShareProvisionalCancellationAndRejectLateSuccess() async throws {
        let ownerToken: UInt = 0x16
        let effects = WorkspaceRegistryEffects(ownerToken: ownerToken)
        let prepareSuspension = WorkspaceRegistrySuspension(
            honorsCancellation: false
        )
        let registry = makeWorkspaceSessionRegistry(
            effects: effects,
            prepareSuspension: prepareSuspension
        )
        let prepareTask = Task {
            try await registry.prepare(
                workspaceRegistrySnapshot(displayKey: "provisional-display")
            )
        }
        try await waitForWorkspaceRegistryCondition("provisional prepare entry") {
            await prepareSuspension.hasEntered()
        }

        let stopAllTask = Task {
            await registry.stopAll()
        }
        let recoveryTask = Task {
            try await registry.recoverPendingWorkspace()
        }
        try await waitForWorkspaceRegistryCondition("provisional cancellation") {
            await prepareSuspension.hasObservedCancellation()
        }
        await prepareSuspension.release()

        await stopAllTask.value
        let recoveredProvisional = try await recoveryTask.value
        XCTAssertTrue(recoveredProvisional)
        do {
            _ = try await prepareTask.value
            XCTFail("expected the revoked provisional generation to reject late success")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected prepare error: \(error)")
        }

        let effectsSnapshot = await effects.snapshot()
        XCTAssertEqual(effectsSnapshot.releasedOwnerTokens, [ownerToken])
        XCTAssertEqual(effectsSnapshot.journalClearCount, 1)
        XCTAssertEqual(effectsSnapshot.prepareCommitCount, 0)
        XCTAssertEqual(effectsSnapshot.stopCallCount, 1)
        let acceptedPublishedProvisionalStop = try await registry.stop(
            displayKey: "provisional-display"
        )
        XCTAssertTrue(
            acceptedPublishedProvisionalStop,
            "a repeated stop must accept an already-rolled-back provisional session"
        )
        try await assertProvisionalSessionWasNotPublished(registry)
    }

    private func assertProvisionalSessionWasNotPublished(
        _ registry: LumenMacWorkspaceSessionRegistry
    ) async throws {
        do {
            _ = try await registry.activate(displayKey: "provisional-display")
            XCTFail("late provisional completion must not publish a session")
        } catch LumenMacWorkspaceSessionError.sessionNotStarted {
        }
    }

    func testRegistryWatchdogRecoveryOwnsActiveSessionAndJoinsConcurrentCleanup() async throws {
        let ownerToken: UInt = 0x16
        let effects = WorkspaceRegistryEffects(ownerToken: ownerToken)
        let stopSuspension = WorkspaceRegistrySuspension(
            honorsCancellation: false
        )
        let registry = makeWorkspaceSessionRegistry(
            effects: effects,
            stopSuspension: stopSuspension
        )
        let activeDisplayID = try await registry.prepare(
            workspaceRegistrySnapshot(displayKey: "active-display")
        )
        XCTAssertEqual(activeDisplayID, 22)

        let firstRecovery = Task {
            try await registry.recoverPendingWorkspace()
        }
        try await waitForWorkspaceRegistryCondition("active recovery stop") {
            await stopSuspension.hasEntered()
        }
        let secondRecovery = Task {
            try await registry.recoverPendingWorkspace()
        }
        let stopAll = Task {
            await registry.stopAll()
        }
        do {
            _ = try await registry.prepare(
                workspaceRegistrySnapshot(displayKey: "forbidden-overlap")
            )
            XCTFail("prepare must not enter a shared teardown flight")
        } catch LumenMacWorkspaceSessionError.sessionAlreadyStarted {
        }
        await stopSuspension.release()

        let firstRecovered = try await firstRecovery.value
        let secondRecovered = try await secondRecovery.value
        XCTAssertTrue(firstRecovered)
        XCTAssertTrue(secondRecovered)
        await stopAll.value
        let effectsSnapshot = await effects.snapshot()
        XCTAssertEqual(effectsSnapshot.releasedOwnerTokens, [ownerToken])
        XCTAssertEqual(effectsSnapshot.journalClearCount, 1)
        XCTAssertEqual(effectsSnapshot.stopCallCount, 1)
        let repeatedRecovery = try await registry.recoverPendingWorkspace()
        let repeatedStop = try await registry.stop(displayKey: "active-display")
        XCTAssertFalse(repeatedRecovery)
        XCTAssertTrue(
            repeatedStop,
            "a repeated stop must accept a workspace already recovered by the watchdog"
        )
    }

}
