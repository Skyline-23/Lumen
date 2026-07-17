import Foundation

public struct LumenMacWorkspaceSessionRequest: Sendable {
    public let displayKey: String
    public let policy: LumenMacWorkspacePolicy
    public let targetProcessIdentifiers: [Int32]
    public let displayMode: LumenMacDisplayModeRequest
    public let displayName: String
    public let refreshRate: Double
    public let managesCapture: Bool
    public let captureConfiguration: LumenMacCaptureConfiguration

    public init(
        displayKey: String = UUID().uuidString,
        policy: LumenMacWorkspacePolicy = .coexist,
        targetProcessIdentifiers: [Int32] = [],
        displayMode: LumenMacDisplayModeRequest,
        displayName: String = "Lumen Display",
        refreshRate: Double = 120,
        managesCapture: Bool = true,
        captureConfiguration: LumenMacCaptureConfiguration
    ) {
        self.displayKey = displayKey
        self.policy = policy
        self.targetProcessIdentifiers = targetProcessIdentifiers
        self.displayMode = displayMode
        self.displayName = displayName
        self.refreshRate = max(refreshRate, 1)
        self.managesCapture = managesCapture
        self.captureConfiguration = captureConfiguration
    }
}

public enum LumenMacWorkspaceSessionError: Error, Equatable {
    case sessionAlreadyStarted
    case sessionNotStarted
    case recoveryDidNotComplete
    case virtualDisplayOwnershipMismatch
}

public enum LumenMacVirtualDisplayConfigurationFactory {
    public static func make(
        geometry: LumenMacDisplayGeometry,
        request: LumenMacWorkspaceSessionRequest
    ) throws -> LumenMacVirtualDisplayConfiguration {
        let colorProfile = try LumenMacDisplayColorResolver.resolve(
            hdrEnabled: request.captureConfiguration.usesHDRTransport,
            clientGamut: protocolRawGamut(request.captureConfiguration.virtualDisplayGamut),
            clientTransfer: protocolRawTransfer(request.captureConfiguration.virtualDisplayTransfer)
        )
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = request.displayName
        configuration.backingWidth = geometry.backingWidth
        configuration.backingHeight = geometry.backingHeight
        configuration.logicalWidth = geometry.logicalWidth
        configuration.logicalHeight = geometry.logicalHeight
        configuration.refreshRate = request.refreshRate
        configuration.highDensity = geometry.backingWidth != geometry.logicalWidth ||
            geometry.backingHeight != geometry.logicalHeight
        configuration.hdrEnabled = request.captureConfiguration.usesHDRTransport
        configuration.gamut = LumenMacVirtualDisplayGamut(
            rawValue: Int(colorProfile.gamutRawValue)
        )!
        configuration.transfer = LumenMacVirtualDisplayTransfer(
            rawValue: Int(colorProfile.transferRawValue)
        )!

        let capability = request.captureConfiguration.sinkRequest.capability
        configuration.currentEDRHeadroom = Double(capability.currentEDRHeadroom)
        configuration.potentialEDRHeadroom = Double(capability.potentialEDRHeadroom)
        configuration.currentPeakLuminanceNits = Double(capability.currentPeakLuminanceNits)
        configuration.potentialPeakLuminanceNits = Double(capability.potentialPeakLuminanceNits)
        return configuration
    }

    private static func protocolRawGamut(_ gamut: LumenClientSinkGamut) -> Int32 {
        switch gamut {
        case .displayP3:
            return 2
        case .rec2020:
            return 3
        case .srgb, .unknown:
            return gamut == .srgb ? 1 : 0
        }
    }

    private static func protocolRawTransfer(
        _ transfer: LumenClientSinkTransfer
    ) -> Int32 {
        switch transfer {
        case .pq:
            return 2
        case .hlg:
            return 3
        case .sdr, .unknown:
            return transfer == .sdr ? 1 : 0
        }
    }
}

private actor LumenMacVirtualDisplayOwner {
    private var display: LumenMacVirtualDisplay?
    private var displayKey: String?

    func create(
        identity: LumenMacVirtualDisplayIdentity,
        geometry: LumenMacDisplayGeometry,
        request: LumenMacWorkspaceSessionRequest
    ) throws -> UInt32 {
        guard display == nil else {
            throw LumenMacWorkspaceSessionError.sessionAlreadyStarted
        }
        let configuration = try LumenMacVirtualDisplayConfigurationFactory.make(
            geometry: geometry,
            request: request
        )
        let display = try LumenMacVirtualDisplay.createRegisteredDisplay(
            forKey: identity.id,
            configuration: configuration
        )
        self.display = display
        displayKey = identity.id
        return display.displayID
    }

    func configure(
        displayID: UInt32,
        geometry: LumenMacDisplayGeometry,
        refreshRate: Double
    ) throws {
        guard let display, display.displayID == displayID else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        try display.updateLogicalWidth(
            geometry.logicalWidth,
            logicalHeight: geometry.logicalHeight,
            refreshRate: refreshRate
        )
    }

    func verify(displayID: UInt32) throws {
        guard let display,
              display.displayID == displayID,
              LumenMacVirtualDisplay.registeredDisplay(forDisplayID: displayID) === display else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
    }

    func destroy(identity: LumenMacVirtualDisplayIdentity) throws {
        if let displayKey, displayKey != identity.id {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        _ = LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: identity.id)
        self.display = nil
        self.displayKey = nil
    }
}

