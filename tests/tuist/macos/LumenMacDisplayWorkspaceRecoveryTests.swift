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

    func visibleDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(topology.displays.compactMap { state in
            guard state.active, state.online else { return nil }
            return UInt32(state.id)
        })
    }

    func allowVerification() {
        verificationFails = false
    }

    func restoredTopologies() -> [LumenMacPhysicalDisplayTopology] {
        restored
    }
}

private actor TransientVirtualDisplayTopologyController: LumenMacDisplayTopologyControlling {
    private let physicalDisplayID: CGDirectDisplayID
    private var restored: [LumenMacPhysicalDisplayTopology] = []

    init(physicalDisplayID: CGDirectDisplayID) {
        self.physicalDisplayID = physicalDisplayID
    }

    func capture() throws -> LumenMacPhysicalDisplayTopology {
        throw LumenMacDisplayWorkspaceError.displayNotFound(102)
    }

    func restore(_ topology: LumenMacPhysicalDisplayTopology) {
        restored.append(topology)
    }

    func verify(_: LumenMacPhysicalDisplayTopology) {}

    func visibleDisplayIDs() -> Set<CGDirectDisplayID> {
        [physicalDisplayID]
    }

    func restoredTopologies() -> [LumenMacPhysicalDisplayTopology] {
        restored
    }
}

private enum DisplayMirrorEvent: Equatable {
    case mirror(target: UInt32, source: UInt32)
    case unmirror(target: UInt32)
}

private actor DisplayMirrorProbe: LumenMacDisplayMirrorControlling {
    private let sourceDisplayID: UInt32
    private let targetDisplayID: UInt32
    private let reportedMirrorSourceAfterApply: UInt32?
    private var applied = false
    private var events: [DisplayMirrorEvent] = []

    init(
        sourceDisplayID: UInt32,
        targetDisplayID: UInt32,
        reportedMirrorSourceAfterApply: UInt32?
    ) {
        self.sourceDisplayID = sourceDisplayID
        self.targetDisplayID = targetDisplayID
        self.reportedMirrorSourceAfterApply = reportedMirrorSourceAfterApply
    }

    func state(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) -> LumenMacDisplayMirrorState {
        LumenMacDisplayMirrorState(
            mainDisplayID: self.sourceDisplayID,
            mirrorSourceDisplayID: applied
                ? reportedMirrorSourceAfterApply
                : nil,
            sourceIsOnline: sourceDisplayID == self.sourceDisplayID,
            sourceIsActive: sourceDisplayID == self.sourceDisplayID,
            sourceIsOwnedVirtualDisplay: false,
            targetIsOnline: targetDisplayID == self.targetDisplayID,
            targetIsActive: targetDisplayID == self.targetDisplayID
        )
    }

    func mirror(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) {
        events.append(.mirror(
            target: targetDisplayID,
            source: sourceDisplayID
        ))
        applied = true
    }

    func unmirror(targetDisplayID: UInt32) {
        events.append(.unmirror(target: targetDisplayID))
        applied = false
    }

    func recordedEvents() -> [DisplayMirrorEvent] {
        events
    }
}

final class LumenMacDisplayWorkspaceRecoveryTests: XCTestCase {
    func testTopologyCaptureSkipsAnUnusableTransientVirtualDisplay() throws {
        let physical = displayTopology().displays[0]

        let states = LumenCoreGraphicsDisplayTopologyController.usableDisplayStates(
            from: [2, 181]
        ) { displayID in
            displayID == 2 ? physical : nil
        }

        XCTAssertEqual(states, [physical])
    }

    func testExactActiveVirtualDisplayMissingFromEnumerationRemainsPromotable() {
        XCTAssertEqual(
            LumenMacDisplayWorkspace.promotionDisplayIDs(
                displayID: 117,
                visibleDisplayIDs: [2],
                activeDisplayIDs: [2],
                exactDisplayIsOnline: true,
                exactDisplayIsActive: true
            ),
            [2, 117]
        )
        XCTAssertNil(
            LumenMacDisplayWorkspace.promotionDisplayIDs(
                displayID: 117,
                visibleDisplayIDs: [2, 117],
                activeDisplayIDs: [2],
                exactDisplayIsOnline: true,
                exactDisplayIsActive: false
            )
        )
    }

