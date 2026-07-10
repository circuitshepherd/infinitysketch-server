import Foundation
import Testing
@testable import InfSketchServerKit
import FlyingFox

/// Drives WSAdapter.makeMessages directly with hand-fed frames — no sockets.
private struct Harness {
    let input: AsyncStream<WSMessage>.Continuation
    let output: AsyncStream<WSMessage>
    let manager: SessionManager

    init(manager: SessionManager, config: SessionConfig = SessionConfig()) async throws {
        self.manager = manager
        let (inStream, inCont) = AsyncStream<WSMessage>.makeStream()
        self.input = inCont
        self.output = try await WSAdapter(manager: manager, config: config).makeMessages(for: inStream)
    }

    func send(_ message: ClientMessage) throws {
        input.yield(.text(try message.jsonText()))
    }

    func sendRaw(_ text: String) {
        input.yield(.text(text))
    }
}

private func makeManager() throws -> SessionManager {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ws-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = DirectoryDocumentStore(directory: dir)
    try store.save(docId: "d", bytes: Fixtures.docBytes)
    return SessionManager(store: store, config: SessionConfig())
}

/// Runs raw output frames through a client-side reassembler, so tests read
/// complete semantic messages whether or not the server chunked them.
private struct ServerMessageReader {
    var iterator: AsyncStream<WSMessage>.AsyncIterator
    var reassembler = TransferReassembler<ServerMessage>()

    init(_ output: AsyncStream<WSMessage>) { self.iterator = output.makeAsyncIterator() }

    mutating func next() async throws -> ServerMessage? {
        while let frame = await iterator.next() {
            let wire: WireFrame
            switch frame {
            case .text(let text): wire = .text(text)
            case .data(let data): wire = .binary(data)
            case .close: return nil
            }
            if let message = try reassembler.consume(wire) { return message }
        }
        return nil
    }
}

@Suite struct WSAdapterTests {
    @Test func helloHandshakeAndSubscribeAndOp() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)

        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        #expect(try await reader.next() == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))

        let payload = OpPayload(type: "fullDoc", data: Data([7]))
        try harness.send(.op(docId: "d", opId: "o1", payload: payload))
        // The echo broadcast is the ack.
        #expect(try await reader.next() == .event(docId: "d", seq: 1, kind: "op", opId: "o1", payload: payload))
    }

    @Test func messagesBeforeHelloAreRejected() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        #expect(try await reader.next() == .error(reason: "helloRequired"))
    }

    @Test func wrongProtocolVersionClosesConnection() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 99, capabilities: []))
        #expect(try await reader.next() == .error(reason: "unsupportedVersion"))
        #expect(try await reader.next() == nil)  // stream finished = connection closed
    }

    @Test func malformedJSONReportsError() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()  // helloAck
        harness.sendRaw("{nope")
        #expect(try await reader.next() == .error(reason: "malformedMessage"))
    }

    @Test func opWithoutSubscribeErrors() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.op(docId: "d", opId: "o1", payload: OpPayload(type: "fullDoc", data: Data())))
        #expect(try await reader.next() == .error(reason: "notSubscribed"))
    }

    @Test func disconnectReleasesSubscriptions() async throws {
        let manager = try makeManager()
        let harness = try await Harness(manager: manager)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        _ = try await reader.next()
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 1)

        harness.input.finish()  // client disconnects
        while try await reader.next() != nil {}  // drain until adapter closes output
        // Poll briefly for the async cleanup to land.
        for _ in 0..<50 {
            if await manager.liveInfo()["d"]?.subscriberCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 0)
    }

    @Test func clientCloseFrameClosesCleanly() async throws {
        let manager = try makeManager()
        let harness = try await Harness(manager: manager)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        _ = try await reader.next()

        harness.input.yield(.close(.normalClosure))
        // Drain: no error frame may appear; the stream must finish.
        while let message = try await reader.next() {
            if case .error(let reason) = message {
                Issue.record("unexpected error frame on clean close: \(reason)")
            }
        }
        for _ in 0..<50 {
            if await manager.liveInfo()["d"]?.subscriberCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 0)
    }

    @Test func statusSubscriptionDeliversEvents() async throws {
        let manager = try makeManager()
        let harness = try await Harness(manager: manager)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()  // helloAck
        try harness.send(.subscribeStatus)
        // Trigger the status event through the SAME connection: frames are
        // handled strictly in order, so the status subscription is registered
        // before this subscribe emits sessionOpened. (A direct manager call
        // here would race the async subscribeStatus handling.)
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        // The output interleaves the .subscribed reply with pumped statusEvents;
        // the first statusEvent must be sessionOpened (emitted before
        // subscriberCount, and the pump preserves stream order).
        var firstStatus: StatusPayload?
        for _ in 0..<5 {
            guard let message = try await reader.next() else { break }
            if case .statusEvent(let payload) = message {
                firstStatus = payload
                break
            }
        }
        let payload = try #require(firstStatus)
        #expect(payload.docId == "d")
        #expect(payload.kind == "sessionOpened")
    }
}

