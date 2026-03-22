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

let project = Project(
    name: "Apollo",
    packages: [
        .package(path: "../MacDisplayKit")
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
                "src/platform/macos/bootstrap/ApolloCore/src/**/*.{c,cc,cpp,m,mm}"
            ],
            headers: .headers(
                public: "src/platform/macos/bootstrap/ApolloCore/include/ApolloCore.h",
                private: "src/platform/macos/bootstrap/ApolloCore/include/ApolloCore.hpp"
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
                        "$(SRCROOT)/src/platform/macos/bootstrap/ApolloCore/include"
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
                "src/platform/macos/bootstrap/ApolloMacBridge/Sources/**/*.{swift,m,mm}"
            ],
            headers: .headers(
                public: "src/platform/macos/bootstrap/ApolloMacBridge/include/ApolloMacBridge.h"
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
                        "$(SRCROOT)/src/platform/macos/bootstrap/ApolloMacBridge/include"
                    ]
                ]
            )
        ),
        .target(
            name: "ApolloMacCaptureAdapter",
            destinations: .macOS,
            product: .framework,
            bundleId: "com.lizardbyte.apollo.maccaptureadapter",
            deploymentTargets: .macOS("13.0"),
            infoPlist: .default,
            sources: [
                "src/platform/macos/bootstrap/ApolloMacCaptureAdapter/Sources/**/*.{m,mm}"
            ],
            headers: .headers(
                public: "src/platform/macos/bootstrap/ApolloMacCaptureAdapter/include/ApolloMacCaptureAdapter.h"
            ),
            dependencies: [
                .target(name: "ApolloMacBridge")
            ],
            settings: .settings(
                base: [
                    "DEFINES_MODULE": "YES",
                    "PRODUCT_NAME": "ApolloMacCaptureAdapter",
                    "HEADER_SEARCH_PATHS": [
                        "$(SRCROOT)/src/platform/macos/bootstrap/ApolloMacCaptureAdapter/include"
                    ]
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
                    "CFBundleDisplayName": "Apollo",
                    "LSMinimumSystemVersion": "13.0",
                    "INFOPLIST_KEY_NSHighResolutionCapable": "YES",
                    "LSUIElement": "YES"
                ]
            ),
            sources: [
                "src/platform/macos/bootstrap/ApolloApp/Sources/**/*.swift"
            ],
            dependencies: [
                .target(name: "ApolloMacCaptureAdapter")
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
                "tests/tuist/macos/**/*.{swift,m,mm}"
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