    func testPromotionSeparatesAnOverlappingPhysicalDisplayAndRequiresTheOwnedDisplayAsMain() throws {
        let overlappingBounds: [CGDirectDisplayID: CGRect] = [
            2: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
            117: CGRect(x: 0, y: 0, width: 320, height: 180),
        ]

        let placements = try XCTUnwrap(
            LumenMacDisplayWorkspace.promotionPlacements(
                displayID: 117,
                displayIDs: [2, 117],
                boundsByDisplayID: overlappingBounds,
                builtInDisplayIDs: [2],
                targetSize: CGSize(width: 320, height: 180)
            )
        )

        XCTAssertEqual(placements.map { $0.displayID }, [117, 2])
        XCTAssertEqual(placements.map { $0.origin }, [
            .zero,
            CGPoint(x: 320, y: 0),
        ])
        var modeLessBounds = overlappingBounds
        modeLessBounds[117] = .zero
        let modeLessPlacements = try XCTUnwrap(
            LumenMacDisplayWorkspace.promotionPlacements(
                displayID: 117,
                displayIDs: [2, 117],
                boundsByDisplayID: modeLessBounds,
                builtInDisplayIDs: [2],
                targetSize: CGSize(width: 320, height: 180)
            )
        )
        XCTAssertEqual(modeLessPlacements.map { $0.origin }, [
            .zero,
            CGPoint(x: 320, y: 0),
        ])
        XCTAssertFalse(
            LumenMacDisplayWorkspace.promotionIsComplete(
                displayID: 117,
                mainDisplayID: 2,
                activeDisplayIDs: [2, 117],
                requiredActiveDisplayIDs: [2],
                exactDisplayIsOnline: true,
                exactDisplayIsActive: true,
                boundsByDisplayID: overlappingBounds
            )
        )
        XCTAssertFalse(
            LumenMacDisplayWorkspace.promotionIsComplete(
                displayID: 117,
                mainDisplayID: 117,
                activeDisplayIDs: [2, 117],
                requiredActiveDisplayIDs: [2],
                exactDisplayIsOnline: true,
                exactDisplayIsActive: true,
                boundsByDisplayID: overlappingBounds
            )
        )
        XCTAssertFalse(
            LumenMacDisplayWorkspace.promotionIsComplete(
                displayID: 117,
                mainDisplayID: 117,
                activeDisplayIDs: [],
                requiredActiveDisplayIDs: [2],
                exactDisplayIsOnline: true,
                exactDisplayIsActive: true,
                boundsByDisplayID: overlappingBounds
            )
        )
        XCTAssertFalse(
            LumenMacDisplayWorkspace.promotionIsComplete(
                displayID: 117,
                mainDisplayID: 117,
                activeDisplayIDs: [2, 117],
                requiredActiveDisplayIDs: [2],
                exactDisplayIsOnline: true,
                exactDisplayIsActive: true,
                boundsByDisplayID: modeLessBounds
            )
        )

        var separatedBounds = overlappingBounds
        separatedBounds[2]?.origin = CGPoint(x: 320, y: 0)
        XCTAssertTrue(
            LumenMacDisplayWorkspace.promotionIsComplete(
                displayID: 117,
                mainDisplayID: 117,
                activeDisplayIDs: [2, 117],
                requiredActiveDisplayIDs: [2],
                exactDisplayIsOnline: true,
                exactDisplayIsActive: true,
                boundsByDisplayID: separatedBounds
            )
        )
    }

