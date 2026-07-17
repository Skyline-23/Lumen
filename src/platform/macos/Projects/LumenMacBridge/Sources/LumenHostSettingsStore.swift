import Foundation

@frozen public struct LumenNetworkPortPlan: Equatable, Sendable {
    public static let defaultConnectionPort = 47_990
    public static let validConnectionPortRange = 1_030...65_515

    public let basePort: Int
    public let controlHTTPSPort: Int
    public let nativeMediaUDPPort: Int
    public let nativeSessionQUICPort: Int

    public init?(connectionPort: Int) {
        guard Self.validConnectionPortRange.contains(connectionPort) else {
            return nil
        }
        let basePort = connectionPort - 1
        self.basePort = basePort
        controlHTTPSPort = connectionPort
        nativeMediaUDPPort = basePort + 9
        nativeSessionQUICPort = basePort + 21
    }

    public static var `default`: Self {
        guard let plan = Self(connectionPort: defaultConnectionPort) else {
            preconditionFailure("The Lumen default connection port must produce a valid port plan")
        }
        return plan
    }
}

@frozen public enum LumenNetworkAddressFamily: String, CaseIterable, Hashable, Sendable {
    case ipv4
    case dualStack = "both"
}

@frozen public enum LumenEncryptionMode: Int, CaseIterable, Hashable, Sendable {
    case disabled = 0
    case opportunistic = 1
    case required = 2
}

@frozen public enum LumenLogLevel: String, CaseIterable, Hashable, Sendable {
    case verbose
    case debug
    case info
    case warning
    case error
    case fatal
    case none
}

@frozen public enum LumenRemoteAccessScope: String, CaseIterable, Hashable, Sendable {
    case thisComputer = "pc"
    case localNetwork = "lan"
    case anywhere = "wan"
}

@frozen public enum LumenExternalIPMode: String, CaseIterable, Hashable, Sendable {
    case automatic
    case disabled
}

public struct LumenPrepCommand: Equatable, Sendable {
    public var run: String
    public var undo: String

    public init(run: String = "", undo: String = "") {
        self.run = run
        self.undo = undo
    }
}

public struct LumenServerCommand: Equatable, Sendable {
    public var name: String
    public var command: String

    public init(name: String = "", command: String = "") {
        self.name = name
        self.command = command
    }
}

public struct LumenNativeHostSettings: Equatable, Sendable {
    public var workspacePolicy: LumenMacWorkspacePolicy
    public var systemAuthenticationEnabled: Bool
    public var name: String
    public var discoveryEnabled: Bool
    public var deviceEnrollmentEnabled: Bool
    public var notifyPreReleases: Bool
    public var globalPrepCommands: [LumenPrepCommand]
    public var globalStateCommands: [LumenPrepCommand]
    public var serverCommands: [LumenServerCommand]
    public var adapterSelector: String
    public var outputSelector: String
    public var fallbackDisplayMode: String
    public var audioSink: String
    public var streamAudio: Bool
    public var keyboardInput: Bool
    public var mouseInput: Bool
    public var controllerInput: Bool
    public var controllerBackButtonTimeoutMilliseconds: Int
    public var mapRightAltToWindowsKey: Bool
    public var highResolutionScrolling: Bool
    public var nativePenAndTouch: Bool
    public var rumbleForwarding: Bool
    public var addressFamily: LumenNetworkAddressFamily
    public var port: Int
    public var upnpEnabled: Bool
    public var remoteAccessScope: LumenRemoteAccessScope
    public var externalIPMode: LumenExternalIPMode
    public var lanEncryption: LumenEncryptionMode
    public var wanEncryption: LumenEncryptionMode
    public var pingTimeoutMilliseconds: Int
    public var fecPercentage: Int
    public var logLevel: LumenLogLevel
    public var applicationsFilePath: String
    public var credentialsFilePath: String
    public var logFilePath: String
    public var privateKeyPath: String
    public var certificatePath: String
    public var stateFilePath: String

    public var networkPortPlan: LumenNetworkPortPlan {
        LumenNetworkPortPlan(connectionPort: port) ?? .default
    }

