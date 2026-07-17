import XCTest
import Synchronization
@testable import LumenMacBridge

final class LumenScreenCaptureDisplayReadinessTests: XCTestCase {
    func testRetainedDisplayWaitsForScreenCaptureKitPublication() async throws {
        let attempts = Mutex(0)

        let resolved: UInt32 = try await LumenScreenCaptureDisplayResolver.resolve(
            displayID: 117,
            attempts: 3,
            delayNanoseconds: 0,
            isRetained: { true },
            lookup: {
                attempts.withLock { count in
                    count += 1
                    return count == 3 ? 117 : nil
                }
            }
        )

        XCTAssertEqual(resolved, 117)
        XCTAssertEqual(attempts.withLock { $0 }, 3)
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
