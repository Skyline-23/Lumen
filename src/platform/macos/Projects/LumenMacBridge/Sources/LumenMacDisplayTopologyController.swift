import CoreGraphics
import Foundation

protocol LumenMacDisplayTopologyControlling: Sendable {
    func capture() async throws -> LumenMacPhysicalDisplayTopology
    func restore(_ topology: LumenMacPhysicalDisplayTopology) async throws
    func verify(_ topology: LumenMacPhysicalDisplayTopology) async throws
    func visibleDisplayIDs() async -> Set<CGDirectDisplayID>
}

actor LumenCoreGraphicsDisplayTopologyController: LumenMacDisplayTopologyControlling {
    private static let productionVerificationAttempts = 20
    private static let productionVerificationDelayNanoseconds: UInt64 = 100_000_000
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
        let displays = try onlineDisplayIDs().map { displayID in
            let bounds = CGDisplayBounds(displayID)
            guard let mode = CGDisplayCopyDisplayMode(displayID) else {
                throw LumenMacDisplayWorkspaceError.displayNotFound(displayID)
            }
            return LumenMacPhysicalDisplayState(
                id: String(displayID),
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

    func restore(_ topology: LumenMacPhysicalDisplayTopology) async throws {
        if let restoreOverride {
            try await restoreOverride(topology)
            return
        }
        let currentOnline = Set(try onlineDisplayIDs())
        let expected = try topology.displays.map { state -> (CGDirectDisplayID, LumenMacPhysicalDisplayState) in
            guard let displayID = UInt32(state.id), currentOnline.contains(displayID) else {
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
                let mirrorID = state.mirrorMasterID.flatMap(UInt32.init) ?? kCGNullDirectDisplay
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
        let expectedByID = Dictionary(uniqueKeysWithValues: topology.displays.map { ($0.id, $0) })
        for attempt in 0..<verificationAttempts {
            let actual = try await capture()
            let actualByID = Dictionary(uniqueKeysWithValues: actual.displays.map { ($0.id, $0) })
            let visibleDisplayIDs = await visibleDisplayIDs()
            if expectedByID.allSatisfy({ actualByID[$0.key] == $0.value }),
               expectedByID.allSatisfy({ id, state in
                   guard let displayID = UInt32(id) else { return false }
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
            let result = CGCompleteDisplayConfiguration(configuration, .forSession)
            guard result == .success else {
                throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(result.rawValue)
            }
        } catch {
            CGCancelDisplayConfiguration(configuration)
            throw error
        }
    }
}
