import LumenMacBridge

enum LumenCopy {
    static let productName = "Lumen"
    static let productNameUppercase = "LUMEN"

    enum Navigation {
        static let overview = "Overview"
        static let applications = "Applications"
        static let settings = "Settings"
        static let diagnostics = "Diagnostics"
    }

    enum Status {
        static let running = "Running"
        static let stopped = "Stopped"
        static let active = "Active"
        static let idle = "Idle"
        static let ready = "Ready"
        static let configured = "Configured"

        static func runtime(isRunning: Bool) -> String {
            isRunning ? running : stopped
        }

        static func stream(isRunning: Bool) -> String {
            isRunning ? active : idle
        }
    }

    enum Action {
        static let add = "Add"
        static let edit = "Edit"
        static let delete = "Delete"
        static let cancel = "Cancel"
        static let save = "Save"
        static let request = "Request"
        static let openSettings = "Open Settings"
        static let settings = "Settings"
        static let quit = "Quit"
        static let signIn = "Sign in"
        static let createAccount = "Create account"
        static let forgotPassword = "Forgot password?"
        static let lockSettings = "Lock now"
        static let reloadApplications = "Reload applications"
        static let restartHost = "Restart host"
        static let showWindow = "Show Lumen Window"
        static let restartLumen = "Restart Lumen"
        static let factoryReset = "Factory Reset..."
        static let factoryResetLumen = "Factory Reset Lumen..."
        static let quitLumen = "Quit Lumen"
        static let eraseAllSettings = "Erase All Settings"
        static let close = "Close"
        static let checkAgain = "Check Again"
        static let unlockWithSystemAuthentication = "Unlock with Touch ID"
        static let forceStopStream = "Force Stop Stream"
    }

    enum Account {
        static let ownerAccount = "Owner account"
        static let account = "Account"
        static let ownerName = "Owner ID"
        static let password = "Password"
        static let passwordMinimum = "Password (12 characters minimum)"
        static let confirmPassword = "Confirm password"
        static let signedInAs = "Signed in as"
        static let systemAuthenticationReason = "Unlock Lumen settings with Touch ID"
        static let enableSystemAuthenticationReason = "Confirm Touch ID before enabling it for Lumen"
        static let systemAuthenticationUnavailable = "Touch ID is unavailable on this Mac."
        static let systemAuthenticationFailed = "Touch ID authentication did not complete."

        static func signedInAs(_ username: String) -> String {
            "\(signedInAs) \(username)"
        }
    }

    enum Permission {
        static let systemAccess = "System access"
        static let screenRecording = "Screen Recording"
        static let accessibility = "Accessibility"
        static let dragPanelTitle = "Add Lumen to System Settings"
        static let accessibilityDragDetail = "In System Settings, open Accessibility and drag Lumen into the app list below."
        static let screenRecordingDragDetail = "In System Settings, open Screen & System Audio Recording and drag Lumen into the app list below."
        static let dragInstruction = "Drag this app into the permission list"
        static let dragHint = "After adding Lumen, enable its switch and check again."
        static let stillRequired = "The permission is still disabled. Enable Lumen in System Settings, then check again."
        static let dragAccessibilityHelp = "Drag the Lumen application into the open System Settings permission list."
    }

    enum Onboarding {
        static let headline = "Your computer,\nready anywhere."
        static let introduction = "Set up one owner account. Lumen keeps streaming, applications, and enrolled devices under your control."
        static let localCredentials = "Local credentials"
        static let nativeHostControls = "Native host controls"
        static let remoteDeviceAccess = "Remote device access"
        static let credentialsNotice = "Credentials never leave this computer in plaintext."
        static let opening = "Opening Lumen"
        static let openingDetail = "Checking the local owner account and host state."
        static let createOwnerTitle = "Create the owner account"
        static let createOwnerDetail = "This account controls this host, enrolled devices, and remote settings."
        static let passwordStorageNotice = "The password is stored only as an Argon2id hash on this computer."
        static let unlockTitle = "Unlock Lumen"
        static let unlockDetail = "Sign in to manage this host. Streaming services continue independently."
    }

    enum Overview {
        static let subtitle = "Host readiness and active streaming state"
        static let hostRuntime = "Host runtime"
        static let currentStream = "Current stream"
        static let hostControls = "Host controls"
    }

    enum Applications {
        static let subtitle = "Choose what remote clients can launch"
        static let newApplication = "New application"
        static let emptyTitle = "No applications"
        static let emptyDetail = "Add a desktop or application entry for remote clients."
        static let streamDesktop = "Stream the desktop"
        static let virtualDisplay = "Virtual display"
        static let addTitle = "Add application"
        static let editTitle = "Edit application"
        static let identity = "Identity"
        static let name = "Name"
        static let coverPath = "Cover path"
        static let launch = "Launch"
        static let command = "Command"
        static let workingDirectory = "Working directory"
        static let detachedCommands = "Detached commands (one per line)"
        static let display = "Display"
        static let createVirtualDisplay = "Create a virtual display"
        static let processBehavior = "Process behavior"
        static let detachAutomatically = "Detach automatically"
        static let waitForAllProcesses = "Wait for all processes"
        static let terminateWhenPaused = "Terminate when paused"
        static let runElevated = "Run elevated"

