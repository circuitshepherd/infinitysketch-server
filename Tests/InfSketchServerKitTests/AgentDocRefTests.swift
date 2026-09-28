// Apple-platforms-only for the same reason as MCPAdapterTests: the SDK's HTTPClientTransport has
// no SSE without `EventSource`, so its Client cannot complete `initialize` there. Flag defined in
// Package.swift.
#if MCP_SSE_CLIENT
import Foundation
import Testing
@testable import InfSketchServerKit
import MCP
import InfSketchWire

/// A document is its id; its name is a label (spec 2026-09-28 §4). Every tool argument that names
/// a document takes the id or a name no other document carries — a shared name is refused with
/// the ids to choose from, never guessed.
@Suite(.serialized)
struct AgentDocRefTests {
    /// `labelled`: id → name.
    private func startServer(labelled: [String: String]) async throws
        -> (InfSketchServer, UInt16, Task<Void, any Error>, DirectoryDocumentStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-ref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        for (id, name) in labelled {
            try store.save(docId: id, bytes: Fixtures.docBytes)
            try store.setName(name, for: id)
        }
        let server = InfSketchServer(port: 0, docsDirectory: dir)
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        return (server, port, task, DirectoryDocumentStore(directory: dir))
    }

    private func client(_ port: UInt16) async throws -> Client {
        let c = Client(name: "doc-ref", version: "1")
        try await c.connect(transport: HTTPClientTransport(
            endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: false))
        return c
    }

