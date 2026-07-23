import Foundation
import Testing
@testable import InfSketchServerKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InfSketchWire

private func startServer(config: SessionConfig = SessionConfig()) async throws -> (InfSketchServer, UInt16, Task<Void, any Error>) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = DirectoryDocumentStore(directory: dir)
    try store.save(docId: "sample", bytes: Fixtures.docBytes)

    let server = InfSketchServer(port: 0, docsDirectory: dir, config: config)
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

    @Test func rootServesOverviewPage() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let html = String(decoding: data, as: UTF8.self)
        #expect(html.contains("infsketch-server"))
        #expect(html.contains("/api/docs"))
        await server.stop()
    }

    @Test func docPageAndFrameHeaders() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        // Doc page serves for a percent-encoded id.
        let page = URL(string: "http://127.0.0.1:\(port)/doc/sample")!
        let (pageData, pageResponse) = try await URLSession.shared.data(from: page)
        #expect((pageResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: pageData, as: UTF8.self).contains("watchDoc"))

        // No live frame yet: fallback thumbnail, marked stale.
        let frameURL = URL(string: "http://127.0.0.1:\(port)/api/docs/sample/frame")!
        let (_, staleResponse) = try await URLSession.shared.data(from: frameURL)
        #expect((staleResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Frame-Stale") == "true")

        // Submit a frame through the manager; the route now serves it live.
        _ = try await server.manager.subscribe(docId: "sample")
        #expect(await server.manager.submitFrame(docId: "sample", bytes: Fixtures.thumbnailPNG))
        let (liveData, liveResponse) = try await URLSession.shared.data(from: frameURL)
        let http = try #require(liveResponse as? HTTPURLResponse)
        #expect(http.value(forHTTPHeaderField: "X-Frame-Stale") == "false")
        #expect(http.value(forHTTPHeaderField: "X-Frame-Seq") == "0")
        #expect(liveData == Fixtures.thumbnailPNG)
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

        try await send(.hello(protocolVersion: 1, capabilities: [], deviceId: nil))
        #expect(try await receive() == .helloAck(protocolVersion: 1))

        try await send(.subscribe(docId: "sample", fromSeq: nil, createIfMissing: false))
        #expect(try await receive() == .subscribed(docId: "sample", seq: 0, snapshot: .inline(Fixtures.docBytes)))

        let payload = OpPayload(type: "fullDoc", data: Fixtures.docBytes)
        try await send(.op(docId: "sample", opId: "it-1", payload: payload))
        #expect(try await receive() == .event(docId: "sample", seq: 1, kind: "op", opId: "it-1", payload: payload))

        ws.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }

    @Test func chunkedTransferEndToEnd() async throws {
        // Tiny inline limit forces chunking for a ~100 KB doc; chunk fits
        // far under URLSession's default 1 MiB message cap.
        let (server, port, task) = try await startServer(
            config: SessionConfig(inlineLimit: 1024, chunkSize: 4096))
        defer { task.cancel() }

        let bigBytes = Data((0..<100_000).map { UInt8($0 % 256) })

        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        ws.resume()

        var sender = TransferSender<ClientMessage>(inlineLimit: 1024, chunkSize: 4096)
        var reassembler = TransferReassembler<ServerMessage>()
        func send(_ m: ClientMessage) async throws {
            for frame in try sender.frames(for: m) {
                switch frame {
                case .text(let text): try await ws.send(.string(text))
                case .binary(let data): try await ws.send(.data(data))
                }
            }
        }
        func receive() async throws -> ServerMessage {
            while true {
                let wire: WireFrame
                switch try await ws.receive() {
                case .string(let text): wire = .text(text)
                case .data(let data): wire = .binary(data)
                @unknown default: continue
                }
                if let m = try reassembler.consume(wire) { return m }
            }
        }

        try await send(.hello(protocolVersion: 1, capabilities: [], deviceId: nil))
        #expect(try await receive() == .helloAck(protocolVersion: 1))
        try await send(.subscribe(docId: "sample", fromSeq: nil, createIfMissing: false))
        #expect(try await receive() == .subscribed(docId: "sample", seq: 0, snapshot: .inline(Fixtures.docBytes)))

        // Push a ~100 KB op up (chunked), get the echo back (chunked): both
        // directions cross real sockets with messages ≤ 4 KB + header.
        let payload = OpPayload(type: "fullDoc", data: bigBytes)
        try await send(.op(docId: "sample", opId: "chunky-1", payload: payload))
        #expect(try await receive() == .event(docId: "sample", seq: 1, kind: "op", opId: "chunky-1", payload: payload))

        ws.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }

    /// Task 3 (agent stroke-authoring branch): the OUTBOUND direction of
    /// chunked transfer — server → device — driven by
    /// `DeviceCommandBroker.requestStrokeOp` (not by anything the client
    /// itself sends first, unlike every other chunking test above). This
    /// locks the `ServerMessage.strokeOpRequest` `TransferCarrying` arms
    /// end-to-end over a real socket: a small `inlineLimit` forces the
    /// server to chunk the doc bytes handed to `requestStrokeOp`, and the
    /// fake device (a real `URLSessionWebSocketTask`, hello'd with
    /// `authorStrokes`) must see EXACTLY descriptor → N binary chunks →
    /// transferEnd, reassembling to the exact bytes with `spec` intact
    /// (spec is a plain `Data` field, never itself chunked).
    @Test func strokeOpRequestArrivesChunkedOverRealSocketAndReassembles() async throws {
        let (server, port, task) = try await startServer(
            config: SessionConfig(inlineLimit: 1024, chunkSize: 4096))
        defer { task.cancel() }

        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        ws.resume()

        func send(_ m: ClientMessage) async throws {
            try await ws.send(.string(try m.jsonText()))
        }
        func receiveFrame() async throws -> WireFrame {
            while true {
                switch try await ws.receive() {
                case .string(let text): return .text(text)
                case .data(let data): return .binary(data)
                @unknown default: continue
                }
            }
        }

        // Fake device: hellos with authorStrokes so WSAdapter registers it
        // with the server's real DeviceCommandBroker (the same instance the
        // future stroke-authoring MCP tool, Task 4, will call into).
        try await send(.hello(protocolVersion: 1, capabilities: ["authorStrokes"], deviceId: nil))
        guard case .text(let ackText) = try await receiveFrame(),
              try ServerMessage(jsonText: ackText) == .helloAck(protocolVersion: 1)
        else { Issue.record("expected helloAck"); return }

        let bigBytes = Data((0..<100_000).map { UInt8($0 % 256) })
        let spec = Data("stroke-spec".utf8)
        let requestTask = Task {
            try await server.deviceCommandBroker.requestStrokeOp(docId: "sample", docBytes: bigBytes, spec: spec)
        }

        // Frame 1: the descriptor announce (spec travels inline on this very
        // frame — it is never chunked, only the doc-bytes bulk field is).
        guard case .text(let announce) = try await receiveFrame(),
              case .strokeOpRequest(let requestId, "sample", .transfer(let d), let announcedSpec)
                = try ServerMessage(jsonText: announce)
        else { Issue.record("expected strokeOpRequest descriptor"); return }
        #expect(d.totalBytes == bigBytes.count)
        #expect(announcedSpec == spec)

        // Frames 2...N+1: exactly d.chunkCount binary chunks, in order. Fed
        // into a client-side TransferReassembler as they arrive, alongside
        // the raw-decode check, so this one pass both locks the wire SHAPE
        // (descriptor, then exactly chunkCount binaries, then end) and
        // proves semantic reassembly.
        var reassembler = TransferReassembler<ServerMessage>()
        #expect(try reassembler.consume(.text(announce)) == nil)
        var reassembledBytes = Data()
        for _ in 0..<d.chunkCount {
            guard case .binary(let chunkFrame) = try await receiveFrame() else {
                Issue.record("expected binary chunk"); return
            }
            reassembledBytes.append(try ChunkFraming.decode(chunkFrame).payload)
            #expect(try reassembler.consume(.binary(chunkFrame)) == nil)
        }
        #expect(reassembledBytes == bigBytes)

        // Final frame: transferEnd for this exact transferId — the
        // reassembler resolves the complete semantic message right here.
        guard case .text(let endText) = try await receiveFrame() else {
            Issue.record("expected transferEnd"); return
        }
        #expect(try ServerMessage(jsonText: endText) == .transferEnd(transferId: d.transferId))
        let resolved = try reassembler.consume(.text(endText))
        guard case .strokeOpRequest(let resolvedRequestId, "sample", .inline(let resolvedBytes), let resolvedSpec) = resolved
        else { Issue.record("expected resolved strokeOpRequest"); return }
        #expect(resolvedRequestId == requestId)
        #expect(resolvedBytes == bigBytes)
        #expect(resolvedSpec == spec)

        // Reply so the pending broker call resolves cleanly (no leaked Task).
        try await send(.strokeOpReply(
            requestId: requestId, docId: "sample",
            payload: .inline(Data("ok".utf8)), meta: nil, failureReason: nil))
        #expect(try await requestTask.value.bytes == Data("ok".utf8))

        ws.cancel(with: .normalClosure, reason: nil)
        await server.stop()
    }
    #endif

    @Test func percentNamedDocServesPageAndFrame() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        // A document whose name contains a literal percent — the regression case
        // for double-decoding (FlyingFox already decodes the path once).
        _ = try await server.manager.subscribe(docId: "50%off", createIfMissing: true)
        #expect(await server.manager.submitFrame(docId: "50%off", bytes: Fixtures.thumbnailPNG))
        let frameURL = URL(string: "http://127.0.0.1:\(port)/api/docs/50%25off/frame")!
        let (data, response) = try await URLSession.shared.data(from: frameURL)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Frame-Stale") == "false")
        #expect(data == Fixtures.thumbnailPNG)
        let page = URL(string: "http://127.0.0.1:\(port)/doc/50%25off")!
        let (pageData, pageResponse) = try await URLSession.shared.data(from: page)
        #expect((pageResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: pageData, as: UTF8.self).contains(#""50%off""#))
        await server.stop()
    }

    @Test func headRequestsMatchGetHeaders() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        var head = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/docs/sample/frame")!)
        head.httpMethod = "HEAD"
        let (body, response) = try await URLSession.shared.data(for: head)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "X-Frame-Stale") == "true")
        #expect(body.isEmpty)
        await server.stop()
    }
}
