import Foundation
import Testing
import InfSketchWire
import FlyingFox
@testable import InfSketchServerKit

/// Wire v12: the server names its instance, an oversized op-spec rides the chunked payload, and a
/// device's frame can say which seq it rendered.
@Suite struct WireV12Tests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wire-v12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: serverId

    /// The id is what a device keys its lineage by, so it must survive a restart of the same
    /// documents directory — and must never be listed as a document.
    @Test func aDocumentsDirectoryKeepsItsServerIdAcrossRestarts() throws {
        let dir = try temporaryDirectory()
        let first = SessionManager(store: DirectoryDocumentStore(directory: dir)).serverId
        let second = SessionManager(store: DirectoryDocumentStore(directory: dir)).serverId
        #expect(!first.isEmpty)
        #expect(first == second)
        #expect(try DirectoryDocumentStore(directory: dir).list().isEmpty,
                "the id file must never surface as a document")
    }

    @Test func twoDocumentsDirectoriesAreTwoServers() throws {
        let a = SessionManager(store: DirectoryDocumentStore(directory: try temporaryDirectory())).serverId
        let b = SessionManager(store: DirectoryDocumentStore(directory: try temporaryDirectory())).serverId
        #expect(a != b)
    }

    @Test func helloAckRoundTripsItsServerId() throws {
        let ack = ServerMessage.helloAck(protocolVersion: WireProtocol.version, serverId: "abc")
        #expect(try ServerMessage(jsonText: ack.jsonText()) == ack)
    }

    /// The server's clock rides `helloAck` and every `ping` (round 5, item 10), so a device can
    /// judge a request's `notAfter` by the clock that wrote it. Optional both ways.
    @Test func helloAckAndPingCarryTheServersClock() throws {
        let ack = ServerMessage.helloAck(protocolVersion: WireProtocol.version, serverId: "abc",
                                         serverTimeMs: 1_790_000_000_123)
        #expect(try ServerMessage(jsonText: ack.jsonText()) == ack)
        let ping = ServerMessage.ping(serverTimeMs: 42)
        #expect(try ServerMessage(jsonText: ping.jsonText()) == ping)
        #expect(try ServerMessage(jsonText: #"{"type":"ping"}"#) == .ping(serverTimeMs: nil))
        #expect(try ServerMessage(jsonText: #"{"type":"helloAck","protocolVersion":12,"serverId":"x"}"#)
                == .helloAck(protocolVersion: 12, serverId: "x", serverTimeMs: nil))
    }

    /// The server actually SENDS its clock, on the hello and on a keepalive ping.
    @Test func theServerSendsItsClockOnHello() async throws {
        let before = WSAdapter.nowMs()
        let manager = SessionManager(store: DirectoryDocumentStore(directory: try temporaryDirectory()))
        let adapter = WSAdapter(manager: manager, broker: DeviceCommandBroker())
        let (input, cont) = AsyncStream<WSMessage>.makeStream()
        let output = try await adapter.makeMessages(for: input)
        cont.yield(.text(try ClientMessage.hello(protocolVersion: WireProtocol.version, capabilities: [],
                                                 deviceId: nil).jsonText()))
        var ack: ServerMessage?
        for await message in output {
            if case .text(let text) = message { ack = try ServerMessage(jsonText: text); break }
        }
        cont.finish()
        guard case .helloAck(_, _, let serverTimeMs?)? = ack else {
            Issue.record("expected a helloAck carrying the server's clock, got \(String(describing: ack))"); return
        }
        #expect(serverTimeMs >= before && serverTimeMs <= WSAdapter.nowMs())
    }

    // MARK: op-spec as a bundle part

    /// A spec bigger than `inlineSpecLimit` must not ride the text frame: the review measured a
    /// `reshape_strokes` of ~6000 full-attribute points at 1.1 MB, past the app's 1 MiB receive
    /// limit, which drops the connection. It goes into the chunked payload instead, and the
    /// device-side splice restores it byte for byte.
    @Test func aLargeSpecTravelsInThePayloadAndIsRestoredExactly() async throws {
        let broker = DeviceCommandBroker()
        let box = MessageBox()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in
            Task { await box.add(msg) }
        }
        let points = (0..<6000).map { i in
            ["x": Double(i) * 1.25, "y": Double(i) * 0.5, "force": 0.5, "altitude": 1.2,
             "azimuth": 0.3, "opacity": 1.0, "timeOffset": Double(i) / 240, "stampSize": 4.0]
        }
        let spec = try JSONSerialization.data(withJSONObject: [
            "op": "reshape", "items": [["id": "k", "canvasPoints": points]]])
        #expect(spec.count > OpSpecBundleWire.inlineSpecLimit)
        let doc = Data("{\"doc\":true}".utf8)
        let task = Task { try await broker.requestStrokeOp(docId: "D", docBytes: doc, spec: spec) }
        let message = try #require(await box.first())
        guard case .strokeOpRequest(let rid, "D", .inline(let payload), let inlineSpec, let kind, _) = message else {
            Issue.record("expected a strokeOpRequest, got \(message)"); return
        }
        #expect(kind == OpSpecBundleWire.kind)
        #expect(inlineSpec.count < 16, "the text frame carries a placeholder, not the spec")
        // Through the server's own sender, every TEXT frame now stays far under the 1 MiB a
        // URLSessionWebSocketTask accepts — the bulk goes as binary chunks.
        let config = SessionConfig()
        var sender = TransferSender<ServerMessage>(inlineLimit: config.inlineLimit, chunkSize: config.chunkSize)
        for frame in try sender.frames(for: message) {
            if case .text(let text) = frame { #expect(text.utf8.count < 64 * 1024) }
        }

        // What the device does: unwrap, splice, and get the original spec and document back.
        let bundle = try OpSpecBundle(encoded: payload)
        #expect(bundle.primary == doc)
        #expect(try bundle.specRestoringParts(into: inlineSpec) == spec)

        await broker.handleReply(requestId: rid, bytes: Data("ok".utf8), failureReason: nil)
        #expect(try await task.value.bytes == Data("ok".utf8))
    }

    /// A small spec is unchanged on the wire — the common request pays nothing.
    @Test func aSmallSpecStaysInline() async throws {
        let broker = DeviceCommandBroker()
        let box = MessageBox()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in
            Task { await box.add(msg) }
        }
        let spec = Data("{\"op\":\"list\"}".utf8)
        let task = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data([1]), spec: spec) }
        let message = try #require(await box.first())
        guard case .strokeOpRequest(let rid, _, _, let inlineSpec, let kind, _) = message else {
            Issue.record("expected a strokeOpRequest"); return
        }
        #expect(inlineSpec == spec)
        #expect(kind == nil)
        await broker.handleReply(requestId: rid, bytes: Data(), failureReason: nil)
        _ = try await task.value
    }

    /// The spec part and the ordinary bulk parts compose: the spec is restored first, then the
    /// document fields are spliced into it.
    @Test func aSpecPartComposesWithBulkParts() throws {
        let spec = Data("{\"op\":\"copyElements\",\"strokeIds\":[\"a\"]}".utf8)
        let bundle = OpSpecBundle(primary: Data([1]), primaryKind: nil,
                                  parts: [.spec: spec, .source: Data([9, 9])])
        let decoded = try OpSpecBundle(encoded: bundle.encoded())
        let restored = try decoded.specRestoringParts(into: Data("{}".utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: restored) as? [String: Any])
        #expect(object["op"] as? String == "copyElements")
        #expect(object["source"] as? String == Data([9, 9]).base64EncodedString())
    }

    // MARK: device disconnect

    /// A pure op whose device disconnects fails over once, like a timeout — a device that went
    /// away is not an answer.
    @Test func aDisconnectFailsOverToAnotherDevice() async throws {
        let broker = DeviceCommandBroker()
        let first = MessageBox()
        let second = MessageBox()
        let firstId = UUID()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in
            Task { await second.add(msg) }
        }
        await broker.register(connectionId: firstId, capabilities: ["authorStrokes"]) { msg in
            Task { await first.add(msg) }
        }
        let task = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data([1]), spec: Data("{}".utf8)) }
        _ = try #require(await first.first())
        await broker.unregister(connectionId: firstId)
        guard case .strokeOpRequest(let rid, _, _, _, _, _)? = await second.first() else {
            Issue.record("the op must be retried on the remaining device"); return
        }
        await broker.handleReply(requestId: rid, bytes: Data("ok".utf8), failureReason: nil)
        #expect(try await task.value.bytes == Data("ok".utf8))
    }

    // MARK: frame seq

    @Test func aFrameIsStampedWithTheSeqItWasRenderedFrom() async throws {
        let dir = try temporaryDirectory()
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        let manager = SessionManager(store: store)
        _ = try await manager.subscribe(docId: "d")
        for i in 0..<3 {
            _ = await manager.submit(docId: "d", opId: "o\(i)",
                                     payload: OpPayload(type: "fullDoc", data: Fixtures.docBytes))
        }
        #expect(await manager.submitFrame(docId: "d", bytes: Data([1]), canvasRect: nil, atSeq: 1))
        #expect(await manager.latestFrame(docId: "d")?.seq == 1)
        #expect(await manager.submitFrame(docId: "d", bytes: Data([2]), canvasRect: nil))
        #expect(await manager.latestFrame(docId: "d")?.seq == 3, "no seq given: the arrival seq")
    }

    @Test func aFrameSeqRoundTripsAndSurvivesChunking() throws {
        let png = Data((0..<100).map { UInt8($0) })
        var sender = TransferSender<ClientMessage>(inlineLimit: 16, chunkSize: 8)
        var reassembler = TransferReassembler<ClientMessage>()
        var results: [ClientMessage] = []
        let frame = ClientMessage.frame(docId: "d", payload: .inline(png), canvasRect: nil, seq: 7)
        for f in try sender.frames(for: frame) {
            if let m = try reassembler.consume(f) { results.append(m) }
        }
        #expect(results == [frame])
    }
}

private actor MessageBox {
    private var messages: [ServerMessage] = []
    func add(_ m: ServerMessage) { messages.append(m) }
    func first() async -> ServerMessage? {
        for _ in 0..<200 {
            if let m = messages.first { return m }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return messages.first
    }
}
