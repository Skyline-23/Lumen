import ApplicationServices
import CoreGraphics
import Foundation

public enum LumenMacDisplayWorkspaceError: Error, Equatable {
    case snapshotAlreadyExists
    case snapshotMissing
    case displayNotFound(UInt32)
    case displayConfigurationFailed(Int32)
    case accessibilityPermissionMissing
}

public protocol LumenMacDisplayWorkspaceManaging: Sendable {
    func snapshotWorkspace(targetProcessIdentifiers: [Int32]) async throws
    func promoteVirtualDisplay(_ displayID: UInt32) async throws
    func moveTargetWindows(to displayID: UInt32) async throws
    func isolateVirtualDisplay(_ displayID: UInt32) async throws
    func restoreWorkspace() async throws
    func discardSnapshot() async
}

public actor LumenMacDisplayWorkspace: LumenMacDisplayWorkspaceManaging {
    private struct DisplaySnapshot: Sendable {
        let displayID: CGDirectDisplayID
        let origin: CGPoint
        let mirrorMasterID: CGDirectDisplayID
    }

    private struct WindowSnapshot {
        let element: AXUIElement
        let position: CGPoint
        let size: CGSize
    }

    private struct Snapshot {
        let displays: [DisplaySnapshot]
        let mainDisplayID: CGDirectDisplayID
        let windows: [WindowSnapshot]
    }

    private var snapshot: Snapshot?

    public init() {}

    public func snapshotWorkspace(targetProcessIdentifiers: [Int32]) throws {
        guard snapshot == nil else {
            throw LumenMacDisplayWorkspaceError.snapshotAlreadyExists
        }

        let displays = try activeDisplayIDs().map { displayID in
            DisplaySnapshot(
                displayID: displayID,
                origin: CGDisplayBounds(displayID).origin,
                mirrorMasterID: CGDisplayMirrorsDisplay(displayID)
            )
        }
        let windows = try snapshotWindows(
            processIdentifiers: targetProcessIdentifiers.map { pid_t($0) }
        )
        snapshot = Snapshot(
            displays: displays,
            mainDisplayID: CGMainDisplayID(),
            windows: windows
        )
    }

    public func promoteVirtualDisplay(_ displayID: UInt32) throws {
        guard snapshot != nil else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }
        let ids = try activeDisplayIDs()
        guard ids.contains(displayID) else {
            throw LumenMacDisplayWorkspaceError.displayNotFound(displayID)
        }

        let virtualOrigin = CGDisplayBounds(displayID).origin
        try configureDisplays { configuration in
            for activeDisplayID in ids {
                let origin = CGDisplayBounds(activeDisplayID).origin
                let translated = CGPoint(
                    x: origin.x - virtualOrigin.x,
                    y: origin.y - virtualOrigin.y
                )
                let result = CGConfigureDisplayOrigin(
                    configuration,
                    activeDisplayID,
                    Int32(translated.x.rounded()),
                    Int32(translated.y.rounded())
                )
                guard result == .success else {
                    throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                        result.rawValue
                    )
                }
            }
        }
    }

    public func moveTargetWindows(to displayID: UInt32) throws {
        guard let snapshot else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
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

    public func isolateVirtualDisplay(_ displayID: UInt32) throws {
        guard snapshot != nil else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }
        let ids = try activeDisplayIDs()
        guard ids.contains(displayID) else {
            throw LumenMacDisplayWorkspaceError.displayNotFound(displayID)
        }

        try configureDisplays { configuration in
            try configureDisplay(
                displayID,
                mirrorMasterID: kCGNullDirectDisplay,
                origin: .zero,
                configuration: configuration
            )
            var parkedIndex: CGFloat = 0
            for activeDisplayID in ids where activeDisplayID != displayID {
                try configureDisplay(
                    activeDisplayID,
                    mirrorMasterID: kCGNullDirectDisplay,
                    origin: CGPoint(x: 20_000, y: 20_000 + parkedIndex * 2_000),
                    configuration: configuration
                )
                parkedIndex += 1
            }
        }
    }

    public func restoreWorkspace() throws {
        guard let snapshot else {
            throw LumenMacDisplayWorkspaceError.snapshotMissing
        }

        try configureDisplays { configuration in
            for display in snapshot.displays {
                try configureDisplay(
                    display.displayID,
                    mirrorMasterID: display.mirrorMasterID,
                    origin: display.origin,
                    configuration: configuration
                )
            }
        }

        for window in snapshot.windows {
            setWindowSize(window.size, on: window.element)
            setWindowPosition(window.position, on: window.element)
        }
        self.snapshot = nil
    }

    public func discardSnapshot() {
        snapshot = nil
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
            let completeResult = CGCompleteDisplayConfiguration(configuration, .forSession)
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

    private func configureDisplay(
        _ displayID: CGDirectDisplayID,
        mirrorMasterID: CGDirectDisplayID,
        origin: CGPoint,
        configuration: CGDisplayConfigRef
    ) throws {
        let mirrorResult = CGConfigureDisplayMirrorOfDisplay(
            configuration,
            displayID,
            mirrorMasterID
        )
        guard mirrorResult == .success else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                mirrorResult.rawValue
            )
        }
        let originResult = CGConfigureDisplayOrigin(
            configuration,
            displayID,
            Int32(origin.x.rounded()),
            Int32(origin.y.rounded())
        )
        guard originResult == .success else {
            throw LumenMacDisplayWorkspaceError.displayConfigurationFailed(
                originResult.rawValue
            )
        }
    }

    private func snapshotWindows(
        processIdentifiers: [pid_t]
    ) throws -> [WindowSnapshot] {
        guard processIdentifiers.isEmpty || AXIsProcessTrusted() else {
            throw LumenMacDisplayWorkspaceError.accessibilityPermissionMissing
        }

        return processIdentifiers.flatMap { processIdentifier -> [WindowSnapshot] in
            let application = AXUIElementCreateApplication(processIdentifier)
            var copiedWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &copiedWindows
            ) == .success,
            let windows = copiedWindows as? [AXUIElement] else {
                return []
            }

            return windows.compactMap { window in
                guard let position = windowPoint(
                    attribute: kAXPositionAttribute,
                    element: window
                ),
                let size = windowSize(
                    attribute: kAXSizeAttribute,
                    element: window
                ) else {
                    return nil
                }
                return WindowSnapshot(element: window, position: position, size: size)
            }
        }
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
