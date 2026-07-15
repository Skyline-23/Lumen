import Foundation
import LumenEngineBridge

public struct LumenApplicationCommand: Codable, Equatable, Sendable {
    public var run: String
    public var undo: String
    public var elevated: Bool

    public init(run: String = "", undo: String = "", elevated: Bool = false) {
        self.run = run
        self.undo = undo
        self.elevated = elevated
    }

    enum CodingKeys: String, CodingKey {
        case run = "do"
        case undo
        case elevated
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        run = try values.decodeIfPresent(String.self, forKey: .run) ?? ""
        undo = try values.decodeIfPresent(String.self, forKey: .undo) ?? ""
        elevated = try values.decodeIfPresent(Bool.self, forKey: .elevated) ?? false
    }
}

public struct LumenApplication: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var detachedCommands: [String]
    public var preparationCommands: [LumenApplicationCommand]
    public var stateCommands: [LumenApplicationCommand]
    public var workingDirectory: String
    public var output: String
    public var imagePath: String
    public var gamepad: String
    public var elevated: Bool
    public var autoDetach: Bool
    public var waitForAllProcesses: Bool
    public var exitTimeout: Int
    public var virtualDisplay: Bool
    public var scaleFactor: Int
    public var excludeGlobalPreparationCommands: Bool
    public var excludeGlobalStateCommands: Bool
    public var useApplicationIdentity: Bool
    public var perClientApplicationIdentity: Bool
    public var terminateOnPause: Bool

    public init(
        id: String = "",
        name: String,
        command: String = "",
        detachedCommands: [String] = [],
        preparationCommands: [LumenApplicationCommand] = [],
        stateCommands: [LumenApplicationCommand] = [],
        workingDirectory: String = "",
        output: String = "",
        imagePath: String = "",
        gamepad: String = "",
        elevated: Bool = false,
        autoDetach: Bool = true,
        waitForAllProcesses: Bool = true,
        exitTimeout: Int = 5,
        virtualDisplay: Bool = false,
        scaleFactor: Int = 100,
        excludeGlobalPreparationCommands: Bool = false,
        excludeGlobalStateCommands: Bool = false,
        useApplicationIdentity: Bool = false,
        perClientApplicationIdentity: Bool = false,
        terminateOnPause: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.detachedCommands = detachedCommands
        self.preparationCommands = preparationCommands
        self.stateCommands = stateCommands
        self.workingDirectory = workingDirectory
        self.output = output
        self.imagePath = imagePath
        self.gamepad = gamepad
        self.elevated = elevated
        self.autoDetach = autoDetach
        self.waitForAllProcesses = waitForAllProcesses
        self.exitTimeout = exitTimeout
        self.virtualDisplay = virtualDisplay
        self.scaleFactor = scaleFactor
        self.excludeGlobalPreparationCommands = excludeGlobalPreparationCommands
        self.excludeGlobalStateCommands = excludeGlobalStateCommands
        self.useApplicationIdentity = useApplicationIdentity
        self.perClientApplicationIdentity = perClientApplicationIdentity
        self.terminateOnPause = terminateOnPause
    }

    enum CodingKeys: String, CodingKey {
        case id = "uuid"
        case name
        case command = "cmd"
        case detachedCommands = "detached"
        case preparationCommands = "prep-cmd"
        case stateCommands = "state-cmd"
        case workingDirectory = "working-dir"
        case output
        case imagePath = "image-path"
        case gamepad
        case elevated
        case autoDetach = "auto-detach"
        case waitForAllProcesses = "wait-all"
        case exitTimeout = "exit-timeout"
        case virtualDisplay = "virtual-display"
        case scaleFactor = "scale-factor"
        case excludeGlobalPreparationCommands = "exclude-global-prep-cmd"
        case excludeGlobalStateCommands = "exclude-global-state-cmd"
        case useApplicationIdentity = "use-app-identity"
        case perClientApplicationIdentity = "per-client-app-identity"
        case terminateOnPause = "terminate-on-pause"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try values.decode(String.self, forKey: .name)
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        detachedCommands = try values.decodeIfPresent([String].self, forKey: .detachedCommands) ?? []
        preparationCommands = try values.decodeIfPresent([LumenApplicationCommand].self, forKey: .preparationCommands) ?? []
        stateCommands = try values.decodeIfPresent([LumenApplicationCommand].self, forKey: .stateCommands) ?? []
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        output = try values.decodeIfPresent(String.self, forKey: .output) ?? ""
        imagePath = try values.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        gamepad = try values.decodeIfPresent(String.self, forKey: .gamepad) ?? ""
        elevated = try values.decodeIfPresent(Bool.self, forKey: .elevated) ?? false
        autoDetach = try values.decodeIfPresent(Bool.self, forKey: .autoDetach) ?? true
        waitForAllProcesses = try values.decodeIfPresent(Bool.self, forKey: .waitForAllProcesses) ?? true
        exitTimeout = try values.decodeIfPresent(Int.self, forKey: .exitTimeout) ?? 5
        virtualDisplay = try values.decodeIfPresent(Bool.self, forKey: .virtualDisplay) ?? false
        scaleFactor = try values.decodeIfPresent(Int.self, forKey: .scaleFactor) ?? 100
        excludeGlobalPreparationCommands = try values.decodeIfPresent(Bool.self, forKey: .excludeGlobalPreparationCommands) ?? false
        excludeGlobalStateCommands = try values.decodeIfPresent(Bool.self, forKey: .excludeGlobalStateCommands) ?? false
        useApplicationIdentity = try values.decodeIfPresent(Bool.self, forKey: .useApplicationIdentity) ?? false
        perClientApplicationIdentity = try values.decodeIfPresent(Bool.self, forKey: .perClientApplicationIdentity) ?? false
        terminateOnPause = try values.decodeIfPresent(Bool.self, forKey: .terminateOnPause) ?? false
    }
}

