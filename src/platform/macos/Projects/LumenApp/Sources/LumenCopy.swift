import Foundation
import LumenAppArchitecture
import LumenMacBridge

private func localized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: Locale.current, arguments: arguments)
}

enum LumenCopy {
    static let productName = "Lumen"
    static let productNameUppercase = "LUMEN"

    enum Navigation {
        static var overview: String { localized("Overview") }
        static var applications: String { localized("Applications") }
        static var settings: String { localized("Settings") }
        static var diagnostics: String { localized("Diagnostics") }
    }

    enum Status {
        static var running: String { localized("Running") }
        static var stopped: String { localized("Stopped") }
        static var active: String { localized("Active") }
        static var idle: String { localized("Idle") }
        static var ready: String { localized("Ready") }
        static var configured: String { localized("Configured") }

        static func runtime(isRunning: Bool) -> String {
            isRunning ? running : stopped
        }

        static func stream(isRunning: Bool) -> String {
            isRunning ? active : idle
        }
    }

    enum Action {
        static var add: String { localized("Add") }
        static var edit: String { localized("Edit") }
        static var delete: String { localized("Delete") }
        static var cancel: String { localized("Cancel") }
        static var save: String { localized("Save") }
        static var request: String { localized("Request") }
        static var openSettings: String { localized("Open Settings") }
        static var settings: String { localized("Settings") }
        static var quit: String { localized("Quit") }
        static var signIn: String { localized("Sign in") }
        static var createAccount: String { localized("Create account") }
        static var forgotPassword: String { localized("Forgot password?") }
        static var lockSettings: String { localized("Lock now") }
        static var reloadApplications: String { localized("Reload applications") }
        static var restartHost: String { localized("Restart host") }
        static var showWindow: String { localized("Show Lumen Window") }
        static var restartLumen: String { localized("Restart Lumen") }
        static var factoryReset: String { localized("Factory Reset...") }
        static var factoryResetLumen: String { localized("Factory Reset Lumen...") }
        static var quitLumen: String { localized("Quit Lumen") }
        static var eraseAllSettings: String { localized("Erase All Settings") }
        static var close: String { localized("Close") }
        static var checkAgain: String { localized("Check Again") }
        static var unlockWithSystemAuthentication: String { localized("Unlock with Touch ID") }
        static var forceStopStream: String { localized("Force Stop Stream") }
    }

    enum Account {
        static var ownerAccount: String { localized("Owner account") }
        static var account: String { localized("Account") }
        static var ownerName: String { localized("Owner ID") }
        static var password: String { localized("Password") }
        static var passwordMinimum: String { localized("Password (12 characters minimum)") }
        static var confirmPassword: String { localized("Confirm password") }
        static var signedInAs: String { localized("Signed in as") }
        static var systemAuthenticationReason: String { localized("Unlock Lumen settings with Touch ID") }
        static var enableSystemAuthenticationReason: String { localized("Confirm Touch ID before enabling it for Lumen") }
        static var systemAuthenticationUnavailable: String { localized("Touch ID is unavailable on this Mac.") }
        static var systemAuthenticationFailed: String { localized("Touch ID authentication did not complete.") }

        static func signedInAs(_ username: String) -> String {
            localizedFormat("Signed in as %@", username)
        }
    }

    enum Permission {
        static var systemAccess: String { localized("System access") }
        static var screenRecording: String { localized("Screen Recording") }
        static var accessibility: String { localized("Accessibility") }
        static var dragPanelTitle: String { localized("Add Lumen to System Settings") }
        static var accessibilityDragDetail: String { localized("In System Settings, open Accessibility and drag Lumen into the app list below.") }
        static var screenRecordingDragDetail: String { localized("In System Settings, open Screen & System Audio Recording and drag Lumen into the app list below.") }
        static var dragInstruction: String { localized("Drag this app into the permission list") }
        static var dragHint: String { localized("After adding Lumen, enable its switch and check again.") }
        static var stillRequired: String { localized("The permission is still disabled. Enable Lumen in System Settings, then check again.") }
        static var dragAccessibilityHelp: String { localized("Drag the Lumen application into the open System Settings permission list.") }
    }

