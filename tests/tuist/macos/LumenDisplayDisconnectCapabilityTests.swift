import CoreGraphics
import Foundation
import Testing
@testable import LumenMacBridge

@Suite("Physical display disconnect capability")
struct LumenDisplayDisconnectCapabilityTests {
    private let now: Int64 = 1_752_600_000
    private let environment = LumenDisplayDisconnectCapabilityEnvironment(
        osBuild: "25G42",
        hardwareIdentity: "platform-uuid|Mac16,1|J514cAP"
    )
    private let probe = LumenDisplayEnabledSymbolProbe(
        source: .coreGraphicsCGS,
        symbolName: "CGSConfigureDisplayEnabled"
    )

    @Test("An exact unexpired receipt authorizes the requested private display boundary")
    func exactReceiptAuthorizes() throws {
        let receiptURL = temporaryReceiptURL()
        let receipt = verifiedReceipt()
        try LumenDisplayDisconnectCapabilityFileStore(receiptURL: receiptURL).persist(receipt)
        let verifier = fileVerifier(receiptURL: receiptURL)

        try verifier.authorize(
            probe: probe,
            physicalDisplays: Array(verifiedDisplays.reversed())
        )
    }

    @Test("A verified physical identity survives a CoreGraphics display ID change")
    func stableIdentityAuthorizesRenumberedDisplay() throws {
        let receiptURL = temporaryReceiptURL()
        let verifiedDisplay = LumenDisplayDisconnectCapabilityDisplay(
            displayID: 41,
            vendorID: 1_552,
            productID: 41_049,
            serialNumber: 4_251_086_178,
            builtin: true
        )
        let currentDisplay = LumenDisplayDisconnectCapabilityDisplay(
            displayID: 73,
            vendorID: verifiedDisplay.vendorID,
            productID: verifiedDisplay.productID,
            serialNumber: verifiedDisplay.serialNumber,
            builtin: verifiedDisplay.builtin
        )
        let receipt = LumenDisplayDisconnectCapabilityReceipt.verified(
            environment: environment,
            probe: probe,
            physicalDisplays: [verifiedDisplay],
            issuedAtUnixSeconds: now - 60,
            expiresAtUnixSeconds: now + 60
        )
        try LumenDisplayDisconnectCapabilityFileStore(receiptURL: receiptURL)
            .persist(receipt)

        try fileVerifier(receiptURL: receiptURL).authorize(
            probe: probe,
            physicalDisplays: [currentDisplay]
        )
    }

    @Test("A mirrored inactive physical display remains eligible for disconnect")
    func mirroredInactivePhysicalDisplayRemainsEligible() throws {
        let physical = physicalState(
            id: "41",
            enabled: true,
            active: true,
            online: true
        )
        let snapshot = topology([physical])
        let current = topology([
            physicalState(
                id: physical.id,
                enabled: false,
                active: false,
                online: true
            ),
            physicalState(
                id: "99",
                vendorID: 9_999,
                productID: 9_999,
                serialNumber: 9_999,
                enabled: true,
                active: true,
                online: true
            ),
        ])

        let displays = try lumenCurrentPhysicalDisplays(
            snapshot: snapshot,
            current: current,
            sessionDisplayID: 99
        )

        #expect(displays.map(\.displayID) == [41])
    }

