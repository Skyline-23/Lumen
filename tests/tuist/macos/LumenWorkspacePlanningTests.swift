import XCTest
@testable import LumenMacBridge

final class LumenWorkspacePlanningTests: XCTestCase {
    func testRetinaDesktopScalePreservesNativeStreamPixels() throws {
        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            LumenMacDisplayModeRequest(
                width: 3024,
                height: 1964,
                scalePercent: 168,
                dimensionsAreLogical: false,
                highDensity: true
            )
        )

        XCTAssertEqual(geometry.streamWidth, 3024)
        XCTAssertEqual(geometry.streamHeight, 1964)
        XCTAssertEqual(geometry.logicalWidth, 1800)
        XCTAssertEqual(geometry.logicalHeight, 1169)
        XCTAssertEqual(geometry.backingWidth, 3600)
        XCTAssertEqual(geometry.backingHeight, 2338)
    }

    func testCoexistWorkspaceDoesNotPromoteOrMoveWindows() async throws {
        let coordinator = try makeCoordinator()
        try await coordinator.beginSession(policy: .coexist)

        let actions = try await completePendingCommands(coordinator)

        XCTAssertEqual(
            actions,
            [
                .snapshotWorkspace,
                .createVirtualDisplay,
                .configureVirtualDisplay,
                .startCapture
            ]
        )
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .active)
    }

    func testExternalCaptureOwnershipOmitsCaptureCommands() async throws {
        let coordinator = try makeCoordinator()
        try await coordinator.beginSession(policy: .coexist, manageCapture: false)

        let startupActions = try await completePendingCommands(coordinator)
        XCTAssertFalse(startupActions.contains(.startCapture))
        let activeState = try await coordinator.currentState()
        XCTAssertEqual(activeState, .active)

        try await coordinator.endSession()
        let teardownActions = try await completePendingCommands(coordinator)
        XCTAssertFalse(teardownActions.contains(.stopCapture))
        XCTAssertEqual(teardownActions, [.destroyVirtualDisplay])
    }

    func testFocusedWorkspaceRestoresAfterCaptureStops() async throws {
        let coordinator = try makeCoordinator()
        try await coordinator.beginSession(policy: .focusedWorkspace)

        let startup = try await completePendingCommands(coordinator)
        XCTAssertTrue(startup.contains(.promoteVirtualMain))
        XCTAssertTrue(startup.contains(.moveTargetWindows))
        XCTAssertFalse(startup.contains(.applyIsolation))

        try await coordinator.endSession()
        let teardown = try await completePendingCommands(coordinator)
        XCTAssertEqual(
            teardown,
            [
                .stopCapture,
                .restoreWorkspace,
                .verifyPhysicalDisplays,
                .destroyVirtualDisplay
            ]
        )
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testExecutorPassesRustGeometryToNativeDisplayOperations() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let displayMode = LumenMacDisplayModeRequest(
            width: 2388,
            height: 1668,
            scalePercent: 150,
            dimensionsAreLogical: false,
            highDensity: true
        )
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 42
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            verifyVirtualDisplay: { displayID in
                await recorder.append(.resolve(displayID))
            },
            startCapture: { displayID in
                await recorder.append(.startCapture(displayID))
            },
            stopCapture: {},
            destroyVirtualDisplay: { _ in }
        )
        let executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [123],
            displayMode: displayMode,
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder)
        )
        let coordinator = try makeCoordinator()

        try await coordinator.beginSession(policy: .coexist)
        try await coordinator.executePendingCommands(using: executor)

        let geometry = try LumenMacDisplayGeometryResolver.resolve(displayMode)
        let events = await recorder.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .snapshot([123]),
                .create(geometry),
                .configure(42, geometry),
                .startCapture(42)
            ]
        )
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .active)
    }

    func testIsolatedWorkspaceExecutesTypedDisplayIsolation() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, _ in 55 },
            configureVirtualDisplay: { _, _ in },
            verifyVirtualDisplay: { _ in },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { _ in }
        )
        let executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [],
            displayMode: LumenMacDisplayModeRequest(
                width: 1920,
                height: 1080,
                scalePercent: 100,
                dimensionsAreLogical: false,
                highDensity: false
            ),
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder)
        )
        let coordinator = try makeCoordinator()

        try await coordinator.beginSession(
            policy: .isolatedWorkspace,
            manageCapture: false
        )
        try await coordinator.executePendingCommands(using: executor)

        let events = await recorder.recordedEvents()
        XCTAssertTrue(events.contains(.isolate(55)))
        try await coordinator.endSession()
        try await coordinator.executePendingCommands(using: executor)
    }

    private func completePendingCommands(
        _ coordinator: LumenWorkspaceCoordinator
    ) async throws -> [LumenMacWorkspaceAction] {
        var actions: [LumenMacWorkspaceAction] = []
        while let command = try await coordinator.nextCommand() {
            actions.append(command.action)
            let result: LumenMacWorkspaceCommandResult
            switch command.action {
            case .snapshotWorkspace:
                result = .physicalTopology(testTopology())
            case .createVirtualDisplay:
                if case .virtualDisplayIdentity(let identity) = command.payload {
                    result = .virtualDisplayIdentity(identity)
                } else {
                    XCTFail("expected virtual display identity payload")
                    result = .failed
                }
            default:
                result = .succeeded
            }
            try await coordinator.complete(command, result: result)
        }
        return actions
    }
}
