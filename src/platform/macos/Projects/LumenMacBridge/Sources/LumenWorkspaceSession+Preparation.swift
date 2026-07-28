import Foundation

extension LumenMacWorkspaceSession {
    func prepareImpl() async throws {
        guard phase == .idle else {
            throw LumenMacWorkspaceSessionError.sessionAlreadyStarted
        }
        do {
            try await performPreparation()
        } catch {
            try await recoverFailedPreparation(error)
        }
    }

    var effectivePolicy: LumenMacWorkspacePolicy {
        if isDesktopMirror, request.policy != .isolatedWorkspace {
            return .coexist
        }
        return request.policy
    }

    var isDesktopMirror: Bool {
        if case .desktopMirror = request.contentSource {
            return true
        }
        return false
    }

    private func performPreparation() async throws {
        try await preparationFence()
        try await ensureSessionAdmission()
        while let command = try await coordinator.nextCommand() {
            try await runPreparationCommand(command)
            if phase == .prepared {
                return
            }
        }
        try await preparationFence()
        phase = .active
    }

    private func ensureSessionAdmission() async throws {
        let admitted = try await coordinator.beginSession(
            policy: effectivePolicy,
            moveTargetWindows: !request.targetProcessIdentifiers.isEmpty,
            manageCapture: request.managesCapture
        )
        try await preparationFence()
        guard !admitted else {
            return
        }
        if let recoveryError = try await coordinator.executePendingCommandsRecovering(
            using: executor
        ) {
            throw recoveryError
        }
        try await preparationFence()
        let recoveredAdmission = try await coordinator.beginSession(
            policy: effectivePolicy,
            moveTargetWindows: !request.targetProcessIdentifiers.isEmpty,
            manageCapture: request.managesCapture
        )
        try await preparationFence()
        guard recoveredAdmission else {
            throw LumenMacWorkspaceSessionError.recoveryDidNotComplete
        }
    }

    private func runPreparationCommand(
        _ command: LumenMacWorkspaceCommand
    ) async throws {
        do {
            try await prepareForCommandExecution(command)
            if command.action == .awaitExternalFirstEncodedFrame {
                try await preparationFence()
                activationCommand = command
                phase = .prepared
                return
            }
        } catch {
            _ = try? await coordinator.complete(command, result: .failed)
            throw error
        }

        do {
            let result = try await executePreparationCommand(command)
            try await coordinator.complete(command, result: result)
            try await preparationFence()
        } catch {
            _ = try? await coordinator.complete(command, result: .failed)
            throw error
        }
    }

    private func prepareForCommandExecution(
        _ command: LumenMacWorkspaceCommand
    ) async throws {
        if commandRequiresOwnedDisplayVerification(command) {
            try await executor.verifyOwnedVirtualDisplay()
            try await preparationFence()
        }
        guard commandRequiresCapturePreparation(command) else {
            return
        }
        if isDesktopMirror {
            try await prepareDesktopMirrorCapture()
            return
        }
        try await executor.prepareOwnedVirtualDisplayForCapture()
        try await preparationFence()
        try await materializeCaptureContent()
        try await preparationFence()
    }

    private func prepareDesktopMirrorCapture() async throws {
        try await executor.stageOwnedVirtualDisplayUnmirrored()
        try await preparationFence()
        // Retain the exact ScreenCaptureKit display while it is still an
        // independent output. Mirroring can collapse fresh enumeration to the
        // physical sink even though the retained virtual display stays active.
        try await executor.prepareOwnedVirtualDisplayForCapture()
        try await preparationFence()
        try await materializeCaptureContent()
        // Isolated desktop mirrors already journal the preceding
        // PromoteVirtualMain mutation. Coexist has no earlier mutation.
        if effectivePolicy == .coexist {
            try await coordinator.recordDesktopMirrorApplied()
        }
        try await preparationFence()
    }

    private func executePreparationCommand(
        _ command: LumenMacWorkspaceCommand
    ) async throws -> LumenMacWorkspaceCommandResult {
        let result = try await executor.execute(command)
        try await preparationFence()
        guard command.action == .configureVirtualDisplay else {
            return result
        }
        guard !isDesktopMirror else {
            return result
        }
        try await executor.stabilizeOwnedVirtualDisplay()
        try await preparationFence()
        return result
    }

    private func commandRequiresOwnedDisplayVerification(
        _ command: LumenMacWorkspaceCommand
    ) -> Bool {
        switch command.action {
        case .applyIsolation, .startCapture, .awaitExternalFirstEncodedFrame:
            return true
        default:
            return false
        }
    }

    private func commandRequiresCapturePreparation(
        _ command: LumenMacWorkspaceCommand
    ) -> Bool {
        command.action == .startCapture ||
            command.action == .awaitExternalFirstEncodedFrame
    }

    private func recoverFailedPreparation(_ preparationError: any Error) async throws {
        let cleanupError: (any Error)?
        do {
            cleanupError = try await coordinator.executePendingCommandsRecovering(
                using: executor
            )
        } catch {
            cleanupError = error
        }
        if let cleanupError {
            phase = .recoveryPending
            throw cleanupError
        }
        phase = .idle
        throw preparationError
    }

    private func materializeCaptureContent() async throws {
        if case .desktopMirror(let sourceDisplayID) = request.contentSource {
            try await materializeDesktopMirror(sourceDisplayID: sourceDisplayID)
            return
        }
        guard request.policy != .coexist else {
            return
        }
        let displayID = try await executor.activeVirtualDisplayID()
        guard try await executor.promoteOwnedVirtualDisplay() else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayPromotionUnavailable(displayID)
        }
        let message =
            "Lumen virtual display promotion complete after capture readiness " +
            "display-id=\(displayID)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func materializeDesktopMirror(sourceDisplayID: UInt32) async throws {
        let displayID = try await executor.activeVirtualDisplayID()
        try await executor.mirrorOwnedVirtualDisplay()
        let message =
            "Lumen virtual desktop mirror ready " +
            "session-display-id=\(displayID) " +
            "physical-target-display-id=\(sourceDisplayID)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
