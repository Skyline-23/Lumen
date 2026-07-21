import XCTest
import Synchronization
@testable import LumenMacBridge

private struct WorkspaceVirtualDisplayRegistryState {
    var currentOwner: LumenRetainedVirtualDisplayReference?
    var removedOwnerTokens: [UInt] = []
    var discardedCaptureDisplayIDs: [UInt32] = []
}

private enum WorkspaceExecutionEvent: Equatable {
    case snapshot([Int32])
    case create(LumenMacDisplayGeometry)
    case configure(UInt32, LumenMacDisplayGeometry)
    case resolve(UInt32)
    case promote(UInt32)
    case move(UInt32)
    case isolate(UInt32)
    case firstFrameBarrier
    case positionPointer(UInt32, LumenMacDisplayGeometry)
    case captureContinuity
    case startCapture(UInt32)
    case stopCapture
    case restore
    case verify
    case destroy
}

private actor WorkspaceExecutionRecorder {
    private var events: [WorkspaceExecutionEvent] = []

    func append(_ event: WorkspaceExecutionEvent) {
        events.append(event)
    }

    func recordedEvents() -> [WorkspaceExecutionEvent] {
        events
    }
}

private enum WorkspaceRegistryTestError: Error {
    case timedOut(String)
    case injectedStopFailure
    case injectedRecoveryFailure
}

