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

    public var wireName: String {
        switch self {
        case .fullFrame:
            return "full-frame"
        case .perTileAfterLanePrime:
            return "per-tile-after-lane-prime"
        }
    }
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

public enum LumenProtocolControlWireLayout {
    public static let headerSize: UInt16 = 4

    public enum HDRFrameState {
        public static let packetType: UInt16 = 0x3003
        public static let version: UInt8 = 1

        public enum Flags {
            public static let hasStaticMetadata: UInt8 = 1 << 0
            public static let hasOverlayRegions: UInt8 = 1 << 1
        }

        public enum OverlayRegionFlags {
            public static let hasMetadata: UInt8 = 1 << 0
        }

        public enum Offsets {
            public static let version: UInt16 = LumenProtocolControlWireLayout.headerSize
            public static let frameDynamicRange: UInt16 = LumenProtocolControlWireLayout.headerSize + 1
            public static let flags: UInt16 = LumenProtocolControlWireLayout.headerSize + 2
            public static let effectiveFromFrameNumber: UInt16 = LumenProtocolControlWireLayout.headerSize + 4
            public static let overlayRegionCount: UInt16 = LumenProtocolControlWireLayout.headerSize + 8
            public static let staticMetadata: UInt16 = LumenProtocolControlWireLayout.headerSize + 12
        }
    }

    public enum EncodedTileFrameState {
        public static let packetType: UInt16 = 0x3004
        public static let version: UInt8 = 1
        public static let packetLength: UInt16 = 52
        public static let payloadLength: UInt16 = packetLength - LumenProtocolControlWireLayout.headerSize

        public enum Flags {
            public static let hasTileRegion: UInt8 = 1 << 0
        }

        public enum Offsets {
            public static let version: UInt16 = LumenProtocolControlWireLayout.headerSize
            public static let flags: UInt16 = LumenProtocolControlWireLayout.headerSize + 1
            public static let effectiveFromFrameNumber: UInt16 = LumenProtocolControlWireLayout.headerSize + 4
            public static let frameGroupId: UInt16 = LumenProtocolControlWireLayout.headerSize + 8
            public static let tileIndex: UInt16 = LumenProtocolControlWireLayout.headerSize + 16
            public static let tileCount: UInt16 = LumenProtocolControlWireLayout.headerSize + 20
            public static let encodedLaneIndex: UInt16 = LumenProtocolControlWireLayout.headerSize + 24
            public static let encodedLaneCount: UInt16 = LumenProtocolControlWireLayout.headerSize + 28
            public static let tileOriginX: UInt16 = LumenProtocolControlWireLayout.headerSize + 32
            public static let tileOriginY: UInt16 = LumenProtocolControlWireLayout.headerSize + 36
            public static let tileWidth: UInt16 = LumenProtocolControlWireLayout.headerSize + 40
            public static let tileHeight: UInt16 = LumenProtocolControlWireLayout.headerSize + 44
        }
    }
}

public protocol LumenProtocolAdapter: Sendable {
    var requestedTransport: LumenProtocolDynamicRangeTransport { get }
    var negotiatedTransport: LumenProtocolDynamicRangeTransport { get }
    var sinkCapability: LumenProtocolSinkCapability { get }
    var sourceLayout: LumenProtocolEncodedTileLayout { get }
}

public extension LumenProtocolAdapter {
    var presentationContract: LumenProtocolPresentationContract {
        LumenProtocolPresentationContract.resolve(
            requestedTransport: negotiatedTransport,
            sinkCapability: sinkCapability,
            sourceLayout: sourceLayout
        )
    }

    var presentationContractName: String {
        presentationContract.wireName
    }

    var presentationCompletionName: String {
        presentationContract.completionRule.wireName
    }
}
