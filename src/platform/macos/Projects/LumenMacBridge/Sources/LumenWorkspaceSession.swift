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
    let displayOwner: LumenMacVirtualDisplayOwner
    let preparationFence: @Sendable () async throws -> Void
    let isolationStatusHandler: @Sendable (LumenMacWorkspaceIsolationStatus) async -> Void
    var phase = Phase.idle
    var activationCommand: LumenMacWorkspaceCommand?
    var isolationTask: Task<Void, Never>?

    public init(
        request: LumenMacWorkspaceSessionRequest,
        runtime: LumenBridgeRuntime,
        displayWorkspace: any LumenMacDisplayWorkspaceManaging,
        preparationFence: @escaping @Sendable () async throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws {
        let displayOwner = LumenMacVirtualDisplayOwner(ownershipRegistry: .shared)
        let operations = LumenWorkspaceNativeOperationsFactory(
            request: request,
            runtime: runtime,
            displayOwner: displayOwner
        ).make()
        try self.init(
            request: request,
            runtime: runtime,
            displayOwner: displayOwner,
            operations: operations,
            displayWorkspace: displayWorkspace,
            preparationFence: preparationFence,
            isolationStatusHandler: { status in
                LumenWorkspaceEventPublisher.publish(status)
            }
        )
    }

    init(
        request: LumenMacWorkspaceSessionRequest,
        runtime: LumenBridgeRuntime = .shared,
        displayOwner: LumenMacVirtualDisplayOwner = .init(ownershipRegistry: .shared),
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
        self.displayOwner = displayOwner
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
        let previous = request
        let displayID = try await executor.activeVirtualDisplayID()
        let replacementGeometry = try LumenMacDisplayGeometryResolver.resolve(
            replacement.displayMode
        )
        do {
            try await applyDisplayMode(
                replacement,
                geometry: replacementGeometry,
                displayID: displayID
            )
            request = replacement
        } catch {
            let reconfigurationError = error
            if let previousGeometry = try? LumenMacDisplayGeometryResolver.resolve(
                previous.displayMode
            ) {
                try? await applyDisplayMode(
                    previous,
                    geometry: previousGeometry,
                    displayID: displayID
                )
            }
            throw reconfigurationError
        }
    }

    public func state() async throws -> LumenMacWorkspaceState {
        try await coordinator.currentState()
    }

    public func displayID() async throws -> UInt32 {
        try await executor.activeVirtualDisplayID()
    }

    private func applyDisplayMode(
        _ request: LumenMacWorkspaceSessionRequest,
        geometry: LumenMacDisplayGeometry,
        displayID: UInt32
    ) async throws {
        try await displayOwner.configure(
            displayID: displayID,
            geometry: geometry,
            refreshRate: request.refreshRate
        )
        try await displayOwner.settleMode(displayID: displayID)
        try await displayOwner.stabilize(displayID: displayID)
        try await displayOwner.awaitCapturePreparation(displayID: displayID)
    }
}
