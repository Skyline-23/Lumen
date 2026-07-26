import ApplicationServices
import CoreGraphics
import Foundation

public enum LumenMacDisplayWorkspaceError: LocalizedError, Equatable {
    case snapshotAlreadyExists
    case snapshotMissing
    case displayNotFound(UInt32)
    case virtualDisplayPromotionUnavailable(UInt32)
    case virtualDisplayMirrorUnavailable(UInt32, UInt32)
    case virtualDisplayMirrorRollbackFailed(UInt32)
    case virtualDisplayOwnershipLost(UInt32, UInt, UInt?)
    case displayConfigurationFailed(Int32)
    case accessibilityPermissionMissing
    case invalidPersistedDisplayID(String)
    case displayModeNotFound(UInt32)
    case physicalTopologyMismatch
    case physicalDisplayWakeTimeout([UInt32])
    case isolationUnavailable(String)
    case isolationPostconditionFailed
    case isolationRollbackFailed
    case windowSnapshotUnavailable(Int32)
    case windowNotFound(Int32, UInt32)
    case windowTopologyMismatch(Int32, UInt32)

    public var errorDescription: String? {
        switch self {
        case .snapshotAlreadyExists:
            "a display workspace snapshot already exists"
        case .snapshotMissing:
            "the display workspace snapshot is missing"
        case .displayNotFound(let displayID):
            "display \(displayID) was not found"
        case .virtualDisplayPromotionUnavailable(let displayID):
            "owned virtual display \(displayID) could not be promoted into the capture workspace"
        case let .virtualDisplayMirrorUnavailable(displayID, sourceDisplayID):
            "owned virtual display \(displayID) could not become the capture source " +
                "for physical desktop display \(sourceDisplayID)"
        case .virtualDisplayMirrorRollbackFailed(let displayID):
            "owned virtual display \(displayID) could not leave desktop mirror topology"
        case let .virtualDisplayOwnershipLost(displayID, expectedOwnerToken, actualOwnerToken):
            Self.ownershipLostDescription(
                displayID: displayID,
                expectedOwnerToken: expectedOwnerToken,
                actualOwnerToken: actualOwnerToken
            )
        case .displayConfigurationFailed(let status):
            "CoreGraphics display configuration failed with status \(status)"
        case .accessibilityPermissionMissing:
            "Accessibility permission is required to restore managed windows"
        case .invalidPersistedDisplayID(let displayID):
            "persisted display identifier \(displayID) is invalid"
        case .displayModeNotFound(let displayID):
            "the persisted mode for display \(displayID) is unavailable"
        case .physicalTopologyMismatch:
            "the restored physical display topology did not converge"
        case .physicalDisplayWakeTimeout(let displayIDs):
            "the restored physical displays did not wake: " +
                displayIDs.map(String.init).joined(separator: ",")
        case .isolationUnavailable(let message):
            "physical display isolation is unavailable: \(message)"
        case .isolationPostconditionFailed:
            "physical display isolation did not reach its required topology"
        case .isolationRollbackFailed:
            "physical display isolation rollback failed"
        case .windowSnapshotUnavailable(let processID):
            "window snapshot is unavailable for process \(processID)"
        case .windowNotFound(let processID, let windowID):
            "window \(windowID) for process \(processID) was not found"
        case .windowTopologyMismatch(let processID, let windowID):
            "window \(windowID) for process \(processID) did not return to its saved topology"
        }
    }

    private static func ownershipLostDescription(
        displayID: UInt32,
        expectedOwnerToken: UInt,
        actualOwnerToken: UInt?
    ) -> String {
        let actualOwnerDescription = actualOwnerToken.map(String.init) ?? "none"
        return "owned virtual display \(displayID) lost owner token " +
            "\(expectedOwnerToken) before or after staging " +
            "(actual \(actualOwnerDescription))"
    }
}

struct LumenMacDisplayMirrorState: Equatable, Sendable {
    let mainDisplayID: UInt32
    let mirrorSourceDisplayID: UInt32?
    let sourceIsOnline: Bool
    let sourceIsActive: Bool
    let sourceIsOwnedVirtualDisplay: Bool
    let sourceBounds: CGRect
    let sourceConfiguredSize: CGSize?
    let sourceOwnerToken: UInt?
    let targetIsOnline: Bool
    let targetIsActive: Bool
    let targetBounds: CGRect
    let targetOwnerToken: UInt?
}

protocol LumenMacDisplayMirrorControlling: Sendable {
    func displayBounds(
        for displayIDs: [UInt32]
    ) async throws -> [UInt32: CGRect]
    func state(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) async -> LumenMacDisplayMirrorState
    func mirror(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) async throws
    func stageUnmirrored(
        targetDisplayID: UInt32,
        origin: CGPoint,
        expectedOwnerToken: UInt
    ) async throws
    func unmirror(targetDisplayID: UInt32) async throws
}

struct LumenCoreGraphicsDisplayMirrorController:
    LumenMacDisplayMirrorControlling {
    private static let desktopMirrorConfigurationScope: CGConfigureOption =
        .forSession
    private static let desktopMirrorStageConfigurationScope: CGConfigureOption =
        .forAppOnly

    func displayBounds(
        for displayIDs: [UInt32]
    ) -> [UInt32: CGRect] {
        Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, CGDisplayBounds($0)) })
    }

    func state(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) -> LumenMacDisplayMirrorState {
        let mirroredDisplayID = CGDisplayMirrorsDisplay(targetDisplayID)
        let sourceDisplay = LumenMacVirtualDisplay.registeredDisplay(
            forDisplayID: sourceDisplayID
        )
        return LumenMacDisplayMirrorState(
            mainDisplayID: CGMainDisplayID(),
            mirrorSourceDisplayID: mirroredDisplayID == kCGNullDirectDisplay
                ? nil
                : mirroredDisplayID,
            sourceIsOnline: CGDisplayIsOnline(sourceDisplayID) != 0,
            sourceIsActive: CGDisplayIsActive(sourceDisplayID) != 0,
            sourceIsOwnedVirtualDisplay: sourceDisplay != nil,
            sourceBounds: CGDisplayBounds(sourceDisplayID),
            sourceConfiguredSize: sourceDisplay.map {
                CGSize(
                    width: CGFloat($0.logicalWidth),
                    height: CGFloat($0.logicalHeight)
                )
            },
            sourceOwnerToken: sourceDisplay.map {
                LumenRetainedVirtualDisplayReference(display: $0).ownerToken
            },
            targetIsOnline: CGDisplayIsOnline(targetDisplayID) != 0,
            targetIsActive: CGDisplayIsActive(targetDisplayID) != 0,
            targetBounds: CGDisplayBounds(targetDisplayID),
            targetOwnerToken: Self.ownerToken(for: targetDisplayID)
        )
    }

    func mirror(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) throws {
        try configureMirror(
            targetDisplayID: targetDisplayID,
            sourceDisplayID: sourceDisplayID
        )
    }

    func stageUnmirrored(
        targetDisplayID: UInt32,
        origin: CGPoint,
        expectedOwnerToken: UInt
    ) throws {
        let beforeOwnerToken = Self.ownerToken(for: targetDisplayID)
        guard beforeOwnerToken == expectedOwnerToken else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayOwnershipLost(
                targetDisplayID,
                expectedOwnerToken,
                beforeOwnerToken
            )
        }
        try configureMirror(
            targetDisplayID: targetDisplayID,
            sourceDisplayID: kCGNullDirectDisplay,
            origin: origin,
            scope: Self.desktopMirrorStageConfigurationScope
        )
        let afterOwnerToken = Self.ownerToken(for: targetDisplayID)
        guard afterOwnerToken == expectedOwnerToken else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayOwnershipLost(
                targetDisplayID,
                expectedOwnerToken,
                afterOwnerToken
            )
        }
    }

    func unmirror(targetDisplayID: UInt32) throws {
        guard CGDisplayMirrorsDisplay(targetDisplayID) != kCGNullDirectDisplay else {
            return
        }
        try configureMirror(
            targetDisplayID: targetDisplayID,
            sourceDisplayID: kCGNullDirectDisplay
        )
    }

    private func configureMirror(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32,
        origin: CGPoint? = nil,
        scope: CGConfigureOption = Self.desktopMirrorConfigurationScope
    ) throws {
        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                beginResult.rawValue
            )
        }
        do {
            let mirrorResult = CGConfigureDisplayMirrorOfDisplay(
                configuration,
                targetDisplayID,
                sourceDisplayID
            )
            guard mirrorResult == .success else {
                throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                    mirrorResult.rawValue
                )
            }
            if let origin {
                let roundedX = origin.x.rounded(.up)
                let roundedY = origin.y.rounded(.down)
                guard roundedX.isFinite,
                      roundedY.isFinite,
                      roundedX >= CGFloat(Int32.min),
                      roundedX <= CGFloat(Int32.max),
                      roundedY >= CGFloat(Int32.min),
                      roundedY <= CGFloat(Int32.max) else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(-1)
                }
                let originResult = CGConfigureDisplayOrigin(
                    configuration,
                    targetDisplayID,
                    Int32(Int64(roundedX)),
                    Int32(Int64(roundedY))
                )
                guard originResult == .success else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                        originResult.rawValue
                    )
                }
            }
            let completeResult = CGCompleteDisplayConfiguration(
                configuration,
                scope
            )
            guard completeResult == .success else {
                throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                    completeResult.rawValue
                )
            }
        } catch {
            CGCancelDisplayConfiguration(configuration)
            throw error
        }
    }

    private static func ownerToken(for displayID: UInt32) -> UInt? {
        LumenMacVirtualDisplay.registeredDisplay(forDisplayID: displayID).map {
            LumenRetainedVirtualDisplayReference(display: $0).ownerToken
        }
    }
}

