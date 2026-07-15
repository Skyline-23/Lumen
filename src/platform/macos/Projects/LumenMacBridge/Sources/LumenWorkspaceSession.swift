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
            forKey: request.displayKey,
            configuration: configuration
        )
        self.display = display
        displayKey = request.displayKey
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

    func destroy(displayID: UInt32) throws {
        guard let display, display.displayID == displayID else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        guard let displayKey,
              LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: displayKey) else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        self.display = nil
        self.displayKey = nil
    }
}

public actor LumenMacWorkspaceSession {
    private let request: LumenMacWorkspaceSessionRequest
    private let coordinator: LumenWorkspaceCoordinator
    private let executor: LumenMacWorkspaceExecutor
    private var started = false

    public init(
        request: LumenMacWorkspaceSessionRequest,
        runtime: LumenBridgeRuntime,
        displayWorkspace: any LumenMacDisplayWorkspaceManaging
    ) throws {
        let displayOwner = LumenMacVirtualDisplayOwner()
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { geometry in
                try await displayOwner.create(geometry: geometry, request: request)
            },
            configureVirtualDisplay: { displayID, geometry in
                try await displayOwner.configure(
                    displayID: displayID,
                    geometry: geometry,
                    refreshRate: request.refreshRate
                )
            },
            startCapture: { displayID in
                try await runtime.startCapture(
                    configuration: request.captureConfiguration.replacingDisplayID(displayID)
                )
            },
            stopCapture: {
                await runtime.stopCapture()
            },
            destroyVirtualDisplay: { displayID in
                try await displayOwner.destroy(displayID: displayID)
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
        displayWorkspace: any LumenMacDisplayWorkspaceManaging
    ) throws {
        self.request = request
        coordinator = try LumenWorkspaceCoordinator()
        executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: request.targetProcessIdentifiers,
            displayMode: request.displayMode,
            operations: operations,
            displayWorkspace: displayWorkspace
        )
    }

    public func start() async throws {
        guard !started else {
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
            try await coordinator.executePendingCommands(using: executor)
            started = true
        } catch {
            _ = try? await coordinator.executePendingCommandsRecovering(using: executor)
            throw error
        }
    }

    public func stop() async throws {
        guard started else {
            throw LumenMacWorkspaceSessionError.sessionNotStarted
        }
        try await coordinator.endSession()
        let cleanupError = try await coordinator.executePendingCommandsRecovering(using: executor)
        started = false
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
