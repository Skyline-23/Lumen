import AppKit
import CoreGraphics
import Darwin
import Foundation
import LumenMacBridge
import Security

private let lumenVendorID: UInt32 = 6_973
private let lumenProductID: UInt32 = 0xA901

private enum CanaryFailure: Error, CustomStringConvertible {
    case blocked(String)

    var description: String {
        switch self {
        case .blocked(let reason):
            reason
        }
    }
}

private struct DisplayState: Codable {
    let displayID: UInt32
    let active: Bool
    let online: Bool
    let builtin: Bool
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
    let nsscreenVisible: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct CanaryArtifact: Codable {
    let phase: String
    let processID: Int32
    let selectedDisplayID: UInt32
    let safetyDisplayID: UInt32?
    let symbolSource: String?
    let symbolName: String?
    let generationID: String?
    let displayTransactionCount: Int
    let displays: [DisplayState]
    let detail: String?
}

private enum LumenDisplayDisconnectCanaryMain {
    static func main() {
        do {
            if CommandLine.arguments.count > 1,
               CommandLine.arguments[1] == "--watchdog"
            {
                try runWatchdog(arguments: Array(CommandLine.arguments.dropFirst(2)))
            } else {
                try runCanary()
            }
        } catch {
            FileHandle.standardError.write(Data("canary_error=\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func runCanary() throws {
        guard ProcessInfo.processInfo.environment["LUMEN_RUN_DISPLAY_DISCONNECT_CANARY"] == "1" else {
            throw CanaryFailure.blocked(
                "Set LUMEN_RUN_DISPLAY_DISCONNECT_CANARY=1 to authorize display mutation"
            )
        }

        let environment = ProcessInfo.processInfo.environment
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
        }
        let artifactRoot = URL(
            fileURLWithPath: environment["LUMEN_DISPLAY_CANARY_ARTIFACT_DIR"]
                ?? "/tmp/lumen-display-disconnect-canary",
            isDirectory: true
        )
        let runDirectory = artifactRoot.appendingPathComponent(
            "run-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runDirectory.path
        )

        let beforeSelection = try displayStates()
        guard let selected = beforeSelection.first(where: { state in
            state.active && state.nsscreenVisible && !isLumenVirtual(state)
        }) else {
            throw CanaryFailure.blocked("No active non-Lumen display is available")
        }

        let generationID = UUID().uuidString
        let nonce = try randomNonce()
        let authorization = LumenDisplayDisconnectAuthorization(
            parentProcessID: ProcessInfo.processInfo.processIdentifier,
            displayID: selected.displayID,
            generationID: generationID,
            nonce: nonce
        )
        let authorizationURL = runDirectory.appendingPathComponent("authorization.json")
        let mutationURL = runDirectory.appendingPathComponent("mutation.json")
        try writeDurableJSON(authorization, to: authorizationURL)

        let adapter = LumenPhysicalDisplayControlAdapter(
            resolver: LumenDlsymDisplayEnabledSymbolResolver()
        )
        let probe = try adapter.probe()
        try writeArtifact(
            phase: "pre-mutation",
            selectedDisplayID: selected.displayID,
            safetyDisplayID: nil,
            probe: probe,
            displays: beforeSelection,
            generationID: generationID,
            displayTransactionCount: 0,
            detail: "Authorization persisted; no display transaction issued",
            to: runDirectory.appendingPathComponent("pre-mutation.json")
        )
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let restoreRequest = runDirectory.appendingPathComponent("restore.request")
        var watchdogs: [Process] = []
        var disabled = false

        defer {
            if disabled {
                _ = try? adapter.setEnabled(true, for: selected.displayID)
            }
            try? writeDurableData(Data(), to: restoreRequest)
            _ = waitUntil(timeout: 6) {
                watchdogs.allSatisfy { !$0.isRunning }
            }
            for watchdog in watchdogs where watchdog.isRunning {
                watchdog.terminate()
            }
        }

        for index in 1...2 {
            let watchdog = Process()
            watchdog.executableURL = executableURL
            watchdog.arguments = [
                "--watchdog",
                String(ProcessInfo.processInfo.processIdentifier),
                String(selected.displayID),
                String(index),
                runDirectory.path,
            ]
            var watchdogEnvironment = environment
            watchdogEnvironment["LUMEN_RUN_DISPLAY_DISCONNECT_CANARY"] = "1"
            watchdogEnvironment["LUMEN_DISPLAY_CANARY_PARENT_NONCE"] = nonce
            watchdogEnvironment["LUMEN_DISPLAY_CANARY_GENERATION"] = generationID
            watchdog.environment = watchdogEnvironment
            try watchdog.run()
            watchdogs.append(watchdog)
        }

        for index in 1...2 {
            let readyURL = runDirectory.appendingPathComponent("watchdog-\(index)-ready.json")
            guard waitUntil(timeout: 12, condition: {
                FileManager.default.fileExists(atPath: readyURL.path)
            }) else {
                throw CanaryFailure.blocked("Watchdog \(index) did not become ready")
            }
        }
        guard watchdogs.allSatisfy(\.isRunning) else {
            throw CanaryFailure.blocked("A watchdog exited before display mutation")
        }

        let before = try displayStates()
        let safetyDisplays = before.filter { state in
            state.active && state.nsscreenVisible && isLumenVirtual(state)
        }
        guard before.contains(where: { state in
            state.displayID == selected.displayID
                && state.active
                && state.nsscreenVisible
        }), safetyDisplays.count >= 2 else {
            throw CanaryFailure.blocked("Two active Lumen safety displays are required")
        }
        try writeArtifact(
            phase: "before",
            selectedDisplayID: selected.displayID,
            safetyDisplayID: nil,
            probe: probe,
            displays: before,
            generationID: generationID,
            displayTransactionCount: 0,
            detail: "Two independent watchdogs are active",
            to: runDirectory.appendingPathComponent("before.json")
        )

        let attemptedMarker = LumenDisplayDisconnectMutationMarker(
            displayID: selected.displayID,
            generationID: generationID,
            nonce: nonce,
            phase: .disableAttempted
        )
        try writeDurableJSON(attemptedMarker, to: mutationURL)
        _ = try adapter.setEnabled(false, for: selected.displayID)
        disabled = true
        try writeDurableJSON(
            LumenDisplayDisconnectMutationMarker(
                displayID: selected.displayID,
                generationID: generationID,
                nonce: nonce,
                phase: .disableSucceeded
            ),
            to: mutationURL
        )
        guard waitUntil(timeout: 8, condition: {
            guard let state = try? displayStates().first(where: {
                $0.displayID == selected.displayID
            }) else {
                return false
            }
            return state.active == false && state.nsscreenVisible == false
        }) else {
            throw CanaryFailure.blocked(
                "Selected display remained active or visible to NSScreen after disable transaction"
            )
        }

        let during = try displayStates()
        guard during.contains(where: { state in
            state.displayID == selected.displayID
                && !state.active
                && !state.nsscreenVisible
        }) else {
            throw CanaryFailure.blocked("Disabled display state was not observable")
        }
        try writeArtifact(
            phase: "during",
            selectedDisplayID: selected.displayID,
            safetyDisplayID: nil,
            probe: probe,
            displays: during,
            generationID: generationID,
            displayTransactionCount: 1,
            detail: nil,
            to: runDirectory.appendingPathComponent("during.json")
        )

        try writeDurableData(Data(), to: restoreRequest)
        guard waitUntil(timeout: 12, condition: {
            (1...2).allSatisfy { index in
                FileManager.default.fileExists(
                    atPath: runDirectory
                        .appendingPathComponent("watchdog-\(index)-restored.json").path
                )
            }
        }) else {
            throw CanaryFailure.blocked("Watchdogs did not publish restoration receipts")
        }
        guard waitUntil(timeout: 8, condition: {
            guard let state = try? displayStates().first(where: {
                $0.displayID == selected.displayID
            }) else {
                return false
            }
            return state.active && state.nsscreenVisible
        }) else {
            throw CanaryFailure.blocked(
                "Selected display did not return to CoreGraphics and NSScreen"
            )
        }
        disabled = false

        guard waitUntil(timeout: 8, condition: {
            watchdogs.allSatisfy { !$0.isRunning }
        }) else {
            throw CanaryFailure.blocked("Watchdogs did not exit after restoration")
        }
        let after = try displayStates()
        guard after.contains(where: { state in
            state.displayID == selected.displayID
                && state.active
                && state.nsscreenVisible
        }) else {
            throw CanaryFailure.blocked("Restored display was absent from the final snapshot")
        }
        guard !after.contains(where: { state in
            state.serialNumber == 9_001 || state.serialNumber == 9_002
        }) else {
            throw CanaryFailure.blocked("A canary safety display remained online")
        }
        try writeArtifact(
            phase: "after",
            selectedDisplayID: selected.displayID,
            safetyDisplayID: nil,
            probe: probe,
            displays: after,
            generationID: generationID,
            displayTransactionCount: 3,
            detail: "Physical display restored and watchdog safety displays removed",
            to: runDirectory.appendingPathComponent("after.json")
        )
        print(
            "canary_status=passed selected_display_id=\(selected.displayID) "
                + "symbol=\(probe.symbolName) artifacts=\(runDirectory.path)"
        )
    }

    private static func runWatchdog(arguments: [String]) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LUMEN_RUN_DISPLAY_DISCONNECT_CANARY"] == "1" else {
            throw CanaryFailure.blocked("Watchdog mutation gate is not enabled")
        }
        guard arguments.count == 4,
              let parentProcessID = Int32(arguments[0]),
              let selectedDisplayID = UInt32(arguments[1]),
              let index = Int(arguments[2])
        else {
            throw CanaryFailure.blocked("Invalid watchdog arguments")
        }
        let runDirectory = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let authorizationURL = runDirectory.appendingPathComponent("authorization.json")
        let mutationURL = runDirectory.appendingPathComponent("mutation.json")
        let restoreRequest = runDirectory.appendingPathComponent("restore.request")
        guard hasRestrictedPermissions(runDirectory),
              hasRestrictedPermissions(authorizationURL),
              let generationID = environment["LUMEN_DISPLAY_CANARY_GENERATION"],
              let nonce = environment["LUMEN_DISPLAY_CANARY_PARENT_NONCE"]
        else {
            throw CanaryFailure.blocked("Watchdog authorization boundary is not private")
        }
        let authorization: LumenDisplayDisconnectAuthorization = try readJSON(
            from: authorizationURL
        )
        guard authorization.isWellFormed,
              Darwin.getppid() == parentProcessID,
              authorization.parentProcessID == parentProcessID,
              authorization.displayID == selectedDisplayID,
              authorization.generationID == generationID,
              authorization.nonce == nonce
        else {
            throw CanaryFailure.blocked("Watchdog authorization does not match this generation")
        }
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
        }
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = "Lumen Canary Safety \(index)"
        configuration.serialNumber = UInt32(9_000 + index)
        configuration.backingWidth = 1_024
        configuration.backingHeight = 768
        configuration.logicalWidth = 1_024
        configuration.logicalHeight = 768
        configuration.highDensity = false
        let safetyDisplay = try LumenMacVirtualDisplay(configuration: configuration)
        let adapter = LumenPhysicalDisplayControlAdapter(
            resolver: LumenDlsymDisplayEnabledSymbolResolver()
        )
        let probe = try adapter.probe()
        let restorer = LumenDisplayDisconnectWatchdogRestorer(controller: adapter)
        var armed = false
        var trigger = LumenDisplayDisconnectWatchdogTrigger.deadlineExceeded