    public static var defaults: Self {
        let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen", isDirectory: true)
        return Self(
            workspacePolicy: .coexist,
            systemAuthenticationEnabled: false,
            name: Host.current().localizedName ?? "Lumen",
            discoveryEnabled: true,
            deviceEnrollmentEnabled: true,
            notifyPreReleases: false,
            globalPrepCommands: [],
            globalStateCommands: [],
            serverCommands: [],
            adapterSelector: "automatic",
            outputSelector: "automatic",
            fallbackDisplayMode: "1920x1080x60",
            audioSink: "system-default",
            streamAudio: true,
            keyboardInput: true,
            mouseInput: true,
            controllerInput: true,
            controllerBackButtonTimeoutMilliseconds: -1,
            mapRightAltToWindowsKey: false,
            highResolutionScrolling: true,
            nativePenAndTouch: true,
            rumbleForwarding: true,
            addressFamily: .ipv4,
            port: LumenNetworkPortPlan.defaultConnectionPort,
            upnpEnabled: false,
            remoteAccessScope: .localNetwork,
            externalIPMode: .automatic,
            lanEncryption: .disabled,
            wanEncryption: .opportunistic,
            pingTimeoutMilliseconds: 10_000,
            fecPercentage: 20,
            logLevel: .info,
            applicationsFilePath: supportDirectory.appendingPathComponent("apps.json").path,
            credentialsFilePath: supportDirectory.appendingPathComponent("lumen_state.json").path,
            logFilePath: supportDirectory.appendingPathComponent("lumen.log").path,
            privateKeyPath: supportDirectory.appendingPathComponent("credentials/cakey.pem").path,
            certificatePath: supportDirectory.appendingPathComponent("credentials/cacert.pem").path,
            stateFilePath: supportDirectory.appendingPathComponent("lumen_state.json").path
        )
    }

    public var runtimeArguments: [String] {
        let requiredArguments = [
            "host_name=\(name)",
            "enable_discovery=\(discoveryEnabled)",
            "device_enrollment_enabled=\(deviceEnrollmentEnabled)",
            "notify_pre_releases=\(notifyPreReleases)",
            "workspace_policy=\(runtimeWorkspacePolicy)",
            "global_prep_cmd=\(Self.prepCommandsJSON(globalPrepCommands))",
            "global_state_cmd=\(Self.prepCommandsJSON(globalStateCommands))",
            "server_cmd=\(Self.serverCommandsJSON(serverCommands))",
            "fallback_mode=\(fallbackDisplayMode)",
            "stream_audio=\(streamAudio)",
            "keyboard=\(keyboardInput)",
            "mouse=\(mouseInput)",
            "controller=\(controllerInput)",
            "back_button_timeout=\(controllerBackButtonTimeoutMilliseconds)",
            "key_rightalt_to_key_win=\(mapRightAltToWindowsKey)",
            "high_resolution_scrolling=\(highResolutionScrolling)",
            "native_pen_touch=\(nativePenAndTouch)",
            "forward_rumble=\(rumbleForwarding)",
            "address_family=\(addressFamily.rawValue)",
            "port=\(networkPortPlan.basePort)",
            "upnp=\(upnpEnabled)",
            "origin_admin_allowed=\(remoteAccessScope.rawValue)",
            "lan_encryption_mode=\(lanEncryption.rawValue)",
            "wan_encryption_mode=\(wanEncryption.rawValue)",
            "ping_timeout=\(pingTimeoutMilliseconds)",
            "fec_percentage=\(fecPercentage)",
            "min_log_level=\(logLevel.rawValue)",
            "file_apps=\(applicationsFilePath)",
            "credentials_file=\(credentialsFilePath)",
            "log_path=\(logFilePath)",
            "pkey=\(privateKeyPath)",
            "cert=\(certificatePath)",
            "file_state=\(stateFilePath)"
        ]
        let optionalArguments = [
            ("adapter_name", adapterSelector, "automatic"),
            ("output_name", outputSelector, "automatic"),
            ("audio_sink", audioSink, "system-default")
        ].compactMap { name, value, automaticValue in
            value == automaticValue ? nil : "\(name)=\(value)"
        }
        return requiredArguments + optionalArguments
    }

    private var runtimeWorkspacePolicy: String {
        switch workspacePolicy {
        case .coexist: "coexist"
        case .promoteVirtualMain: "promote-virtual-main"
        case .focusedWorkspace: "focused-workspace"
        case .isolatedWorkspace: "isolated-workspace"
        }
    }

