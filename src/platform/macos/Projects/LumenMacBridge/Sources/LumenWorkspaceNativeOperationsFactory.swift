struct LumenWorkspaceNativeOperationsFactory: Sendable {
    private let request: LumenMacWorkspaceSessionRequest
    private let runtime: LumenBridgeRuntime
    private let displayOwner: LumenMacVirtualDisplayOwner

    init(
        request: LumenMacWorkspaceSessionRequest,
        runtime: LumenBridgeRuntime,
        displayOwner: LumenMacVirtualDisplayOwner
    ) {
        self.request = request
        self.runtime = runtime
        self.displayOwner = displayOwner
    }

    func make() -> LumenMacWorkspaceNativeOperations {
        LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: createVirtualDisplay,
            configureVirtualDisplay: configureVirtualDisplay,
            verifyVirtualDisplay: verifyVirtualDisplay,
            settleVirtualDisplayMode: settleVirtualDisplayMode,
            stabilizeVirtualDisplay: stabilizeVirtualDisplay,
            prepareCaptureDisplay: prepareCaptureDisplay,
            startCapture: startCapture,
            stopCapture: stopCapture,
            destroyVirtualDisplay: destroyVirtualDisplay,
            waitForExternalFirstEncodedFrame: waitForExternalFirstEncodedFrame,
            verifyCaptureContinuity: verifyCaptureContinuity,
            positionPointer: positionPointer
        )
    }

    private func createVirtualDisplay(
        identity: LumenMacVirtualDisplayIdentity,
        geometry: LumenMacDisplayGeometry
    ) async throws -> UInt32 {
        try await displayOwner.create(
            identity: identity,
            geometry: geometry,
            request: request
        )
    }

    private func configureVirtualDisplay(
        displayID: UInt32,
        geometry: LumenMacDisplayGeometry
    ) async throws {
        try await displayOwner.configure(
            displayID: displayID,
            geometry: geometry,
            refreshRate: request.refreshRate
        )
    }

    private func verifyVirtualDisplay(displayID: UInt32) async throws {
        try await displayOwner.verify(displayID: displayID)
    }

    private func settleVirtualDisplayMode(displayID: UInt32) async throws {
        try await displayOwner.settleMode(displayID: displayID)
    }

    private func stabilizeVirtualDisplay(displayID: UInt32) async throws {
        try await displayOwner.stabilize(displayID: displayID)
    }

    private func prepareCaptureDisplay(displayID: UInt32) async throws {
        try await displayOwner.awaitCapturePreparation(displayID: displayID)
    }

    private func startCapture(displayID: UInt32) async throws {
        try await runtime.startCapture(
            configuration: request.captureConfiguration.replacingDisplayID(displayID)
        )
        try await runtime.waitForFirstEncodedFrame(
            timeoutNanoseconds: LumenMacWorkspaceSession.firstEncodedFrameTimeoutNanoseconds
        )
    }

    private func stopCapture() async {
        await runtime.stopCapture()
    }

    private func destroyVirtualDisplay(
        identity: LumenMacVirtualDisplayIdentity
    ) async throws {
        try await displayOwner.destroy(identity: identity)
    }

    private func waitForExternalFirstEncodedFrame() async throws {
        try await runtime.waitForFirstEncodedFrame(
            timeoutNanoseconds: LumenMacWorkspaceSession.firstEncodedFrameTimeoutNanoseconds
        )
    }

    private func verifyCaptureContinuity() async throws {
        try await runtime.verifyEncodedFrameContinuity(
            timeoutNanoseconds: LumenMacWorkspaceSession.captureContinuityTimeoutNanoseconds
        )
    }

    private func positionPointer(
        displayID: UInt32,
        geometry: LumenMacDisplayGeometry
    ) async {
        LumenMacPointerPositioner.centerPointer(
            on: displayID,
            geometry: geometry
        )
    }
}
