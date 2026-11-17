// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "fnb58",
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "fnb58",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "fnb58Tests",
            dependencies: ["fnb58"]
        ),
    ]
)
