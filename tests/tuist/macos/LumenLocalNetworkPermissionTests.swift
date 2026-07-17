import Foundation
import XCTest

final class LumenLocalNetworkPermissionTests: XCTestCase {
    func testAppDeclaresTheLocalNetworkAndBonjourServicesUsedByTheHostWorker() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("src/platform/macos/Project.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(manifest.components(separatedBy: "NSLocalNetworkUsageDescription").count - 1, 2)
        XCTAssertEqual(manifest.components(separatedBy: "NSBonjourServices").count - 1, 2)
        XCTAssertTrue(manifest.contains("_lumen._udp"))
        XCTAssertTrue(manifest.contains("CREATE_INFOPLIST_SECTION_IN_BINARY"))
        XCTAssertTrue(manifest.contains("dev.skyline23.lumen.hostworker"))
    }
}
