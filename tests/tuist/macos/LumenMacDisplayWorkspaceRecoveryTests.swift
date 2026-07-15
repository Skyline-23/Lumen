import XCTest
import Synchronization
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
        let workspace = LumenMacDisplayWorkspace(
            topologyController: probe,
            physicalDisplayController: RecordingPhysicalDisplayController()
        )
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

    func testIsolationDisablesEverySnapshottedPhysicalDisplayAndKeepsVirtualActive() async throws {
        let fixture = IsolationDisplayFixture(physicalTopology: isolationPhysicalTopology())
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(fixture: fixture)
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        fixture.publishVirtualDisplay(99)

        try await workspace.isolateVirtualDisplay(99)

        XCTAssertEqual(
            fixture.controlCalls(),
            [
                .init(displayID: 41, enabled: false),
                .init(displayID: 42, enabled: false),
            ]
        )
        XCTAssertFalse(fixture.state(displayID: 41)?.active ?? true)
        XCTAssertFalse(fixture.state(displayID: 42)?.active ?? true)
        XCTAssertTrue(fixture.state(displayID: 99)?.active ?? false)
    }

    func testSecondDisplayDisableFailureRollsBackFirstDisplay() async throws {
        let topology = isolationPhysicalTopology()
        let fixture = IsolationDisplayFixture(physicalTopology: topology)
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(
                fixture: fixture,
                failingDisableDisplayID: 42
            )
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        fixture.publishVirtualDisplay(99)

        await XCTAssertThrowsErrorAsync {
            try await workspace.isolateVirtualDisplay(99)
        }

        XCTAssertEqual(
            fixture.controlCalls(),
            [
                .init(displayID: 41, enabled: false),
                .init(displayID: 42, enabled: false),
                .init(displayID: 41, enabled: true),
            ]
        )
        XCTAssertEqual(fixture.physicalTopology(), topology)
    }

    func testRestoreReenablesPhysicalDisplaysBeforeExactTopologyVerification() async throws {
        let topology = isolationPhysicalTopology()
        let fixture = IsolationDisplayFixture(physicalTopology: topology)
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(fixture: fixture)
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        fixture.publishVirtualDisplay(99)
        try await workspace.isolateVirtualDisplay(99)

        try await workspace.restoreWorkspace(topology)
        try await workspace.verifyWorkspace(topology)

        XCTAssertEqual(
            fixture.controlCalls(),
            [
                .init(displayID: 41, enabled: false),
                .init(displayID: 42, enabled: false),
                .init(displayID: 41, enabled: true),
                .init(displayID: 42, enabled: true),
            ]
        )
        XCTAssertEqual(fixture.physicalTopology(), topology)
    }

    func testProbeFailurePerformsNoDisplayMutationOrCoordinateFallback() async throws {
        let fixture = IsolationDisplayFixture(physicalTopology: isolationPhysicalTopology())
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(
                fixture: fixture,
                probeFails: true
            )
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        fixture.publishVirtualDisplay(99)

        await XCTAssertThrowsErrorAsync {
            try await workspace.isolateVirtualDisplay(99)
        }

        XCTAssertTrue(fixture.controlCalls().isEmpty)
        XCTAssertEqual(fixture.physicalTopology(), isolationPhysicalTopology())
    }

    func testIndependentReadbackFailureRollsBackEveryReportedDisable() async throws {
        let topology = isolationPhysicalTopology()
        let fixture = IsolationDisplayFixture(physicalTopology: topology)
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(
                fixture: fixture,
                doesNotApplyDisable: true
            )
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        fixture.publishVirtualDisplay(99)

        await XCTAssertThrowsErrorAsync {
            try await workspace.isolateVirtualDisplay(99)
        }

        XCTAssertEqual(
            fixture.controlCalls(),
            [
                .init(displayID: 41, enabled: false),
                .init(displayID: 42, enabled: false),
                .init(displayID: 42, enabled: true),
                .init(displayID: 41, enabled: true),
            ]
        )
        XCTAssertEqual(fixture.physicalTopology(), topology)
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

    private func isolationPhysicalTopology() -> LumenMacPhysicalDisplayTopology {
        LumenMacPhysicalDisplayTopology(
            displays: [
                physicalDisplayState(id: "41", originX: 0),
                physicalDisplayState(id: "42", originX: 2560),
            ],
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
    }

    private func physicalDisplayState(
        id: String,
        originX: Int32,
        enabled: Bool = true,
        active: Bool = true
    ) -> LumenMacPhysicalDisplayState {
        LumenMacPhysicalDisplayState(
            id: id,
            mode: LumenMacPhysicalDisplayMode(
                width: 2560,
                height: 1440,
                refreshMillihertz: 60_000,
                bitDepth: 8
            ),
            originX: originX,
            originY: 0,
            mirrorMasterID: nil,
            enabled: enabled,
            active: active,
            online: true
        )
    }
}

private struct PhysicalControlCall: Equatable {
    let displayID: UInt32
    let enabled: Bool
}

private final class IsolationDisplayFixture: Sendable {
    private struct State: Sendable {
        var topology: LumenMacPhysicalDisplayTopology
        var originalPhysicalTopology: LumenMacPhysicalDisplayTopology
        var calls: [PhysicalControlCall] = []
    }

    private let storage: Mutex<State>

    init(physicalTopology: LumenMacPhysicalDisplayTopology) {
        storage = Mutex(
            State(
                topology: physicalTopology,
                originalPhysicalTopology: physicalTopology
            )
        )
    }

    func publishVirtualDisplay(_ displayID: UInt32) {
        storage.withLock { state in
            state.topology = LumenMacPhysicalDisplayTopology(
                displays: state.topology.displays + [
                    LumenMacPhysicalDisplayState(
                        id: String(displayID),
                        mode: LumenMacPhysicalDisplayMode(
                            width: 1920,
                            height: 1080,
                            refreshMillihertz: 120_000,
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

    func setEnabled(_ enabled: Bool, displayID: UInt32) {
        storage.withLock { state in
            state.calls.append(.init(displayID: displayID, enabled: enabled))
            state.topology = LumenMacPhysicalDisplayTopology(
                displays: state.topology.displays.map { display in
                    guard display.id == String(displayID) else { return display }
                    return LumenMacPhysicalDisplayState(
                        id: display.id,
                        mode: display.mode,
                        originX: display.originX,
                        originY: display.originY,
                        mirrorMasterID: display.mirrorMasterID,
                        enabled: enabled,
                        active: enabled,
                        online: display.online
                    )
                },
                windowsAdapterLUID: nil,
                windowsTargetPaths: []
            )
        }
    }

    func recordControlCall(_ enabled: Bool, displayID: UInt32) {
        storage.withLock { state in
            state.calls.append(.init(displayID: displayID, enabled: enabled))
        }
    }

    func restore(_ topology: LumenMacPhysicalDisplayTopology) {
        storage.withLock { state in
            let virtualDisplays = state.topology.displays.filter { current in
                !topology.displays.contains(where: { $0.id == current.id })
            }
            state.topology = LumenMacPhysicalDisplayTopology(
                displays: topology.displays + virtualDisplays,
                windowsAdapterLUID: nil,
                windowsTargetPaths: []
            )
        }
    }

    func topology() -> LumenMacPhysicalDisplayTopology {
        storage.withLock { $0.topology }
    }

    func physicalTopology() -> LumenMacPhysicalDisplayTopology {
        storage.withLock { state in
            let physicalIDs = Set(state.originalPhysicalTopology.displays.map(\.id))
            return LumenMacPhysicalDisplayTopology(
                displays: state.topology.displays.filter { physicalIDs.contains($0.id) },
                windowsAdapterLUID: nil,
                windowsTargetPaths: []
            )
        }
    }

    func state(displayID: UInt32) -> LumenMacPhysicalDisplayState? {
        storage.withLock { state in
            state.topology.displays.first { $0.id == String(displayID) }
        }
    }

    func controlCalls() -> [PhysicalControlCall] {
        storage.withLock { $0.calls }
    }
}

private actor IsolationTopologyController: LumenMacDisplayTopologyControlling {
    let fixture: IsolationDisplayFixture

    init(fixture: IsolationDisplayFixture) {
        self.fixture = fixture
    }

    func capture() -> LumenMacPhysicalDisplayTopology {
        fixture.topology()
    }

    func restore(_ topology: LumenMacPhysicalDisplayTopology) {
        fixture.restore(topology)
    }

    func verify(_ topology: LumenMacPhysicalDisplayTopology) throws {
        let actual = fixture.physicalTopology()
        guard actual == topology else {
            throw DisplayTopologyProbeFailure.mismatch
        }
    }
}

private struct RecordingPhysicalDisplayController: LumenPhysicalDisplayControlling {
    let fixture: IsolationDisplayFixture?
    let failingDisableDisplayID: UInt32?
    let probeFails: Bool
    let doesNotApplyDisable: Bool

    init(
        fixture: IsolationDisplayFixture? = nil,
        failingDisableDisplayID: UInt32? = nil,
        probeFails: Bool = false,
        doesNotApplyDisable: Bool = false
    ) {
        self.fixture = fixture
        self.failingDisableDisplayID = failingDisableDisplayID
        self.probeFails = probeFails
        self.doesNotApplyDisable = doesNotApplyDisable
    }

    func probe() throws -> LumenDisplayEnabledSymbolProbe {
        if probeFails {
            throw LumenPhysicalDisplayControlFailure(code: .privateSymbolUnavailable)
        }
        return LumenDisplayEnabledSymbolProbe(
            source: .skyLightSLS,
            symbolName: "SLSConfigureDisplayEnabled"
        )
    }

    func setEnabled(
        _ enabled: Bool,
        for displayID: CGDirectDisplayID
    ) throws -> LumenPhysicalDisplayControlReceipt {
        if !enabled, displayID == failingDisableDisplayID {
            fixture?.recordControlCall(enabled, displayID: displayID)
            throw LumenPhysicalDisplayControlFailure(
                code: .transactionRejected,
                status: 1_003,
                source: .skyLightSLS
            )
        }
        if !enabled, doesNotApplyDisable {
            fixture?.recordControlCall(enabled, displayID: displayID)
            return LumenPhysicalDisplayControlReceipt(
                displayID: displayID,
                enabled: enabled,
                source: .skyLightSLS,
                symbolName: "SLSConfigureDisplayEnabled"
            )
        }
        fixture?.setEnabled(enabled, displayID: displayID)
        return LumenPhysicalDisplayControlReceipt(
            displayID: displayID,
            enabled: enabled,
            source: .skyLightSLS,
            symbolName: "SLSConfigureDisplayEnabled"
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
