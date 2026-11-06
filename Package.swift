// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AISessionRadar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AISessionRadar",
            path: "Sources/AISessionRadar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AISessionRadarTests",
            dependencies: ["AISessionRadar"],
            path: "tests/AISessionRadarTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
