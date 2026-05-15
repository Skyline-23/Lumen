import Foundation

public enum LumenProtocolDynamicRangeTransport: Equatable, Sendable {
    case sdr
    case fullFrameHDR
    case frameGatedHDR
    case sdrBaseHDROverlay
}

public struct LumenProtocolSinkCapability: Equatable, Sendable {
    public let prefersHDR: Bool
    public let supportsHDRTileOverlay: Bool
    public let supportsPerFrameHDRMetadata: Bool
    public let supportsEncodedTileStream: Bool

    public init(
        prefersHDR: Bool,
        supportsHDRTileOverlay: Bool,
        supportsPerFrameHDRMetadata: Bool,
        supportsEncodedTileStream: Bool
    ) {
        self.prefersHDR = prefersHDR
        self.supportsHDRTileOverlay = supportsHDRTileOverlay
        self.supportsPerFrameHDRMetadata = supportsPerFrameHDRMetadata
        self.supportsEncodedTileStream = supportsEncodedTileStream
    }
}

public struct LumenProtocolEncodedTileLayout: Equatable, Sendable {
    public let tileCount: UInt32
    public let encodedLaneCount: UInt32

    public init(tileCount: UInt32, encodedLaneCount: UInt32) {
        self.tileCount = max(1, tileCount)
        self.encodedLaneCount = max(1, encodedLaneCount)
    }

    public var isSingleFrame: Bool {
        tileCount <= 1 && encodedLaneCount <= 1
    }
}

public enum LumenProtocolPresentationCompletionRule: Equatable, Sendable {
    case fullFrame
    case perTileAfterLanePrime
}

public enum LumenProtocolPresentationContract: Equatable, Sendable {
    case singleFrame
    case primedPerTileUpdate

    public static func resolve(
        requestedTransport: LumenProtocolDynamicRangeTransport,
        sinkCapability: LumenProtocolSinkCapability,
        sourceLayout: LumenProtocolEncodedTileLayout
    ) -> LumenProtocolPresentationContract {
        guard requestedTransport == .sdrBaseHDROverlay,
              sinkCapability.prefersHDR,
              sinkCapability.supportsHDRTileOverlay,
              sinkCapability.supportsPerFrameHDRMetadata,
              sinkCapability.supportsEncodedTileStream,
              !sourceLayout.isSingleFrame
        else {
            return .singleFrame
        }

        return .primedPerTileUpdate
    }

    public var wireName: String {
        switch self {
        case .singleFrame:
            return "single-frame"
        case .primedPerTileUpdate:
            return "primed-per-tile-update"
        }
    }

    public var completionRule: LumenProtocolPresentationCompletionRule {
        switch self {
        case .singleFrame:
            return .fullFrame
        case .primedPerTileUpdate:
            return .perTileAfterLanePrime
        }
    }
}

