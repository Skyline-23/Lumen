import CoreGraphics
import XCTest
@testable import LumenMacBridge

final class LumenDisplayReconfigurationObserverTests: XCTestCase {
    func testOnlyPostConfigurationCallbackAdvancesDisplayGeneration() async throws {
        let hub = LumenDisplayReconfigurationEventHub()

        await hub.publish(displayID: 22, flags: .beginConfigurationFlag)
        let generationBeforeCompletion = await hub.generation(for: 22)
        XCTAssertEqual(generationBeforeCompletion, 0)

        await hub.publish(displayID: 22, flags: .setModeFlag)
        let generationAfterCompletion = await hub.generation(for: 22)
        XCTAssertEqual(generationAfterCompletion, 1)

        try await hub.wait(
            id: UUID(),
            displayID: 22,
            after: generationBeforeCompletion,
            timeoutNanoseconds: 1_000_000
        )
    }

    func testMissingPostConfigurationCallbackTimesOut() async {
        let hub = LumenDisplayReconfigurationEventHub()

        do {
            try await hub.wait(
                id: UUID(),
                displayID: 22,
                after: 0,
                timeoutNanoseconds: 1_000_000
            )
            XCTFail("expected a missing display completion callback to time out")
        } catch LumenDisplayReconfigurationObservationError.timedOut(22) {
        } catch {
            XCTFail("unexpected callback wait error: \(error)")
        }
    }
}
