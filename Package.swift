// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PocketPilot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PocketPilotCore", targets: ["PocketPilotCore"]),
        .executable(name: "PocketPilot", targets: ["PocketPilot"]),
        .executable(name: "pocketpilot-mock", targets: ["pocketpilot-mock"]),
    ],
    targets: [
        .target(
            name: "PocketPilotCore",
            path: "Sources/PocketPilotCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Vision"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "PocketPilot",
            dependencies: ["PocketPilotCore"],
            path: "Sources/PocketPilot"
        ),
        .executableTarget(
            name: "pocketpilot-mock",
            dependencies: ["PocketPilotCore"],
            path: "Sources/pocketpilot-mock"
        ),
        .testTarget(
            name: "PocketPilotCoreTests",
            dependencies: ["PocketPilotCore"],
            path: "Tests/PocketPilotCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
