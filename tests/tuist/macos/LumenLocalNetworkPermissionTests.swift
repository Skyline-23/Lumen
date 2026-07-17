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
        let workerInfo = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "engine/lumen-host/resources/macos-worker-info.plist"
            ),
            encoding: .utf8
        )
        let rustEntry = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "engine/lumen-host/src/entry.rs"
            ),
            encoding: .utf8
        )
        let legacyWorker = repositoryRoot.appendingPathComponent(
            "src/platform/macos/Projects/LumenHostWorker/Sources/main.m"
        )

        XCTAssertEqual(manifest.components(separatedBy: "NSLocalNetworkUsageDescription").count - 1, 1)
        XCTAssertEqual(manifest.components(separatedBy: "NSBonjourServices").count - 1, 1)
        XCTAssertTrue(manifest.contains("LumenRustHostWorker"))
        XCTAssertFalse(manifest.contains("name: \"LumenHostWorker\""))
        XCTAssertTrue(workerInfo.contains("NSLocalNetworkUsageDescription"))
        XCTAssertTrue(workerInfo.contains("NSBonjourServices"))
        XCTAssertTrue(workerInfo.contains("_lumen._udp"))
        XCTAssertTrue(workerInfo.contains("dev.skyline23.lumen.hostworker"))
        XCTAssertTrue(rustEntry.contains("MacPlatformSessionControl::new()"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyWorker.path))
    }
}
