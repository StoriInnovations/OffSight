// swift-tools-version:5.9
// offsight-test: on-device test tool for OffSight. See README.md.
import PackageDescription

let package = Package(
    name: "OffSightTest",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/OffSightCore"),
    ],
    targets: [
        .executableTarget(
            name: "offsight-test",
            dependencies: [.product(name: "OffSightCore", package: "OffSightCore")],
            path: "Sources/offsight-test"),
    ]
)
