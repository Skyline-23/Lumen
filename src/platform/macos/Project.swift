import ProjectDescription

let baseSettings: SettingsDictionary = [
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++23",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "DEVELOPMENT_TEAM": "Q23JLSJCCV",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "SWIFT_VERSION": "5.0"
]

let macDisplayKitURL = "https://github.com/Skyline-23/MacDisplayKit.git"
let macDisplayKitRevision = "3525b1f79ba6f25842f3b337704c011476ef1d94"

let repoRoot = "$(SRCROOT)/../../.."
let buildDepsRoot = "\(repoRoot)/third-party/build-deps/dist/Darwin-arm64"
let runtimeDepsRoot = "\(repoRoot)/third-party/runtime-deps/dist/Darwin-arm64"

let hostedRuntimeHeaderSearchPaths = [
    "\(buildDepsRoot)/include",
    "\(runtimeDepsRoot)/include",
    "\(repoRoot)/src",
    "$(SRCROOT)/Projects/ApolloCore/Headers",
    "$(SRCROOT)/Projects/LumenMacBridge/Headers",
    "$(SRCROOT)/Projects/LumenMacSupport/Headers"
]

let hostedRuntimeSystemHeaderSearchPaths = [
    "\(repoRoot)",
    "\(repoRoot)/third-party",
    "\(repoRoot)/third-party/libdisplaydevice/src/common/include",
    "\(repoRoot)/third-party/moonlight-common-c/enet/include",
    "\(repoRoot)/third-party/nanors",
    "\(repoRoot)/third-party/nanors/deps/obl",
    "\(repoRoot)/third-party/nv-codec-headers/include"
]

let hostedRuntimeLibrarySearchPaths = [
    "\(buildDepsRoot)/lib"
]

let hostedRuntimeVendoredArchives = [
    "\(runtimeDepsRoot)/lib/libminiupnpc.a",
    "\(runtimeDepsRoot)/lib/libopus.a",
    "\(runtimeDepsRoot)/lib/libssl.a",
    "\(runtimeDepsRoot)/lib/libcrypto.a"
]

let hostedRuntimePreprocessorDefinitions = [
    "BOOST_ATOMIC_NO_LIB",
    "BOOST_CHARCONV_NO_LIB",
    "BOOST_CHRONO_NO_LIB",
    "BOOST_CONTAINER_NO_LIB",
    "BOOST_DATE_TIME_NO_LIB",
    "BOOST_FILESYSTEM_NO_LIB",
    "BOOST_LOCALE_NO_LIB",
    "BOOST_LOG_NO_LIB",
    "BOOST_PROGRAM_OPTIONS_NO_LIB",
    "BOOST_REGEX_NO_LIB",
    "BOOST_THREAD_NO_LIB",
    "PROJECT_NAME=\\\"Lumen\\\"",
    "PROJECT_VERSION=\\\"0.0.0\\\"",
    "PROJECT_VERSION_COMMIT=\\\"\\\"",
    "PROJECT_VERSION_MAJOR=\\\"0\\\"",
    "PROJECT_VERSION_MINOR=\\\"0\\\"",
    "PROJECT_VERSION_PATCH=\\\"0\\\"",
    "SUNSHINE_ASSETS_DIR=\\\"../Resources/assets\\\"",
    "SUNSHINE_PLATFORM=\\\"macos\\\"",
    "SUNSHINE_PUBLISHER_ISSUE_URL=\\\"https://github.com/Skyline-23/Lumen/issues\\\"",
    "SUNSHINE_PUBLISHER_NAME=\\\"SudoMaker\\\"",
    "SUNSHINE_PUBLISHER_WEBSITE=\\\"https://www.sudomaker.com\\\"",
    "SUNSHINE_TRAY=1",
    "APOLLO_EMBEDDED_HOST=1"
]

let hostedRuntimeOtherLdFlags = hostedRuntimeVendoredArchives + [
    "-framework",
    "UserNotifications",
    "-lcurl",
    "-lavcodec",
    "-lswscale",
    "-lavutil",
    "-lcbs",
    "-lSvtAv1Enc",
    "-lx264",
    "-lx265",
    "-lboost_locale",
    "-lboost_log",
    "-lboost_program_options",
    "-lboost_filesystem",
    "-lboost_thread",
    "-lboost_atomic",
    "-lboost_chrono",
    "-lboost_date_time",
    "-lboost_container"
]

