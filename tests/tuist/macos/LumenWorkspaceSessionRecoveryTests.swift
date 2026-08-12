import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceSessionRecoveryTests: XCTestCase {
    func testPointerCenterUsesVirtualDisplayLogicalGeometry() throws {
        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            LumenMacDisplayModeRequest(
                width: 3512,
                height: 2420,
                scalePercent: 150,
                dimensionsAreLogical: false,
                highDensity: true
            )
        )

        let point = LumenMacPointerPositioner.centerPoint(geometry: geometry)

        XCTAssertEqual(point.x, CGFloat(geometry.logicalWidth) / 2)
        XCTAssertEqual(point.y, CGFloat(geometry.logicalHeight) / 2)
    }

    func testUnavailablePhysicalIsolationStopsAndRecoversTheStreamSession() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let statusRecorder = IsolationStatusRecorder()
        let journalPath = temporaryRecoveryJournalPath()
        let session = try LumenMacWorkspaceSession(
            request: externalIsolatedRequest(),
            operations: makeUnavailableIsolationOperations(recorder: recorder),
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
        let recoveredState = try await session.state()
        XCTAssertEqual(recoveredState, .idle)
        let recoveredEvents = await recorder.recordedEvents()
        XCTAssertTrue(recoveredEvents.contains(.firstFrameBarrier))
        XCTAssertTrue(recoveredEvents.contains(.isolate(114)))
        XCTAssertTrue(recoveredEvents.contains(.restore))
        XCTAssertTrue(recoveredEvents.contains(.verify))
        XCTAssertTrue(recoveredEvents.contains(.destroy))
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
        try await assertVerificationFailureRemainsRecoverable(
            session: session,
            recorder: recorder,
            journalPath: journalPath
        )
        let recoveryEvents = try await recoverFailedWorkspace(journalPath: journalPath)
        XCTAssertEqual(recoveryEvents.filter { $0 == .destroy }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
    }

}

private extension LumenWorkspaceSessionRecoveryTests {
    func makeUnavailableIsolationOperations(
        recorder: WorkspaceExecutionRecorder
    ) -> LumenMacWorkspaceNativeOperations {
        LumenMacWorkspaceNativeOperations(
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
    }

    func assertVerificationFailureRemainsRecoverable(
        session: LumenMacWorkspaceSession,
        recorder: WorkspaceExecutionRecorder,
        journalPath: String
    ) async throws {
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
        XCTAssertEqual(journal["phase"] as? String, "capture-stopped")
    }

    func recoverFailedWorkspace(
        journalPath: String
    ) async throws -> [WorkspaceExecutionEvent] {
        let recorder = WorkspaceExecutionRecorder()
        let coordinator = try LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        let executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [],
            displayMode: LumenMacDisplayModeRequest(
                width: 1_920,
                height: 1_080,
                scalePercent: 100,
                dimensionsAreLogical: false,
                highDensity: false
            ),
            operations: LumenMacWorkspaceNativeOperations(
                createVirtualDisplay: { _, _ in 0 },
                configureVirtualDisplay: { _, _ in },
                verifyVirtualDisplay: { _ in },
                startCapture: { _ in },
                stopCapture: {},
                destroyVirtualDisplay: { _ in await recorder.append(.destroy) }
            ),
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder)
        )
        let admitted = try await coordinator.beginSession(
            policy: .coexist,
            manageCapture: false
        )
        XCTAssertFalse(admitted)
        let error = try await coordinator.executePendingCommandsRecovering(
            using: executor
        )
        XCTAssertNil(error)
        return await recorder.recordedEvents()
    }
}
