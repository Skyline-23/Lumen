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

public struct LumenProtocolPresentationSignal: Equatable, Sendable {
    public let requestedTransport: LumenProtocolDynamicRangeTransport
    public let negotiatedTransport: LumenProtocolDynamicRangeTransport
    public let sinkCapability: LumenProtocolSinkCapability
    public let sourceLayout: LumenProtocolEncodedTileLayout

    public init(
        requestedTransport: LumenProtocolDynamicRangeTransport,
        negotiatedTransport: LumenProtocolDynamicRangeTransport,
        sinkCapability: LumenProtocolSinkCapability,
        sourceLayout: LumenProtocolEncodedTileLayout
    ) {
        self.requestedTransport = requestedTransport
        self.negotiatedTransport = negotiatedTransport
        self.sinkCapability = sinkCapability
        self.sourceLayout = sourceLayout
    }
}

public struct LumenProtocolAdapterOutput: Equatable, Sendable {
    public let requestedTransport: LumenProtocolDynamicRangeTransport
    public let negotiatedTransport: LumenProtocolDynamicRangeTransport
    public let sinkCapability: LumenProtocolSinkCapability
    public let sourceLayout: LumenProtocolEncodedTileLayout
    public let presentationContract: LumenProtocolPresentationContract

    public init(
        requestedTransport: LumenProtocolDynamicRangeTransport,
        negotiatedTransport: LumenProtocolDynamicRangeTransport,
        sinkCapability: LumenProtocolSinkCapability,
        sourceLayout: LumenProtocolEncodedTileLayout
    ) {
        self.requestedTransport = requestedTransport
        self.negotiatedTransport = negotiatedTransport
        self.sinkCapability = sinkCapability
        self.sourceLayout = sourceLayout
        self.presentationContract = LumenProtocolPresentationContract.resolve(
            signal: LumenProtocolPresentationSignal(
                requestedTransport: requestedTransport,
                negotiatedTransport: negotiatedTransport,
                sinkCapability: sinkCapability,
                sourceLayout: sourceLayout
            )
        )
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
        resolve(
            signal: LumenProtocolPresentationSignal(
                requestedTransport: requestedTransport,
                negotiatedTransport: requestedTransport,
                sinkCapability: sinkCapability,
                sourceLayout: sourceLayout
            )
        )
    }

    public static func resolve(
        signal: LumenProtocolPresentationSignal
    ) -> LumenProtocolPresentationContract {
        guard signal.negotiatedTransport == .sdrBaseHDROverlay,
              signal.sinkCapability.prefersHDR,
              signal.sinkCapability.supportsHDRTileOverlay,
              signal.sinkCapability.supportsPerFrameHDRMetadata,
              signal.sinkCapability.supportsEncodedTileStream,
              !signal.sourceLayout.isSingleFrame
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

public protocol LumenProtocolAdapter: Sendable {
    var requestedTransport: LumenProtocolDynamicRangeTransport { get }
    var negotiatedTransport: LumenProtocolDynamicRangeTransport { get }
    var sinkCapability: LumenProtocolSinkCapability { get }
    var sourceLayout: LumenProtocolEncodedTileLayout { get }
    var output: LumenProtocolAdapterOutput { get }
}

public extension LumenProtocolAdapter {
    var output: LumenProtocolAdapterOutput {
        LumenProtocolAdapterOutput(
            requestedTransport: requestedTransport,
            negotiatedTransport: negotiatedTransport,
            sinkCapability: sinkCapability,
            sourceLayout: sourceLayout
        )
    }

    var presentationSignal: LumenProtocolPresentationSignal {
        LumenProtocolPresentationSignal(
            requestedTransport: requestedTransport,
            negotiatedTransport: negotiatedTransport,
            sinkCapability: sinkCapability,
            sourceLayout: sourceLayout
        )
    }

    var presentationContract: LumenProtocolPresentationContract {
        output.presentationContract
    }

    var presentationContractName: String {
        presentationContract.wireName
    }

    var presentationCompletionName: String {
        presentationContract.completionRule.wireName
    }
}