        static func exitTimeout(seconds: Int) -> String {
            "Exit timeout: \(seconds) seconds"
        }

        static func desktopScale(percent: Int) -> String {
            "Desktop scale: \(percent)%"
        }
    }

    enum Settings {
        struct LocaleOption {
            let code: String
            let title: String
        }

        static let subtitle = "Native host behavior and account controls"
        static let security = "Security"
        static let securitySubtitle = "Protect local access and recovery controls"
        static let general = "General"
        static let generalSubtitle = "Computer identity, discovery, language, and logging"
        static let application = "Application"
        static let hideDockIconWhenMainWindowCloses = "Hide Dock icon when the main window closes"
        static let hideDockIconWhenMainWindowClosesDetail = "Lumen stays available from the menu bar. Showing the main window restores the Dock icon."
        static let host = "Host"
        static let hostName = "Computer name"
        static let locale = "Language"
        static let discovery = "Discoverable on the local network"
        static let deviceEnrollment = "Allow new device enrollment"
        static let notifyPreReleases = "Notify about pre-release updates"
        static let streaming = "Streaming"
        static let streamingSubtitle = "Display, workspace, and capture device behavior"
        static let display = "Display"
        static let adapterName = "Display adapter"
        static let outputName = "Display output"
        static let fallbackDisplayMode = "Fallback display mode"
        static let audio = "Audio"
        static let audioSubtitle = "Computer audio capture and device selection"
        static let audioSink = "Audio device"
        static let audioSinkDetail = "Leave empty to use native system audio capture, or enter an input device name."
        static let streamAudio = "Stream computer audio"
        static let input = "Input"
        static let inputSubtitle = "Keyboard, pointer, touch, and controller forwarding"
        static let controller = "Controller"
        static let keyboard = "Keyboard"
        static let pointer = "Pointer and touch"
        static let keyboardInput = "Keyboard input"
        static let mouseInput = "Mouse input"
        static let controllerInput = "Game controller input"
        static let controllerBackButtonTimeout = "Back button timeout (ms)"
        static let mapRightAltToWindowsKey = "Map Right Alt to Windows key"
        static let highResolutionScrolling = "High-resolution scrolling"
        static let nativePenAndTouch = "Native pen and touch"
        static let rumbleForwarding = "Controller rumble"
        static let network = "Network"
        static let networkSubtitle = "Discovery, remote access, encryption, and recovery"
        static let addressFamily = "Address family"
        static let port = "Base port"
        static let upnp = "UPnP port mapping"
        static let externalIP = "External IP address"
        static let encryption = "Encryption and recovery"
        static let lanEncryption = "LAN encryption"
        static let wanEncryption = "Remote encryption"
        static let pingTimeout = "Connection timeout (ms)"
        static let fecPercentage = "Forward error correction (%)"
        static let advanced = "Advanced"
        static let advancedSubtitle = "Lifecycle commands and host process automation"
        static let preparationCommands = "Preparation commands"
        static let stateCommands = "State commands"
        static let serverCommands = "Server commands"
        static let commandName = "Name"
        static let command = "Command"
        static let undoCommand = "Undo command"
        static let logging = "Logging"
        static let logLevel = "Log level"
        static let systemAuthentication = "Unlock with Touch ID"
        static let systemAuthenticationDetail = "Touch ID confirmation is required when this option is enabled."
        static let automatic = "Automatic"
        static let disabled = "Disabled"
        static let displayModeOptions = [
            "1280x720x60",
            "1920x1080x60",
            "2560x1440x60",
            "2560x1440x120",
            "3840x2160x60",
            "3840x2160x120",
        ]
        static let controllerTimeoutOptions = [-1, 250, 500, 750, 1_000, 1_500, 2_000]
        static let connectionTimeoutOptions = [1_000, 3_000, 5_000, 10_000, 15_000, 30_000, 60_000, 120_000]
        static let fecOptions = [5, 10, 15, 20, 25, 30, 40, 50]

        static func displayModeTitle(_ mode: String) -> String {
            let components = mode.split(separator: "x")
            guard components.count == 3 else {
                return mode
            }
            return "\(components[0]) × \(components[1]) at \(components[2]) Hz"
        }

        static func controllerTimeoutTitle(_ milliseconds: Int) -> String {
            milliseconds < 0 ? disabled : millisecondsTitle(milliseconds)
        }

