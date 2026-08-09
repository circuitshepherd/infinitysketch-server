// Apple-platforms-only for the same reason as MCPAdapterTests: the SDK's HTTPClientTransport has
// no SSE without `EventSource`, so its Client cannot complete `initialize` there. Flag defined in
// Package.swift.
#if MCP_SSE_CLIENT

import Foundation
import Testing
@testable import InfSketchServerKit
import MCP

/// Errors that name only a SYMPTOM get the context that makes them actionable
/// (spec 2026-07-27-actionable-tool-errors-design.md).
///
/// The failure this exists for: a document renamed while open keeps the mirror `docId` it was
/// registered under, so an agent aiming at the name the user now sees is told `noSelectionActive`
/// with no way to learn that `grok2 test` and `Untitled 16 1 1` are the same open document.
///
/// The other half of the contract matters as much: every OTHER error, and every success, must
/// come back byte-identical. A blanket rewrite of tool output would be far worse than the dead
/// end it replaces.
@Suite(.serialized)
struct ErrorContextTests {

    private func startServer(docIds: [String]) async throws
        -> (InfSketchServer, UInt16, Task<Void, any Error>) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("err-ctx-\(UUID().uuidString)", isDirectory: true)
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
        let c = Client(name: "err-ctx", version: "1")
        try await c.connect(transport: HTTPClientTransport(
            endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!,
            streaming: false))
        return c
    }

    private func text(_ content: [Tool.Content]) -> String {
        content.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }.joined()
    }

    @Test func anUnknownDocumentNamesTheOnesThatExist() async throws {
        let (_, port, task) = try await startServer(docIds: ["Example A", "Example B"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        let (content, isError) = try await c.callTool(
            name: "set_paper", arguments: ["docId": "grok2 test", "light": "#FFEEC0"])

        #expect(isError == true)
        let t = text(content)
        #expect(t.contains("unknownDoc"))            // the machine-readable reason survives
        #expect(t.contains("grok2 test"))            // what was asked for
        #expect(t.contains("Example A"))             // …and what exists instead
        #expect(t.contains("Example B"))
    }

    /// A store with dozens of documents must not answer a mistyped name with a wall of text.
    @Test func theDocumentListIsCapped() async throws {
        let ids = (1...30).map { "Doc \($0)" }
        let (_, port, task) = try await startServer(docIds: ids)
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        let (content, _) = try await c.callTool(
            name: "set_paper", arguments: ["docId": "nope", "light": "#FFEEC0"])

        let t = text(content)
        #expect(t.contains("more)"))                 // the overflow is acknowledged, not hidden
        #expect(t.count < 600)                       // and it stays readable
    }

    /// With no device connected at all, a live-selection tool fails `noDeviceAvailable` — not
    /// `noSelectionActive`, which is what I assumed until this test said otherwise. Saying WHICH
    /// of the two it is, and what to do, is the whole point: "no device is connected" and "a
    /// device is connected but cannot do this" have different fixes.
    @Test func noDeviceAvailableSaysThatNothingIsConnected() async throws {
        let (_, port, task) = try await startServer(docIds: ["d"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        let (content, isError) = try await c.callTool(name: "get_selection", arguments: ["docId": "d"])

        #expect(isError == true)
        let t = text(content)
        #expect(t.contains("noDeviceAvailable"))     // the machine-readable reason survives
        #expect(t.contains("no device is connected"))
        #expect(t.contains("mirror"))                // …and how to fix it
    }

    // NOT covered here, honestly: the `noSelectionActive` clause that names the live session —
    // the rename scenario this work exists for. Producing it needs a CONNECTED device with an
    // open document, which this suite has no way to fake (the broker's registration is a live WS
    // connection). It is exercised on the simulator instead; the clause itself is three lines
    // over `manager.liveInfo()`.

    /// The contract's other half: an unrelated error is passed through verbatim.
    @Test func anUnrelatedErrorIsUntouched() async throws {
        let (_, port, task) = try await startServer(docIds: ["d"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        // `set_paper` with no fields is `invalidArguments`, nothing to do with names or sessions.
        let (content, isError) = try await c.callTool(name: "set_paper", arguments: ["docId": "d"])

        #expect(isError == true)
        let t = text(content)
        #expect(!t.contains("Documents:"))
        #expect(!t.contains("open on a connected device"))
    }

    /// …and a SUCCESS is untouched. Tool output is parsed by agents; the shapes other tests pin
    /// ("added <id> at seq <n>") must not acquire a suffix.
    @Test func aSuccessfulResultIsUntouched() async throws {
        let (_, port, task) = try await startServer(docIds: ["d"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }

        let (content, isError) = try await c.callTool(
            name: "add_text", arguments: ["docId": "d", "text": "hi", "canvasX": 10, "canvasY": 20])

        #expect(isError != true)
        let t = text(content)
        #expect(t.hasPrefix("added "))
        #expect(!t.contains("Documents:"))
    }
}

#endif
