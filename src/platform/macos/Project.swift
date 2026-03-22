import ProjectDescription

let baseSettings: SettingsDictionary = [
    "CLANG_CXX_LANGUAGE_STANDARD": "gnu++23",
    "CLANG_ENABLE_MODULES": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "DEVELOPMENT_TEAM": "6C922D256U",
    "MACOSX_DEPLOYMENT_TARGET": "13.0",
    "SWIFT_VERSION": "5.0"
]

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
    "SUNSHINE_ASSETS_DIR=\\\"/usr/local/assets\\\"",
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
    "OTHER_LDFLAGS": .array(hostedRuntimeOtherLdFlags)
]

let project = Project(
    name: "Apollo",
    packages: [
        .package(url: "https://github.com/Skyline-23/MacDisplayKit", from: "0.2.0")
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
                    "LSMinimumSystemVersion": "13.0",
                    "INFOPLIST_KEY_NSHighResolutionCapable": "YES",
                    "LSUIElement": "YES"
                ]
            ),
            sources: [
                "Projects/ApolloApp/Sources/**/*.swift"
            ],
            dependencies: [
                .target(name: "ApolloMacCaptureAdapter"),
                .sdk(name: "UserNotifications", type: .framework)
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "Apollo"
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
