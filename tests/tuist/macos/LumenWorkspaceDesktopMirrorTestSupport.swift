import XCTest
@testable import LumenMacBridge

private struct DesktopMirrorPreparationContext {
    let recorder: WorkspaceExecutionRecorder
    let cancellationSuspension: WorkspaceRegistrySuspension?
    let request: LumenMacWorkspaceSessionRequest
    let session: LumenMacWorkspaceSession
}

func runDesktopMirrorPreparation(
    managesCapture: Bool,
    policy: LumenMacWorkspacePolicy,
    captureAdmissionOutcome: DesktopMirrorCaptureAdmissionOutcome = .success
) async throws -> [WorkspaceExecutionEvent] {
    let context = try makeDesktopMirrorPreparationContext(
        managesCapture: managesCapture,
        policy: policy,
        captureAdmissionOutcome: captureAdmissionOutcome
    )
    let prepareTask = Task {
        try await context.session.prepare()
    }
    if let failedEvents = try await awaitDesktopMirrorPreparation(
        task: prepareTask,
        context: context,
        captureAdmissionOutcome: captureAdmissionOutcome
    ) {
        return failedEvents
    }
    try await completeDesktopMirrorActivation(
        context: context,
        managesCapture: managesCapture,
        policy: policy
    )
    try await context.session.stop()
    return await context.recorder.recordedEvents()
}

func runDesktopMirrorReconfiguration() async throws -> [WorkspaceExecutionEvent] {
    let context = try makeDesktopMirrorPreparationContext(
        managesCapture: true,
        policy: .isolatedWorkspace,
        captureAdmissionOutcome: .success
    )
    try await context.session.prepare()
    let replacement = LumenMacWorkspaceSessionRequest(
        displayKey: context.request.displayKey,
        policy: context.request.policy,
        contentSource: context.request.contentSource,
        displayMode: LumenMacDisplayModeRequest(
            width: 800,
            height: 450,
            scalePercent: 100,
            dimensionsAreLogical: false
        ),
        refreshRate: context.request.refreshRate,
        managesCapture: context.request.managesCapture,
        captureConfiguration: context.request.captureConfiguration
    )
    try await context.session.reconfigure(replacement)
    let events = await context.recorder.recordedEvents()
    try await context.session.stop()
    return events
}

private func makeDesktopMirrorPreparationContext(
    managesCapture: Bool,
    policy: LumenMacWorkspacePolicy,
    captureAdmissionOutcome: DesktopMirrorCaptureAdmissionOutcome
) throws -> DesktopMirrorPreparationContext {
    let recorder = WorkspaceExecutionRecorder()
    let suspension = captureAdmissionOutcome == .cancellation
        ? WorkspaceRegistrySuspension(honorsCancellation: true)
        : nil
    let request = makeDesktopMirrorRequest(
        managesCapture: managesCapture,
        policy: policy
    )
    let session = try LumenMacWorkspaceSession(
        request: request,
        operations: makeDesktopMirrorOperations(
            recorder: recorder,
            outcome: captureAdmissionOutcome,
            cancellationSuspension: suspension
        ),
        displayWorkspace: WorkspaceDisplayMock(recorder: recorder),
        coordinator: makeCoordinator()
    )
    return DesktopMirrorPreparationContext(
        recorder: recorder,
        cancellationSuspension: suspension,
        request: request,
        session: session
    )
}