        defer {
            if armed {
                do {
                    let marker: LumenDisplayDisconnectMutationMarker? = try? readJSON(
                        from: mutationURL
                    )
                    let receipt = try restorer.restoreIfAuthorized(
                        authorization: authorization,
                        marker: marker,
                        trigger: trigger
                    )
                    if receipt != nil {
                        _ = waitUntil(timeout: 8, condition: {
                            guard let state = try? displayStates().first(where: {
                                $0.displayID == selectedDisplayID
                            }) else {
                                return false
                            }
                            return state.active && state.nsscreenVisible
                        })
                        try writeArtifact(
                            phase: "restored",
                            selectedDisplayID: selectedDisplayID,
                            safetyDisplayID: safetyDisplay.displayID,
                            probe: probe,
                            displays: try displayStates(),
                            generationID: generationID,
                            displayTransactionCount: 1,
                            detail: "Authorized restore after \(trigger.rawValue)",
                            to: runDirectory.appendingPathComponent(
                                "watchdog-\(index)-restored.json"
                            )
                        )
                    } else {
                        try writeArtifact(
                            phase: "restore-skipped",
                            selectedDisplayID: selectedDisplayID,
                            safetyDisplayID: safetyDisplay.displayID,
                            probe: probe,
                            displays: try displayStates(),
                            generationID: generationID,
                            displayTransactionCount: 0,
                            detail: "No exact durable mutation marker for this generation",
                            to: runDirectory.appendingPathComponent(
                                "watchdog-\(index)-skipped.json"
                            )
                        )
                    }
                } catch {
                    let failureURL = runDirectory.appendingPathComponent(
                        "watchdog-\(index)-restore-failed.txt"
                    )
                    try? Data(String(describing: error).utf8).write(
                        to: failureURL,
                        options: .atomic
                    )
                }
            }
            safetyDisplay.destroy()
        }

