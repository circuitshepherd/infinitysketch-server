// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "infsketch-server",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.27.0")),
    ],
    targets: [
        .target(
            name: "InfSketchServerKit",
            dependencies: [.product(name: "FlyingFox", package: "FlyingFox")]
        ),
        .executableTarget(
            name: "infsketch-server",
            dependencies: ["InfSketchServerKit"]
        ),
        .executableTarget(
            name: "infsketch-demo",
            dependencies: ["InfSketchServerKit"]
        ),
        .testTarget(
            name: "InfSketchServerKitTests",
            dependencies: ["InfSketchServerKit"]
        ),
    ]
)
