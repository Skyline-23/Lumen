import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import IOKit

public struct LumenDisplayDisconnectCapabilityEnvironment: Codable, Equatable, Sendable {
    public let osBuild: String
    public let hardwareIdentity: String

    public init(osBuild: String, hardwareIdentity: String) {
        self.osBuild = osBuild
        self.hardwareIdentity = hardwareIdentity
    }

    public static var current: Self {
        Self(
            osBuild: displayDisconnectSysctlString("kern.osversion")
                ?? "unknown-os-build",
            hardwareIdentity: [
                displayDisconnectPlatformUUID(),
                displayDisconnectSysctlString("hw.model"),
                displayDisconnectSysctlString("hw.targettype"),
            ]
            .compactMap { $0 }
            .joined(separator: "|")
            .nonEmptyDisplayDisconnectValue ?? "unknown-hardware"
        )
    }

    public var isResolved: Bool {
        !osBuild.isEmpty
            && osBuild != "unknown-os-build"
            && !hardwareIdentity.isEmpty
            && hardwareIdentity != "unknown-hardware"
    }
}

public struct LumenDisplayDisconnectCapabilityReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let osBuild: String
    public let hardwareIdentity: String
    public let symbolSource: LumenDisplayEnabledSymbolSource
    public let symbolName: String
    public let physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay]
    public let issuedAtUnixSeconds: Int64
    public let expiresAtUnixSeconds: Int64
    public let checksum: String

    public var physicalDisplayIDs: [CGDirectDisplayID] {
        physicalDisplays.map(\.displayID)
    }

    public init(
        schemaVersion: Int,
        osBuild: String,
        hardwareIdentity: String,
        symbolSource: LumenDisplayEnabledSymbolSource,
        symbolName: String,
        physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay],
        issuedAtUnixSeconds: Int64,
        expiresAtUnixSeconds: Int64,
        checksum: String
    ) {
        self.schemaVersion = schemaVersion
        self.osBuild = osBuild
        self.hardwareIdentity = hardwareIdentity
        self.symbolSource = symbolSource
        self.symbolName = symbolName
        self.physicalDisplays = physicalDisplays
        self.issuedAtUnixSeconds = issuedAtUnixSeconds
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
        self.checksum = checksum
    }

    public static func verified(
        environment: LumenDisplayDisconnectCapabilityEnvironment,
        probe: LumenDisplayEnabledSymbolProbe,
        physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay],
        issuedAtUnixSeconds: Int64,
        expiresAtUnixSeconds: Int64
    ) -> Self {
        let sortedDisplays = sorted(physicalDisplays)
        let checksum = checksum(
            schemaVersion: currentSchemaVersion,
            osBuild: environment.osBuild,
            hardwareIdentity: environment.hardwareIdentity,
            symbolSource: probe.source,
            symbolName: probe.symbolName,
            physicalDisplays: sortedDisplays,
            issuedAtUnixSeconds: issuedAtUnixSeconds,
            expiresAtUnixSeconds: expiresAtUnixSeconds
        )
        return Self(
            schemaVersion: currentSchemaVersion,
            osBuild: environment.osBuild,
            hardwareIdentity: environment.hardwareIdentity,
            symbolSource: probe.source,
            symbolName: probe.symbolName,
            physicalDisplays: sortedDisplays,
            issuedAtUnixSeconds: issuedAtUnixSeconds,
            expiresAtUnixSeconds: expiresAtUnixSeconds,
            checksum: checksum
        )
    }

    fileprivate func authorizes(
        environment: LumenDisplayDisconnectCapabilityEnvironment,
        probe: LumenDisplayEnabledSymbolProbe,
        physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay],
        currentTimeUnixSeconds: Int64
    ) -> Bool {
        let sortedDisplays = Self.sorted(physicalDisplays)
        let verifiedIdentities = self.physicalDisplays.map(\.stableIdentity).sorted()
        let currentIdentities = sortedDisplays.map(\.stableIdentity).sorted()
        guard environment.isResolved,
              schemaVersion == Self.currentSchemaVersion,
              !sortedDisplays.isEmpty,
              sortedDisplays.allSatisfy(\.hasStableIdentity),
              self.physicalDisplays.allSatisfy(\.hasStableIdentity),
              Set(verifiedIdentities).count == verifiedIdentities.count,
              Set(currentIdentities).count == currentIdentities.count,
              verifiedIdentities == currentIdentities,
              osBuild == environment.osBuild,
              hardwareIdentity == environment.hardwareIdentity,
              symbolSource == probe.source,
              symbolName == probe.symbolName,
              issuedAtUnixSeconds <= currentTimeUnixSeconds,
              currentTimeUnixSeconds < expiresAtUnixSeconds else {
            return false
        }
        return checksum == Self.checksum(
            schemaVersion: schemaVersion,
            osBuild: osBuild,
            hardwareIdentity: hardwareIdentity,
            symbolSource: symbolSource,
            symbolName: symbolName,
            physicalDisplays: self.physicalDisplays,
            issuedAtUnixSeconds: issuedAtUnixSeconds,
            expiresAtUnixSeconds: expiresAtUnixSeconds
        )
    }

    private static func checksum(
        schemaVersion: Int,
        osBuild: String,
        hardwareIdentity: String,
        symbolSource: LumenDisplayEnabledSymbolSource,
        symbolName: String,
        physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay],
        issuedAtUnixSeconds: Int64,
        expiresAtUnixSeconds: Int64
    ) -> String {
        let canonicalPayload = [
            String(schemaVersion),
            osBuild,
            hardwareIdentity,
            symbolSource.rawValue,
            symbolName,
            physicalDisplays.map {
                [
                    String($0.displayID),
                    String($0.vendorID),
                    String($0.productID),
                    String($0.serialNumber),
                    $0.builtin ? "1" : "0"
                ].joined(separator: ":")
            }.joined(separator: ","),
            String(issuedAtUnixSeconds),
            String(expiresAtUnixSeconds),
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(canonicalPayload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sorted(
        _ displays: [LumenDisplayDisconnectCapabilityDisplay]
    ) -> [LumenDisplayDisconnectCapabilityDisplay] {
        displays.sorted {
            if $0.stableIdentity != $1.stableIdentity {
                return $0.stableIdentity < $1.stableIdentity
            }
            return $0.displayID < $1.displayID
        }
    }
}

public protocol LumenDisplayDisconnectCapabilityVerifying: Sendable {
    func authorize(
        probe: LumenDisplayEnabledSymbolProbe,
        physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay]
    ) throws
}

public struct LumenDisplayDisconnectCapabilityFileVerifier:
    LumenDisplayDisconnectCapabilityVerifying,
    Sendable
{
    public static var production: Self {
        Self(
            receiptURL: LumenDisplayDisconnectCapabilityFileStore.productionReceiptURL,
            environment: .current
        )
    }

    private let receiptURL: URL
    private let environment: LumenDisplayDisconnectCapabilityEnvironment
    private let fixedCurrentTimeUnixSeconds: Int64?

    public init(
        receiptURL: URL,
        environment: LumenDisplayDisconnectCapabilityEnvironment,
        currentTimeUnixSeconds: Int64? = nil
    ) {
        self.receiptURL = receiptURL
        self.environment = environment
        fixedCurrentTimeUnixSeconds = currentTimeUnixSeconds
    }

    public func authorize(
        probe: LumenDisplayEnabledSymbolProbe,
        physicalDisplays: [LumenDisplayDisconnectCapabilityDisplay]
    ) throws {
        let receipt: LumenDisplayDisconnectCapabilityReceipt
        do {
            receipt = try JSONDecoder().decode(
                LumenDisplayDisconnectCapabilityReceipt.self,
                from: Data(contentsOf: receiptURL)
            )
        } catch {
            throw unverifiedFailure()
        }
        let currentTime = fixedCurrentTimeUnixSeconds
            ?? Int64(Date().timeIntervalSince1970)
        guard receipt.authorizes(
            environment: environment,
            probe: probe,
            physicalDisplays: physicalDisplays,
            currentTimeUnixSeconds: currentTime
        ) else {
            throw unverifiedFailure()
        }
    }

    private func unverifiedFailure() -> LumenPhysicalDisplayControlFailure {
        LumenPhysicalDisplayControlFailure(code: .physicalDisplayDisconnectUnverified)
    }
}

public struct LumenDisplayDisconnectCapabilityFileStore: Sendable {
    public static let legacyProductionReceiptURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lumen", isDirectory: true)
        .appendingPathComponent("display-disconnect-capability-v1.json")
    public static let productionReceiptURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lumen", isDirectory: true)
        .appendingPathComponent("display-disconnect-capability-v2.json")

    public static var production: Self {
        Self(receiptURL: productionReceiptURL)
    }

    public static var legacyProduction: Self {
        Self(receiptURL: legacyProductionReceiptURL)
    }

    public let receiptURL: URL

    public init(receiptURL: URL) {
        self.receiptURL = receiptURL
    }

    public func persist(_ receipt: LumenDisplayDisconnectCapabilityReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try persistDurably(encoder.encode(receipt))
    }

    public func revoke() throws {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: receiptURL)
        try synchronizeDirectory(receiptURL.deletingLastPathComponent())
    }

    private func persistDurably(_ data: Data) throws {
        let directoryURL = receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(receiptURL.lastPathComponent).\(UUID().uuidString).tmp"
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
            guard Darwin.rename(temporaryURL.path, receiptURL.path) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try synchronizeDirectory(directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

private func displayDisconnectSysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
        return nil
    }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
        return nil
    }
    let bytes = value
        .prefix { $0 != 0 }
        .map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func displayDisconnectPlatformUUID() -> String? {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice")
    )
    guard service != 0 else {
        return nil
    }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(
        service,
        kIOPlatformUUIDKey as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue() as? String
}

private extension String {
    var nonEmptyDisplayDisconnectValue: String? {
        isEmpty ? nil : self
    }
}
