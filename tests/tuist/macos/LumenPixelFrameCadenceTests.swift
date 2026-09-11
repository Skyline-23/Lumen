@testable import LumenMacBridge
import XCTest

final class LumenPixelFrameCadenceTests: XCTestCase {
    func testDuplicatePacketsAreLimitedToOnePerSecond() {
        var cadence = LumenPixelFrameCadence()
        XCTAssertTrue(cadence.shouldEmit(hasPixelChanges: false, forceRefresh: false, sourceTimeSeconds: 0))
        cadence.recordEmission(sourceTimeSeconds: 0)
        for frame in 1..<120 {
            XCTAssertFalse(cadence.shouldEmit(
                hasPixelChanges: false, forceRefresh: false, sourceTimeSeconds: Double(frame) / 120))
        }
        XCTAssertTrue(cadence.shouldEmit(hasPixelChanges: false, forceRefresh: false, sourceTimeSeconds: 1))
    }

    func testDamageAndInputImmediatelyBypassDuplicatePacing() {
        var cadence = LumenPixelFrameCadence()
        cadence.recordEmission(sourceTimeSeconds: 10)
        XCTAssertTrue(cadence.shouldEmit(hasPixelChanges: true, forceRefresh: false, sourceTimeSeconds: 10.001))
        XCTAssertTrue(cadence.shouldEmit(hasPixelChanges: false, forceRefresh: true, sourceTimeSeconds: 10.001))
        // Merely considering a frame does not consume the opportunity to send it.
        XCTAssertTrue(cadence.shouldEmit(hasPixelChanges: false, forceRefresh: false, sourceTimeSeconds: 11))
        XCTAssertTrue(cadence.shouldEmit(hasPixelChanges: false, forceRefresh: false, sourceTimeSeconds: 11))
        cadence.recordEmission(sourceTimeSeconds: 11)
        XCTAssertFalse(cadence.shouldEmit(hasPixelChanges: false, forceRefresh: false, sourceTimeSeconds: 11.1))
        XCTAssertTrue(cadence.shouldEmit(hasPixelChanges: false, forceRefresh: false, sourceTimeSeconds: 1))
    }
}
