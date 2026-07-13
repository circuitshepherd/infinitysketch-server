import Foundation
import Testing
@testable import InfSketchServerKit
import FlyingFox
import InfSketchWire

/// Drives WSAdapter.makeMessages directly with hand-fed frames — no sockets.
private struct Harness {
    let input: AsyncStream<WSMessage>.Continuation
    let output: AsyncStream<WSMessage>
    let manager: SessionManager
    let broker: DeviceCommandBroker

    init(
        manager: SessionManager, config: SessionConfig = SessionConfig(),
        broker: DeviceCommandBroker = DeviceCommandBroker()
    ) async throws {
        self.manager = manager
        self.broker = broker
        let (inStream, inCont) = AsyncStream<WSMessage>.makeStream()
        self.input = inCont
        self.output = try await WSAdapter(manager: manager, config: config, broker: broker)
            .makeMessages(for: inStream)
    }

    func send(_ message: ClientMessage) throws {
        input.yield(.text(try message.jsonText()))
    }

    func sendRaw(_ text: String) {
        input.yield(.text(text))
    }

    /// Sends a client message through sender-side chunk expansion (like the demo client will).
    func sendChunked(_ message: ClientMessage, inlineLimit: Int, chunkSize: Int) throws {
        var sender = TransferSender<ClientMessage>(inlineLimit: inlineLimit, chunkSize: chunkSize)
        for frame in try sender.frames(for: message) {
            switch frame {
            case .text(let text): input.yield(.text(text))
            case .binary(let data): input.yield(.data(data))
            }
        }
    }

    func sendBinary(_ data: Data) {
        input.yield(.data(data))
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

        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        #expect(try await reader.next() == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))

        let payload = OpPayload(type: "fullDoc", data: Data([7]))
        try harness.send(.op(docId: "d", opId: "o1", payload: payload))
        // The echo broadcast is the ack.
        #expect(try await reader.next() == .event(docId: "d", seq: 1, kind: "op", opId: "o1", payload: payload))
    }

    @Test func messagesBeforeHelloAreRejected() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
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
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
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
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
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
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
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
    /// inlineLimit far below Fixtures.docBytes.count (136 bytes) forces chunking.
    private static let tinyConfig = SessionConfig(inlineLimit: 16, chunkSize: 8)

    @Test func bigSnapshotArrivesChunkedAndReassembles() async throws {
        let harness = try await Harness(manager: try makeManager(), config: Self.tinyConfig)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()   // helloAck
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        // The reader reassembles descriptor + chunks + end back into one message.
        #expect(try await reader.next() == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))
    }

    @Test func bigSnapshotWireShapeIsDescriptorChunksEnd() async throws {
        let harness = try await Harness(manager: try makeManager(), config: Self.tinyConfig)
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = await it.next()   // helloAck text frame
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))

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
        // Default config: 136-byte fixture is far below the 256 KiB inline limit.
        let harness = try await Harness(manager: try makeManager())
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = await it.next()
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        guard case .text(let json) = await it.next() else { Issue.record("expected single text frame"); return }
        #expect(try ServerMessage(jsonText: json) == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))
    }

    @Test func bigEventBroadcastArrivesChunked() async throws {
        let manager = try makeManager()
        let harness = try await Harness(manager: manager, config: Self.tinyConfig)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        _ = try await reader.next()   // subscribed
        // Submit a big op directly through the manager (incoming chunks land in Task 6).
        let bigBytes = Data((0..<200).map { UInt8($0 % 256) })
        let outcome = await manager.submit(docId: "d", opId: "big-1",
                                           payload: OpPayload(type: "fullDoc", data: bigBytes))
        #expect(outcome == .accepted(seq: 1))
        #expect(try await reader.next() == .event(docId: "d", seq: 1, kind: "op", opId: "big-1",
                                                  payload: OpPayload(type: "fullDoc", data: bigBytes)))
    }
}

@Suite struct WSAdapterIncomingTransferTests {
    private func subscribedHarness() async throws -> (Harness, ServerMessageReader, SessionManager) {
        let manager = try makeManager()
        let harness = try await Harness(manager: manager)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()   // helloAck
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        _ = try await reader.next()   // subscribed
        return (harness, reader, manager)
    }

