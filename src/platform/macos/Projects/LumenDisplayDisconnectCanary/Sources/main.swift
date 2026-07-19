import AppKit
import CoreGraphics
import Darwin
import Foundation
import LumenMacBridge
import Security

private let lumenVendorID: UInt32 = 6_973
private let lumenProductID: UInt32 = 0xA901
// Give each safety output a stable namespaced serial and a normal desktop-sized
// mode so WindowServer publishes it as an independent desktop.
private let canarySafetySerialBase: UInt32 = 0x4C4D_0000
private let canarySafetyWidth: UInt32 = 1_920
private let canarySafetyHeight: UInt32 = 1_080

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
    let mirrorMasterID: UInt32?
    let inMirrorSet: Bool
    let alwaysInMirrorSet: Bool
    let modeIOFlags: UInt32?
    let usableForDesktopGUI: Bool?
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
                runCanaryApplication()
            }
        } catch {
            FileHandle.standardError.write(Data("canary_error=\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func runCanaryApplication() -> Never {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                do {
                    try runCanary()
                    Darwin.exit(0)
                } catch {
                    FileHandle.standardError.write(Data("canary_error=\(error)\n".utf8))
                    Darwin.exit(1)
                }
            }
            application.run()
        }
        Darwin.exit(1)
    }

    private static func runCanary() throws {
        guard ProcessInfo.processInfo.environment["LUMEN_RUN_DISPLAY_DISCONNECT_CANARY"] == "1" else {
            throw CanaryFailure.blocked(
                "Set LUMEN_RUN_DISPLAY_DISCONNECT_CANARY=1 to authorize display mutation"
            )
        }
        if ProcessInfo.processInfo.environment["LUMEN_VIRTUAL_DISPLAY_PROBE_ONLY"] == "1" {
            try runVirtualDisplayPublicationProbe()
            return
        }
        let capabilityStore = LumenDisplayDisconnectCapabilityFileStore.production
        try capabilityStore.revoke()

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
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runDirectory.path
        )

        let beforeSelection = try displayStates()
        let physicalCandidates = beforeSelection.filter { state in
            state.active && state.nsscreenVisible && !isLumenVirtual(state)
        }
        guard physicalCandidates.count == 1, let selected = physicalCandidates.first else {
            throw CanaryFailure.blocked(
                "Exactly one active non-Lumen display is required for exact-set verification"
            )
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
        let safetyDisplays = try createCanarySafetyDisplays(
            selectedPhysicalDisplayID: selected.displayID
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
            if !FileManager.default.fileExists(atPath: mutationURL.path) {
                _ = waitUntil(timeout: 6) {
                    watchdogs.allSatisfy { !$0.isRunning }
                }
                for watchdog in watchdogs where watchdog.isRunning {
                    watchdog.terminate()
                }
            }
            let physicalDisplayIsSafe = waitUntilPumpingMainRunLoop(timeout: 8) {
                guard let state = try? displayStates().first(where: {
                    $0.displayID == selected.displayID
                }) else {
                    return false
                }
                return state.active && state.nsscreenVisible
            }
            if physicalDisplayIsSafe {
                for display in safetyDisplays {
                    display.destroy()
                }
            } else {
                // Fail closed: retaining the two safety outputs is safer than leaving
                // the user with no visible display after an unverified restore.
                while true {
                    RunLoop.main.run(until: Date().addingTimeInterval(1))
                }
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
            guard waitUntilPumpingMainRunLoop(timeout: 12, condition: {
                FileManager.default.fileExists(atPath: readyURL.path)
            }) else {
                throw CanaryFailure.blocked("Watchdog \(index) did not become ready")
            }
        }
        guard watchdogs.allSatisfy(\.isRunning) else {
            throw CanaryFailure.blocked("A watchdog exited before display mutation")
        }

        let before = try displayStates()
        let observedSafetyDisplays = before.filter { state in
            state.active && state.nsscreenVisible && isCanarySafetyDisplay(state)
        }
        guard before.contains(where: { state in
            state.displayID == selected.displayID
                && state.active
                && state.nsscreenVisible
        }), observedSafetyDisplays.count >= 2 else {
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
            detail: "Two safety displays and two independent restore watchdogs are active",
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
        guard waitUntilPumpingMainRunLoop(timeout: 8, condition: {
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
        guard waitUntilPumpingMainRunLoop(timeout: 12, condition: {
            (1...2).allSatisfy { index in
                FileManager.default.fileExists(
                    atPath: runDirectory
                        .appendingPathComponent("watchdog-\(index)-restored.json").path
                )
            }
        }) else {
            let restoreFailed = (1...2).contains { index in
                FileManager.default.fileExists(
                    atPath: runDirectory
                        .appendingPathComponent("watchdog-\(index)-restore-failed.json").path
                )
            }
            if restoreFailed {
                throw CanaryFailure.blocked(
                    "Restore verification failed; watchdog safety displays remain active for retry"
                )
            }
            throw CanaryFailure.blocked("Watchdogs did not publish restoration receipts")
        }
        guard waitUntilPumpingMainRunLoop(timeout: 8, condition: {
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

        guard waitUntilPumpingMainRunLoop(timeout: 8, condition: {
            watchdogs.allSatisfy { !$0.isRunning }
        }) else {
            throw CanaryFailure.blocked("Watchdogs did not exit after restoration")
        }
        for display in safetyDisplays {
            display.destroy()
        }
        guard waitUntilPumpingMainRunLoop(timeout: 8, condition: {
            ((try? displayStates()) ?? []).allSatisfy { !isCanarySafetyDisplay($0) }
        }) else {
            throw CanaryFailure.blocked("A canary safety display remained online")
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
        let issuedAtUnixSeconds = Int64(Date().timeIntervalSince1970)
        let capabilityEnvironment = LumenDisplayDisconnectCapabilityEnvironment.current
        guard capabilityEnvironment.isResolved else {
            throw CanaryFailure.blocked(
                "OS build or hardware identity could not be resolved for capability receipt"
            )
        }
        let capabilityReceipt = LumenDisplayDisconnectCapabilityReceipt.verified(
            environment: capabilityEnvironment,
            probe: probe,
            physicalDisplayIDs: [selected.displayID],
            issuedAtUnixSeconds: issuedAtUnixSeconds,
            expiresAtUnixSeconds: issuedAtUnixSeconds + (7 * 24 * 60 * 60)
        )
        try capabilityStore.persist(capabilityReceipt)
        print(
            "canary_status=passed selected_display_id=\(selected.displayID) "
                + "symbol=\(probe.symbolName) artifacts=\(runDirectory.path) "
                + "capability_receipt=\(capabilityStore.receiptURL.path)"
        )
    }

    private static func runVirtualDisplayPublicationProbe() throws {
        let before = try displayStates()
        let physicalDisplays = before.filter {
            $0.active && $0.online && $0.nsscreenVisible && !isLumenVirtual($0)
        }
        guard physicalDisplays.count == 1, let physicalDisplay = physicalDisplays.first else {
            throw CanaryFailure.blocked("Publication probe requires exactly one physical desktop")
        }
        let displays = try createCanarySafetyDisplays(
            selectedPhysicalDisplayID: physicalDisplay.displayID
        )
        defer {
            for display in displays {
                display.destroy()
            }
        }
        let displayIDs = Set(displays.map(\.displayID))

        guard waitUntilPumpingMainRunLoop(timeout: 8, condition: {
            let published = ((try? displayStates()) ?? []).filter {
                displayIDs.contains($0.displayID)
                    && $0.active
                    && $0.online
                    && $0.nsscreenVisible
                    && $0.usableForDesktopGUI == true
                    && !$0.inMirrorSet
            }
            return Set(published.map(\.displayID)) == displayIDs
        }) else {
            let states = (try? displayStates()) ?? []
            let encoded = try JSONEncoder().encode(states)
            FileHandle.standardError.write(Data("probe_unready display_ids=\(displayIDs.sorted()) states=".utf8))
            FileHandle.standardError.write(encoded)
            FileHandle.standardError.write(Data("\n".utf8))
            throw CanaryFailure.blocked("Safety displays did not publish as independent desktops")
        }
        FileHandle.standardOutput.write(
            Data("probe_ready display_ids=\(displayIDs.sorted())\n".utf8)
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
        let adapter = LumenPhysicalDisplayControlAdapter(
            resolver: LumenDlsymDisplayEnabledSymbolResolver()
        )
        let probe = try adapter.probe()
        let restorer = LumenDisplayDisconnectWatchdogRestorer(controller: adapter)
        var trigger = LumenDisplayDisconnectWatchdogTrigger.deadlineExceeded

        let readyDisplays = try displayStates()
        guard readyDisplays.filter({
            $0.active && $0.nsscreenVisible && isCanarySafetyDisplay($0)
        }).count >= 2,
              readyDisplays.contains(where: { state in
                  state.displayID == selectedDisplayID
                      && state.active
                      && state.nsscreenVisible
              })
        else {
            throw CanaryFailure.blocked("Watchdog refused to arm without two active displays")
        }

        try writeArtifact(
            phase: "ready",
            selectedDisplayID: selectedDisplayID,
            safetyDisplayID: nil,
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

        let restoreFailedURL = runDirectory.appendingPathComponent(
            "watchdog-\(index)-restore-failed.json"
        )
        var restoreAttemptCount = 0
        while true {
            let marker: LumenDisplayDisconnectMutationMarker? = try? readJSON(
                from: mutationURL
            )
            restoreAttemptCount += 1
            do {
                let outcome = try restorer.recoverIfAuthorized(
                    authorization: authorization,
                    marker: marker,
                    trigger: trigger,
                    verifyRestored: {
                        waitUntil(timeout: 8, condition: {
                            guard let state = try? displayStates().first(where: {
                                $0.displayID == selectedDisplayID
                            }) else {
                                return false
                            }
                            return state.active && state.nsscreenVisible
                        })
                    }
                )
                switch outcome {
                case .skipped:
                    try? writeArtifact(
                        phase: "restore-skipped",
                        selectedDisplayID: selectedDisplayID,
                        safetyDisplayID: nil,
                        probe: probe,
                        displays: try displayStates(),
                        generationID: generationID,
                        displayTransactionCount: 0,
                        detail: "No exact durable mutation marker for this generation",
                        to: runDirectory.appendingPathComponent(
                            "watchdog-\(index)-skipped.json"
                        )
                    )
                    return
                case .restored:
                    do {
                        try writeArtifact(
                        phase: "restored",
                        selectedDisplayID: selectedDisplayID,
                        safetyDisplayID: nil,
                        probe: probe,
                        displays: try displayStates(),
                        generationID: generationID,
                        displayTransactionCount: restoreAttemptCount,
                        detail: "Authorized restore after \(trigger.rawValue)",
                        to: runDirectory.appendingPathComponent(
                            "watchdog-\(index)-restored.json"
                        )
                        )
                        return
                    } catch {
                        // Keep retrying until the durable restoration receipt is written.
                    }
                case .restoreFailed(let failureReceipt):
                    try? writeDurableJSON(failureReceipt, to: restoreFailedURL)
                    try? writeArtifact(
                        phase: "restore-failed",
                        selectedDisplayID: selectedDisplayID,
                        safetyDisplayID: nil,
                        probe: probe,
                        displays: try displayStates(),
                        generationID: generationID,
                        displayTransactionCount: restoreAttemptCount,
                        detail: failureReceipt.code.rawValue,
                        to: runDirectory.appendingPathComponent(
                            "watchdog-\(index)-restore-failed-state.json"
                        )
                    )
                }
            } catch {
                try? writeDurableJSON(
                    LumenDisplayDisconnectRestoreFailedReceipt(
                        displayID: selectedDisplayID,
                        generationID: generationID,
                        trigger: trigger,
                        code: .transactionFailed
                    ),
                    to: restoreFailedURL
                )
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
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
        let mode = CGDisplayCopyDisplayMode(displayID)
        return DisplayState(
            displayID: displayID,
            active: CGDisplayIsActive(displayID) != 0,
            online: CGDisplayIsOnline(displayID) != 0,
            builtin: CGDisplayIsBuiltin(displayID) != 0,
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            mirrorMasterID: optionalDisplayID(CGDisplayMirrorsDisplay(displayID)),
            inMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0,
            alwaysInMirrorSet: CGDisplayIsAlwaysInMirrorSet(displayID) != 0,
            modeIOFlags: mode?.ioFlags,
            usableForDesktopGUI: mode?.isUsableForDesktopGUI(),
            nsscreenVisible: visibleDisplayIDs.contains(displayID),
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width,
            height: bounds.height
        )
    }
}

private func isLumenVirtual(_ state: DisplayState) -> Bool {
    isProductionLumenVirtual(state) || isCanarySafetyDisplay(state)
}

private func isProductionLumenVirtual(_ state: DisplayState) -> Bool {
    state.vendorID == lumenVendorID && state.productID == lumenProductID
}

private func isCanarySafetyDisplay(_ state: DisplayState) -> Bool {
    state.vendorID == lumenVendorID
        && state.productID == lumenProductID
        && (state.serialNumber == canarySafetySerialBase + 1
            || state.serialNumber == canarySafetySerialBase + 2)
}

private func optionalDisplayID(_ displayID: CGDirectDisplayID) -> UInt32? {
    displayID == kCGNullDirectDisplay ? nil : displayID
}

private func createCanarySafetyDisplays(
    selectedPhysicalDisplayID: CGDirectDisplayID
) throws -> [LumenMacVirtualDisplay] {
    var displays: [LumenMacVirtualDisplay] = []
    do {
        for index in 1...2 {
            let configuration = LumenMacVirtualDisplayConfiguration()
            configuration.name = "Lumen Canary Safety \(index)"
            configuration.serialNumber = canarySafetySerialBase + UInt32(index)
            configuration.backingWidth = canarySafetyWidth
            configuration.backingHeight = canarySafetyHeight
            configuration.logicalWidth = canarySafetyWidth
            configuration.logicalHeight = canarySafetyHeight
            configuration.highDensity = false
            let display = try LumenMacVirtualDisplay(configuration: configuration)
            displays.append(display)

            guard waitUntilPumpingMainRunLoop(timeout: 8, condition: {
                ((try? displayStates()) ?? []).contains(where: {
                    $0.displayID == display.displayID
                        && $0.active
                        && $0.nsscreenVisible
                        && isCanarySafetyDisplay($0)
                })
            }) else {
                throw CanaryFailure.blocked(
                    "Canary safety display \(index) did not publish through WindowServer"
                )
            }
            try configureAsIndependentOutput(
                displayID: display.displayID,
                selectedPhysicalDisplayID: selectedPhysicalDisplayID,
                index: index
            )
        }
        return displays
    } catch {
        for display in displays {
            display.destroy()
        }
        throw error
    }
}

private func configureAsIndependentOutput(
    displayID: CGDirectDisplayID,
    selectedPhysicalDisplayID: CGDirectDisplayID,
    index: Int
) throws {
    var configuration: CGDisplayConfigRef?
    let beginResult = CGBeginDisplayConfiguration(&configuration)
    guard beginResult == .success, let configuration else {
        throw CanaryFailure.blocked(
            "Could not begin independent safety display configuration: \(beginResult.rawValue)"
        )
    }

    do {
        let unmirrorResult = CGConfigureDisplayMirrorOfDisplay(
            configuration,
            displayID,
            kCGNullDirectDisplay
        )
        guard unmirrorResult == .success else {
            throw CanaryFailure.blocked(
                "Could not mark safety display independent: \(unmirrorResult.rawValue)"
            )
        }

        let physicalBounds = CGDisplayBounds(selectedPhysicalDisplayID)
        let safetyBounds = CGDisplayBounds(displayID)
        let x = physicalBounds.maxX + (CGFloat(index - 1) * max(1, safetyBounds.width))
        let originResult = CGConfigureDisplayOrigin(
            configuration,
            displayID,
            Int32(clamping: Int64(x.rounded())),
            Int32(clamping: Int64(physicalBounds.minY.rounded()))
        )
        guard originResult == .success else {
            throw CanaryFailure.blocked(
                "Could not place safety display as an extended output: \(originResult.rawValue)"
            )
        }

        let completeResult = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard completeResult == .success else {
            throw CanaryFailure.blocked(
                "Could not commit independent safety display configuration: \(completeResult.rawValue)"
            )
        }
    } catch {
        CGCancelDisplayConfiguration(configuration)
        throw error
    }
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
