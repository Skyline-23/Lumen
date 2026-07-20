import CoreGraphics
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
    case isolationCommandMissing
}

public struct LumenMacWorkspaceActivationOutcome: Equatable, Sendable {
    public let isolationStatus: LumenMacWorkspaceIsolationStatus

    public init(isolationStatus: LumenMacWorkspaceIsolationStatus) {
        self.isolationStatus = isolationStatus
    }
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
    ) async throws -> UInt32 {
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

    func destroy(identity: LumenMacVirtualDisplayIdentity) async throws {
        if let displayKey, displayKey != identity.id {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        if let display {
            await LumenScreenCaptureDisplayPrefetch.discard(displayID: display.displayID)
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
    private static let isolationCaptureContinuityTimeoutNanoseconds: UInt64 = 2_000_000_000
    private static let promotionRetryNanoseconds: UInt64 = 50_000_000
    private static let promotionRetryCount = 20
    private let request: LumenMacWorkspaceSessionRequest
    private let coordinator: LumenWorkspaceCoordinator
    private let executor: LumenMacWorkspaceExecutor
    private let isolationStatusHandler: @Sendable (LumenMacWorkspaceIsolationStatus) async -> Void
    private var phase = Phase.idle
    private var activationCommand: LumenMacWorkspaceCommand?
    private var isolationTask: Task<Void, Never>?

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
                    timeoutNanoseconds: Self.isolationCaptureContinuityTimeoutNanoseconds
                )
            },
            positionPointer: { displayID, geometry in
                LumenMacPointerPositioner.centerPointer(
                    on: displayID,
                    geometry: geometry
                )
            }
        )
        try self.init(
            request: request,
            operations: operations,
            displayWorkspace: displayWorkspace,
            isolationStatusHandler: { status in
                LumenMacWorkspaceIsolationRuntimeEventPublisher.publish(status)
            }
        )
    }

    init(
        request: LumenMacWorkspaceSessionRequest,
        operations: LumenMacWorkspaceNativeOperations,
        displayWorkspace: any LumenMacDisplayWorkspaceManaging,
        coordinator: LumenWorkspaceCoordinator? = nil,
        isolationStatusHandler: @escaping @Sendable (
            LumenMacWorkspaceIsolationStatus
        ) async -> Void = { _ in }
    ) throws {
        self.request = request
        self.coordinator = try coordinator ?? LumenWorkspaceCoordinator()
        self.isolationStatusHandler = isolationStatusHandler
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
                do {
                    if command.action == .applyIsolation ||
                        command.action == .startCapture ||
                        command.action == .awaitExternalFirstEncodedFrame {
                        try await executor.verifyOwnedVirtualDisplay()
                    }
                    if command.action == .awaitExternalFirstEncodedFrame {
                        activationCommand = command
                        phase = .prepared
                        return
                    }
                } catch {
                    _ = try? await coordinator.complete(command, result: .failed)
                    throw error
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

    @discardableResult
    public func activate() async throws -> LumenMacWorkspaceActivationOutcome {
        if phase == .active {
            return LumenMacWorkspaceActivationOutcome(
                isolationStatus: isolationTask == nil
                    ? await executor.physicalIsolationStatus()
                    : .pending
            )
        }
        guard phase == .prepared, let activationCommand else {
            throw LumenMacWorkspaceSessionError.sessionNotStarted
        }
        do {
            let result = try await executor.execute(activationCommand)
            try await coordinator.complete(activationCommand, result: result)
            await promoteVirtualDisplayAfterCaptureReadiness()
            await executor.positionPointerOnVirtualDisplay()
            self.activationCommand = nil
            phase = .active
            if request.policy == .isolatedWorkspace {
                isolationTask = Task { [weak self] in
                    await self?.completeDeferredIsolation()
                }
                return LumenMacWorkspaceActivationOutcome(isolationStatus: .pending)
            }
            return LumenMacWorkspaceActivationOutcome(isolationStatus: .notRequested)
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
        if let isolationTask {
            await isolationTask.value
            self.isolationTask = nil
        }
        guard phase != .idle else {
            return
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
            await isolationStatusHandler(.notRequested)
            return
        }
        try await coordinator.endSession()
        let cleanupError = try await coordinator.executePendingCommandsRecovering(using: executor)
        phase = .idle
        if let cleanupError {
            throw cleanupError
        }
        await isolationStatusHandler(.notRequested)
    }

    public func state() async throws -> LumenMacWorkspaceState {
        try await coordinator.currentState()
    }

    public func displayID() async throws -> UInt32 {
        try await executor.activeVirtualDisplayID()
    }

    private func completeDeferredIsolation() async {
        var isolationCommand: LumenMacWorkspaceCommand?
        do {
            guard let command = try await coordinator.nextCommand(),
                  command.action == .applyIsolation else {
                throw LumenMacWorkspaceSessionError.isolationCommandMissing
            }
            isolationCommand = command
            try await executor.verifyOwnedVirtualDisplay()
            let result = try await executor.execute(command)
            await executor.positionPointerOnVirtualDisplay()
            try await executor.verifyOwnedCaptureContinuity()
            try await coordinator.complete(command, result: result)
            isolationCommand = nil
            try await coordinator.executePendingCommands(using: executor)
            await isolationStatusHandler(await executor.physicalIsolationStatus())
        } catch {
            let isolationError = error
            if let isolationCommand {
                _ = try? await coordinator.complete(isolationCommand, result: .failed)
            }
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
            let failures = [isolationError, cleanupError, ownershipCleanupError]
                .compactMap { $0 }
                .map { String(describing: $0) }
                .joined(separator: "; ")
            await isolationStatusHandler(.failed(message: failures))
        }
        isolationTask = nil
    }

    private func promoteVirtualDisplayAfterCaptureReadiness() async {
        for attempt in 0..<Self.promotionRetryCount {
            do {
                if try await executor.promoteOwnedVirtualDisplay() {
                    return
                }
            } catch {
                FileHandle.standardError.write(
                    Data("Lumen virtual display promotion failed: \(error)\n".utf8)
                )
                return
            }
            guard attempt + 1 < Self.promotionRetryCount else {
                break
            }
            try? await Task.sleep(nanoseconds: Self.promotionRetryNanoseconds)
        }
        FileHandle.standardError.write(
            Data("Lumen virtual display promotion deferred after capture readiness\n".utf8)
        )
    }

}

enum LumenMacPointerPositioner {
    static func centerPoint(geometry: LumenMacDisplayGeometry) -> CGPoint {
        CGPoint(
            x: CGFloat(geometry.logicalWidth) / 2,
            y: CGFloat(geometry.logicalHeight) / 2
        )
    }

    static func centerPointer(
        on displayID: CGDirectDisplayID,
        geometry: LumenMacDisplayGeometry
    ) {
        let result = CGDisplayMoveCursorToPoint(displayID, centerPoint(geometry: geometry))
        guard result != .success else {
            return
        }
        FileHandle.standardError.write(
            Data(
                (
                    "Lumen pointer initialization failed " +
                        "display-id=\(displayID) status=\(result.rawValue)\n"
                ).utf8
            )
        )
    }
}

private enum LumenMacWorkspaceIsolationRuntimeEventPublisher {
    private static let notification = Notification.Name("LumenRuntimeEventNotification")
    private static let isolationWarningCode = 13

    static func publish(_ status: LumenMacWorkspaceIsolationStatus) {
        let disposition: Int
        let severity: Int
        let code: Int
        let body: String
        switch status {
        case .notRequested, .applied:
            disposition = 1
            severity = 0
            code = isolationWarningCode
            body = ""
        case .pending:
            return
        case .unavailable(let message):
            disposition = 0
            severity = 0
            code = isolationWarningCode
            body = message
        case .failed(let message):
            disposition = 0
            severity = 1
            code = 6
            body = message
        }
        DistributedNotificationCenter.default().postNotificationName(
            notification,
            object: nil,
            userInfo: [
                "identifier": "runtime-event-\(code)",
                "disposition": disposition,
                "severity": severity,
                "code": code,
                "body": body,
                "launchPath": "/diagnostics",
            ],
            deliverImmediately: true
        )
    }
}
