// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "infsketch-server",
    platforms: [
        .macOS(.v14),
        .iOS(.v18)
    ],
    products: [
        // Wire-only library the InfinitySketch app links (no FlyingFox, no server code).
        .library(name: "InfSketchWire", targets: ["InfSketchWire"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.27.0")),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(name: "InfSketchWire"),
        .target(
            name: "InfSketchServerKit",
            dependencies: [
                "InfSketchWire",
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "infsketch-server",
            dependencies: ["InfSketchServerKit"]
        ),
        .executableTarget(
            name: "infsketch-demo",
            dependencies: ["InfSketchServerKit", "InfSketchWire"]
        ),
        .testTarget(
            name: "InfSketchServerKitTests",
            dependencies: ["InfSketchServerKit", "InfSketchWire"]
        ),
    ]
)