    private static func prepCommandsJSON(_ commands: [LumenPrepCommand]) -> String {
        jsonString(commands.compactMap { command in
            let run = command.run.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !run.isEmpty else { return nil }
            return ["run": run, "undo": command.undo, "privilege": "user"]
        })
    }

    private static func serverCommandsJSON(_ commands: [LumenServerCommand]) -> String {
        jsonString(commands.compactMap { command in
            let name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let invocation = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !invocation.isEmpty else { return nil }
            return ["name": name, "command": invocation, "privilege": "user"]
        })
    }

    private static func jsonString(_ value: [[String: String]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}

public enum LumenHostSettingsError: Error, Equatable, LocalizedError, Sendable {
    case invalidValue

    public var errorDescription: String? {
        "One or more host settings are invalid."
    }
}

public actor LumenHostSettingsStore {
    private enum Key {
        static let workspacePolicy = "host.workspace-policy"
        static let systemAuthentication = "security.system-authentication"
        static let name = "host.name"
        static let discovery = "host.discovery"
        static let deviceEnrollment = "security.device-enrollment-enabled"
        static let notifyPreReleases = "general.notify-pre-releases"
        static let globalPrepCommands = "commands.prep"
        static let globalStateCommands = "commands.state"
        static let serverCommands = "commands.server"
        static let adapterSelector = "stream.adapter-selector"
        static let outputSelector = "stream.output-selector"
        static let fallbackDisplayMode = "stream.fallback-display-mode"
        static let audioSink = "audio.sink"
        static let streamAudio = "audio.stream"
        static let keyboardInput = "input.keyboard"
        static let mouseInput = "input.mouse"
        static let controllerInput = "input.controller"
        static let controllerBackButtonTimeout = "input.controller-back-button-timeout-ms"
        static let mapRightAltToWindowsKey = "input.map-right-alt-to-windows-key"
        static let highResolutionScrolling = "input.high-resolution-scrolling"
        static let nativePenAndTouch = "input.native-pen-touch"
        static let rumbleForwarding = "input.rumble"
        static let addressFamily = "network.address-family"
        static let port = "network.port"
        static let portSemanticsVersion = "network.port-semantics-version"
        static let upnp = "network.upnp"
        static let remoteAccessScope = "network.remote-access-scope"
        static let externalIPMode = "network.external-ip-mode"
        static let lanEncryption = "network.lan-encryption"
        static let wanEncryption = "network.wan-encryption"
        static let pingTimeout = "network.ping-timeout-ms"
        static let fecPercentage = "network.fec-percentage"
        static let logLevel = "diagnostics.log-level"
        static let applicationsFilePath = "files.applications"
        static let credentialsFilePath = "files.credentials"
        static let logFilePath = "files.log"
        static let privateKeyPath = "files.private-key"
        static let certificatePath = "files.certificate"
        static let stateFilePath = "files.state"
    }

    private let suiteName: String?

    public init(suiteName: String? = nil) throws {
        if let suiteName, UserDefaults(suiteName: suiteName) == nil {
            throw LumenHostSettingsError.invalidValue
        }
        self.suiteName = suiteName
    }

    public func snapshot() throws -> LumenNativeHostSettings {
        try Self.load(defaults: makeDefaults())
    }

    public func save(_ settings: LumenNativeHostSettings) throws {
        let settings = try Self.validated(settings)
        let defaults = try makeDefaults()
        defaults.set(Self.workspaceName(settings.workspacePolicy), forKey: Key.workspacePolicy)
        defaults.set(settings.systemAuthenticationEnabled, forKey: Key.systemAuthentication)
        defaults.set(settings.name, forKey: Key.name)
        defaults.set(settings.discoveryEnabled, forKey: Key.discovery)
        defaults.set(settings.deviceEnrollmentEnabled, forKey: Key.deviceEnrollment)
        defaults.set(settings.notifyPreReleases, forKey: Key.notifyPreReleases)
        defaults.set(Self.prepCommandRecords(settings.globalPrepCommands), forKey: Key.globalPrepCommands)
        defaults.set(Self.prepCommandRecords(settings.globalStateCommands), forKey: Key.globalStateCommands)
        defaults.set(Self.serverCommandRecords(settings.serverCommands), forKey: Key.serverCommands)
        defaults.set(settings.adapterSelector, forKey: Key.adapterSelector)
        defaults.set(settings.outputSelector, forKey: Key.outputSelector)
        defaults.set(settings.fallbackDisplayMode, forKey: Key.fallbackDisplayMode)
        defaults.set(settings.audioSink, forKey: Key.audioSink)
        defaults.set(settings.streamAudio, forKey: Key.streamAudio)
        defaults.set(settings.keyboardInput, forKey: Key.keyboardInput)
        defaults.set(settings.mouseInput, forKey: Key.mouseInput)
        defaults.set(settings.controllerInput, forKey: Key.controllerInput)
        defaults.set(settings.controllerBackButtonTimeoutMilliseconds, forKey: Key.controllerBackButtonTimeout)
        defaults.set(settings.mapRightAltToWindowsKey, forKey: Key.mapRightAltToWindowsKey)
        defaults.set(settings.highResolutionScrolling, forKey: Key.highResolutionScrolling)
        defaults.set(settings.nativePenAndTouch, forKey: Key.nativePenAndTouch)
        defaults.set(settings.rumbleForwarding, forKey: Key.rumbleForwarding)
        defaults.set(settings.addressFamily.rawValue, forKey: Key.addressFamily)
        defaults.set(settings.port, forKey: Key.port)
        defaults.set(1, forKey: Key.portSemanticsVersion)
        defaults.set(settings.upnpEnabled, forKey: Key.upnp)
        defaults.set(settings.remoteAccessScope.rawValue, forKey: Key.remoteAccessScope)
        defaults.set(settings.externalIPMode.rawValue, forKey: Key.externalIPMode)
        defaults.set(settings.lanEncryption.rawValue, forKey: Key.lanEncryption)
        defaults.set(settings.wanEncryption.rawValue, forKey: Key.wanEncryption)
        defaults.set(settings.pingTimeoutMilliseconds, forKey: Key.pingTimeout)
        defaults.set(settings.fecPercentage, forKey: Key.fecPercentage)
        defaults.set(settings.logLevel.rawValue, forKey: Key.logLevel)
        defaults.set(settings.applicationsFilePath, forKey: Key.applicationsFilePath)
        defaults.set(settings.credentialsFilePath, forKey: Key.credentialsFilePath)
        defaults.set(settings.logFilePath, forKey: Key.logFilePath)
        defaults.set(settings.privateKeyPath, forKey: Key.privateKeyPath)
        defaults.set(settings.certificatePath, forKey: Key.certificatePath)
        defaults.set(settings.stateFilePath, forKey: Key.stateFilePath)
    }

    public func workspacePolicy() throws -> LumenMacWorkspacePolicy {
        try snapshot().workspacePolicy
    }

    public func isSystemAuthenticationEnabled() -> Bool {
        guard let defaults = try? makeDefaults() else {
            return false
        }
        return (try? Self.load(defaults: defaults).systemAuthenticationEnabled) ?? false
    }

    public func setSystemAuthenticationEnabled(_ enabled: Bool) {
        var settings = (try? snapshot()) ?? .defaults
        settings.systemAuthenticationEnabled = enabled
        try? save(settings)
    }

    private func makeDefaults() throws -> UserDefaults {
        guard let suiteName else {
            return .standard
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw LumenHostSettingsError.invalidValue
        }
        return defaults
    }

    public static func resetStandardDefaults(bundleIdentifier: String?) {
        guard let bundleIdentifier else {
            return
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
    }

    public nonisolated static func currentSnapshot() -> LumenNativeHostSettings {
        (try? load(defaults: .standard)) ?? .defaults
    }

    private nonisolated static func load(defaults: UserDefaults) throws -> LumenNativeHostSettings {
        let fallback = LumenNativeHostSettings.defaults
        let settings = LumenNativeHostSettings(
            workspacePolicy: workspacePolicy(defaults.string(forKey: Key.workspacePolicy)) ?? fallback.workspacePolicy,
            systemAuthenticationEnabled: bool(defaults, Key.systemAuthentication, fallback.systemAuthenticationEnabled),
            name: defaults.string(forKey: Key.name) ?? fallback.name,
            discoveryEnabled: bool(defaults, Key.discovery, fallback.discoveryEnabled),
            deviceEnrollmentEnabled: bool(
                defaults,
                Key.deviceEnrollment,
                fallback.deviceEnrollmentEnabled
            ),
            notifyPreReleases: bool(defaults, Key.notifyPreReleases, fallback.notifyPreReleases),
            globalPrepCommands: prepCommands(defaults, Key.globalPrepCommands),
            globalStateCommands: prepCommands(defaults, Key.globalStateCommands),
            serverCommands: serverCommands(defaults, Key.serverCommands),
            adapterSelector: canonicalSelector(
                defaults,
                Key.adapterSelector,
                fallback.adapterSelector
            ),
            outputSelector: canonicalSelector(
                defaults,
                Key.outputSelector,
                fallback.outputSelector
            ),
            fallbackDisplayMode: defaults.string(forKey: Key.fallbackDisplayMode) ?? fallback.fallbackDisplayMode,
            audioSink: canonicalSelector(defaults, Key.audioSink, fallback.audioSink),
            streamAudio: bool(defaults, Key.streamAudio, fallback.streamAudio),
            keyboardInput: bool(defaults, Key.keyboardInput, fallback.keyboardInput),
            mouseInput: bool(defaults, Key.mouseInput, fallback.mouseInput),
            controllerInput: bool(defaults, Key.controllerInput, fallback.controllerInput),
            controllerBackButtonTimeoutMilliseconds: integer(
                defaults,
                Key.controllerBackButtonTimeout,
                fallback.controllerBackButtonTimeoutMilliseconds
            ),
            mapRightAltToWindowsKey: bool(defaults, Key.mapRightAltToWindowsKey, fallback.mapRightAltToWindowsKey),
            highResolutionScrolling: bool(defaults, Key.highResolutionScrolling, fallback.highResolutionScrolling),
            nativePenAndTouch: bool(defaults, Key.nativePenAndTouch, fallback.nativePenAndTouch),
            rumbleForwarding: bool(defaults, Key.rumbleForwarding, fallback.rumbleForwarding),
            addressFamily: LumenNetworkAddressFamily(rawValue: defaults.string(forKey: Key.addressFamily) ?? "") ?? fallback.addressFamily,
            port: connectionPort(defaults, fallback: fallback.port),
            upnpEnabled: bool(defaults, Key.upnp, fallback.upnpEnabled),
            remoteAccessScope: LumenRemoteAccessScope(rawValue: defaults.string(forKey: Key.remoteAccessScope) ?? "") ?? fallback.remoteAccessScope,
            externalIPMode: LumenExternalIPMode(
                rawValue: defaults.string(forKey: Key.externalIPMode) ?? ""
            ) ?? fallback.externalIPMode,
            lanEncryption: LumenEncryptionMode(rawValue: integer(defaults, Key.lanEncryption, fallback.lanEncryption.rawValue)) ?? fallback.lanEncryption,
            wanEncryption: LumenEncryptionMode(rawValue: integer(defaults, Key.wanEncryption, fallback.wanEncryption.rawValue)) ?? fallback.wanEncryption,
            pingTimeoutMilliseconds: integer(defaults, Key.pingTimeout, fallback.pingTimeoutMilliseconds),
            fecPercentage: integer(defaults, Key.fecPercentage, fallback.fecPercentage),
            logLevel: LumenLogLevel(rawValue: defaults.string(forKey: Key.logLevel) ?? "") ?? fallback.logLevel,
            applicationsFilePath: defaults.string(forKey: Key.applicationsFilePath) ?? fallback.applicationsFilePath,
            credentialsFilePath: defaults.string(forKey: Key.credentialsFilePath) ?? fallback.credentialsFilePath,
            logFilePath: defaults.string(forKey: Key.logFilePath) ?? fallback.logFilePath,
            privateKeyPath: defaults.string(forKey: Key.privateKeyPath) ?? fallback.privateKeyPath,
            certificatePath: defaults.string(forKey: Key.certificatePath) ?? fallback.certificatePath,
            stateFilePath: defaults.string(forKey: Key.stateFilePath) ?? fallback.stateFilePath
        )
        return try validated(settings)
    }

    private nonisolated static func validated(_ settings: LumenNativeHostSettings) throws -> LumenNativeHostSettings {
        var settings = settings
        settings.name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.name.isEmpty,
              settings.name.count <= 64,
              settings.adapterSelector == "automatic",
              settings.outputSelector == "automatic",
              settings.audioSink == "system-default",
              LumenNetworkPortPlan.validConnectionPortRange.contains(settings.port),
              (1_000...120_000).contains(settings.pingTimeoutMilliseconds),
              (1...255).contains(settings.fecPercentage),
              (-1...60_000).contains(settings.controllerBackButtonTimeoutMilliseconds),
              settings.fallbackDisplayMode.range(
                  of: #"^\d+x\d+x\d+(\.\d+)?$"#,
                  options: .regularExpression
              ) != nil,
              [
                  "1280x720x60",
                  "1920x1080x60",
                  "2560x1440x60",
                  "2560x1440x120",
                  "3840x2160x60",
                  "3840x2160x120"
              ].contains(settings.fallbackDisplayMode),
              !settings.applicationsFilePath.isEmpty,
              !settings.credentialsFilePath.isEmpty,
              !settings.logFilePath.isEmpty,
              !settings.privateKeyPath.isEmpty,
              !settings.certificatePath.isEmpty,
              !settings.stateFilePath.isEmpty else {
            throw LumenHostSettingsError.invalidValue
        }
        return settings
    }

    private nonisolated static func bool(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private nonisolated static func integer(_ defaults: UserDefaults, _ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private nonisolated static func connectionPort(_ defaults: UserDefaults, fallback: Int) -> Int {
        guard defaults.object(forKey: Key.port) != nil else {
            return fallback
        }
        let storedPort = defaults.integer(forKey: Key.port)
        guard defaults.integer(forKey: Key.portSemanticsVersion) < 1 else {
            return storedPort
        }
        let (migratedPort, overflowed) = storedPort.addingReportingOverflow(1)
        guard !overflowed,
              LumenNetworkPortPlan.validConnectionPortRange.contains(migratedPort) else {
            return storedPort
        }
        defaults.set(migratedPort, forKey: Key.port)
        defaults.set(1, forKey: Key.portSemanticsVersion)
        return migratedPort
    }

    private nonisolated static func canonicalSelector(
        _ defaults: UserDefaults,
        _ key: String,
        _ fallback: String
    ) -> String {
        guard let value = defaults.string(forKey: key), !value.isEmpty else {
            return fallback
        }
        return value
    }

    private nonisolated static func prepCommandRecords(_ commands: [LumenPrepCommand]) -> [[String: String]] {
        commands.map { ["run": $0.run, "undo": $0.undo] }
    }

    private nonisolated static func serverCommandRecords(_ commands: [LumenServerCommand]) -> [[String: String]] {
        commands.map { ["name": $0.name, "command": $0.command] }
    }

    private nonisolated static func prepCommands(_ defaults: UserDefaults, _ key: String) -> [LumenPrepCommand] {
        guard let records = defaults.array(forKey: key) as? [[String: String]] else {
            return []
        }
        return records.map { LumenPrepCommand(run: $0["run"] ?? "", undo: $0["undo"] ?? "") }
    }

    private nonisolated static func serverCommands(_ defaults: UserDefaults, _ key: String) -> [LumenServerCommand] {
        guard let records = defaults.array(forKey: key) as? [[String: String]] else {
            return []
        }
        return records.map { LumenServerCommand(name: $0["name"] ?? "", command: $0["command"] ?? "") }
    }

    private nonisolated static func workspaceName(_ policy: LumenMacWorkspacePolicy) -> String {
        switch policy {
        case .coexist: "coexist"
        case .promoteVirtualMain: "promote-virtual-main"
        case .focusedWorkspace: "focused-workspace"
        case .isolatedWorkspace: "isolated-workspace"
        }
    }

    private nonisolated static func workspacePolicy(_ name: String?) -> LumenMacWorkspacePolicy? {
        switch name {
        case "coexist": .coexist
        case "promote-virtual-main": .promoteVirtualMain
        case "focused-workspace": .focusedWorkspace
        case "isolated-workspace": .isolatedWorkspace
        default: nil
        }
    }
}

@objcMembers
public final class LumenNativeRuntimeSettingsSnapshot: NSObject {
    public let runtimeArguments: [String]
    public let applicationsFilePath: String
    public let credentialsFilePath: String
    public let stateFilePath: String

    public override init() {
        let settings = LumenHostSettingsStore.currentSnapshot()
        runtimeArguments = settings.runtimeArguments
        applicationsFilePath = settings.applicationsFilePath
        credentialsFilePath = settings.credentialsFilePath
        stateFilePath = settings.stateFilePath
        super.init()
    }
}
