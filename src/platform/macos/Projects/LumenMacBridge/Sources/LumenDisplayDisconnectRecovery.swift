import CoreGraphics
import CryptoKit
import Darwin
import Foundation

public struct LumenDisconnectRecoveryEnvironment: Codable, Equatable, Sendable {
    public let bootSessionUUID: String
    public let windowServerSessionUUID: String

    public init(
        bootSessionUUID: String,
        windowServerSessionUUID: String
    ) {
        self.bootSessionUUID = bootSessionUUID
        self.windowServerSessionUUID = windowServerSessionUUID
    }

    public static func current() throws -> Self {
        guard let bootSessionUUID = sysctlString("kern.bootsessionuuid"),
              !bootSessionUUID.isEmpty,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let windowServerSessionUUID =
              session["CGSSessionUniqueSessionUUID"] as? String,
              !windowServerSessionUUID.isEmpty else {
            throw LumenPhysicalDisplayControlFailure(
                code: .physicalDisplayDisconnectUnverified
            )
        }
        return Self(
            bootSessionUUID: bootSessionUUID,
            windowServerSessionUUID: windowServerSessionUUID
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var byteCount = 0
        guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0,
              byteCount > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname(name, &bytes, &byteCount, nil, 0) == 0 else {
            return nil
        }
        return String(
            bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            encoding: .utf8
        )
    }
}

enum LumenDisconnectRecoveryPhase: String, Codable, Sendable {
    case planned
    case disableAttempted
    case disableSucceeded

    var requiresEnableRecovery: Bool {
        self != .planned
    }
}

struct LumenDisconnectRecoveryEntry: Codable, Equatable, Sendable {
    let display: LumenDisplayDisconnectCapabilityDisplay
    let phase: LumenDisconnectRecoveryPhase
}

struct LumenDisconnectRecoveryRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let environment: LumenDisconnectRecoveryEnvironment
    let recoveryGeneration: UInt64
    let topologyChecksum: String
    let entries: [LumenDisconnectRecoveryEntry]
    let checksum: String

    static func staged(
        environment: LumenDisconnectRecoveryEnvironment,
        recoveryGeneration: UInt64,
        topology: LumenMacPhysicalDisplayTopology,
        physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay]
    ) throws -> Self {
        let entries = physicalDisplays
            .sorted { $0.displayID < $1.displayID }
            .map {
                LumenDisconnectRecoveryEntry(
                    display: $0,
                    phase: .planned
                )
            }
        return make(
            environment: environment,
            recoveryGeneration: recoveryGeneration,
            topologyChecksum: try lumenDisconnectTopologyChecksum(topology),
            entries: entries
        )
    }

    func updating(
        displayID: CGDirectDisplayID,
        phase: LumenDisconnectRecoveryPhase
    ) -> Self {
        Self.make(
            environment: environment,
            recoveryGeneration: recoveryGeneration,
            topologyChecksum: topologyChecksum,
            entries: entries.map { entry in
                guard entry.display.displayID == displayID else {
                    return entry
                }
                return LumenDisconnectRecoveryEntry(
                    display: entry.display,
                    phase: phase
                )
            }
        )
    }

    func matches(
        recoveryGeneration: UInt64,
        topology: LumenMacPhysicalDisplayTopology
    ) throws -> Bool {
        let currentTopologyChecksum = try lumenDisconnectTopologyChecksum(topology)
        return schemaVersion == Self.currentSchemaVersion
            && self.recoveryGeneration == recoveryGeneration
            && topologyChecksum == currentTopologyChecksum
            && checksum == Self.checksum(
                schemaVersion: schemaVersion,
                environment: environment,
                recoveryGeneration: self.recoveryGeneration,
                topologyChecksum: topologyChecksum,
                entries: entries
            )
            && entries.allSatisfy { $0.display.hasStableIdentity }
            && Set(entries.map(\.display.stableIdentity)).count == entries.count
    }

    private static func make(
        environment: LumenDisconnectRecoveryEnvironment,
        recoveryGeneration: UInt64,
        topologyChecksum: String,
        entries: [LumenDisconnectRecoveryEntry]
    ) -> Self {
        Self(
            schemaVersion: currentSchemaVersion,
            environment: environment,
            recoveryGeneration: recoveryGeneration,
            topologyChecksum: topologyChecksum,
            entries: entries,
            checksum: checksum(
                schemaVersion: currentSchemaVersion,
                environment: environment,
                recoveryGeneration: recoveryGeneration,
                topologyChecksum: topologyChecksum,
                entries: entries
            )
        )
    }

    private static func checksum(
        schemaVersion: Int,
        environment: LumenDisconnectRecoveryEnvironment,
        recoveryGeneration: UInt64,
        topologyChecksum: String,
        entries: [LumenDisconnectRecoveryEntry]
    ) -> String {
        let payload = [
            String(schemaVersion),
            environment.bootSessionUUID,
            environment.windowServerSessionUUID,
            String(recoveryGeneration),
            topologyChecksum,
            entries.map { entry in
                [
                    String(entry.display.displayID),
                    String(entry.display.vendorID),
                    String(entry.display.productID),
                    String(entry.display.serialNumber),
                    entry.display.builtin ? "1" : "0",
                    entry.phase.rawValue
                ].joined(separator: ":")
            }.joined(separator: ",")
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct LumenDisconnectRecoveryFileStore: Sendable {
    public static let productionRecordURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lumen", isDirectory: true)
        .appendingPathComponent("display-disconnect-recovery-v1.json")

    public static var production: Self {
        Self(recordURL: productionRecordURL)
    }

    public let recordURL: URL

    public init(recordURL: URL) {
        self.recordURL = recordURL
    }

    func load() throws -> LumenDisconnectRecoveryRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            LumenDisconnectRecoveryRecord.self,
            from: Data(contentsOf: recordURL)
        )
    }

    func persist(_ record: LumenDisconnectRecoveryRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try persistDurably(encoder.encode(record))
    }

    func revoke() throws {
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: recordURL)
        try synchronizeDirectory(recordURL.deletingLastPathComponent())
    }

    private func persistDurably(_ data: Data) throws {
        let directoryURL = recordURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(recordURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporaryURL.path, recordURL.path) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try synchronizeDirectory(directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

private func lumenDisconnectTopologyChecksum(
    _ topology: LumenMacPhysicalDisplayTopology
) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(topology))
        .map { String(format: "%02x", $0) }
        .joined()
}
