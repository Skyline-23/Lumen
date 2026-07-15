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
        source: .skyLightSLS,
        symbolName: "SLSConfigureDisplayEnabled"
    )

    @Test("An exact unexpired receipt authorizes the requested private display boundary")
    func exactReceiptAuthorizes() throws {
        let receiptURL = temporaryReceiptURL()
        let receipt = verifiedReceipt()
        try LumenDisplayDisconnectCapabilityFileStore(receiptURL: receiptURL).persist(receipt)
        let verifier = fileVerifier(receiptURL: receiptURL)

        try verifier.authorize(probe: probe, physicalDisplayIDs: [42, 41])
    }

    @Test("Missing, expired, or environment-stale receipts are rejected")
    func staleReceiptIsRejected() throws {
        let missingURL = temporaryReceiptURL()
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try fileVerifier(receiptURL: missingURL).authorize(
                probe: probe,
                physicalDisplayIDs: [41, 42]
            )
        }

        let expiredURL = temporaryReceiptURL()
        let expired = LumenDisplayDisconnectCapabilityReceipt.verified(
            environment: environment,
            probe: probe,
            physicalDisplayIDs: [41, 42],
            issuedAtUnixSeconds: now - 120,
            expiresAtUnixSeconds: now - 1
        )
        try LumenDisplayDisconnectCapabilityFileStore(receiptURL: expiredURL).persist(expired)
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try fileVerifier(receiptURL: expiredURL).authorize(
                probe: probe,
                physicalDisplayIDs: [41, 42]
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
                physicalDisplayIDs: [41, 42]
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
            physicalDisplayIDs: valid.physicalDisplayIDs,
            issuedAtUnixSeconds: valid.issuedAtUnixSeconds,
            expiresAtUnixSeconds: valid.expiresAtUnixSeconds,
            checksum: "forged"
        )
        let store = LumenDisplayDisconnectCapabilityFileStore(receiptURL: receiptURL)
        try store.persist(tampered)
        let verifier = fileVerifier(receiptURL: receiptURL)

        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try verifier.authorize(probe: probe, physicalDisplayIDs: [41, 42])
        }
        try store.persist(valid)
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try verifier.authorize(
                probe: .init(source: .skyLightCGS, symbolName: "CGSConfigureDisplayEnabled"),
                physicalDisplayIDs: [41, 42]
            )
        }
        #expect(throws: LumenPhysicalDisplayControlFailure.self) {
            try verifier.authorize(probe: probe, physicalDisplayIDs: [41])
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
            physicalDisplayIDs: [41, 42],
            issuedAtUnixSeconds: now - 60,
            expiresAtUnixSeconds: now + 60
        )
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
            .appendingPathComponent("display-disconnect-capability-v1.json")
    }
}

struct AllowingDisplayDisconnectCapabilityVerifier:
    LumenDisplayDisconnectCapabilityVerifying
{
    func authorize(
        probe _: LumenDisplayEnabledSymbolProbe,
        physicalDisplayIDs _: [CGDirectDisplayID]
    ) {}
}
