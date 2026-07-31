import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceSessionManagedCaptureTests: XCTestCase {
    func testManagedCaptureStrictPromotionFailureStopsBeforeCaptureAndRollsBack() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let (session, journalPath) = try makeManagedPromotionFailureSession(
            recorder: recorder
        )

        do {
            try await session.start()
            XCTFail("expected strict managed promotion to fail closed")
        } catch LumenMacDisplayWorkspaceError.virtualDisplayPromotionUnavailable(120) {}

        let events = await recorder.recordedEvents()
        let capturePreparationIndex = try XCTUnwrap(
            events.firstIndex(of: .prepareCapture(120))
        )
        let strictPromotionIndex = try XCTUnwrap(
            events.firstIndex(of: .promote(120, .required))
        )
        let restoreIndex = try XCTUnwrap(events.firstIndex(of: .restore))
        let verifyIndex = try XCTUnwrap(events.firstIndex(of: .verify))
        let destroyIndex = try XCTUnwrap(events.firstIndex(of: .destroy))
        XCTAssertLessThan(capturePreparationIndex, strictPromotionIndex)
        XCTAssertLessThan(strictPromotionIndex, restoreIndex)
        XCTAssertLessThan(restoreIndex, verifyIndex)
        XCTAssertLessThan(verifyIndex, destroyIndex)
        XCTAssertFalse(events.contains(.startCapture(120)))
        XCTAssertFalse(events.contains(.stopCapture))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
        let recoveredState = try await session.state()
        XCTAssertEqual(recoveredState, .idle)
    }

    func testWorkspaceSessionRestoresResourcesAfterCaptureStartupFailure() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let (session, request) = try makeCaptureStartupFailureSession(
            recorder: recorder
        )

        do {
            try await session.start()
            XCTFail("Expected capture startup failure")
        } catch WorkspaceManagedCaptureExpectedFailure.captureStartup {
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
                .destroy
            ]
        )
    }

}

private enum WorkspaceManagedCaptureExpectedFailure: Error {
    case captureStartup
}

private extension LumenWorkspaceSessionManagedCaptureTests {
    func makeManagedPromotionFailureSession(
        recorder: WorkspaceExecutionRecorder
    ) throws -> (LumenMacWorkspaceSession, String) {
        let journalPath = temporaryRecoveryJournalPath()
        let session = try LumenMacWorkspaceSession(
            request: managedCaptureRequest(policy: .promoteVirtualMain),
            operations: managedPromotionOperations(recorder: recorder),
            displayWorkspace: WorkspaceDisplayMock(
                recorder: recorder,
                promotionResults: [true, false]
            ),
            coordinator: LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        )
        return (session, journalPath)
    }

    func managedPromotionOperations(
        recorder: WorkspaceExecutionRecorder
    ) -> LumenMacWorkspaceNativeOperations {
        LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 120
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { _ in },
            prepareCaptureDisplay: { displayID in
                await recorder.append(.prepareCapture(displayID))
            },
            startCapture: { displayID in
                await recorder.append(.startCapture(displayID))
            },
            stopCapture: { await recorder.append(.stopCapture) },
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) }
        )
    }

    func makeCaptureStartupFailureSession(
        recorder: WorkspaceExecutionRecorder
    ) throws -> (LumenMacWorkspaceSession, LumenMacWorkspaceSessionRequest) {
        let request = managedCaptureRequest(policy: .coexist)
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
                throw WorkspaceManagedCaptureExpectedFailure.captureStartup
            },
            stopCapture: { await recorder.append(.stopCapture) },
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) }
        )
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: makeCoordinator()
        )
        return (session, request)
    }

    func managedCaptureRequest(
        policy: LumenMacWorkspacePolicy
    ) -> LumenMacWorkspaceSessionRequest {
        LumenMacWorkspaceSessionRequest(
            policy: policy,
            displayMode: LumenMacDisplayModeRequest(
                width: 1920,
                height: 1080,
                scalePercent: 100,
                dimensionsAreLogical: false,
                highDensity: false
            ),
            captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
        )
    }
}