public actor LumenMacWorkspaceSession {
    private enum Phase {
        case idle
        case prepared
        case active
    }

    private static let firstEncodedFrameTimeoutNanoseconds: UInt64 = 5_000_000_000
    private let request: LumenMacWorkspaceSessionRequest
    private let coordinator: LumenWorkspaceCoordinator
    private let executor: LumenMacWorkspaceExecutor
    private var phase = Phase.idle
    private var activationCommand: LumenMacWorkspaceCommand?

    public init(
        request: LumenMacWorkspaceSessionRequest,
        runtime: LumenBridgeRuntime,
        displayWorkspace: any LumenMacDisplayWorkspaceManaging
    ) throws {
        let displayOwner = LumenMacVirtualDisplayOwner()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { identity, geometry in
                try await displayOwner.create(
                    identity: identity,
                    geometry: geometry,
                    request: request
                )
            },
            configureVirtualDisplay: { displayID, geometry in
                try await displayOwner.configure(
                    displayID: displayID,
                    geometry: geometry,
                    refreshRate: request.refreshRate
                )
            },
            verifyVirtualDisplay: { displayID in
                try await displayOwner.verify(displayID: displayID)
            },
            startCapture: { displayID in
                try await runtime.startCapture(
                    configuration: request.captureConfiguration.replacingDisplayID(displayID)
                )
                try await runtime.waitForFirstEncodedFrame(
                    timeoutNanoseconds: Self.firstEncodedFrameTimeoutNanoseconds
                )
            },
            stopCapture: {
                await runtime.stopCapture()
            },
            destroyVirtualDisplay: { identity in
                try await displayOwner.destroy(identity: identity)
            },
            waitForExternalFirstEncodedFrame: {
                try await runtime.waitForFirstEncodedFrame(
                    timeoutNanoseconds: Self.firstEncodedFrameTimeoutNanoseconds
                )
            },
            verifyCaptureContinuity: {
                try await runtime.verifyEncodedFrameContinuity(
                    timeoutNanoseconds: Self.firstEncodedFrameTimeoutNanoseconds
                )
            }
        )
        try self.init(
            request: request,
            operations: operations,
            displayWorkspace: displayWorkspace
        )
    }

    init(
        request: LumenMacWorkspaceSessionRequest,
        operations: LumenMacWorkspaceNativeOperations,
        displayWorkspace: any LumenMacDisplayWorkspaceManaging,
        coordinator: LumenWorkspaceCoordinator? = nil
    ) throws {
        self.request = request
        self.coordinator = try coordinator ?? LumenWorkspaceCoordinator()
        executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: request.targetProcessIdentifiers,
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
        guard phase == .idle else {
            throw LumenMacWorkspaceSessionError.sessionAlreadyStarted
        }

        let admitted = try await coordinator.beginSession(
            policy: request.policy,
            moveTargetWindows: !request.targetProcessIdentifiers.isEmpty,
            manageCapture: request.managesCapture
        )
        if !admitted {
            if let recoveryError = try await coordinator.executePendingCommandsRecovering(
                using: executor
            ) {
                throw recoveryError
            }
            let recoveredAdmission = try await coordinator.beginSession(
                policy: request.policy,
                moveTargetWindows: !request.targetProcessIdentifiers.isEmpty,
                manageCapture: request.managesCapture
            )
            guard recoveredAdmission else {
                throw LumenMacWorkspaceSessionError.recoveryDidNotComplete
            }
        }
        do {
            while let command = try await coordinator.nextCommand() {
                if command.action == .awaitExternalFirstEncodedFrame {
                    activationCommand = command
                    phase = .prepared
                    return
                }
                let result: LumenMacWorkspaceCommandResult
                do {
                    result = try await executor.execute(command)
                } catch {
                    _ = try? await coordinator.complete(command, result: .failed)
                    throw error
                }
                try await coordinator.complete(command, result: result)
            }
            phase = .active
        } catch {
            _ = try? await coordinator.executePendingCommandsRecovering(using: executor)
            phase = .idle
            throw error
        }
    }

    public func activate() async throws {
        if phase == .active {
            return
        }
        guard phase == .prepared, let activationCommand else {
            throw LumenMacWorkspaceSessionError.sessionNotStarted
        }
        do {
            try await executor.verifyOwnedVirtualDisplay()
            let result = try await executor.execute(activationCommand)
            try await coordinator.complete(activationCommand, result: result)
            self.activationCommand = nil
            try await coordinator.executePendingCommands(using: executor)
            phase = .active
        } catch {
            let activationError = error
            _ = try? await coordinator.complete(activationCommand, result: .failed)
            self.activationCommand = nil
            let cleanupError: (any Error)?
            do {
                cleanupError = try await coordinator.executePendingCommandsRecovering(
                    using: executor
                )
            } catch {
                cleanupError = error
            }
            let ownershipCleanupError: (any Error)?
            do {
                try await executor.destroyOwnedVirtualDisplay()
                ownershipCleanupError = nil
            } catch {
                ownershipCleanupError = error
            }
            phase = .idle
            if let ownershipCleanupError {
                throw ownershipCleanupError
            }
            if let cleanupError {
                throw cleanupError
            }
            throw activationError
        }
    }

    public func stop() async throws {
        guard phase != .idle else {
            throw LumenMacWorkspaceSessionError.sessionNotStarted
        }
        if let activationCommand {
            _ = try? await coordinator.complete(activationCommand, result: .failed)
            self.activationCommand = nil
            let cleanupError = try await coordinator.executePendingCommandsRecovering(
                using: executor
            )
            phase = .idle
            if let cleanupError {
                throw cleanupError
            }
            return
        }
        try await coordinator.endSession()
        let cleanupError = try await coordinator.executePendingCommandsRecovering(using: executor)
        phase = .idle
        if let cleanupError {
            throw cleanupError
        }
    }

    public func state() async throws -> LumenMacWorkspaceState {
        try await coordinator.currentState()
    }

    public func displayID() async throws -> UInt32 {
        try await executor.activeVirtualDisplayID()
    }
}
