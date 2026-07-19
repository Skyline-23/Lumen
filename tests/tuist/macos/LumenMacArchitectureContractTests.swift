import Foundation
import Testing

@Suite("macOS architecture contract")
struct LumenMacArchitectureContractTests {
    @Test("macOS build and release surfaces are Apple Silicon only")
    func macOSBuildAndReleaseAreArm64Only() throws {
        let repositoryRoot = try repositoryRoot()
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("src/platform/macos/Project.swift"),
            encoding: .utf8
        )
        let rustBuild = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/rust/build_lumen_engine.sh"),
            encoding: .utf8
        )
        let release = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        #expect(project.contains(#""ARCHS": "arm64""#))
        #expect(project.contains("/arm64/LumenRustHostWorker"))
        #expect(!project.contains("/x86_64/"))
        #expect(!project.contains("lipo -create"))

        #expect(rustBuild.contains("aarch64-apple-darwin"))
        #expect(!rustBuild.contains("x86_64-apple-darwin"))
        #expect(rustBuild.contains("supports Apple Silicon only"))

        #expect(release.contains("rustup target add aarch64-apple-darwin"))
        #expect(!release.contains("rustup target add x86_64-apple-darwin"))
        #expect(release.contains("ARCHS=arm64"))
        #expect(release.contains(#"lipo -archs "${STAGED_APP}/Contents/MacOS/LumenHostWorker")"#))
        #expect(release.contains("= 'arm64'"))
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
        throw ArchitectureContractError.repositoryRootNotFound
    }
}

private enum ArchitectureContractError: Error {
    case repositoryRootNotFound
}
