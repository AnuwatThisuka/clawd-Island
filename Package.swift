// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawdIsland",
    platforms: [.macOS("14.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClawdIsland",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClawdIslandTests",
            dependencies: ["ClawdIsland"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
