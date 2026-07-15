public protocol LumenWorkspaceCommandExecuting: Sendable {
    func execute(_ command: LumenMacWorkspaceCommand) async throws
}

public extension LumenWorkspaceCoordinator {
    func executePendingCommands(
        using executor: any LumenWorkspaceCommandExecuting
    ) async throws {
        while let command = try nextCommand() {
            do {
                try await executor.execute(command)
                try complete(command, succeeded: true)
            } catch {
                try? complete(command, succeeded: false)
                throw error
            }
        }
    }

    func executePendingCommandsRecovering(
        using executor: any LumenWorkspaceCommandExecuting
    ) async throws -> (any Error)? {
        var firstExecutionError: (any Error)?
        while let command = try nextCommand() {
            do {
                try await executor.execute(command)
                try complete(command, succeeded: true)
            } catch {
                if firstExecutionError == nil {
                    firstExecutionError = error
                }
                _ = try? complete(command, succeeded: false)
            }
        }
        return firstExecutionError
    }
}

public struct LumenMacWorkspaceNativeOperations: Sendable {
    public var createVirtualDisplay: @Sendable (LumenMacDisplayGeometry) async throws -> UInt32
    public var configureVirtualDisplay: @Sendable (UInt32, LumenMacDisplayGeometry) async throws -> Void
    public var startCapture: @Sendable (UInt32) async throws -> Void
    public var stopCapture: @Sendable () async throws -> Void
    public var destroyVirtualDisplay: @Sendable (UInt32) async throws -> Void

    public init(
        createVirtualDisplay: @escaping @Sendable (LumenMacDisplayGeometry) async throws -> UInt32,
        configureVirtualDisplay: @escaping @Sendable (UInt32, LumenMacDisplayGeometry) async throws -> Void,
        startCapture: @escaping @Sendable (UInt32) async throws -> Void,
        stopCapture: @escaping @Sendable () async throws -> Void,
        destroyVirtualDisplay: @escaping @Sendable (UInt32) async throws -> Void
    ) {
        self.createVirtualDisplay = createVirtualDisplay
        self.configureVirtualDisplay = configureVirtualDisplay
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.destroyVirtualDisplay = destroyVirtualDisplay
    }
}

public enum LumenMacWorkspaceExecutorError: Error, Equatable {
    case virtualDisplayMissing
}

public actor LumenMacWorkspaceExecutor: LumenWorkspaceCommandExecuting {
    private let displayWorkspace: any LumenMacDisplayWorkspaceManaging
    private let targetProcessIdentifiers: [Int32]
    private let operations: LumenMacWorkspaceNativeOperations
    private let displayGeometry: LumenMacDisplayGeometry
    private var virtualDisplayID: UInt32?

    public init(
        targetProcessIdentifiers: [Int32],
        displayMode: LumenMacDisplayModeRequest,
        operations: LumenMacWorkspaceNativeOperations,
        displayWorkspace: any LumenMacDisplayWorkspaceManaging
    ) throws {
        self.targetProcessIdentifiers = targetProcessIdentifiers
        self.operations = operations
        self.displayWorkspace = displayWorkspace
        displayGeometry = try LumenMacDisplayGeometryResolver.resolve(displayMode)
    }

    public func execute(_ command: LumenMacWorkspaceCommand) async throws {
        switch command.action {
        case .snapshotWorkspace:
            try await displayWorkspace.snapshotWorkspace(
                targetProcessIdentifiers: targetProcessIdentifiers
            )
        case .createVirtualDisplay:
            virtualDisplayID = try await operations.createVirtualDisplay(displayGeometry)
        case .configureVirtualDisplay:
            try await operations.configureVirtualDisplay(
                try requireVirtualDisplay(),
                displayGeometry
            )
        case .promoteVirtualMain:
            try await displayWorkspace.promoteVirtualDisplay(try requireVirtualDisplay())
        case .moveTargetWindows:
            try await displayWorkspace.moveTargetWindows(to: try requireVirtualDisplay())
        case .applyIsolation:
            try await displayWorkspace.isolateVirtualDisplay(try requireVirtualDisplay())
        case .startCapture:
            try await operations.startCapture(try requireVirtualDisplay())
        case .stopCapture:
            try await operations.stopCapture()
        case .restoreWorkspace:
            try await displayWorkspace.restoreWorkspace()
        case .destroyVirtualDisplay:
            let displayID = try requireVirtualDisplay()
            try await operations.destroyVirtualDisplay(displayID)
            virtualDisplayID = nil
        }
    }

    public func activeVirtualDisplayID() throws -> UInt32 {
        try requireVirtualDisplay()
    }

    private func requireVirtualDisplay() throws -> UInt32 {
        guard let virtualDisplayID else {
            throw LumenMacWorkspaceExecutorError.virtualDisplayMissing
        }
        return virtualDisplayID
    }
}
