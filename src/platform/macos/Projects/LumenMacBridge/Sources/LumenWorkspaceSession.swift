public actor LumenMacWorkspaceSession {
    enum Phase {
        case idle
        case prepared
        case active
        case recoveryPending
    }

    static let firstEncodedFrameTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let captureContinuityTimeoutNanoseconds: UInt64 = 2_000_000_000

    let request: LumenMacWorkspaceSessionRequest
    let coordinator: LumenWorkspaceCoordinator
    let executor: LumenMacWorkspaceExecutor
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

    public func state() async throws -> LumenMacWorkspaceState {
        try await coordinator.currentState()
    }

    public func displayID() async throws -> UInt32 {
        try await executor.activeVirtualDisplayID()
    }
}
