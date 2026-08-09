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
        // PINNED TO A FORK, and only to get Windows building. The fork is upstream 0.12.1 plus one
        // commit: `HTTPClientTransport.swift` guards `import EventSource` with `#if !os(Linux)`,
        // while upstream's own manifest links EventSource on APPLE platforms only — so on Windows
        // the guard is true, the module is absent, and the MCP target does not compile. EventSource
        // cannot be linked there instead (it depends on swift-nio and declares only Apple
        // platforms), so Windows belongs on the same no-SSE path Linux takes; the fix expresses the
        // condition as `canImport(EventSource)` at all five sites. Patch and rationale:
        // docs/swift-sdk-windows-eventsource.patch.
        //
        // DROP THIS PIN once an upstream release carries the fix — a fork pin that outlives its
        // reason is how a dependency quietly stops receiving updates. A `revision:` rather than a
        // branch so the build is reproducible.
        .package(url: "https://github.com/circuitshepherd/swift-sdk.git",
                 revision: "518721b77a77e8f8835d89353e0acbb2b110297b"),
        // SHA-256 for the `.matchHash` write expectation. On InfSketchServerKit ONLY —
        // InfSketchWire carries the digest as opaque bytes and stays dependency-free.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Terminal QR codes for scan-to-join. MIT, pure Swift, no dependencies of its own — a
        // port of Nayuki's reference implementation. Chosen over image-only libraries because it
        // exposes the module grid (`getModule(x:y:)`), which is what a text renderer needs.
        .package(url: "https://github.com/fwcd/swift-qrcode-generator.git", from: "2.0.2"),
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
                .product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
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
            dependencies: ["InfSketchServerKit", "InfSketchWire"],
            // A document written by the APP's `JSONEncoder`, carrying a real escaped base64 run.
            // Checked in so the blob-omission tests are self-contained: the app repo is not present
            // in the Linux container CI runs in, and a test that silently skips there is a test
            // that passes with zero coverage of the thing it exists to cover.
            resources: [.copy("Fixtures/RealDocument.infsketch")],
            swiftSettings: [
                // The SDK's `HTTPClientTransport` can only do SSE where swift-sdk compiles in its
                // `EventSource` dependency, which its own manifest restricts to exactly the
                // platforms listed here — so its `Client` cannot complete an initialize against
                // `StatefulHTTPServerTransport` anywhere else. The four test files that drive a
                // real client over real HTTP gate on this flag.
                //
                // Declared HERE, beside the dependency whose upstream conditional causes it, and
                // as a POSITIVE list of the platforms that HAVE the capability. It used to live in
                // each file as `#if !os(Linux)` — naming the one platform then known to lack it —
                // and that is exactly how it broke: Windows lacks it too, so the gate read TRUE
                // there and the suite compiled in four files whose client can never connect. A
                // capability written as "not the platform that was failing at the time" is one
                // more platform away from being wrong again.
                .define("MCP_SSE_CLIENT", .when(platforms: [
                    .macOS, .iOS, .tvOS, .watchOS, .visionOS, .macCatalyst,
                ])),
            ]
        ),
    ]
)