    @Test func chunkedOpIsReassembledAppliedAndEchoed() async throws {
        var (harness, reader, manager) = try await subscribedHarness()
        let bigBytes = Data((0..<100).map { UInt8($0 % 256) })
        try harness.sendChunked(
            .op(docId: "d", opId: "big-1", payload: OpPayload(type: "fullDoc", data: bigBytes)),
            inlineLimit: 16, chunkSize: 8)
        // Echo event proves the session saw fully reassembled inline bytes.
        #expect(try await reader.next() == .event(docId: "d", seq: 1, kind: "op", opId: "big-1",
                                                  payload: OpPayload(type: "fullDoc", data: bigBytes)))
        #expect(await manager.liveInfo()["d"]?.seq == 1)
    }

    @Test func abortMidTransferVoidsOpAndConnectionSurvives() async throws {
        var (harness, reader, manager) = try await subscribedHarness()
        let d = TransferDescriptor(transferId: 0, totalBytes: 100, chunkSize: 8)
        try harness.send(.op(docId: "d", opId: "doomed",
                             payload: OpPayload(type: "fullDoc", bulk: .transfer(d))))
        harness.sendBinary(ChunkFraming.encode(transferId: 0, index: 0, payload: Data(count: 8)))
        try harness.send(.transferAbort(transferId: 0, reason: "cancelled"))
        // The voided op consumed no seq; a follow-up inline op works and is seq 1.
        try harness.send(.op(docId: "d", opId: "after",
                             payload: OpPayload(type: "fullDoc", data: Data([1]))))
        #expect(try await reader.next() == .event(docId: "d", seq: 1, kind: "op", opId: "after",
                                                  payload: OpPayload(type: "fullDoc", data: Data([1]))))
        #expect(await manager.liveInfo()["d"]?.seq == 1)
    }

    @Test func unknownBinaryKindIsFatal() async throws {
        var (harness, reader, _) = try await subscribedHarness()
        harness.sendBinary(Data([0x7F]) + Data(count: 8))
        #expect(try await reader.next() == .error(reason: "transferViolation"))
        #expect(try await reader.next() == nil)   // connection closed
    }

    @Test func chunkGapIsFatal() async throws {
        var (harness, reader, _) = try await subscribedHarness()
        let d = TransferDescriptor(transferId: 0, totalBytes: 24, chunkSize: 8)
        try harness.send(.op(docId: "d", opId: "gap",
                             payload: OpPayload(type: "fullDoc", bulk: .transfer(d))))
        harness.sendBinary(ChunkFraming.encode(transferId: 0, index: 1, payload: Data(count: 8)))
        #expect(try await reader.next() == .error(reason: "transferViolation"))
        #expect(try await reader.next() == nil)
    }

    @Test func transferEndWithNoPendingIsFatal() async throws {
        var (harness, reader, _) = try await subscribedHarness()
        try harness.send(.transferEnd(transferId: 0))
        #expect(try await reader.next() == .error(reason: "transferViolation"))
        #expect(try await reader.next() == nil)
    }

    @Test func malformedJSONStillPerMessage() async throws {
        var (harness, reader, _) = try await subscribedHarness()
        harness.sendRaw("{nope")
        #expect(try await reader.next() == .error(reason: "malformedMessage"))
        // Connection survives: a normal op still works.
        try harness.send(.op(docId: "d", opId: "ok",
                             payload: OpPayload(type: "fullDoc", data: Data([1]))))
        #expect(try await reader.next() == .event(docId: "d", seq: 1, kind: "op", opId: "ok",
                                                  payload: OpPayload(type: "fullDoc", data: Data([1]))))
    }
}

@Suite struct WSAdapterCreateIfMissingTests {
    @Test func flaggedSubscribeToUnknownDocSucceedsAndOpEchoes() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.subscribe(docId: "brandnew", fromSeq: nil, createIfMissing: true))
        #expect(try await reader.next() == .subscribed(docId: "brandnew", seq: 0, snapshot: .inline(Data())))
        let payload = OpPayload(type: "fullDoc", data: Data([9]))
        try harness.send(.op(docId: "brandnew", opId: "o1", payload: payload))
        #expect(try await reader.next() == .event(docId: "brandnew", seq: 1, kind: "op", opId: "o1", payload: payload))
    }

    @Test func unflaggedSubscribeToUnknownDocStillErrors() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.subscribe(docId: "ghost", fromSeq: nil, createIfMissing: false))
        #expect(try await reader.next() == .error(reason: "unknownDoc"))
    }
}