private func makeDesktopMirrorOperations(
    recorder: WorkspaceExecutionRecorder,
    outcome: DesktopMirrorCaptureAdmissionOutcome,
    cancellationSuspension: WorkspaceRegistrySuspension?
) -> LumenMacWorkspaceNativeOperations {
    LumenMacWorkspaceNativeOperations(
        createVirtualDisplay: { _, geometry in
            await recorder.append(.create(geometry))
            return 89
        },
        configureVirtualDisplay: { displayID, geometry in
            await recorder.append(.configure(displayID, geometry))
        },
        verifyVirtualDisplay: { displayID in
            await recorder.append(.resolve(displayID))
        },
        settleVirtualDisplayMode: { displayID in
            await recorder.append(.settle(displayID))
        },
        stabilizeVirtualDisplay: { displayID in
            await recorder.append(.stabilize(displayID))
        },
        prepareCaptureDisplay: { displayID in
            await recorder.append(.prepareCapture(displayID))
            try await performDesktopMirrorCaptureAdmission(
                outcome: outcome,
                cancellationSuspension: cancellationSuspension
            )
            await recorder.append(.capturePrepared(displayID))
        },
        prepareReconfiguredCaptureDisplay: { displayID in
            await recorder.append(.prepareCapture(displayID))
            try await performDesktopMirrorCaptureAdmission(
                outcome: outcome,
                cancellationSuspension: cancellationSuspension
            )
            await recorder.append(.capturePrepared(displayID))
        },
        startCapture: { _ in
            await recorder.append(.firstFrameBarrier)
        },
        stopCapture: {},
        destroyVirtualDisplay: { _ in await recorder.append(.destroy) },
        waitForExternalFirstEncodedFrame: {
            await recorder.append(.firstFrameBarrier)
        },
        positionPointer: { displayID, geometry in
            await recorder.append(.positionPointer(displayID, geometry))
        }
    )
}

private func performDesktopMirrorCaptureAdmission(
    outcome: DesktopMirrorCaptureAdmissionOutcome,
    cancellationSuspension: WorkspaceRegistrySuspension?
) async throws {
    switch outcome {
    case .success:
        return
    case .failure:
        throw DesktopMirrorCaptureAdmissionFailure.injected
    case .cancellation:
        guard let cancellationSuspension else {
            throw DesktopMirrorCaptureAdmissionFailure.injected
        }
        try await cancellationSuspension.suspend()
    }
}

private func makeDesktopMirrorRequest(
    managesCapture: Bool,
    policy: LumenMacWorkspacePolicy
) -> LumenMacWorkspaceSessionRequest {
    LumenMacWorkspaceSessionRequest(
        policy: policy,
        contentSource: .desktopMirror(sourceDisplayID: 3),
        displayMode: LumenMacDisplayModeRequest(
            width: 640,
            height: 360,
            scalePercent: 100,
            dimensionsAreLogical: false
        ),
        managesCapture: managesCapture,
        captureConfiguration: LumenMacCaptureConfiguration(displayID: 0)
    )
}

private func awaitDesktopMirrorPreparation(
    task: Task<Void, Error>,
    context: DesktopMirrorPreparationContext,
    captureAdmissionOutcome: DesktopMirrorCaptureAdmissionOutcome
) async throws -> [WorkspaceExecutionEvent]? {
    if let cancellationSuspension = context.cancellationSuspension {
        do {
            try await waitForWorkspaceRegistryCondition(
                "desktop mirror capture admission suspension"
            ) {
                await cancellationSuspension.hasEntered()
            }
        } catch {
            task.cancel()
            await cancellationSuspension.release()
            _ = try? await task.value
            throw error
        }
        task.cancel()
    }
    do {
        try await task.value
    } catch {
        try validateDesktopMirrorAdmissionError(
            error,
            outcome: captureAdmissionOutcome
        )
        return await context.recorder.recordedEvents()
    }
    guard captureAdmissionOutcome == .success else {
        XCTFail("capture admission failure unexpectedly prepared a session")
        return await context.recorder.recordedEvents()
    }
    return nil
}

private func validateDesktopMirrorAdmissionError(
    _ error: Error,
    outcome: DesktopMirrorCaptureAdmissionOutcome
) throws {
    switch outcome {
    case .success:
        throw error
    case .failure:
        guard error is DesktopMirrorCaptureAdmissionFailure else {
            throw error
        }
    case .cancellation:
        guard error is CancellationError else {
            throw error
        }
    }
}

private func completeDesktopMirrorActivation(
    context: DesktopMirrorPreparationContext,
    managesCapture: Bool,
    policy: LumenMacWorkspacePolicy
) async throws {
    if managesCapture {
        let state = try await context.session.state()
        XCTAssertEqual(state, .active)
        return
    }
    let outcome = try await context.session.activate()
    XCTAssertEqual(
        outcome.isolationStatus,
        policy == .isolatedWorkspace ? .pending : .notRequested
    )
    let events = await context.recorder.recordedEvents()
    let geometry = try LumenMacDisplayGeometryResolver.resolve(
        context.request.displayMode
    )
    XCTAssertTrue(events.contains(.firstFrameBarrier))
    XCTAssertTrue(events.contains(.positionPointer(89, geometry)))
}
