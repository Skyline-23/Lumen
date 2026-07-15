import XCTest
@testable import LumenMacBridge

final class LumenNativeVirtualDisplayTests: XCTestCase {
    func testNativeVirtualDisplayRejectsEmptyGeometry() {
        let configuration = LumenMacVirtualDisplayConfiguration()
        XCTAssertThrowsError(try LumenMacVirtualDisplay(configuration: configuration))
    }

    func testVirtualDisplayRegistryHandlesUnknownKeysWithoutSideEffects() {
        LumenMacVirtualDisplay.destroyAllRegisteredDisplays()

        XCTAssertNil(LumenMacVirtualDisplay.registeredDisplay(forKey: "missing"))
        XCTAssertNil(LumenMacVirtualDisplay.registeredDisplay(forDisplayID: 999_999))
        XCTAssertFalse(LumenMacVirtualDisplay.removeRegisteredDisplay(forKey: "missing"))
    }
}
