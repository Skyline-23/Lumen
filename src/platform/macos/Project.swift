import ProjectDescription

let baseSettings: SettingsDictionary = [
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++23",
    "CLANG_ENABLE_MODULES": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "DEVELOPMENT_TEAM": "Q23JLSJCCV",
    "MACOSX_DEPLOYMENT_TARGET": "13.0",
    "SWIFT_VERSION": "5.0"
]

let macDisplayKitURL = "https://github.com/Skyline-23/MacDisplayKit.git"
let macDisplayKitRevision = "20e8751aa4d186998fe329b6fa7d05b260a4bf53"

let repoRoot = "$(SRCROOT)/../../.."
let buildDepsRoot = "\(repoRoot)/third-party/build-deps/dist/Darwin-arm64"

let hostedRuntimeHeaderSearchPaths = [
    "\(buildDepsRoot)/include",
    "\(repoRoot)",
    "\(repoRoot)/src",
    "\(repoRoot)/third-party",
    "$(SRCROOT)/Projects/ApolloCore/Headers",
    "$(SRCROOT)/Projects/ApolloMacSupport/Headers",
    "\(repoRoot)/third-party/libdisplaydevice/src/common/include",
    "\(repoRoot)/third-party/moonlight-common-c/enet/include",
    "\(repoRoot)/third-party/nanors",
    "\(repoRoot)/third-party/nanors/deps/obl",
    "\(repoRoot)/third-party/nv-codec-headers/include",
    "/opt/homebrew/include",
    "/opt/homebrew/Cellar/miniupnpc/2.3.3/include"
]

let hostedRuntimeLibrarySearchPaths = [
    "/opt/homebrew/opt/boost/lib",
    "\(buildDepsRoot)/lib",
    "/opt/homebrew/lib",
    "/opt/homebrew/opt/openssl/lib",
    "/usr/local/lib"
]

let hostedRuntimePreprocessorDefinitions = [
    "BOOST_ATOMIC_DYN_LINK",
    "BOOST_ATOMIC_NO_LIB",
    "BOOST_CHARCONV_DYN_LINK",
    "BOOST_CHARCONV_NO_LIB",
    "BOOST_CHRONO_DYN_LINK",
    "BOOST_CHRONO_NO_LIB",
    "BOOST_CONTAINER_DYN_LINK",
    "BOOST_CONTAINER_NO_LIB",
    "BOOST_DATE_TIME_DYN_LINK",
    "BOOST_DATE_TIME_NO_LIB",
    "BOOST_FILESYSTEM_DYN_LINK",
    "BOOST_FILESYSTEM_NO_LIB",
    "BOOST_LOCALE_DYN_LINK",
    "BOOST_LOCALE_NO_LIB",
    "BOOST_LOG_DYN_LINK",
    "BOOST_LOG_NO_LIB",
    "BOOST_PROGRAM_OPTIONS_DYN_LINK",
    "BOOST_PROGRAM_OPTIONS_NO_LIB",
    "BOOST_REGEX_DYN_LINK",
    "BOOST_REGEX_NO_LIB",
    "BOOST_THREAD_DYN_LINK",
    "BOOST_THREAD_NO_LIB",
    "PROJECT_NAME=\\\"Apollo\\\"",
    "PROJECT_VERSION=\\\"0.0.0\\\"",
    "PROJECT_VERSION_COMMIT=\\\"\\\"",
    "PROJECT_VERSION_MAJOR=\\\"0\\\"",
    "PROJECT_VERSION_MINOR=\\\"0\\\"",
    "PROJECT_VERSION_PATCH=\\\"0\\\"",
    "SUNSHINE_ASSETS_DIR=\\\"../Resources/assets\\\"",
    "SUNSHINE_PLATFORM=\\\"macos\\\"",
    "SUNSHINE_PUBLISHER_ISSUE_URL=\\\"https://github.com/ClassicOldSong/Apollo/issues\\\"",
    "SUNSHINE_PUBLISHER_NAME=\\\"SudoMaker\\\"",
    "SUNSHINE_PUBLISHER_WEBSITE=\\\"https://www.sudomaker.com\\\"",
    "SUNSHINE_TRAY=1",
    "APOLLO_EMBEDDED_HOST=1"
]

let hostedRuntimeOtherLdFlags = [
    "-framework",
    "UserNotifications",
    "-lcurl",
    "-lminiupnpc",
    "-lopus",
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
    "-lssl",
    "-lcrypto",
    "-lboost_charconv",
    "-lboost_filesystem",
    "-lboost_thread",
    "-lboost_atomic",
    "-lboost_chrono",
    "-lboost_date_time",
    "-lboost_regex",
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
    "../../../src/nvhttp.cpp",
    "../../../src/httpcommon.cpp",
    "../../../src/confighttp.cpp",
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
    "Projects/ApolloMacSupport/Sources/**/*.{c,cc,cpp,m,mm,h,hpp}",
    "Projects/ApolloHostedRuntime/Sources/**/*.{c,cc,cpp,m,mm,h,hpp}"
]

