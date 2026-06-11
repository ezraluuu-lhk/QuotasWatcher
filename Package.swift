// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuotasWatcher",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "QuotasWatcher", targets: ["QuotasWatcher"]),
        .library(name: "QuotasWatcherCore", targets: ["QuotasWatcherCore"])
    ],
    targets: [
        .target(name: "QuotasWatcherCore"),
        .executableTarget(
            name: "QuotasWatcher",
            dependencies: ["QuotasWatcherCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "QuotasWatcherCoreTests",
            dependencies: ["QuotasWatcherCore"]
        )
    ]
)
