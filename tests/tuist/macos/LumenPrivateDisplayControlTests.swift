import CoreGraphics
import Testing
@testable import LumenMacBridge

@Suite("Private display control symbol selection")
struct LumenPrivateDisplayControlTests {
    @Test("SLS is preferred over every fallback")
    func slsHasHighestPriority() throws {
        let sls = FakeDisplayEnabledInvoker()
        let cgs = FakeDisplayEnabledInvoker()
        let resolver = FakeDisplayEnabledSymbolResolver(
            invokers: [
                "SLSConfigureDisplayEnabled": sls,
                "CGSConfigureDisplayEnabled": cgs,
            ]
        )
        let adapter = LumenPhysicalDisplayControlAdapter(resolver: resolver)

        let receipt = try adapter.setEnabled(false, for: 42)

        #expect(receipt.source == .skyLightSLS)
        #expect(sls.calls == [.init(displayID: 42, enabled: false)])
        #expect(cgs.calls.isEmpty)
        #expect(resolver.requests.map(\.symbolName) == ["SLSConfigureDisplayEnabled"])
    }

    @Test("CGS is used only when SLS is absent")
    func cgsIsSecondPriority() throws {
        let cgs = FakeDisplayEnabledInvoker()
        let resolver = FakeDisplayEnabledSymbolResolver(
            invokers: ["CGSConfigureDisplayEnabled": cgs]
        )
        let adapter = LumenPhysicalDisplayControlAdapter(resolver: resolver)

        let receipt = try adapter.setEnabled(true, for: 7)

        #expect(receipt.source == .skyLightCGS)
        #expect(cgs.calls == [.init(displayID: 7, enabled: true)])
        #expect(
            resolver.requests.map(\.symbolName) == [
                "SLSConfigureDisplayEnabled",
                "CGSConfigureDisplayEnabled",
            ]
        )
    }

    @Test("CoreDisplay is never guessed without independent ABI proof")
    func coreDisplayIsNotSpeculativelyProbed() {
        let speculativeCoreDisplay = FakeDisplayEnabledInvoker()
        let resolver = FakeDisplayEnabledSymbolResolver(
            invokers: ["CoreDisplay_Display_SetEnabled": speculativeCoreDisplay]
        )
        let adapter = LumenPhysicalDisplayControlAdapter(resolver: resolver)

        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try adapter.setEnabled(false, for: 99)
        }
        #expect(speculativeCoreDisplay.calls.isEmpty)
        #expect(
            resolver.requests.map(\.symbolName) == [
                "SLSConfigureDisplayEnabled",
                "CGSConfigureDisplayEnabled",
            ]
        )
    }

    @Test("An independently verified CoreDisplay ABI is the final fallback")
    func verifiedCoreDisplayIsFinalFallback() throws {
        let coreDisplay = FakeDisplayEnabledInvoker()
        let resolver = FakeDisplayEnabledSymbolResolver(
            invokers: ["VerifiedCoreDisplaySetEnabled": coreDisplay]
        )
        let proof = LumenVerifiedCoreDisplayEnabledABI(
            symbolName: "VerifiedCoreDisplaySetEnabled",
            evidenceIdentifier: "fixture-abi-proof"
        )
        let adapter = LumenPhysicalDisplayControlAdapter(
            resolver: resolver,
            verifiedCoreDisplayABI: proof
        )

        let receipt = try adapter.setEnabled(false, for: 13)

        #expect(receipt.source == .verifiedCoreDisplay)
        #expect(coreDisplay.calls == [.init(displayID: 13, enabled: false)])
        #expect(
            resolver.requests.map(\.symbolName) == [
                "SLSConfigureDisplayEnabled",
                "CGSConfigureDisplayEnabled",
                "VerifiedCoreDisplaySetEnabled",
            ]
        )
    }

    @Test("Symbol absence emits a stable code and performs no mutation")
    func missingSymbolsDoNotMutate() {
        let resolver = FakeDisplayEnabledSymbolResolver(invokers: [:])
        let adapter = LumenPhysicalDisplayControlAdapter(resolver: resolver)

        do {
            _ = try adapter.setEnabled(false, for: 11)
            Issue.record("Expected symbol resolution to fail")
        } catch let failure as LumenPhysicalDisplayControlFailure {
            #expect(failure.code == .privateSymbolUnavailable)
            #expect(failure.code.rawValue == "mac.display_disconnect.private_symbol_unavailable")
            #expect(failure.status == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(resolver.resolvedInvokers.flatMap(\.calls).isEmpty)
    }

    @Test("A rejected private transaction emits a stable typed failure")
    func rejectedMutationIsTyped() {
        let invoker = FakeDisplayEnabledInvoker(status: 1_003)
        let resolver = FakeDisplayEnabledSymbolResolver(
            invokers: ["SLSConfigureDisplayEnabled": invoker]
        )
        let adapter = LumenPhysicalDisplayControlAdapter(resolver: resolver)

        do {
            _ = try adapter.setEnabled(false, for: 81)
            Issue.record("Expected the transaction to fail")
        } catch let failure as LumenPhysicalDisplayControlFailure {
            #expect(failure.code == .transactionRejected)
            #expect(failure.code.rawValue == "mac.display_disconnect.transaction_rejected")
            #expect(failure.status == 1_003)
            #expect(failure.source == .skyLightSLS)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(invoker.calls == [.init(displayID: 81, enabled: false)])
    }
}

private final class FakeDisplayEnabledSymbolResolver: LumenDisplayEnabledSymbolResolving {
    private let invokers: [String: FakeDisplayEnabledInvoker]
    private(set) var requests: [LumenDisplayEnabledSymbolRequest] = []

    init(invokers: [String: FakeDisplayEnabledInvoker]) {
        self.invokers = invokers
    }

    var resolvedInvokers: [FakeDisplayEnabledInvoker] {
        requests.compactMap { invokers[$0.symbolName] }
    }

    func resolve(
        _ request: LumenDisplayEnabledSymbolRequest
    ) -> (any LumenDisplayEnabledInvoking)? {
        requests.append(request)
        return invokers[request.symbolName]
    }
}

private final class FakeDisplayEnabledInvoker: LumenDisplayEnabledInvoking {
    struct Call: Equatable {
        let displayID: CGDirectDisplayID
        let enabled: Bool
    }

    private let status: Int32
    private(set) var calls: [Call] = []

    init(status: Int32 = 0) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Int32 {
        calls.append(Call(displayID: displayID, enabled: enabled))
        return status
    }
}
