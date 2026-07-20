import XCTest
import Synchronization
@testable import LumenMacBridge

final class LumenScreenCaptureDisplayReadinessTests: XCTestCase {
    func testDisplayLookupStartsOnceAndReusesThePreparedResult() async throws {
        let lookup = LumenSingleFlightDisplayLookup<UInt32>()
        let invocationCount = Mutex(0)

        await lookup.begin(displayID: 121, ownerToken: 7) {
            invocationCount.withLock { $0 += 1 }
            return 121
        }
        await lookup.begin(displayID: 121, ownerToken: 7) {
            invocationCount.withLock { $0 += 1 }
            return 999
        }

        let resolved = try await lookup.resolve(displayID: 121, ownerToken: 7)
        XCTAssertEqual(resolved, 121)
        XCTAssertEqual(invocationCount.withLock { $0 }, 1)
    }

    func testDisplayLookupRejectsAStaleOwnerAndKeepsTheNewOwnerResult() async throws {
        let lookup = LumenSingleFlightDisplayLookup<UInt32>()

        await lookup.begin(displayID: 121, ownerToken: 7) { 121 }
        await lookup.begin(displayID: 121, ownerToken: 8) { 122 }

        let staleResult = try await lookup.resolve(displayID: 121, ownerToken: 7)
        let currentResult = try await lookup.resolve(displayID: 121, ownerToken: 8)
        XCTAssertNil(staleResult)
        XCTAssertEqual(currentResult, 122)
    }

    func testRetainedAuthorityEnumeratesWindowServerDisplayBeforeAdmission() async throws {
        let enumerationCount = Mutex(0)

        let admission: LumenScreenCaptureDisplayAdmissionResult<UInt32> = try await
            LumenScreenCaptureDisplayAdmission.resolve(
                displayID: 121,
                isRetained: { true },
                enumerateShareableContent: {
                    enumerationCount.withLock { $0 += 1 }
                    return 121
                }
            )

        XCTAssertEqual(admission.value, 121)
        XCTAssertEqual(admission.mode, .retainedShareableContent)
        XCTAssertEqual(enumerationCount.withLock { $0 }, 1)
    }

    func testLostRetainedAuthorityAfterEnumerationFailsClosed() async {
        let enumerationCount = Mutex(0)
        let retentionChecks = Mutex(0)

        do {
            let _: LumenScreenCaptureDisplayAdmissionResult<UInt32> = try await
                LumenScreenCaptureDisplayAdmission.resolve(
                    displayID: 121,
                    isRetained: {
                        retentionChecks.withLock { count in
                            count += 1
                            return count == 1
                        }
                    },
                    enumerateShareableContent: {
                        enumerationCount.withLock { $0 += 1 }
                        return 121
                    }
                )
            XCTFail("expected retained authority loss")
        } catch LumenScreenCaptureError.displayOwnershipLost(121) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(enumerationCount.withLock { $0 }, 1)
    }

    func testRetainedDisplayWaitsForScreenCaptureKitPublication() async throws {
        let attempts = Mutex(0)
        let publicationAttempt = 4

        let resolved: UInt32 = try await LumenScreenCaptureDisplayResolver.resolve(
            displayID: 117,
            attempts: LumenScreenCaptureDisplayResolver.retainedDisplayPublicationAttempts,
            delayNanoseconds: 0,
            isRetained: { true },
            lookup: {
                attempts.withLock { count in
                    count += 1
                    return count == publicationAttempt ? 117 : nil
                }
            }
        )

        XCTAssertEqual(resolved, 117)
        XCTAssertEqual(attempts.withLock { $0 }, publicationAttempt)
    }

    func testDisplayDisappearanceFailsBeforeBindingScreenCaptureKit() async {
        let retentionChecks = Mutex(0)

        do {
            let _: UInt32 = try await LumenScreenCaptureDisplayResolver.resolve(
                displayID: 117,
                attempts: 3,
                delayNanoseconds: 0,
                isRetained: {
                    retentionChecks.withLock { count in
                        count += 1
                        return count == 1
                    }
                },
                lookup: { nil }
            )
            XCTFail("expected retained display disappearance")
        } catch LumenScreenCaptureError.displayOwnershipLost(117) {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
