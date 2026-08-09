// Apple-platforms-only: the SDK's HTTPClientTransport does not support SSE without its
// `EventSource` dependency (documented in its source), so its Client cannot complete initialize
// against StatefulHTTPServerTransport there; the server-side mount itself is Linux-proven — see
// task-1-report.md (gate resolution: Josef, 2026-07-11). The flag is defined in Package.swift,
// beside the dependency that causes it; it replaced `!os(Linux)`, which read TRUE on Windows.
#if MCP_SSE_CLIENT

import Foundation
import Testing
@testable import InfSketchServerKit
import MCP

/// Spike (Task 1, mcp_endpoint branch): proves the official MCP swift-sdk
/// composes with our FlyingFox server. Starts a real `InfSketchServer` on a
/// real socket, connects the SDK's own `Client` + `HTTPClientTransport` to
/// `/mcp` over real HTTP (no in-process shortcut), and drives a full
/// initialize -> resources/list round-trip. This test is the composition
/// proof and stays in the suite forever as the mount's regression net — see
/// docs/superpowers/sdd/task-1-report.md for the full spike write-up (the
/// three SPIKE-PINs, SDK version, gate decision).
///
/// Task 6 replaced the spike's hello-world `ping` tool server with the real
/// `MCPAdapter` (resources, not tools — Task 7 adds tools). This test was
/// updated accordingly: the initialize handshake and `serverInfo.name ==
/// "infsketch"` assertions are unchanged, but the surviving minimal
/// capability check is now `capabilities.resources?.subscribe == true` +
/// `resources/list` containing `infsketch://docs`, in place of the old
/// `capabilities.tools`/`ping` assertions (the adapter declares no tools
/// capability yet). See task-6-report.md for the full reasoning.
private func startServer() async throws -> (InfSketchServer, UInt16, Task<Void, any Error>) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-spike-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let server = InfSketchServer(port: 0, docsDirectory: dir)
    let task = Task { try await server.run() }
    try await server.waitUntilListening()
    let port = try #require(await server.listeningPort)
    return (server, port, task)
}

@Suite struct MCPSpikeTests {
    @Test func initializeAndListResourcesOverRealHTTP() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let transport = HTTPClientTransport(endpoint: endpoint)
        let client = Client(name: "mcp-spike-client", version: "0.0.1")

        // `connect(transport:)` performs the full initialize handshake
        // (request + InitializedNotification) itself and returns the result.
        let initResult = try await client.connect(transport: transport)
        #expect(initResult.serverInfo.name == "infsketch")
        #expect(initResult.serverInfo.version == ServerInfo.version)
        #expect(initResult.capabilities.resources?.subscribe == true)

        let (resources, _) = try await client.listResources()
        #expect(resources.contains { $0.uri == "infsketch://docs" })

        await client.disconnect()
        await server.stop()
    }
}

#endif  // MCP_SSE_CLIENT
