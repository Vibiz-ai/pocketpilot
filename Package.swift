// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenTap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenTapCore", targets: ["OpenTapCore"]),
        .executable(name: "OpenTap", targets: ["OpenTap"]),
        .executable(name: "opentap-mock", targets: ["opentap-mock"]),
    ],
    targets: [
        .target(
            name: "OpenTapCore",
            path: "Sources/OpenTapCore",
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
            name: "OpenTap",
            dependencies: ["OpenTapCore"],
            path: "Sources/OpenTap"
        ),
        .executableTarget(
            name: "opentap-mock",
            dependencies: ["OpenTapCore"],
            path: "Sources/opentap-mock"
        ),
        .testTarget(
            name: "OpenTapCoreTests",
            dependencies: ["OpenTapCore"],
            path: "Tests/OpenTapCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
