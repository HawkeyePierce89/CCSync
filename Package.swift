// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CCSync",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CCSyncCore", targets: ["CCSyncCore"])
    ],
    targets: [
        .target(
            name: "CCSyncCore"
        ),
        .testTarget(
            name: "CCSyncCoreTests",
            dependencies: ["CCSyncCore"]
        )
    ]
)
