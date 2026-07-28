import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceExternalIsolationTests: XCTestCase {
    func testExternalCaptureStartsPhysicalIsolationImmediatelyAfterFirstFrameReadiness() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let statusRecorder = IsolationStatusRecorder()
        let request = externalIsolatedRequest()
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: makeExternalIsolationOperations(recorder: recorder),
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: makeCoordinator(),
            isolationStatusHandler: { status in
                await statusRecorder.append(status)
            }
        )

        try await session.prepare()

        let preparedEvents = await recorder.recordedEvents()
        try assertPreparedIsolationEvents(preparedEvents)
        let preparedState = try await session.state()
        XCTAssertEqual(preparedState, .starting)

        let outcome = try await session.activate()
        let expectedIsolationStatus = LumenMacWorkspaceIsolationStatus.applied
        XCTAssertEqual(outcome.isolationStatus, .pending)
        let statuses = await statusRecorder.waitForStatusCount(1)
        XCTAssertEqual(statuses, [expectedIsolationStatus])

        let activeEvents = await recorder.recordedEvents()
        try assertActiveIsolationEvents(activeEvents, request: request)
        let activeState = try await session.state()
        XCTAssertEqual(activeState, .active)
        try await session.stop()
    }

}

private extension LumenWorkspaceExternalIsolationTests {
    func makeExternalIsolationOperations(
        recorder: WorkspaceExecutionRecorder
    ) -> LumenMacWorkspaceNativeOperations {
        LumenMacWorkspaceNativeOperations(
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
            stabilizeVirtualDisplay: { displayID in
                await recorder.append(.stabilize(displayID))
            },
            prepareCaptureDisplay: { displayID in
                await recorder.append(.prepareCapture(displayID))
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
    }

    func assertPreparedIsolationEvents(
        _ events: [WorkspaceExecutionEvent]
    ) throws {
        XCTAssertFalse(events.contains(.firstFrameBarrier))
        let resolveIndex = try XCTUnwrap(events.firstIndex(of: .resolve(88)))
        let promotionIndex = try XCTUnwrap(
            events.firstIndex(of: .promote(88, .deferredUntilCaptureReady))
        )
        let stabilizationIndex = try XCTUnwrap(events.firstIndex(of: .stabilize(88)))
        let capturePreparationIndex = try XCTUnwrap(
            events.firstIndex(of: .prepareCapture(88))
        )
        let strictPromotionIndex = try XCTUnwrap(
            events.firstIndex(of: .promote(88, .required))
        )
        XCTAssertEqual(
            events.filter { $0 == .promote(88, .deferredUntilCaptureReady) }.count,
            1
        )
        XCTAssertEqual(events.filter { $0 == .promote(88, .required) }.count, 1)
        XCTAssertLessThan(resolveIndex, promotionIndex)
        XCTAssertLessThan(stabilizationIndex, promotionIndex)
        XCTAssertLessThan(promotionIndex, capturePreparationIndex)
        XCTAssertLessThan(capturePreparationIndex, strictPromotionIndex)
        XCTAssertFalse(events.contains(.move(88)))
        XCTAssertFalse(events.contains(.isolate(88)))
    }

    func assertActiveIsolationEvents(
        _ events: [WorkspaceExecutionEvent],
        request: LumenMacWorkspaceSessionRequest
    ) throws {
        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)
        let resolveIndex = try XCTUnwrap(events.firstIndex(of: .resolve(88)))
        let promotionIndex = try XCTUnwrap(
            events.firstIndex(of: .promote(88, .deferredUntilCaptureReady))
        )
        let barrierIndex = try XCTUnwrap(events.firstIndex(of: .firstFrameBarrier))
        let strictPromotionIndex = try XCTUnwrap(
            events.firstIndex(of: .promote(88, .required))
        )
        let isolateIndex = try XCTUnwrap(events.firstIndex(of: .isolate(88)))
        let continuityIndex = try XCTUnwrap(events.firstIndex(of: .captureContinuity))
        let pointerIndices = events.indices.filter {
            events[$0] == .positionPointer(88, geometry)
        }
        let finalResolveIndex = try XCTUnwrap(events.lastIndex(of: .resolve(88)))
        XCTAssertLessThan(resolveIndex, barrierIndex)
        XCTAssertLessThan(promotionIndex, barrierIndex)
        XCTAssertLessThan(strictPromotionIndex, barrierIndex)
        XCTAssertLessThan(strictPromotionIndex, pointerIndices[0])
        XCTAssertLessThan(barrierIndex, finalResolveIndex)
        XCTAssertLessThan(finalResolveIndex, isolateIndex)
        XCTAssertEqual(pointerIndices.count, 2)
        XCTAssertLessThan(barrierIndex, pointerIndices[0])
        XCTAssertLessThan(pointerIndices[0], isolateIndex)
        XCTAssertLessThan(isolateIndex, pointerIndices[1])
        XCTAssertLessThan(pointerIndices[1], continuityIndex)
        XCTAssertLessThan(isolateIndex, continuityIndex)
        XCTAssertLessThan(barrierIndex, isolateIndex)
        XCTAssertEqual(events.filter { $0 == .isolate(88) }.count, 1)
    }
}
