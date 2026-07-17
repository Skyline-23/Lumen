import Foundation
import XCTest
@testable import LumenMacBridge

private enum RecoveryPayloadEvent: Equatable {
    case restore(LumenMacPhysicalDisplayTopology)
    case verify(LumenMacPhysicalDisplayTopology)
    case destroy(LumenMacVirtualDisplayIdentity)
}

private actor RecoveryPayloadRecorder {
    private var events: [RecoveryPayloadEvent] = []

    func append(_ event: RecoveryPayloadEvent) {
        events.append(event)
    }

    func recordedEvents() -> [RecoveryPayloadEvent] {
        events
    }
}

private enum RecoveryPayloadFailure: Error {
    case verification
}

private actor RecoveryPayloadDisplayWorkspace: LumenMacDisplayWorkspaceManaging {
    private let topology: LumenMacPhysicalDisplayTopology
    private let recorder: RecoveryPayloadRecorder
    private let verificationFails: Bool

    init(
        topology: LumenMacPhysicalDisplayTopology,
        recorder: RecoveryPayloadRecorder,
        verificationFails: Bool = false
    ) {
        self.topology = topology
        self.recorder = recorder
        self.verificationFails = verificationFails
    }

    func snapshotWorkspace(
        targetProcessIdentifiers _: [Int32]
    ) async -> LumenMacPhysicalDisplayTopology {
        topology
    }

    func promoteVirtualDisplay(_: UInt32) async {}
    func moveTargetWindows(to _: UInt32) async {}
    func isolateVirtualDisplay(_: UInt32) async {}

    func restoreWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async {
        await recorder.append(.restore(topology))
    }

    func verifyWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async throws {
        await recorder.append(.verify(topology))
        if verificationFails {
            throw RecoveryPayloadFailure.verification
        }
    }

    func discardSnapshot() async {}
}

final class LumenWorkspaceRecoveryPayloadTests: XCTestCase {
    func testFreshExecutorRestoresFromProductionJournalPayloads() async throws {
        // Given: a production FFI session persisted an isolated topology and identity.
        let journalURL = temporaryJournalURL()
        let topology = recoveryTopology()
        try await seedIsolatedProductionJournal(at: journalURL, topology: topology)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let recorder = RecoveryPayloadRecorder()
        let executor = try makeExecutor(topology: topology, recorder: recorder)
        let coordinator = try LumenWorkspaceCoordinator(recoveryJournalPath: journalURL.path)

        // When: a fresh coordinator and executor recover before admitting another session.
        let admitted = try await coordinator.beginSession(policy: .isolatedWorkspace)
        XCTAssertFalse(admitted)
        try await coordinator.executePendingCommands(using: executor)

        // Then: persisted payloads drive restore, independent verification, and keyed destroy.
        let events = await recorder.recordedEvents()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .restore(topology))
        XCTAssertEqual(events[1], .verify(topology))
        guard case .destroy(let identity) = events[2] else {
            return XCTFail("expected persisted virtual identity")
        }
        XCTAssertFalse(identity.id.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testFreshExecutorDestroysOwnedDisplayWhenPhysicalReadbackFails() async throws {
        // Given: a fresh executor has no in-memory snapshot and verification will fail.
        let journalURL = temporaryJournalURL()
        let topology = recoveryTopology()
        try await seedIsolatedProductionJournal(at: journalURL, topology: topology)
        let recorder = RecoveryPayloadRecorder()
        let executor = try makeExecutor(
            topology: topology,
            recorder: recorder,
            verificationFails: true
        )
        let coordinator = try LumenWorkspaceCoordinator(recoveryJournalPath: journalURL.path)
        let admitted = try await coordinator.beginSession(policy: .isolatedWorkspace)
        XCTAssertFalse(admitted)

        // When: restore completes but independent display readback rejects the result.
        let error = try await coordinator.executePendingCommandsRecovering(using: executor)

        // Then: the physical recovery error and journal remain, but the owned
        // virtual display is destroyed independently.
        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let events = await recorder.recordedEvents()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .restore(topology))
        XCTAssertEqual(events[1], .verify(topology))
        guard case .destroy(let identity) = events[2] else {
            return XCTFail("expected persisted virtual identity")
        }
        XCTAssertFalse(identity.id.isEmpty)
        let nextCommand = try await coordinator.nextCommand()
        XCTAssertNil(nextCommand)
    }

