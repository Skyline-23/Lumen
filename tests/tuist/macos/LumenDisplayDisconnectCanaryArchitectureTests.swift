import Foundation
import Testing

@Suite("Display disconnect canary architecture")
struct LumenDisplayDisconnectCanaryArchitectureTests {
    @Test("Capture staging is app-scoped while the committed mirror is session-scoped")
    func displayEnabledMutationUsesDurableScope() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let connectionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/platform/macos/Projects/LumenMacBridge/Sources/LumenPrivateDisplayControl.swift"
            ),
            encoding: .utf8
        )
        #expect(connectionSource.contains(".permanently"))
        #expect(!connectionSource.contains(".forSession"))

        let workspaceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/platform/macos/Projects/LumenMacBridge/Sources/LumenMacDisplayWorkspace.swift"
            ),
            encoding: .utf8
        )
        #expect(workspaceSource.contains(".forAppOnly"))
        #expect(workspaceSource.contains("desktopMirrorConfigurationScope"))
        #expect(workspaceSource.contains("desktopMirrorStageConfigurationScope"))
        #expect(workspaceSource.contains(".forSession"))
        #expect(
            workspaceSource.contains(
                "scope: Self.desktopMirrorStageConfigurationScope"
            )
        )

        let topologySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/platform/macos/Projects/LumenMacBridge/Sources/LumenMacDisplayTopologyController.swift"
            ),
            encoding: .utf8
        )
        #expect(topologySource.contains("restoreConfigurationScope"))
        #expect(topologySource.contains(".permanently"))
        #expect(!topologySource.contains(".forAppOnly"))
        #expect(!topologySource.contains(".forSession"))
    }

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
        #expect(source.contains("ProcessInfo.processInfo.systemUptime + timeout"))
        #expect(source.contains("try verifySafetyDesktopStability("))
        #expect(source.contains("duration: 2"))
        #expect(source.contains("private func isDisplayDisconnected("))
        #expect(source.contains("CGDisplayIsActive(displayID) == 0"))
        #expect(source.contains("CGDisplayIsOnline(displayID) == 0"))
        #expect(source.contains("condition: { isDisplayDisconnected(selected.displayID) }"))

        let layoutStart = try #require(
            source.range(of: "private func configureDisplayOrigins(")
        )
        let layoutTail = source[layoutStart.lowerBound...]
        let layoutEnd = try #require(layoutTail.range(of: "\nprivate func waitUntil("))
        let layout = layoutTail[..<layoutEnd.lowerBound]
        let unmirror = try #require(layout.range(of: "CGConfigureDisplayMirrorOfDisplay"))
        let origin = try #require(layout.range(of: "CGConfigureDisplayOrigin"))
        #expect(unmirror.lowerBound < origin.lowerBound)

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
