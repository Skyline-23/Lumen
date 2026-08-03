public actor LumenMacWorkspaceSession {
    enum Phase {
        case idle
        case prepared
        case active
        case recoveryPending
    }

    static let firstEncodedFrameTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let captureContinuityTimeoutNanoseconds: UInt64 = 2_000_000_000

    var request: LumenMacWorkspaceSessionRequest
    let coordinator: LumenWorkspaceCoordinator
    let executor: LumenMacWorkspaceExecutor
    let preparationFence: @Sendable () async throws -> Void
    let isolationStatusHandler: @Sendable (LumenMacWorkspaceIsolationStatus) async -> Void
    var phase = Phase.idle
    var activationCommand: LumenMacWorkspaceCommand?
    var isolationTask: Task<Void, Never>?

    init(
        request: LumenMacWorkspaceSessionRequest,
        runtime: LumenBridgeRuntime = .shared,
        operations: LumenMacWorkspaceNativeOperations,
        displayWorkspace: any LumenMacDisplayWorkspaceManaging,
        coordinator: LumenWorkspaceCoordinator? = nil,
        preparationFence: @escaping @Sendable () async throws -> Void = {
            try Task.checkCancellation()
        },
        isolationStatusHandler: @escaping @Sendable (
            LumenMacWorkspaceIsolationStatus
        ) async -> Void = { _ in }
    ) throws {
        self.request = request
        self.coordinator = try coordinator ?? LumenWorkspaceCoordinator()
        self.preparationFence = preparationFence
        self.isolationStatusHandler = isolationStatusHandler
        executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: request.targetProcessIdentifiers,
            contentSource: request.contentSource,
            displayMode: request.displayMode,
            operations: operations,
            displayWorkspace: displayWorkspace
        )
    }

    public func start() async throws {
        try await prepare()
        try await activate()
    }

    public func prepare() async throws {
        try await prepareImpl()
    }

    @discardableResult
    public func activate() async throws -> LumenMacWorkspaceActivationOutcome {
        try await activateImpl()
    }

    public func stop() async throws {
        try await stopImpl()
    }

    public func reconfigure(
        _ replacement: LumenMacWorkspaceSessionRequest
    ) async throws {
        guard phase == .active,
              replacement.displayKey == request.displayKey
        else {
            throw LumenMacWorkspaceSessionError.sessionNotStarted
        }
        let replacementGeometry = try LumenMacDisplayGeometryResolver.resolve(
            replacement.displayMode
        )
        _ = try await applyDisplayMode(
            replacement,
            geometry: replacementGeometry
        )
        request = replacement
    }

    public func state() async throws -> LumenMacWorkspaceState {
        try await coordinator.currentState()
    }

    public func displayID() async throws -> UInt32 {
        try await executor.activeVirtualDisplayID()
    }

    private func applyDisplayMode(
        _ request: LumenMacWorkspaceSessionRequest,
        geometry: LumenMacDisplayGeometry
    ) async throws -> UInt32 {
        if isDesktopMirror {
            // CGVirtualDisplay mode mutation can remove an otherwise retained
            // display from ScreenCaptureKit. Restore the physical source, then
            // replace the owned display and admit that fresh identity before
            // committing the mirror topology.
            try await executor.stageOwnedVirtualDisplayUnmirrored()
            let replacementDisplayID = try await executor
                .replaceOwnedVirtualDisplay(
                    geometry: geometry,
                    refreshRate: request.refreshRate
                )
            try await executor.prepareOwnedVirtualDisplayForReconfiguration()
            try await executor.mirrorOwnedVirtualDisplay()
            return replacementDisplayID
        }
        let displayID = try await executor.activeVirtualDisplayID()
        try await executor.reconfigureOwnedVirtualDisplay(
            geometry: geometry,
            refreshRate: request.refreshRate
        )
        try await executor.settleOwnedVirtualDisplayMode()
        try await executor.stabilizeOwnedVirtualDisplay()
        try await executor.prepareOwnedVirtualDisplayForCapture()
        return displayID
    }
}
