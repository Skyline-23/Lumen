import CoreGraphics

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
    public var settleVirtualDisplayMode: @Sendable (UInt32) async throws -> Void
    public var stabilizeVirtualDisplay: @Sendable (UInt32) async throws -> Void
    public var prepareCaptureDisplay: @Sendable (UInt32) async throws -> Void
    public var startCapture: @Sendable (UInt32) async throws -> Void
    public var stopCapture: @Sendable () async throws -> Void
    public var destroyVirtualDisplay: @Sendable (LumenMacVirtualDisplayIdentity) async throws -> Void
    public var waitForExternalFirstEncodedFrame: @Sendable () async throws -> Void
    public var verifyCaptureContinuity: @Sendable () async throws -> Void
    public var positionPointer: @Sendable (
        UInt32,
        LumenMacDisplayGeometry
    ) async -> Void

    public init(
        createVirtualDisplay: @escaping @Sendable (
            LumenMacVirtualDisplayIdentity,
            LumenMacDisplayGeometry
        ) async throws -> UInt32,
        configureVirtualDisplay: @escaping @Sendable (UInt32, LumenMacDisplayGeometry) async throws -> Void,
        verifyVirtualDisplay: @escaping @Sendable (UInt32) async throws -> Void,
        settleVirtualDisplayMode: @escaping @Sendable (UInt32) async throws -> Void = { _ in },
        stabilizeVirtualDisplay: @escaping @Sendable (UInt32) async throws -> Void = { _ in },
        prepareCaptureDisplay: @escaping @Sendable (UInt32) async throws -> Void = { _ in },
        startCapture: @escaping @Sendable (UInt32) async throws -> Void,
        stopCapture: @escaping @Sendable () async throws -> Void,
        destroyVirtualDisplay: @escaping @Sendable (
            LumenMacVirtualDisplayIdentity
        ) async throws -> Void,
        waitForExternalFirstEncodedFrame: @escaping @Sendable () async throws -> Void = {},
        verifyCaptureContinuity: @escaping @Sendable () async throws -> Void = {},
        positionPointer: @escaping @Sendable (
            UInt32,
            LumenMacDisplayGeometry
        ) async -> Void = { _, _ in }
    ) {
        self.createVirtualDisplay = createVirtualDisplay
        self.configureVirtualDisplay = configureVirtualDisplay
        self.verifyVirtualDisplay = verifyVirtualDisplay
        self.settleVirtualDisplayMode = settleVirtualDisplayMode
        self.stabilizeVirtualDisplay = stabilizeVirtualDisplay
        self.prepareCaptureDisplay = prepareCaptureDisplay
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.destroyVirtualDisplay = destroyVirtualDisplay
        self.waitForExternalFirstEncodedFrame = waitForExternalFirstEncodedFrame
        self.verifyCaptureContinuity = verifyCaptureContinuity
        self.positionPointer = positionPointer
    }
}

public enum LumenMacWorkspaceExecutorError: Error, Equatable {
    case virtualDisplayMissing
    case commandPayloadMismatch
}

public enum LumenMacWorkspaceIsolationStatus: Equatable, Sendable {
    case notRequested
    case pending
    case applied
    case unavailable(message: String)
    case failed(message: String)
}

