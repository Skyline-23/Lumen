import ApolloMacBridge
import XCTest

final class ApolloTuistBootstrapTests: XCTestCase {
    func testBridgeDefaultsToMacDisplayKitBackend() async {
        let status = await ApolloBridgeRuntime.shared.statusSnapshot()

        XCTAssertEqual(status.preferredCaptureBackend, .macDisplayKit)
        XCTAssertEqual(status.coreVersion, "ApolloCore bootstrap")
        XCTAssertFalse(status.integrationStatus.isEmpty)
    }
}
