import CoreGraphics
import Darwin
import Foundation

public enum LumenDisplayEnabledSymbolSource: String, Codable, Equatable, Sendable {
    case skyLightSLS
    case coreGraphicsCGS
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

public protocol LumenPhysicalDisplayControlling {
    func probe() throws -> LumenDisplayEnabledSymbolProbe
    func setEnabled(
        _ enabled: Bool,
        for displayID: CGDirectDisplayID
    ) throws -> LumenPhysicalDisplayControlReceipt
}

public struct LumenDisplayDisconnectAuthorization: Codable, Equatable, Sendable {
    public let parentProcessID: Int32
    public let displayID: CGDirectDisplayID
    public let generationID: String
    public let nonce: String

    public init(
        parentProcessID: Int32,
        displayID: CGDirectDisplayID,
        generationID: String,
        nonce: String
    ) {
        self.parentProcessID = parentProcessID
        self.displayID = displayID
        self.generationID = generationID
        self.nonce = nonce
    }

    public var isWellFormed: Bool {
        parentProcessID > 0
            && displayID != 0
            && !generationID.isEmpty
            && nonce.utf8.count >= 32
    }
}

public enum LumenDisplayDisconnectMutationPhase: String, Codable, Equatable, Sendable {
    case disableAttempted
    case disableSucceeded
}

public struct LumenDisplayDisconnectMutationMarker: Codable, Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let generationID: String
    public let nonce: String
    public let phase: LumenDisplayDisconnectMutationPhase

    public init(
        displayID: CGDirectDisplayID,
        generationID: String,
        nonce: String,
        phase: LumenDisplayDisconnectMutationPhase
    ) {
        self.displayID = displayID
        self.generationID = generationID
        self.nonce = nonce
        self.phase = phase
    }

    public func authorizes(_ authorization: LumenDisplayDisconnectAuthorization) -> Bool {
        authorization.isWellFormed
            && displayID == authorization.displayID
            && generationID == authorization.generationID
            && nonce == authorization.nonce
    }
}

public enum LumenDisplayDisconnectWatchdogTrigger: String, Codable, Equatable, Sendable {
    case restoreRequested
    case parentExited
    case deadlineExceeded
}

public enum LumenDisplayDisconnectRestoreFailureCode: String, Codable, Equatable, Sendable {
    case postconditionTimedOut
    case transactionFailed
}

public struct LumenDisplayDisconnectRestoreFailedReceipt: Codable, Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let generationID: String
    public let trigger: LumenDisplayDisconnectWatchdogTrigger
    public let code: LumenDisplayDisconnectRestoreFailureCode

    public init(
        displayID: CGDirectDisplayID,
        generationID: String,
        trigger: LumenDisplayDisconnectWatchdogTrigger,
        code: LumenDisplayDisconnectRestoreFailureCode
    ) {
        self.displayID = displayID
        self.generationID = generationID
        self.trigger = trigger
        self.code = code
    }
}

@frozen public enum LumenDisplayDisconnectWatchdogRecoveryOutcome: Equatable, Sendable {
    case skipped
    case restored(LumenPhysicalDisplayControlReceipt)
    case restoreFailed(LumenDisplayDisconnectRestoreFailedReceipt)

    public var restoredReceipt: LumenPhysicalDisplayControlReceipt? {
        guard case .restored(let receipt) = self else {
            return nil
        }
        return receipt
    }

    public var restoreFailedReceipt: LumenDisplayDisconnectRestoreFailedReceipt? {
        guard case .restoreFailed(let receipt) = self else {
            return nil
        }
        return receipt
    }

    public var shouldRetainSafetyDisplay: Bool {
        if case .restoreFailed = self {
            return true
        }
        return false
    }
}

public struct LumenDisplayDisconnectWatchdogRestorer {
    private let controller: any LumenPhysicalDisplayControlling

    public init(controller: any LumenPhysicalDisplayControlling) {
        self.controller = controller
    }

    public func recoverIfAuthorized(
        authorization: LumenDisplayDisconnectAuthorization,
        marker: LumenDisplayDisconnectMutationMarker?,
        trigger: LumenDisplayDisconnectWatchdogTrigger,
        verifyRestored: () -> Bool
    ) throws -> LumenDisplayDisconnectWatchdogRecoveryOutcome {
        guard let marker, marker.authorizes(authorization) else {
            return .skipped
        }
        let receipt = try controller.setEnabled(true, for: authorization.displayID)
        guard verifyRestored() else {
            return .restoreFailed(
                LumenDisplayDisconnectRestoreFailedReceipt(
                    displayID: authorization.displayID,
                    generationID: authorization.generationID,
                    trigger: trigger,
                    code: .postconditionTimedOut
                )
            )
        }
        return .restored(receipt)
    }
}

public enum LumenPhysicalDisplayControlCode: String, Equatable, Sendable {
    case physicalDisplayDisconnectUnverified =
        "mac.display_disconnect.physical_display_disconnect_unverified"
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

public struct LumenPhysicalDisplayControlAdapter: LumenPhysicalDisplayControlling {
    private static let coreGraphicsPath =
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    private static let skyLightPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private let resolver: any LumenDisplayEnabledSymbolResolving

    public init(resolver: any LumenDisplayEnabledSymbolResolving) {
        self.resolver = resolver
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
        [
            LumenDisplayEnabledSymbolRequest(
                source: .coreGraphicsCGS,
                frameworkPath: Self.coreGraphicsPath,
                symbolName: "CGSConfigureDisplayEnabled"
            ),
            LumenDisplayEnabledSymbolRequest(
                source: .skyLightSLS,
                frameworkPath: Self.skyLightPath,
                symbolName: "SLSConfigureDisplayEnabled"
            ),
        ]
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

public final class LumenSystemDisplayEnabledSymbolResolver:
    LumenDisplayEnabledSymbolResolving
{
    private let dynamicResolver = LumenDlsymDisplayEnabledSymbolResolver()

    public init() {}

    public func resolve(
        _ request: LumenDisplayEnabledSymbolRequest
    ) -> (any LumenDisplayEnabledInvoking)? {
        if request.source == .coreGraphicsCGS {
            return LumenDirectCGSDisplayEnabledInvoker()
        }
        return dynamicResolver.resolve(request)
    }
}

private struct LumenDirectCGSDisplayEnabledInvoker: LumenDisplayEnabledInvoking {
    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Int32 {
        var configuration: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&configuration)
        guard beginStatus == .success, let configuration else {
            return beginStatus.rawValue
        }

        let mutationStatus = LumenMacDirectCGSConfigureDisplayEnabled(
            configuration,
            displayID,
            enabled
        )
        guard mutationStatus == CGError.success.rawValue else {
            CGCancelDisplayConfiguration(configuration)
            return mutationStatus
        }

        let completeStatus = CGCompleteDisplayConfiguration(configuration, .permanently)
        if completeStatus != .success {
            CGCancelDisplayConfiguration(configuration)
        }
        return completeStatus.rawValue
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

        // Display connection state must survive the mutating process long
        // enough for independent watchdog recovery to observe and reverse it.
        let completeStatus = CGCompleteDisplayConfiguration(configuration, .permanently)
        if completeStatus != .success {
            CGCancelDisplayConfiguration(configuration)
        }
        return completeStatus.rawValue
    }
}
