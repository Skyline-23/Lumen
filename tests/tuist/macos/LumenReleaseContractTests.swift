import Foundation
import Testing

@Suite("Release distribution contract")
struct LumenReleaseContractTests {
    @Test("Windows release, signing, and installation use one MSI contract")
    func windowsReleaseUsesOneMSIContract() throws {
        let root = try repositoryRoot()
        let release = try source(".github/workflows/release.yml", from: root)
        let releasingGuide = try source("docs/releasing.md", from: root)
        let installingGuide = try source("docs/installing.md", from: root)

        #expect(release.contains("signpath/github-action-submit-signing-request@v2"))
        #expect(release.contains("Lumen-*-Windows-x86_64.msi"))
        #expect(release.contains("Lumen.exe"))
        #expect(release.contains("LumenService.exe"))
        #expect(release.contains("LumenDriverSetup.exe"))
        #expect(release.contains("LumenIddCx.dll"))
        #expect(release.contains("lumeniddcx.cat"))

        #expect(releasingGuide.contains("Lumen-*-Windows-x86_64.msi"))
        #expect(releasingGuide.contains("MSI deep signing"))
        #expect(installingGuide.contains("Lumen-<version>-Windows-x86_64.msi"))
        #expect(installingGuide.contains("first-party Lumen virtual-display driver"))

        #expect(!releasingGuide.contains("Windows-x86_64.exe"))
        #expect(!releasingGuide.contains("NSIS"))
        #expect(!installingGuide.contains("Windows-x86_64.exe"))
        #expect(!installingGuide.contains("installed independently"))
    }

    private func source(_ path: String, from root: URL) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(path),
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
        throw ReleaseContractError.repositoryRootNotFound
    }
}

private enum ReleaseContractError: Error {
    case repositoryRootNotFound
}