    enum Onboarding {
        static var headline: String { localized("Your computer,\nready anywhere.") }
        static var introduction: String { localized("Set up one owner account. Lumen keeps streaming, applications, and enrolled devices under your control.") }
        static var localCredentials: String { localized("Local credentials") }
        static var nativeHostControls: String { localized("Native host controls") }
        static var remoteDeviceAccess: String { localized("Remote device access") }
        static var credentialsNotice: String { localized("Credentials never leave this computer in plaintext.") }
        static var opening: String { localized("Opening Lumen") }
        static var openingDetail: String { localized("Checking the local owner account and host state.") }
        static var createOwnerTitle: String { localized("Create the owner account") }
        static var createOwnerDetail: String { localized("This account controls this host, enrolled devices, and remote settings.") }
        static var passwordStorageNotice: String { localized("The password is stored only as an Argon2id hash on this computer.") }
        static var unlockTitle: String { localized("Unlock Lumen") }
        static var unlockDetail: String { localized("Sign in to manage this host. Streaming services continue independently.") }
    }

    enum Overview {
        static var subtitle: String { localized("Host readiness and active streaming state") }
        static var hostRuntime: String { localized("Host runtime") }
        static var currentStream: String { localized("Current stream") }
        static var hostControls: String { localized("Host controls") }
    }

    enum Applications {
        static var subtitle: String { localized("Choose what remote clients can launch") }
        static var newApplication: String { localized("New application") }
        static var emptyTitle: String { localized("No applications") }
        static var emptyDetail: String { localized("Add a desktop or application entry for remote clients.") }
        static var streamDesktop: String { localized("Stream the desktop") }
        static var virtualDisplay: String { localized("Virtual display") }
        static var addTitle: String { localized("Add application") }
        static var editTitle: String { localized("Edit application") }
        static var identity: String { localized("Identity") }
        static var name: String { localized("Name") }
        static var coverPath: String { localized("Cover path") }
        static var launch: String { localized("Launch") }
        static var command: String { localized("Command") }
        static var workingDirectory: String { localized("Working directory") }
        static var detachedCommands: String { localized("Detached commands (one per line)") }
        static var display: String { localized("Display") }
        static var createVirtualDisplay: String { localized("Create a virtual display") }
        static var processBehavior: String { localized("Process behavior") }
        static var detachAutomatically: String { localized("Detach automatically") }
        static var waitForAllProcesses: String { localized("Wait for all processes") }
        static var terminateWhenPaused: String { localized("Terminate when paused") }
        static var runElevated: String { localized("Run elevated") }

        static func exitTimeout(seconds: Int) -> String {
            localizedFormat("Exit timeout: %@ seconds", seconds.formatted())
        }

        static func desktopScale(percent: Int) -> String {
            localizedFormat("Desktop scale: %@%%", percent.formatted())
        }
    }

    enum Settings {
        static var subtitle: String { localized("Native host behavior and account controls") }
        static var security: String { localized("Security") }
        static var securitySubtitle: String { localized("Protect local access and recovery controls") }
        static var general: String { localized("General") }
        static var generalSubtitle: String { localized("Computer identity, discovery, and logging") }
        static var application: String { localized("Application") }
        static var hideDockIconWhenMainWindowCloses: String { localized("Hide Dock icon when the main window closes") }
        static var hideDockIconWhenMainWindowClosesDetail: String { localized("Lumen stays available from the menu bar. Showing the main window restores the Dock icon.") }
        static var host: String { localized("Host") }
        static var name: String { localized("Computer name") }
        static var discovery: String { localized("Discoverable on the local network") }
        static var deviceEnrollment: String { localized("Allow new device enrollment") }
        static var network: String { localized("Network") }
        static var networkSubtitle: String { localized("Connection, WAN mapping, and media recovery") }
        static var addressFamily: String { localized("Address family") }
        static var port: String { localized("Port") }
        static func connectionPortDetail(_ value: Int) -> String {
            localizedFormat(
                "Use this same port in Shadow. Default: %@",
                value.formatted(.number.grouping(.never))
            )
        }
        static var upnpMappingDetail: String {
            localized(
                "UPnP automatically maps the connection and streaming ports required by authenticated WAN clients."
            )
        }
        static var upnp: String { localized("UPnP port mapping") }
        static var fecPercentage: String { localized("Forward error correction (%)") }
        static var advanced: String { localized("Advanced") }
        static var advancedSubtitle: String { localized("Lifecycle commands and host process automation") }
        static var preparationCommands: String { localized("Preparation commands") }
        static var stateCommands: String { localized("State commands") }
        static var serverCommands: String { localized("Server commands") }
        static var commandName: String { localized("Name") }
        static var command: String { localized("Command") }
        static var undoCommand: String { localized("Undo command") }
        static var systemAuthentication: String { localized("Unlock with Touch ID") }
        static var systemAuthenticationDetail: String { localized("Touch ID confirmation is required when this option is enabled.") }
        static let fecOptions = [5, 10, 15, 20, 25, 30, 40, 50]

