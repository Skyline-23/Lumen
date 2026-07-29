import Foundation
import Testing

@Suite("Release distribution contract")
struct LumenReleaseContractTests {
    @Test("Windows release, signing, and installation use one MSI contract")
    func windowsReleaseUsesOneMSIContract() throws {
        let root = try repositoryRoot()
        let release = try source(".github/workflows/release.yml", from: root)
        let readme = try source("README.md", from: root)
        let releasingGuide = try source("docs/releasing.md", from: root)
        let installingGuide = try source("docs/installing.md", from: root)
        let wixPackage = try source("packaging/windows/Package.wxs", from: root)
        let signPathConfiguration = try source(
            "packaging/windows/signpath-artifact-configuration.xml",
            from: root
        )

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
        #expect(signPathConfiguration.contains(#"<zip-file>"#))
        #expect(
            signPathConfiguration.contains(
                #"<msi-file path="Lumen-*-Windows-x86_64.msi">"#
            )
        )
        #expect(signPathConfiguration.contains(#"<pe-file path="Lumen.exe">"#))
        #expect(
            signPathConfiguration.contains(
                #"<pe-file path="tools/LumenService.exe">"#
            )
        )
        #expect(
            signPathConfiguration.contains(
                #"<pe-file path="tools/LumenDriverSetup.exe">"#
            )
        )
        #expect(
            signPathConfiguration.contains(
                #"<catalog-file path="driver/lumeniddcx.cat">"#
            )
        )
        #expect(
            signPathConfiguration.contains(
                #"<pe-file path="scripts/vigembus_installer.exe">"#
            )
        )
        #expect(signPathConfiguration.contains(#"<authenticode-verify />"#))
        #expect(!signPathConfiguration.contains(#"<pe-file path="driver/LumenIddCx.dll">"#))
        #expect(wixPackage.contains(#"AllowSameVersionUpgrades="yes""#))

        #expect(readme.contains("x86-64 MSI installer"))
        #expect(!readme.contains("NSIS"))
        #expect(!releasingGuide.contains("Windows-x86_64.exe"))
        #expect(!releasingGuide.contains("NSIS"))
        #expect(!installingGuide.contains("Windows-x86_64.exe"))
        #expect(!installingGuide.contains("installed independently"))
    }

    @Test("Windows package workflows cache only native compiler outputs")
    func windowsPackageUsesBoundedCompilerCache() throws {
        let root = try repositoryRoot()
        let ci = try source(".github/workflows/ci.yml", from: root)
        let release = try source(".github/workflows/release.yml", from: root)
        let packageBuild = try source("scripts/ci/build_windows_package.sh", from: root)

        for workflow in [ci, release] {
            #expect(workflow.contains("hendrikmuhs/ccache-action@v1.2.23"))
            #expect(workflow.contains("variant: sccache"))
            #expect(workflow.contains("key: windows-gnu-package"))
            #expect(workflow.contains("max-size: 250M"))
            #expect(workflow.contains("LUMEN_CMAKE_COMPILER_LAUNCHER: sccache"))
        }
        #expect(
            packageBuild.contains(
                #"-DCMAKE_C_COMPILER_LAUNCHER=${COMPILER_LAUNCHER}"#
            )
        )
        #expect(
            packageBuild.contains(
                #"-DCMAKE_CXX_COMPILER_LAUNCHER=${COMPILER_LAUNCHER}"#
            )
        )
        #expect(packageBuild.contains("command -v"))
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
