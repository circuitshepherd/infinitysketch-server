import Foundation
import Testing
@testable import InfSketchServerKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func startServer() async throws -> (InfSketchServer, UInt16, Task<Void, any Error>) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = DirectoryDocumentStore(directory: dir)
    try store.save(docId: "sample", bytes: Fixtures.docBytes)

    let server = InfSketchServer(port: 0, docsDirectory: dir)
    let task = Task { try await server.run() }
    try await server.waitUntilListening()
    let port = try #require(await server.listeningPort)
    return (server, port, task)
}

@Suite struct IntegrationTests {
    @Test func apiDocsListsDocuments() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let url = URL(string: "http://127.0.0.1:\(port)/api/docs")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let docs = try decoder.decode([DocSummary].self, from: data)
        #expect(docs.count == 1)
        #expect(docs[0].id == "sample")
        #expect(docs[0].subscriberCount == nil)  // no live session yet
        await server.stop()
    }

    @Test func frameServesStoredThumbnail() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let url = URL(string: "http://127.0.0.1:\(port)/api/docs/sample/frame")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(http.value(forHTTPHeaderField: "X-Frame-Stale") == "true")
        #expect(data == Fixtures.thumbnailPNG)

        let missing = URL(string: "http://127.0.0.1:\(port)/api/docs/ghost/frame")!
        let (_, missingResponse) = try await URLSession.shared.data(from: missing)
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)
        await server.stop()
    }

    #if canImport(Darwin)
    @Test func webSocketEndToEnd() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let ws = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        ws.resume()

        func send(_ m: ClientMessage) async throws {
            try await ws.send(.string(try m.jsonText()))
        }
        func receive() async throws -> ServerMessage {
            let frame = try await ws.receive()
            guard case .string(let text) = frame else {
                throw DocumentStoreError.notFound  // any error; wrong frame type fails the test
            }
            return try ServerMessage(jsonText: text)
        }

        try await send(.hello(protocolVersion: 1, capabilities: []))
        #expect(try await receive() == .helloAck(protocolVersion: 1))

        try await send(.subscribe(docId: "sample", fromSeq: nil))
        #expect(try await receive() == .subscribed(docId: "sample", seq: 0, snapshot: Fixtures.docBytes))

        let payload = OpPayload(type: "fullDoc", data: Fixtures.docBytes)
        try await send(.op(docId: "sample", opId: "it-1", payload: payload))
        #expect(try await receive() == .event(docId: "sample", seq: 1, kind: "op", opId: "it-1", payload: payload))

        ws.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }
    #endif
}
