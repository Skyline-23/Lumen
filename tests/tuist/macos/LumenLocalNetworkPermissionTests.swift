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

        XCTAssertTrue(manifest.contains("NSLocalNetworkUsageDescription"))
        XCTAssertTrue(manifest.contains("NSBonjourServices"))
        XCTAssertTrue(manifest.contains("_lumen._udp"))
    }
}