let hostedRuntimeSources: SourceFilesList = [
    "../../../third-party/moonlight-common-c/src/RtspParser.c",
    "../../../third-party/moonlight-common-c/enet/**/*.{c,h}",
    "../../../third-party/TPCircularBuffer/TPCircularBuffer.c",
    "../../../third-party/tray/src/tray_darwin.m",
    "../../../third-party/libdisplaydevice/src/common/**/*.{c,cc,cpp,h,hpp}",
    "../../../src/upnp.cpp",
    "../../../src/cbs.cpp",
    "../../../src/config.cpp",
    "../../../src/display_device.cpp",
    "../../../src/entry_handler.cpp",
    "../../../src/file_handler.cpp",
    "../../../src/globals.cpp",
    "../../../src/logging.cpp",
    "../../../src/main.cpp",
    "../../../src/crypto.cpp",
    "../../../src/shadow_http.cpp",
    "../../../src/shadow_http_common.cpp",
    "../../../src/shadow_control_http.cpp",
    "../../../src/rtsp.cpp",
    "../../../src/stream.cpp",
    "../../../src/video.cpp",
    "../../../src/video_colorspace.cpp",
    "../../../src/input.cpp",
    "../../../src/audio.cpp",
    "../../../src/process.cpp",
    "../../../src/network.cpp",
    "../../../src/system_tray.cpp",
    "../../../src/stat_trackers.cpp",
    "../../../src/rswrapper.c",
    "../../../src/nvenc/*.cpp",
    "Projects/LumenMacSupport/Sources/**/*.{c,cc,cpp,m,mm,h,hpp}",
    "Projects/LumenHostedRuntime/Sources/**/*.{c,cc,cpp,m,mm,h,hpp}"
]

let hostedRuntimeSettings: SettingsDictionary = [
    "PRODUCT_NAME": "LumenHostedRuntime",
    "DEFINES_MODULE": "YES",
    "HEADER_SEARCH_PATHS": .array(hostedRuntimeHeaderSearchPaths),
    "SYSTEM_HEADER_SEARCH_PATHS": .array(hostedRuntimeSystemHeaderSearchPaths),
    "LIBRARY_SEARCH_PATHS": .array(hostedRuntimeLibrarySearchPaths),
    "GCC_PREPROCESSOR_DEFINITIONS": .array(hostedRuntimePreprocessorDefinitions),
    "OTHER_CPLUSPLUSFLAGS": .array([
        "$(inherited)",
        "-include",
        "type_traits"
    ]),
    "OTHER_LDFLAGS": .array(hostedRuntimeOtherLdFlags)
]

