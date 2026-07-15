import CoreGraphics
import Darwin
import Foundation

public enum LumenDisplayEnabledSymbolSource: String, Equatable, Sendable {
    case skyLightSLS
    case skyLightCGS
    case verifiedCoreDisplay
}

public struct LumenDisplayEnabledSymbolRequest: Equatable, Sendable {
    public let source: LumenDisplayEnabledSymbolSource
    public let frameworkPath: String
    public let symbolName: String

    public init(
        source: LumenDisplayEnabledSymbolSource,
        frameworkPath: String,
        symbolName: String
    ) {
        self.source = source
        self.frameworkPath = frameworkPath
        self.symbolName = symbolName
    }
}

public protocol LumenDisplayEnabledInvoking {
    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Int32
}

public protocol LumenDisplayEnabledSymbolResolving {
    func resolve(
        _ request: LumenDisplayEnabledSymbolRequest
    ) -> (any LumenDisplayEnabledInvoking)?
}

public struct LumenVerifiedCoreDisplayEnabledABI: Equatable, Sendable {
    public let symbolName: String
    public let evidenceIdentifier: String

    public init(symbolName: String, evidenceIdentifier: String) {
        precondition(!symbolName.isEmpty)
        precondition(!evidenceIdentifier.isEmpty)
        self.symbolName = symbolName
        self.evidenceIdentifier = evidenceIdentifier
    }
}

public struct LumenPhysicalDisplayControlReceipt: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let enabled: Bool
    public let source: LumenDisplayEnabledSymbolSource
    public let symbolName: String
}

public struct LumenDisplayEnabledSymbolProbe: Equatable, Sendable {
    public let source: LumenDisplayEnabledSymbolSource
    public let symbolName: String
}

public enum LumenPhysicalDisplayControlCode: String, Equatable, Sendable {
    case privateSymbolUnavailable = "mac.display_disconnect.private_symbol_unavailable"
    case transactionRejected = "mac.display_disconnect.transaction_rejected"
}

public struct LumenPhysicalDisplayControlFailure: Error, Equatable, Sendable {
    public let code: LumenPhysicalDisplayControlCode
    public let status: Int32?
    public let source: LumenDisplayEnabledSymbolSource?

    public init(
        code: LumenPhysicalDisplayControlCode,
        status: Int32? = nil,
        source: LumenDisplayEnabledSymbolSource? = nil
    ) {
        self.code = code
        self.status = status
        self.source = source
    }
}

public struct LumenPhysicalDisplayControlAdapter {
    private static let skyLightPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let coreDisplayPath =
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"

    private let resolver: any LumenDisplayEnabledSymbolResolving
    private let verifiedCoreDisplayABI: LumenVerifiedCoreDisplayEnabledABI?

    public init(
        resolver: any LumenDisplayEnabledSymbolResolving,
        verifiedCoreDisplayABI: LumenVerifiedCoreDisplayEnabledABI? = nil
    ) {
        self.resolver = resolver
        self.verifiedCoreDisplayABI = verifiedCoreDisplayABI
    }

    public func setEnabled(
        _ enabled: Bool,
        for displayID: CGDirectDisplayID
    ) throws -> LumenPhysicalDisplayControlReceipt {
        let selection = try resolveSymbol()
        let status = selection.invoker.setEnabled(enabled, for: displayID)
        guard status == CGError.success.rawValue else {
            throw LumenPhysicalDisplayControlFailure(
                code: .transactionRejected,
                status: status,
                source: selection.request.source
            )
        }
        return LumenPhysicalDisplayControlReceipt(
            displayID: displayID,
            enabled: enabled,
            source: selection.request.source,
            symbolName: selection.request.symbolName
        )
    }

    public func probe() throws -> LumenDisplayEnabledSymbolProbe {
        let selection = try resolveSymbol()
        return LumenDisplayEnabledSymbolProbe(
            source: selection.request.source,
            symbolName: selection.request.symbolName
        )
    }

    private func resolveSymbol() throws -> (
        request: LumenDisplayEnabledSymbolRequest,
        invoker: any LumenDisplayEnabledInvoking
    ) {
        for request in symbolRequests {
            if let invoker = resolver.resolve(request) {
                return (request, invoker)
            }
        }
        throw LumenPhysicalDisplayControlFailure(code: .privateSymbolUnavailable)
    }

    private var symbolRequests: [LumenDisplayEnabledSymbolRequest] {
        var requests = [
            LumenDisplayEnabledSymbolRequest(
                source: .skyLightSLS,
                frameworkPath: Self.skyLightPath,
                symbolName: "SLSConfigureDisplayEnabled"
            ),
            LumenDisplayEnabledSymbolRequest(
                source: .skyLightCGS,
                frameworkPath: Self.skyLightPath,
                symbolName: "CGSConfigureDisplayEnabled"
            ),
        ]
        if let verifiedCoreDisplayABI {
            requests.append(
                LumenDisplayEnabledSymbolRequest(
                    source: .verifiedCoreDisplay,
                    frameworkPath: Self.coreDisplayPath,
                    symbolName: verifiedCoreDisplayABI.symbolName
                )
            )
        }
        return requests
    }
}

public final class LumenDlsymDisplayEnabledSymbolResolver:
    LumenDisplayEnabledSymbolResolving
{
    public init() {}

    public func resolve(
        _ request: LumenDisplayEnabledSymbolRequest
    ) -> (any LumenDisplayEnabledInvoking)? {
        guard let handle = dlopen(request.frameworkPath, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        guard let symbol = dlsym(handle, request.symbolName) else {
            dlclose(handle)
            return nil
        }
        return LumenDlsymDisplayEnabledInvoker(handle: handle, symbol: symbol)
    }
}

private final class LumenDlsymDisplayEnabledInvoker: LumenDisplayEnabledInvoking {
    private typealias DisplayEnabledFunction = @convention(c) (
        CGDisplayConfigRef,
        CGDirectDisplayID,
        Bool
    ) -> CGError

    private let handle: UnsafeMutableRawPointer
    private let function: DisplayEnabledFunction

    init(handle: UnsafeMutableRawPointer, symbol: UnsafeMutableRawPointer) {
        self.handle = handle
        function = unsafeBitCast(symbol, to: DisplayEnabledFunction.self)
    }

    deinit {
        dlclose(handle)
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Int32 {
        var configuration: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&configuration)
        guard beginStatus == .success, let configuration else {
            return beginStatus.rawValue
        }

        let mutationStatus = function(configuration, displayID, enabled)
        guard mutationStatus == .success else {
            CGCancelDisplayConfiguration(configuration)
            return mutationStatus.rawValue
        }

        let completeStatus = CGCompleteDisplayConfiguration(configuration, .forSession)
        if completeStatus != .success {
            CGCancelDisplayConfiguration(configuration)
        }
        return completeStatus.rawValue
    }
}
