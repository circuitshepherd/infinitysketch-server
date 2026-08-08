import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import InfSketchServerKit

/// The overview page carries the connect block, and it is built per request — so an address that
/// appeared since startup shows up on a reload rather than at the next restart.
@Suite struct ConnectSectionRouteTests {

    private func startServer() async throws -> (InfSketchServer, UInt16, Task<Void, any Error>) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = InfSketchServer(port: 0, docsDirectory: dir, config: SessionConfig())
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        return (server, port, task)
    }

    @Test func theOverviewPageCarriesTheConnectSection() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let (body, response) = try await URLSession.shared
            .data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let html = String(decoding: body, as: UTF8.self)
        #expect(html.contains("id=\"connect\""))
        #expect(html.contains("Connect a device"))
        // The document table is still there — the section is added, not substituted.
        #expect(html.contains("id=\"docs\""))
        await server.stop()
    }

    /// The page names the port it is actually LISTENING on, which under `port: 0` is not the port
    /// it was constructed with. An agent url naming port 0 would be unusable.
    @Test func theAgentUrlNamesTheRealPort() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let (body, _) = try await URLSession.shared
            .data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let html = String(decoding: body, as: UTF8.self)
        #expect(html.contains(":\(port)/mcp"))
        #expect(!html.contains(":0/mcp"))
        await server.stop()
    }
}