@Suite struct WSAdapterWatchAndFrameTests {
    /// Two connections against one manager: an app (subscriber) and a browser (watcher).
    @Test func watchFrameCycle() async throws {
        let manager = try makeManager()
        let app = try await Harness(manager: manager)
        var appReader = ServerMessageReader(app.output)
        try app.send(.hello(protocolVersion: 1, capabilities: ["render"]))
        _ = try await appReader.next()
        try app.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        _ = try await appReader.next()   // subscribed

        let browser = try await Harness(manager: manager)
        var browserReader = ServerMessageReader(browser.output)
        try browser.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await browserReader.next()
        try browser.send(.watchDoc(docId: "d"))

        // The app learns it is watched.
        #expect(try await appReader.next() == .watchers(docId: "d", count: 1))

        // The app pushes a frame; the browser gets the nudge.
        try app.send(.frame(docId: "d", payload: .inline(Data([7, 7]))))
        #expect(try await browserReader.next() == .frameAvailable(docId: "d", seq: 0))

        // Unwatch: the app learns the viewer left.
        try browser.send(.unwatchDoc(docId: "d"))
        #expect(try await appReader.next() == .watchers(docId: "d", count: 0))
    }

    @Test func frameWithoutSubscriptionErrors() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["render"]))
        _ = try await reader.next()
        try harness.send(.frame(docId: "d", payload: .inline(Data([1]))))
        #expect(try await reader.next() == .error(reason: "notSubscribed"))
    }

    @Test func watchUnknownDocErrors() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.watchDoc(docId: "ghost"))
        #expect(try await reader.next() == .error(reason: "unknownDoc"))
    }

    @Test func disconnectReleasesWatch() async throws {
        let manager = try makeManager()
        // An app subscriber observes watcher-count notifications.
        let app = try await Harness(manager: manager)
        var appReader = ServerMessageReader(app.output)
        try app.send(.hello(protocolVersion: 1, capabilities: ["render"]))
        _ = try await appReader.next()
        try app.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        _ = try await appReader.next()   // subscribed

        let browser = try await Harness(manager: manager)
        var browserReader = ServerMessageReader(browser.output)
        try browser.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await browserReader.next()
        try browser.send(.watchDoc(docId: "d"))
        #expect(try await appReader.next() == .watchers(docId: "d", count: 1))

        // Browser vanishes without unwatchDoc: Connection.close() must release
        // the watch, observable as the count dropping back to 0.
        browser.input.finish()
        #expect(try await appReader.next() == .watchers(docId: "d", count: 0))
    }
}

/// Task 3 (create_doc branch): wires `DeviceCommandBroker` into `Connection` —
/// registers a createDoc-capable connection at hello, routes an inbound
/// `createDocReply` to `broker.handleReply`, unregisters on close. Each test
/// injects its own test-owned broker so assertions can drive
/// `broker.requestCreation` directly alongside the WS frames the adapter
/// exchanges with the (fake) client.
@Suite struct WSAdapterCreateDocTests {
    @Test func helloWithCreateDocCapabilityRegisters() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["createDoc"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        // Drive requestCreation on the broker the Connection registered
        // with at hello; the request must reach the client as a wire frame.
        let task = Task { try await broker.requestCreation(docId: "newDoc") }
        guard case .createDocRequest(let requestId, "newDoc") = try await reader.next() else {
            Issue.record("expected createDocRequest frame"); return
        }
        // Resolve directly through the broker (not the client) so the test
        // doesn't leave a pending continuation/timeout Task dangling.
        await broker.handleReply(requestId: requestId, bytes: Data(), failureReason: nil)
        _ = try await task.value
    }

    @Test func createDocReplyRoutesToBroker() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["createDoc"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        let task = Task { try await broker.requestCreation(docId: "newDoc") }
        guard case .createDocRequest(let requestId, "newDoc") = try await reader.next() else {
            Issue.record("expected createDocRequest frame"); return
        }
        // The client answers over the wire; Connection.dispatch must route
        // this to broker.handleReply, resolving the pending requestCreation.
        try harness.send(.createDocReply(
            requestId: requestId, docId: "newDoc",
            payload: .inline(Data("bytes".utf8)), failureReason: nil))
        #expect(try await task.value == Data("bytes".utf8))
    }

