extension LumenMacWorkspaceSession {
    func activateImpl() async throws -> LumenMacWorkspaceActivationOutcome {
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
            return try await performActivation(activationCommand)
        } catch {
            let activationError = error
            if let cleanupError = await recoverFailedActivation(activationCommand) {
                phase = .recoveryPending
                throw cleanupError
            }
            phase = .idle
            throw activationError
        }
    }

    func stopImpl() async throws {
        if let isolationTask {
            await isolationTask.value
            self.isolationTask = nil
        }
        if phase == .recoveryPending {
            throw LumenMacWorkspaceSessionError.recoveryDidNotComplete
        }
        guard phase != .idle else {
            return
        }
        if let activationCommand {
            try await stopPreparedSession(activationCommand)
            return
        }
        try await stopActiveSession()
    }

    private func performActivation(
        _ command: LumenMacWorkspaceCommand
    ) async throws -> LumenMacWorkspaceActivationOutcome {
        let result = try await executor.execute(command)
        try await coordinator.complete(command, result: result)
        await executor.positionPointerOnSessionDisplay()
        activationCommand = nil
        phase = .active
        guard effectivePolicy == .isolatedWorkspace else {
            return LumenMacWorkspaceActivationOutcome(isolationStatus: .notRequested)
        }
        isolationTask = Task { [weak self] in
            await self?.completeDeferredIsolation()
        }
        return LumenMacWorkspaceActivationOutcome(isolationStatus: .pending)
    }

    private func recoverFailedActivation(
        _ command: LumenMacWorkspaceCommand
    ) async -> (any Error)? {
        _ = try? await coordinator.complete(command, result: .failed)
        activationCommand = nil
        let cleanupError: (any Error)?
        do {
            cleanupError = try await coordinator.executePendingCommandsRecovering(
                using: executor
            )
        } catch {
            cleanupError = error
        }
        do {
            try await executor.destroyOwnedVirtualDisplay()
        } catch {
            return error
        }
        return cleanupError
    }

    private func stopPreparedSession(
        _ activationCommand: LumenMacWorkspaceCommand
    ) async throws {
        _ = try? await coordinator.complete(activationCommand, result: .failed)
        self.activationCommand = nil
        let cleanupError = try await coordinator.executePendingCommandsRecovering(
            using: executor
        )
        if let cleanupError {
            phase = .recoveryPending
            throw cleanupError
        }
        phase = .idle
        await isolationStatusHandler(.notRequested)
    }

    private func stopActiveSession() async throws {
        let cleanupError: (any Error)?
        do {
            try await coordinator.endSession()
            cleanupError = try await coordinator.executePendingCommandsRecovering(
                using: executor
            )
        } catch {
            phase = .recoveryPending
            throw error
        }
        if let cleanupError {
            phase = .recoveryPending
            throw cleanupError
        }
        phase = .idle
        await isolationStatusHandler(.notRequested)
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
            await executor.positionPointerOnSessionDisplay()
            try await executor.verifyOwnedCaptureContinuity()
            try await coordinator.complete(command, result: result)
            isolationCommand = nil
            try await coordinator.executePendingCommands(using: executor)
            await isolationStatusHandler(await executor.physicalIsolationStatus())
        } catch {
            await handleDeferredIsolationFailure(error, command: isolationCommand)
        }
        isolationTask = nil
    }

    private func handleDeferredIsolationFailure(
        _ isolationError: any Error,
        command: LumenMacWorkspaceCommand?
    ) async {
        let platformIsolationStatus = await executor.physicalIsolationStatus()
        if let command {
            _ = try? await coordinator.complete(command, result: .failed)
        }
        let cleanupError = await recoverPendingCommandsError()
        let ownershipCleanupError: (any Error)?
        do {
            try await executor.destroyOwnedVirtualDisplay()
            ownershipCleanupError = nil
        } catch {
            ownershipCleanupError = error
        }
        phase = cleanupError == nil && ownershipCleanupError == nil
            ? .idle
            : .recoveryPending
        if cleanupError == nil,
           ownershipCleanupError == nil,
           case .unavailable = platformIsolationStatus {
            await isolationStatusHandler(platformIsolationStatus)
            return
        }
        let failures = [isolationError, cleanupError, ownershipCleanupError]
            .compactMap { $0 }
            .map { String(describing: $0) }
            .joined(separator: "; ")
        await isolationStatusHandler(.failed(message: failures))
    }

    private func recoverPendingCommandsError() async -> (any Error)? {
        do {
            return try await coordinator.executePendingCommandsRecovering(
                using: executor
            )
        } catch {
            return error
        }
    }
}
