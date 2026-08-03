import Foundation

@frozen public enum LumenMacWorkspaceContentSource: Equatable, Sendable {
    case targetWindows
    case desktopMirror(sourceDisplayID: UInt32)
}

public struct LumenMacWorkspaceSessionRequest: Sendable {
    public let displayKey: String
    public let policy: LumenMacWorkspacePolicy
    public let contentSource: LumenMacWorkspaceContentSource
    public let targetProcessIdentifiers: [Int32]
    public let displayMode: LumenMacDisplayModeRequest
    public let displayName: String
    public let refreshRate: Double
    public let managesCapture: Bool
    public let captureConfiguration: LumenMacCaptureConfiguration

    public init(
        displayKey: String = UUID().uuidString,
        policy: LumenMacWorkspacePolicy = .coexist,
        contentSource: LumenMacWorkspaceContentSource = .targetWindows,
        targetProcessIdentifiers: [Int32] = [],
        displayMode: LumenMacDisplayModeRequest,
        displayName: String = "Lumen Display",
        refreshRate: Double = 120,
        managesCapture: Bool = true,
        captureConfiguration: LumenMacCaptureConfiguration
    ) {
        self.displayKey = displayKey
        self.policy = policy
        self.contentSource = contentSource
        self.targetProcessIdentifiers = targetProcessIdentifiers
        self.displayMode = displayMode
        self.displayName = displayName
        self.refreshRate = max(refreshRate, 1)
        self.managesCapture = managesCapture
        self.captureConfiguration = captureConfiguration
    }
}

public enum LumenMacWorkspaceSessionError: Error, Equatable, LocalizedError, Sendable {
    case sessionAlreadyStarted
    case sessionNotStarted
    case recoveryDidNotComplete
    case virtualDisplayOwnershipMismatch
    case virtualDisplayModeSettlementUnavailable(UInt32)
    case virtualDisplayPublicationUnavailable(UInt32)
    case isolationCommandMissing

    public var errorDescription: String? {
        switch self {
        case .sessionAlreadyStarted:
            "a workspace session is already started"
        case .sessionNotStarted:
            "the workspace session has not started"
        case .recoveryDidNotComplete:
            "the previous workspace recovery did not complete"
        case .virtualDisplayOwnershipMismatch:
            "the owned virtual display identity changed during the workspace lifecycle"
        case .virtualDisplayModeSettlementUnavailable(let displayID):
            "owned virtual display \(displayID) did not finish its mode publication " +
                "before the settlement deadline"
        case .virtualDisplayPublicationUnavailable(let displayID):
            "owned virtual display \(displayID) did not reach stable capture readiness " +
                "before the publication deadline"
        case .isolationCommandMissing:
            "the workspace isolation command is missing"
        }
    }
}

public struct LumenMacWorkspaceActivationOutcome: Equatable, Sendable {
    public let isolationStatus: LumenMacWorkspaceIsolationStatus

    public init(isolationStatus: LumenMacWorkspaceIsolationStatus) {
        self.isolationStatus = isolationStatus
    }
}

struct LumenMacVirtualDisplayPersistentIdentity: Equatable, Sendable {
    let productID: UInt32
    let serialNumber: UInt32
}

// The public factory name is retained for source compatibility with bridge clients.
// swiftlint:disable:next type_name
public enum LumenMacVirtualDisplayConfigurationFactory {
    // The native host admits modes up to an 8K long edge in either orientation.
    // CGVirtualDisplay descriptor capacity is immutable, so reserve both axes
    // for the initial publication and every replacement display generation.
    private static let maximumStreamDimension: UInt32 = 7_680

    public static func make(
        geometry: LumenMacDisplayGeometry,
        request: LumenMacWorkspaceSessionRequest,
        refreshRate: Double? = nil
    ) throws -> LumenMacVirtualDisplayConfiguration {
        let colorProfile = try LumenMacDisplayColorResolver.resolve(
            hdrEnabled: request.captureConfiguration.usesHDRTransport,
            clientGamut: protocolRawGamut(request.captureConfiguration.virtualDisplayGamut),
            clientTransfer: protocolRawTransfer(request.captureConfiguration.virtualDisplayTransfer)
        )
        let configuration = LumenMacVirtualDisplayConfiguration()
        configuration.name = request.displayName
        let identity = persistentIdentity(forDisplayKey: request.displayKey)
        configuration.productID = identity.productID
        configuration.serialNumber = identity.serialNumber
        configuration.backingWidth = geometry.backingWidth
        configuration.backingHeight = geometry.backingHeight
        configuration.highDensity = request.displayMode.highDensity
        let maximumBackingDimension = maximumStreamDimension *
            (configuration.highDensity ? 2 : 1)
        configuration.maximumBackingWidth = max(
            geometry.backingWidth,
            maximumBackingDimension
        )
        configuration.maximumBackingHeight = max(
            geometry.backingHeight,
            maximumBackingDimension
        )
        configuration.logicalWidth = geometry.logicalWidth
        configuration.logicalHeight = geometry.logicalHeight
        configuration.refreshRate = max(refreshRate ?? request.refreshRate, 1)
        configuration.hdrEnabled = request.captureConfiguration.usesHDRTransport
        configuration.gamut = LumenMacVirtualDisplayGamut(
            rawValue: Int(colorProfile.gamutRawValue)
        )!
        configuration.transfer = LumenMacVirtualDisplayTransfer(
            rawValue: Int(colorProfile.transferRawValue)
        )!

        let capability = request.captureConfiguration.sinkRequest.capability
        configuration.currentEDRHeadroom = Double(capability.currentEDRHeadroom)
        configuration.potentialEDRHeadroom = Double(capability.potentialEDRHeadroom)
        configuration.currentPeakLuminanceNits = Double(capability.currentPeakLuminanceNits)
        configuration.potentialPeakLuminanceNits = Double(capability.potentialPeakLuminanceNits)
        return configuration
    }

    static func persistentIdentity(
        forDisplayKey displayKey: String
    ) -> LumenMacVirtualDisplayPersistentIdentity {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "dev.skyline23.lumen.virtual-display:\(displayKey)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        let rawProductID = UInt32((hash >> 32) & 0xFFFF)
        let rawSerialNumber = UInt32(truncatingIfNeeded: hash)
        return LumenMacVirtualDisplayPersistentIdentity(
            productID: rawProductID == 0 ? 1 : rawProductID,
            serialNumber: rawSerialNumber == 0 ? 1 : rawSerialNumber
        )
    }

    private static func protocolRawGamut(_ gamut: LumenClientSinkGamut) -> Int32 {
        switch gamut {
        case .displayP3:
            return 2
        case .rec2020:
            return 3
        case .srgb, .unknown:
            return gamut == .srgb ? 1 : 0
        }
    }

    private static func protocolRawTransfer(
        _ transfer: LumenClientSinkTransfer
    ) -> Int32 {
        switch transfer {
        case .pq:
            return 2
        case .hlg:
            return 3
        case .sdr, .unknown:
            return transfer == .sdr ? 1 : 0
        }
    }
}
