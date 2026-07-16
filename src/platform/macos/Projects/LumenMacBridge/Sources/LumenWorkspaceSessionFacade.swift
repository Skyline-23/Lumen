import Foundation
import Synchronization

@objcMembers
public final class LumenMacWorkspaceSessionRequestBox: NSObject {
    public var displayKey = ""
    public var displayName = "Lumen Display"
    public var width: UInt32 = 1920
    public var height: UInt32 = 1080
    public var scalePercent: UInt32 = 100
    public var dimensionsAreLogical = false
    public var refreshRate = 120.0
    public var hdrEnabled = false
    public var clientSinkGamutRawValue = 0
    public var clientSinkTransferRawValue = 0
    public var currentEDRHeadroom: Float = 0
    public var potentialEDRHeadroom: Float = 0
    public var currentPeakLuminanceNits = 0
    public var potentialPeakLuminanceNits = 0

    @nonobjc fileprivate func snapshot() -> LumenMacWorkspaceSessionRequestSnapshot {
        LumenMacWorkspaceSessionRequestSnapshot(
            displayKey: displayKey,
            displayName: displayName,
            width: width,
            height: height,
            scalePercent: scalePercent,
            dimensionsAreLogical: dimensionsAreLogical,
            refreshRate: refreshRate,
            hdrEnabled: hdrEnabled,
            clientSinkGamutRawValue: clientSinkGamutRawValue,
            clientSinkTransferRawValue: clientSinkTransferRawValue,
            currentEDRHeadroom: currentEDRHeadroom,
            potentialEDRHeadroom: potentialEDRHeadroom,
            currentPeakLuminanceNits: currentPeakLuminanceNits,
            potentialPeakLuminanceNits: potentialPeakLuminanceNits
        )
    }

    @nonobjc public func makeRequest(
        policy: LumenMacWorkspacePolicy
    ) -> LumenMacWorkspaceSessionRequest {
        snapshot().swiftValue(policy: policy)
    }
}

private struct LumenMacWorkspaceSessionRequestSnapshot: Sendable {
    let displayKey: String
    let displayName: String
    let width: UInt32
    let height: UInt32
    let scalePercent: UInt32
    let dimensionsAreLogical: Bool
    let refreshRate: Double
    let hdrEnabled: Bool
    let clientSinkGamutRawValue: Int
    let clientSinkTransferRawValue: Int
    let currentEDRHeadroom: Float
    let potentialEDRHeadroom: Float
    let currentPeakLuminanceNits: Int
    let potentialPeakLuminanceNits: Int

    func swiftValue(
        policy: LumenMacWorkspacePolicy
    ) -> LumenMacWorkspaceSessionRequest {
        let gamut = LumenBridgeObjCFacade.clientSinkGamut(
            fromRawValue: clientSinkGamutRawValue
        )
        let transfer = LumenBridgeObjCFacade.clientSinkTransfer(
            fromRawValue: clientSinkTransferRawValue
        )
        let dynamicRangeTransport = hdrEnabled
            ? LumenMacDynamicRangeTransportFullFrameHDR
            : LumenMacDynamicRangeTransportSDR
        let sinkRequest = LumenBridgeSinkRequest(
            mode: LumenBridgeSinkMode(
                hidpi: scalePercent != 100,
                scaleExplicit: scalePercent != 100,
                modeIsLogical: dimensionsAreLogical,
                scalePercent: Int(scalePercent)
            ),
            capability: LumenBridgeSinkCapability(
                gamut: gamut,
                transfer: transfer,
                currentEDRHeadroom: currentEDRHeadroom,
                potentialEDRHeadroom: potentialEDRHeadroom,
                currentPeakLuminanceNits: currentPeakLuminanceNits,
                potentialPeakLuminanceNits: potentialPeakLuminanceNits
            ),
            dynamicRangeTransport: dynamicRangeTransport
        )
        return LumenMacWorkspaceSessionRequest(
            displayKey: displayKey,
            policy: policy,
            displayMode: LumenMacDisplayModeRequest(
                width: width,
                height: height,
                scalePercent: scalePercent,
                dimensionsAreLogical: dimensionsAreLogical
            ),
            displayName: displayName,
            refreshRate: refreshRate,
            managesCapture: false,
            captureConfiguration: LumenMacCaptureConfiguration(
                displayID: 0,
                targetFrameRate: Int(refreshRate.rounded()),
                requestedWidth: Int(width),
                requestedHeight: Int(height),
                sinkRequest: sinkRequest,
                effectiveDisplayState: LumenBridgeEffectiveDisplayState(
                    gamut: gamut,
                    transfer: transfer
                )
            )
        )
    }
}