@frozen public enum LumenMacDisplayPromotionConvergence: Equatable, Sendable {
    case deferredUntilCaptureReady
    case required
}

public protocol LumenMacDisplayWorkspaceManaging: Sendable {
    func snapshotWorkspace(
        targetProcessIdentifiers: [Int32],
        recoveryGeneration: UInt64
    ) async throws -> LumenMacPhysicalDisplayTopology
    @discardableResult
    func promoteVirtualDisplay(
        _ displayID: UInt32,
        logicalSize: CGSize,
        convergence: LumenMacDisplayPromotionConvergence
    ) async throws -> Bool
    func stageVirtualDisplayUnmirrored(
        _ displayID: UInt32,
        sourceDisplayID: UInt32
    ) async throws
    func mirrorOwnedVirtualDisplay(
        _ displayID: UInt32,
        sourceDisplayID: UInt32
    ) async throws
    func moveTargetWindows(to displayID: UInt32) async throws
    func isolateVirtualDisplay(_ displayID: UInt32) async throws
    func restoreWorkspace(
        _ topology: LumenMacPhysicalDisplayTopology,
        recoveryGeneration: UInt64
    ) async throws
    func verifyWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async throws
    func discardSnapshot() async
}

public actor LumenMacDisplayWorkspace: LumenMacDisplayWorkspaceManaging {
    private static let promotionConvergenceTimeout: TimeInterval = 5
    private static let promotionPollNanoseconds: UInt64 = 50_000_000
    private static let desktopMirrorConvergenceTimeout: TimeInterval = 5
    private static let desktopMirrorPollNanoseconds: UInt64 = 50_000_000
    private static let restorePublicationConvergenceTimeout: Duration = .seconds(5)
    private static let restorePublicationPollInterval: Duration = .milliseconds(50)
    private static let wakeStableObservationCount = 9
    private static let wakeMaximumObservationCount = 24
    private static let physicalDisplayWakePollInterval: Duration = .milliseconds(250)
    private static let postRecoveryWakeLeaseDuration: Duration = .seconds(600)

    private struct WindowSnapshot {
        let processID: Int32
        let windowID: UInt32
        let element: AXUIElement
        let position: CGPoint
        let size: CGSize

        var persisted: LumenMacWorkspaceWindowState {
            LumenMacWorkspaceWindowState(
                processID: processID,
                windowID: windowID,
                originX: Int32(clamping: Int64(position.x.rounded())),
                originY: Int32(clamping: Int64(position.y.rounded())),
                width: UInt32(clamping: Int64(size.width.rounded())),
                height: UInt32(clamping: Int64(size.height.rounded()))
            )
        }
    }

    private struct Snapshot {
        let topology: LumenMacPhysicalDisplayTopology
        let windows: [WindowSnapshot]
    }

    private struct DesktopMirrorStageGeometry {
        let physicalDisplayIDs: [CGDirectDisplayID]
        let physicalBounds: [CGRect]
        let targetOrigin: CGPoint
    }

    private let topologyController: any LumenMacDisplayTopologyControlling
    private let mirrorController: any LumenMacDisplayMirrorControlling
    private let physicalDisplayController: any LumenPhysicalDisplayControlling
    private let disconnectCapabilityVerifier: any LumenDisplayDisconnectCapabilityVerifying
    private let physicalDisplayWakeSignal: any LumenPhysicalDisplayWakeSignaling
    private let disconnectRecoveryStore: LumenDisconnectRecoveryFileStore
    private let disconnectRecoveryEnvironment:
        @Sendable () throws -> LumenDisconnectRecoveryEnvironment
    private var snapshot: Snapshot?
    private var snapshotRecoveryGeneration: UInt64?
    private var pendingDisconnectRecoveryRecord: LumenDisconnectRecoveryRecord?
    private var pendingRecoveryWakeAssertion:
        (any LumenPhysicalDisplayWakeAssertion)?
    private var mirroredDisplayIDs: (
        physicalTargetDisplayID: UInt32,
        sessionSourceDisplayID: UInt32
    )?

    public init() {
        topologyController = LumenCoreGraphicsDisplayTopologyController()
        mirrorController = LumenCoreGraphicsDisplayMirrorController()
        physicalDisplayController = LumenPhysicalDisplayControlAdapter(
            resolver: LumenSystemDisplayEnabledSymbolResolver()
        )
        disconnectCapabilityVerifier = LumenDisplayDisconnectCapabilityFileVerifier.production
        physicalDisplayWakeSignal = LumenSystemPhysicalDisplayWakeSignal()
        disconnectRecoveryStore = .production
        disconnectRecoveryEnvironment = {
            try LumenDisconnectRecoveryEnvironment.current()
        }
    }

    init(
        topologyController: any LumenMacDisplayTopologyControlling,
        mirrorController: any LumenMacDisplayMirrorControlling =
            LumenCoreGraphicsDisplayMirrorController(),
        physicalDisplayController: any LumenPhysicalDisplayControlling =
            LumenPhysicalDisplayControlAdapter(
                resolver: LumenSystemDisplayEnabledSymbolResolver()
            ),
        disconnectCapabilityVerifier: any LumenDisplayDisconnectCapabilityVerifying,
        physicalDisplayWakeSignal: any LumenPhysicalDisplayWakeSignaling,
        disconnectRecoveryStore: LumenDisconnectRecoveryFileStore,
        disconnectRecoveryEnvironment: @escaping @Sendable () throws ->
            LumenDisconnectRecoveryEnvironment
    ) {
        self.topologyController = topologyController
        self.mirrorController = mirrorController
        self.physicalDisplayController = physicalDisplayController
        self.disconnectCapabilityVerifier = disconnectCapabilityVerifier
        self.physicalDisplayWakeSignal = physicalDisplayWakeSignal
        self.disconnectRecoveryStore = disconnectRecoveryStore
        self.disconnectRecoveryEnvironment = disconnectRecoveryEnvironment
    }

    public func snapshotWorkspace(
        targetProcessIdentifiers: [Int32],
        recoveryGeneration: UInt64
    ) async throws -> LumenMacPhysicalDisplayTopology {
        guard snapshot == nil else {
            throw LumenMacDisplayWorkspaceError.snapshotAlreadyExists
        }

        let topology = try await topologyController.capture()
        let windows = try snapshotWindows(
            processIdentifiers: targetProcessIdentifiers.map { pid_t($0) }
        )
        let durableTopology = LumenMacPhysicalDisplayTopology(
            displays: topology.displays,
            macWindows: windows.map(\.persisted),
            windowsAdapterLUID: topology.windowsAdapterLUID,
            windowsTargetPaths: topology.windowsTargetPaths
        )
        snapshot = Snapshot(topology: durableTopology, windows: windows)
        snapshotRecoveryGeneration = recoveryGeneration
        return durableTopology
    }

    public func snapshotWorkspace(
        targetProcessIdentifiers: [Int32]
    ) async throws -> LumenMacPhysicalDisplayTopology {
        try await snapshotWorkspace(
            targetProcessIdentifiers: targetProcessIdentifiers,
            recoveryGeneration: 0
        )
    }

    @discardableResult
    public func promoteVirtualDisplay(
        _ displayID: UInt32,
        logicalSize: CGSize,
        convergence: LumenMacDisplayPromotionConvergence
    ) async throws -> Bool {
        guard let snapshot else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }
        let requiredActiveDisplayIDs: Set<CGDirectDisplayID> = Set(
            snapshot.topology.displays.compactMap { state -> CGDirectDisplayID? in
                guard state.active, state.online else {
                    return nil
                }
                return UInt32(state.id)
            }
        )
        let visibleDisplayIDs = await topologyController.visibleDisplayIDs()
        let activeDisplayIDs = try activeDisplayIDs()
        guard let ids = Self.promotionDisplayIDs(
            displayID: displayID,
            visibleDisplayIDs: visibleDisplayIDs,
            activeDisplayIDs: activeDisplayIDs,
            exactDisplayIsOnline: CGDisplayIsOnline(displayID) != 0,
            exactDisplayIsActive: CGDisplayIsActive(displayID) != 0
        ) else {
            return false
        }

        let boundsByDisplayID = Dictionary(
            uniqueKeysWithValues: ids.map { ($0, CGDisplayBounds($0)) }
        )
        let builtInDisplayIDs = Set(ids.filter { CGDisplayIsBuiltin($0) != 0 })
        guard let placements = Self.promotionPlacements(
            displayID: displayID,
            displayIDs: ids,
            boundsByDisplayID: boundsByDisplayID,
            builtInDisplayIDs: builtInDisplayIDs,
            targetSize: logicalSize
        ) else {
            return false
        }
        try configureDisplays { configuration in
            for activeDisplayID in ids {
                let result = CGConfigureDisplayMirrorOfDisplay(
                    configuration,
                    activeDisplayID,
                    kCGNullDirectDisplay
                )
                guard result == .success else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                        result.rawValue
                    )
                }
            }
            for placement in placements {
                let result = CGConfigureDisplayOrigin(
                    configuration,
                    placement.displayID,
                    Int32(clamping: Int64(placement.origin.x.rounded())),
                    Int32(clamping: Int64(placement.origin.y.rounded()))
                )
                guard result == .success else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                        result.rawValue
                    )
                }
            }
        }
        guard case .required = convergence else {
            logPromotionState(
                displayID: displayID,
                mainDisplayID: CGMainDisplayID(),
                activeDisplayIDs: activeDisplayIDs,
                targetBounds: CGDisplayBounds(displayID),
                result: "configured-pending-capture-readiness"
            )
            return true
        }
        return try await waitForPromotionConvergence(
            displayID: displayID,
            requiredActiveDisplayIDs: requiredActiveDisplayIDs
        )
    }

    nonisolated static func promotionDisplayIDs(
        displayID: CGDirectDisplayID,
        visibleDisplayIDs: Set<CGDirectDisplayID>,
        activeDisplayIDs: [CGDirectDisplayID],
        exactDisplayIsOnline: Bool,
        exactDisplayIsActive: Bool
    ) -> [CGDirectDisplayID]? {
        guard (
            visibleDisplayIDs.contains(displayID) &&
                activeDisplayIDs.contains(displayID)
        ) ||
            (exactDisplayIsOnline && exactDisplayIsActive)
        else {
            return nil
        }
        guard !activeDisplayIDs.contains(displayID) else {
            return activeDisplayIDs
        }
        return activeDisplayIDs + [displayID]
    }

    nonisolated static func promotionPlacements(
        displayID: CGDirectDisplayID,
        displayIDs: [CGDirectDisplayID],
        boundsByDisplayID: [CGDirectDisplayID: CGRect],
        builtInDisplayIDs: Set<CGDirectDisplayID>,
        targetSize: CGSize
    ) -> [(displayID: CGDirectDisplayID, origin: CGPoint)]? {
        guard displayIDs.contains(displayID),
              targetSize.width > 0,
              targetSize.height > 0 else {
            return nil
        }
        let remaining = displayIDs
            .filter { $0 != displayID }
            .sorted { lhs, rhs in
                let lhsBuiltIn = builtInDisplayIDs.contains(lhs)
                let rhsBuiltIn = builtInDisplayIDs.contains(rhs)
                if lhsBuiltIn != rhsBuiltIn {
                    return lhsBuiltIn
                }
                return lhs < rhs
            }
        var nextX = targetSize.width
        var placements: [(displayID: CGDirectDisplayID, origin: CGPoint)] = [
            (displayID, .zero),
        ]
        for remainingDisplayID in remaining {
            guard let bounds = boundsByDisplayID[remainingDisplayID],
                  bounds.width > 0,
                  bounds.height > 0 else {
                return nil
            }
            placements.append((
                remainingDisplayID,
                CGPoint(x: nextX, y: 0)
            ))
            nextX += max(1, bounds.width)
        }
        return placements
    }

    nonisolated static func promotionIsComplete(
        displayID: CGDirectDisplayID,
        mainDisplayID: CGDirectDisplayID,
        activeDisplayIDs: [CGDirectDisplayID],
        requiredActiveDisplayIDs: Set<CGDirectDisplayID>,
        exactDisplayIsOnline: Bool,
        exactDisplayIsActive: Bool,
        boundsByDisplayID: [CGDirectDisplayID: CGRect]
    ) -> Bool {
        guard mainDisplayID == displayID,
              requiredActiveDisplayIDs.isSubset(of: Set(activeDisplayIDs)),
              exactDisplayIsOnline,
              exactDisplayIsActive,
              let targetBounds = boundsByDisplayID[displayID],
              targetBounds.width > 0,
              targetBounds.height > 0,
              targetBounds.origin.x.rounded() == 0,
              targetBounds.origin.y.rounded() == 0 else {
            return false
        }
        for activeDisplayID in activeDisplayIDs where activeDisplayID != displayID {
            guard let activeBounds = boundsByDisplayID[activeDisplayID],
                  activeBounds.width > 0,
                  activeBounds.height > 0,
                  !targetBounds.intersects(activeBounds) else {
                return false
            }
        }
        return true
    }

    public func moveTargetWindows(to displayID: UInt32) throws {
        guard let snapshot else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }
        guard !snapshot.windows.isEmpty else {
            return
        }
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else {
            throw LumenMacDisplayWorkspaceError.displayNotFound(displayID)
        }

        for (index, window) in snapshot.windows.enumerated() {
            let maximumSize = CGSize(
                width: max(1, bounds.width * 0.9),
                height: max(1, bounds.height * 0.9)
            )
            let size = CGSize(
                width: min(window.size.width, maximumSize.width),
                height: min(window.size.height, maximumSize.height)
            )
            let offset = CGFloat(index % 8) * 24
            let position = CGPoint(
                x: bounds.minX + max(0, (bounds.width - size.width) / 2) + offset,
                y: bounds.minY + max(0, (bounds.height - size.height) / 2) + offset
            )
            setWindowSize(size, on: window.element)
            setWindowPosition(position, on: window.element)
        }
    }

    public func mirrorOwnedVirtualDisplay(
        _ displayID: UInt32,
        sourceDisplayID: UInt32
    ) async throws {
        guard let snapshot else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }
        guard mirroredDisplayIDs == nil,
              displayID != 0,
              sourceDisplayID != 0,
              displayID != sourceDisplayID,
              snapshot.topology.displays.contains(where: { state in
                  state.id == String(sourceDisplayID) &&
                      state.enabled &&
                      state.active &&
                      state.online
              }) else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                displayID,
                sourceDisplayID
            )
        }
        let before = await mirrorController.state(
            targetDisplayID: sourceDisplayID,
            sourceDisplayID: displayID
        )
        logDesktopMirrorState(
            phase: "before",
            state: before,
            displayID: displayID,
            sourceDisplayID: sourceDisplayID
        )
        guard let expectedSourceOwnerToken = before.sourceOwnerToken,
              let expectedSourceSize = before.sourceConfiguredSize,
              Self.isValidDesktopMirrorPrecondition(
                  before,
                  displayID: displayID,
                  sourceDisplayID: sourceDisplayID,
                  expectedOwnerToken: expectedSourceOwnerToken,
                  expectedSourceSize: expectedSourceSize
              ) else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                displayID,
                sourceDisplayID
            )
        }

        try await topologyController.verify(snapshot.topology)
        let verifiedBefore = await mirrorController.state(
            targetDisplayID: sourceDisplayID,
            sourceDisplayID: displayID
        )
        guard Self.isValidDesktopMirrorPrecondition(
            verifiedBefore,
            displayID: displayID,
            sourceDisplayID: sourceDisplayID,
            expectedOwnerToken: expectedSourceOwnerToken,
            expectedSourceSize: expectedSourceSize
        ) else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                displayID,
                sourceDisplayID
            )
        }

        try await mirrorController.mirror(
            targetDisplayID: sourceDisplayID,
            sourceDisplayID: displayID
        )
        mirroredDisplayIDs = (
            physicalTargetDisplayID: sourceDisplayID,
            sessionSourceDisplayID: displayID
        )
        do {
            let after = try await waitForDesktopMirrorConvergence(
                displayID: displayID,
                sourceDisplayID: sourceDisplayID,
                expectedOwnerToken: expectedSourceOwnerToken,
                expectedSourceSize: expectedSourceSize
            )
            logDesktopMirrorState(
                phase: "after",
                state: after,
                displayID: displayID,
                sourceDisplayID: sourceDisplayID
            )
        } catch {
            let originalError = error
            do {
                try await releaseDesktopMirror(
                    targetDisplayID: sourceDisplayID,
                    topology: snapshot.topology
                )
            } catch {
                throw LumenMacDisplayWorkspaceError
                    .virtualDisplayMirrorRollbackFailed(displayID)
            }
            throw originalError
        }
    }

    nonisolated private static func isValidDesktopMirrorPrecondition(
        _ state: LumenMacDisplayMirrorState,
        displayID: UInt32,
        sourceDisplayID: UInt32,
        expectedOwnerToken: UInt,
        expectedSourceSize: CGSize
    ) -> Bool {
        state.mainDisplayID == sourceDisplayID &&
            state.mirrorSourceDisplayID == nil &&
            state.sourceIsOnline &&
            state.sourceIsActive &&
            state.sourceIsOwnedVirtualDisplay &&
            Self.hasUsableDisplayBounds(state.sourceBounds) &&
            state.sourceBounds.size == expectedSourceSize &&
            state.sourceConfiguredSize == expectedSourceSize &&
            expectedSourceSize.width > 0 &&
            expectedSourceSize.height > 0 &&
            state.sourceOwnerToken == expectedOwnerToken &&
            state.targetIsOnline &&
            state.targetIsActive &&
            state.targetOwnerToken == nil &&
            displayID != sourceDisplayID
    }

    nonisolated private static func isValidDesktopMirrorPostcondition(
        _ state: LumenMacDisplayMirrorState,
        displayID: UInt32,
        expectedOwnerToken: UInt,
        expectedSourceSize: CGSize
    ) -> Bool {
        state.mainDisplayID == displayID &&
            state.mirrorSourceDisplayID == displayID &&
            state.sourceIsOnline &&
            state.sourceIsActive &&
            state.sourceIsOwnedVirtualDisplay &&
            Self.hasUsableDisplayBounds(state.sourceBounds) &&
            state.sourceBounds.size == expectedSourceSize &&
            state.sourceConfiguredSize == expectedSourceSize &&
            state.sourceOwnerToken == expectedOwnerToken &&
            state.targetIsOnline &&
            state.targetOwnerToken == nil
    }

    private func waitForDesktopMirrorConvergence(
        displayID: UInt32,
        sourceDisplayID: UInt32,
        expectedOwnerToken: UInt,
        expectedSourceSize: CGSize
    ) async throws -> LumenMacDisplayMirrorState {
        let deadline = ProcessInfo.processInfo.systemUptime
            + Self.desktopMirrorConvergenceTimeout
        while true {
            try Task.checkCancellation()
            let state = await mirrorController.state(
                targetDisplayID: sourceDisplayID,
                sourceDisplayID: displayID
            )
            if Self.isValidDesktopMirrorPostcondition(
                state,
                displayID: displayID,
                expectedOwnerToken: expectedOwnerToken,
                expectedSourceSize: expectedSourceSize
            ) {
                return state
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                logDesktopMirrorState(
                    phase: "convergence-timeout",
                    state: state,
                    displayID: displayID,
                    sourceDisplayID: sourceDisplayID
                )
                throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                    displayID,
                    sourceDisplayID
                )
            }
            try await Task.sleep(
                nanoseconds: Self.desktopMirrorPollNanoseconds
            )
        }
    }

    public func stageVirtualDisplayUnmirrored(
        _ displayID: UInt32,
        sourceDisplayID: UInt32
    ) async throws {
        guard let snapshot else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }
        guard displayID != 0,
              sourceDisplayID != 0,
              displayID != sourceDisplayID,
              snapshot.topology.displays.contains(where: { state in
                  state.id == String(sourceDisplayID) &&
                      state.enabled &&
                      state.active &&
                      state.online
              }) else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                displayID,
                sourceDisplayID
            )
        }
        let before = await mirrorController.state(
            targetDisplayID: displayID,
            sourceDisplayID: sourceDisplayID
        )
        guard Self.isAdmissibleDesktopMirrorStageInitialState(
            before,
            targetDisplayID: displayID,
            sourceDisplayID: sourceDisplayID
        ) else {
            logDesktopMirrorState(
                phase: "stage-initial-rejected",
                state: before,
                displayID: displayID,
                sourceDisplayID: sourceDisplayID
            )
            throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                displayID,
                sourceDisplayID
            )
        }
        guard let expectedOwnerToken = before.targetOwnerToken else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayOwnershipLost(
                displayID,
                0,
                nil
            )
        }
        let geometry = try await desktopMirrorStageGeometry(
            topology: snapshot.topology,
            displayID: displayID,
            sourceDisplayID: sourceDisplayID,
            preferPersistedBounds: before.mainDisplayID == displayID,
            preferredTargetWidth: Self.hasUsableDisplayBounds(before.targetBounds)
                ? before.targetBounds.width
                : nil
        )

        var targetTransactionAttempted = false
        do {
            let readyState = before
            if Self.isValidDesktopMirrorStageState(
                readyState,
                targetDisplayID: displayID,
                sourceDisplayID: sourceDisplayID,
                physicalBounds: geometry.physicalBounds,
                targetOrigin: geometry.targetOrigin,
                expectedOwnerToken: expectedOwnerToken
            ) {
                try await topologyController.verify(snapshot.topology)
                let preservedState = await mirrorController.state(
                    targetDisplayID: displayID,
                    sourceDisplayID: sourceDisplayID
                )
                guard Self.isValidDesktopMirrorStageState(
                    preservedState,
                    targetDisplayID: displayID,
                    sourceDisplayID: sourceDisplayID,
                    physicalBounds: geometry.physicalBounds,
                    targetOrigin: geometry.targetOrigin,
                    expectedOwnerToken: expectedOwnerToken
                ) else {
                    throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                        displayID,
                        sourceDisplayID
                    )
                }
                logDesktopMirrorStageReady(
                    displayID: displayID,
                    ownerToken: expectedOwnerToken,
                    targetBounds: preservedState.targetBounds,
                    physicalDisplayIDs: geometry.physicalDisplayIDs,
                    placement: "preserved"
                )
                return
            }
            targetTransactionAttempted = true
            try await mirrorController.stageUnmirrored(
                targetDisplayID: displayID,
                origin: geometry.targetOrigin,
                expectedOwnerToken: expectedOwnerToken
            )
            guard try await waitForDesktopMirrorConvergence(
                targetDisplayID: displayID,
                sourceDisplayID: sourceDisplayID,
                physicalDisplayIDs: geometry.physicalDisplayIDs,
                physicalBounds: geometry.physicalBounds,
                expectedOwnerToken: expectedOwnerToken
            ) else {
                throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                    displayID,
                    sourceDisplayID
                )
            }
            try await topologyController.verify(snapshot.topology)
            let finalState = await mirrorController.state(
                targetDisplayID: displayID,
                sourceDisplayID: sourceDisplayID
            )
            let finalPhysicalBounds = try await currentDesktopMirrorPhysicalBounds(
                displayIDs: geometry.physicalDisplayIDs,
                fallback: geometry.physicalBounds
            )
            guard Self.isValidDesktopMirrorStageState(
                finalState,
                targetDisplayID: displayID,
                sourceDisplayID: sourceDisplayID,
                physicalBounds: finalPhysicalBounds,
                targetOrigin: nil,
                expectedOwnerToken: expectedOwnerToken
            ) else {
                throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                    displayID,
                    sourceDisplayID
                )
            }
            logDesktopMirrorStageReady(
                displayID: displayID,
                ownerToken: expectedOwnerToken,
                targetBounds: finalState.targetBounds,
                physicalDisplayIDs: geometry.physicalDisplayIDs,
                placement: "configured"
            )
        } catch {
            let originalError = error
            guard targetTransactionAttempted else {
                throw originalError
            }
            do {
                try await restoreStageTopologyIfNeeded(snapshot.topology)
            } catch {
                throw LumenMacDisplayWorkspaceError
                    .virtualDisplayMirrorRollbackFailed(displayID)
            }
            throw originalError
        }
    }

    nonisolated static func isValidDesktopMirrorState(
        _ state: LumenMacDisplayMirrorState,
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32,
        requireUnmirrored: Bool,
        requireTargetReady: Bool = true,
        expectedOwnerToken: UInt? = nil
    ) -> Bool {
        guard state.mainDisplayID == sourceDisplayID,
              state.sourceIsOnline,
              state.sourceIsActive,
              !state.sourceIsOwnedVirtualDisplay else {
            return false
        }
        if requireTargetReady,
           (!state.targetIsOnline || !state.targetIsActive) {
            return false
        }
        if requireUnmirrored {
            guard state.mirrorSourceDisplayID == nil else {
                return false
            }
        }
        if let expectedOwnerToken,
           state.targetOwnerToken != expectedOwnerToken {
            return false
        }
        return targetDisplayID != sourceDisplayID
    }

    nonisolated static func isAdmissibleDesktopMirrorStageInitialState(
        _ state: LumenMacDisplayMirrorState,
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) -> Bool {
        if isValidDesktopMirrorState(
            state,
            targetDisplayID: targetDisplayID,
            sourceDisplayID: sourceDisplayID,
            requireUnmirrored: false,
            requireTargetReady: false
        ) {
            return true
        }
        return targetDisplayID != sourceDisplayID &&
            state.mainDisplayID == targetDisplayID &&
            state.sourceIsOnline &&
            !state.sourceIsOwnedVirtualDisplay &&
            state.targetIsOnline &&
            state.targetIsActive &&
            state.targetOwnerToken != nil
    }

    private func desktopMirrorStageGeometry(
        topology: LumenMacPhysicalDisplayTopology,
        displayID: UInt32,
        sourceDisplayID: UInt32,
        preferPersistedBounds: Bool = false,
        preferredTargetWidth: CGFloat? = nil
    ) async throws -> DesktopMirrorStageGeometry {
        let unavailable = LumenMacDisplayWorkspaceError
            .virtualDisplayMirrorUnavailable(displayID, sourceDisplayID)
        let resolvedIDs = try await topologyController.resolvedDisplayIDs(for: topology)
        let physicalDisplayIDs = try topology.displays.map { state -> CGDirectDisplayID in
            guard let resolvedID = resolvedIDs[state.id] else {
                throw LumenMacDisplayWorkspaceError.invalidPersistedDisplayID(state.id)
            }
            return resolvedID
        }
        guard !physicalDisplayIDs.isEmpty else {
            throw unavailable
        }
        let boundsByDisplayID = try await mirrorController.displayBounds(
            for: physicalDisplayIDs
        )
        guard !physicalDisplayIDs.contains(displayID) else {
            throw unavailable
        }
        let physicalBounds = zip(topology.displays, physicalDisplayIDs).compactMap {
            state,
            resolvedID -> CGRect? in
            if !preferPersistedBounds,
               let currentBounds = boundsByDisplayID[resolvedID],
               Self.hasUsableDisplayBounds(currentBounds) {
                return currentBounds
            }
            let persistedBounds = CGRect(
                x: CGFloat(state.originX),
                y: CGFloat(state.originY),
                width: CGFloat(state.mode.width),
                height: CGFloat(state.mode.height)
            )
            return Self.hasUsableDisplayBounds(persistedBounds)
                ? persistedBounds
                : nil
        }
        guard physicalBounds.count == physicalDisplayIDs.count,
              !physicalBounds.isEmpty else {
            throw unavailable
        }
        let union = physicalBounds.dropFirst().reduce(physicalBounds[0]) {
            $0.union($1)
        }
        let targetOriginX = preferredTargetWidth.map {
            (union.minX - $0).rounded(.down)
        } ?? union.maxX.rounded(.up)
        let targetOrigin = CGPoint(
            x: targetOriginX,
            y: union.minY.rounded(.down)
        )
        guard Self.hasValidDisplayOrigin(targetOrigin) else {
            throw unavailable
        }
        return DesktopMirrorStageGeometry(
            physicalDisplayIDs: physicalDisplayIDs,
            physicalBounds: physicalBounds,
            targetOrigin: targetOrigin
        )
    }

    nonisolated private static func hasUsableDisplayBounds(_ bounds: CGRect) -> Bool {
        bounds.width.isFinite &&
            bounds.height.isFinite &&
            bounds.origin.x.isFinite &&
            bounds.origin.y.isFinite &&
            bounds.width > 0 &&
            bounds.height > 0
    }

    nonisolated private static func hasValidDisplayOrigin(_ origin: CGPoint) -> Bool {
        let roundedX = origin.x.rounded(.up)
        let roundedY = origin.y.rounded(.down)
        return roundedX.isFinite &&
            roundedY.isFinite &&
            roundedX >= CGFloat(Int32.min) &&
            roundedX <= CGFloat(Int32.max) &&
            roundedY >= CGFloat(Int32.min) &&
            roundedY <= CGFloat(Int32.max)
    }

    nonisolated static func isValidDesktopMirrorStageState(
        _ state: LumenMacDisplayMirrorState,
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32,
        physicalBounds: [CGRect],
        targetOrigin: CGPoint?,
        expectedOwnerToken: UInt
    ) -> Bool {
        guard isValidDesktopMirrorState(
            state,
            targetDisplayID: targetDisplayID,
            sourceDisplayID: sourceDisplayID,
            requireUnmirrored: true,
            requireTargetReady: true,
            expectedOwnerToken: expectedOwnerToken
        ),
        hasUsableDisplayBounds(state.targetBounds),
        physicalBounds.allSatisfy({ !$0.intersects(state.targetBounds) }) else {
            return false
        }
        if let targetOrigin,
           (state.targetBounds.origin.x.rounded(.up) != targetOrigin.x.rounded(.up) ||
               state.targetBounds.origin.y.rounded(.down) != targetOrigin.y.rounded(.down)) {
            return false
        }
        return true
    }

    public func isolateVirtualDisplay(_ displayID: UInt32) async throws {
        guard let snapshot,
              let snapshotRecoveryGeneration else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }
        var attemptedDisplayIDs: [CGDirectDisplayID] = []
        do {
            let currentTopology = try await topologyController.capture()
            let physicalDisplays = try lumenCurrentPhysicalDisplays(
                snapshot: snapshot.topology,
                current: currentTopology,
                sessionDisplayID: displayID
            )
            try await verifyOnlineDisplayFence(
                physicalDisplays: physicalDisplays,
                sessionDisplayID: displayID
            )
            let probe = try physicalDisplayController.probe()
            try disconnectCapabilityVerifier.authorize(
                probe: probe,
                physicalDisplays: physicalDisplays
            )
            let confirmedDisplays = try lumenCurrentPhysicalDisplays(
                snapshot: snapshot.topology,
                current: try await topologyController.capture(),
                sessionDisplayID: displayID
            )
            guard confirmedDisplays == physicalDisplays else {
                throw LumenPhysicalDisplayControlFailure(
                    code: .physicalDisplayDisconnectUnverified
                )
            }
            try await verifyOnlineDisplayFence(
                physicalDisplays: confirmedDisplays,
                sessionDisplayID: displayID
            )
            let physicalDisplayIDs = physicalDisplays.map(\.displayID)
            var recoveryRecord = try LumenDisconnectRecoveryRecord.staged(
                environment: disconnectRecoveryEnvironment(),
                recoveryGeneration: snapshotRecoveryGeneration,
                topology: snapshot.topology,
                physicalDisplays: physicalDisplays
            )
            try disconnectRecoveryStore.persist(recoveryRecord)
            do {
                for physicalDisplayID in physicalDisplayIDs {
                    recoveryRecord = recoveryRecord.updating(
                        displayID: physicalDisplayID,
                        phase: .disableAttempted
                    )
                    try disconnectRecoveryStore.persist(recoveryRecord)
                    attemptedDisplayIDs.append(physicalDisplayID)
                    _ = try physicalDisplayController.setEnabled(false, for: physicalDisplayID)
                    recoveryRecord = recoveryRecord.updating(
                        displayID: physicalDisplayID,
                        phase: .disableSucceeded
                    )
                    try disconnectRecoveryStore.persist(recoveryRecord)
                }
                try await verifyIsolation(
                    physicalDisplayIDs: Set(physicalDisplayIDs)
                )
            } catch {
                do {
                    for physicalDisplayID in attemptedDisplayIDs.reversed() {
                        _ = try physicalDisplayController.setEnabled(true, for: physicalDisplayID)
                    }
                    try await topologyController.restore(snapshot.topology)
                    try await topologyController.verify(snapshot.topology)
                    try disconnectRecoveryStore.revoke()
                } catch {
                    throw LumenMacDisplayWorkspaceError.isolationRollbackFailed
                }
                throw error
            }
        } catch LumenMacDisplayWorkspaceError.isolationRollbackFailed {
            throw LumenMacDisplayWorkspaceError.isolationRollbackFailed
        } catch {
            let message = (error as? any LocalizedError)?.errorDescription
                ?? String(describing: error)
            throw LumenMacDisplayWorkspaceError.isolationUnavailable(message)
        }
    }

    public func restoreWorkspace(
        _ topology: LumenMacPhysicalDisplayTopology,
        recoveryGeneration: UInt64
    ) async throws {
        if pendingRecoveryWakeAssertion == nil {
            pendingRecoveryWakeAssertion = try physicalDisplayWakeSignal
                .acquireUserActivityAssertion()
        }
        if let mirroredDisplayIDs {
            do {
                try await releaseDesktopMirror(
                    targetDisplayID: mirroredDisplayIDs.physicalTargetDisplayID,
                    topology: topology
                )
            } catch {
                throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorRollbackFailed(
                    mirroredDisplayIDs.sessionSourceDisplayID
                )
            }
        }
        let physicalTopologyAlreadyRestored =
            (try? await topologyController.verify(topology)) != nil
        let disconnectRecoveryRecord = try disconnectRecoveryStore.load()
        var requestedDurableEnableRecovery = false
        if let disconnectRecoveryRecord {
            guard try disconnectRecoveryRecord.matches(
                recoveryGeneration: recoveryGeneration,
                topology: topology
            ) else {
                throw LumenMacDisplayWorkspaceError.isolationUnavailable(
                    "physical display recovery ownership could not be verified"
                )
            }
            let currentEnvironment = try disconnectRecoveryEnvironment()
            if disconnectRecoveryRecord.environment == currentEnvironment {
                var entriesToEnable = disconnectRecoveryRecord.entries.filter {
                    $0.phase.requiresEnableRecovery
                }
                if !entriesToEnable.isEmpty {
                    _ = try physicalDisplayController.probe()
                }
                do {
                    for entry in entriesToEnable {
                        _ = try physicalDisplayController.setEnabled(
                            true,
                            for: entry.display.displayID
                        )
                    }
                } catch {
                    guard let resolvedIDs = try? await resolveDisplayIDsAfterDurableEnable(
                        topology
                    ),
                    await recoveryDisplaysAreVisible(
                        entriesToEnable,
                        topology: topology,
                        resolvedIDs: resolvedIDs
                    ) else {
                        throw error
                    }
                    entriesToEnable.removeAll(keepingCapacity: false)
                }
                requestedDurableEnableRecovery = !entriesToEnable.isEmpty
            }
            pendingDisconnectRecoveryRecord = disconnectRecoveryRecord
        }
        if !physicalTopologyAlreadyRestored || requestedDurableEnableRecovery {
            let resolvedIDs = if requestedDurableEnableRecovery {
                try await resolveDisplayIDsAfterDurableEnable(topology)
            } else {
                try await topologyController.resolvedDisplayIDs(for: topology)
            }
            let expectedDisplays = try topology.displays.map { state -> (CGDirectDisplayID, LumenMacPhysicalDisplayState) in
                guard let displayID = resolvedIDs[state.id] else {
                    throw LumenMacDisplayWorkspaceError.invalidPersistedDisplayID(state.id)
                }
                return (displayID, state)
            }
            let visibleDisplayIDs = await topologyController.visibleDisplayIDs()
            let displaysToEnable = expectedDisplays.filter { displayID, state in
                (state.enabled || state.active) && !visibleDisplayIDs.contains(displayID)
            }
            if !displaysToEnable.isEmpty {
                _ = try physicalDisplayController.probe()
            }
            for (displayID, _) in displaysToEnable {
                _ = try physicalDisplayController.setEnabled(true, for: displayID)
            }
            try await topologyController.restore(topology)
        }
        let windows: [WindowSnapshot]
        if let snapshot {
            windows = snapshot.windows
        } else {
            windows = try resolvePersistedWindows(topology.macWindows)
        }
        for window in windows {
            setWindowSize(window.size, on: window.element)
            setWindowPosition(window.position, on: window.element)
        }
    }

    private func recoveryDisplaysAreVisible(
        _ entries: [LumenDisconnectRecoveryEntry],
        topology: LumenMacPhysicalDisplayTopology,
        resolvedIDs: [String: CGDirectDisplayID]
    ) async -> Bool {
        let visibleDisplayIDs = await topologyController.visibleDisplayIDs()
        let visiblePhysicalIdentities: Set<
            LumenDisplayDisconnectCapabilityDisplay.StableIdentity
        > = Set(
            topology.displays.compactMap { state
                -> LumenDisplayDisconnectCapabilityDisplay.StableIdentity? in
                guard let displayID = resolvedIDs[state.id],
                      visibleDisplayIDs.contains(displayID),
                      let vendorID = state.vendorID,
                      let productID = state.productID,
                      let serialNumber = state.serialNumber,
                      let builtin = state.builtin else {
                    return nil
                }
                return LumenDisplayDisconnectCapabilityDisplay.StableIdentity(
                    vendorID: vendorID,
                    productID: productID,
                    serialNumber: serialNumber,
                    builtin: builtin
                )
            }
        )
        return entries.allSatisfy { entry in
            visiblePhysicalIdentities.contains(entry.display.stableIdentity)
        }
    }

    private func resolveDisplayIDsAfterDurableEnable(
        _ topology: LumenMacPhysicalDisplayTopology
    ) async throws -> [String: CGDirectDisplayID] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: Self.restorePublicationConvergenceTimeout
        )
        var lastError: (any Error)?
        repeat {
            do {
                return try await topologyController.resolvedDisplayIDs(
                    for: topology
                )
            } catch {
                lastError = error
            }
            try await Task.sleep(for: Self.restorePublicationPollInterval)
        } while clock.now < deadline
        throw lastError ?? LumenMacDisplayWorkspaceError.physicalTopologyMismatch
    }

    public func restoreWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async throws {
        try await restoreWorkspace(
            topology,
            recoveryGeneration: snapshotRecoveryGeneration ?? 0
        )
    }

    public func verifyWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async throws {
        let inheritedWakeAssertion = pendingRecoveryWakeAssertion != nil
        let wakeAssertion: any LumenPhysicalDisplayWakeAssertion
        if let pendingRecoveryWakeAssertion {
            wakeAssertion = pendingRecoveryWakeAssertion
        } else {
            wakeAssertion = try physicalDisplayWakeSignal
                .acquireUserActivityAssertion()
        }
        pendingRecoveryWakeAssertion = nil
        var retainWakeAssertionAfterVerification = false
        defer {
            if retainWakeAssertionAfterVerification {
                physicalDisplayWakeSignal.retainUserActivityAssertion(
                    wakeAssertion,
                    for: Self.postRecoveryWakeLeaseDuration
                )
            } else if inheritedWakeAssertion {
                pendingRecoveryWakeAssertion = wakeAssertion
            } else {
                wakeAssertion.release()
            }
        }
        try await topologyController.verify(topology)
        try physicalDisplayWakeSignal.pulseUserActivity()
        try await waitForPhysicalDisplaysToWake(topology)
        retainWakeAssertionAfterVerification = true
        for expected in try resolvePersistedWindows(topology.macWindows) {
            guard let actualPosition = windowPoint(
                attribute: kAXPositionAttribute,
                element: expected.element
            ),
            let actualSize = windowSize(
                attribute: kAXSizeAttribute,
                element: expected.element
            ),
            Int32(clamping: Int64(actualPosition.x.rounded()))
                == Int32(clamping: Int64(expected.position.x.rounded())),
            Int32(clamping: Int64(actualPosition.y.rounded()))
                == Int32(clamping: Int64(expected.position.y.rounded())),
            UInt32(clamping: Int64(actualSize.width.rounded()))
                == UInt32(clamping: Int64(expected.size.width.rounded())),
            UInt32(clamping: Int64(actualSize.height.rounded()))
                == UInt32(clamping: Int64(expected.size.height.rounded())) else {
                throw LumenMacDisplayWorkspaceError.windowTopologyMismatch(
                    expected.processID,
                    expected.windowID
                )
            }
        }
        if let pendingDisconnectRecoveryRecord {
            guard try pendingDisconnectRecoveryRecord.matches(
                recoveryGeneration: pendingDisconnectRecoveryRecord.recoveryGeneration,
                topology: topology
            ) else {
                throw LumenMacDisplayWorkspaceError.isolationUnavailable(
                    "physical display recovery verification did not match its owner"
                )
            }
            try disconnectRecoveryStore.revoke()
            self.pendingDisconnectRecoveryRecord = nil
        }
        self.snapshot = nil
        snapshotRecoveryGeneration = nil
    }

    private func waitForPhysicalDisplaysToWake(
        _ topology: LumenMacPhysicalDisplayTopology
    ) async throws {
        let resolvedDisplayIDs = try await topologyController.resolvedDisplayIDs(
            for: topology
        )
        let activeDisplayIDs: [CGDirectDisplayID] =
            try topology.displays.compactMap { state in
            guard state.active, state.online else {
                return nil
            }
            guard let displayID = resolvedDisplayIDs[state.id] else {
                throw LumenMacDisplayWorkspaceError.invalidPersistedDisplayID(
                    state.id
                )
            }
            return displayID
        }
        guard !activeDisplayIDs.isEmpty else {
            return
        }

        var consecutiveAwakeObservations = 0
        for observation in 0 ..< Self.wakeMaximumObservationCount {
            let hasSleepingDisplay = activeDisplayIDs.contains {
                physicalDisplayWakeSignal.isDisplayAsleep($0)
            }
            if hasSleepingDisplay {
                consecutiveAwakeObservations = 0
                try physicalDisplayWakeSignal.pulseUserActivity()
            } else {
                consecutiveAwakeObservations += 1
                if consecutiveAwakeObservations >=
                    Self.wakeStableObservationCount {
                    return
                }
            }
            if observation + 1 < Self.wakeMaximumObservationCount {
                try await Task.sleep(
                    for: Self.physicalDisplayWakePollInterval
                )
            }
        }
        throw LumenMacDisplayWorkspaceError.physicalDisplayWakeTimeout(
            activeDisplayIDs
        )
    }

    public func discardSnapshot() {
        snapshot = nil
        snapshotRecoveryGeneration = nil
        pendingRecoveryWakeAssertion?.release()
        pendingRecoveryWakeAssertion = nil
    }

    private func restoreStageTopologyIfNeeded(
        _ topology: LumenMacPhysicalDisplayTopology
    ) async throws {
        guard (try? await topologyController.verify(topology)) == nil else {
            return
        }
        try await topologyController.restore(topology)
        try await topologyController.verify(topology)
    }

    private func logDesktopMirrorStageReady(
        displayID: UInt32,
        ownerToken: UInt,
        targetBounds: CGRect,
        physicalDisplayIDs: [CGDirectDisplayID],
        placement: String
    ) {
        let physicalIDs = physicalDisplayIDs
            .sorted()
            .map(String.init)
            .joined(separator: ",")
        let message =
            "Lumen desktop mirror stage " +
            "display-id=\(displayID) " +
            "owner-token=\(ownerToken) " +
            "target-origin=\(Int(targetBounds.origin.x.rounded()))," +
            "\(Int(targetBounds.origin.y.rounded())) " +
            "target-size=\(Int(targetBounds.width.rounded()))x" +
            "\(Int(targetBounds.height.rounded())) " +
            "physical-display-ids=\(physicalIDs) " +
            "placement=\(placement) result=ready\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func logDesktopMirrorState(
        phase: String,
        state: LumenMacDisplayMirrorState,
        displayID: UInt32,
        sourceDisplayID: UInt32
    ) {
        let mirrorSource = state.mirrorSourceDisplayID.map(String.init) ?? "none"
        let sourceOwnerToken = state.sourceOwnerToken.map(String.init) ?? "none"
        let targetOwnerToken = state.targetOwnerToken.map(String.init) ?? "none"
        let configuredSourceSize = state.sourceConfiguredSize.map {
            "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))"
        } ?? "none"
        let message =
            "Lumen desktop mirror state " +
            "phase=\(phase) " +
            "session-display-id=\(displayID) " +
            "physical-target-display-id=\(sourceDisplayID) " +
            "main-display-id=\(state.mainDisplayID) " +
            "mirror-source-id=\(mirrorSource) " +
            "session-online=\(state.sourceIsOnline) " +
            "session-active=\(state.sourceIsActive) " +
            "session-owned=\(state.sourceIsOwnedVirtualDisplay) " +
            "session-origin=\(Int(state.sourceBounds.origin.x.rounded()))," +
            "\(Int(state.sourceBounds.origin.y.rounded())) " +
            "session-size=\(Int(state.sourceBounds.width.rounded()))x" +
            "\(Int(state.sourceBounds.height.rounded())) " +
            "session-configured-size=\(configuredSourceSize) " +
            "session-owner-token=\(sourceOwnerToken) " +
            "physical-target-online=\(state.targetIsOnline) " +
            "physical-target-active=\(state.targetIsActive) " +
            "physical-target-origin=\(Int(state.targetBounds.origin.x.rounded()))," +
            "\(Int(state.targetBounds.origin.y.rounded())) " +
            "physical-target-size=\(Int(state.targetBounds.width.rounded()))x" +
            "\(Int(state.targetBounds.height.rounded())) " +
            "physical-target-owner-token=\(targetOwnerToken)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func releaseDesktopMirror(
        targetDisplayID: UInt32,
        topology: LumenMacPhysicalDisplayTopology
    ) async throws {
        try await mirrorController.unmirror(targetDisplayID: targetDisplayID)
        if (try? await topologyController.verify(topology)) == nil {
            try await topologyController.restore(topology)
        }
        try await topologyController.verify(topology)
        mirroredDisplayIDs = nil
    }

    private func waitForDesktopMirrorConvergence(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32,
        physicalDisplayIDs: [CGDirectDisplayID],
        physicalBounds: [CGRect],
        expectedOwnerToken: UInt
    ) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime
            + Self.desktopMirrorConvergenceTimeout
        while true {
            try Task.checkCancellation()
            let state = await mirrorController.state(
                targetDisplayID: targetDisplayID,
                sourceDisplayID: sourceDisplayID
            )
            let currentPhysicalBounds = try await currentDesktopMirrorPhysicalBounds(
                displayIDs: physicalDisplayIDs,
                fallback: physicalBounds
            )
            if Self.isValidDesktopMirrorStageState(
                state,
                targetDisplayID: targetDisplayID,
                sourceDisplayID: sourceDisplayID,
                physicalBounds: currentPhysicalBounds,
                targetOrigin: nil,
                expectedOwnerToken: expectedOwnerToken
            ) {
                return true
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                logDesktopMirrorState(
                    phase: "stage-convergence-timeout",
                    state: state,
                    displayID: targetDisplayID,
                    sourceDisplayID: sourceDisplayID
                )
                return false
            }
            try await Task.sleep(nanoseconds: Self.desktopMirrorPollNanoseconds)
        }
    }

    private func currentDesktopMirrorPhysicalBounds(
        displayIDs: [CGDirectDisplayID],
        fallback: [CGRect]
    ) async throws -> [CGRect] {
        let boundsByDisplayID = try await mirrorController.displayBounds(
            for: displayIDs
        )
        let current = displayIDs.compactMap { boundsByDisplayID[$0] }
        guard current.count == displayIDs.count,
              current.allSatisfy(Self.hasUsableDisplayBounds) else {
            return fallback
        }
        return current
    }

    private func verifyIsolation(
        physicalDisplayIDs: Set<CGDirectDisplayID>
    ) async throws {
        let current = try await topologyController.capture()
        let statesByID = Dictionary(uniqueKeysWithValues: current.displays.compactMap { state in
            UInt32(state.id).map { ($0, state) }
        })
        let visibleDisplayIDs = await topologyController.visibleDisplayIDs()
        guard physicalDisplayIDs.allSatisfy({ statesByID[$0]?.active != true }),
              physicalDisplayIDs.isDisjoint(with: visibleDisplayIDs) else {
            throw LumenMacDisplayWorkspaceError.isolationPostconditionFailed
        }
    }

    private func verifyOnlineDisplayFence(
        physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay],
        sessionDisplayID: CGDirectDisplayID
    ) async throws {
        var onlineDisplayIDs = try await topologyController.onlineDisplayIDs()
        onlineDisplayIDs.remove(sessionDisplayID)
        guard onlineDisplayIDs == Set(physicalDisplays.map(\.displayID)) else {
            throw LumenPhysicalDisplayControlFailure(
                code: .physicalDisplayDisconnectUnverified
            )
        }
    }

    private func activeDisplayIDs() throws -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &displayCount)
        guard result == .success else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(result.rawValue)
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        result = CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        guard result == .success else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(result.rawValue)
        }
        return Array(displays.prefix(Int(displayCount)))
    }

    private func waitForPromotionConvergence(
        displayID: CGDirectDisplayID,
        requiredActiveDisplayIDs: Set<CGDirectDisplayID>
    ) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime
            + Self.promotionConvergenceTimeout
        while true {
            try Task.checkCancellation()
            guard let activeDisplayIDs = try? activeDisplayIDs() else {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    logPromotionState(
                        displayID: displayID,
                        mainDisplayID: CGMainDisplayID(),
                        activeDisplayIDs: [],
                        targetBounds: CGDisplayBounds(displayID),
                        result: "timeout-active-enumeration"
                    )
                    return false
                }
                try await Task.sleep(nanoseconds: Self.promotionPollNanoseconds)
                continue
            }
            let boundsByDisplayID = Dictionary(
                uniqueKeysWithValues: Set(activeDisplayIDs + [displayID]).map {
                    ($0, CGDisplayBounds($0))
                }
            )
            let mainDisplayID = CGMainDisplayID()
            let isComplete = Self.promotionIsComplete(
                displayID: displayID,
                mainDisplayID: mainDisplayID,
                activeDisplayIDs: activeDisplayIDs,
                requiredActiveDisplayIDs: requiredActiveDisplayIDs,
                exactDisplayIsOnline: CGDisplayIsOnline(displayID) != 0,
                exactDisplayIsActive: CGDisplayIsActive(displayID) != 0,
                boundsByDisplayID: boundsByDisplayID
            )
            if isComplete ||
                ProcessInfo.processInfo.systemUptime >= deadline {
                logPromotionState(
                    displayID: displayID,
                    mainDisplayID: mainDisplayID,
                    activeDisplayIDs: activeDisplayIDs,
                    targetBounds: boundsByDisplayID[displayID] ?? .zero,
                    result: isComplete ? "ready" : "timeout"
                )
                return isComplete
            }
            try await Task.sleep(nanoseconds: Self.promotionPollNanoseconds)
        }
    }

    private func logPromotionState(
        displayID: CGDirectDisplayID,
        mainDisplayID: CGDirectDisplayID,
        activeDisplayIDs: [CGDirectDisplayID],
        targetBounds: CGRect,
        result: String
    ) {
        let activeIDs = activeDisplayIDs
            .sorted()
            .map(String.init)
            .joined(separator: ",")
        let message =
            "Lumen virtual display promotion state " +
            "display-id=\(displayID) main-display-id=\(mainDisplayID) " +
            "target-origin=\(Int(targetBounds.origin.x.rounded()))," +
            "\(Int(targetBounds.origin.y.rounded())) " +
            "target-size=\(Int(targetBounds.width.rounded()))x" +
            "\(Int(targetBounds.height.rounded())) " +
            "active-display-ids=\(activeIDs) result=\(result)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func configureDisplays(
        _ body: (CGDisplayConfigRef) throws -> Void
    ) throws {
        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                beginResult.rawValue
            )
        }

        do {
            try body(configuration)
            let completeResult = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
            guard completeResult == .success else {
                throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                    completeResult.rawValue
                )
            }
        } catch {
            CGCancelDisplayConfiguration(configuration)
            throw error
        }
    }

    private func snapshotWindows(
        processIdentifiers: [pid_t]
    ) throws -> [WindowSnapshot] {
        guard processIdentifiers.isEmpty || AXIsProcessTrusted() else {
            throw LumenMacDisplayWorkspaceError.accessibilityPermissionMissing
        }

        var snapshots: [WindowSnapshot] = []
        for processIdentifier in processIdentifiers {
            let application = AXUIElementCreateApplication(processIdentifier)
            var copiedWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &copiedWindows
            ) == .success,
            let windows = copiedWindows as? [AXUIElement] else {
                throw LumenMacDisplayWorkspaceError.windowSnapshotUnavailable(
                    Int32(processIdentifier)
                )
            }

            for window in windows {
                guard let windowID = windowIdentifier(window),
                      let position = windowPoint(
                        attribute: kAXPositionAttribute,
                        element: window
                      ),
                      let size = windowSize(
                        attribute: kAXSizeAttribute,
                        element: window
                      ) else {
                    throw LumenMacDisplayWorkspaceError.windowSnapshotUnavailable(
                        Int32(processIdentifier)
                    )
                }
                snapshots.append(WindowSnapshot(
                    processID: Int32(processIdentifier),
                    windowID: windowID,
                    element: window,
                    position: position,
                    size: size
                ))
            }
        }
        return snapshots
    }

    private func resolvePersistedWindows(
        _ persistedWindows: [LumenMacWorkspaceWindowState]
    ) throws -> [WindowSnapshot] {
        guard persistedWindows.isEmpty || AXIsProcessTrusted() else {
            throw LumenMacDisplayWorkspaceError.accessibilityPermissionMissing
        }
        return try persistedWindows.map { persisted in
            let application = AXUIElementCreateApplication(pid_t(persisted.processID))
            var copiedWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &copiedWindows
            ) == .success,
            let windows = copiedWindows as? [AXUIElement],
            let element = windows.first(where: { windowIdentifier($0) == persisted.windowID }) else {
                throw LumenMacDisplayWorkspaceError.windowNotFound(
                    persisted.processID,
                    persisted.windowID
                )
            }
            return WindowSnapshot(
                processID: persisted.processID,
                windowID: persisted.windowID,
                element: element,
                position: CGPoint(
                    x: CGFloat(persisted.originX),
                    y: CGFloat(persisted.originY)
                ),
                size: CGSize(
                    width: CGFloat(persisted.width),
                    height: CGFloat(persisted.height)
                )
            )
        }
    }

    private func windowIdentifier(_ element: AXUIElement) -> UInt32? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              let position = windowPoint(
                attribute: kAXPositionAttribute,
                element: element
              ),
              let size = windowSize(
                attribute: kAXSizeAttribute,
                element: element
              ),
              let windowDescriptions = CGWindowListCopyWindowInfo(
                .optionAll,
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }
        let expectedBounds = CGRect(origin: position, size: size)
        return windowDescriptions.lazy.compactMap { description -> UInt32? in
            guard (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == Int32(processIdentifier),
                  let boundsDictionary = description[kCGWindowBounds as String] as? NSDictionary,
                  let windowNumber = description[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds),
                  abs(bounds.minX - expectedBounds.minX) <= 1,
                  abs(bounds.minY - expectedBounds.minY) <= 1,
                  abs(bounds.width - expectedBounds.width) <= 1,
                  abs(bounds.height - expectedBounds.height) <= 1 else {
                return nil
            }
            return windowNumber.uint32Value
        }.first
    }

    private func windowPoint(
        attribute: String,
        element: AXUIElement
    ) -> CGPoint? {
        var copiedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &copiedValue
        ) == .success,
        let value = copiedValue,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func windowSize(
        attribute: String,
        element: AXUIElement
    ) -> CGSize? {
        var copiedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &copiedValue
        ) == .success,
        let value = copiedValue,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func setWindowPosition(_ position: CGPoint, on element: AXUIElement) {
        var mutablePosition = position
        guard let value = AXValueCreate(.cgPoint, &mutablePosition) else {
            return
        }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setWindowSize(_ size: CGSize, on element: AXUIElement) {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            return
        }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}
