import Foundation

actor LumenMacVirtualDisplayOwner {
    private let ownershipRegistry: LumenMacOwnedVirtualDisplayRegistry
    private var display: LumenMacVirtualDisplay?
    private var displayKey: String?
    private var capturePreparationTask: Task<Void, Error>?

    init(ownershipRegistry: LumenMacOwnedVirtualDisplayRegistry) {
        self.ownershipRegistry = ownershipRegistry
    }

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
        let owner = LumenRetainedVirtualDisplayReference(display: display)
        do {
            try await ownershipRegistry.register(owner, forKey: identity.id)
        } catch {
            _ = LumenMacVirtualDisplay.removeRegisteredDisplay(
                forKey: identity.id,
                ifMatchingDisplay: display
            )
            throw error
        }
        self.display = display
        displayKey = identity.id
        return display.displayID
    }

    func configure(
        displayID: UInt32,
        geometry: LumenMacDisplayGeometry,
        refreshRate: Double
    ) async throws {
        guard let display, display.displayID == displayID else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        try display.updateLogicalWidth(
            geometry.logicalWidth,
            logicalHeight: geometry.logicalHeight,
            refreshRate: refreshRate
        )
    }

    func beginCapturePreparation(displayID: UInt32) throws {
        _ = try retainedOwner(for: displayID)
        guard capturePreparationTask == nil else {
            return
        }
        capturePreparationTask = Task {
            try await LumenScreenCaptureDisplayPrefetch.prepare(
                displayID: displayID
            )
        }
    }

    func awaitCapturePreparation(displayID: UInt32) async throws {
        _ = try retainedOwner(for: displayID)
        if capturePreparationTask == nil {
            try beginCapturePreparation(displayID: displayID)
        }
        guard let capturePreparationTask else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        try await withTaskCancellationHandler {
            try await capturePreparationTask.value
        } onCancel: {
            capturePreparationTask.cancel()
        }
        try verify(displayID: displayID)
    }

    func settleMode(displayID: UInt32) async throws {
        let owner = try retainedOwner(for: displayID)
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try await waitForModeSettlement(displayID: displayID, owner: owner)
        } catch {
            writeModeSettlementFailure(
                displayID: displayID,
                owner: owner,
                startedAt: startedAt,
                error: error
            )
            throw error
        }
        writeModeSettlementSuccess(
            displayID: displayID,
            owner: owner,
            startedAt: startedAt
        )
    }

    func stabilize(displayID: UInt32) async throws {
        let owner = try retainedOwner(for: displayID)
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            try await waitForPublication(displayID: displayID, owner: owner)
        } catch {
            writePublicationFailure(
                displayID: displayID,
                owner: owner,
                startedAt: startedAt,
                error: error
            )
            throw error
        }
        let elapsedMilliseconds = elapsedMilliseconds(since: startedAt)
        let message =
            "Lumen virtual display publication stabilized " +
            "display-id=\(displayID) " +
            "owner-token=\(owner.ownerToken) " +
            "elapsed-ms=\(elapsedMilliseconds)\n"
        FileHandle.standardError.write(Data(message.utf8))
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
        guard let display else {
            try await ownershipRegistry.recoverDisplay(forKey: identity.id)
            return
        }
        capturePreparationTask?.cancel()
        capturePreparationTask = nil
        try await ownershipRegistry.destroy(
            LumenRetainedVirtualDisplayReference(display: display),
            forKey: identity.id
        )
        self.display = nil
        self.displayKey = nil
    }

    private func retainedOwner(
        for displayID: UInt32
    ) throws -> LumenRetainedVirtualDisplayReference {
        guard let display, display.displayID == displayID else {
            throw LumenMacWorkspaceSessionError.virtualDisplayOwnershipMismatch
        }
        return LumenRetainedVirtualDisplayReference(display: display)
    }

    private func waitForModeSettlement(
        displayID: UInt32,
        owner: LumenRetainedVirtualDisplayReference
    ) async throws {
        try await LumenMacVirtualDisplayPublicationStabilizer.waitForModeSettlement(
            displayID: displayID,
            expectedOwnerToken: owner.ownerToken,
            timing: .production,
            now: monotonicNow,
            sleepUntil: monotonicSleep,
            snapshot: {
                LumenScreenCaptureDisplayReadiness.snapshot(
                    displayID: displayID,
                    owner: owner
                )
            }
        )
    }

    private func waitForPublication(
        displayID: UInt32,
        owner: LumenRetainedVirtualDisplayReference
    ) async throws {
        try await LumenMacVirtualDisplayPublicationStabilizer.wait(
            displayID: displayID,
            expectedOwnerToken: owner.ownerToken,
            timing: .production,
            now: monotonicNow,
            sleepUntil: monotonicSleep,
            snapshot: {
                LumenScreenCaptureDisplayReadiness.snapshot(
                    displayID: displayID,
                    owner: owner
                )
            }
        )
    }

    private func writeModeSettlementFailure(
        displayID: UInt32,
        owner: LumenRetainedVirtualDisplayReference,
        startedAt: TimeInterval,
        error: any Error
    ) {
        let snapshot = readinessSnapshot(displayID: displayID, owner: owner)
        let observedOwner = snapshot.ownerToken.map(String.init) ?? "none"
        let description =
            (error as? any LocalizedError)?.errorDescription ??
            String(describing: error)
        let message =
            "Lumen virtual display mode settlement failed " +
            "display-id=\(displayID) " +
            "expected-owner-token=\(owner.ownerToken) " +
            "observed-owner-token=\(observedOwner) " +
            readinessDescription(snapshot) +
            "elapsed-ms=\(elapsedMilliseconds(since: startedAt)) " +
            "error=\(description)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func writeModeSettlementSuccess(
        displayID: UInt32,
        owner: LumenRetainedVirtualDisplayReference,
        startedAt: TimeInterval
    ) {
        let snapshot = readinessSnapshot(displayID: displayID, owner: owner)
        let message =
            "Lumen virtual display mode settled " +
            "display-id=\(displayID) " +
            "owner-token=\(owner.ownerToken) " +
            readinessDescription(snapshot) +
            "elapsed-ms=\(elapsedMilliseconds(since: startedAt))\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func writePublicationFailure(
        displayID: UInt32,
        owner: LumenRetainedVirtualDisplayReference,
        startedAt: TimeInterval,
        error: any Error
    ) {
        let snapshot = readinessSnapshot(displayID: displayID, owner: owner)
        let observedOwner = snapshot.ownerToken.map(String.init) ?? "none"
        let modeReady = snapshot.isModeReady(
            for: .retained(ownerToken: owner.ownerToken)
        )
        let description =
            (error as? any LocalizedError)?.errorDescription ??
            String(describing: error)
        let message =
            "Lumen virtual display publication failed " +
            "display-id=\(displayID) " +
            "expected-owner-token=\(owner.ownerToken) " +
            "observed-owner-token=\(observedOwner) " +
            readinessDescription(snapshot) +
            "mode-ready=\(modeReady) " +
            "elapsed-ms=\(elapsedMilliseconds(since: startedAt)) " +
            "error=\(description)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func readinessSnapshot(
        displayID: UInt32,
        owner: LumenRetainedVirtualDisplayReference
    ) -> LumenCaptureDisplayReadinessSnapshot {
        LumenScreenCaptureDisplayReadiness.snapshot(
            displayID: displayID,
            owner: owner
        )
    }

    private func readinessDescription(
        _ snapshot: LumenCaptureDisplayReadinessSnapshot
    ) -> String {
        "online=\(snapshot.isOnline) " +
            "active=\(snapshot.isActive) " +
            "current-mode=\(snapshot.hasCurrentMode) " +
            "pixel-size=\(snapshot.pixelWidth)x\(snapshot.pixelHeight) " +
            "configured-size=\(snapshot.configuredPixelWidth)x" +
            "\(snapshot.configuredPixelHeight) "
    }

    private func elapsedMilliseconds(since startedAt: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    }
}

private func monotonicNow() async -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func monotonicSleep(until deadline: UInt64) async throws {
    let now = DispatchTime.now().uptimeNanoseconds
    if deadline > now {
        try await Task.sleep(nanoseconds: deadline - now)
    }
}
