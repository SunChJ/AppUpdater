// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "AppUpdater",
            targets: ["AppUpdater"]),
        .executable(
            name: "AppUpdaterHelper",
            targets: ["AppUpdaterHelper"]),
        .executable(
            name: "AppUpdaterXPC",
            targets: ["AppUpdaterXPC"]),
    ],
    dependencies: [
      .package(url: "https://github.com/mxcl/Version.git", .upToNextMajor(from: "2.0.1")),
      .package(url: "https://github.com/mxcl/Path.swift.git", from: "1.0.0"),
      .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", .upToNextMajor(from: "2.3.1"))
    ],
    targets: [
        .target(
            name: "AppUpdater",
            dependencies: [
                .product(name: "Version", package: "Version"),
                .product(name: "Path", package: "Path.swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                "AppUpdaterShared"
            ],
            resources: [
                .process("Resources"),
                .copy("../AppUpdaterHelper"),
                .copy("../AppUpdaterXPC"),
                .copy("../AppUpdaterShared")
            ]),
        .executableTarget(
            name: "AppUpdaterHelper",
            dependencies: ["AppUpdaterShared"]),
        .executableTarget(
            name: "AppUpdaterXPC",
            dependencies: ["AppUpdaterShared"]),
        .target(
            name: "AppUpdaterShared",
            dependencies: [])
    ]
)