let appAssetsScript = TargetScript.post(
    script: #"""
    set -euo pipefail

    resolve_npm() {
        local npm_path

        npm_path="$(command -v npm 2>/dev/null || true)"
        if [[ -n "${npm_path}" ]]; then
            printf '%s\n' "${npm_path}"
            return 0
        fi

        if [[ -n "${HOME:-}" ]]; then
            npm_path="$(/bin/ls -1dt "${HOME}"/.nvm/versions/node/*/bin/npm 2>/dev/null | /usr/bin/head -n 1 || true)"
            if [[ -n "${npm_path}" ]]; then
                printf '%s\n' "${npm_path}"
                return 0
            fi
        fi

        for npm_path in /opt/homebrew/bin/npm /usr/local/bin/npm /opt/homebrew/opt/node/bin/npm; do
            if [[ -x "${npm_path}" ]]; then
                printf '%s\n' "${npm_path}"
                return 0
            fi
        done

        return 1
    }

    REPO_ROOT="${SRCROOT}/../../.."
    RESOURCES_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
    ASSETS_ROOT="${RESOURCES_ROOT}/assets"
    NPM_BIN="$(resolve_npm || true)"

    if [[ -z "${NPM_BIN}" ]]; then
        echo "error: npm was not found for the Lumen asset build phase." >&2
        echo "Searched PATH, ~/.nvm, /opt/homebrew/bin, /usr/local/bin, and /opt/homebrew/opt/node/bin." >&2
        exit 1
    fi

    rm -rf "${ASSETS_ROOT}"
    mkdir -p "${ASSETS_ROOT}"

    rsync -a --exclude 'web' "${REPO_ROOT}/src_assets/common/assets/" "${ASSETS_ROOT}/"
    rsync -a --exclude 'Info.plist' "${REPO_ROOT}/src_assets/macos/assets/" "${ASSETS_ROOT}/"

    cd "${REPO_ROOT}"
    export SUNSHINE_SOURCE_ASSETS_DIR="${REPO_ROOT}/src_assets"
    export SUNSHINE_ASSETS_DIR="${RESOURCES_ROOT}"
    export PATH="$(/usr/bin/dirname "${NPM_BIN}"):${PATH:-}"
    "${NPM_BIN}" exec -- vite build
    """#,
    name: "Stage Lumen Assets",
    inputPaths: [
        .glob("\(repoRoot)/src_assets/common/assets/**/*"),
        .glob("\(repoRoot)/src_assets/macos/assets/**/*"),
        .glob("\(repoRoot)/package.json"),
        .glob("\(repoRoot)/package-lock.json"),
        .glob("\(repoRoot)/vite.config.js")
    ],
    basedOnDependencyAnalysis: false,
    shellPath: "/bin/zsh"
)

let project = Project(
    name: "Lumen",
    packages: [
        .package(url: macDisplayKitURL, .revision(macDisplayKitRevision))
    ],
    settings: .settings(base: baseSettings),
    targets: [
        .target(
            name: "ApolloCore",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.core",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: [
                "Projects/ApolloCore/Sources/**/*.{c,cc,cpp,m,mm}"
            ],
            headers: .headers(
                public: "Projects/ApolloCore/Headers/ApolloCore.h"
            ),
            dependencies: [
                .sdk(name: "CoreFoundation", type: .framework),
                .sdk(name: "CoreMedia", type: .framework)
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "ApolloCore",
                    "HEADER_SEARCH_PATHS": [
                        "$(SRCROOT)/Projects/ApolloCore/Headers"
                    ]
                ]
            )
        ),
        .target(
            name: "LumenMacBridge",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.macbridge",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: [
                "Projects/LumenMacBridge/Sources/**/*.{swift,m,mm}"
            ],
            headers: .headers(
                public: "Projects/LumenMacBridge/Headers/LumenMacBridge.h"
            ),
            dependencies: [
                .target(name: "ApolloCore"),
                .package(product: "MacDisplayCaptureKit", type: .runtime)
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
            name: "LumenHostedRuntime",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.hostedruntime",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: hostedRuntimeSources,
            headers: .headers(
                public: "Projects/LumenHostedRuntime/Headers/LumenHostedRuntime.h"
            ),
            dependencies: [
                .target(name: "ApolloCore"),
                .target(name: "LumenMacBridge"),
                .sdk(name: "AppKit", type: .framework),
                .sdk(name: "ApplicationServices", type: .framework),
                .sdk(name: "AVFoundation", type: .framework),
                .sdk(name: "Cocoa", type: .framework),
                .sdk(name: "CoreMedia", type: .framework),
                .sdk(name: "CoreVideo", type: .framework),
                .sdk(name: "Foundation", type: .framework),
                .sdk(name: "Metal", type: .framework),
                .sdk(name: "ScreenCaptureKit", type: .framework),
                .sdk(name: "UserNotifications", type: .framework),
                .sdk(name: "VideoToolbox", type: .framework)
            ],
            settings: .settings(base: hostedRuntimeSettings)
        ),
        .target(
            name: "LumenMacCaptureAdapter",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.skyline23.lumen.maccaptureadapter",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: [
                "Projects/LumenMacCaptureAdapter/Sources/**/*.swift"
            ],
            dependencies: [
                .target(name: "LumenMacBridge"),
                .target(name: "LumenHostedRuntime")
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "LumenMacCaptureAdapter"
                ]
            )
        ),
        .target(
            name: "LumenApp",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.skyline23.lumen.app",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "Lumen",
                    "CFBundleIconFile": "lumen.icns",
                    "LSMinimumSystemVersion": "14.0",
                    "INFOPLIST_KEY_NSHighResolutionCapable": "YES",
                    "LSUIElement": "YES",
                    "NSAudioCaptureUsageDescription": "Lumen needs access to system audio to stream the selected Mac display with audio.",
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
                "../../../lumen.icns",
                "../../../src_assets/common/assets/web/public/images/logo-lumen-16.png",
                "../../../src_assets/common/assets/web/public/images/lumen-playing-16.png",
                "../../../src_assets/common/assets/web/public/images/lumen-pausing-16.png",
                "../../../src_assets/common/assets/web/public/images/lumen-locked-16.png"
            ],
            scripts: [appAssetsScript],
            dependencies: [
                .target(name: "LumenMacCaptureAdapter"),
                .sdk(name: "UserNotifications", type: .framework)
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "Lumen",
                    "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "DEVELOPMENT_TEAM": "Q23JLSJCCV"
                ]
            )
        ),
        .target(
            name: "LumenTuistTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "dev.skyline23.lumen.tuist.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: [
                "../../../tests/tuist/macos/**/*.{swift,m,mm}"
            ],
            dependencies: [
                .target(name: "LumenMacBridge"),
                .target(name: "LumenMacCaptureAdapter")
            ]
        )
    ],
    schemes: [
        .scheme(
            name: "LumenTuistTests",
            shared: true,
            buildAction: .buildAction(targets: [
                "ApolloCore",
                "LumenMacBridge",
                "LumenTuistTests"
            ]),
            testAction: .targets([
                .testableTarget(target: "LumenTuistTests")
            ])
        )
    ]
)