@Suite struct WSAdapterOutgoingTransferTests {
    /// inlineLimit far below Fixtures.docBytes.count (105 bytes) forces chunking.
    private static let tinyConfig = SessionConfig(inlineLimit: 16, chunkSize: 8)

    @Test func bigSnapshotArrivesChunkedAndReassembles() async throws {
        let harness = try await Harness(manager: try makeManager(), config: Self.tinyConfig)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()   // helloAck
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        // The reader reassembles descriptor + chunks + end back into one message.
        #expect(try await reader.next() == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))
    }

    @Test func bigSnapshotWireShapeIsDescriptorChunksEnd() async throws {
        let harness = try await Harness(manager: try makeManager(), config: Self.tinyConfig)
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = await it.next()   // helloAck text frame
        try harness.send(.subscribe(docId: "d", fromSeq: nil))

        guard case .text(let announce) = await it.next(),
              case .subscribed(_, 0, .transfer(let d)) = try ServerMessage(jsonText: announce)
        else { Issue.record("expected descriptor announce"); return }
        #expect(d.totalBytes == Fixtures.docBytes.count)
        var reassembled = Data()
        for _ in 0..<d.chunkCount {
            guard case .data(let chunkFrame) = await it.next() else { Issue.record("expected binary chunk"); return }
            reassembled.append(try ChunkFraming.decode(chunkFrame).payload)
        }
        #expect(reassembled == Fixtures.docBytes)
        guard case .text(let end) = await it.next() else { Issue.record("expected end"); return }
        #expect(try ServerMessage(jsonText: end) == .transferEnd(transferId: d.transferId))
    }

    @Test func smallSnapshotStaysInlineSingleFrame() async throws {
        // Default config: 105-byte fixture is far below the 256 KiB inline limit.
        let harness = try await Harness(manager: try makeManager())
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = await it.next()
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        guard case .text(let json) = await it.next() else { Issue.record("expected single text frame"); return }
        #expect(try ServerMessage(jsonText: json) == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))
    }

    @Test func bigEventBroadcastArrivesChunked() async throws {
        let manager = try makeManager()
        let harness = try await Harness(manager: manager, config: Self.tinyConfig)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        _ = try await reader.next()   // subscribed
        // Submit a big op directly through the manager (incoming chunks land in Task 6).
        let bigBytes = Data((0..<200).map { UInt8($0 % 256) })
        let reject = await manager.submit(docId: "d", opId: "big-1",
                                          payload: OpPayload(type: "fullDoc", data: bigBytes))
        #expect(reject == nil)
        #expect(try await reader.next() == .event(docId: "d", seq: 1, kind: "op", opId: "big-1",
                                                  payload: OpPayload(type: "fullDoc", data: bigBytes)))
    }
}
