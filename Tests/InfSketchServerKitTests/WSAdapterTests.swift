import Foundation
import Testing
@testable import InfSketchServerKit
import FlyingFox

/// Drives WSAdapter.makeMessages directly with hand-fed frames — no sockets.
private struct Harness {
    let input: AsyncStream<WSMessage>.Continuation
    let output: AsyncStream<WSMessage>
    let manager: SessionManager

    init(manager: SessionManager) async throws {
        self.manager = manager
        let (inStream, inCont) = AsyncStream<WSMessage>.makeStream()
        self.input = inCont
        self.output = try await WSAdapter(manager: manager).makeMessages(for: inStream)
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

private func nextServerMessage(
    _ it: inout AsyncStream<WSMessage>.AsyncIterator
) async throws -> ServerMessage? {
    guard let frame = await it.next(), case .text(let text) = frame else { return nil }
    return try ServerMessage(jsonText: text)
}

@Suite struct WSAdapterTests {
    @Test func helloHandshakeAndSubscribeAndOp() async throws {
        let harness = try await Harness(manager: try makeManager())
        var it = harness.output.makeAsyncIterator()

        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        #expect(try await nextServerMessage(&it) == .helloAck(protocolVersion: 1))

        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        #expect(try await nextServerMessage(&it) == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))

        let payload = OpPayload(type: "fullDoc", data: Data([7]))
        try harness.send(.op(docId: "d", opId: "o1", payload: payload))
        // The echo broadcast is the ack.
        #expect(try await nextServerMessage(&it) == .event(docId: "d", seq: 1, kind: "op", opId: "o1", payload: payload))
    }

    @Test func messagesBeforeHelloAreRejected() async throws {
        let harness = try await Harness(manager: try makeManager())
        var it = harness.output.makeAsyncIterator()
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        #expect(try await nextServerMessage(&it) == .error(reason: "helloRequired"))
    }

    @Test func wrongProtocolVersionClosesConnection() async throws {
        let harness = try await Harness(manager: try makeManager())
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 99, capabilities: []))
        #expect(try await nextServerMessage(&it) == .error(reason: "unsupportedVersion"))
        #expect(await it.next() == nil)  // stream finished = connection closed
    }

    @Test func malformedJSONReportsError() async throws {
        let harness = try await Harness(manager: try makeManager())
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await nextServerMessage(&it)  // helloAck
        harness.sendRaw("{nope")
        #expect(try await nextServerMessage(&it) == .error(reason: "malformedMessage"))
    }

    @Test func opWithoutSubscribeErrors() async throws {
        let harness = try await Harness(manager: try makeManager())
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await nextServerMessage(&it)
        try harness.send(.op(docId: "d", opId: "o1", payload: OpPayload(type: "fullDoc", data: Data())))
        #expect(try await nextServerMessage(&it) == .error(reason: "notSubscribed"))
    }

    @Test func disconnectReleasesSubscriptions() async throws {
        let manager = try makeManager()
        let harness = try await Harness(manager: manager)
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await nextServerMessage(&it)
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        _ = try await nextServerMessage(&it)
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 1)

        harness.input.finish()  // client disconnects
        while await it.next() != nil {}  // drain until adapter closes output
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
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await nextServerMessage(&it)
        try harness.send(.subscribe(docId: "d", fromSeq: nil))
        _ = try await nextServerMessage(&it)

        harness.input.yield(.close(.normalClosure))
        // Drain: no error frame may appear; the stream must finish.
        while let message = try await nextServerMessage(&it) {
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
        var it = harness.output.makeAsyncIterator()
        try harness.send(.hello(protocolVersion: 1, capabilities: []))
        _ = try await nextServerMessage(&it)  // helloAck
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
            guard let message = try await nextServerMessage(&it) else { break }
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