    func testOwnedDesktopMirrorPreservesPhysicalTopologyAndUnmirrorsDuringRestore() async throws {
        let topology = displayTopology()
        let sourceDisplayID = try XCTUnwrap(
            topology.displays.first.flatMap { UInt32($0.id) }
        )
        let targetDisplayID: UInt32 = 117
        let topologyProbe = DisplayTopologyProbe(topology: topology)
        let mirrorProbe = DisplayMirrorProbe(
            sourceDisplayID: sourceDisplayID,
            targetDisplayID: targetDisplayID,
            reportedMirrorSourceAfterApply: sourceDisplayID
        )
        let workspace = LumenMacDisplayWorkspace(
            topologyController: topologyProbe,
            mirrorController: mirrorProbe,
            physicalDisplayController: RecordingPhysicalDisplayController(),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        await topologyProbe.allowVerification()

        try await workspace.mirrorOwnedVirtualDisplay(
            targetDisplayID,
            sourceDisplayID: sourceDisplayID
        )
        try await workspace.restoreWorkspace(topology)

        let events = await mirrorProbe.recordedEvents()
        XCTAssertEqual(events, [
            .mirror(target: targetDisplayID, source: sourceDisplayID),
            .unmirror(target: targetDisplayID),
        ])
        let restoredTopologies = await topologyProbe.restoredTopologies()
        XCTAssertTrue(restoredTopologies.isEmpty)
    }

    func testOwnedDesktopMirrorPostconditionFailureUnmirrorsOnlyExactTarget() async throws {
        let topology = displayTopology()
        let sourceDisplayID = try XCTUnwrap(
            topology.displays.first.flatMap { UInt32($0.id) }
        )
        let targetDisplayID: UInt32 = 118
        let topologyProbe = DisplayTopologyProbe(topology: topology)
        let mirrorProbe = DisplayMirrorProbe(
            sourceDisplayID: sourceDisplayID,
            targetDisplayID: targetDisplayID,
            reportedMirrorSourceAfterApply: nil
        )
        let workspace = LumenMacDisplayWorkspace(
            topologyController: topologyProbe,
            mirrorController: mirrorProbe,
            physicalDisplayController: RecordingPhysicalDisplayController(),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        await topologyProbe.allowVerification()

        do {
            try await workspace.mirrorOwnedVirtualDisplay(
                targetDisplayID,
                sourceDisplayID: sourceDisplayID
            )
            XCTFail("mirror postcondition mismatch must fail closed")
        } catch LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
            targetDisplayID,
            sourceDisplayID
        ) {
        }

        let events = await mirrorProbe.recordedEvents()
        XCTAssertEqual(events, [
            .mirror(target: targetDisplayID, source: sourceDisplayID),
            .unmirror(target: targetDisplayID),
        ])
        let restoredTopologies = await topologyProbe.restoredTopologies()
        XCTAssertTrue(restoredTopologies.isEmpty)
    }

    func testRestoreSkipsCoreGraphicsMutationWhenPhysicalTopologyAlreadyConverged() async throws {
        let topology = displayTopology()
        let physicalDisplayID = try XCTUnwrap(topology.displays.first.flatMap { UInt32($0.id) })
        let controller = TransientVirtualDisplayTopologyController(
            physicalDisplayID: physicalDisplayID
        )
        let workspace = LumenMacDisplayWorkspace(
            topologyController: controller,
            physicalDisplayController: RecordingPhysicalDisplayController(),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
        )

        try await workspace.restoreWorkspace(topology)

        let restoredTopologies = await controller.restoredTopologies()
        XCTAssertTrue(restoredTopologies.isEmpty)
    }

    func testModeSelectionUsesCurrentModeWhenEnumerationOmitsIt() {
        let current = LumenMacPhysicalDisplayMode(
            width: 5120,
            height: 2880,
            refreshMillihertz: 240_000,
            bitDepth: 8
        )

        XCTAssertEqual(
            LumenCoreGraphicsDisplayTopologyController.preferredModeIndex(
                current: current,
                available: [],
                expected: current
            ),
            0
        )
    }

    func testStableHardwareIdentityRemapsChangedCoreGraphicsDisplayID() throws {
        let expected = LumenMacPhysicalDisplayTopology(
            displays: [physicalDisplayState(
                id: "2",
                originX: 0,
                vendorID: 1_554,
                productID: 4_096,
                serialNumber: 77,
                builtin: true
            )],
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
        let current = physicalDisplayState(
            id: "1",
            originX: 0,
            vendorID: 1_554,
            productID: 4_096,
            serialNumber: 77,
            builtin: true
        )

        let resolved = try LumenCoreGraphicsDisplayTopologyController.resolveDisplayIDs(
            for: expected,
            candidates: [current]
        )

        XCTAssertEqual(resolved, ["2": 1])
    }

    func testLegacySingleDisplayJournalRemapsOnlyOneMatchingNonLumenDisplay() throws {
        let expected = LumenMacPhysicalDisplayTopology(
            displays: [physicalDisplayState(id: "2", originX: 0)],
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
        let physical = physicalDisplayState(id: "1", originX: 0)
        let lumenVirtual = physicalDisplayState(
            id: "26",
            originX: 0,
            vendorID: 6_973,
            productID: 0xA901,
            serialNumber: 1,
            builtin: false
        )

        let resolved = try LumenCoreGraphicsDisplayTopologyController.resolveDisplayIDs(
            for: expected,
            candidates: [physical, lumenVirtual]
        )

        XCTAssertEqual(resolved, ["2": 1])
    }

    func testLegacyJournalRefusesAmbiguousPhysicalDisplayRemap() {
        let expected = LumenMacPhysicalDisplayTopology(
            displays: [physicalDisplayState(id: "2", originX: 0)],
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )

        XCTAssertThrowsError(
            try LumenCoreGraphicsDisplayTopologyController.resolveDisplayIDs(
                for: expected,
                candidates: [
                    physicalDisplayState(id: "1", originX: 0),
                    physicalDisplayState(id: "3", originX: 0),
                ]
            )
        )
    }

    func testLegacyCorruptModeConvergesOnlyToOneActiveBuiltinDisplay() throws {
        let expected = LumenMacPhysicalDisplayTopology(
            displays: [LumenMacPhysicalDisplayState(
                id: "2",
                mode: LumenMacPhysicalDisplayMode(
                    width: 5_120,
                    height: 2_880,
                    refreshMillihertz: 240_000,
                    bitDepth: 8
                ),
                originX: 0,
                originY: 0,
                mirrorMasterID: nil,
                enabled: true,
                active: true,
                online: true
            )],
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
        let currentBuiltin = physicalDisplayState(
            id: "1",
            originX: 0,
            vendorID: 1_552,
            productID: 41_049,
            serialNumber: 4_251_086_178,
            builtin: true
        )
        let resolved = try LumenCoreGraphicsDisplayTopologyController.resolveDisplayIDs(
            for: expected,
            candidates: [currentBuiltin]
        )

        XCTAssertEqual(resolved, ["2": 1])
        XCTAssertTrue(
            LumenCoreGraphicsDisplayTopologyController.matches(
                actual: currentBuiltin,
                expected: try XCTUnwrap(expected.displays.first),
                resolvedIDs: resolved
            )
        )
    }

    func testProductionTopologyVerificationWaitsForDisplayReadbackToConverge() async throws {
        let expected = displayTopology()
        let mismatched = LumenMacPhysicalDisplayTopology(
            displays: expected.displays.map { display in
                LumenMacPhysicalDisplayState(
                    id: display.id,
                    mode: display.mode,
                    originX: display.originX + 1,
                    originY: display.originY,
                    mirrorMasterID: display.mirrorMasterID,
                    enabled: display.enabled,
                    active: display.active,
                    online: display.online
                )
            },
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
        let captures = Mutex(0)
        let controller = LumenCoreGraphicsDisplayTopologyController(
            capture: {
                captures.withLock { count in
                    count += 1
                    return count == 1 ? mismatched : expected
                }
            },
            restore: { _ in },
            visibleDisplayIDs: {
                Set(expected.displays.compactMap { UInt32($0.id) })
            },
            verificationAttempts: 2
        )

        try await controller.verify(expected)
        XCTAssertEqual(captures.withLock { $0 }, 2)
    }

    func testProductionTopologyVerificationRejectsCGDisplayMissingFromNSScreen() async throws {
        // Given: CoreGraphics reports the exact persisted topology but AppKit cannot see it.
        let topology = displayTopology()
        let controller = LumenCoreGraphicsDisplayTopologyController(
            capture: { topology },
            restore: { _ in },
            visibleDisplayIDs: { [] }
        )

        // When/Then: the production verifier rejects the incomplete restoration readback.
        await XCTAssertThrowsErrorAsync {
            try await controller.verify(topology)
        }
    }

    func testMissingCapabilityReceiptRejectsIsolationBeforeDisplayMutation() async throws {
        let fixture = IsolationDisplayFixture(physicalTopology: isolationPhysicalTopology())
        let receiptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("display-disconnect-capability-v1.json")
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(fixture: fixture),
            disconnectCapabilityVerifier: LumenDisplayDisconnectCapabilityFileVerifier(
                receiptURL: receiptURL,
                environment: .init(
                    osBuild: "25G42",
                    hardwareIdentity: "platform-uuid|Mac16,1|J514cAP"
                ),
                currentTimeUnixSeconds: 1_752_600_000
            )
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        fixture.publishVirtualDisplay(99)

        do {
            try await workspace.isolateVirtualDisplay(99)
            XCTFail("expected missing capability receipt to reject isolation")
        } catch LumenMacDisplayWorkspaceError.isolationUnavailable(let message) {
            XCTAssertTrue(
                message.contains("physicalDisplayDisconnectUnverified")
            )
        }

        XCTAssertTrue(fixture.controlCalls().isEmpty)
        XCTAssertEqual(fixture.physicalTopology(), isolationPhysicalTopology())
    }

    func testCaptureProvenUnpublishedVirtualDisplayCanIsolatePhysicalDisplays() async throws {
        let topology = isolationPhysicalTopology()
        let fixture = IsolationDisplayFixture(physicalTopology: topology)
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(fixture: fixture),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])

        try await workspace.isolateVirtualDisplay(114)

        XCTAssertEqual(
            fixture.controlCalls(),
            topology.displays.compactMap { display in
                UInt32(display.id).map { PhysicalControlCall(displayID: $0, enabled: false) }
            }
        )
        XCTAssertTrue(
            fixture.physicalTopology().displays.allSatisfy { !$0.active && !$0.enabled }
        )
    }

    func testRetainedModeLessVirtualDisplayCanIsolateAfterActiveReadback() async throws {
        let topology = isolationPhysicalTopology()
        let fixture = IsolationDisplayFixture(physicalTopology: topology)
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(fixture: fixture),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        fixture.publishModeLessVirtualDisplay(123)

        try await workspace.isolateVirtualDisplay(123)

        XCTAssertEqual(
            fixture.controlCalls(),
            topology.displays.compactMap { display in
                UInt32(display.id).map { PhysicalControlCall(displayID: $0, enabled: false) }
            }
        )
        XCTAssertTrue(
            fixture.physicalTopology().displays.allSatisfy { !$0.active && !$0.enabled }
        )
    }

    func testSnapshotSurvivesRestoreUntilIndependentVerificationSucceeds() async throws {
        // Given: a workspace owns a snapshot and its first physical readback will fail.
        let topology = displayTopology()
        let probe = DisplayTopologyProbe(topology: topology)
        let workspace = LumenMacDisplayWorkspace(
            topologyController: probe,
            physicalDisplayController: RecordingPhysicalDisplayController(),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
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
            physicalDisplayController: RecordingPhysicalDisplayController(fixture: fixture),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
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
            ),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
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
            physicalDisplayController: RecordingPhysicalDisplayController(fixture: fixture),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
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
            ),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
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
            ),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
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

    func testIsolationRollsBackWhenNSScreenStillShowsDisabledPhysicalDisplays() async throws {
        // Given: private disable updates CoreGraphics state but NSScreen remains stale.
        let topology = isolationPhysicalTopology()
        let fixture = IsolationDisplayFixture(
            physicalTopology: topology,
            keepsDisabledDisplaysVisible: true
        )
        let workspace = LumenMacDisplayWorkspace(
            topologyController: IsolationTopologyController(fixture: fixture),
            physicalDisplayController: RecordingPhysicalDisplayController(fixture: fixture),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
        )
        _ = try await workspace.snapshotWorkspace(targetProcessIdentifiers: [])
        fixture.publishVirtualDisplay(99)

        // When: isolation validates both CoreGraphics and NSScreen postconditions.
        await XCTAssertThrowsErrorAsync {
            try await workspace.isolateVirtualDisplay(99)
        }

        // Then: every physical display is enabled again and the exact topology is restored.
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
        vendorID: UInt32? = nil,
        productID: UInt32? = nil,
        serialNumber: UInt32? = nil,
        builtin: Bool? = nil,
        enabled: Bool = true,
        active: Bool = true
    ) -> LumenMacPhysicalDisplayState {
        LumenMacPhysicalDisplayState(
            id: id,
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            builtin: builtin,
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
        var visibleDisplayIDs: Set<CGDirectDisplayID>
        var calls: [PhysicalControlCall] = []
    }

    private let storage: Mutex<State>
    private let keepsDisabledDisplaysVisible: Bool

    init(
        physicalTopology: LumenMacPhysicalDisplayTopology,
        keepsDisabledDisplaysVisible: Bool = false
    ) {
        self.keepsDisabledDisplaysVisible = keepsDisabledDisplaysVisible
        storage = Mutex(
            State(
                topology: physicalTopology,
                originalPhysicalTopology: physicalTopology,
                visibleDisplayIDs: Set(physicalTopology.displays.compactMap { UInt32($0.id) })
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
            state.visibleDisplayIDs.insert(displayID)
        }
    }

    func publishModeLessVirtualDisplay(_ displayID: UInt32) {
        storage.withLock { state in
            state.visibleDisplayIDs.insert(displayID)
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
            if enabled {
                state.visibleDisplayIDs.insert(displayID)
            } else if !keepsDisabledDisplaysVisible {
                state.visibleDisplayIDs.remove(displayID)
            }
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
            state.visibleDisplayIDs.formUnion(
                topology.displays.compactMap { state in
                    guard state.active, state.online else { return nil }
                    return UInt32(state.id)
                }
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

    func visibleDisplayIDs() -> Set<CGDirectDisplayID> {
        storage.withLock { $0.visibleDisplayIDs }
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

    func visibleDisplayIDs() -> Set<CGDirectDisplayID> {
        fixture.visibleDisplayIDs()
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
