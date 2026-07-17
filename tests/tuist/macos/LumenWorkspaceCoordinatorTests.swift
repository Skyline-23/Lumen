import XCTest
@testable import LumenMacBridge

private enum WorkspaceExecutionEvent: Equatable {
    case snapshot([Int32])
    case create(LumenMacDisplayGeometry)
    case configure(UInt32, LumenMacDisplayGeometry)
    case resolve(UInt32)
    case isolate(UInt32)
    case firstFrameBarrier
    case captureContinuity
    case startCapture(UInt32)
    case stopCapture
    case restore
    case verify
    case destroy
}

private actor WorkspaceExecutionRecorder {
    private var events: [WorkspaceExecutionEvent] = []

    func append(_ event: WorkspaceExecutionEvent) {
        events.append(event)
    }

    func recordedEvents() -> [WorkspaceExecutionEvent] {
        events
    }
}

private actor WorkspaceDisplayMock: LumenMacDisplayWorkspaceManaging {
    private let recorder: WorkspaceExecutionRecorder

    init(recorder: WorkspaceExecutionRecorder) {
        self.recorder = recorder
    }

    func snapshotWorkspace(
        targetProcessIdentifiers: [Int32]
    ) async -> LumenMacPhysicalDisplayTopology {
        await recorder.append(.snapshot(targetProcessIdentifiers))
        return testTopology()
    }

    func promoteVirtualDisplay(_: UInt32) async {}
    func moveTargetWindows(to _: UInt32) async {}
    func awaitVirtualDisplay(_ displayID: UInt32) async {
        await recorder.append(.resolve(displayID))
    }
    func isolateVirtualDisplay(_ displayID: UInt32) async {
        await recorder.append(.isolate(displayID))
    }
    func restoreWorkspace(_: LumenMacPhysicalDisplayTopology) async {
        await recorder.append(.restore)
    }
    func verifyWorkspace(_: LumenMacPhysicalDisplayTopology) async {
        await recorder.append(.verify)
    }
    func discardSnapshot() async {}
}

private actor DisappearingWorkspaceDisplayMock: LumenMacDisplayWorkspaceManaging {
    private let recorder: WorkspaceExecutionRecorder

    init(recorder: WorkspaceExecutionRecorder) {
        self.recorder = recorder
    }

    func snapshotWorkspace(
        targetProcessIdentifiers: [Int32]
    ) async -> LumenMacPhysicalDisplayTopology {
        await recorder.append(.snapshot(targetProcessIdentifiers))
        return testTopology()
    }

    func promoteVirtualDisplay(_: UInt32) async {}
    func moveTargetWindows(to _: UInt32) async {}
    func awaitVirtualDisplay(_ displayID: UInt32) async throws {
        await recorder.append(.resolve(displayID))
        throw LumenMacDisplayWorkspaceError.displayNotFound(displayID)
    }
    func isolateVirtualDisplay(_ displayID: UInt32) async {
        await recorder.append(.isolate(displayID))
    }
    func restoreWorkspace(_: LumenMacPhysicalDisplayTopology) async {
        await recorder.append(.restore)
    }
    func verifyWorkspace(_: LumenMacPhysicalDisplayTopology) async {
        await recorder.append(.verify)
    }
    func discardSnapshot() async {}
}

