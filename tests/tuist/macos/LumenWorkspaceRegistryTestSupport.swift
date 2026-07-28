import XCTest
import Synchronization
@testable import LumenMacBridge

struct WorkspaceVirtualDisplayRegistryState {
    var currentOwner: LumenRetainedVirtualDisplayReference?
    var topologyReleaseFailuresRemaining = 0
    var releasedTopologyDisplayIDs: [UInt32] = []
    var removedOwnerTokens: [UInt] = []
    var discardedCaptureDisplayIDs: [UInt32] = []
    var cleanupEvents: [WorkspaceVirtualDisplayCleanupEvent] = []
}

enum WorkspaceVirtualDisplayCleanupEvent: Equatable {
    case releaseTopology(UInt32)
    case discardCapture(UInt32)
    case removeOwner
}

enum WorkspaceVirtualDisplayCleanupFailure: Error {
    case releaseTopology
}

enum WorkspaceExecutionEvent: Equatable {
    case snapshot([Int32])
    case create(LumenMacDisplayGeometry)
    case configure(UInt32, LumenMacDisplayGeometry)
    case resolve(UInt32)
    case settle(UInt32)
    case stabilize(UInt32)
    case prepareDesktopMirror(UInt32, UInt32)
    case prepareCapture(UInt32)
    case capturePrepared(UInt32)
    case promote(UInt32, LumenMacDisplayPromotionConvergence)
    case mirror(UInt32, UInt32)
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

actor WorkspaceExecutionRecorder {
    private var events: [WorkspaceExecutionEvent] = []

    func append(_ event: WorkspaceExecutionEvent) {
        events.append(event)
    }

    func recordedEvents() -> [WorkspaceExecutionEvent] {
        events
    }
}

enum WorkspaceRegistryTestError: Error {
    case timedOut(String)
    case injectedStopFailure
    case injectedRecoveryFailure
}

enum DesktopMirrorCaptureAdmissionOutcome: Equatable, Sendable {
    case success
    case failure
    case cancellation
}

enum DesktopMirrorCaptureAdmissionFailure: Error {
    case injected
}

actor WorkspaceRegistrySuspension {
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

struct WorkspaceRegistryEffectsSnapshot: Equatable {
    let releasedOwnerTokens: [UInt]
    let journalClearCount: Int
    let prepareCommitCount: Int
    let stopCallCount: Int
    let durableRecoveryCallCount: Int
}

actor WorkspaceRegistryEffects {
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

actor WorkspaceRegistrySessionDouble: LumenMacWorkspaceSessionLifecycle {
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

func waitForWorkspaceRegistryCondition(
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

func workspaceRegistrySnapshot(
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
        potentialPeakLuminanceNits: 0,
        desktopMirrorSourceDisplayID: 0
    )
}

func makeWorkspaceSessionRegistry(
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
