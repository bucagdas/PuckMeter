// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PuckMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SMC",
            path: "Sources/SMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "PuckMeter", dependencies: ["SMC"], path: "Sources/PuckMeter")
    ]
)
