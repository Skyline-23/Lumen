import Foundation
import Testing

@Suite("Virtual display lifecycle contract")
struct LumenVirtualDisplayLifecycleContractTests {
    @Test("Virtual display promotion removes mirroring before layout mutation")
    func promotionUnmirrorsBeforeRepositioning() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/LumenMacDisplayWorkspace.swift"
        )
        let start = try #require(
            source.range(of: "    public func promoteVirtualDisplay(")
        )
        let tail = source[start.lowerBound...]
        let end = try #require(
            tail.range(of: "\n    public func moveTargetWindows")
        )
        let promotion = tail[..<end.lowerBound]

        let unmirror = try #require(
            promotion.range(of: "CGConfigureDisplayMirrorOfDisplay")
        )
        let origin = try #require(promotion.range(of: "CGConfigureDisplayOrigin"))
        #expect(unmirror.lowerBound < origin.lowerBound)
        #expect(promotion.contains("kCGNullDirectDisplay"))
    }

    @Test("Virtual display settings declare rotation and HDR reference state")
    func settingsMatchDesktopDisplayContract() throws {
        let source = try source(
            "src/platform/macos/Projects/LumenMacBridge/Sources/LumenNativeVirtualDisplay.m"
        )

        #expect(source.contains("[_settings setValue:@0 forKey:@\"rotation\"]"))
        #expect(
            source.contains(
                "[_settings setValue:@(configuration.hdrEnabled) forKey:@\"isReference\"]"
            )
        )
    }

    private func source(_ relativePath: String) throws -> String {
        let root = try repositoryRoot()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath)
        while candidate.path != "/" {
            candidate.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Cargo.toml").path
            ) {
                return candidate
            }
        }
        throw VirtualDisplayLifecycleContractError.repositoryRootNotFound
    }
}

private enum VirtualDisplayLifecycleContractError: Error {
    case repositoryRootNotFound
}
