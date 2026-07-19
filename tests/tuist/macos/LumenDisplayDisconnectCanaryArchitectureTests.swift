import Foundation
import Testing

@Suite("Display disconnect canary architecture")
struct LumenDisplayDisconnectCanaryArchitectureTests {
    @Test("A single UIElement app owns safety displays while watchdogs only restore")
    func singleApplicationOwnsSafetyDisplays() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("src/platform/macos/Project.swift"),
            encoding: .utf8
        )
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/platform/macos/Projects/LumenDisplayDisconnectCanary/Sources/main.swift"
            ),
            encoding: .utf8
        )

        let targetStart = try #require(
            manifest.range(of: "name: \"LumenDisplayDisconnectCanary\"")
        )
        let targetTail = manifest[targetStart.lowerBound...]
        let targetEnd = targetTail.dropFirst().range(of: "        .target(")?.lowerBound
            ?? targetTail.endIndex
        let target = String(targetTail[..<targetEnd])
        #expect(target.contains("\"LSUIElement\": true"))
        #expect(!target.contains("LSBackgroundOnly"))

        #expect(source.contains("application.setActivationPolicy(.accessory)"))
        #expect(!source.contains("application.setActivationPolicy(.prohibited)"))
        #expect(!source.contains("application.setActivationPolicy(.regular)"))

        let watchdogStart = try #require(
            source.range(of: "    private static func runWatchdog(arguments: [String]) throws {")
        )
        let watchdogTail = source[watchdogStart.lowerBound...]
        let watchdogEnd = try #require(
            watchdogTail.range(of: "\nprivate func displayStates() throws")
        )
        let watchdog = watchdogTail[..<watchdogEnd.lowerBound]
        #expect(!watchdog.contains("LumenMacVirtualDisplay("))
        #expect(source.contains("private func createCanarySafetyDisplays("))
    }
}