    @Test func replyBeforeHelloIsRejected() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.createDocReply(requestId: 1, docId: "d", payload: nil, failureReason: "x"))
        #expect(try await reader.next() == .error(reason: "helloRequired"))
    }

    @Test func disconnectUnregisters() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["createDoc"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        harness.input.finish()  // client disconnects
        while try await reader.next() != nil {}  // drain until adapter closes output (calls close())

        // close() awaits broker.unregister before finishing the output
        // stream, so by the time the drain above completes the registration
        // is already gone: no connection to route a new request to.
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.noDeviceAvailable) {
            _ = try await broker.requestCreation(docId: "d")
        }
    }

    /// RIDER (b): the broker's `handleReply` defaults a nil payload with no
    /// failureReason to a success with empty Data — Connection's dispatch
    /// arm must make that path unreachable by always substituting a
    /// failureReason ("unspecified") when neither is present on the wire.
    @Test func replyWithNeitherPayloadNorFailureReasonIsDeviceFailed() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["createDoc"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        let task = Task { try await broker.requestCreation(docId: "newDoc") }
        guard case .createDocRequest(let requestId, "newDoc") = try await reader.next() else {
            Issue.record("expected createDocRequest frame"); return
        }
        try harness.send(.createDocReply(requestId: requestId, docId: "newDoc", payload: nil, failureReason: nil))
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("unspecified")) {
            _ = try await task.value
        }
    }

    /// RIDER (a), other half: a payload present alongside a (spec-violating)
    /// failureReason must win as a success — never surfaced as a failure.
    @Test func replyWithPayloadWinsOverFailureReason() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["createDoc"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        let task = Task { try await broker.requestCreation(docId: "newDoc") }
        guard case .createDocRequest(let requestId, "newDoc") = try await reader.next() else {
            Issue.record("expected createDocRequest frame"); return
        }
        try harness.send(.createDocReply(
            requestId: requestId, docId: "newDoc",
            payload: .inline(Data("bytes".utf8)), failureReason: "ignored-because-payload-wins"))
        #expect(try await task.value == Data("bytes".utf8))
    }
}

@Suite struct WSAdapterListDocsTests {
    @Test func listDocsReturnsStoreEntriesWithLiveInfo() async throws {
        let manager = try makeManager()   // seeds doc "d"
        let harness = try await Harness(manager: manager)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await reader.next()
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        _ = try await reader.next()   // subscribed → doc "d" is live

        try harness.send(.listDocs)
        guard case .docList(let docs) = try await reader.next() else {
            Issue.record("expected docList"); return
        }
        let d = try #require(docs.first(where: { $0.id == "d" }))
        #expect(d.sizeBytes == Fixtures.docBytes.count)
        #expect(d.seq == 0)
        #expect(d.subscriberCount == 1)
    }
}

