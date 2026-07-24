import Foundation
import OSLog
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
    public var desktopMirrorSourceDisplayID: UInt32 = 0

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
            potentialPeakLuminanceNits: potentialPeakLuminanceNits,
            desktopMirrorSourceDisplayID: desktopMirrorSourceDisplayID
        )
    }

    @nonobjc public func makeRequest(
        policy: LumenMacWorkspacePolicy
    ) -> LumenMacWorkspaceSessionRequest {
        snapshot().swiftValue(policy: policy)
    }
}

struct LumenMacWorkspaceSessionRequestSnapshot: Sendable {
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
    let desktopMirrorSourceDisplayID: UInt32

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
        let displayMode = desktopMirrorSourceDisplayID == 0
            ? LumenMacDisplayModeRequest(
                width: width,
                height: height,
                scalePercent: 100,
                dimensionsAreLogical: false
            )
            : LumenMacDesktopMirrorDisplayModeResolver.resolve(
                captureWidth: width,
                captureHeight: height,
                sinkMode: sinkRequest.mode
            )
        return LumenMacWorkspaceSessionRequest(
            displayKey: displayKey,
            policy: policy,
            contentSource: desktopMirrorSourceDisplayID == 0
                ? .targetWindows
                : .desktopMirror(sourceDisplayID: desktopMirrorSourceDisplayID),
            displayMode: displayMode,
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

private enum LumenMacDesktopMirrorDisplayModeResolver {
    private static let minimumLogicalWidth: UInt64 = 800
    private static let minimumHiDPILogicalHeight: UInt64 = 540
    private static let minimumOneXLogicalHeight: UInt64 = 576
    private static let maximumEvenDimension = UInt64(UInt32.max - 1)

    static func resolve(
        captureWidth: UInt32,
        captureHeight: UInt32,
        sinkMode: LumenBridgeSinkMode
    ) -> LumenMacDisplayModeRequest {
        let scalePercent = UInt64(max(sinkMode.scalePercent, 100))
        let requestedLogicalWidth = sinkMode.modeIsLogical
            ? UInt64(captureWidth)
            : UInt64(captureWidth) * 100 / scalePercent
        let requestedLogicalHeight = sinkMode.modeIsLogical
            ? UInt64(captureHeight)
            : UInt64(captureHeight) * 100 / scalePercent
        let minimumHeight = sinkMode.hidpi
            ? minimumHiDPILogicalHeight
            : minimumOneXLogicalHeight
        let logicalSize = scaleToSupportedMinimum(
            width: max(requestedLogicalWidth, 2),
            height: max(requestedLogicalHeight, 2),
            minimumWidth: minimumLogicalWidth,
            minimumHeight: minimumHeight
        )
        let backingScale: UInt64 = sinkMode.hidpi ? 2 : 1
        return LumenMacDisplayModeRequest(
            width: boundedEven(logicalSize.width * backingScale),
            height: boundedEven(logicalSize.height * backingScale),
            scalePercent: UInt32(backingScale * 100),
            dimensionsAreLogical: false
        )
    }

    private static func scaleToSupportedMinimum(
        width: UInt64,
        height: UInt64,
        minimumWidth: UInt64,
        minimumHeight: UInt64
    ) -> (width: UInt64, height: UInt64) {
        guard width < minimumWidth || height < minimumHeight else {
            return (even(width), even(height))
        }
        if minimumWidth * height >= minimumHeight * width {
            return (
                even(minimumWidth),
                even(dividingRoundUp(height * minimumWidth, by: width))
            )
        }
        return (
            even(dividingRoundUp(width * minimumHeight, by: height)),
            even(minimumHeight)
        )
    }

    private static func dividingRoundUp(_ numerator: UInt64, by denominator: UInt64) -> UInt64 {
        numerator / denominator + (numerator % denominator == 0 ? 0 : 1)
    }

    private static func even(_ value: UInt64) -> UInt64 {
        min((value + 1) & ~1, maximumEvenDimension)
    }

    private static func boundedEven(_ value: UInt64) -> UInt32 {
        UInt32(even(value))
    }
}

@objcMembers
public final class LumenMacWorkspaceActivationOutcomeBox: NSObject {
    public let isolationStatusRawValue: UInt32
    public let warningMessage: String

    @nonobjc init(_ outcome: LumenMacWorkspaceActivationOutcome) {
        switch outcome.isolationStatus {
        case .notRequested:
            isolationStatusRawValue = 0
            warningMessage = ""
        case .pending:
            isolationStatusRawValue = 3
            warningMessage = ""
        case .applied:
            isolationStatusRawValue = 1
            warningMessage = ""
        case .unavailable(let message):
            isolationStatusRawValue = 2
            warningMessage = message
        case .failed(let message):
            isolationStatusRawValue = 4
            warningMessage = message
        }
        super.init()
    }
}

protocol LumenMacWorkspaceSessionLifecycle: Sendable {
    func prepare() async throws
    func activate() async throws -> LumenMacWorkspaceActivationOutcome
    func stop() async throws
    func displayID() async throws -> UInt32
}

extension LumenMacWorkspaceSession: LumenMacWorkspaceSessionLifecycle {}

actor LumenMacWorkspacePreparationLease {
    struct Token: Equatable, Sendable {
        let value: UUID
    }

    private var activeToken: Token?

    init(token: Token) {
        activeToken = token
    }

    func validate(_ token: Token) throws {
        try Task.checkCancellation()
        guard activeToken == token else {
            throw CancellationError()
        }
    }

    func revoke(_ token: Token) {
        guard activeToken == token else { return }
        activeToken = nil
    }
}

struct LumenMacWorkspaceLifecycleAdmission {
    enum Operation: Equatable, Sendable {
        case prepare
        case activate
        case stop
        case stopAll
        case recover
    }

    private(set) var operation: Operation?

    mutating func begin(
        _ operation: Operation,
        activeSessionCount: Int
    ) throws {
        guard self.operation == nil else {
            throw LumenMacWorkspaceSessionError.sessionAlreadyStarted
        }
        if operation == .prepare {
            guard activeSessionCount == 0 else {
                throw LumenMacWorkspaceSessionError.sessionAlreadyStarted
            }
        }
        self.operation = operation
    }

    mutating func takeOver(
        _ expected: Operation,
        with replacement: Operation
    ) throws {
        guard operation == expected else {
            throw LumenMacWorkspaceSessionError.sessionAlreadyStarted
        }
        operation = replacement
    }

    mutating func end(_ operation: Operation) {
        guard self.operation == operation else {
            return
        }
        self.operation = nil
    }
}

actor LumenMacWorkspaceSessionRegistry {
    typealias ResolvePolicy = @Sendable () async throws -> LumenMacWorkspacePolicy
    typealias PreparationFence = @Sendable () async throws -> Void
    typealias MakeSession = @Sendable (
        LumenMacWorkspaceSessionRequest,
        @escaping PreparationFence
    ) throws -> any LumenMacWorkspaceSessionLifecycle
    typealias RecoverDurableWorkspace = @Sendable () async throws -> Bool
    typealias AwaitPublicationBoundary = @Sendable () async -> Void

    private struct PreparedSession: Sendable {
        let displayKey: String
        let displayID: UInt32
        let session: any LumenMacWorkspaceSessionLifecycle
    }

    private struct ProvisionalSession: Sendable {
        let token: LumenMacWorkspacePreparationLease.Token
        let displayKey: String
        let lease: LumenMacWorkspacePreparationLease
        let task: Task<PreparedSession, Error>
    }

    private struct PreparationTaskError: Error, @unchecked Sendable {
        let underlyingError: any Error
        let session: any LumenMacWorkspaceSessionLifecycle
    }

    private struct TeardownOutcome: Sendable {
        let provisionalToken: LumenMacWorkspacePreparationLease.Token?
        let displayKeys: Set<String>
        let recoveredWorkspace: Bool
    }

    private struct TeardownFlight: Sendable {
        let id: UUID
        let operation: LumenMacWorkspaceLifecycleAdmission.Operation
        let displayKeys: Set<String>
        let task: Task<TeardownOutcome, Error>
    }

    private let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "MacWorkspaceSessionRegistry"
    )
    private let resolvePolicy: ResolvePolicy
    private let makeSession: MakeSession
    private let recoverDurableWorkspace: RecoverDurableWorkspace
    private let awaitPublicationBoundary: AwaitPublicationBoundary
    private var sessions: [String: any LumenMacWorkspaceSessionLifecycle] = [:]
    private var provisionalSession: ProvisionalSession?
    private var teardownFlight: TeardownFlight?
    private var lifecycleAdmission = LumenMacWorkspaceLifecycleAdmission()
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        settingsStore: LumenHostSettingsStore,
        runtime: LumenBridgeRuntime,
        makeDisplayWorkspace: @escaping @Sendable () -> any LumenMacDisplayWorkspaceManaging
    ) {
        resolvePolicy = {
            try await settingsStore.workspacePolicy()
        }
        makeSession = { request, preparationFence in
            try LumenMacWorkspaceSession(
                request: request,
                runtime: runtime,
                displayWorkspace: makeDisplayWorkspace(),
                preparationFence: preparationFence
            )
        }
        recoverDurableWorkspace = {
            try await LumenMacWorkspaceDurableRecovery.perform(
                runtime: runtime,
                makeDisplayWorkspace: makeDisplayWorkspace
            )
        }
        awaitPublicationBoundary = {}
    }

