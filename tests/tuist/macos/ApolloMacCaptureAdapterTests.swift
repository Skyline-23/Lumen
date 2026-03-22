import ApolloMacCaptureAdapter
import XCTest

final class ApolloMacCaptureAdapterTests: XCTestCase {
    func testAdapterReflectsBridgeDefaults() {
        let adapter = ApolloMacCaptureAdapter()

        let status = adapter.copyStatusSnapshot()
        XCTAssertFalse(status.captureSessionRunning)
        XCTAssertFalse(status.forwardingPumpRunning)
        XCTAssertGreaterThan(status.coreVersion.count, 0)
        XCTAssertGreaterThan(status.runtimeDescription.count, 0)
        XCTAssertGreaterThan(status.integrationStatus.count, 0)

        let configuration = adapter.makePanelNativeConfiguration(forDisplayID: 9)
        XCTAssertEqual(configuration.display_id, 9)
        XCTAssertEqual(configuration.codec, ApolloCoreCaptureCodecHEVC)
        XCTAssertEqual(configuration.queue_profile.rawValue, 1)
    }

    func testAdapterStartsAndStopsForwardingPump() {
        let adapter = ApolloMacCaptureAdapter()
        adapter.configureCoreForwarding(withFrameCapacity: 2, eventCapacity: 2)

        XCTAssertNoThrow(try adapter.startForwardingPump())

        let runningStatus = adapter.copyStatusSnapshot()
        XCTAssertTrue(runningStatus.forwardingPumpRunning)
        XCTAssertEqual(runningStatus.forwardedFrameCallbackCount, 0)
        XCTAssertEqual(runningStatus.forwardedEventCallbackCount, 0)

        adapter.stopForwardingPump()

        let stoppedStatus = adapter.copyStatusSnapshot()
        XCTAssertFalse(stoppedStatus.forwardingPumpRunning)
    }
}
