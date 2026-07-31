// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "Lumen",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "LumenClientContracts", targets: ["LumenClientContracts"]),
    .executable(name: "lumen-contract-tool", targets: ["LumenContractTool"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")
  ],
  targets: [
    .target(
      name: "LumenClientContracts",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf")
      ],
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "LumenClientContractsTests",
      dependencies: ["LumenClientContracts"],
      path: "tests/LumenClientContractsTests"
    ),
    .target(
      name: "LumenContractToolCore",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf")
      ]
    ),
    .executableTarget(
      name: "LumenContractTool",
      dependencies: ["LumenContractToolCore"]
    ),
    .testTarget(
      name: "LumenContractToolTests",
      dependencies: ["LumenContractToolCore"],
      path: "tests/LumenContractToolTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
