import ApolloMacBridge
import XCTest

final class ApolloTuistBootstrapTests: XCTestCase {
    func testBridgeDefaultsToMacDisplayKitBackend() async {
        let status = await ApolloBridgeRuntime.shared.statusSnapshot()

        XCTAssertEqual(status.preferredCaptureBackend, .macDisplayKit)
        XCTAssertEqual(status.coreVersion, "ApolloCore bootstrap")
        XCTAssertFalse(status.integrationStatus.isEmpty)
    }

    func testBridgeBuildsPanelNativeMacDisplayKitConfiguration() async {
        let configuration = await ApolloBridgeRuntime.shared.preferredMacDisplayKitCaptureConfiguration(
            displayID: 7
        )

        XCTAssertEqual(configuration.displayID, 7)
        XCTAssertEqual(configuration.codec, .hevc)
        XCTAssertEqual(configuration.preprocessStrategy, .none)
        XCTAssertEqual(configuration.queueProfile, .q2)
        XCTAssertEqual(configuration.targetFrameRate, 120)
        XCTAssertFalse(configuration.showCursor)
    }
}
