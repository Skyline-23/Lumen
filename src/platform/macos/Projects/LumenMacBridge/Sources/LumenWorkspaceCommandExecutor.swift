public protocol LumenWorkspaceCommandExecuting: Sendable {
    func execute(_ command: LumenMacWorkspaceCommand) async throws -> LumenMacWorkspaceCommandResult
}

public extension LumenWorkspaceCoordinator {
    func executePendingCommands(
        using executor: any LumenWorkspaceCommandExecuting
    ) async throws {
        while let command = try nextCommand() {
            do {
                let result = try await executor.execute(command)
                try complete(command, result: result)
            } catch {
                try? complete(command, result: .failed)
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
                let result = try await executor.execute(command)
                try complete(command, result: result)
            } catch {
                if firstExecutionError == nil {
                    firstExecutionError = error
                }
                _ = try? complete(command, result: .failed)
            }
        }
        return firstExecutionError
    }
}

public struct LumenMacWorkspaceNativeOperations: Sendable {
    public var createVirtualDisplay: @Sendable (
        LumenMacVirtualDisplayIdentity,
        LumenMacDisplayGeometry
    ) async throws -> UInt32
    public var configureVirtualDisplay: @Sendable (UInt32, LumenMacDisplayGeometry) async throws -> Void
    public var verifyVirtualDisplay: @Sendable (UInt32) async throws -> Void
    public var startCapture: @Sendable (UInt32) async throws -> Void
    public var stopCapture: @Sendable () async throws -> Void
    public var destroyVirtualDisplay: @Sendable (LumenMacVirtualDisplayIdentity) async throws -> Void
    public var waitForExternalFirstEncodedFrame: @Sendable () async throws -> Void
    public var verifyCaptureContinuity: @Sendable () async throws -> Void

    public init(
        createVirtualDisplay: @escaping @Sendable (
            LumenMacVirtualDisplayIdentity,
            LumenMacDisplayGeometry
        ) async throws -> UInt32,
        configureVirtualDisplay: @escaping @Sendable (UInt32, LumenMacDisplayGeometry) async throws -> Void,
        verifyVirtualDisplay: @escaping @Sendable (UInt32) async throws -> Void,
        startCapture: @escaping @Sendable (UInt32) async throws -> Void,
        stopCapture: @escaping @Sendable () async throws -> Void,
        destroyVirtualDisplay: @escaping @Sendable (
            LumenMacVirtualDisplayIdentity
        ) async throws -> Void,
        waitForExternalFirstEncodedFrame: @escaping @Sendable () async throws -> Void = {},
        verifyCaptureContinuity: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.createVirtualDisplay = createVirtualDisplay
        self.configureVirtualDisplay = configureVirtualDisplay
        self.verifyVirtualDisplay = verifyVirtualDisplay
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.destroyVirtualDisplay = destroyVirtualDisplay
        self.waitForExternalFirstEncodedFrame = waitForExternalFirstEncodedFrame
        self.verifyCaptureContinuity = verifyCaptureContinuity
    }
}

public enum LumenMacWorkspaceExecutorError: Error, Equatable {
    case virtualDisplayMissing
    case commandPayloadMismatch
}

public actor LumenMacWorkspaceExecutor: LumenWorkspaceCommandExecuting {
    private let displayWorkspace: any LumenMacDisplayWorkspaceManaging
    private let targetProcessIdentifiers: [Int32]
    private let operations: LumenMacWorkspaceNativeOperations
    private let displayGeometry: LumenMacDisplayGeometry
    private var virtualDisplayID: UInt32?
    private var virtualDisplayIdentity: LumenMacVirtualDisplayIdentity?

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

    public func execute(
        _ command: LumenMacWorkspaceCommand
    ) async throws -> LumenMacWorkspaceCommandResult {
        switch command.action {
        case .snapshotWorkspace:
            return .physicalTopology(
                try await displayWorkspace.snapshotWorkspace(
                    targetProcessIdentifiers: targetProcessIdentifiers
                )
            )
        case .createVirtualDisplay:
            let identity = try requireVirtualIdentity(command.payload)
            virtualDisplayID = try await operations.createVirtualDisplay(identity, displayGeometry)
            virtualDisplayIdentity = identity
            return .virtualDisplayIdentity(identity)
        case .configureVirtualDisplay:
            try await operations.configureVirtualDisplay(
                try requireVirtualDisplay(),
                displayGeometry
            )
            return .succeeded
        case .promoteVirtualMain:
            try await displayWorkspace.promoteVirtualDisplay(try requireVirtualDisplay())
            return .succeeded
        case .moveTargetWindows:
            try await displayWorkspace.moveTargetWindows(to: try requireVirtualDisplay())
            return .succeeded
        case .applyIsolation:
            try await displayWorkspace.isolateVirtualDisplay(try requireVirtualDisplay())
            try await operations.verifyCaptureContinuity()
            return .succeeded
        case .awaitExternalFirstEncodedFrame:
            try await operations.waitForExternalFirstEncodedFrame()
            return .succeeded
        case .startCapture:
            try await operations.startCapture(try requireVirtualDisplay())
            return .succeeded
        case .stopCapture:
            try await operations.stopCapture()
            return .succeeded
        case .restoreWorkspace:
            try await displayWorkspace.restoreWorkspace(
                try requirePhysicalTopology(command.payload)
            )
            return .succeeded
        case .verifyPhysicalDisplays:
            try await displayWorkspace.verifyWorkspace(
                try requirePhysicalTopology(command.payload)
            )
            return .succeeded
        case .destroyVirtualDisplay:
            try await operations.destroyVirtualDisplay(
                try requireVirtualIdentity(command.payload)
            )
            virtualDisplayID = nil
            virtualDisplayIdentity = nil
            return .succeeded
        }
    }

    public func activeVirtualDisplayID() throws -> UInt32 {
        try requireVirtualDisplay()
    }

    public func verifyOwnedVirtualDisplay() async throws {
        try await operations.verifyVirtualDisplay(try requireVirtualDisplay())
    }

    public func destroyOwnedVirtualDisplay() async throws {
        guard let virtualDisplayIdentity else {
            return
        }
        try await operations.destroyVirtualDisplay(virtualDisplayIdentity)
        virtualDisplayID = nil
        self.virtualDisplayIdentity = nil
    }

    private func requireVirtualDisplay() throws -> UInt32 {
        guard let virtualDisplayID else {
            throw LumenMacWorkspaceExecutorError.virtualDisplayMissing
        }
        return virtualDisplayID
    }

    private func requirePhysicalTopology(
        _ payload: LumenMacWorkspaceCommandPayload
    ) throws -> LumenMacPhysicalDisplayTopology {
        guard case .physicalTopology(let topology) = payload else {
            throw LumenMacWorkspaceExecutorError.commandPayloadMismatch
        }
        return topology
    }

    private func requireVirtualIdentity(
        _ payload: LumenMacWorkspaceCommandPayload
    ) throws -> LumenMacVirtualDisplayIdentity {
        guard case .virtualDisplayIdentity(let identity) = payload else {
            throw LumenMacWorkspaceExecutorError.commandPayloadMismatch
        }
        return identity
    }
}
