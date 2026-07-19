import CoreGraphics
import Testing
@testable import LumenMacBridge

@Suite("Private display control symbol selection")
struct LumenPrivateDisplayControlTests {
    @Test("CoreGraphics CGS is preferred for connection mutation")
    func coreGraphicsCGSHasHighestPriority() throws {
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

        #expect(receipt.source == .coreGraphicsCGS)
        #expect(cgs.calls == [.init(displayID: 42, enabled: false)])
        #expect(sls.calls.isEmpty)
        #expect(resolver.requests.map(\.symbolName) == ["CGSConfigureDisplayEnabled"])
    }

    @Test("SkyLight SLS remains a runtime fallback")
    func slsIsSecondPriority() throws {
        let sls = FakeDisplayEnabledInvoker()
        let resolver = FakeDisplayEnabledSymbolResolver(
            invokers: ["SLSConfigureDisplayEnabled": sls]
        )
        let adapter = LumenPhysicalDisplayControlAdapter(resolver: resolver)

        let receipt = try adapter.setEnabled(true, for: 7)

        #expect(receipt.source == .skyLightSLS)
        #expect(sls.calls == [.init(displayID: 7, enabled: true)])
        #expect(
            resolver.requests.map(\.symbolName) == [
                "CGSConfigureDisplayEnabled",
                "SLSConfigureDisplayEnabled",
            ]
        )
    }

    @Test("Unsupported legacy symbols are never guessed")
    func legacySymbolsAreNotSpeculativelyProbed() {
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
                "CGSConfigureDisplayEnabled",
                "SLSConfigureDisplayEnabled",
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
            invokers: ["CGSConfigureDisplayEnabled": invoker]
        )
        let adapter = LumenPhysicalDisplayControlAdapter(resolver: resolver)

        do {
            _ = try adapter.setEnabled(false, for: 81)
            Issue.record("Expected the transaction to fail")
        } catch let failure as LumenPhysicalDisplayControlFailure {
            #expect(failure.code == .transactionRejected)
            #expect(failure.code.rawValue == "mac.display_disconnect.transaction_rejected")
            #expect(failure.status == 1_003)
            #expect(failure.source == .coreGraphicsCGS)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(invoker.calls == [.init(displayID: 81, enabled: false)])
    }

    @Test("Pre-mutation guard failure causes zero display transactions")
    func preMutationFailureDoesNotRestore() throws {
        let controller = FakePhysicalDisplayController()
        let restorer = LumenDisplayDisconnectWatchdogRestorer(controller: controller)
        let authorization = fixtureAuthorization()

        let outcome = try restorer.recoverIfAuthorized(
            authorization: authorization,
            marker: nil,
            trigger: .restoreRequested,
            verifyRestored: { true }
        )

        #expect(outcome == .skipped)
        #expect(controller.calls.isEmpty)
    }

    @Test("Forged generation and nonce cannot authorize restoration")
    func mismatchedAuthorizationDoesNotRestore() throws {
        let controller = FakePhysicalDisplayController()
        let restorer = LumenDisplayDisconnectWatchdogRestorer(controller: controller)
        let authorization = fixtureAuthorization()
        let forgedMarkers = [
            fixtureMarker(nonce: "forged"),
            fixtureMarker(generationID: "other-generation"),
            fixtureMarker(displayID: 404),
        ]

        for marker in forgedMarkers {
            let outcome = try restorer.recoverIfAuthorized(
                authorization: authorization,
                marker: marker,
                trigger: .parentExited,
                verifyRestored: { true }
            )
            #expect(outcome == .skipped)
        }
        #expect(controller.calls.isEmpty)
    }

    @Test("Parent crash after durable disable attempt restores once")
    func parentCrashRestoresAttemptedMutation() throws {
        let controller = FakePhysicalDisplayController()
        let restorer = LumenDisplayDisconnectWatchdogRestorer(controller: controller)
        let authorization = fixtureAuthorization()

        let outcome = try restorer.recoverIfAuthorized(
            authorization: authorization,
            marker: fixtureMarker(phase: .disableAttempted),
            trigger: .parentExited,
            verifyRestored: { true }
        )

        #expect(outcome.restoredReceipt?.enabled == true)
        #expect(outcome.restoredReceipt?.displayID == authorization.displayID)
        #expect(controller.calls == [.init(displayID: authorization.displayID, enabled: true)])
    }

    @Test("Interruption after successful disable restores once")
    func requestedRestoreHandlesSuccessfulMutation() throws {
        let controller = FakePhysicalDisplayController()
        let restorer = LumenDisplayDisconnectWatchdogRestorer(controller: controller)
        let authorization = fixtureAuthorization()

        let outcome = try restorer.recoverIfAuthorized(
            authorization: authorization,
            marker: fixtureMarker(phase: .disableSucceeded),
            trigger: .restoreRequested,
            verifyRestored: { true }
        )

        #expect(outcome.restoredReceipt?.enabled == true)
        #expect(controller.calls == [.init(displayID: authorization.displayID, enabled: true)])
    }

    @Test("Failed restore postcondition retains safety recovery without a restored receipt")
    func failedRestorePostconditionRetainsSafetyRecovery() throws {
        let controller = FakePhysicalDisplayController()
        let restorer = LumenDisplayDisconnectWatchdogRestorer(controller: controller)
        let authorization = fixtureAuthorization()

        let outcome = try restorer.recoverIfAuthorized(
            authorization: authorization,
            marker: fixtureMarker(phase: .disableSucceeded),
            trigger: .parentExited,
            verifyRestored: { false }
        )

        #expect(outcome.restoredReceipt == nil)
        #expect(outcome.shouldRetainSafetyDisplay)
        #expect(
            outcome.restoreFailedReceipt
                == LumenDisplayDisconnectRestoreFailedReceipt(
                    displayID: authorization.displayID,
                    generationID: authorization.generationID,
                    trigger: .parentExited,
                    code: .postconditionTimedOut
                )
        )
        #expect(controller.calls == [.init(displayID: authorization.displayID, enabled: true)])
    }

    private func fixtureAuthorization() -> LumenDisplayDisconnectAuthorization {
        LumenDisplayDisconnectAuthorization(
            parentProcessID: 123,
            displayID: 81,
            generationID: "generation",
            nonce: "0123456789abcdef0123456789abcdef"
        )
    }

    private func fixtureMarker(
        displayID: CGDirectDisplayID = 81,
        generationID: String = "generation",
        nonce: String = "0123456789abcdef0123456789abcdef",
        phase: LumenDisplayDisconnectMutationPhase = .disableAttempted
    ) -> LumenDisplayDisconnectMutationMarker {
        LumenDisplayDisconnectMutationMarker(
            displayID: displayID,
            generationID: generationID,
            nonce: nonce,
            phase: phase
        )
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

private final class FakePhysicalDisplayController: LumenPhysicalDisplayControlling {
    struct Call: Equatable {
        let displayID: CGDirectDisplayID
        let enabled: Bool
    }

    private(set) var calls: [Call] = []

    func probe() -> LumenDisplayEnabledSymbolProbe {
        LumenDisplayEnabledSymbolProbe(
            source: .skyLightSLS,
            symbolName: "SLSConfigureDisplayEnabled"
        )
    }

    func setEnabled(
        _ enabled: Bool,
        for displayID: CGDirectDisplayID
    ) -> LumenPhysicalDisplayControlReceipt {
        calls.append(.init(displayID: displayID, enabled: enabled))
        return LumenPhysicalDisplayControlReceipt(
            displayID: displayID,
            enabled: enabled,
            source: .skyLightSLS,
            symbolName: "SLSConfigureDisplayEnabled"
        )
    }
}