        guard waitUntilPumpingMainRunLoop(timeout: 8, condition: {
            (try? displayStates().contains(where: {
                $0.displayID == safetyDisplay.displayID
                    && $0.active
                    && $0.nsscreenVisible
            })) == true
        }) else {
            try? writeArtifact(
                phase: "blocked",
                selectedDisplayID: selectedDisplayID,
                safetyDisplayID: safetyDisplay.displayID,
                probe: probe,
                displays: try displayStates(),
                generationID: generationID,
                displayTransactionCount: 0,
                detail: "CGVirtualDisplay returned an ID but WindowServer did not publish it",
                to: runDirectory.appendingPathComponent("watchdog-\(index)-blocked.json")
            )
            throw CanaryFailure.blocked("Lumen safety display did not become active")
        }
        let readyDisplays = try displayStates()
        guard readyDisplays.filter({ $0.active && $0.nsscreenVisible }).count >= 2,
              readyDisplays.contains(where: { state in
                  state.displayID == selectedDisplayID
                      && state.active
                      && state.nsscreenVisible
              })
        else {
            throw CanaryFailure.blocked("Watchdog refused to arm without two active displays")
        }

        armed = true
        try writeArtifact(
            phase: "ready",
            selectedDisplayID: selectedDisplayID,
            safetyDisplayID: safetyDisplay.displayID,
            probe: probe,
            displays: readyDisplays,
            generationID: generationID,
            displayTransactionCount: 0,
            detail: "Watchdog \(index) armed",
            to: runDirectory.appendingPathComponent("watchdog-\(index)-ready.json")
        )

