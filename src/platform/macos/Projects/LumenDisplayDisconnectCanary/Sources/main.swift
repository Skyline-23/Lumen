import AppKit
import CoreGraphics
import Darwin
import Foundation
import LumenMacBridge

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

        let beforeSelection = try displayStates()
        guard let selected = beforeSelection.first(where: { state in
            state.active && !isLumenVirtual(state)
        }) else {
            throw CanaryFailure.blocked("No active non-Lumen display is available")
        }

        let adapter = LumenPhysicalDisplayControlAdapter(
            resolver: LumenDlsymDisplayEnabledSymbolResolver()
        )
        let probe = try adapter.probe()
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let restoreRequest = runDirectory.appendingPathComponent("restore.request")
        var watchdogs: [Process] = []
        var disabled = false

        defer {
            if disabled {
                _ = try? adapter.setEnabled(true, for: selected.displayID)
            }
            try? Data().write(to: restoreRequest, options: .atomic)
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
            state.active && isLumenVirtual(state)
        }
        guard before.filter(\.active).count >= 3, safetyDisplays.count >= 2 else {
            throw CanaryFailure.blocked("Two active Lumen safety displays are required")
        }
        try writeArtifact(
            phase: "before",
            selectedDisplayID: selected.displayID,
            safetyDisplayID: nil,
            probe: probe,
            displays: before,
            detail: "Two independent watchdogs are active",
            to: runDirectory.appendingPathComponent("before.json")
        )

        _ = try adapter.setEnabled(false, for: selected.displayID)
        disabled = true
        guard waitUntil(timeout: 8, condition: {
            (try? displayStates().first(where: { $0.displayID == selected.displayID })?.active) == false
        }) else {
            throw CanaryFailure.blocked("Selected display remained active after disable transaction")
        }

        let during = try displayStates()
        guard during.contains(where: { state in
            state.displayID == selected.displayID && !state.active
        }) else {
            throw CanaryFailure.blocked("Disabled display state was not observable")
        }
        try writeArtifact(
            phase: "during",
            selectedDisplayID: selected.displayID,
            safetyDisplayID: nil,
            probe: probe,
            displays: during,
            detail: nil,
            to: runDirectory.appendingPathComponent("during.json")
        )

        try Data().write(to: restoreRequest, options: .atomic)
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
            (try? displayStates().first(where: { $0.displayID == selected.displayID })?.active) == true
        }) else {
            throw CanaryFailure.blocked("Selected display did not return to the active list")
        }
        disabled = false

        guard waitUntil(timeout: 8, condition: {
            watchdogs.allSatisfy { !$0.isRunning }
        }) else {
            throw CanaryFailure.blocked("Watchdogs did not exit after restoration")
        }
        let after = try displayStates()
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
            detail: "Physical display restored and watchdog safety displays removed",
            to: runDirectory.appendingPathComponent("after.json")
        )
        print(
            "canary_status=passed selected_display_id=\(selected.displayID) "
                + "symbol=\(probe.symbolName) artifacts=\(runDirectory.path)"
        )
    }

    private static func runWatchdog(arguments: [String]) throws {
        guard arguments.count == 4,
              let parentProcessID = Int32(arguments[0]),
              let selectedDisplayID = UInt32(arguments[1]),
              let index = Int(arguments[2])
        else {
            throw CanaryFailure.blocked("Invalid watchdog arguments")
        }
        let runDirectory = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let restoreRequest = runDirectory.appendingPathComponent("restore.request")
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
        var armed = false

        defer {
            if armed {
                do {
                    _ = try adapter.setEnabled(true, for: selectedDisplayID)
                    _ = waitUntil(timeout: 8, condition: {
                        (try? displayStates().first(where: {
                            $0.displayID == selectedDisplayID
                        })?.active) == true
                    })
                    try writeArtifact(
                        phase: "restored",
                        selectedDisplayID: selectedDisplayID,
                        safetyDisplayID: safetyDisplay.displayID,
                        probe: probe,
                        displays: try displayStates(),
                        detail: nil,
                        to: runDirectory.appendingPathComponent(
                            "watchdog-\(index)-restored.json"
                        )
                    )
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
                $0.displayID == safetyDisplay.displayID && $0.active
            })) == true
        }) else {
            try? writeArtifact(
                phase: "blocked",
                selectedDisplayID: selectedDisplayID,
                safetyDisplayID: safetyDisplay.displayID,
                probe: probe,
                displays: try displayStates(),
                detail: "CGVirtualDisplay returned an ID but WindowServer did not publish it",
                to: runDirectory.appendingPathComponent("watchdog-\(index)-blocked.json")
            )
            throw CanaryFailure.blocked("Lumen safety display did not become active")
        }
        let readyDisplays = try displayStates()
        guard readyDisplays.filter(\.active).count >= 2,
              readyDisplays.contains(where: { state in
                  state.displayID == selectedDisplayID && state.active
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
            detail: "Watchdog \(index) armed",
            to: runDirectory.appendingPathComponent("watchdog-\(index)-ready.json")
        )

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline,
              !FileManager.default.fileExists(atPath: restoreRequest.path),
              Darwin.kill(parentProcessID, 0) == 0
        {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }
}

LumenDisplayDisconnectCanaryMain.main()

private func displayStates() throws -> [DisplayState] {
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
        displays: displays,
        detail: detail
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(artifact).write(to: url, options: .atomic)
}
