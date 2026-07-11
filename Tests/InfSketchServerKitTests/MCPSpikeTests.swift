import Foundation
import Testing
@testable import InfSketchServerKit
import MCP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Spike (Task 1, mcp_endpoint branch): proves the official MCP swift-sdk
/// composes with our FlyingFox server. Starts a real `InfSketchServer` on a
/// real socket, connects the SDK's own `Client` + `HTTPClientTransport` to
/// `/mcp` over real HTTP (no in-process shortcut), and drives a full
/// initialize -> tools/list round-trip. This test is the composition proof
/// and stays in the suite forever — see docs/superpowers/sdd/task-1-report.md
/// for the full spike write-up (the three SPIKE-PINs, SDK version, gate
/// decision).
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
    @Test func initializeAndListToolsOverRealHTTP() async throws {
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
        #expect(initResult.capabilities.tools != nil)

        let (tools, _) = try await client.listTools()
        #expect(tools.contains { $0.name == "ping" })

        await client.disconnect()
        await server.stop()
    }
}