public enum LumenApplicationCatalogError: Error, LocalizedError, Sendable {
    case incompatibleABI(expected: UInt32, actual: UInt32)
    case unavailable
    case invalidApplication
    case storageUnavailable
    case corruptData
    case engineStatus(UInt32)

    public var errorDescription: String? {
        switch self {
        case let .incompatibleABI(expected, actual):
            "Lumen engine ABI mismatch (expected \(expected), received \(actual))."
        case .unavailable:
            "The application catalog could not be opened."
        case .invalidApplication:
            "The application configuration is invalid."
        case .storageUnavailable:
            "The application catalog could not be saved."
        case .corruptData:
            "The application catalog is damaged."
        case let .engineStatus(status):
            "The Lumen engine returned application status \(status)."
        }
    }
}

public actor LumenApplicationCatalogStore {
    private struct Document: Codable {
        var applications: [LumenApplication]

        enum CodingKeys: String, CodingKey {
            case applications = "apps"
        }
    }

    public static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen", isDirectory: true)
            .appendingPathComponent("apps.json", isDirectory: false)
    }

    private let handle: LumenEngineHandle

    public init(fileURL: URL = LumenApplicationCatalogStore.defaultFileURL) throws {
        let actualVersion = LumenEngineBridgeABIVersion()
        guard actualVersion == LUMEN_ENGINE_ABI_VERSION else {
            throw LumenApplicationCatalogError.incompatibleABI(
                expected: LUMEN_ENGINE_ABI_VERSION,
                actual: actualVersion
            )
        }
        try Self.installBundledCatalogIfNeeded(at: fileURL)
        var openedHandle: OpaquePointer?
        let status = fileURL.path.withCString { path in
            lumen_application_catalog_open(path, &openedHandle)
        }
        try Self.requireSuccess(status)
        guard let openedHandle else {
            throw LumenApplicationCatalogError.unavailable
        }
        handle = LumenEngineHandle(openedHandle, destructor: lumen_application_catalog_destroy)
    }

    public func applications() throws -> [LumenApplication] {
        let requiredSize = lumen_application_catalog_json_size(handle.rawValue)
        guard requiredSize > 1 else {
            throw LumenApplicationCatalogError.corruptData
        }
        var buffer = Array<CChar>(repeating: 0, count: requiredSize)
        let status = buffer.withUnsafeMutableBufferPointer { buffer in
            lumen_application_catalog_copy_json(handle.rawValue, buffer.baseAddress, buffer.count)
        }
        try Self.requireSuccess(status)
        let data = Data(lumenStringFromCString(buffer).utf8)
        return try JSONDecoder().decode(Document.self, from: data).applications
    }

    public func save(_ application: LumenApplication) throws {
        let data = try JSONEncoder().encode(application)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LumenApplicationCatalogError.invalidApplication
        }
        let status = json.withCString { lumen_application_catalog_upsert_json(handle.rawValue, $0) }
        try Self.requireSuccess(status)
    }

    public func delete(applicationID: String) throws {
        try Self.requireSuccess(
            applicationID.withCString { lumen_application_catalog_delete(handle.rawValue, $0) }
        )
    }

    public func reorder(applicationIDs: [String]) throws {
        let data = try JSONEncoder().encode(applicationIDs)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LumenApplicationCatalogError.invalidApplication
        }
        try Self.requireSuccess(
            json.withCString { lumen_application_catalog_reorder_json(handle.rawValue, $0) }
        )
    }

    private static func installBundledCatalogIfNeeded(at fileURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              let bundledURL = Bundle.main.url(
                  forResource: "apps",
                  withExtension: "json",
                  subdirectory: "assets"
              ) else {
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: bundledURL, to: fileURL)
    }

    private static func requireSuccess(_ status: LumenEngineStatus) throws {
        switch status {
        case LumenEngineStatusOk:
            return
        case LumenEngineStatusInvalidArgument:
            throw LumenApplicationCatalogError.invalidApplication
        case LumenEngineStatusStorageError:
            throw LumenApplicationCatalogError.storageUnavailable
        case LumenEngineStatusCorruptData:
            throw LumenApplicationCatalogError.corruptData
        default:
            throw LumenApplicationCatalogError.engineStatus(status.rawValue)
        }
    }
}
