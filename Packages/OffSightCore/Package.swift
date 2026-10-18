// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OffSightCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OffSightCore", targets: ["OffSightCore"]),
    ],
    targets: [
        .target(name: "OffSightCore"),
        .testTarget(name: "OffSightCoreTests", dependencies: ["OffSightCore"]),
    ]
)
