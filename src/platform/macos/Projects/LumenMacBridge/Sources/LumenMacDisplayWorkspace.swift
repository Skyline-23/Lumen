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
    case displayConfigurationFailed(Int32)
    case accessibilityPermissionMissing
    case invalidPersistedDisplayID(String)
    case displayModeNotFound(UInt32)
    case physicalTopologyMismatch
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
            "owned virtual display \(displayID) could not mirror desktop source \(sourceDisplayID)"
        case .virtualDisplayMirrorRollbackFailed(let displayID):
            "owned virtual display \(displayID) could not leave desktop mirror topology"
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
}

struct LumenMacDisplayMirrorState: Equatable, Sendable {
    let mainDisplayID: UInt32
    let mirrorSourceDisplayID: UInt32?
    let sourceIsOnline: Bool
    let sourceIsActive: Bool
    let sourceIsOwnedVirtualDisplay: Bool
    let targetIsOnline: Bool
    let targetIsActive: Bool
}

protocol LumenMacDisplayMirrorControlling: Sendable {
    func state(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) async -> LumenMacDisplayMirrorState
    func mirror(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) async throws
    func unmirror(targetDisplayID: UInt32) async throws
}

struct LumenCoreGraphicsDisplayMirrorController:
    LumenMacDisplayMirrorControlling {
    func state(
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    ) -> LumenMacDisplayMirrorState {
        let mirroredDisplayID = CGDisplayMirrorsDisplay(targetDisplayID)
        return LumenMacDisplayMirrorState(
            mainDisplayID: CGMainDisplayID(),
            mirrorSourceDisplayID: mirroredDisplayID == kCGNullDirectDisplay
                ? nil
                : mirroredDisplayID,
            sourceIsOnline: CGDisplayIsOnline(sourceDisplayID) != 0,
            sourceIsActive: CGDisplayIsActive(sourceDisplayID) != 0,
            sourceIsOwnedVirtualDisplay:
                LumenMacVirtualDisplay.registeredDisplay(
                    forDisplayID: sourceDisplayID
                ) != nil,
            targetIsOnline: CGDisplayIsOnline(targetDisplayID) != 0,
            targetIsActive: CGDisplayIsActive(targetDisplayID) != 0
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
        sourceDisplayID: UInt32
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
            let completeResult = CGCompleteDisplayConfiguration(
                configuration,
                .forAppOnly
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
}

@frozen public enum LumenMacDisplayPromotionConvergence: Equatable, Sendable {
    case deferredUntilCaptureReady
    case required
}

public protocol LumenMacDisplayWorkspaceManaging: Sendable {
    func snapshotWorkspace(
        targetProcessIdentifiers: [Int32]
    ) async throws -> LumenMacPhysicalDisplayTopology
    @discardableResult
    func promoteVirtualDisplay(
        _ displayID: UInt32,
        logicalSize: CGSize,
        convergence: LumenMacDisplayPromotionConvergence
    ) async throws -> Bool
    func mirrorOwnedVirtualDisplay(
        _ displayID: UInt32,
        sourceDisplayID: UInt32
    ) async throws
    func moveTargetWindows(to displayID: UInt32) async throws
    func isolateVirtualDisplay(_ displayID: UInt32) async throws
    func restoreWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async throws
    func verifyWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async throws
    func discardSnapshot() async
}

public actor LumenMacDisplayWorkspace: LumenMacDisplayWorkspaceManaging {
    private static let promotionConvergenceTimeout: TimeInterval = 5
    private static let promotionPollNanoseconds: UInt64 = 50_000_000

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

    private let topologyController: any LumenMacDisplayTopologyControlling
    private let mirrorController: any LumenMacDisplayMirrorControlling
    private let physicalDisplayController: any LumenPhysicalDisplayControlling
    private let disconnectCapabilityVerifier: any LumenDisplayDisconnectCapabilityVerifying
    private var snapshot: Snapshot?
    private var mirroredDisplayIDs: (
        targetDisplayID: UInt32,
        sourceDisplayID: UInt32
    )?

    public init() {
        topologyController = LumenCoreGraphicsDisplayTopologyController()
        mirrorController = LumenCoreGraphicsDisplayMirrorController()
        physicalDisplayController = LumenPhysicalDisplayControlAdapter(
            resolver: LumenSystemDisplayEnabledSymbolResolver()
        )
        disconnectCapabilityVerifier = LumenDisplayDisconnectCapabilityFileVerifier.production
    }

    init(
        topologyController: any LumenMacDisplayTopologyControlling,
        mirrorController: any LumenMacDisplayMirrorControlling =
            LumenCoreGraphicsDisplayMirrorController(),
        physicalDisplayController: any LumenPhysicalDisplayControlling =
            LumenPhysicalDisplayControlAdapter(
                resolver: LumenSystemDisplayEnabledSymbolResolver()
            ),
        disconnectCapabilityVerifier: any LumenDisplayDisconnectCapabilityVerifying
    ) {
        self.topologyController = topologyController
        self.mirrorController = mirrorController
        self.physicalDisplayController = physicalDisplayController
        self.disconnectCapabilityVerifier = disconnectCapabilityVerifier
    }

    public func snapshotWorkspace(
        targetProcessIdentifiers: [Int32]
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
        return durableTopology
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
            targetDisplayID: displayID,
            sourceDisplayID: sourceDisplayID
        )
        guard before.mainDisplayID == sourceDisplayID,
              before.mirrorSourceDisplayID == nil,
              before.sourceIsOnline,
              before.sourceIsActive,
              !before.sourceIsOwnedVirtualDisplay,
              before.targetIsOnline,
              before.targetIsActive else {
            throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                displayID,
                sourceDisplayID
            )
        }

        try await mirrorController.mirror(
            targetDisplayID: displayID,
            sourceDisplayID: sourceDisplayID
        )
        mirroredDisplayIDs = (displayID, sourceDisplayID)
        do {
            let after = await mirrorController.state(
                targetDisplayID: displayID,
                sourceDisplayID: sourceDisplayID
            )
            guard after.mainDisplayID == sourceDisplayID,
                  after.mirrorSourceDisplayID == sourceDisplayID,
                  after.sourceIsOnline,
                  after.sourceIsActive,
                  !after.sourceIsOwnedVirtualDisplay,
                  after.targetIsOnline,
                  after.targetIsActive else {
                throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorUnavailable(
                    displayID,
                    sourceDisplayID
                )
            }
            try await topologyController.verify(snapshot.topology)
        } catch {
            let originalError = error
            do {
                try await releaseDesktopMirror(
                    targetDisplayID: displayID,
                    topology: snapshot.topology
                )
            } catch {
                throw LumenMacDisplayWorkspaceError
                    .virtualDisplayMirrorRollbackFailed(displayID)
            }
            throw originalError
        }
    }

    public func isolateVirtualDisplay(_ displayID: UInt32) async throws {
        guard let snapshot else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }
        do {
            let physicalDisplayIDs = try snapshot.topology.displays
                .filter { $0.enabled || $0.active }
                .map { state -> CGDirectDisplayID in
                    guard let physicalDisplayID = UInt32(state.id), physicalDisplayID != displayID else {
                        throw LumenMacDisplayWorkspaceError.invalidPersistedDisplayID(state.id)
                    }
                    return physicalDisplayID
                }
            let probe = try physicalDisplayController.probe()
            try disconnectCapabilityVerifier.authorize(
                probe: probe,
                physicalDisplayIDs: physicalDisplayIDs
            )

            var disabled: [CGDirectDisplayID] = []
            do {
                for physicalDisplayID in physicalDisplayIDs {
                    _ = try physicalDisplayController.setEnabled(false, for: physicalDisplayID)
                    disabled.append(physicalDisplayID)
                }
                try await verifyIsolation(
                    physicalDisplayIDs: Set(physicalDisplayIDs)
                )
            } catch {
                do {
                    for physicalDisplayID in disabled.reversed() {
                        _ = try physicalDisplayController.setEnabled(true, for: physicalDisplayID)
                    }
                    try await topologyController.restore(snapshot.topology)
                    try await topologyController.verify(snapshot.topology)
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

    public func restoreWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async throws {
        if let mirroredDisplayIDs {
            do {
                try await releaseDesktopMirror(
                    targetDisplayID: mirroredDisplayIDs.targetDisplayID,
                    topology: topology
                )
            } catch {
                throw LumenMacDisplayWorkspaceError.virtualDisplayMirrorRollbackFailed(
                    mirroredDisplayIDs.targetDisplayID
                )
            }
        }
        if (try? await topologyController.verify(topology)) == nil {
            let resolvedIDs = try await topologyController.resolvedDisplayIDs(for: topology)
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

    public func verifyWorkspace(_ topology: LumenMacPhysicalDisplayTopology) async throws {
        try await topologyController.verify(topology)
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
        self.snapshot = nil
    }

    public func discardSnapshot() {
        snapshot = nil
    }

    private func releaseDesktopMirror(
        targetDisplayID: UInt32,
        topology: LumenMacPhysicalDisplayTopology
    ) async throws {
        try await mirrorController.unmirror(targetDisplayID: targetDisplayID)
        try await topologyController.verify(topology)
        mirroredDisplayIDs = nil
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
