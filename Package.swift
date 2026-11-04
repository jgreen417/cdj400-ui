// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CDJ400UI",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "CDJ400UI",
            path: "Sources/CDJ400UI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CDJ400UITests",
            dependencies: ["CDJ400UI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