        let deadline = Date().addingTimeInterval(25)
        while true {
            if FileManager.default.fileExists(atPath: restoreRequest.path) {
                trigger = .restoreRequested
                break
            }
            if Darwin.kill(parentProcessID, 0) != 0 {
                trigger = .parentExited
                break
            }
            if Date() >= deadline {
                trigger = .deadlineExceeded
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }
}

LumenDisplayDisconnectCanaryMain.main()

private func displayStates() throws -> [DisplayState] {
    let visibleDisplayIDs = MainActor.assumeIsolated {
        Set(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value
        })
    }
    var count: UInt32 = 0
    var status = CGGetOnlineDisplayList(0, nil, &count)
    guard status == .success else {
        throw CanaryFailure.blocked("CGGetOnlineDisplayList count failed: \(status.rawValue)")
    }
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
    status = CGGetOnlineDisplayList(count, &displayIDs, &count)
    guard status == .success else {
        throw CanaryFailure.blocked("CGGetOnlineDisplayList failed: \(status.rawValue)")
    }
    return displayIDs.prefix(Int(count)).map { displayID in
        let bounds = CGDisplayBounds(displayID)
        return DisplayState(
            displayID: displayID,
            active: CGDisplayIsActive(displayID) != 0,
            online: CGDisplayIsOnline(displayID) != 0,
            builtin: CGDisplayIsBuiltin(displayID) != 0,
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            nsscreenVisible: visibleDisplayIDs.contains(displayID),
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width,
            height: bounds.height
        )
    }
}

private func isLumenVirtual(_ state: DisplayState) -> Bool {
    state.vendorID == lumenVendorID && state.productID == lumenProductID
}

private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return condition()
}

private func waitUntilPumpingMainRunLoop(
    timeout: TimeInterval,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
}

private func writeArtifact(
    phase: String,
    selectedDisplayID: UInt32,
    safetyDisplayID: UInt32?,
    probe: LumenDisplayEnabledSymbolProbe,
    displays: [DisplayState],
    generationID: String? = nil,
    displayTransactionCount: Int = 0,
    detail: String?,
    to url: URL
) throws {
    let artifact = CanaryArtifact(
        phase: phase,
        processID: ProcessInfo.processInfo.processIdentifier,
        selectedDisplayID: selectedDisplayID,
        safetyDisplayID: safetyDisplayID,
        symbolSource: probe.source.rawValue,
        symbolName: probe.symbolName,
        generationID: generationID,
        displayTransactionCount: displayTransactionCount,
        displays: displays,
        detail: detail
    )
    try writeDurableJSON(artifact, to: url)
}

private func randomNonce() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
        throw CanaryFailure.blocked("Secure nonce generation failed: \(status)")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private func writeDurableJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeDurableData(encoder.encode(value), to: url)
}

private func writeDurableData(_ data: Data, to url: URL) throws {
    let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
        ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
    )
    try data.write(to: temporaryURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: temporaryURL.path
    )
    let handle = try FileHandle(forWritingTo: temporaryURL)
    try handle.synchronize()
    try handle.close()
    guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
        let error = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: temporaryURL)
        throw CanaryFailure.blocked("Durable marker rename failed: \(error)")
    }
    let directoryDescriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
    guard directoryDescriptor >= 0 else {
        throw CanaryFailure.blocked("Durable marker directory open failed")
    }
    defer { Darwin.close(directoryDescriptor) }
    guard Darwin.fsync(directoryDescriptor) == 0 else {
        throw CanaryFailure.blocked("Durable marker directory sync failed")
    }
}

private func readJSON<T: Decodable>(from url: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

private func hasRestrictedPermissions(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let permissions = attributes[.posixPermissions] as? NSNumber
    else {
        return false
    }
    return permissions.intValue & 0o077 == 0
}
