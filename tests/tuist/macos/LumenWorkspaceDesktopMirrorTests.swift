import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceDesktopMirrorTests: XCTestCase {
    func testDesktopMirrorStagesRetainedSourceWithoutGenericMainPromotionBeforeFreshCaptureAdmission() async throws {
        for managesCapture in [false, true] {
            let preparedEvents = try await runDesktopMirrorPreparation(
                managesCapture: managesCapture,
                policy: .isolatedWorkspace
            )
            try assertIsolatedMirrorStages(preparedEvents)
            try assertIsolatedMirrorCleanup(preparedEvents)

            let coexistEvents = try await runDesktopMirrorPreparation(
                managesCapture: managesCapture,
                policy: .coexist
            )
            try assertCoexistMirrorLifecycle(coexistEvents)
        }
    }

    func testDesktopMirrorWaitsForExactDisplayQueryCompletionBeforeTopologyCommit() async throws {
        for policy in [LumenMacWorkspacePolicy.isolatedWorkspace, .coexist] {
            let events = try await runDesktopMirrorPreparation(
                managesCapture: true,
                policy: policy,
                captureAdmissionOutcome: .cancellation
            )

            XCTAssertEqual(
                events.filter { $0 == .prepareCapture(89) }.count,
                1
            )
            XCTAssertFalse(events.contains(.mirror(89, 3)))
            XCTAssertEqual(events.filter { $0 == .stabilize(89) }.count, 1)
            let stageIndex = try XCTUnwrap(
                events.firstIndex(of: .prepareDesktopMirror(89, 3))
            )
            let stabilizationIndex = try XCTUnwrap(
                events.firstIndex(of: .stabilize(89))
            )
            let prefetchIndex = try XCTUnwrap(
                events.firstIndex(of: .prepareCapture(89))
            )
            XCTAssertLessThan(stageIndex, stabilizationIndex)
            XCTAssertLessThan(stabilizationIndex, prefetchIndex)
        }
    }

}

private extension LumenWorkspaceDesktopMirrorTests {
    func assertIsolatedMirrorStages(
        _ events: [WorkspaceExecutionEvent]
    ) throws {
        XCTAssertEqual(events.filter { $0 == .prepareDesktopMirror(89, 3) }.count, 1)
        XCTAssertEqual(events.filter { $0 == .prepareCapture(89) }.count, 1)
        XCTAssertEqual(events.filter { $0 == .mirror(89, 3) }.count, 1)
        XCTAssertEqual(events.filter { $0 == .stabilize(89) }.count, 2)
        XCTAssertEqual(events.filter { $0 == .settle(89) }.count, 1)
        let configureIndex = try XCTUnwrap(
            events.firstIndex {
                if case .configure(89, _) = $0 { return true }
                return false
            }
        )
        let settlementIndex = try XCTUnwrap(events.firstIndex(of: .settle(89)))
        let stageIndex = try XCTUnwrap(
            events.firstIndex(of: .prepareDesktopMirror(89, 3))
        )
        let mirrorIndex = try XCTUnwrap(events.firstIndex(of: .mirror(89, 3)))
        let independentStabilizationIndex = try XCTUnwrap(
            events.firstIndex(of: .stabilize(89))
        )
        let mirroredStabilizationIndex = try XCTUnwrap(
            events.lastIndex(of: .stabilize(89))
        )
        let prefetchIndex = try XCTUnwrap(
            events.firstIndex(of: .prepareCapture(89))
        )
        XCTAssertLessThan(configureIndex, settlementIndex)
        XCTAssertLessThan(settlementIndex, stageIndex)
        XCTAssertLessThan(stageIndex, independentStabilizationIndex)
        XCTAssertLessThan(independentStabilizationIndex, prefetchIndex)
        XCTAssertLessThan(prefetchIndex, mirrorIndex)
        XCTAssertLessThan(mirrorIndex, mirroredStabilizationIndex)
        XCTAssertFalse(events.contains {
            if case .promote = $0 { return true }
            return false
        })
    }

    func assertIsolatedMirrorCleanup(
        _ events: [WorkspaceExecutionEvent]
    ) throws {
        let firstFrameIndex = try XCTUnwrap(events.firstIndex(of: .firstFrameBarrier))
        let isolateIndex = try XCTUnwrap(events.firstIndex(of: .isolate(89)))
        let prefetchIndex = try XCTUnwrap(events.firstIndex(of: .prepareCapture(89)))
        let restoreIndex = try XCTUnwrap(events.firstIndex(of: .restore))
        let verifyIndex = try XCTUnwrap(events.firstIndex(of: .verify))
        let destroyIndex = try XCTUnwrap(events.firstIndex(of: .destroy))
        XCTAssertLessThan(firstFrameIndex, isolateIndex)
        XCTAssertLessThan(prefetchIndex, restoreIndex)
        XCTAssertLessThan(isolateIndex, restoreIndex)
        XCTAssertLessThan(restoreIndex, verifyIndex)
        XCTAssertLessThan(verifyIndex, destroyIndex)
    }

    func assertCoexistMirrorLifecycle(
        _ events: [WorkspaceExecutionEvent]
    ) throws {
        XCTAssertFalse(events.contains {
            if case .promote = $0 { return true }
            return false
        })
        XCTAssertFalse(events.contains(.isolate(89)))
        XCTAssertEqual(events.filter { $0 == .mirror(89, 3) }.count, 1)
        let restoreIndex = try XCTUnwrap(events.firstIndex(of: .restore))
        let verifyIndex = try XCTUnwrap(events.firstIndex(of: .verify))
        let destroyIndex = try XCTUnwrap(events.firstIndex(of: .destroy))
        XCTAssertLessThan(restoreIndex, verifyIndex)
        XCTAssertLessThan(verifyIndex, destroyIndex)
    }
}
