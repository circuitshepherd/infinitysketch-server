// macOS-only for the same reason as MCPAdapterTests: no SSE in the SDK's client on Linux.
#if !os(Linux)

import Foundation
import Testing
@testable import InfSketchServerKit
import MCP

/// `list_open_docs` — "which document am I actually talking to?"
/// (spec 2026-07-27-list-open-docs-design.md).
///
/// A `docId` is the filename stem captured when the app opened the document, so a rename
/// mid-session leaves the name a human says different from the live id, and every tool aimed at
/// the spoken name fails against a healthy device. This tool is the truth, read cheaply and
/// without a device round trip.
@Suite(.serialized)
struct ListOpenDocsTests {

    private func startServer(docIds: [String]) async throws
        -> (InfSketchServer, UInt16, Task<Void, any Error>) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-docs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        for id in docIds { try store.save(docId: id, bytes: Fixtures.docBytes) }
        let server = InfSketchServer(port: 0, docsDirectory: dir)
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        return (server, port, task)
    }

    private func client(_ port: UInt16) async throws -> Client {
        let c = Client(name: "open-docs", version: "1")
        try await c.connect(transport: HTTPClientTransport(
            endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: false))
        return c
    }

    private func listing(_ c: Client) async throws -> [String: Any] {
        let (content, isError) = try await c.callTool(name: "list_open_docs", arguments: [:])
        #expect(isError != true)
        let text = content.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }.joined()
        return (try JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test func withNothingConnectedBothHalvesAreEmpty() async throws {
        let (_, port, task) = try await startServer(docIds: ["d"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        let json = try await listing(c)

        #expect((json["openDocs"] as? [Any])?.isEmpty == true)
        let devices = json["devices"] as? [String: Any]
        #expect(devices?["count"] as? Int == 0)
        #expect((devices?["capabilities"] as? [Any])?.isEmpty == true)
    }

    /// The filter that makes "open" mean OPEN. Any server-side tool touching a document opens a
    /// session for it; listing those would answer "what is open?" with documents nobody has on
    /// screen — the exact guesswork this tool exists to end.
    @Test func aSessionWithNoSubscriberIsNotOpen() async throws {
        let (_, port, task) = try await startServer(docIds: ["d"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        // A server-side write. It opens a session for "d" — with no subscriber.
        let (_, isError) = try await c.callTool(
            name: "set_paper", arguments: ["docId": "d", "light": "#FFEEC0"])
        #expect(isError != true)

        let json = try await listing(c)
        #expect((json["openDocs"] as? [Any])?.isEmpty == true)
    }

    /// It is a listing, not a document tool: no docId, and it never fails for want of one.
    @Test func itNeedsNoArgumentsAndNoDocument() async throws {
        let (_, port, task) = try await startServer(docIds: [])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        let (content, isError) = try await c.callTool(name: "list_open_docs", arguments: nil)

        #expect(isError != true)
        let text = content.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }.joined()
        #expect(text.contains("openDocs"))
        #expect(text.contains("devices"))
    }

    @Test func theToolIsAdvertised() async throws {
        let (_, port, task) = try await startServer(docIds: ["d"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        let (tools, _) = try await c.listTools()
        let tool = try #require(tools.first { $0.name == "list_open_docs" })
        // The description has to carry the WHY: an agent reaching for a spoken name is exactly
        // who needs to find this tool.
        let description = try #require(tool.description)
        #expect(description.contains("rename"))
        #expect(description.contains("docId"))
    }
}

#endif
