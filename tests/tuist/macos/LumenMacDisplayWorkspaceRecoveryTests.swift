import XCTest
@testable import LumenMacBridge

private enum DisplayTopologyProbeFailure: Error {
    case mismatch
}

private actor DisplayTopologyProbe: LumenMacDisplayTopologyControlling {
    private let topology: LumenMacPhysicalDisplayTopology
    private var verificationFails = true
    private var restored: [LumenMacPhysicalDisplayTopology] = []

    init(topology: LumenMacPhysicalDisplayTopology) {
        self.topology = topology
    }

    func capture() -> LumenMacPhysicalDisplayTopology {
        topology
    }

    func restore(_ topology: LumenMacPhysicalDisplayTopology) {
        restored.append(topology)
    }

    func verify(_ topology: LumenMacPhysicalDisplayTopology) throws {
        guard !verificationFails, topology == self.topology else {
            throw DisplayTopologyProbeFailure.mismatch
        }
    }

    func allowVerification() {
        verificationFails = false
    }

    func restoredTopologies() -> [LumenMacPhysicalDisplayTopology] {
        restored
    }
}

final class LumenMacDisplayWorkspaceRecoveryTests: XCTestCase {
    func testSnapshotSurvivesRestoreUntilIndependentVerificationSucceeds() async throws {
        // Given: a workspace owns a snapshot and its first physical readback will fail.
        let topology = displayTopology()
        let probe = DisplayTopologyProbe(topology: topology)
        let workspace = LumenMacDisplayWorkspace(topologyController: probe)
        let captured = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        XCTAssertEqual(captured, topology)

        // When: restore applies but independent readback rejects the resulting topology.
        try await workspace.restoreWorkspace(topology)
        do {
            try await workspace.verifyWorkspace(topology)
            XCTFail("expected independent verification failure")
        } catch DisplayTopologyProbeFailure.mismatch {
        }

        // Then: the in-memory snapshot remains until a later successful verification.
        do {
            _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
            XCTFail("expected retained snapshot")
        } catch LumenMacDisplayWorkspaceError.snapshotAlreadyExists {
        }
        await probe.allowVerification()
        try await workspace.verifyWorkspace(topology)
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        let restored = await probe.restoredTopologies()
        XCTAssertEqual(restored, [topology])
    }

    private func displayTopology() -> LumenMacPhysicalDisplayTopology {
        LumenMacPhysicalDisplayTopology(
            displays: [
                LumenMacPhysicalDisplayState(
                    id: "77",
                    mode: LumenMacPhysicalDisplayMode(
                        width: 2560,
                        height: 1440,
                        refreshMillihertz: 60_000,
                        bitDepth: 8
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
}
