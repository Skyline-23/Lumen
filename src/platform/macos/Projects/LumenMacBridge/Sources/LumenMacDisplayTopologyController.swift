import CoreGraphics
import Foundation
import OSLog

protocol LumenMacDisplayTopologyControlling: Sendable {
    func capture() async throws -> LumenMacPhysicalDisplayTopology
    func restore(_ topology: LumenMacPhysicalDisplayTopology) async throws
    func verify(_ topology: LumenMacPhysicalDisplayTopology) async throws
    func visibleDisplayIDs() async -> Set<CGDirectDisplayID>
    func resolvedDisplayIDs(
        for topology: LumenMacPhysicalDisplayTopology
    ) async throws -> [String: CGDirectDisplayID]
}

extension LumenMacDisplayTopologyControlling {
    func resolvedDisplayIDs(
        for topology: LumenMacPhysicalDisplayTopology
    ) async throws -> [String: CGDirectDisplayID] {
        try Dictionary(uniqueKeysWithValues: topology.displays.map { state in
            guard let displayID = UInt32(state.id) else {
                throw LumenMacDisplayWorkspaceError.invalidPersistedDisplayID(state.id)
            }
            return (state.id, displayID)
        })
    }
}

actor LumenCoreGraphicsDisplayTopologyController: LumenMacDisplayTopologyControlling {
    private static let productionVerificationAttempts = 20
    private static let productionVerificationDelayNanoseconds: UInt64 = 100_000_000
    private static let logger = Logger(
        subsystem: "dev.skyline23.lumen",
        category: "MacDisplayTopology"
    )
    private let captureOverride: (@Sendable () async throws -> LumenMacPhysicalDisplayTopology)?
    private let restoreOverride: (@Sendable (LumenMacPhysicalDisplayTopology) async throws -> Void)?
    private let visibleDisplayIDsProvider: @Sendable () async -> Set<CGDirectDisplayID>
    private let verificationAttempts: Int
    private let verificationDelayNanoseconds: UInt64

    init() {
        captureOverride = nil
        restoreOverride = nil
        visibleDisplayIDsProvider = {
            Set(Self.activeDisplayIDs())
        }
        verificationAttempts = Self.productionVerificationAttempts
        verificationDelayNanoseconds = Self.productionVerificationDelayNanoseconds
    }

    init(
        capture: @escaping @Sendable () async throws -> LumenMacPhysicalDisplayTopology,
        restore: @escaping @Sendable (LumenMacPhysicalDisplayTopology) async throws -> Void,
        visibleDisplayIDs: @escaping @Sendable () async -> Set<CGDirectDisplayID>,
        verificationAttempts: Int = 1,
        verificationDelayNanoseconds: UInt64 = 0
    ) {
        captureOverride = capture
        restoreOverride = restore
        visibleDisplayIDsProvider = visibleDisplayIDs
        self.verificationAttempts = max(1, verificationAttempts)
        self.verificationDelayNanoseconds = verificationDelayNanoseconds
    }

    func capture() async throws -> LumenMacPhysicalDisplayTopology {
        if let captureOverride {
            return try await captureOverride()
        }
        let displays = Self.usableDisplayStates(from: try onlineDisplayIDs()) { displayID in
            let bounds = CGDisplayBounds(displayID)
            guard let mode = CGDisplayCopyDisplayMode(displayID) else {
                Self.logger.warning(
                    "stage=topology-capture-skip-mode-less-display display-id=\(displayID, privacy: .public)"
                )
                return nil
            }
            return LumenMacPhysicalDisplayState(
                id: String(displayID),
                vendorID: CGDisplayVendorNumber(displayID),
                productID: CGDisplayModelNumber(displayID),
                serialNumber: CGDisplaySerialNumber(displayID),
                builtin: CGDisplayIsBuiltin(displayID) != 0,
                mode: displayMode(mode),
                originX: clampedInt32(bounds.origin.x),
                originY: clampedInt32(bounds.origin.y),
                mirrorMasterID: optionalDisplayID(CGDisplayMirrorsDisplay(displayID)),
                enabled: CGDisplayIsActive(displayID) != 0,
                active: CGDisplayIsActive(displayID) != 0,
                online: CGDisplayIsOnline(displayID) != 0
            )
        }
        return LumenMacPhysicalDisplayTopology(
            displays: displays,
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
    }

    static func usableDisplayStates(
        from displayIDs: [CGDirectDisplayID],
        makeState: (CGDirectDisplayID) throws -> LumenMacPhysicalDisplayState?
    ) rethrows -> [LumenMacPhysicalDisplayState] {
        try displayIDs.compactMap(makeState)
    }

    func restore(_ topology: LumenMacPhysicalDisplayTopology) async throws {
        if let restoreOverride {
            try await restoreOverride(topology)
            return
        }
        let resolvedIDs = try await resolvedDisplayIDs(for: topology)
        let expected = try topology.displays.map { state -> (CGDirectDisplayID, LumenMacPhysicalDisplayState) in
            guard let displayID = resolvedIDs[state.id] else {
                throw LumenMacDisplayWorkspaceError.invalidPersistedDisplayID(state.id)
            }
            return (displayID, state)
        }
        try configureDisplays { configuration in
            for (displayID, state) in expected {
                let mode = try matchingMode(displayID: displayID, expected: state.mode)
                let modeResult = CGConfigureDisplayWithDisplayMode(
                    configuration,
                    displayID,
                    mode,
                    nil
                )
                guard modeResult == .success else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                        modeResult.rawValue
                    )
                }
                let unmirrorResult = CGConfigureDisplayMirrorOfDisplay(
                    configuration,
                    displayID,
                    kCGNullDirectDisplay
                )
                guard unmirrorResult == .success else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                        unmirrorResult.rawValue
                    )
                }
                let originResult = CGConfigureDisplayOrigin(
                    configuration,
                    displayID,
                    state.originX,
                    state.originY
                )
                guard originResult == .success else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                        originResult.rawValue
                    )
                }
            }
            for (displayID, state) in expected {
                let mirrorID = state.mirrorMasterID.flatMap { persistedID in
                    resolvedIDs[persistedID] ?? UInt32(persistedID)
                } ?? kCGNullDirectDisplay
                let mirrorResult = CGConfigureDisplayMirrorOfDisplay(
                    configuration,
                    displayID,
                    mirrorID
                )
                guard mirrorResult == .success else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                        mirrorResult.rawValue
                    )
                }
            }
        }
    }

    func verify(_ topology: LumenMacPhysicalDisplayTopology) async throws {
        for attempt in 0..<verificationAttempts {
            let actual = try await capture()
            let actualByID = Dictionary(uniqueKeysWithValues: actual.displays.map { ($0.id, $0) })
            let visibleDisplayIDs = await visibleDisplayIDs()
            let resolvedIDs = try await resolvedDisplayIDs(for: topology)
            if topology.displays.allSatisfy({ state in
                guard let displayID = resolvedIDs[state.id],
                      let actualState = actualByID[String(displayID)] else {
                    return false
                }
                return Self.matches(
                    actual: actualState,
                    expected: state,
                    resolvedIDs: resolvedIDs
                )
            }), topology.displays.allSatisfy({ state in
                   guard let displayID = resolvedIDs[state.id] else { return false }
                   return visibleDisplayIDs.contains(displayID) == (state.active && state.online)
               }) {
                return
            }
            if attempt + 1 < verificationAttempts, verificationDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: verificationDelayNanoseconds)
            }
        }
        throw LumenMacDisplayWorkspaceError.physicalTopologyMismatch
    }

    func visibleDisplayIDs() async -> Set<CGDirectDisplayID> {
        await visibleDisplayIDsProvider()
    }

    func resolvedDisplayIDs(
        for topology: LumenMacPhysicalDisplayTopology
    ) async throws -> [String: CGDirectDisplayID] {
        if captureOverride != nil {
            return try Dictionary(uniqueKeysWithValues: topology.displays.map { state in
                guard let displayID = UInt32(state.id) else {
                    throw LumenMacDisplayWorkspaceError.invalidPersistedDisplayID(state.id)
                }
                return (state.id, displayID)
            })
        }
        let online = try onlineDisplayIDs()
        let candidates = online.compactMap { displayID -> LumenMacPhysicalDisplayState? in
            guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
            let bounds = CGDisplayBounds(displayID)
            return LumenMacPhysicalDisplayState(
                id: String(displayID),
                vendorID: CGDisplayVendorNumber(displayID),
                productID: CGDisplayModelNumber(displayID),
                serialNumber: CGDisplaySerialNumber(displayID),
                builtin: CGDisplayIsBuiltin(displayID) != 0,
                mode: displayMode(mode),
                originX: clampedInt32(bounds.origin.x),
                originY: clampedInt32(bounds.origin.y),
                mirrorMasterID: optionalDisplayID(CGDisplayMirrorsDisplay(displayID)),
                enabled: CGDisplayIsActive(displayID) != 0,
                active: CGDisplayIsActive(displayID) != 0,
                online: CGDisplayIsOnline(displayID) != 0
            )
        }
        let resolved = try Self.resolveDisplayIDs(for: topology, candidates: candidates)
        for state in topology.displays {
            guard !Self.hasStableIdentity(state),
                  let resolvedID = resolved[state.id],
                  state.id != String(resolvedID) else {
                continue
            }
            Self.logger.warning(
                "stage=legacy-display-id-reconciled persisted-id=\(state.id, privacy: .public) current-id=\(resolvedID, privacy: .public)"
            )
        }
        return resolved
    }

    private func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var result = CGGetOnlineDisplayList(0, nil, &count)
        guard result == .success else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(result.rawValue)
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        result = CGGetOnlineDisplayList(count, &displays, &count)
        guard result == .success else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(result.rawValue)
        }
        return Array(displays.prefix(Int(count)))
    }

    nonisolated private static func hasStableIdentity(
        _ state: LumenMacPhysicalDisplayState
    ) -> Bool {
        state.vendorID != nil || state.productID != nil || state.serialNumber != nil || state.builtin != nil
    }

    nonisolated static func resolveDisplayIDs(
        for topology: LumenMacPhysicalDisplayTopology,
        candidates: [LumenMacPhysicalDisplayState]
    ) throws -> [String: CGDirectDisplayID] {
        var resolved: [String: CGDirectDisplayID] = [:]
        var claimed: Set<CGDirectDisplayID> = []

        for state in topology.displays {
            if let exact = candidates.first(where: { candidate in
                candidate.id == state.id && identityMatches(actual: candidate, expected: state)
            }), let displayID = UInt32(exact.id) {
                resolved[state.id] = displayID
                claimed.insert(displayID)
                continue
            }

            let stableMatches = candidates.filter { candidate in
                guard let displayID = UInt32(candidate.id) else { return false }
                return !claimed.contains(displayID)
                    && hasStableIdentity(state)
                    && identityMatches(actual: candidate, expected: state)
            }
            if stableMatches.count == 1,
               let candidate = stableMatches.first,
               let displayID = UInt32(candidate.id) {
                resolved[state.id] = displayID
                claimed.insert(displayID)
            }
        }

        if topology.displays.count == 1,
           let state = topology.displays.first,
           resolved[state.id] == nil,
           !hasStableIdentity(state) {
            let legacyMatches = candidates.filter { candidate in
                guard let displayID = UInt32(candidate.id) else { return false }
                return !claimed.contains(displayID)
                    && !isLumenVirtualDisplay(candidate)
                    && candidate.online
                    && candidate.mode == state.mode
            }
            if legacyMatches.count == 1,
               let candidate = legacyMatches.first,
               let displayID = UInt32(candidate.id) {
                resolved[state.id] = displayID
            } else if legacyMatches.isEmpty {
                let activeBuiltins = candidates.filter { candidate in
                    guard let displayID = UInt32(candidate.id) else { return false }
                    return !claimed.contains(displayID)
                        && candidate.builtin == true
                        && candidate.enabled
                        && candidate.active
                        && candidate.online
                }
                if activeBuiltins.count == 1,
                   let candidate = activeBuiltins.first,
                   let displayID = UInt32(candidate.id) {
                    resolved[state.id] = displayID
                }
            }
        }

        guard resolved.count == topology.displays.count else {
            let missing = topology.displays.first { resolved[$0.id] == nil }?.id ?? "unknown"
            throw LumenMacDisplayWorkspaceError.invalidPersistedDisplayID(missing)
        }
        return resolved
    }

    nonisolated private static func identityMatches(
        actual: LumenMacPhysicalDisplayState,
        expected: LumenMacPhysicalDisplayState
    ) -> Bool {
        (expected.vendorID == nil || expected.vendorID == actual.vendorID)
            && (expected.productID == nil || expected.productID == actual.productID)
            && (expected.serialNumber == nil || expected.serialNumber == actual.serialNumber)
            && (expected.builtin == nil || expected.builtin == actual.builtin)
    }

    nonisolated private static func isLumenVirtualDisplay(
        _ state: LumenMacPhysicalDisplayState
    ) -> Bool {
        state.vendorID == 6_973 && state.productID == 0xA901
    }

    nonisolated static func matches(
        actual: LumenMacPhysicalDisplayState,
        expected: LumenMacPhysicalDisplayState,
        resolvedIDs: [String: CGDirectDisplayID]
    ) -> Bool {
        if !hasStableIdentity(expected), actual.id != expected.id {
            return actual.builtin == true
                && actual.enabled
                && actual.active
                && actual.online
        }
        let expectedMirrorID = expected.mirrorMasterID.flatMap { persistedID in
            resolvedIDs[persistedID].map(String.init) ?? persistedID
        }
        return actual.mode == expected.mode
            && actual.originX == expected.originX
            && actual.originY == expected.originY
            && actual.mirrorMasterID == expectedMirrorID
            && actual.enabled == expected.enabled
            && actual.active == expected.active
            && actual.online == expected.online
            && (expected.vendorID == nil || actual.vendorID == expected.vendorID)
            && (expected.productID == nil || actual.productID == expected.productID)
            && (expected.serialNumber == nil || actual.serialNumber == expected.serialNumber)
            && (expected.builtin == nil || actual.builtin == expected.builtin)
    }

    nonisolated private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            return []
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return []
        }
        return Array(displays.prefix(Int(count)))
    }

    private func matchingMode(
        displayID: CGDirectDisplayID,
        expected: LumenMacPhysicalDisplayMode
    ) throws -> CGDisplayMode {
        let current = CGDisplayCopyDisplayMode(displayID)
        let available = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] ?? []
        let candidates = [current].compactMap { $0 } + available
        guard let index = Self.preferredModeIndex(
            current: current.map(displayMode),
            available: available.map(displayMode),
            expected: expected
        ) else {
            throw LumenMacDisplayWorkspaceError.displayModeNotFound(displayID)
        }
        return candidates[index]
    }

    static func preferredModeIndex(
        current: LumenMacPhysicalDisplayMode?,
        available: [LumenMacPhysicalDisplayMode],
        expected: LumenMacPhysicalDisplayMode
    ) -> Int? {
        if current == expected {
            return 0
        }
        return available.firstIndex(of: expected).map { $0 + (current == nil ? 0 : 1) }
    }

    private func displayMode(_ mode: CGDisplayMode) -> LumenMacPhysicalDisplayMode {
        let refresh = max(0, mode.refreshRate * 1_000).rounded()
        return LumenMacPhysicalDisplayMode(
            width: UInt32(clamping: mode.pixelWidth),
            height: UInt32(clamping: mode.pixelHeight),
            refreshMillihertz: UInt32(clamping: Int64(refresh)),
            bitDepth: bitDepth(mode)
        )
    }

    private func bitDepth(_ mode: CGDisplayMode) -> UInt8 {
        let encoding = mode.pixelEncoding.map { $0 as String } ?? ""
        if encoding.contains("30Bit") || encoding.contains("RRRRRRRRRR") {
            return 10
        }
        if encoding.contains("64Bit") || encoding.contains("16R16G16B16") {
            return 16
        }
        return 8
    }

    private func optionalDisplayID(_ displayID: CGDirectDisplayID) -> String? {
        displayID == kCGNullDirectDisplay ? nil : String(displayID)
    }

    private func clampedInt32(_ value: CGFloat) -> Int32 {
        Int32(clamping: Int64(value.rounded()))
    }

    private func configureDisplays(
        _ body: (CGDisplayConfigRef) throws -> Void
    ) throws {
        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(beginResult.rawValue)
        }
        do {
            try body(configuration)
            let result = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
            guard result == .success else {
                throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(result.rawValue)
            }
        } catch {
            CGCancelDisplayConfiguration(configuration)
            throw error
        }
    }
}