public actor LumenMacWorkspaceExecutor: LumenWorkspaceCommandExecuting {
    private let displayWorkspace: any LumenMacDisplayWorkspaceManaging
    private let contentSource: LumenMacWorkspaceContentSource
    private let targetProcessIdentifiers: [Int32]
    private let operations: LumenMacWorkspaceNativeOperations
    private let displayGeometry: LumenMacDisplayGeometry
    private var virtualDisplayID: UInt32?
    private var virtualDisplayIdentity: LumenMacVirtualDisplayIdentity?
    private var isolationStatus = LumenMacWorkspaceIsolationStatus.notRequested

    public init(
        targetProcessIdentifiers: [Int32],
        contentSource: LumenMacWorkspaceContentSource = .targetWindows,
        displayMode: LumenMacDisplayModeRequest,
        operations: LumenMacWorkspaceNativeOperations,
        displayWorkspace: any LumenMacDisplayWorkspaceManaging
    ) throws {
        self.targetProcessIdentifiers = targetProcessIdentifiers
        self.contentSource = contentSource
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
            let displayID = try requireVirtualDisplay()
            try await operations.verifyVirtualDisplay(displayID)
            guard try await displayWorkspace.promoteVirtualDisplay(
                displayID,
                logicalSize: CGSize(
                    width: CGFloat(displayGeometry.logicalWidth),
                    height: CGFloat(displayGeometry.logicalHeight)
                ),
                convergence: .deferredUntilCaptureReady
            ) else {
                throw LumenMacDisplayWorkspaceError.virtualDisplayPromotionUnavailable(displayID)
            }
            return .succeeded
        case .moveTargetWindows:
            try await displayWorkspace.moveTargetWindows(to: try requireVirtualDisplay())
            return .succeeded
        case .applyIsolation:
            do {
                try await displayWorkspace.isolateVirtualDisplay(try requireVirtualDisplay())
                isolationStatus = .applied
                return .physicalMutationApplied(true)
            } catch LumenMacDisplayWorkspaceError.isolationUnavailable(let message) {
                isolationStatus = .unavailable(message: message)
                return .physicalMutationApplied(false)
            }
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

    public func prepareOwnedVirtualDisplayForCapture() async throws {
        try await operations.prepareCaptureDisplay(try requireVirtualDisplay())
    }

    public func stabilizeOwnedVirtualDisplay() async throws {
        try await operations.stabilizeVirtualDisplay(try requireVirtualDisplay())
    }

    public func settleOwnedVirtualDisplayMode() async throws {
        try await operations.settleVirtualDisplayMode(try requireVirtualDisplay())
    }

    public func stageOwnedVirtualDisplayUnmirrored() async throws {
        guard case .desktopMirror(let sourceDisplayID) = contentSource else {
            return
        }
        let displayID = try requireVirtualDisplay()
        try await operations.verifyVirtualDisplay(displayID)
        try await displayWorkspace.stageVirtualDisplayUnmirrored(
            displayID,
            sourceDisplayID: sourceDisplayID
        )
        try await operations.verifyVirtualDisplay(displayID)
    }

    public func verifyOwnedCaptureContinuity() async throws {
        try await operations.verifyCaptureContinuity()
    }

    public func positionPointerOnSessionDisplay() async {
        guard let virtualDisplayID else {
            return
        }
        await operations.positionPointer(virtualDisplayID, displayGeometry)
    }

    @discardableResult
    public func promoteOwnedVirtualDisplay() async throws -> Bool {
        let displayID = try requireVirtualDisplay()
        try await operations.verifyVirtualDisplay(displayID)
        return try await displayWorkspace.promoteVirtualDisplay(
            displayID,
            logicalSize: CGSize(
                width: CGFloat(displayGeometry.logicalWidth),
                height: CGFloat(displayGeometry.logicalHeight)
            ),
            convergence: .required
        )
    }

    public func mirrorOwnedVirtualDisplay() async throws {
        guard case .desktopMirror(let sourceDisplayID) = contentSource else {
            return
        }
        let displayID = try requireVirtualDisplay()
        try await operations.verifyVirtualDisplay(displayID)
        try await displayWorkspace.mirrorOwnedVirtualDisplay(
            displayID,
            sourceDisplayID: sourceDisplayID
        )
        try await operations.verifyVirtualDisplay(displayID)
    }

    public func destroyOwnedVirtualDisplay() async throws {
        guard let virtualDisplayIdentity else {
            return
        }
        try await operations.destroyVirtualDisplay(virtualDisplayIdentity)
        virtualDisplayID = nil
        self.virtualDisplayIdentity = nil
    }

    public func physicalIsolationStatus() -> LumenMacWorkspaceIsolationStatus {
        isolationStatus
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
