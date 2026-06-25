// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Showless",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "showless", targets: ["ShowlessCLI"]),
        .library(name: "ShowlessCore", targets: ["ShowlessCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "ShowlessCLI",
            dependencies: [
                "ShowlessCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .target(
            name: "ShowlessCore"
        ),
        .testTarget(
            name: "ShowlessCoreTests",
            dependencies: ["ShowlessCore"]
        ),
        .testTarget(
            name: "ShowlessCLITests",
            dependencies: ["ShowlessCore"]
        )
    ]
)
