// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "infsketch-server",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "infsketch-server"
        )
    ]
)
