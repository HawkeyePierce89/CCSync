// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CCSync",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CCSyncCore", targets: ["CCSyncCore"]),
        .executable(name: "ccsync", targets: ["ccsync"])
    ],
    targets: [
        .target(
            name: "CCSyncCore"
        ),
        .executableTarget(
            name: "ccsync",
            dependencies: ["CCSyncCore"]
        ),
        .testTarget(
            name: "CCSyncCoreTests",
            dependencies: ["CCSyncCore"]
        )
    ]
)