        static func percentageTitle(_ percentage: Int) -> String {
            localizedFormat("Percentage value", percentage.formatted())
        }

        static func addressFamilyTitle(_ family: LumenNetworkAddressFamily) -> String {
            switch family {
            case .ipv4: localized("IPv4")
            case .dualStack: localized("IPv4 and IPv6")
            }
        }

    }

    enum Diagnostics {
        static var subtitle: String { localized("Live state from the native host runtime") }
        static var runtimeWarning: String { localized("Runtime warning") }
        static var runtimeWarnings: String { localized("Runtime warnings") }
        static var videoCapture: String { localized("Video capture") }
        static var audioCapture: String { localized("Audio capture") }
        static var applicationRecords: String { localized("Application records") }
        static var lastRuntimeEvent: String { localized("Last runtime event") }
        static var lastError: String { localized("Last error") }

        static func runtimeWarningMessage(code: Int, fallback: String) -> String {
            if code == 13 {
                let summary = localized(
                    "The stream is active, but Lumen could not safely turn off the physical display."
                )
                return fallback.isEmpty ? summary : "\(summary) \(fallback)"
            }

            if code == 14 {
                let summary = localized(
                    "Lumen could not apply remote pointer motion to the active display."
                )
                return fallback.isEmpty ? summary : "\(summary) \(fallback)"
            }

            return switch code {
            case 0:
                localized("UPnP could not find a compatible gateway.")
            case 1:
                localized("UPnP could not determine this Mac's local network address.")
            case 2:
                localized("UPnP could not configure the requested port mapping.")
            case 3:
                localized("UPnP could not configure the requested IPv6 pinhole.")
            case 4:
                localized("UPnP could not remove the previous port mapping.")
            case 5:
                localized("The native session transport failed.")
            case 6:
                localized("The native capture session could not start. Check Screen Recording permission and Diagnostics.")
            default:
                fallback
            }
        }
    }

    enum Recovery {
        static var damagedTitle: String { localized("Owner data is damaged") }
        static var damagedDetail: String { localized("Reset Lumen to remove the damaged account and all host settings. Diagnostic logs will be kept.") }
        static var unavailableTitle: String { localized("Owner storage is unavailable") }
        static var unavailableDetail: String { localized("Lumen could not open its local account store. Check disk access or reset the host configuration.") }
        static var factoryResetTitle: String { localized("Factory Reset Lumen") }
        static var factoryResetDetail: String { localized("This removes the owner account, enrolled devices, applications, streaming settings, host certificates, display state, and cached covers. Logs are kept for diagnostics.") }
        static var factoryResetPrompt: String { localized("Type RESET to continue.") }
        static let factoryResetConfirmation = "RESET"
    }

    enum HostState {
        static var ownerSetupRequired: String { localized("Owner account setup is required") }
        static var ready: String { localized("Ready for streaming and remote input") }
        static var permissionsRequired: String { localized("Screen Recording and Accessibility permissions are required") }
        static var screenRecordingRequired: String { localized("Screen Recording permission is required") }
        static var accessibilityRequired: String { localized("Accessibility permission is required for remote input") }
        static var runtimeStopped: String { localized("Lumen host runtime stopped.") }
        static var passwordConfirmationMismatch: String { localized("The password confirmation does not match.") }
    }
}
