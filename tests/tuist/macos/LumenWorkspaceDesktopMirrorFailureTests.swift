import XCTest
@testable import LumenMacBridge

final class LumenWorkspaceDesktopMirrorFailureTests: XCTestCase {
    func testDesktopMirrorCaptureAdmissionFailureRestoresTrackedTopology() async throws {
        for managesCapture in [false, true] {
            for outcome in [
                DesktopMirrorCaptureAdmissionOutcome.failure,
                .cancellation
            ] {
                let events = try await runDesktopMirrorPreparation(
                    managesCapture: managesCapture,
                    policy: .isolatedWorkspace,
                    captureAdmissionOutcome: outcome
                )
                let mirrorIndex = try XCTUnwrap(
                    events.firstIndex(of: .mirror(89, 3))
                )
                let prefetchIndex = try XCTUnwrap(
                    events.firstIndex(of: .prepareCapture(89))
                )
                let restoreIndex = try XCTUnwrap(
                    events.firstIndex(of: .restore)
                )
                let verifyIndex = try XCTUnwrap(
                    events.firstIndex(of: .verify)
                )
                let destroyIndex = try XCTUnwrap(
                    events.firstIndex(of: .destroy)
                )
                XCTAssertFalse(events.contains {
                    if case .promote = $0 { return true }
                    return false
                })
                XCTAssertLessThan(mirrorIndex, prefetchIndex)
                XCTAssertLessThan(prefetchIndex, restoreIndex)
                XCTAssertLessThan(restoreIndex, verifyIndex)
                XCTAssertLessThan(verifyIndex, destroyIndex)
            }
        }
    }

}