    init(
        resolvePolicy: @escaping ResolvePolicy,
        makeSession: @escaping MakeSession,
        recoverDurableWorkspace: @escaping RecoverDurableWorkspace,
        awaitPublicationBoundary: @escaping AwaitPublicationBoundary = {}
    ) {
        self.resolvePolicy = resolvePolicy
        self.makeSession = makeSession
        self.recoverDurableWorkspace = recoverDurableWorkspace
        self.awaitPublicationBoundary = awaitPublicationBoundary
    }

    func prepare(_ snapshot: LumenMacWorkspaceSessionRequestSnapshot) async throws -> UInt32 {
        guard !snapshot.displayKey.isEmpty else {
            throw LumenMacWorkspaceSessionFacadeError.emptyDisplayKey
        }
        guard provisionalSession == nil, teardownFlight == nil else {
            throw LumenMacWorkspaceSessionError.sessionAlreadyStarted
        }
        try lifecycleAdmission.begin(.prepare, activeSessionCount: sessions.count)
        let token = LumenMacWorkspacePreparationLease.Token(value: UUID())
        let lease = LumenMacWorkspacePreparationLease(token: token)
        let resolvePolicy = self.resolvePolicy
        let makeSession = self.makeSession
        let recoverDurableWorkspace = self.recoverDurableWorkspace
        let task = Task<PreparedSession, Error> {
            let fence: PreparationFence = {
                try await lease.validate(token)
            }
            try await fence()
            let request = snapshot.swiftValue(policy: try await resolvePolicy())
            try await fence()
            _ = try await recoverDurableWorkspace()
            try await fence()
            let session = try makeSession(request, fence)
            do {
                try await session.prepare()
                try await fence()
                let displayID = try await session.displayID()
                try await fence()
                return PreparedSession(
                    displayKey: request.displayKey,
                    displayID: displayID,
                    session: session
                )
            } catch {
                throw PreparationTaskError(
                    underlyingError: error,
                    session: session
                )
            }
        }
        let provisional = ProvisionalSession(
            token: token,
            displayKey: snapshot.displayKey,
            lease: lease,
            task: task
        )
        provisionalSession = provisional
        do {
            let prepared = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { await lease.revoke(token) }
            }
            await awaitPublicationBoundary()
            try Task.checkCancellation()
            try await lease.validate(token)
            guard provisionalSession?.token == token,
                  lifecycleAdmission.operation == .prepare else {
                throw CancellationError()
            }
            sessions[prepared.displayKey] = prepared.session
            provisionalSession = nil
            endLifecycleOperation(.prepare)
            return prepared.displayID
        } catch {
            let preparationError = (error as? PreparationTaskError)?.underlyingError ?? error
            do {
                _ = try await runTeardown(
                    operation: .recover,
                    requestedDisplayKey: snapshot.displayKey,
                    includesAllSessions: false,
                    recoversDurableWorkspaceWhenEmpty: true
                )
            } catch {
                throw error
            }
            throw preparationError
        }
    }

    func activate(displayKey: String) async throws -> LumenMacWorkspaceActivationOutcome {
        guard let session = sessions[displayKey] else {
            throw LumenMacWorkspaceSessionError.sessionNotStarted
        }
        try lifecycleAdmission.begin(.activate, activeSessionCount: sessions.count)
        defer { endLifecycleOperation(.activate) }
        do {
            return try await session.activate()
        } catch {
            let activationError = error
            do {
                _ = try await recoverDurableWorkspace()
                sessions.removeValue(forKey: displayKey)
            } catch {
                logger.error(
                    "Workspace activation rollback remains pending display-key=\(displayKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                throw error
            }
            throw activationError
        }
    }

    func stop(displayKey: String) async throws -> Bool {
        if let teardownFlight {
            guard teardownFlight.displayKeys.contains(displayKey) else {
                return false
            }
        } else {
            guard provisionalSession?.displayKey == displayKey ||
                sessions[displayKey] != nil else {
                return false
            }
        }
        _ = try await runTeardown(
            operation: .stop,
            requestedDisplayKey: displayKey,
            includesAllSessions: false,
            recoversDurableWorkspaceWhenEmpty: false
        )
        return true
    }

    func stopAll() async {
        guard teardownFlight != nil || provisionalSession != nil || !sessions.isEmpty else {
            return
        }
        do {
            _ = try await runTeardown(
                operation: .stopAll,
                requestedDisplayKey: nil,
                includesAllSessions: true,
                recoversDurableWorkspaceWhenEmpty: false
            )
        } catch {
            logger.error(
                "Workspace stop-all retained cleanup state error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    func recoverPendingWorkspace() async throws -> Bool {
        let outcome = try await runTeardown(
            operation: .recover,
            requestedDisplayKey: nil,
            includesAllSessions: true,
            recoversDurableWorkspaceWhenEmpty: true
        )
        return outcome?.recoveredWorkspace ?? false
    }

    private func runTeardown(
        operation: LumenMacWorkspaceLifecycleAdmission.Operation,
        requestedDisplayKey: String?,
        includesAllSessions: Bool,
        recoversDurableWorkspaceWhenEmpty: Bool
    ) async throws -> TeardownOutcome? {
        if let teardownFlight {
            return try await joinTeardown(teardownFlight)
        }
        while lifecycleAdmission.operation != nil,
              lifecycleAdmission.operation != .prepare {
            await waitForLifecycleIdle()
            if let teardownFlight {
                return try await joinTeardown(teardownFlight)
            }
        }

        let provisional: ProvisionalSession?
        if let current = provisionalSession,
           includesAllSessions || current.displayKey == requestedDisplayKey {
            provisional = current
        } else {
            provisional = nil
        }
        let selectedSessions: [String: any LumenMacWorkspaceSessionLifecycle]
        if includesAllSessions {
            selectedSessions = sessions
        } else if let requestedDisplayKey,
                  let session = sessions[requestedDisplayKey] {
            selectedSessions = [requestedDisplayKey: session]
        } else {
            selectedSessions = [:]
        }
        guard provisional != nil ||
            !selectedSessions.isEmpty ||
            recoversDurableWorkspaceWhenEmpty else {
            return nil
        }

        if lifecycleAdmission.operation == .prepare {
            try lifecycleAdmission.takeOver(.prepare, with: operation)
        } else {
            try lifecycleAdmission.begin(operation, activeSessionCount: sessions.count)
        }
        let recoverDurableWorkspace = self.recoverDurableWorkspace
        let flightID = UUID()
        let task = Task<TeardownOutcome, Error> {
            var recoveredWorkspace = false
            if let provisional {
                await provisional.lease.revoke(provisional.token)
                provisional.task.cancel()
                switch await provisional.task.result {
                case .success(let prepared):
                    _ = try await LumenWorkspaceStopRecoveryCoordinator.stop(
                        stop: { try await prepared.session.stop() },
                        recover: recoverDurableWorkspace
                    )
                    recoveredWorkspace = true
                case .failure(let error):
                    if let preparationError = error as? PreparationTaskError {
                        _ = try await LumenWorkspaceStopRecoveryCoordinator.stop(
                            stop: { try await preparationError.session.stop() },
                            recover: recoverDurableWorkspace
                        )
                        recoveredWorkspace = true
                    } else {
                        recoveredWorkspace = try await recoverDurableWorkspace()
                    }
                }
            }
            for session in selectedSessions.values {
                _ = try await LumenWorkspaceStopRecoveryCoordinator.stop(
                    stop: { try await session.stop() },
                    recover: recoverDurableWorkspace
                )
                recoveredWorkspace = true
            }
            if provisional == nil,
               selectedSessions.isEmpty,
               recoversDurableWorkspaceWhenEmpty {
                recoveredWorkspace = try await recoverDurableWorkspace()
            }
            return TeardownOutcome(
                provisionalToken: provisional?.token,
                displayKeys: Set(selectedSessions.keys),
                recoveredWorkspace: recoveredWorkspace
            )
        }
        let flight = TeardownFlight(
            id: flightID,
            operation: operation,
            displayKeys: Set(selectedSessions.keys).union(
                provisional.map { [$0.displayKey] } ?? []
            ),
            task: task
        )
        teardownFlight = flight
        return try await joinTeardown(flight)
    }

    private func joinTeardown(
        _ flight: TeardownFlight
    ) async throws -> TeardownOutcome {
        do {
            let outcome = try await flight.task.value
            if teardownFlight?.id == flight.id {
                if provisionalSession?.token == outcome.provisionalToken {
                    provisionalSession = nil
                }
                for displayKey in outcome.displayKeys {
                    sessions.removeValue(forKey: displayKey)
                }
                teardownFlight = nil
                endLifecycleOperation(flight.operation)
            }
            return outcome
        } catch {
            if teardownFlight?.id == flight.id {
                teardownFlight = nil
                endLifecycleOperation(flight.operation)
            }
            throw error
        }
    }

    private func waitForLifecycleIdle() async {
        guard lifecycleAdmission.operation != nil else { return }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(continuation)
        }
    }

    private func endLifecycleOperation(
        _ operation: LumenMacWorkspaceLifecycleAdmission.Operation
    ) {
        lifecycleAdmission.end(operation)
        guard lifecycleAdmission.operation == nil else { return }
        let waiters = lifecycleWaiters
        lifecycleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum LumenMacWorkspaceDurableRecovery {
    static func perform(
        runtime: LumenBridgeRuntime,
        makeDisplayWorkspace: @escaping @Sendable () -> any LumenMacDisplayWorkspaceManaging
    ) async throws -> Bool {
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
            verifyVirtualDisplay: { _ in
                throw LumenMacWorkspaceSessionError.recoveryDidNotComplete
            },
            startCapture: { _ in
                throw LumenMacWorkspaceSessionError.recoveryDidNotComplete
            },
            stopCapture: {
                await runtime.stopCapture()
            },
            destroyVirtualDisplay: { identity in
                try await LumenMacOwnedVirtualDisplayRegistry.shared.recoverDisplay(
                    forKey: identity.id
                )
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
    ) -> LumenMacWorkspaceActivationOutcomeBox? {
        do {
            let outcome = try blockingRun {
                try await self.registry.activate(displayKey: displayKey)
            }
            return LumenMacWorkspaceActivationOutcomeBox(outcome)
        } catch {
            errorPointer?.pointee = error as NSError
            return nil
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
