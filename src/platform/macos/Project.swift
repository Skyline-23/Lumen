import ProjectDescription

let baseSettings: SettingsDictionary = [
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++23",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "DEVELOPMENT_TEAM": "Q23JLSJCCV",
    "MACOSX_DEPLOYMENT_TARGET": "15.0",
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated"
]

let repoRoot = "$(SRCROOT)/../../.."
let swiftOpusPackage = Package.package(
    url: "https://github.com/Skyline-23/SwiftOpus.git",
    .exact("0.5.0")
)

let rustEngineBuildScript = TargetScript.pre(
    script: #"""
    set -euo pipefail

    REPO_ROOT="${SRCROOT}/../../.."
    "${REPO_ROOT}/scripts/rust/build_lumen_engine.sh"
    """#,
    name: "Build Lumen Rust Engine",
    inputPaths: [
        .glob("\(repoRoot)/Cargo.toml"),
        .glob("\(repoRoot)/Cargo.lock"),
        .glob("\(repoRoot)/engine/lumen-engine/Cargo.toml"),
        .glob("\(repoRoot)/engine/lumen-engine/src/**/*.rs"),
        .glob("\(repoRoot)/engine/lumen-engine/include/**/*.h"),
        .glob("\(repoRoot)/engine/lumen-host/Cargo.toml"),
        .glob("\(repoRoot)/engine/lumen-host/src/**/*.rs"),
        .glob("\(repoRoot)/scripts/rust/build_lumen_engine.sh")
    ],
    outputPaths: [
        .path("\(repoRoot)/build/rust-engine/$(CONFIGURATION)/arm64/liblumen_engine.a"),
        .path("\(repoRoot)/build/rust-engine/$(CONFIGURATION)/arm64/liblumen_host.a"),
        .path("\(repoRoot)/build/rust-engine/$(CONFIGURATION)/arm64/LumenRustHostWorker"),
        .path("\(repoRoot)/build/rust-engine/$(CONFIGURATION)/x86_64/liblumen_engine.a"),
        .path("\(repoRoot)/build/rust-engine/$(CONFIGURATION)/x86_64/liblumen_host.a"),
        .path("\(repoRoot)/build/rust-engine/$(CONFIGURATION)/x86_64/LumenRustHostWorker")
    ],
    basedOnDependencyAnalysis: false,
    shellPath: "/bin/zsh"
)

let nativeAssetsScript = TargetScript.post(
    script: #"""
    set -euo pipefail

    REPO_ROOT="${SRCROOT}/../../.."
    RESOURCES_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
    ASSETS_ROOT="${RESOURCES_ROOT}/assets"

    rm -rf "${ASSETS_ROOT}"
    mkdir -p "${ASSETS_ROOT}"

    rsync -a "${REPO_ROOT}/src_assets/common/assets/" "${ASSETS_ROOT}/"
    rsync -a --exclude 'Info.plist' "${REPO_ROOT}/src_assets/macos/assets/" "${ASSETS_ROOT}/"

    WORKER_DESTINATION="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/LumenHostWorker"
    rm -f "${WORKER_DESTINATION}"
    WORKER_ARCHS=(${(z)ARCHS})
    if (( ${#WORKER_ARCHS} > 1 )); then
      WORKER_SOURCES=()
      for WORKER_ARCH in "${WORKER_ARCHS[@]}"; do
        WORKER_SOURCE="${REPO_ROOT}/build/rust-engine/${CONFIGURATION}/${WORKER_ARCH}/LumenRustHostWorker"
        test -x "${WORKER_SOURCE}"
        WORKER_SOURCES+=("${WORKER_SOURCE}")
      done
      lipo -create "${WORKER_SOURCES[@]}" -output "${WORKER_DESTINATION}"
    else
      WORKER_ARCH="${CURRENT_ARCH:-}"
      if [[ -z "${WORKER_ARCH}" || "${WORKER_ARCH}" == "undefined_arch" ]]; then
        WORKER_ARCH="${ARCHS%% *}"
      fi
      WORKER_SOURCE="${REPO_ROOT}/build/rust-engine/${CONFIGURATION}/${WORKER_ARCH}/LumenRustHostWorker"
      test -x "${WORKER_SOURCE}"
      ditto "${WORKER_SOURCE}" "${WORKER_DESTINATION}"
    fi
    chmod 755 "${WORKER_DESTINATION}"
    SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    /usr/bin/codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${WORKER_DESTINATION}"
    """#,
    name: "Stage Lumen Native Assets",
    inputPaths: [
        .glob("\(repoRoot)/src_assets/common/assets/**/*"),
        .glob("\(repoRoot)/src_assets/macos/assets/**/*")
    ],
    basedOnDependencyAnalysis: false,
    shellPath: "/bin/zsh"
)

let project = Project(
    name: "Lumen",
    options: .options(
        defaultKnownRegions: ["en", "ko", "ja"],
        developmentRegion: "en",
        disableSynthesizedResourceAccessors: true
    ),
    packages: [swiftOpusPackage],
    settings: .settings(base: baseSettings),
    targets: [
        .target(
            name: "LumenEngineBridge",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.enginebridge",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Projects/LumenEngineBridge/Sources/**/*.{m}"
            ],
            headers: .headers(
                public: "Projects/LumenEngineBridge/Headers/LumenEngineBridge.h"
            ),
            scripts: [rustEngineBuildScript],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "LumenEngineBridge",
                    "HEADER_SEARCH_PATHS": [
                        "$(SRCROOT)/Projects/LumenEngineBridge/Headers",
                        "\(repoRoot)/engine/lumen-engine/include"
                    ],
                    "OTHER_LDFLAGS": .array([
                        "$(inherited)",
                        "-force_load",
                        "\(repoRoot)/build/rust-engine/$(CONFIGURATION)/$(CURRENT_ARCH)/liblumen_engine.a"
                    ])
                ]
            )
        ),
        .target(
            name: "LumenMacBridge",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.macbridge",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Projects/LumenMacBridge/Sources/**/*.{swift,m,mm}"
            ],
            headers: .headers(
                public: "Projects/LumenMacBridge/Headers/LumenMacBridge.h"
            ),
            dependencies: [
                .target(name: "LumenEngineBridge"),
                .package(product: "COpus"),
                .sdk(name: "AppKit", type: .framework),
                .sdk(name: "AVFoundation", type: .framework),
                .sdk(name: "CoreVideo", type: .framework),
                .sdk(name: "ScreenCaptureKit", type: .framework),
                .sdk(name: "VideoToolbox", type: .framework)
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "LumenMacBridge",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                    "SWIFT_ENABLE_LIBRARY_EVOLUTION": "YES",
                    "HEADER_SEARCH_PATHS": [
                        "$(SRCROOT)/Projects/LumenMacBridge/Headers"
                    ]
                ]
            )
        ),
        .target(
            name: "LumenHostRuntimeBridge",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.hostruntimebridge",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Projects/LumenHostRuntimeBridge/Sources/**/*.m"
            ],
            headers: .headers(
                public: "Projects/LumenHostRuntimeBridge/Headers/LumenHostRuntimeBridge.h"
            ),
            dependencies: [
                .target(name: "LumenEngineBridge"),
                .target(name: "LumenMacBridge"),
                .sdk(name: "AppKit", type: .framework),
                .sdk(name: "ApplicationServices", type: .framework),
                .sdk(name: "Foundation", type: .framework),
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "LumenHostRuntimeBridge",
                    "HEADER_SEARCH_PATHS": [
                        "$(SRCROOT)/Projects/LumenHostRuntimeBridge/Headers",
                        "\(repoRoot)/engine/lumen-engine/include"
                    ]
                ]
            )
        ),
        .target(
            name: "LumenMacCaptureAdapter",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.maccaptureadapter",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Projects/LumenMacCaptureAdapter/Sources/**/*.swift"
            ],
            dependencies: [
                .target(name: "LumenMacBridge"),
                .target(name: "LumenHostRuntimeBridge")
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "LumenMacCaptureAdapter"
                ]
            )
        ),
        .target(
            name: "LumenAppArchitecture",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.apparchitecture",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "Projects/LumenAppArchitecture/Sources/**/*.swift"
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "LumenAppArchitecture"
                ]
            )
        ),
        .target(
            name: "LumenDisplayDisconnectCanary",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.skyline23.lumen.displaydisconnectcanary",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "NSPrincipalClass": "NSApplication"
            ]),
            sources: [
                "Projects/LumenDisplayDisconnectCanary/Sources/**/*.swift"
            ],
            dependencies: [
                .target(name: "LumenMacBridge"),
                .sdk(name: "AppKit", type: .framework)
            ],
            settings: .settings(
                base: [
                    "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGN_STYLE": "Manual",
                    "CODE_SIGN_IDENTITY": "Developer ID Application: Buseong Kim (Q23JLSJCCV)",
                    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                    "DEVELOPMENT_TEAM": "Q23JLSJCCV",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
                    "OTHER_CODE_SIGN_FLAGS": "--timestamp",
                    "PRODUCT_NAME": "LumenDisplayDisconnectCanary",
                    "SKIP_INSTALL": "YES"
                ]
            )
        ),
        .target(
            name: "LumenApp",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.skyline23.lumen.app",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "Lumen",
                    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                    "LSApplicationCategoryType": "public.app-category.utilities",
                    "LSMinimumSystemVersion": "15.0",
                    "INFOPLIST_KEY_NSHighResolutionCapable": "YES",
                    "LSUIElement": "NO",
                    "NSAudioCaptureUsageDescription": "Lumen needs access to system audio to stream the selected Mac display with audio.",
                    "NSBonjourServices": [
                        "_lumen._udp"
                    ],
                    "NSLocalNetworkUsageDescription": "Lumen needs local network access to advertise this host and configure authenticated remote access.",
                    "NSMicrophoneUsageDescription": "Lumen needs microphone access when you choose microphone audio for a stream.",
                    "NSMainStoryboardFile": "",
                    "NSMainNibFile": "",
                    "NSScreenCaptureUsageDescription": "Lumen needs screen recording access to capture the selected Mac display for streaming."
                ]
            ),
            sources: [
                "Projects/LumenApp/Sources/**/*.swift"
            ],
            resources: [
                "Projects/LumenApp/Resources/**",
                .folderReference(path: "../../../lumen.icon"),
                "../../../icon.svg",
                "../../../LICENSE",
                "../../../NOTICE",
                "../../../third-party/licenses/Opus-BSD-3-Clause.txt",
                "../../../third-party/licenses/Rust-Crates.html",
                "../../../third-party/licenses/Slint-Royalty-Free-2.0.txt"
            ],
            scripts: [nativeAssetsScript],
            dependencies: [
                .target(name: "LumenAppArchitecture"),
                .target(name: "LumenMacCaptureAdapter"),
                .target(name: "LumenMacBridge"),
                .sdk(name: "LocalAuthentication", type: .framework),
                .sdk(name: "UserNotifications", type: .framework)
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "Lumen",
                    "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
                    "DEVELOPMENT_TEAM": "Q23JLSJCCV",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "lumen",
                    "CODE_SIGN_STYLE": "Manual",
                    "CODE_SIGN_IDENTITY": "Developer ID Application: Buseong Kim (Q23JLSJCCV)",
                    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "OTHER_CODE_SIGN_FLAGS": "--timestamp"
                ]
            )
        ),
        .target(
            name: "LumenTuistTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.skyline23.lumen.tuist.tests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: [
                "../../../tests/tuist/macos/**/*.swift",
                "../../../tests/tuist/macos/**/*.m",
                "../../../tests/tuist/macos/**/*.mm"
            ],
            dependencies: [
                .target(name: "LumenAppArchitecture"),
                .target(name: "LumenMacBridge"),
                .target(name: "LumenMacCaptureAdapter")
            ]
        )
    ],
    schemes: [
        .scheme(
            name: "LumenApp",
            shared: true,
            buildAction: .buildAction(targets: [
                "LumenApp"
            ])
        ),
        .scheme(
            name: "LumenTuistTests",
            shared: true,
            buildAction: .buildAction(targets: [
                "LumenEngineBridge",
                "LumenAppArchitecture",
                "LumenMacBridge",
                "LumenTuistTests"
            ]),
            testAction: .targets([
                .testableTarget(target: "LumenTuistTests")
            ])
        ),
        .scheme(
            name: "LumenDisplayDisconnectCanary",
            shared: true,
            buildAction: .buildAction(targets: [
                "LumenDisplayDisconnectCanary"
            ])
        )
    ]
)