final class LumenWorkspaceCoordinatorTests: XCTestCase {
    func testRetinaDesktopScalePreservesNativeStreamPixels() throws {
        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            )
        )

        XCTAssertEqual(geometry.streamWidth, 2388)
        XCTAssertEqual(geometry.streamHeight, 1668)
        XCTAssertEqual(geometry.logicalWidth, 1592)
        XCTAssertEqual(geometry.logicalHeight, 1112)
        XCTAssertEqual(geometry.backingWidth, 2388)
        XCTAssertEqual(geometry.backingHeight, 1668)
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
                .startCapture,
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
        XCTAssertEqual(
            teardownActions,
            [.restoreWorkspace, .verifyPhysicalDisplays, .destroyVirtualDisplay]
        )
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
                .destroyVirtualDisplay,
            ]
        )
        let state = try await coordinator.currentState()
        XCTAssertEqual(state, .idle)
    }

    func testExecutorPassesRustGeometryToNativeDisplayOperations() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 42
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            startCapture: { displayID in
                await recorder.append(.startCapture(displayID))
            },
            stopCapture: {},
            destroyVirtualDisplay: { _ in }
        )
        let executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [123],
            displayMode: LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            ),
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder)
        )
        let coordinator = try makeCoordinator()

        try await coordinator.beginSession(policy: .coexist)
        try await coordinator.executePendingCommands(using: executor)

        let geometry = try LumenMacDisplayGeometryResolver.resolve(
            LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            )
        )
        let events = await recorder.recordedEvents()
        XCTAssertEqual(
            events,
            [
                .snapshot([123]),
                .create(geometry),
                .configure(42, geometry),
                .startCapture(42),
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
                dimensionsAreLogical: false
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

    func testExternalCapturePreparationPausesBeforePhysicalIsolation() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 88
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
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
        let request = externalIsolatedRequest()
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: makeCoordinator()
        )

        try await session.prepare()

        let preparedEvents = await recorder.recordedEvents()
        XCTAssertFalse(preparedEvents.contains(.firstFrameBarrier))
        XCTAssertFalse(preparedEvents.contains(.isolate(88)))
        let preparedState = try await session.state()
        XCTAssertEqual(preparedState, .starting)

        try await session.activate()

        let activeEvents = await recorder.recordedEvents()
        let resolveIndex = try XCTUnwrap(activeEvents.firstIndex(of: .resolve(88)))
        let barrierIndex = try XCTUnwrap(activeEvents.firstIndex(of: .firstFrameBarrier))
        let isolateIndex = try XCTUnwrap(activeEvents.firstIndex(of: .isolate(88)))
        let continuityIndex = try XCTUnwrap(activeEvents.firstIndex(of: .captureContinuity))
        XCTAssertLessThan(resolveIndex, barrierIndex)
        XCTAssertLessThan(barrierIndex, isolateIndex)
        XCTAssertLessThan(isolateIndex, continuityIndex)
        let activeState = try await session.state()
        XCTAssertEqual(activeState, .active)
        try await session.stop()
    }

    func testPreparedDisplayDisappearanceRollsBackBeforeIsolationAndRemovesJournal() async throws {
        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 90
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            startCapture: { _ in },
            stopCapture: {},
            destroyVirtualDisplay: { _ in await recorder.append(.destroy) },
            waitForExternalFirstEncodedFrame: {
                await recorder.append(.firstFrameBarrier)
            }
        )
        let journalPath = temporaryRecoveryJournalPath()
        let session = try LumenMacWorkspaceSession(
            request: externalIsolatedRequest(),
            operations: operations,
            displayWorkspace: DisappearingWorkspaceDisplayMock(recorder: recorder),
            coordinator: LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        )

        try await session.prepare()
        let preparedDisplayID = try await session.displayID()
        XCTAssertEqual(preparedDisplayID, 90)

        do {
            try await session.activate()
            XCTFail("expected the disappeared prepared display to fail closed")
        } catch LumenMacDisplayWorkspaceError.displayNotFound(90) {}

        let events = await recorder.recordedEvents()
        XCTAssertTrue(events.contains(.resolve(90)))
        XCTAssertFalse(events.contains(.firstFrameBarrier))
        XCTAssertFalse(events.contains(.isolate(90)))
        XCTAssertTrue(events.contains(.restore))
        XCTAssertTrue(events.contains(.verify))
        XCTAssertTrue(events.contains(.destroy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalPath))
        let recoveredState = try await session.state()
        XCTAssertEqual(recoveredState, .idle)
    }

    func testFailedExternalFirstFrameBarrierLeavesPhysicalDisplaysUntouched() async throws {
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
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 73
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
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
        let request = LumenMacWorkspaceSessionRequest(
            displayMode: LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            ),
            captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
        )
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: operations,
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
                .startCapture(73),
                .stopCapture,
                .restore,
                .verify,
                .destroy,
            ]
        )
    }

    func testWorkspaceSessionRestoresResourcesAfterCaptureStartupFailure() async throws {
        enum ExpectedFailure: Error {
            case captureStartup
        }

        let recorder = WorkspaceExecutionRecorder()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, geometry in
                await recorder.append(.create(geometry))
                return 91
            },
            configureVirtualDisplay: { displayID, geometry in
                await recorder.append(.configure(displayID, geometry))
            },
            startCapture: { displayID in
                await recorder.append(.startCapture(displayID))
                throw ExpectedFailure.captureStartup
            },
            stopCapture: {
                await recorder.append(.stopCapture)
            },
            destroyVirtualDisplay: { _ in
                await recorder.append(.destroy)
            }
        )
        let request = LumenMacWorkspaceSessionRequest(
            displayMode: LumenMacDisplayModeRequest(
                width: 1920,
                height: 1080,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
        )
        let session = try LumenMacWorkspaceSession(
            request: request,
            operations: operations,
            displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
            coordinator: makeCoordinator()
        )

        do {
            try await session.start()
            XCTFail("Expected capture startup failure")
        } catch ExpectedFailure.captureStartup {
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
                .restore,
                .verify,
                .destroy,
            ]
        )
    }

    func testVirtualDisplayConfigurationPreservesHDRSinkContract() throws {
        let capture = LumenMacCaptureConfiguration(
            displayID: 0,
            sinkRequest: LumenBridgeSinkRequest(
                capability: LumenBridgeSinkCapability(
                    gamut: .displayP3,
                    transfer: .pq,
                    currentEDRHeadroom: 1.2,
                    potentialEDRHeadroom: 16,
                    currentPeakLuminanceNits: 120,
                    potentialPeakLuminanceNits: 1600,
                    supportsFrameGatedHDR: true,
                    supportsPerFrameHDRMetadata: true
                ),
                dynamicRangeTransport: LumenMacDynamicRangeTransportFrameGatedHDR
            ),
            effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                gamut: .displayP3,
                transfer: .pq
            )
        )
        let request = LumenMacWorkspaceSessionRequest(
            displayMode: LumenMacDisplayModeRequest(
                width: 2388,
                height: 1668,
                scalePercent: 150,
                dimensionsAreLogical: false
            ),
            refreshRate: 120,
            captureConfiguration: capture
        )
        let geometry = try LumenMacDisplayGeometryResolver.resolve(request.displayMode)

        let configuration = try LumenMacVirtualDisplayConfigurationFactory.make(
            geometry: geometry,
            request: request
        )

        XCTAssertEqual(configuration.backingWidth, 2388)
        XCTAssertEqual(configuration.logicalWidth, 1592)
        XCTAssertEqual(configuration.refreshRate, 120)
        XCTAssertTrue(configuration.highDensity)
        XCTAssertTrue(configuration.hdrEnabled)
        XCTAssertEqual(configuration.gamut.rawValue, 1)
        XCTAssertEqual(configuration.transfer.rawValue, 1)
        XCTAssertEqual(configuration.currentPeakLuminanceNits, 120)
        XCTAssertEqual(configuration.potentialPeakLuminanceNits, 1600)
    }

    func testWorkspaceRequestBoxBuildsExternalCaptureSession() throws {
        let box = LumenMacWorkspaceSessionRequestBox()
        box.displayKey = "client-key"
        box.width = 2732
        box.height = 2048
        box.scalePercent = 77
        box.refreshRate = 120
        box.hdrEnabled = true
        box.clientSinkGamutRawValue = 3
        box.clientSinkTransferRawValue = 2
        box.potentialEDRHeadroom = 16
        box.potentialPeakLuminanceNits = 1600

        let request = box.makeRequest(policy: .isolatedWorkspace)

        XCTAssertEqual(request.displayKey, "client-key")
        XCTAssertEqual(request.policy, .isolatedWorkspace)
        XCTAssertFalse(request.managesCapture)
        XCTAssertEqual(request.displayMode.scalePercent, 77)
        XCTAssertTrue(request.captureConfiguration.usesHDRTransport)
        XCTAssertEqual(
            request.captureConfiguration.sinkRequest.capability.potentialPeakLuminanceNits,
            1600
        )
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

    private func makeCoordinator() throws -> LumenWorkspaceCoordinator {
        try LumenWorkspaceCoordinator(recoveryJournalPath: temporaryRecoveryJournalPath())
    }

    private func temporaryRecoveryJournalPath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "display-recovery.json", directoryHint: .notDirectory)
            .path(percentEncoded: false)
    }

    private func externalIsolatedRequest() -> LumenMacWorkspaceSessionRequest {
        LumenMacWorkspaceSessionRequest(
            policy: .isolatedWorkspace,
            displayMode: LumenMacDisplayModeRequest(
                width: 1920,
                height: 1080,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            managesCapture: false,
            captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
        )
    }
}

private func testTopology() -> LumenMacPhysicalDisplayTopology {
    LumenMacPhysicalDisplayTopology(
        displays: [
            LumenMacPhysicalDisplayState(
                id: "1",
                mode: LumenMacPhysicalDisplayMode(
                    width: 2560,
                    height: 1440,
                    refreshMillihertz: 120_000,
                    bitDepth: 10
                ),
                originX: 0,
                originY: 0,
                mirrorMasterID: nil,
                enabled: true,
                active: true,
                online: true
            ),
        ],
        windowsAdapterLUID: nil,
        windowsTargetPaths: []
    )
}
