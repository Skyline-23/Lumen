import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceSessionPromotionTests: XCTestCase {
    func testDisplayReadinessFailureRestoresPromotedWorkspaceBeforeOwnedDisplayRollback() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let (session, journalPath) = try makePromotionFailureSession(
            scenario: .displayReadiness,
            recorder: recorder
        )

        do {
            try await session.prepare()
            XCTFail("expected display readiness to fail closed")
        } catch LumenScreenCaptureError.displayUnavailable(90) {}

        let events = await recorder.recordedEvents()
        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            externalIsolatedRequest().displayMode
        )
        XCTAssertTrue(events.contains(.configure(90, geometry)))
        let promotionIndex = try XCTUnwrap(
            events.firstIndex(
                of: .promote(90, .deferredUntilCaptureReady)
            )
        )
        let resolveIndex = try XCTUnwrap(events.firstIndex(of: .resolve(90)))
        let capturePreparationIndex = try XCTUnwrap(
            events.firstIndex(of: .prepareCapture(90))
        )
        let restoreIndex = try XCTUnwrap(events.firstIndex(of: .restore))
        let destroyIndex = try XCTUnwrap(events.firstIndex(of: .destroy))
        XCTAssertLessThan(resolveIndex, promotionIndex)
        XCTAssertLessThan(promotionIndex, capturePreparationIndex)
        XCTAssertLessThan(capturePreparationIndex, restoreIndex)
        XCTAssertLessThan(restoreIndex, destroyIndex)
        XCTAssertFalse(events.contains(.firstFrameBarrier))
        XCTAssertFalse(events.contains(.isolate(90)))
        XCTAssertTrue(events.contains(.verify))
        XCTAssertTrue(events.contains(.destroy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
        let recoveredState = try await session.state()
        XCTAssertEqual(recoveredState, .idle)
    }

    func testFailedOwnedDisplayPromotionStopsBeforeCaptureAndRollsBack() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let (session, journalPath) = try makePromotionFailureSession(
            scenario: .deferredPromotion,
            recorder: recorder
        )

        do {
            try await session.prepare()
            XCTFail("expected failed virtual display promotion to fail closed")
        } catch LumenMacDisplayWorkspaceError.virtualDisplayPromotionUnavailable(118) {}

        let events = await recorder.recordedEvents()
        let ownerVerificationIndex = try XCTUnwrap(events.firstIndex(of: .resolve(118)))
        let promotionIndex = try XCTUnwrap(
            events.firstIndex(
                of: .promote(118, .deferredUntilCaptureReady)
            )
        )
        let destroyIndex = try XCTUnwrap(events.firstIndex(of: .destroy))
        XCTAssertLessThan(ownerVerificationIndex, promotionIndex)
        XCTAssertLessThan(promotionIndex, destroyIndex)
        XCTAssertFalse(events.contains(.prepareCapture(118)))
        XCTAssertFalse(events.contains(.firstFrameBarrier))
        XCTAssertFalse(events.contains(.isolate(118)))
        XCTAssertFalse(events.contains(.restore))
        XCTAssertFalse(events.contains(.verify))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
        let recoveredState = try await session.state()
        XCTAssertEqual(recoveredState, .idle)
    }

    func testPostReadinessPromotionFailureRestoresWithoutIsolation() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let (session, journalPath) = try makePromotionFailureSession(
            scenario: .strictPromotion,
            recorder: recorder
        )

        do {
            try await session.prepare()
            XCTFail("expected post-readiness promotion to fail closed")
        } catch LumenMacDisplayWorkspaceError.virtualDisplayPromotionUnavailable(119) {}

        let events = await recorder.recordedEvents()
        let capturePreparationIndex = try XCTUnwrap(
            events.firstIndex(of: .prepareCapture(119))
        )
        let deferredPromotionIndex = try XCTUnwrap(
            events.firstIndex(
                of: .promote(119, .deferredUntilCaptureReady)
            )
        )
        let strictPromotionIndex = try XCTUnwrap(
            events.firstIndex(of: .promote(119, .required))
        )
        let restoreIndex = try XCTUnwrap(events.firstIndex(of: .restore))
        let verifyIndex = try XCTUnwrap(events.firstIndex(of: .verify))
        let destroyIndex = try XCTUnwrap(events.firstIndex(of: .destroy))
        XCTAssertLessThan(deferredPromotionIndex, capturePreparationIndex)
        XCTAssertLessThan(capturePreparationIndex, strictPromotionIndex)
        XCTAssertLessThan(strictPromotionIndex, restoreIndex)
        XCTAssertLessThan(restoreIndex, verifyIndex)
        XCTAssertLessThan(verifyIndex, destroyIndex)
        XCTAssertFalse(events.contains(.firstFrameBarrier))
        XCTAssertFalse(events.contains(.isolate(119)))
        XCTAssertFalse(events.contains(.captureContinuity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
        let recoveredState = try await session.state()
        XCTAssertEqual(recoveredState, .idle)
    }

}

private enum WorkspacePromotionFailureScenario: Sendable {
    case displayReadiness
    case deferredPromotion
    case strictPromotion

    var displayID: UInt32 {
        switch self {
        case .displayReadiness:
            return 90
        case .deferredPromotion:
            return 118
        case .strictPromotion:
            return 119
        }
    }

    var promotionResults: [Bool] {
        switch self {
        case .displayReadiness:
            return [true]
        case .deferredPromotion:
            return [false]
        case .strictPromotion:
            return [true, false]
        }
    }
}

private extension LumenWorkspaceSessionPromotionTests {
    func makePromotionFailureSession(
        scenario: WorkspacePromotionFailureScenario,
        recorder: WorkspaceExecutionRecorder
    ) throws -> (LumenMacWorkspaceSession, String) {
        let journalPath = temporaryRecoveryJournalPath()
        let session = try LumenMacWorkspaceSession(
            request: externalIsolatedRequest(),
            operations: makePromotionOperations(
                scenario: scenario,
                recorder: recorder
            ),
            displayWorkspace: WorkspaceDisplayMock(
                recorder: recorder,
                promotionResults: scenario.promotionResults
            ),
            coordinator: LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        )
        return (session, journalPath)
    }

    func makePromotionOperations(
        scenario: WorkspacePromotionFailureScenario,
        recorder: WorkspaceExecutionRecorder
    ) -> LumenMacWorkspaceNativeOperations {
        LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return scenario.displayID
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { displayID in
                await recorder.append(.resolve(displayID))
            },
            prepareCaptureDisplay: { displayID in
                await recorder.append(.prepareCapture(displayID))
                if scenario == .displayReadiness {
                    throw LumenScreenCaptureError.displayUnavailable(displayID)
                }
            },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) },
            waitForExternalFirstEncodedFrame: {
                await recorder.append(.firstFrameBarrier)
            },
            verifyCaptureContinuity: {
                await recorder.append(.captureContinuity)
            }
        )
    }
}