        static func millisecondsTitle(_ milliseconds: Int) -> String {
            "\(milliseconds.formatted()) ms"
        }

        static func percentageTitle(_ percentage: Int) -> String {
            "\(percentage)%"
        }
        static let locales = [
            LocaleOption(code: "bg", title: "Български"),
            LocaleOption(code: "cs", title: "Čeština"),
            LocaleOption(code: "de", title: "Deutsch"),
            LocaleOption(code: "en", title: "English"),
            LocaleOption(code: "en_GB", title: "English, UK"),
            LocaleOption(code: "en_US", title: "English, US"),
            LocaleOption(code: "es", title: "Español"),
            LocaleOption(code: "fr", title: "Français"),
            LocaleOption(code: "hu", title: "Magyar"),
            LocaleOption(code: "it", title: "Italiano"),
            LocaleOption(code: "ja", title: "日本語"),
            LocaleOption(code: "ko", title: "한국어"),
            LocaleOption(code: "pl", title: "Polski"),
            LocaleOption(code: "pt", title: "Português"),
            LocaleOption(code: "pt_BR", title: "Português, Brasil"),
            LocaleOption(code: "ru", title: "Русский"),
            LocaleOption(code: "sv", title: "Svenska"),
            LocaleOption(code: "tr", title: "Türkçe"),
            LocaleOption(code: "uk", title: "Українська"),
            LocaleOption(code: "vi", title: "Tiếng Việt"),
            LocaleOption(code: "zh", title: "简体中文"),
            LocaleOption(code: "zh_TW", title: "繁體中文"),
        ]

        static func addressFamilyTitle(_ family: LumenNetworkAddressFamily) -> String {
            switch family {
            case .ipv4: "IPv4"
            case .dualStack: "IPv4 and IPv6"
            }
        }

        static func encryptionTitle(_ mode: LumenEncryptionMode) -> String {
            switch mode {
            case .disabled: "Disabled"
            case .opportunistic: "When supported"
            case .required: "Required"
            }
        }

        static func logLevelTitle(_ level: LumenLogLevel) -> String {
            switch level {
            case .verbose: "Verbose"
            case .debug: "Debug"
            case .info: "Info"
            case .warning: "Warning"
            case .error: "Error"
            case .fatal: "Fatal only"
            case .none: "None"
            }
        }
    }

    enum Diagnostics {
        static let subtitle = "Live state from the native host runtime"
        static let runtimeWarning = "Runtime warning"
        static let runtimeWarnings = "Runtime warnings"
        static let videoCapture = "Video capture"
        static let audioCapture = "Audio capture"
        static let applicationRecords = "Application records"
        static let lastRuntimeEvent = "Last runtime event"
        static let lastError = "Last error"
    }

    enum Workspace {
        static let label = "Display workspace"
        static let nextSessionNotice = "Changes apply to the next stream session."

        static func title(for policy: LumenMacWorkspacePolicy) -> String {
            switch policy {
            case .coexist:
                "Keep physical displays active"
            case .promoteVirtualMain:
                "Make stream display primary"
            case .focusedWorkspace:
                "Focus selected app windows"
            case .isolatedWorkspace:
                "Isolate stream display"
            }
        }

        static func description(for policy: LumenMacWorkspacePolicy) -> String {
            switch policy {
            case .coexist:
                "Adds the stream display without moving the computer desktop or existing windows."
            case .promoteVirtualMain:
                "Makes the stream display primary while physical displays remain active."
            case .focusedWorkspace:
                "Makes the stream display primary and moves only windows selected for the stream."
            case .isolatedWorkspace:
                "Places physical displays outside the active workspace until the stream ends, then restores the previous layout."
            }
        }
    }

    enum Recovery {
        static let damagedTitle = "Owner data is damaged"
        static let damagedDetail = "Reset Lumen to remove the damaged account and all host settings. Diagnostic logs will be kept."
        static let unavailableTitle = "Owner storage is unavailable"
        static let unavailableDetail = "Lumen could not open its local account store. Check disk access or reset the host configuration."
        static let factoryResetTitle = "Factory Reset Lumen"
        static let factoryResetDetail = "This removes the owner account, enrolled devices, applications, streaming settings, host certificates, display state, and cached covers. Logs are kept for diagnostics."
        static let factoryResetPrompt = "Type RESET to continue."
        static let factoryResetConfirmation = "RESET"
    }

    enum HostState {
        static let ownerSetupRequired = "Owner account setup is required"
        static let ready = "Ready for streaming and remote input"
        static let permissionsRequired = "Screen Recording and Accessibility permissions are required"
        static let screenRecordingRequired = "Screen Recording permission is required"
        static let accessibilityRequired = "Accessibility permission is required for remote input"
        static let runtimeStopped = "Lumen host runtime stopped."
        static let passwordConfirmationMismatch = "The password confirmation does not match."
    }
}
