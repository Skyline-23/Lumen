import XCTest
@testable import LumenMacBridge

actor IsolationStatusRecorder {
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

actor WorkspaceDisplayMock: LumenMacDisplayWorkspaceManaging {
    private let recorder: WorkspaceExecutionRecorder
    private let isolationFailure: LumenMacDisplayWorkspaceError?
    private var promotionResults: [Bool]
    private var verificationFailuresRemaining: Int

    init(
        recorder: WorkspaceExecutionRecorder,
        isolationFailure: LumenMacDisplayWorkspaceError? = nil,
        promotionResults: [Bool] = [true],
        verificationFailures: Int = 0
    ) {
        self.recorder = recorder
        self.isolationFailure = isolationFailure
        self.promotionResults = promotionResults
        self.verificationFailuresRemaining = verificationFailures
    }

    func snapshotWorkspace(
        targetProcessIdentifiers: [Int32],
        recoveryGeneration _: UInt64
    ) async -> LumenMacPhysicalDisplayTopology {
        await recorder.append(.snapshot(targetProcessIdentifiers))
        return testTopology()
    }

    func promoteVirtualDisplay(
        _ displayID: UInt32,
        logicalSize _: CGSize,
        convergence: LumenMacDisplayPromotionConvergence
    ) async -> Bool {
        await recorder.append(.promote(displayID, convergence))
        guard promotionResults.count > 1 else {
            return promotionResults.first ?? true
        }
        return promotionResults.removeFirst()
    }
    func mirrorOwnedVirtualDisplay(
        _ displayID: UInt32,
        sourceDisplayID: UInt32
    ) async {
        await recorder.append(.mirror(displayID, sourceDisplayID))
    }
    func stageVirtualDisplayUnmirrored(
        _ displayID: UInt32,
        sourceDisplayID: UInt32
    ) async {
        await recorder.append(.prepareDesktopMirror(displayID, sourceDisplayID))
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
    func restoreWorkspace(
        _: LumenMacPhysicalDisplayTopology,
        recoveryGeneration _: UInt64
    ) async {
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

func makeCoordinator() throws -> LumenWorkspaceCoordinator {
    try LumenWorkspaceCoordinator(recoveryJournalPath: temporaryRecoveryJournalPath())
}

func temporaryRecoveryJournalPath() -> String {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "display-recovery.json", directoryHint: .notDirectory)
        .path(percentEncoded: false)
}

func externalIsolatedRequest() -> LumenMacWorkspaceSessionRequest {
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

func testTopology() -> LumenMacPhysicalDisplayTopology {
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
            )
        ],
        windowsAdapterLUID: nil,
        windowsTargetPaths: []
    )
}
