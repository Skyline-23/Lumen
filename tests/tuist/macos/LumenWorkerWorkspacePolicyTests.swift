@testable import LumenMacBridge
import XCTest

final class LumenWorkerWorkspacePolicyTests: XCTestCase {
    func testExplicitWorkerPolicySurvivesTheProcessBoundary() throws {
        XCTAssertEqual(
            try LumenHostSettingsStore.workerWorkspacePolicy(arguments: [
                "/Applications/Lumen.app/Contents/MacOS/LumenHostWorker",
                "workspace_policy=isolated-workspace", "port=48989",
            ]),
            .isolatedWorkspace
        )
        XCTAssertEqual(
            try LumenHostSettingsStore.workerWorkspacePolicy(arguments: [
                "LumenHostWorker", "workspace_policy=coexist",
            ]),
            .coexist
        )
    }

    func testMissingWorkerPolicyUsesTheSettingsStore() throws {
        XCTAssertNil(try LumenHostSettingsStore.workerWorkspacePolicy(
            arguments: ["LumenHostWorker", "host_name=workspace_policy=coexist"]
        ))
    }

    func testAmbiguousOrInvalidPolicyCannotSilentlyChangeIsolation() {
        for arguments in [
            ["workspace_policy=unknown"],
            ["workspace_policy="],
            ["workspace_policy=coexist", "workspace_policy=isolated-workspace"],
        ] {
            XCTAssertThrowsError(try LumenHostSettingsStore.workerWorkspacePolicy(
                arguments: arguments
            ))
        }
    }
}
