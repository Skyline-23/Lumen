import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceSessionFailureTests: XCTestCase {
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
        let request = makePromotedWorkspaceRequest()
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: makeLifecycleOperations(recorder: recorder),
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
                .promote(73, .deferredUntilCaptureReady),
                .prepareCapture(73),
                .promote(73, .required),
                .startCapture(73),
                .stopCapture,
                .restore,
                .verify,
                .destroy
            ]
        )
    }

}

private extension LumenWorkspaceSessionFailureTests {
    func makePromotedWorkspaceRequest() -> LumenMacWorkspaceSessionRequest {
        LumenMacWorkspaceSessionRequest(
            policy: .promoteVirtualMain,
            displayMode: LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false,
                highDensity: true
            ),
            captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
        )
    }

    func makeLifecycleOperations(
        recorder: WorkspaceExecutionRecorder
    ) -> LumenMacWorkspaceNativeOperations {
        LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 73
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
            stopCapture: {
                await recorder.append(.stopCapture)
            },
            destroyVirtualDisplay: { _ in
                await recorder.append(.destroy)
            }
        )
    }
}
