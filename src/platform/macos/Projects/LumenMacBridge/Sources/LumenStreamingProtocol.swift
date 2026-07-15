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

    public init(
        prefersHDR: Bool,
        supportsHDRTileOverlay: Bool,
        supportsPerFrameHDRMetadata: Bool
    ) {
        self.prefersHDR = prefersHDR
        self.supportsHDRTileOverlay = supportsHDRTileOverlay
        self.supportsPerFrameHDRMetadata = supportsPerFrameHDRMetadata
    }
}

public struct LumenProtocolPresentationSignal: Equatable, Sendable {
    public let requestedTransport: LumenProtocolDynamicRangeTransport
    public let negotiatedTransport: LumenProtocolDynamicRangeTransport
    public let sinkCapability: LumenProtocolSinkCapability

    public init(
        requestedTransport: LumenProtocolDynamicRangeTransport,
        negotiatedTransport: LumenProtocolDynamicRangeTransport,
        sinkCapability: LumenProtocolSinkCapability
    ) {
        self.requestedTransport = requestedTransport
        self.negotiatedTransport = negotiatedTransport
        self.sinkCapability = sinkCapability
    }
}

public struct LumenProtocolAdapterOutput: Equatable, Sendable {
    public let requestedTransport: LumenProtocolDynamicRangeTransport
    public let negotiatedTransport: LumenProtocolDynamicRangeTransport
    public let sinkCapability: LumenProtocolSinkCapability
    public let presentationContract: LumenProtocolPresentationContract

    public init(
        requestedTransport: LumenProtocolDynamicRangeTransport,
        negotiatedTransport: LumenProtocolDynamicRangeTransport,
        sinkCapability: LumenProtocolSinkCapability
    ) {
        self.requestedTransport = requestedTransport
        self.negotiatedTransport = negotiatedTransport
        self.sinkCapability = sinkCapability
        self.presentationContract = LumenProtocolPresentationContract.resolve(
            signal: LumenProtocolPresentationSignal(
                requestedTransport: requestedTransport,
                negotiatedTransport: negotiatedTransport,
                sinkCapability: sinkCapability
            )
        )
    }
}

public enum LumenProtocolPresentationCompletionRule: Equatable, Sendable {
    case fullFrame

    public var wireName: String {
        switch self {
        case .fullFrame:
            return "full-frame"
        }
    }
}

public enum LumenProtocolPresentationContract: Equatable, Sendable {
    case singleFrame

    public static func resolve(
        requestedTransport: LumenProtocolDynamicRangeTransport,
        sinkCapability: LumenProtocolSinkCapability
    ) -> LumenProtocolPresentationContract {
        resolve(
            signal: LumenProtocolPresentationSignal(
                requestedTransport: requestedTransport,
                negotiatedTransport: requestedTransport,
                sinkCapability: sinkCapability
            )
        )
    }

    public static func resolve(
        signal _: LumenProtocolPresentationSignal
    ) -> LumenProtocolPresentationContract {
        .singleFrame
    }

    public var wireName: String {
        switch self {
        case .singleFrame:
            return "single-frame"
        }
    }

    public var completionRule: LumenProtocolPresentationCompletionRule {
        switch self {
        case .singleFrame:
            return .fullFrame
        }
    }
}

public protocol LumenProtocolAdapter: Sendable {
    var requestedTransport: LumenProtocolDynamicRangeTransport { get }
    var negotiatedTransport: LumenProtocolDynamicRangeTransport { get }
    var sinkCapability: LumenProtocolSinkCapability { get }
    var output: LumenProtocolAdapterOutput { get }
}

public extension LumenProtocolAdapter {
    var output: LumenProtocolAdapterOutput {
        LumenProtocolAdapterOutput(
            requestedTransport: requestedTransport,
            negotiatedTransport: negotiatedTransport,
            sinkCapability: sinkCapability
        )
    }

    var presentationSignal: LumenProtocolPresentationSignal {
        LumenProtocolPresentationSignal(
            requestedTransport: requestedTransport,
            negotiatedTransport: negotiatedTransport,
            sinkCapability: sinkCapability
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
