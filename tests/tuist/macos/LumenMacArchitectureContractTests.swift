import Foundation
import Testing

@Suite("macOS architecture contract")
struct LumenMacArchitectureContractTests {
    @Test("Host worker declares the AppKit event-loop bundle contract")
    func hostWorkerDeclaresAppKitEventLoopContract() throws {
        let workerInfoURL = try repositoryRoot().appendingPathComponent(
            "engine/lumen-host/resources/macos-worker-info.plist"
        )
        let propertyList = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: workerInfoURL),
                format: nil
            ) as? [String: Any]
        )

        #expect(propertyList["LSUIElement"] as? Bool == true)
        #expect(propertyList["NSHighResolutionCapable"] as? Bool == true)
        #expect(propertyList["NSPrincipalClass"] as? String == "NSApplication")
    }

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

        #expect(release.contains("target: aarch64-apple-darwin"))
        #expect(!release.contains("target: x86_64-apple-darwin"))
        #expect(release.contains("ARCHS=arm64"))
        #expect(!release.contains("-derivedDataPath"))
        #expect(release.contains(#"${HOME}/Library/Developer/Xcode/DerivedData"#))
        #expect(release.contains(#"lipo -archs "${STAGED_APP}/Contents/MacOS/LumenHostWorker")"#))
        #expect(release.contains("= 'arm64'"))
    }

    @Test("Local apps preserve the Apple Development identity used by privacy grants")
    func localAppsUseDevelopmentSigningWhileReleaseInjectsDistributionSigning() throws {
        let repositoryRoot = try repositoryRoot()
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("src/platform/macos/Project.swift"),
            encoding: .utf8
        )
        let release = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        #expect(project.contains(#""CODE_SIGN_STYLE": "Automatic""#))
        #expect(project.contains(#""CODE_SIGN_IDENTITY": "Apple Development""#))
        #expect(!project.contains("Developer ID Application:"))
        #expect(release.contains("CODE_SIGN_STYLE=Manual"))
        #expect(
            release.contains(#""CODE_SIGN_IDENTITY=${LUMEN_SIGNING_IDENTITY}""#)
        )
    }

    @Test("Exact Tuist test preserves exact Tuist build app roots")
    func exactTuistTestPreservesAllBuildEntries() throws {
        let project = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "src/platform/macos/Project.swift"
            ),
            encoding: .utf8
        )
        let testTargetStart = try #require(
            project.range(of: "            name: \"LumenTuistTests\",")
        )
        let testTargetTail = project[testTargetStart.lowerBound...]
        let testTargetEnd = try #require(
            testTargetTail.range(of: "\n    ],\n    schemes: [")
        )
        let testTarget = testTargetTail[..<testTargetEnd.lowerBound]

        #expect(testTarget.contains(#".target(name: "LumenApp", status: .none)"#))
        #expect(
            testTarget.contains(
                #".target(name: "LumenDisplayDisconnectCanary", status: .none)"#
            )
        )
        #expect(testTarget.contains(#""BUNDLE_LOADER": """#))
        #expect(testTarget.contains(#""TEST_HOST": """#))
        #expect(testTarget.contains(#""TEST_TARGET_NAME": """#))
    }

    @Test("Release tags stay on their reviewed GitFlow branch")
    func releaseTagsRequireReviewedBranchAncestry() throws {
        let repositoryRoot = try repositoryRoot()
        let release = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                ".github/workflows/release.yml"
            ),
            encoding: .utf8
        )
        let validator = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/release/validate_gitflow_release.sh"
            ),
            encoding: .utf8
        )

        #expect(release.contains("scripts/release/validate_gitflow_release.sh"))
        #expect(validator.contains(#"RELEASE_BRANCH="release/${PRODUCT_VERSION}""#))
        #expect(validator.contains("must point at the current ${REMOTE}/${RELEASE_BRANCH} head"))
        #expect(validator.contains("must point at the current ${REMOTE}/main head"))
        #expect(validator.contains("must point at a no-ff merge"))
        #expect(validator.contains("must be merged back into ${REMOTE}/develop"))
        #expect(validator.contains("must be annotated"))
        #expect(validator.contains("is out of sequence"))
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