private actor WorkspaceRegistrySuspension {
    private let honorsCancellation: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var cancellationObserved = false
    private var released = false

    init(honorsCancellation: Bool) {
        self.honorsCancellation = honorsCancellation
    }

    func suspend() async throws {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || (honorsCancellation && Task.isCancelled) {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
        if honorsCancellation {
            try Task.checkCancellation()
        }
    }

    func hasEntered() -> Bool {
        entered
    }

    func hasObservedCancellation() -> Bool {
        cancellationObserved
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func observeCancellation() {
        cancellationObserved = true
        guard honorsCancellation else { return }
        continuation?.resume()
        continuation = nil
    }
}

private struct WorkspaceRegistryEffectsSnapshot: Equatable {
    let releasedOwnerTokens: [UInt]
    let journalClearCount: Int
    let prepareCommitCount: Int
    let stopCallCount: Int
    let durableRecoveryCallCount: Int
}

private actor WorkspaceRegistryEffects {
    private let ownerToken: UInt
    private var journalPresent = false
    private var stopFailuresRemaining: Int
    private var recoveryFailuresRemaining: Int
    private var releasedOwnerTokens: [UInt] = []
    private var journalClearCount = 0
    private var prepareCommitCount = 0
    private var stopCallCount = 0
    private var durableRecoveryCallCount = 0

    init(
        ownerToken: UInt,
        stopFailures: Int = 0,
        recoveryFailures: Int = 0
    ) {
        self.ownerToken = ownerToken
        stopFailuresRemaining = stopFailures
        recoveryFailuresRemaining = recoveryFailures
    }

    func beginPrepare() {
        journalPresent = true
    }

    func recordPrepareCommit() {
        prepareCommitCount += 1
    }

    func stopExactOwner() throws {
        stopCallCount += 1
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw WorkspaceRegistryTestError.injectedStopFailure
        }
        clearJournalAndReleaseOwnerIfNeeded()
    }

    func recoverDurableWorkspace() throws -> Bool {
        durableRecoveryCallCount += 1
        guard journalPresent else { return false }
        if recoveryFailuresRemaining > 0 {
            recoveryFailuresRemaining -= 1
            throw WorkspaceRegistryTestError.injectedRecoveryFailure
        }
        clearJournalAndReleaseOwnerIfNeeded()
        return true
    }

    func snapshot() -> WorkspaceRegistryEffectsSnapshot {
        WorkspaceRegistryEffectsSnapshot(
            releasedOwnerTokens: releasedOwnerTokens,
            journalClearCount: journalClearCount,
            prepareCommitCount: prepareCommitCount,
            stopCallCount: stopCallCount,
            durableRecoveryCallCount: durableRecoveryCallCount
        )
    }

    private func clearJournalAndReleaseOwnerIfNeeded() {
        guard journalPresent else { return }
        journalPresent = false
        releasedOwnerTokens.append(ownerToken)
        journalClearCount += 1
    }
}

private actor WorkspaceRegistrySessionDouble: LumenMacWorkspaceSessionLifecycle {
    private let displayIDValue: UInt32
    private let preparationFence: LumenMacWorkspaceSessionRegistry.PreparationFence
    private let prepareSuspension: WorkspaceRegistrySuspension?
    private let stopSuspension: WorkspaceRegistrySuspension?
    private let effects: WorkspaceRegistryEffects

    init(
        displayID: UInt32,
        preparationFence: @escaping LumenMacWorkspaceSessionRegistry.PreparationFence,
        prepareSuspension: WorkspaceRegistrySuspension?,
        stopSuspension: WorkspaceRegistrySuspension?,
        effects: WorkspaceRegistryEffects
    ) {
        displayIDValue = displayID
        self.preparationFence = preparationFence
        self.prepareSuspension = prepareSuspension
        self.stopSuspension = stopSuspension
        self.effects = effects
    }

    func prepare() async throws {
        await effects.beginPrepare()
        try await prepareSuspension?.suspend()
        try await preparationFence()
        await effects.recordPrepareCommit()
    }

    func activate() async throws -> LumenMacWorkspaceActivationOutcome {
        LumenMacWorkspaceActivationOutcome(isolationStatus: .notRequested)
    }

    func stop() async throws {
        try await stopSuspension?.suspend()
        try await effects.stopExactOwner()
    }

    func displayID() async throws -> UInt32 {
        try await preparationFence()
        return displayIDValue
    }
}

private func waitForWorkspaceRegistryCondition(
    _ description: String,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw WorkspaceRegistryTestError.timedOut(description)
}

private func workspaceRegistrySnapshot(
    displayKey: String
) -> LumenMacWorkspaceSessionRequestSnapshot {
    LumenMacWorkspaceSessionRequestSnapshot(
        displayKey: displayKey,
        displayName: "Registry Test Display",
        width: 1920,
        height: 1080,
        scalePercent: 100,
        dimensionsAreLogical: false,
        refreshRate: 120,
        hdrEnabled: false,
        clientSinkGamutRawValue: 0,
        clientSinkTransferRawValue: 0,
        currentEDRHeadroom: 0,
        potentialEDRHeadroom: 0,
        currentPeakLuminanceNits: 0,
        potentialPeakLuminanceNits: 0
    )
}

private func makeWorkspaceSessionRegistry(
    effects: WorkspaceRegistryEffects,
    prepareSuspension: WorkspaceRegistrySuspension? = nil,
    stopSuspension: WorkspaceRegistrySuspension? = nil,
    publicationSuspension: WorkspaceRegistrySuspension? = nil
) -> LumenMacWorkspaceSessionRegistry {
    LumenMacWorkspaceSessionRegistry(
        resolvePolicy: { .coexist },
        makeSession: { _, preparationFence in
            WorkspaceRegistrySessionDouble(
                displayID: 22,
                preparationFence: preparationFence,
                prepareSuspension: prepareSuspension,
                stopSuspension: stopSuspension,
                effects: effects
            )
        },
        recoverDurableWorkspace: {
            try await effects.recoverDurableWorkspace()
        },
        awaitPublicationBoundary: {
            try? await publicationSuspension?.suspend()
        }
    )
}

private actor IsolationStatusRecorder {
    private var statuses: [LumenMacWorkspaceIsolationStatus] = []

    func append(_ status: LumenMacWorkspaceIsolationStatus) {
        statuses.append(status)
    }

    func waitForStatusCount(_ count: Int) async -> [LumenMacWorkspaceIsolationStatus] {
        while statuses.count < count {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return statuses
    }
}

private actor WorkspaceDisplayMock: LumenMacDisplayWorkspaceManaging {
    private let recorder: WorkspaceExecutionRecorder
    private let isolationFailure: LumenMacDisplayWorkspaceError?
    private var verificationFailuresRemaining: Int

    init(
        recorder: WorkspaceExecutionRecorder,
        isolationFailure: LumenMacDisplayWorkspaceError? = nil,
        verificationFailures: Int = 0
    ) {
        self.recorder = recorder
        self.isolationFailure = isolationFailure
        self.verificationFailuresRemaining = verificationFailures
    }

    func snapshotWorkspace(
        targetProcessIdentifiers: [Int32]
    ) async -> LumenMacPhysicalDisplayTopology {
        await recorder.append(.snapshot(targetProcessIdentifiers))
        return testTopology()
    }

    func promoteVirtualDisplay(_ displayID: UInt32) async -> Bool {
        await recorder.append(.promote(displayID))
        return true
    }
    func moveTargetWindows(to displayID: UInt32) async {
        await recorder.append(.move(displayID))
    }
    func isolateVirtualDisplay(_ displayID: UInt32) async throws {
        await recorder.append(.isolate(displayID))
        if let isolationFailure {
            throw isolationFailure
        }
    }
    func restoreWorkspace(_: LumenMacPhysicalDisplayTopology) async {
        await recorder.append(.restore)
    }
    func verifyWorkspace(_: LumenMacPhysicalDisplayTopology) async throws {
        await recorder.append(.verify)
        if verificationFailuresRemaining > 0 {
            verificationFailuresRemaining -= 1
            throw LumenMacDisplayWorkspaceError.physicalTopologyMismatch
        }
    }
    func discardSnapshot() async {}
}

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
        let stoppedCancelledSession = try await registry.stop(
            displayKey: "caller-cancelled-display"
        )
        XCTAssertFalse(stoppedCancelledSession)
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
        let stoppedPublishedSession = try await registry.stop(
            displayKey: "publication-cancelled-display"
        )
        XCTAssertFalse(stoppedPublishedSession)
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
        let stoppedPublishedProvisional = try await registry.stop(
            displayKey: "provisional-display"
        )
        XCTAssertFalse(stoppedPublishedProvisional)
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
        XCTAssertFalse(repeatedStop)
    }

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
        let key = "failed-prepare-retry-owner"
        let original = try XCTUnwrap(
            (LumenMacVirtualDisplay.self as AnyObject)
                .perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue() as? LumenMacVirtualDisplay
        )
        let replacement = try XCTUnwrap(
            (LumenMacVirtualDisplay.self as AnyObject)
                .perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue() as? LumenMacVirtualDisplay
        )
        let state = Mutex(
            WorkspaceVirtualDisplayRegistryState(
                currentOwner: LumenRetainedVirtualDisplayReference(display: original)
            )
        )
        let expectedOwners = LumenExpectedDisplayOwnerStore<UInt>()
        let preparedDisplays = LumenPreparedDisplayStore<UInt32>()
        await expectedOwners.set(7, displayID: 22)
        let preparedGeneration = await preparedDisplays.begin(
            displayID: 22,
            ownerToken: 7
        )
        try await preparedDisplays.complete(
            displayID: 22,
            ownerToken: 7,
            generation: preparedGeneration,
            value: 22,
            expiresAt: 100
        )
        let registry = LumenMacOwnedVirtualDisplayRegistry(
            access: LumenMacVirtualDisplayRegistryAccess(
                currentOwner: { requestedKey in
                    guard requestedKey == key else { return nil }
                    return state.withLock { $0.currentOwner }
                },
                displayID: { _ in 22 },
                discardCaptureState: { displayID in
                    await preparedDisplays.discard(displayID: displayID)
                    await expectedOwners.discard(displayID: displayID)
                    state.withLock {
                        $0.discardedCaptureDisplayIDs.append(displayID)
                    }
                },
                removeMatchingOwner: { requestedKey, expectedOwner in
                    guard requestedKey == key else { return false }
                    return state.withLock { current in
                        guard current.currentOwner?.display === expectedOwner.display else {
                            return false
                        }
                        current.removedOwnerTokens.append(expectedOwner.ownerToken)
                        current.currentOwner = nil
                        return true
                    }
                }
            )
        )
        try await registry.register(
            LumenRetainedVirtualDisplayReference(display: original),
            forKey: key
        )
        let retryOwner = LumenMacVirtualDisplayOwner(
            ownershipRegistry: registry
        )
        state.withLock {
            $0.currentOwner = LumenRetainedVirtualDisplayReference(display: replacement)
        }

        do {
            try await retryOwner.destroy(
                identity: LumenMacVirtualDisplayIdentity(id: key)
            )
            XCTFail("expected replacement ownership to fail closed")
        } catch LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch {
        }
        XCTAssertTrue(state.withLock { $0.currentOwner?.display === replacement })
        XCTAssertTrue(state.withLock { $0.removedOwnerTokens.isEmpty })
        XCTAssertTrue(state.withLock { $0.discardedCaptureDisplayIDs.isEmpty })

        state.withLock {
            $0.currentOwner = LumenRetainedVirtualDisplayReference(display: original)
        }
        try await retryOwner.destroy(
            identity: LumenMacVirtualDisplayIdentity(id: key)
        )
        XCTAssertNil(state.withLock { $0.currentOwner })
        XCTAssertEqual(state.withLock { $0.removedOwnerTokens }, [UInt(bitPattern: ObjectIdentifier(original))])
        XCTAssertEqual(state.withLock { $0.discardedCaptureDisplayIDs }, [22])
        let recoveredExpectedOwner = await expectedOwners.owner(displayID: 22)
        let recoveredPreparedDisplay = await preparedDisplays.take(
            displayID: 22,
            ownerToken: 7,
            now: 10
        )
        XCTAssertNil(recoveredExpectedOwner)
        XCTAssertNil(recoveredPreparedDisplay)
    }

    func testRetinaDesktopScalePreservesNativeStreamPixels() throws {
        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            )
        )

        XCTAssertEqual(geometry.streamWidth, 2388)
        XCTAssertEqual(geometry.streamHeight, 1668)
        XCTAssertEqual(geometry.logicalWidth, 1592)
        XCTAssertEqual(geometry.logicalHeight, 1112)
        XCTAssertEqual(geometry.backingWidth, 2388)
        XCTAssertEqual(geometry.backingHeight, 1668)
    }

    func testCoexistWorkspaceDoesNotPromoteOrMoveWindows() async throws {
        let coordinator = try makeCoordinator()
        try await coordinator.beginSession(policy: .coexist)

        let actions = try await completePendingCommands(coordinator)

        XCTAssertEqual(
            actions,
            [
                .snapshotWorkspace,
                .createVirtualDisplay,
                .configureVirtualDisplay,
                .startCapture,
            ]
        )
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .active)
    }

    func testExternalCaptureOwnershipOmitsCaptureCommands() async throws {
        let coordinator = try makeCoordinator()
        try await coordinator.beginSession(policy: .coexist, manageCapture: false)

        let startupActions = try await completePendingCommands(coordinator)
        XCTAssertFalse(startupActions.contains(.startCapture))
        let activeState = try await coordinator.currentState()
        XCTAssertEqual(activeState, .active)

        try await coordinator.endSession()
        let teardownActions = try await completePendingCommands(coordinator)
        XCTAssertFalse(teardownActions.contains(.stopCapture))
        XCTAssertEqual(teardownActions, [.destroyVirtualDisplay])
    }

    func testFocusedWorkspaceRestoresAfterCaptureStops() async throws {
        let coordinator = try makeCoordinator()
        try await coordinator.beginSession(policy: .focusedWorkspace)

        let startup = try await completePendingCommands(coordinator)
        XCTAssertTrue(startup.contains(.promoteVirtualMain))
        XCTAssertTrue(startup.contains(.moveTargetWindows))
        XCTAssertFalse(startup.contains(.applyIsolation))

        try await coordinator.endSession()
        let teardown = try await completePendingCommands(coordinator)
        XCTAssertEqual(
            teardown,
            [
                .stopCapture,
                .restoreWorkspace,
                .verifyPhysicalDisplays,
                .destroyVirtualDisplay,
            ]
        )
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testExecutorPassesRustGeometryToNativeDisplayOperations() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 42
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { displayID in
                await recorder.append(.resolve(displayID))
            },
            startCapture: { displayID in
                await recorder.append(.startCapture(displayID))
            },
            stopCapture: {},
            destroyVirtualDisplay: { _ in }
        )
        let executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [123],
            displayMode: LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            ),
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder)
        )
        let coordinator = try makeCoordinator()

        try await coordinator.beginSession(policy: .coexist)
        try await coordinator.executePendingCommands(using: executor)

        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            )
        )
        let events = await recorder.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .snapshot([123]),
                .create(geometry),
                .configure(42, geometry),
                .startCapture(42),
            ]
        )
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .active)
    }

    func testIsolatedWorkspaceExecutesTypedDisplayIsolation() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, _ in 55 },
            configureVirtualDisplay: { _, _ in },
            verifyVirtualDisplay: { _ in },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { _ in }
        )
        let executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [],
            displayMode: LumenMacDisplayModeRequest(
                width: 1920,
                height: 1080,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder)
        )
        let coordinator = try makeCoordinator()

        try await coordinator.beginSession(
            policy: .isolatedWorkspace,
            manageCapture: false
        )
        try await coordinator.executePendingCommands(using: executor)

        let events = await recorder.recordedEvents()
        XCTAssertTrue(events.contains(.isolate(55)))
        try await coordinator.endSession()
        try await coordinator.executePendingCommands(using: executor)
    }

    func testExternalCaptureStartsPhysicalIsolationImmediatelyAfterFirstFrameReadiness() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let statusRecorder = IsolationStatusRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 88
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { displayID in
                await recorder.append(.resolve(displayID))
            },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) },
            waitForExternalFirstEncodedFrame: {
                await recorder.append(.firstFrameBarrier)
            },
            verifyCaptureContinuity: {
                await recorder.append(.captureContinuity)
            },
            positionPointer: { displayID, geometry in
                await recorder.append(.positionPointer(displayID, geometry))
            }
        )
        let request = externalIsolatedRequest()
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: makeCoordinator(),
            isolationStatusHandler: { status in
                await statusRecorder.append(status)
            }
        )

        try await session.prepare()

        let preparedEvents = await recorder.recordedEvents()
        XCTAssertFalse(preparedEvents.contains(.firstFrameBarrier))
        let resolveIndex = try XCTUnwrap(preparedEvents.firstIndex(of: .resolve(88)))
        XCTAssertTrue(preparedEvents.contains(.promote(88)))
        XCTAssertFalse(preparedEvents.contains(.move(88)))
        XCTAssertFalse(preparedEvents.contains(.isolate(88)))
        let preparedState = try await session.state()
        XCTAssertEqual(preparedState, .starting)

        let outcome = try await session.activate()
        let expectedIsolationStatus = LumenMacWorkspaceIsolationStatus.applied
        XCTAssertEqual(outcome.isolationStatus, .pending)
        let statuses = await statusRecorder.waitForStatusCount(1)
        XCTAssertEqual(statuses, [expectedIsolationStatus])

        let activeEvents = await recorder.recordedEvents()
        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)
        let barrierIndex = try XCTUnwrap(activeEvents.firstIndex(of: .firstFrameBarrier))
        let promotionIndices = activeEvents.indices.filter {
            activeEvents[$0] == .promote(88)
        }
        let isolateIndex = try XCTUnwrap(activeEvents.firstIndex(of: .isolate(88)))
        let continuityIndex = try XCTUnwrap(activeEvents.firstIndex(of: .captureContinuity))
        let pointerIndices = activeEvents.indices.filter {
            activeEvents[$0] == .positionPointer(88, geometry)
        }
        let finalResolveIndex = try XCTUnwrap(activeEvents.lastIndex(of: .resolve(88)))
        XCTAssertLessThan(resolveIndex, barrierIndex)
        XCTAssertEqual(promotionIndices.count, 2)
        XCTAssertLessThan(promotionIndices[0], barrierIndex)
        XCTAssertLessThan(barrierIndex, promotionIndices[1])
        XCTAssertLessThan(promotionIndices[1], pointerIndices[0])
        XCTAssertLessThan(barrierIndex, finalResolveIndex)
        XCTAssertLessThan(finalResolveIndex, isolateIndex)
        XCTAssertEqual(pointerIndices.count, 2)
        XCTAssertLessThan(barrierIndex, pointerIndices[0])
        XCTAssertLessThan(pointerIndices[0], isolateIndex)
        XCTAssertLessThan(isolateIndex, pointerIndices[1])
        XCTAssertLessThan(pointerIndices[1], continuityIndex)
        XCTAssertLessThan(isolateIndex, continuityIndex)
        XCTAssertLessThan(barrierIndex, isolateIndex)
        XCTAssertEqual(activeEvents.filter { $0 == .isolate(88) }.count, 1)
        let activeState = try await session.state()
        XCTAssertEqual(activeState, .active)
        try await session.stop()
    }

    func testPointerCenterUsesVirtualDisplayLogicalGeometry() throws {
        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            LumenMacDisplayModeRequest(
                width: 3512,
                height: 2420,
                scalePercent: 150,
                dimensionsAreLogical: false
            )
        )

        let point = LumenMacPointerPositioner.centerPoint(geometry: geometry)

        XCTAssertEqual(point.x, CGFloat(geometry.logicalWidth) / 2)
        XCTAssertEqual(point.y, CGFloat(geometry.logicalHeight) / 2)
    }

    func testUnavailablePhysicalIsolationDoesNotBlockOrStopTheStreamSession() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let statusRecorder = IsolationStatusRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 114
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { displayID in
                await recorder.append(.resolve(displayID))
            },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) },
            waitForExternalFirstEncodedFrame: {
                await recorder.append(.firstFrameBarrier)
            }
        )
        let journalPath = temporaryRecoveryJournalPath()
        let session = try LumenMacWorkspaceSession(
            request: externalIsolatedRequest(),
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(
                recorder: recorder,
                isolationFailure: .isolationUnavailable("display 114 was not published")
            ),
            coordinator: LumenWorkspaceCoordinator(recoveryJournalPath: journalPath),
            isolationStatusHandler: { status in
                await statusRecorder.append(status)
            }
        )

        try await session.prepare()
        let outcome = try await session.activate()

        let expectedIsolationStatus = LumenMacWorkspaceIsolationStatus.unavailable(
            message: "display 114 was not published"
        )
        XCTAssertEqual(outcome.isolationStatus, .pending)
        let statuses = await statusRecorder.waitForStatusCount(1)
        XCTAssertEqual(statuses, [expectedIsolationStatus])
        let activeState = try await session.state()
        XCTAssertEqual(activeState, .active)
        let activeEvents = await recorder.recordedEvents()
        XCTAssertTrue(activeEvents.contains(.firstFrameBarrier))
        XCTAssertTrue(activeEvents.contains(.isolate(114)))
        XCTAssertFalse(activeEvents.contains(.restore))
        XCTAssertFalse(activeEvents.contains(.destroy))

        try await session.stop()
        let stoppedEvents = await recorder.recordedEvents()
        XCTAssertTrue(stoppedEvents.contains(.restore))
        XCTAssertTrue(stoppedEvents.contains(.verify))
        XCTAssertTrue(stoppedEvents.contains(.destroy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
    }

    func testVerificationFailureDestroysOwnedDisplayBeforeDurableRecoveryClearsJournal() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 115
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { displayID in
                await recorder.append(.resolve(displayID))
            },
            startCapture: { _ in },
            stopCapture: { await recorder.append(.stopCapture) },
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) },
            waitForExternalFirstEncodedFrame: {
                await recorder.append(.firstFrameBarrier)
            }
        )
        let journalPath = temporaryRecoveryJournalPath()
        let session = try LumenMacWorkspaceSession(
            request: externalIsolatedRequest(),
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(
                recorder: recorder,
                verificationFailures: 1
            ),
            coordinator: LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        )

        try await session.prepare()
        _ = try await session.activate()
        do {
            try await session.stop()
            XCTFail("expected physical verification failure to remain typed")
        } catch LumenMacDisplayWorkspaceError.physicalTopologyMismatch {}
        do {
            try await session.stop()
            XCTFail("failed stop cleanup must remain recovery pending")
        } catch LumenMacWorkspaceSessionError.recoveryDidNotComplete {
        }

        let failedStopEvents = await recorder.recordedEvents()
        XCTAssertEqual(failedStopEvents.filter { $0 == .destroy }.count, 1)
        let journalData = try Data(contentsOf: URL(fileURLWithPath: journalPath))
        let journalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: journalData) as? [String: Any]
        )
        let journal = try XCTUnwrap(journalObject["journal"] as? [String: Any])
        XCTAssertEqual(journal["phase"] as? String, "physical-restored")

        let recoveryRecorder = WorkspaceExecutionRecorder()
        let recoveryCoordinator = try LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        let recoveryExecutor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [],
            displayMode: LumenMacDisplayModeRequest(
                width: 1_920,
                height: 1_080,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            operations: LumenMacWorkspaceNativeOperations(
                createVirtualDisplay: { _, _ in 0 },
                configureVirtualDisplay: { _, _ in },
                verifyVirtualDisplay: { _ in },
                startCapture: { _ in },
                stopCapture: {},
                destroyVirtualDisplay: { _ in await recoveryRecorder.append(.destroy) }
            ),
            displayWorkspace: WorkspaceDisplayMock(recorder: recoveryRecorder)
        )
        let admitted = try await recoveryCoordinator.beginSession(
            policy: .coexist,
            manageCapture: false
        )
        XCTAssertFalse(admitted)
        let recoveryError = try await recoveryCoordinator.executePendingCommandsRecovering(
            using: recoveryExecutor
        )

        XCTAssertNil(recoveryError)
        let recoveryEvents = await recoveryRecorder.recordedEvents()
        XCTAssertEqual(recoveryEvents.filter { $0 == .destroy }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
    }

    func testDisplayReadinessFailureRollsBackOwnedDisplayBeforePromotion() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 90
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
                throw LumenScreenCaptureError.displayUnavailable(displayID)
            },
            verifyVirtualDisplay: { displayID in
                await recorder.append(.resolve(displayID))
            },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) },
            waitForExternalFirstEncodedFrame: {
                await recorder.append(.firstFrameBarrier)
            }
        )
        let journalPath = temporaryRecoveryJournalPath()
        let session = try LumenMacWorkspaceSession(
            request: externalIsolatedRequest(),
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        )

        do {
            try await session.prepare()
            XCTFail("expected display readiness to fail closed")
        } catch LumenScreenCaptureError.displayUnavailable(90) {}

        let events = await recorder.recordedEvents()
        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            externalIsolatedRequest().displayMode
        )
        XCTAssertTrue(events.contains(.configure(90, geometry)))
        XCTAssertFalse(events.contains(.resolve(90)))
        XCTAssertFalse(events.contains(.promote(90)))
        XCTAssertFalse(events.contains(.firstFrameBarrier))
        XCTAssertFalse(events.contains(.isolate(90)))
        XCTAssertFalse(events.contains(.restore))
        XCTAssertFalse(events.contains(.verify))
        XCTAssertTrue(events.contains(.destroy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
        let recoveredState = try await session.state()
        XCTAssertEqual(recoveredState, .idle)
    }

    func testPrepareCleanupFailureRemainsRecoveryPendingInsteadOfClaimingIdle() async throws {
        enum ExpectedFailure: Error {
            case readiness
            case destroy
        }
        let recorder = WorkspaceExecutionRecorder()
        let journalPath = temporaryRecoveryJournalPath()
        defer { try? FileManager.default.removeItem(atPath: journalPath) }
        let session = try LumenMacWorkspaceSession(
            request: externalIsolatedRequest(),
            operations: LumenMacWorkspaceNativeOperations(
                createVirtualDisplay: { _, geometry in
                    await recorder.append(.create(geometry))
                    return 116
                },
                configureVirtualDisplay: { displayID, geometry in
                    await recorder.append(.configure(displayID, geometry))
                    throw ExpectedFailure.readiness
                },
                verifyVirtualDisplay: { _ in },
                startCapture: { _ in },
                stopCapture: {},
                destroyVirtualDisplay: { _ in
                    await recorder.append(.destroy)
                    throw ExpectedFailure.destroy
                }
            ),
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        )

        do {
            try await session.prepare()
            XCTFail("expected failed display cleanup to remain terminal")
        } catch ExpectedFailure.destroy {
        }
        do {
            try await session.stop()
            XCTFail("recovery-pending session must require durable recovery")
        } catch LumenMacWorkspaceSessionError.recoveryDidNotComplete {
        }
        let events = await recorder.recordedEvents()
        XCTAssertEqual(events.filter { $0 == .destroy }.count, 1)
    }

    func testFailedExternalFirstFrameBarrierRestoresPhysicalDisplaysBeforeDestroy() async throws {
        enum ExpectedFailure: Error {
            case firstFrameTimeout
        }
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 89
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { _ in },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) },
            waitForExternalFirstEncodedFrame: {
                await recorder.append(.firstFrameBarrier)
                throw ExpectedFailure.firstFrameTimeout
            }
        )
        let session = try LumenMacWorkspaceSession(
            request: externalIsolatedRequest(),
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: makeCoordinator()
        )
        try await session.prepare()

        do {
            try await session.activate()
            XCTFail("expected first-frame barrier failure")
        } catch ExpectedFailure.firstFrameTimeout {}

        let events = await recorder.recordedEvents()
        XCTAssertTrue(events.contains(.firstFrameBarrier))
        XCTAssertFalse(events.contains(.isolate(89)))
        XCTAssertTrue(events.contains(.restore))
        XCTAssertTrue(events.contains(.verify))
        XCTAssertTrue(events.contains(.destroy))
        let recoveredState = try await session.state()
        XCTAssertEqual(recoveredState, .idle)
    }

    func testWorkspaceSessionRunsRustPlannedLifecycleThroughNativeOperations() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 73
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { _ in },
            startCapture: { displayID in
                await recorder.append(.startCapture(displayID))
            },
            stopCapture: {
                await recorder.append(.stopCapture)
            },
            destroyVirtualDisplay: { _ in
                await recorder.append(.destroy)
            }
        )
        let request = LumenMacWorkspaceSessionRequest(
            displayMode: LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            ),
            captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
        )
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: makeCoordinator()
        )

        try await session.start()
        let displayID = try await session.displayID()
        let activeState = try await session.state()
        XCTAssertEqual(activeState, .active)
        XCTAssertEqual(displayID, 73)
        try await session.stop()
        let idleState = try await session.state()
        XCTAssertEqual(idleState, .idle)

        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)
        let events = await recorder.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .snapshot([]),
                .create(geometry),
                .configure(73, geometry),
                .startCapture(73),
                .stopCapture,
                .destroy,
            ]
        )
    }

    func testWorkspaceSessionRestoresResourcesAfterCaptureStartupFailure() async throws {
        enum ExpectedFailure: Error {
            case captureStartup
        }

        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 91
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { _ in },
            startCapture: { displayID in
                await recorder.append(.startCapture(displayID))
                throw ExpectedFailure.captureStartup
            },
            stopCapture: {
                await recorder.append(.stopCapture)
            },
            destroyVirtualDisplay: { _ in
                await recorder.append(.destroy)
            }
        )
        let request = LumenMacWorkspaceSessionRequest(
            displayMode: LumenMacDisplayModeRequest(
                width: 1920,
                height: 1080,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
        )
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: makeCoordinator()
        )

        do {
            try await session.start()
            XCTFail("Expected capture startup failure")
        } catch ExpectedFailure.captureStartup {
        }

        let state = try await session.state()
        XCTAssertEqual(state, .idle)
        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)
        let events = await recorder.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .snapshot([]),
                .create(geometry),
                .configure(91, geometry),
                .startCapture(91),
                .destroy,
            ]
        )
    }

    func testVirtualDisplayConfigurationPreservesHDRSinkContract() throws {
        let capture = LumenMacCaptureConfiguration(
            displayID: 0,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    currentEDRHeadroom: 1.2,
                    potentialEDRHeadroom: 16,
                    currentPeakLuminanceNits: 120,
                    potentialPeakLuminanceNits: 1600,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )
        let request = LumenMacWorkspaceSessionRequest(
            displayMode: LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            ),
            refreshRate: 120,
            captureConfiguration: capture
        )
        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)

        let configuration = try LumenMacVirtualDisplayConfigurationFactory.make(
            geometry: geometry,
            request: request
        )

        XCTAssertEqual(configuration.backingWidth, 2388)
        XCTAssertEqual(configuration.logicalWidth, 1592)
        XCTAssertEqual(configuration.refreshRate, 120)
        XCTAssertTrue(configuration.highDensity)
        XCTAssertTrue(configuration.hdrEnabled)
        XCTAssertEqual(configuration.gamut.rawValue, 1)
        XCTAssertEqual(configuration.transfer.rawValue, 1)
        XCTAssertEqual(configuration.currentPeakLuminanceNits, 120)
        XCTAssertEqual(configuration.potentialPeakLuminanceNits, 1600)
    }

    func testWorkspaceRequestBoxBuildsExternalCaptureSession() throws {
        let box = LumenMacWorkspaceSessionRequestBox()
        box.displayKey = "client-key"
        box.width = 2732
        box.height = 2048
        box.scalePercent = 77
        box.refreshRate = 120
        box.hdrEnabled = true
        box.clientSinkGamutRawValue = 3
        box.clientSinkTransferRawValue = 2
        box.potentialEDRHeadroom = 16
        box.potentialPeakLuminanceNits = 1600

        let request = box.makeRequest(policy: .isolatedWorkspace)

        XCTAssertEqual(request.displayKey, "client-key")
        XCTAssertEqual(request.policy, .isolatedWorkspace)
        XCTAssertFalse(request.managesCapture)
        XCTAssertEqual(request.displayMode.scalePercent, 77)
        XCTAssertTrue(request.captureConfiguration.usesHDRTransport)
        XCTAssertEqual(
            request.captureConfiguration.sinkRequest.capability.potentialPeakLuminanceNits,
            1600
        )
    }

    private func completePendingCommands(
        _ coordinator: LumenWorkspaceCoordinator
    ) async throws -> [LumenMacWorkspaceAction] {
        var actions: [LumenMacWorkspaceAction] = []
        while let command = try await coordinator.nextCommand() {
            actions.append(command.action)
            let result: LumenMacWorkspaceCommandResult
            switch command.action {
            case .snapshotWorkspace:
                result = .physicalTopology(testTopology())
            case .createVirtualDisplay:
                if case .virtualDisplayIdentity(let identity) = command.payload {
                    result = .virtualDisplayIdentity(identity)
                } else {
                    XCTFail("expected virtual display identity payload")
                    result = .failed
                }
            default:
                result = .succeeded
            }
            try await coordinator.complete(command, result: result)
        }
        return actions
    }

    private func makeCoordinator() throws -> LumenWorkspaceCoordinator {
        try LumenWorkspaceCoordinator(recoveryJournalPath: temporaryRecoveryJournalPath())
    }

    private func temporaryRecoveryJournalPath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "display-recovery.json", directoryHint: .notDirectory)
            .path(percentEncoded: false)
    }

    private func externalIsolatedRequest() -> LumenMacWorkspaceSessionRequest {
        LumenMacWorkspaceSessionRequest(
            policy: .isolatedWorkspace,
            displayMode: LumenMacDisplayModeRequest(
                width: 1920,
                height: 1080,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            managesCapture: false,
            captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
        )
    }
}

private func testTopology() -> LumenMacPhysicalDisplayTopology {
    LumenMacPhysicalDisplayTopology(
        displays: [
            LumenMacPhysicalDisplayState(
                id: "1",
                mode: LumenMacPhysicalDisplayMode(
                    width: 2560,
                    height: 1440,
                    refreshMillihertz: 120_000,
                    bitDepth: 10
                ),
                originX: 0,
                originY: 0,
                mirrorMasterID: nil,
                enabled: true,
                active: true,
                online: true
            ),
        ],
        windowsAdapterLUID: nil,
        windowsTargetPaths: []
    )
}
