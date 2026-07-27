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
        // SHA-256 for the `.matchHash` write expectation. On InfSketchServerKit ONLY —
        // InfSketchWire carries the digest as opaque bytes and stays dependency-free.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
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
                .product(name: "Crypto", package: "swift-crypto"),
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