    @Test("An offline physical display is never admitted for disconnect")
    func offlinePhysicalDisplayIsRejected() {
        let physical = physicalState(
            id: "41",
            enabled: true,
            active: true,
            online: true
        )
        let snapshot = topology([physical])
        let current = topology([
            physicalState(
                id: physical.id,
                enabled: false,
                active: false,
                online: false
            ),
        ])

        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try lumenCurrentPhysicalDisplays(
                snapshot: snapshot,
                current: current,
                sessionDisplayID: 99
            )
        }
    }

    @Test("Missing, expired, or environment-stale receipts are rejected")
    func staleReceiptIsRejected() throws {
        let missingURL = temporaryReceiptURL()
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try fileVerifier(receiptURL: missingURL).authorize(
                probe: probe,
                physicalDisplays: verifiedDisplays
            )
        }

        let expiredURL = temporaryReceiptURL()
        let expired = LumenDisplayDisconnectCapabilityReceipt.verified(
            environment: environment,
            probe: probe,
            physicalDisplays: verifiedDisplays,
            issuedAtUnixSeconds: now - 120,
            expiresAtUnixSeconds: now - 1
        )
        try LumenDisplayDisconnectCapabilityFileStore(receiptURL: expiredURL).persist(expired)
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try fileVerifier(receiptURL: expiredURL).authorize(
                probe: probe,
                physicalDisplays: verifiedDisplays
            )
        }

        let staleEnvironmentVerifier = LumenDisplayDisconnectCapabilityFileVerifier(
            receiptURL: expiredURL,
            environment: .init(
                osBuild: "25G43",
                hardwareIdentity: environment.hardwareIdentity
            ),
            currentTimeUnixSeconds: now - 60
        )
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try staleEnvironmentVerifier.authorize(
                probe: probe,
                physicalDisplays: verifiedDisplays
            )
        }
    }

    @Test("Checksum, symbol, and exact display-set mismatches are rejected")
    func tamperedReceiptIsRejected() throws {
        let receiptURL = temporaryReceiptURL()
        let valid = verifiedReceipt()
        let tampered = LumenDisplayDisconnectCapabilityReceipt(
            schemaVersion: valid.schemaVersion,
            osBuild: valid.osBuild,
            hardwareIdentity: valid.hardwareIdentity,
            symbolSource: valid.symbolSource,
            symbolName: valid.symbolName,
            physicalDisplays: valid.physicalDisplays,
            issuedAtUnixSeconds: valid.issuedAtUnixSeconds,
            expiresAtUnixSeconds: valid.expiresAtUnixSeconds,
            checksum: "forged"
        )
        let store = LumenDisplayDisconnectCapabilityFileStore(receiptURL: receiptURL)
        try store.persist(tampered)
        let verifier = fileVerifier(receiptURL: receiptURL)

        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try verifier.authorize(
                probe: probe,
                physicalDisplays: verifiedDisplays
            )
        }
        try store.persist(valid)
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try verifier.authorize(
                probe: .init(source: .skyLightSLS, symbolName: "SLSConfigureDisplayEnabled"),
                physicalDisplays: verifiedDisplays
            )
        }
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try verifier.authorize(
                probe: probe,
                physicalDisplays: Array(verifiedDisplays.prefix(1))
            )
        }
    }

    @Test("Revocation removes an existing capability receipt")
    func receiptRevocationIsDurable() throws {
        let receiptURL = temporaryReceiptURL()
        let store = LumenDisplayDisconnectCapabilityFileStore(receiptURL: receiptURL)
        try store.persist(verifiedReceipt())
        #expect(FileManager.default.fileExists(atPath: receiptURL.path))

        try store.revoke()

        #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
    }

    private func verifiedReceipt() -> LumenDisplayDisconnectCapabilityReceipt {
        .verified(
            environment: environment,
            probe: probe,
            physicalDisplays: verifiedDisplays,
            issuedAtUnixSeconds: now - 60,
            expiresAtUnixSeconds: now + 60
        )
    }

    private var verifiedDisplays: [LumenDisplayDisconnectCapabilityDisplay] {
        [
            .init(
                displayID: 41,
                vendorID: 1_552,
                productID: 41_049,
                serialNumber: 4_251_086_178,
                builtin: true
            ),
            .init(
                displayID: 42,
                vendorID: 4_268,
                productID: 41_607,
                serialNumber: 809_654_099,
                builtin: false
            )
        ]
    }

    private func fileVerifier(
        receiptURL: URL
    ) -> LumenDisplayDisconnectCapabilityFileVerifier {
        LumenDisplayDisconnectCapabilityFileVerifier(
            receiptURL: receiptURL,
            environment: environment,
            currentTimeUnixSeconds: now
        )
    }

    private func temporaryReceiptURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("display-disconnect-capability-v2.json")
    }

    private func topology(
        _ displays: [LumenMacPhysicalDisplayState]
    ) -> LumenMacPhysicalDisplayTopology {
        LumenMacPhysicalDisplayTopology(
            displays: displays,
            windowsAdapterLUID: nil,
            windowsTargetPaths: []
        )
    }

    private func physicalState(
        id: String,
        vendorID: UInt32 = 1_552,
        productID: UInt32 = 41_049,
        serialNumber: UInt32 = 4_251_086_178,
        enabled: Bool,
        active: Bool,
        online: Bool
    ) -> LumenMacPhysicalDisplayState {
        LumenMacPhysicalDisplayState(
            id: id,
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            builtin: false,
            mode: LumenMacPhysicalDisplayMode(
                width: 2_560,
                height: 1_440,
                refreshMillihertz: 240_000,
                bitDepth: 10
            ),
            originX: 0,
            originY: 0,
            mirrorMasterID: nil,
            enabled: enabled,
            active: active,
            online: online
        )
    }
}

struct AllowingDisplayDisconnectCapabilityVerifier:
    LumenDisplayDisconnectCapabilityVerifying
{
    func authorize(
        probe _: LumenDisplayEnabledSymbolProbe,
        physicalDisplays _: [LumenDisplayDisconnectCapabilityDisplay]
    ) {}
}