private actor LumenMacWorkspaceSessionRegistry {
    private let settingsStore: LumenHostSettingsStore
    private let runtime: LumenBridgeRuntime
    private let makeDisplayWorkspace: @Sendable () -> any LumenMacDisplayWorkspaceManaging
    private var sessions: [String: LumenMacWorkspaceSession] = [:]

    init(
        settingsStore: LumenHostSettingsStore,
        runtime: LumenBridgeRuntime,
        makeDisplayWorkspace: @escaping @Sendable () -> any LumenMacDisplayWorkspaceManaging
    ) {
        self.settingsStore = settingsStore
        self.runtime = runtime
        self.makeDisplayWorkspace = makeDisplayWorkspace
    }

    func prepare(_ snapshot: LumenMacWorkspaceSessionRequestSnapshot) async throws -> UInt32 {
        let request = snapshot.swiftValue(
            policy: try await settingsStore.workspacePolicy()
        )
        guard !request.displayKey.isEmpty else {
            throw LumenMacWorkspaceSessionFacadeError.emptyDisplayKey
        }
        guard sessions[request.displayKey] == nil else {
            throw LumenMacWorkspaceSessionError.sessionAlreadyStarted
        }

        let session = try LumenMacWorkspaceSession(
            request: request,
            runtime: runtime,
            displayWorkspace: makeDisplayWorkspace()
        )
        try await session.prepare()
        let displayID = try await session.displayID()
        sessions[request.displayKey] = session
        return displayID
    }

    func activate(displayKey: String) async throws -> Bool {
        guard let session = sessions[displayKey] else {
            throw LumenMacWorkspaceSessionError.sessionNotStarted
        }
        do {
            try await session.activate()
            return true
        } catch {
            sessions.removeValue(forKey: displayKey)
            throw error
        }
    }

    func stop(displayKey: String) async throws -> Bool {
        guard let session = sessions.removeValue(forKey: displayKey) else {
            return false
        }
        try await session.stop()
        return true
    }

    func stopAll() async {
        let activeSessions = sessions
        sessions.removeAll()
        for session in activeSessions.values {
            _ = try? await session.stop()
        }
    }

    func recoverPendingWorkspace() async throws -> Bool {
        let journalPath = LumenWorkspaceCoordinator.defaultRecoveryJournalPath
        guard FileManager.default.fileExists(atPath: journalPath) else {
            return false
        }
        let coordinator = try LumenWorkspaceCoordinator(recoveryJournalPath: journalPath)
        let operations = LumenMacWorkspaceNativeOperations(
            createVirtualDisplay: { _, _ in
                throw LumenMacWorkspaceSessionError.recoveryDidNotComplete
            },
            configureVirtualDisplay: { _, _ in
                throw LumenMacWorkspaceSessionError.recoveryDidNotComplete
            },
            startCapture: { _ in
                throw LumenMacWorkspaceSessionError.recoveryDidNotComplete
            },
            stopCapture: {
                await self.runtime.stopCapture()
            },
            destroyVirtualDisplay: { identity in
                _ = LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: identity.id)
            }
        )
        let executor = try LumenMacWorkspaceExecutor(
            targetProcessIdentifiers: [],
            displayMode: LumenMacDisplayModeRequest(
                width: 1920,
                height: 1080,
                scalePercent: 100,
                dimensionsAreLogical: false
            ),
            operations: operations,
            displayWorkspace: makeDisplayWorkspace()
        )
        let admitted = try await coordinator.beginSession(
            policy: .coexist,
            manageCapture: false
        )
        guard !admitted else {
            return false
        }
        if let recoveryError = try await coordinator.executePendingCommandsRecovering(
            using: executor
        ) {
            throw recoveryError
        }
        return true
    }
}

public enum LumenMacWorkspaceSessionFacadeError: Error, Equatable {
    case emptyDisplayKey
}

@objcMembers
public final class LumenMacWorkspaceSessionFacade: NSObject, Sendable {
    public static let shared = LumenMacWorkspaceSessionFacade()

    private let registry: LumenMacWorkspaceSessionRegistry

    public override init() {
        guard let settingsStore = try? LumenHostSettingsStore() else {
            fatalError("Unable to construct the Lumen host settings store")
        }
        registry = LumenMacWorkspaceSessionRegistry(
            settingsStore: settingsStore,
            runtime: .shared,
            makeDisplayWorkspace: { LumenMacDisplayWorkspace() }
        )
        super.init()
    }

    public func prepareSessionSync(
        _ request: LumenMacWorkspaceSessionRequestBox,
        error errorPointer: NSErrorPointer
    ) -> UInt32 {
        let snapshot = request.snapshot()
        do {
            return try blockingRun {
                try await self.registry.prepare(snapshot)
            }
        } catch {
            errorPointer?.pointee = error as NSError
            return 0
        }
    }

    public func activateSessionSync(
        displayKey: String,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        do {
            return try blockingRun {
                try await self.registry.activate(displayKey: displayKey)
            }
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func stopSessionSync(
        displayKey: String,
        error errorPointer: NSErrorPointer
    ) -> Bool {
        do {
            return try blockingRun {
                try await self.registry.stop(displayKey: displayKey)
            }
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    public func stopAllSessionsSync() {
        try? blockingRun {
            await self.registry.stopAll()
        }
    }

    public func recoverPendingWorkspaceSync(
        error errorPointer: NSErrorPointer
    ) -> Bool {
        do {
            return try blockingRun {
                try await self.registry.recoverPendingWorkspace()
            }
        } catch {
            errorPointer?.pointee = error as NSError
            return false
        }
    }

    private func blockingRun<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Result<T, Error>?>(nil)
        Task {
            do {
                let value = try await operation()
                result.withLock { $0 = .success(value) }
            } catch {
                result.withLock { $0 = .failure(error) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.withLock { result in
            guard let result else {
                fatalError("LumenMacWorkspaceSessionFacade resolved without a result")
            }
            return try result.get()
        }
    }
}