    func testFreshExecutorRetainsJournalWhenNSScreenDisagreesWithCoreGraphics() async throws {
        // Given: persisted display state matches CoreGraphics while NSScreen omits the display.
        let journalURL = temporaryJournalURL()
        let persisted = recoveryTopology()
        let topology = LumenMacPhysicalDisplayTopology(
            displays: persisted.displays,
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
        try await seedIsolatedProductionJournal(at: journalURL, topology: topology)
        let recorder = RecoveryPayloadRecorder()
        let topologyController = LumenCoreGraphicsDisplayTopologyController(
            capture: { topology },
            restore: { _ in },
            visibleDisplayIDs: { [] }
        )
        let displayWorkspace = LumenMacDisplayWorkspace(
            topologyController: topologyController,
            physicalDisplayController: RecoveryNoopPhysicalDisplayController(),
            disconnectCapabilityVerifier: AllowingDisplayDisconnectCapabilityVerifier()
        )
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, _ in 410 },
            configureVirtualDisplay: { _, _ in },
            verifyVirtualDisplay: { _ in },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { identity in
                await recorder.append(.destroy(identity))
            }
        )
        let executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [],
            displayMode: LumenMacDisplayModeRequest(
                width: 3024,
                height: 1964,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            operations: operations,
            displayWorkspace: displayWorkspace
        )
        let coordinator = try LumenWorkspaceCoordinator(recoveryJournalPath: journalURL.path)
        let admitted = try await coordinator.beginSession(policy: .isolatedWorkspace)
        XCTAssertFalse(admitted)

        // When: the fresh executor restores and performs production combined verification.
        let error = try await coordinator.executePendingCommandsRecovering(using: executor)

        // Then: verification fails and the durable journal remains retryable,
        // while virtual-display destruction is not blocked by NSScreen readback.
        XCTAssertNotNil(error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let events = await recorder.recordedEvents()
        XCTAssertEqual(events.count, 1)
        guard case .destroy(let identity) = events[0] else {
            return XCTFail("expected persisted virtual identity")
        }
        XCTAssertFalse(identity.id.isEmpty)
    }

    private func seedIsolatedProductionJournal(
        at journalURL: URL,
        topology: LumenMacPhysicalDisplayTopology
    ) async throws {
        let recorder = RecoveryPayloadRecorder()
        let executor = try makeExecutor(topology: topology, recorder: recorder)
        let coordinator = try LumenWorkspaceCoordinator(recoveryJournalPath: journalURL.path)
        let admitted = try await coordinator.beginSession(policy: .isolatedWorkspace)
        XCTAssertTrue(admitted)
        try await coordinator.executePendingCommands(using: executor)
    }

    private func makeExecutor(
        topology: LumenMacPhysicalDisplayTopology,
        recorder: RecoveryPayloadRecorder,
        verificationFails: Bool = false
    ) throws -> LumenMacWorkspaceExecutor {
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, _ in 410 },
            configureVirtualDisplay: { _, _ in },
            verifyVirtualDisplay: { _ in },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { identity in
                await recorder.append(.destroy(identity))
            }
        )
        return try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [],
            displayMode: LumenMacDisplayModeRequest(
                width: 3024,
                height: 1964,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            operations: operations,
            displayWorkspace: RecoveryPayloadDisplayWorkspace(
                topology: topology,
                recorder: recorder,
                verificationFails: verificationFails
            )
        )
    }

    private func recoveryTopology() -> LumenMacPhysicalDisplayTopology {
        LumenMacPhysicalDisplayTopology(
            displays: [
                LumenMacPhysicalDisplayState(
                    id: "410",
                    mode: LumenMacPhysicalDisplayMode(
                        width: 3024,
                        height: 1964,
                        refreshMillihertz: 120_000,
                        bitDepth: 10
                    ),
                    originX: -1512,
                    originY: 0,
                    mirrorMasterID: "7",
                    enabled: true,
                    active: true,
                    online: true
                ),
            ],
            macWindows: [
                LumenMacWorkspaceWindowState(
                    processID: 7_001,
                    windowID: 88,
                    originX: -640,
                    originY: 120,
                    width: 1_280,
                    height: 720
                ),
            ],
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
    }

    private func temporaryJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "display-recovery.json", directoryHint: .notDirectory)
    }
}

private struct RecoveryNoopPhysicalDisplayController: LumenPhysicalDisplayControlling {
    func probe() -> LumenDisplayEnabledSymbolProbe {
        LumenDisplayEnabledSymbolProbe(
            source: .skyLightSLS,
            symbolName: "SLSConfigureDisplayEnabled"
        )
    }

    func setEnabled(
        _ enabled: Bool,
        for displayID: CGDirectDisplayID
    ) -> LumenPhysicalDisplayControlReceipt {
        LumenPhysicalDisplayControlReceipt(
            displayID: displayID,
            enabled: enabled,
            source: .skyLightSLS,
            symbolName: "SLSConfigureDisplayEnabled"
        )
    }
}