let hostedRuntimeSettings: SettingsDictionary = [
    "PRODUCT_NAME": "ApolloHostedRuntime",
    "DEFINES_MODULE": "YES",
    "HEADER_SEARCH_PATHS": .array(hostedRuntimeHeaderSearchPaths),
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
        echo "error: npm was not found for the Apollo asset build phase." >&2
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
    name: "Stage Apollo Assets",
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
    name: "Apollo",
    packages: [
        .package(url: macDisplayKitURL, .revision(macDisplayKitRevision))
    ],
    settings: .settings(base: baseSettings),
    targets: [
        .target(
            name: "ApolloCore",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.lizardbyte.apollo.core",
            deploymentTargets: .macOS("13.0"),
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
            name: "ApolloMacBridge",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.lizardbyte.apollo.macbridge",
            deploymentTargets: .macOS("13.0"),
            infoPlist: .default,
            sources: [
                "Projects/ApolloMacBridge/Sources/**/*.{swift,m,mm}"
            ],
            headers: .headers(
                public: "Projects/ApolloMacBridge/Headers/ApolloMacBridge.h"
            ),
            dependencies: [
                .target(name: "ApolloCore"),
                .package(product: "MacDisplayCaptureKit", type: .runtime)
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "ApolloMacBridge",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                    "SWIFT_ENABLE_LIBRARY_EVOLUTION": "YES",
                    "HEADER_SEARCH_PATHS": [
                        "$(SRCROOT)/Projects/ApolloMacBridge/Headers"
                    ]
                ]
            )
        ),
        .target(
            name: "ApolloHostedRuntime",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.lizardbyte.apollo.hostedruntime",
            deploymentTargets: .macOS("13.0"),
            infoPlist: .default,
            sources: hostedRuntimeSources,
            headers: .headers(
                public: "Projects/ApolloHostedRuntime/Headers/ApolloHostedRuntime.h"
            ),
            dependencies: [
                .target(name: "ApolloCore"),
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
            name: "ApolloMacCaptureAdapter",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.lizardbyte.apollo.maccaptureadapter",
            deploymentTargets: .macOS("13.0"),
            infoPlist: .default,
            sources: [
                "Projects/ApolloMacCaptureAdapter/Sources/**/*.swift"
            ],
            dependencies: [
                .target(name: "ApolloMacBridge"),
                .target(name: "ApolloHostedRuntime")
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "ApolloMacCaptureAdapter"
                ]
            )
        ),
        .target(
            name: "ApolloApp",
            destinations: .macOS,
            product: .app,
            bundleId: "com.lizardbyte.apollo.app",
            deploymentTargets: .macOS("13.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "Apollo Companion",
                    "CFBundleIconFile": "apollo.icns",
                    "LSMinimumSystemVersion": "13.0",
                    "INFOPLIST_KEY_NSHighResolutionCapable": "YES",
                    "LSUIElement": "YES",
                    "NSAudioCaptureUsageDescription": "Apollo needs access to system audio to stream the selected Mac display with audio.",
                    "NSMicrophoneUsageDescription": "Apollo needs microphone access when you choose microphone audio for a stream.",
                    "NSMainStoryboardFile": "",
                    "NSMainNibFile": "",
                    "NSScreenCaptureUsageDescription": "Apollo needs screen recording access to capture the selected Mac display for streaming."
                ]
            ),
            sources: [
                "Projects/ApolloApp/Sources/**/*.swift"
            ],
            resources: [
                "../../../apollo.icns",
                "../../../src_assets/common/assets/web/public/images/logo-apollo-16.png",
                "../../../src_assets/common/assets/web/public/images/apollo-playing-16.png",
                "../../../src_assets/common/assets/web/public/images/apollo-pausing-16.png",
                "../../../src_assets/common/assets/web/public/images/apollo-locked-16.png"
            ],
            scripts: [appAssetsScript],
            dependencies: [
                .target(name: "ApolloMacCaptureAdapter"),
                .sdk(name: "UserNotifications", type: .framework)
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "Apollo",
                    "AD_HOC_CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "DEVELOPMENT_TEAM": "Q23JLSJCCV"
                ]
            )
        ),
        .target(
            name: "ApolloTuistTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.lizardbyte.apollo.tuist.tests",
            deploymentTargets: .macOS("13.0"),
            infoPlist: .default,
            sources: [
                "../../../tests/tuist/macos/**/*.{swift,m,mm}"
            ],
            dependencies: [
                .target(name: "ApolloMacBridge"),
                .target(name: "ApolloMacCaptureAdapter")
            ]
        )
    ],
    schemes: [
        .scheme(
            name: "ApolloTuistTests",
            shared: true,
            buildAction: .buildAction(targets: [
                "ApolloCore",
                "ApolloMacBridge",
                "ApolloTuistTests"
            ]),
            testAction: .targets([
                .testableTarget(target: "ApolloTuistTests")
            ])
        )
    ]
)
