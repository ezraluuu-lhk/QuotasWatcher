// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuotasWatch",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "QuotasWatch", targets: ["QuotasWatch"]),
        .library(name: "QuotasWatchCore", targets: ["QuotasWatchCore"])
    ],
    targets: [
        .target(name: "QuotasWatchCore"),
        .executableTarget(
            name: "QuotasWatch",
            dependencies: ["QuotasWatchCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "QuotasWatchCoreTests",
            dependencies: ["QuotasWatchCore"]
        )
    ]
)