    private func text(_ content: [Tool.Content]) -> String {
        content.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }.joined()
    }

    private func json(_ content: [Tool.Content]) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [String: Any]
    }

    /// Two documents called "Chart": a name reference must refuse rather than guess.
    @Test func aSharedNameIsRefusedWithTheCandidates() async throws {
        let (_, port, task, store) = try await startServer(labelled: ["A-1": "Chart", "B-2": "Chart"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let (content, isError) = try await c.callTool(name: "delete_doc", arguments: ["docId": "Chart"])
        #expect(isError == true)
        #expect(text(content).hasPrefix("ambiguousName: \"Chart\" names 2 documents"))
        #expect(text(content).contains("A-1") && text(content).contains("B-2"))
        #expect(try store.exists(docId: "A-1") && store.exists(docId: "B-2"))
    }

    @Test func aUniqueNameReachesItsDocument() async throws {
        let (_, port, task, store) = try await startServer(labelled: ["A-1": "Chart"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let (_, isError) = try await c.callTool(name: "delete_doc", arguments: ["docId": "Chart"])
        #expect(isError != true)
        #expect(try store.exists(docId: "A-1") == false)
    }

    /// `source` and `target` resolve too, not only `docId`.
    @Test func mergeSourceAndTargetResolveByName() async throws {
        let (_, port, task, _) = try await startServer(labelled: ["A-1": "Chart", "B-2": "Chart", "C-3": "Other"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let (content, isError) = try await c.callTool(
            name: "merge_docs", arguments: ["source": "Other", "target": "Chart"])
        #expect(isError == true)
        #expect(text(content).hasPrefix("ambiguousName: \"Chart\""))
    }

    @Test func listDocsCarriesNames() async throws {
        let (_, port, task, _) = try await startServer(labelled: ["A-1": "Chart"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let (content, _) = try await c.callTool(name: "list_docs", arguments: [:])
        let rows = try JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [[String: Any]]
        #expect(rows?.first?["name"] as? String == "Chart")
        #expect(rows?.first?["id"] as? String == "A-1")
    }

    /// `replace_doc` of a reference nothing carries creates a NEW document labelled with it.
    @Test func replacingAnUnknownRefCreatesALabelledDocument() async throws {
        let (_, port, task, store) = try await startServer(labelled: [:])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let (content, isError) = try await c.callTool(
            name: "replace_doc",
            arguments: ["docId": "Fresh", "bytes": .string(Fixtures.docBytes.base64EncodedString())])
        #expect(isError != true)
        let created = try store.list().first { $0.name == "Fresh" }
        #expect(created != nil && created?.docId != "Fresh")
        #expect(json(content)?["docId"] as? String == created?.docId)
        #expect(json(content)?["name"] as? String == "Fresh")
        #expect(json(content)?["seq"] as? Int == 1)
        // The bytes carry the new document's own identity.
        let stored = try store.load(docId: try #require(created?.docId))
        #expect(DocumentIdentity.documentId(of: stored) == created?.docId)
    }

    /// `replace_doc` of a NAME replaces that document and keeps its id.
    @Test func replacingANamedDocumentKeepsItsId() async throws {
        let (_, port, task, store) = try await startServer(labelled: ["A-1": "Chart"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let fresh = Data(#"{"aaa001_thumbnailData":"","marker":"new"}"#.utf8)
        let (content, isError) = try await c.callTool(
            name: "replace_doc", arguments: ["docId": "Chart", "bytes": .string(fresh.base64EncodedString())])
        #expect(isError != true)
        #expect(text(content).contains("replaced A-1"))
        #expect(try store.list().map(\.docId) == ["A-1"])
        let stored = try store.load(docId: "A-1")
        #expect(String(decoding: stored, as: UTF8.self).contains("\"marker\":\"new\""))
        // A legacy stored document gains its id.
        #expect(DocumentIdentity.documentId(of: stored) == "A-1")
    }

    @Test func createDocRefusesTheOldArgumentName() async throws {
        let (_, port, task, _) = try await startServer(labelled: [:])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let (content, isError) = try await c.callTool(name: "create_doc", arguments: ["docId": "X"])
        #expect(isError == true)
        #expect(text(content).hasPrefix("invalidArgument: docId"))
    }

    @Test func createDocMintsAnIdAndLabelsIt() async throws {
        let (_, port, task, store) = try await startServer(labelled: [:])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: Fixtures.docBytes)
        defer { Task { await device.close() } }

        let (content, isError) = try await c.callTool(name: "create_doc", arguments: ["name": "Plan"])
        #expect(isError != true)
        let reply = try #require(json(content))
        let id = try #require(reply["docId"] as? String)
        #expect(id != "Plan")
        #expect(reply["name"] as? String == "Plan")
        #expect(reply["seq"] as? Int == 1)
        #expect(store.name(of: id) == "Plan")
        #expect(DocumentIdentity.documentId(of: try store.load(docId: id)) == id)
        // …and the name now reaches it.
        let (_, fetchError) = try await c.callTool(name: "fetch_doc", arguments: ["docId": "Plan"])
        #expect(fetchError != true)
    }

    /// Controller ruling F13: a name ANY document already has is refused, naming its id — before
    /// any device is woken.
    @Test func createDocRefusesAUniqueExistingName() async throws {
        let (_, port, task, _) = try await startServer(labelled: ["A-1": "Chart"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: Fixtures.docBytes)
        defer { Task { await device.close() } }

        let (content, isError) = try await c.callTool(name: "create_doc", arguments: ["name": "Chart"])
        #expect(isError == true)
        #expect(text(content) == "docExists: \"Chart\" is document A-1")
        #expect(await device.receivedRequests.isEmpty)
    }

    /// …including a name two documents already share: a third would only deepen the ambiguity.
    @Test func createDocRefusesASharedExistingNameNamingEveryId() async throws {
        let (_, port, task, _) = try await startServer(labelled: ["A-1": "Chart", "B-2": "Chart"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: Fixtures.docBytes)
        defer { Task { await device.close() } }

        let (content, isError) = try await c.callTool(name: "create_doc", arguments: ["name": "Chart"])
        #expect(isError == true)
        #expect(text(content).hasPrefix("docExists: \"Chart\" is documents "))
        #expect(text(content).contains("A-1") && text(content).contains("B-2"))
        #expect(await device.receivedRequests.isEmpty)
    }

    /// Controller ruling F13: the label is written only AFTER the create was accepted. A create
    /// the store refuses (here: the minted id collides with a stored document, so the `.absent`
    /// guard rejects it) must leave no label behind — and must not relabel the document it hit.
    @Test func aRejectedCreateLeavesNoLabel() async throws {
        let (server, port, task, store) = try await startServer(labelled: ["COLLIDE": "Other"])
        defer { task.cancel() }
        await server.mcpAdapter.setDocumentIdMinterForTesting { "COLLIDE" }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: Fixtures.docBytes)
        defer { Task { await device.close() } }

        let (content, isError) = try await c.callTool(name: "create_doc", arguments: ["name": "NewName"])
        #expect(isError == true)
        #expect(text(content).hasPrefix("docExists"))
        #expect(store.name(of: "COLLIDE") == "Other")
        #expect(try store.list().contains { $0.name == "NewName" } == false)
    }

    @Test func mergeIntoAnExistingNameIsRefused() async throws {
        let (_, port, task, _) = try await startServer(
            labelled: ["A-1": "Chart", "B-2": "Other", "C-3": "Taken"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let (content, isError) = try await c.callTool(
            name: "merge_docs", arguments: ["source": "Chart", "target": "Other", "into": "Taken"])
        #expect(isError == true)
        #expect(text(content) == "docExists: \"Taken\" is document C-3")
    }

    @Test func anUnknownDocumentListsNamesAndIds() async throws {
        let (_, port, task, _) = try await startServer(labelled: ["A-1": "Chart"])
        defer { task.cancel() }
        let c = try await client(port); defer { Task { await c.disconnect() } }
        let (content, _) = try await c.callTool(name: "set_paper", arguments: ["docId": "nope", "light": "#FFEEC0"])
        #expect(text(content).contains("\"Chart\" (A-1)"))
    }
}
#endif