/// Task 3 (agent stroke-authoring branch): broadens the hello gate to
/// register any connection advertising `createDoc` OR `authorStrokes` (the
/// broker itself still filters per-request by capability), and routes an
/// inbound `strokeOpReply` to `broker.handleReply` with the EXACT precedence
/// `WSAdapterCreateDocTests` locks for `createDocReply` above. Each test
/// injects its own test-owned broker, mirroring `WSAdapterCreateDocTests`.
@Suite struct WSAdapterStrokeOpTests {
    @Test func helloWithAuthorStrokesCapabilityRegistersForStrokeOpOnly() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["authorStrokes"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        // Drive requestStrokeOp on the broker the Connection registered with
        // at hello; the request must reach the client as a wire frame,
        // carrying both the doc bytes and the spec bytes intact.
        let docBytes = Data("stroke-doc-bytes".utf8)
        let spec = Data("stroke-spec-bytes".utf8)
        let task = Task { try await broker.requestStrokeOp(docId: "d", docBytes: docBytes, spec: spec) }
        guard case .strokeOpRequest(let requestId, "d", .inline(let sentBytes), let sentSpec) = try await reader.next()
        else {
            Issue.record("expected strokeOpRequest frame"); return
        }
        #expect(sentBytes == docBytes)
        #expect(sentSpec == spec)
        await broker.handleReply(requestId: requestId, bytes: Data("done".utf8), failureReason: nil)
        #expect(try await task.value == Data("done".utf8))

        // This connection only ever advertised authorStrokes: a createDoc
        // request must find no capable device (the broker's own per-request
        // capability filter, not something Connection re-implements).
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.noDeviceAvailable) {
            _ = try await broker.requestCreation(docId: "d")
        }
    }

    @Test func strokeOpReplyRoutesToBroker() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["authorStrokes"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        let task = Task { try await broker.requestStrokeOp(docId: "d", docBytes: Data(), spec: Data()) }
        guard case .strokeOpRequest(let requestId, "d", _, _) = try await reader.next() else {
            Issue.record("expected strokeOpRequest frame"); return
        }
        // The client answers over the wire; Connection.dispatch must route
        // this to broker.handleReply, resolving the pending requestStrokeOp.
        try harness.send(.strokeOpReply(
            requestId: requestId, docId: "d",
            payload: .inline(Data("bytes".utf8)), failureReason: nil))
        #expect(try await task.value == Data("bytes".utf8))
    }

    @Test func replyBeforeHelloIsRejected() async throws {
        let harness = try await Harness(manager: try makeManager())
        var reader = ServerMessageReader(harness.output)
        try harness.send(.strokeOpReply(requestId: 1, docId: "d", payload: nil, failureReason: "x"))
        #expect(try await reader.next() == .error(reason: "helloRequired"))
    }

    /// Mirrors `replyWithNeitherPayloadNorFailureReasonIsDeviceFailed` in
    /// `WSAdapterCreateDocTests`: the broker's `handleReply` defaults a nil
    /// payload with no failureReason to a success with empty Data —
    /// Connection's dispatch arm must make that path unreachable by always
    /// substituting a failureReason ("unspecified") when neither is present
    /// on the wire.
    @Test func replyWithNeitherPayloadNorFailureReasonIsDeviceFailed() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["authorStrokes"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        let task = Task { try await broker.requestStrokeOp(docId: "d", docBytes: Data(), spec: Data()) }
        guard case .strokeOpRequest(let requestId, "d", _, _) = try await reader.next() else {
            Issue.record("expected strokeOpRequest frame"); return
        }
        try harness.send(.strokeOpReply(requestId: requestId, docId: "d", payload: nil, failureReason: nil))
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("unspecified")) {
            _ = try await task.value
        }
    }

    /// Mirrors `replyWithPayloadWinsOverFailureReason`: a payload present
    /// alongside a (spec-violating) failureReason must win as a success —
    /// never surfaced as a failure.
    @Test func replyWithPayloadWinsOverFailureReason() async throws {
        let broker = DeviceCommandBroker()
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["authorStrokes"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        let task = Task { try await broker.requestStrokeOp(docId: "d", docBytes: Data(), spec: Data()) }
        guard case .strokeOpRequest(let requestId, "d", _, _) = try await reader.next() else {
            Issue.record("expected strokeOpRequest frame"); return
        }
        try harness.send(.strokeOpReply(
            requestId: requestId, docId: "d",
            payload: .inline(Data("bytes".utf8)), failureReason: "ignored-because-payload-wins"))
        #expect(try await task.value == Data("bytes".utf8))
    }

    /// Disconnect must fail a pending stroke op FAST (via
    /// `DeviceCommandBroker.unregister`), not wait out the full
    /// `strokeOpTimeout` — the elapsed-time bound is what makes a regression
    /// (disconnect no longer unregistering) fail loudly instead of merely
    /// making the test slow.
    @Test func disconnectFailsPendingStrokeOpFast() async throws {
        let broker = DeviceCommandBroker(strokeOpTimeout: .seconds(30))
        let harness = try await Harness(manager: try makeManager(), broker: broker)
        var reader = ServerMessageReader(harness.output)
        try harness.send(.hello(protocolVersion: 1, capabilities: ["authorStrokes"]))
        #expect(try await reader.next() == .helloAck(protocolVersion: 1))

        let task = Task { try await broker.requestStrokeOp(docId: "d", docBytes: Data(), spec: Data()) }
        guard case .strokeOpRequest = try await reader.next() else {
            Issue.record("expected strokeOpRequest frame"); return
        }

        let clock = ContinuousClock()
        let start = clock.now
        harness.input.finish()  // client disconnects
        while try await reader.next() != nil {}  // drain until adapter closes output (calls close())

        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await task.value
        }
        #expect(clock.now - start < .seconds(1))
    }
}
