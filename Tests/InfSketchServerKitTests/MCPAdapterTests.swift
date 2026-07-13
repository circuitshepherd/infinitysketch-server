// macOS-only: the SDK's HTTPClientTransport does not support SSE on Linux
// (documented in its source), so its Client cannot complete initialize against
// StatefulHTTPServerTransport there; the server-side mount + adapter are
// Linux-safe to compile — see task-1-report.md (gate resolution) and
// MCPSpikeTests.swift, which carries the identical gate.
#if !os(Linux)

import Foundation
import Testing
@testable import InfSketchServerKit
import MCP
import InfSketchWire


/// Task 6 (mcp_endpoint branch): `MCPAdapter` — the MCP resource surface
/// (doc list / summary / raw bytes / frame PNG) plus `resources/subscribe`
/// with debounced update notifications. Uses the SDK's own `Client` +
/// `HTTPClientTransport` over real HTTP, the same pattern as
/// `MCPSpikeTests.swift`.
private func startServer(
    seedDocId: String = "d",
    bytes: Data = Fixtures.docBytes,
    config: SessionConfig = SessionConfig()
) async throws -> (
    InfSketchServer, UInt16, Task<Void, any Error>
) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-adapter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = DirectoryDocumentStore(directory: dir)
    try store.save(docId: seedDocId, bytes: bytes)

    let server = InfSketchServer(port: 0, docsDirectory: dir, config: config)
    let task = Task { try await server.run() }
    try await server.waitUntilListening()
    let port = try #require(await server.listeningPort)
    return (server, port, task)
}

/// Task 2 review (I1): the same harness over an INJECTED store, so a test can
/// make the document's live bytes differ from what a tool handler read — with
/// no timing, no device, and no concurrency (see `StaleReadStore`).
private func startServer(
    store: any DocumentStore,
    config: SessionConfig = SessionConfig()
) async throws -> (
    InfSketchServer, UInt16, Task<Void, any Error>
) {
    let server = InfSketchServer(port: 0, store: store, config: config)
    let task = Task { try await server.run() }
    try await server.waitUntilListening()
    let port = try #require(await server.listeningPort)
    return (server, port, task)
}

/// A `DocumentStore` whose `load` returns `first` on its FIRST call and
/// `afterFirst` on every call after — the timing-free seam that pins the
/// write-CAS wiring inside the no-device tool handlers (`edit_text`,
/// `remove_text`, `replace_doc`; Task 2 review, I1 / adjudication 2).
///
/// How it exercises the real handler body, with zero concurrency: no session
/// is live, so the handler's `manager.currentBytes(docId:)` falls through to
/// `store.load` — the FIRST load, returning `first`. The handler computes its
/// result from those bytes and submits; `submitOpeningSession` then opens the
/// session, which loads AGAIN — the second load, returning `afterFirst`. The
/// session's content and the handler's expectation therefore differ, exactly
/// as they would if a competing writer had landed in between, and the CAS must
/// reject.
///
/// It discriminates all three failure modes, which is the point:
///   - handler passes the bytes it read (correct)  → expectation `first` vs
///     session `afterFirst` → REJECTED → test green.
///   - handler passes `nil` (the regression)       → unconditional → ACCEPTED
///     → test red.
///   - handler re-reads at submit time (the other  → expectation `afterFirst`
///     regression the binding rule forbids)          vs session `afterFirst`
///                                                   → ACCEPTED → test red.
///
/// `saves` is the proof that nothing was written: a rejected submit must never
/// reach `store.save`.
private final class StaleReadStore: DocumentStore, @unchecked Sendable {
    private let lock = NSLock()
    private let docId: String
    private let first: Data
    private let afterFirst: Data
    private var loadCount = 0
    private var savedBytes: [Data] = []

    init(docId: String, first: Data, afterFirst: Data) {
        self.docId = docId
        self.first = first
        self.afterFirst = afterFirst
    }

    var loads: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCount
    }

    var saves: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return savedBytes
    }

    func list() throws -> [StoredDocInfo] {
        [StoredDocInfo(docId: docId, name: docId, sizeBytes: first.count, modifiedAt: Date())]
    }

    func load(docId: String) throws -> Data {
        guard docId == self.docId else { throw DocumentStoreError.notFound }
        lock.lock()
        defer { lock.unlock() }
        loadCount += 1
        return loadCount == 1 ? first : afterFirst
    }

    func save(docId: String, bytes: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        savedBytes.append(bytes)
    }
}

/// A raw MCP-shaped HTTP request (URLSession), for driving paths the SDK
/// client cannot: explicit `DELETE /mcp`, `resources/unsubscribe`, and
/// header-less / validation-failing POSTs.
private func rawMCPRequest(
    port: UInt16,
    method: String,
    sessionID: String? = nil,
    accept: String = "application/json, text/event-stream",
    jsonBody: String? = nil
) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = method
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    }
    if let jsonBody {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpBody = Data(jsonBody.utf8)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    return (data, http)
}

private func connectedClient(port: UInt16) async throws -> Client {
    let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
    // Short sseInitializationTimeout: the SDK client's SSE task waits for an
    // internal "session id set" signal before opening its standalone GET
    // stream, and that signal is racy (the trigger can fire before the task
    // registers its continuation — more likely under parallel test load), in
    // which case the task waits out the FULL timeout (default 10s!) before
    // proceeding anyway. Our tests only use the client after connect()
    // returns, when the session id is always set, so a short timeout just
    // caps the raced wait at 500ms instead of stalling notifications for 10s.
    let transport = HTTPClientTransport(endpoint: endpoint, sseInitializationTimeout: 0.5)
    let client = Client(name: "mcp-adapter-test-client", version: "0.0.1")
    _ = try await client.connect(transport: transport)
    return client
}

/// Collects `notifications/resources/updated` uris off the client's
/// notification handler. An actor (not a plain array) because the handler
/// closure runs off whatever task drives the client's receive loop.
private actor NotificationSink {
    private(set) var uris: [String] = []
    func record(_ uri: String) { uris.append(uri) }
    func reset() { uris.removeAll() }
}

/// Polls (bounded by `timeoutMS`) rather than a fixed sleep, so the happy
/// path resolves as soon as the notification actually arrives.
private func waitFor(_ sink: NotificationSink, atLeast n: Int, timeoutMS: Int = 2000) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMS))
    while ContinuousClock.now < deadline {
        if await sink.uris.count >= n { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await sink.uris.count >= n
}

/// The SDK client attaches its standalone GET SSE stream ASYNCHRONOUSLY
/// after initialize (HTTPClientTransport's `streamingTask`) — a notification
/// pushed before it attaches is stored server-side for replay only and never
/// live-delivered, so a test that writes immediately after subscribing races
/// the attach. Prime the channel: submit throwaway writes until one is
/// actually delivered, then let cooldowns drain and reset the sink so the
/// test counts from a clean, attached state.
private func primePushChannel(
    server: InfSketchServer, sink: NotificationSink, docId: String = "d"
) async throws {
    for attempt in 0..<10 {
        _ = await server.manager.submit(
            docId: docId, opId: "prime-\(attempt)",
            payload: OpPayload(type: "fullDoc", data: Data([0xEE])))
        if await waitFor(sink, atLeast: 1, timeoutMS: 700) { break }
    }
    #expect(await sink.uris.count >= 1, "push channel never became live")
    #expect(await sink.uris.first == "infsketch://doc/\(docId)")
    try await quiesce(sink)
    await sink.reset()
}

/// Waits until no notification has arrived for a full cooldown-plus-margin
/// window, so no in-flight trailing notify (the debouncer's 500ms trailing
/// edge) can pollute counts taken after this returns.
private func quiesce(_ sink: NotificationSink) async throws {
    var last = await sink.uris.count
    while true {
        try await Task.sleep(for: .milliseconds(700))
        let now = await sink.uris.count
        if now == last { return }
        last = now
    }
}

private struct SummaryEnvelope: Decodable {
    var seq: Int
    var summary: DocJSON.DocSummary
}

/// Concatenates every `.text` content item's string. This adapter's tool
/// results are always a single text item, but staying robust to more is free.
private func toolResultText(_ content: [Tool.Content]) -> String {
    content.compactMap { item -> String? in
        if case .text(let text, _, _) = item { return text }
        return nil
    }.joined()
}

/// Tool results that report success are shaped "<verb> <id> at seq <n>" —
/// this pulls the id back out for tests that need to act on it afterward
/// (e.g. edit/remove a just-added text).
private func addedId(from resultText: String) -> String {
    String(resultText.split(separator: " ").dropFirst().first ?? "")
}

/// A fake InfinitySketch device for the `create_doc` tests (Task 4): a real
/// WebSocket client against the same running server's `/ws` endpoint (NOT
/// the in-process `WSAdapterTests` harness — this needs to share the
/// server's actual `DeviceCommandBroker`/`SessionManager` instances with the MCP
/// client under test, which only a real running `InfSketchServer` provides).
/// Hellos with the "createDoc" capability so `WSAdapter` registers it with
/// the broker, then runs a background receive pump so it can react to an
/// inbound `createDocRequest` whenever the broker sends one — independent of
/// whatever the test's main task is doing (typically awaiting
/// `client.callTool(name: "create_doc", ...)` on the MCP side).
private actor FakeCreateDocDevice {
    private let ws: URLSessionWebSocketTask
    private var pumpTask: Task<Void, Never>?
    private(set) var receivedRequests: [(requestId: UInt32, docId: String)] = []
    private let autoReplyBytes: Data?

    /// - Parameter autoReplyBytes: when non-nil, every inbound
    ///   `createDocRequest` is answered immediately with these bytes as an
    ///   inline `createDocReply`. When nil, requests are recorded but never
    ///   answered — the `deviceTimeout` scenario.
    init(port: UInt16, autoReplyBytes: Data?) async throws {
        self.autoReplyBytes = autoReplyBytes
        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        self.ws = ws
        ws.resume()
        try await ws.send(.string(ClientMessage.hello(protocolVersion: 1, capabilities: ["createDoc"]).jsonText()))
        let ack = try await Self.receiveOne(ws)
        guard ack == .helloAck(protocolVersion: 1) else {
            throw DocumentStoreError.notFound  // any error type; an unexpected ack fails the test loudly
        }
        pumpTask = Task { [weak self] in await self?.pumpLoop() }
    }

    private func pumpLoop() async {
        while true {
            guard let message = try? await Self.receiveOne(ws) else { return }
            guard case .createDocRequest(let requestId, let docId) = message else { continue }
            receivedRequests.append((requestId, docId))
            guard let bytes = autoReplyBytes else { continue }
            try? await ws.send(.string(ClientMessage.createDocReply(
                requestId: requestId, docId: docId,
                payload: .inline(bytes), failureReason: nil
            ).jsonText()))
        }
    }

    /// Manually answers a recorded request — for tests that stall the
    /// device (autoReplyBytes: nil) to hold a request in flight, then
    /// release it at a moment of their choosing.
    func sendReply(requestId: UInt32, docId: String, bytes: Data) async throws {
        try await ws.send(.string(ClientMessage.createDocReply(
            requestId: requestId, docId: docId,
            payload: .inline(bytes), failureReason: nil
        ).jsonText()))
    }

    private static func receiveOne(_ ws: URLSessionWebSocketTask) async throws -> ServerMessage {
        let frame = try await ws.receive()
        guard case .string(let text) = frame else {
            throw DocumentStoreError.notFound  // any error type; a binary frame here is unexpected
        }
        return try ServerMessage(jsonText: text)
    }

    func close() {
        pumpTask?.cancel()
        ws.cancel(with: .normalClosure, reason: nil)
    }
}

/// A fake InfinitySketch device for the stroke-op tools (Task 4,
/// `draw_strokes`/`delete_strokes`/`list_strokes`): the same real-WS-client
/// pattern as `FakeCreateDocDevice` above, hello'd with the "authorStrokes"
/// capability instead of "createDoc", answering `strokeOpRequest` with a
/// `strokeOpReply` — either a success (`autoReply: .bytes`) or a device-side
/// failure (`autoReply: .failure`). `nil` stalls every request (recorded but
/// never answered) — the `opInProgress`/manual-release scenarios.
private actor FakeStrokeOpDevice {
    struct ReceivedRequest {
        let requestId: UInt32
        let docId: String
        let docBytes: Data
        let spec: Data
    }

    enum AutoReply {
        case bytes(Data)
        case failure(String)
    }

    private let ws: URLSessionWebSocketTask
    private var pumpTask: Task<Void, Never>?
    private(set) var receivedRequests: [ReceivedRequest] = []
    private let autoReply: AutoReply?

    init(port: UInt16, autoReply: AutoReply?) async throws {
        self.autoReply = autoReply
        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        self.ws = ws
        ws.resume()
        try await ws.send(.string(ClientMessage.hello(protocolVersion: 1, capabilities: ["authorStrokes"]).jsonText()))
        let ack = try await Self.receiveOne(ws)
        guard ack == .helloAck(protocolVersion: 1) else {
            throw DocumentStoreError.notFound  // any error type; an unexpected ack fails the test loudly
        }
        pumpTask = Task { [weak self] in await self?.pumpLoop() }
    }

    private func pumpLoop() async {
        while true {
            guard let message = try? await Self.receiveOne(ws) else { return }
            guard case .strokeOpRequest(let requestId, let docId, let payload, let spec) = message else { continue }
            receivedRequests.append(ReceivedRequest(
                requestId: requestId, docId: docId, docBytes: payload.inlineData ?? Data(), spec: spec))
            switch autoReply {
            case .bytes(let bytes):
                try? await ws.send(.string(ClientMessage.strokeOpReply(
                    requestId: requestId, docId: docId, payload: .inline(bytes), meta: nil, failureReason: nil
                ).jsonText()))
            case .failure(let reason):
                try? await ws.send(.string(ClientMessage.strokeOpReply(
                    requestId: requestId, docId: docId, payload: nil, meta: nil, failureReason: reason
                ).jsonText()))
            case nil:
                continue  // stall: recorded above, never answered until sendReply is called manually
            }
        }
    }

    /// Manually answers a recorded request — for the `opInProgress` scenario,
    /// which stalls the device (`autoReply: nil`) to hold a request in
    /// flight, then releases it once the collision has been observed.
    func sendReply(requestId: UInt32, docId: String, bytes: Data) async throws {
        try await ws.send(.string(ClientMessage.strokeOpReply(
            requestId: requestId, docId: docId, payload: .inline(bytes), meta: nil, failureReason: nil
        ).jsonText()))
    }

    private static func receiveOne(_ ws: URLSessionWebSocketTask) async throws -> ServerMessage {
        let frame = try await ws.receive()
        guard case .string(let text) = frame else {
            throw DocumentStoreError.notFound  // any error type; a binary frame here is unexpected
        }
        return try ServerMessage(jsonText: text)
    }

    func close() {
        pumpTask?.cancel()
        ws.cancel(with: .normalClosure, reason: nil)
    }
}

/// `.serialized`: the SDK client's standalone GET SSE stream is unreliable
/// under parallel in-process load — its internal session-id signal race,
/// "POST stream closed without data → cancel GET" reconnection heuristic,
/// and 3s retry interval combine so that several concurrent clients in one
/// process can leave one deaf to server pushes for many seconds (observed:
/// zero deliveries for 7s with 6+ concurrent clients; every test passes
/// solo and in small parallel groups). Serializing this suite removes that
/// client-side flake without weakening any server-side assertion.
@Suite(.serialized) struct MCPAdapterTests {
    @Test func listResourcesContainsTemplatesAndSeededDoc() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (resources, _) = try await client.listResources()
        #expect(resources.contains { $0.uri == "infsketch://docs" })
        #expect(resources.contains { $0.uri == "infsketch://doc/d" })

        await server.stop()
    }

    @Test func readResourceCoversDocsSummaryRawAndFrame() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let docsContents = try await client.readResource(uri: "infsketch://docs")
        #expect(docsContents.count == 1)
        #expect(docsContents[0].mimeType == "application/json")
        let docsJSON = try #require(docsContents[0].text)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([DocListEntry].self, from: Data(docsJSON.utf8))
        #expect(entries.contains { $0.id == "d" })

        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        #expect(summaryContents.count == 1)
        #expect(summaryContents[0].mimeType == "application/json")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.seq == -1)  // no live session yet
        #expect(envelope.summary.texts.isEmpty)
        #expect(envelope.summary.darkColorScheme == false)

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        #expect(rawContents.count == 1)
        #expect(rawContents[0].mimeType == "application/octet-stream")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == Fixtures.docBytes)

        let frameContents = try await client.readResource(uri: "infsketch://doc/d/frame")
        #expect(frameContents.count == 1)
        #expect(frameContents[0].mimeType == "image/png")
        let frameBlob = try #require(frameContents[0].blob)
        #expect(Data(base64Encoded: frameBlob) == Fixtures.thumbnailPNG)

        await #expect(throws: (any Error).self) {
            _ = try await client.readResource(uri: "infsketch://doc/ghost")
        }

        await server.stop()
    }

    @Test func subscribedSessionReceivesUpdateNotificationOnWrite() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let sink = NotificationSink()
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await sink.record(message.params.uri)
        }

        try await client.subscribeToResource(uri: "infsketch://doc/d")
        _ = try await server.manager.subscribe(docId: "d")
        try await primePushChannel(server: server, sink: sink)

        // Channel proven live and quiet: one write → exactly its notification.
        let outcome = await server.manager.submit(
            docId: "d", opId: "mcp-adapter-1",
            payload: OpPayload(type: "fullDoc", data: Fixtures.docBytes))
        #expect(outcome.rejectMessage == nil)

        let arrived = await waitFor(sink, atLeast: 1)
        #expect(arrived)
        #expect(await sink.uris.first == "infsketch://doc/d")

        await server.stop()
    }

    @Test func rapidWritesDebounceToAtMostTwoNotifications() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let sink = NotificationSink()
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await sink.record(message.params.uri)
        }

        try await client.subscribeToResource(uri: "infsketch://doc/d")
        _ = try await server.manager.subscribe(docId: "d")
        try await primePushChannel(server: server, sink: sink)

        // Two writes back-to-back: the debouncer's contract is one
        // immediate notify + at most one trailing notify after the 500ms
        // cooldown (NotificationDebouncer.minInterval) — never one per write.
        _ = await server.manager.submit(
            docId: "d", opId: "rapid-1", payload: OpPayload(type: "fullDoc", data: Data([1])))
        _ = await server.manager.submit(
            docId: "d", opId: "rapid-2", payload: OpPayload(type: "fullDoc", data: Data([2])))

        // Wait comfortably past the cooldown window so a trailing notify
        // (if owed) has time to fire, then assert the cap.
        try await Task.sleep(for: .milliseconds(1200))
        let count = await sink.uris.count
        #expect(count >= 1)
        #expect(count <= 2)

        await server.stop()
    }

    @Test func explicitDeleteEndsSessionAndStopsNotifications() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)

        let sink = NotificationSink()
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await sink.record(message.params.uri)
        }

        try await client.subscribeToResource(uri: "infsketch://doc/d")
        _ = try await server.manager.subscribe(docId: "d")
        try await primePushChannel(server: server, sink: sink)

        // The SDK client (0.12.1) never sends DELETE — client.disconnect()
        // only invalidates its local URLSession — so real session teardown
        // must be driven with an explicit DELETE /mcp carrying the session id.
        let sessionIDs = await server.mcpAdapter.activeSessionIDs
        #expect(sessionIDs.count == 1)
        let sessionID = try #require(sessionIDs.first)
        let (_, deleteResponse) = try await rawMCPRequest(
            port: port, method: "DELETE", sessionID: sessionID)
        #expect(deleteResponse.statusCode == 200)

        // The registry entry and the debouncer subscription are gone…
        #expect(await server.mcpAdapter.activeSessionIDs.isEmpty)
        #expect(await server.mcpAdapter.debouncerSubscriptions.isEmpty)

        // …and a post-DELETE write pushes nothing (sink was reset by the
        // primer) and must not crash the pump.
        _ = await server.manager.submit(
            docId: "d", opId: "after-end", payload: OpPayload(type: "fullDoc", data: Data([2])))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await sink.uris.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    @Test func idleSessionIsReapedAndItsSubscriptionsDropped() async throws {
        // The SDK client never sends DELETE, so idle reaping is the ordinary
        // teardown path for MCP sessions. Shortened timeouts via config.
        // All assertions are server-side (registry + debouncer hooks):
        // client-side silence after a reap is trivially true (the reap
        // closes the client's SSE stream), so it proves nothing.
        let (server, port, task) = try await startServer(config: SessionConfig(
            mcpSessionIdleTimeout: .milliseconds(500),
            mcpSessionCleanupInterval: .milliseconds(100)))
        defer { task.cancel() }
        let client = try await connectedClient(port: port)

        try await client.subscribeToResource(uri: "infsketch://doc/d")
        #expect(await server.mcpAdapter.activeSessionIDs.count == 1)
        #expect(await server.mcpAdapter.debouncerSubscriptions["d"]?.count == 1)

        // Client goes quiet (sends no further requests): past the idle
        // timeout the adapter must reap the session — registry entry
        // removed and debouncer subscription dropped.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await server.mcpAdapter.activeSessionIDs.isEmpty)
        #expect(await server.mcpAdapter.debouncerSubscriptions.isEmpty)

        // A post-reap write must not crash the pump.
        _ = try await server.manager.subscribe(docId: "d")
        _ = await server.manager.submit(
            docId: "d", opId: "after-reap", payload: OpPayload(type: "fullDoc", data: Data([2])))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.mcpAdapter.debouncerSubscriptions.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    @Test func resourcesUnsubscribeStopsNotifications() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)

        let sink = NotificationSink()
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await sink.record(message.params.uri)
        }

        try await client.subscribeToResource(uri: "infsketch://doc/d")
        _ = try await server.manager.subscribe(docId: "d")
        try await primePushChannel(server: server, sink: sink)

        // The SDK client (0.12.1) has no unsubscribe method, so drive
        // resources/unsubscribe with a raw JSON-RPC POST carrying the
        // session id. The response streams back SSE-framed; assert it is a
        // result, not an error (unwired handler would be method-not-found).
        let sessionID = try #require(await server.mcpAdapter.activeSessionIDs.first)
        let (body, response) = try await rawMCPRequest(
            port: port, method: "POST", sessionID: sessionID,
            jsonBody: #"{"jsonrpc":"2.0","id":"unsub-1","method":"resources/unsubscribe","params":{"uri":"infsketch://doc/d"}}"#)
        #expect(response.statusCode == 200)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""result""#))
        #expect(!text.contains(#""error""#))

        // Dropped server-side…
        #expect(await server.mcpAdapter.debouncerSubscriptions.isEmpty)

        // …and the client is STILL fully connected (live GET stream, session
        // registered) — so this silence assertion is meaningful: were the
        // subscription still registered, the notification WOULD arrive.
        #expect(await server.mcpAdapter.activeSessionIDs.count == 1)
        _ = await server.manager.submit(
            docId: "d", opId: "post-unsub", payload: OpPayload(type: "fullDoc", data: Data([2])))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await sink.uris.isEmpty)

        await client.disconnect()
        await server.stop()
    }

    @Test func headerlessNonInitializePostIsRejectedWithoutCreatingASession() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let (_, response) = try await rawMCPRequest(
            port: port, method: "POST",
            jsonBody: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(response.statusCode == 400)
        #expect(await server.mcpAdapter.activeSessionIDs.isEmpty)

        await server.stop()
    }

    @Test func initializeFailingTransportValidationRollsBackTheSession() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        // A genuine initialize request whose Accept header fails the
        // transport's validation pipeline (no text/event-stream): the
        // adapter creates the session pair, the transport 406es, and the
        // rollback branch must remove the just-registered session.
        let (_, response) = try await rawMCPRequest(
            port: port, method: "POST",
            accept: "application/json",
            jsonBody: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
        #expect(response.statusCode == 406)
        #expect(await server.mcpAdapter.activeSessionIDs.isEmpty)

        await server.stop()
    }

    // MARK: - Tools (Task 7)

    // Renamed from `listToolsContainsAllFiveWriteTools` (Task 4, agent
    // stroke-authoring): three more tools joined the surface, so "Five" was
    // no longer accurate.
    @Test func listToolsContainsAllEightWriteTools() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        let names = Set(tools.map(\.name))
        #expect(names == [
            "add_text", "edit_text", "remove_text", "replace_doc", "create_doc",
            "draw_strokes", "delete_strokes", "list_strokes",
        ])
        // The formatting-reset warning is load-bearing enough to regression-test verbatim presence.
        let editText = try #require(tools.first { $0.name == "edit_text" })
        #expect(editText.description?.contains("resets") == true)

        await server.stop()
    }

    @Test func addTextSucceedsAndSummaryReflectsIt() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "add_text",
            arguments: ["docId": "d", "text": "hello agent", "x": 10, "y": 20, "pinned": false])
        #expect(isError != true)
        let text = toolResultText(content)
        #expect(text.hasPrefix("added "))
        #expect(text.contains("seq 1"))

        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.seq == 1)
        #expect(envelope.summary.texts.count == 1)
        #expect(envelope.summary.texts.first?.text == "hello agent")
        #expect(envelope.summary.texts.first?.x == 10)
        #expect(envelope.summary.texts.first?.y == 20)
        #expect(envelope.summary.texts.first?.pinned == false)

        await server.stop()
    }

    /// The mandatory rider (Task 3 review, N2): a numeric-looking JSON STRING
    /// must be rejected as a tool error, never coerced (`Double("40000")`
    /// would succeed and, for a truly non-finite string, would arm DocJSON's
    /// x/y finite-value precondition remotely).
    @Test func addTextRejectsNonNumericCoordinateWithoutCoercion() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "add_text",
            arguments: ["docId": "d", "text": "hi", "x": .string("40000"), "y": 20])
        #expect(isError == true)
        #expect(!toolResultText(content).isEmpty)

        // No crash, and the doc is untouched (no session was ever opened).
        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.seq == -1)
        #expect(envelope.summary.texts.isEmpty)

        await server.stop()
    }

    @Test func addTextUnknownDocReturnsToolError() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "add_text",
            arguments: ["docId": "ghost", "text": "hi", "x": 1, "y": 2])
        #expect(isError == true)
        #expect(toolResultText(content) == "unknownDoc")

        await server.stop()
    }

    // MARK: - Write CAS at the tool boundary, via the StaleReadStore seam
    //
    // (Task 2 review, I1 / adjudication 2.) These four run the REAL handler
    // bodies — callAddText / callEditText / callRemoveText / callReplaceDoc —
    // end to end through `client.callTool`, and go green ONLY if the handler
    // passes the bytes it read as its expectation. A `nil` expectation or a
    // fresh re-read at submit time both make the write land and turn them red.
    // See `StaleReadStore` above for why no timing, device, or concurrency is
    // needed to make the doc's live bytes differ from what the handler read.
    //
    // The stroke tools (which DO have a device stall to lean on) get the real
    // thing instead — a genuine competing write mid-round-trip; see
    // drawStrokes/deleteStrokesRejectsWhenTheDocumentChangedMidOp below.

    /// The bytes a StaleReadStore hands back on every load AFTER the first —
    /// i.e. what the tool handler never saw.
    private static let changedUnderneathBytes =
        Data(#"{"aaa001_thumbnailData":"","marker":"changed-underneath"}"#.utf8)

    @Test func addTextRejectsWhenTheDocumentChangedMidOp() async throws {
        let store = StaleReadStore(
            docId: "d", first: Fixtures.docBytes, afterFirst: Self.changedUnderneathBytes)
        let (server, port, task) = try await startServer(store: store)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "add_text", arguments: ["docId": "d", "text": "hi", "x": 1, "y": 2])
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")
        // Nothing reached the store: a rejected submit must never save.
        #expect(store.saves.isEmpty)

        await server.stop()
    }

    @Test func editTextRejectsWhenTheDocumentChangedMidOp() async throws {
        let textId = UUID()
        let seeded = try DocJSON.addText(
            to: Fixtures.docBytes, id: textId, text: "before", x: 1, y: 2, pinned: false)
        let store = StaleReadStore(
            docId: "d", first: seeded, afterFirst: Self.changedUnderneathBytes)
        let (server, port, task) = try await startServer(store: store)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "edit_text",
            arguments: ["docId": "d", "textId": .string(textId.uuidString), "text": "after"])
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")
        #expect(store.saves.isEmpty)

        await server.stop()
    }

    @Test func removeTextRejectsWhenTheDocumentChangedMidOp() async throws {
        let textId = UUID()
        let seeded = try DocJSON.addText(
            to: Fixtures.docBytes, id: textId, text: "gone soon", x: 1, y: 2, pinned: false)
        let store = StaleReadStore(
            docId: "d", first: seeded, afterFirst: Self.changedUnderneathBytes)
        let (server, port, task) = try await startServer(store: store)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "remove_text",
            arguments: ["docId": "d", "textId": .string(textId.uuidString)])
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")
        #expect(store.saves.isEmpty)

        await server.stop()
    }

    @Test func editTextUnknownIdReturnsToolError() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "edit_text",
            arguments: ["docId": "d", "textId": "ghost-id", "text": "new"])
        #expect(isError == true)
        #expect(toolResultText(content) == "textNotFound")

        await server.stop()
    }

    @Test func editTextUpdatesTextAndPosition() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (addContent, addIsError) = try await client.callTool(
            name: "add_text", arguments: ["docId": "d", "text": "before", "x": 1, "y": 2])
        #expect(addIsError != true)
        let id = addedId(from: toolResultText(addContent))

        let (editContent, editIsError) = try await client.callTool(
            name: "edit_text",
            arguments: ["docId": "d", "textId": .string(id), "text": "after", "x": 5, "y": 6])
        #expect(editIsError != true)
        #expect(toolResultText(editContent).contains("seq 2"))

        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.summary.texts.count == 1)
        #expect(envelope.summary.texts.first?.text == "after")
        #expect(envelope.summary.texts.first?.x == 5)
        #expect(envelope.summary.texts.first?.y == 6)

        await server.stop()
    }

    @Test func removeTextRemovesEntryById() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (addContent, _) = try await client.callTool(
            name: "add_text", arguments: ["docId": "d", "text": "gone soon", "x": 1, "y": 2])
        let id = addedId(from: toolResultText(addContent))

        let (removeContent, removeIsError) = try await client.callTool(
            name: "remove_text", arguments: ["docId": "d", "textId": .string(id)])
        #expect(removeIsError != true)
        #expect(toolResultText(removeContent).contains("seq 2"))

        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.summary.texts.isEmpty)

        await server.stop()
    }

    /// Covers the `createIfMissing: true` path `create_doc` would have used
    /// (deferred per the Task 2 gate resolution — see the plan doc).
    @Test func replaceDocForFreshIdStoresFile() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let freshBytes = Data(#"{"aaa001_thumbnailData":"","placedTextsData":[]}"#.utf8)
        let (content, isError) = try await client.callTool(
            name: "replace_doc",
            arguments: ["docId": "fresh", "bytes": .string(freshBytes.base64EncodedString())])
        #expect(isError != true)
        #expect(toolResultText(content).contains("seq 1"))

        let entries = try await server.manager.listDocuments()
        #expect(entries.contains { $0.id == "fresh" })

        let rawContents = try await client.readResource(uri: "infsketch://doc/fresh/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == freshBytes)

        await server.stop()
    }

    @Test func replaceDocRoundTripsRawBytes() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let originalRaw = try await client.readResource(uri: "infsketch://doc/d/raw")
        #expect(Data(base64Encoded: try #require(originalRaw[0].blob)) == Fixtures.docBytes)

        let replacement = Data(#"{"aaa001_thumbnailData":"","marker":"replaced"}"#.utf8)
        let (_, isError) = try await client.callTool(
            name: "replace_doc",
            arguments: ["docId": "d", "bytes": .string(replacement.base64EncodedString())])
        #expect(isError != true)

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == replacement)

        await server.stop()
    }

    /// Task 2 review (I1): `replace_doc`'s EXISTING-doc branch, at the real
    /// tool boundary, via the `StaleReadStore` seam (see the MARK above the
    /// text-tool CAS tests). The agent's bytes are opaque, but the handler
    /// still reads the doc first and must expect exactly what it read —
    /// otherwise it blindly overwrites a document that changed under it.
    @Test func replaceDocOnExistingDocIsGuarded() async throws {
        let store = StaleReadStore(
            docId: "d", first: Fixtures.docBytes, afterFirst: Self.changedUnderneathBytes)
        let (server, port, task) = try await startServer(store: store)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let replacement = Data(#"{"aaa001_thumbnailData":"","marker":"replacement"}"#.utf8)
        let (content, isError) = try await client.callTool(
            name: "replace_doc",
            arguments: ["docId": "d", "bytes": .string(replacement.base64EncodedString())])
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")
        #expect(store.saves.isEmpty)

        await server.stop()
    }

    /// Task 2 (write CAS): the missing-doc branch must stay `expectedBytes:
    /// nil` (there is nothing to compare against) with `createIfMissing:
    /// true` unchanged — a fresh docId must still create successfully.
    @Test func replaceDocOnMissingDocStillCreates() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let freshBytes = Data(#"{"aaa001_thumbnailData":"","marker":"brand-new"}"#.utf8)
        let (content, isError) = try await client.callTool(
            name: "replace_doc",
            arguments: ["docId": "totally-new", "bytes": .string(freshBytes.base64EncodedString())])
        #expect(isError != true)
        #expect(toolResultText(content).contains("seq 1"))

        let rawContents = try await client.readResource(uri: "infsketch://doc/totally-new/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == freshBytes)

        await server.stop()
    }

    /// The seq in a tool ack must be the seq THIS call's own write was
    /// assigned — not whatever the doc's seq happens to be a beat later
    /// (Task 7 review, Important #1: the original implementation read the
    /// seq back via a separate `liveInfo()` actor hop AFTER the write, so a
    /// racing concurrent write landing in that gap made the ack report the
    /// wrong seq). Race shape: several concurrent `add_text` calls to the
    /// same doc. Ground truth comes from the broadcast events — each
    /// accepted write's event carries its assigned seq, and the event that
    /// FIRST contains a given text id is that text's own write (no other
    /// writer can carry id U in its payload before U's own write landed, and
    /// seqs are assigned in landing order).
    ///
    /// Updated for Task 2 (write CAS): each call now carries the bytes IT read
    /// as its `expectedBytes`, so several truly-concurrent add_text calls
    /// racing on the SAME doc can legitimately lose the compare-and-swap — a
    /// call that read before a sibling's write landed, then tried to submit
    /// after it, is correctly rejected with docChangedDuringOp instead of
    /// silently clobbering. Each racer therefore RETRIES on that reason (the
    /// published contract — the six tool descriptions say verbatim "re-read
    /// the document and retry"), which keeps all six racers accepting and so
    /// pins the Task 7 seq-ack property at full strength, while making the
    /// test double as the executable spec of that retry contract. A retry is
    /// correct by construction: a rejected attempt wrote nothing, and the
    /// retry re-reads fresh bytes.
    @Test func toolAckSeqIsTheWritesOwnAssignedSeqUnderConcurrency() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        // Direct manager subscription = the broadcast ground truth.
        let sub = try await server.manager.subscribe(docId: "d")
        defer { Task { await server.manager.unsubscribe(docId: "d", token: sub.token) } }

        let concurrency = 6
        let maxAttempts = 10
        let accepted: [(id: String, reportedSeq: Int)] = try await withThrowingTaskGroup(
            of: (String, Int)?.self
        ) { group in
            for i in 0..<concurrency {
                group.addTask {
                    // The retry loop the tool descriptions prescribe. Contention
                    // falls off as racers succeed and drop out, so the bound is
                    // generous rather than tight.
                    for _ in 0..<maxAttempts {
                        let (content, isError) = try await client.callTool(
                            name: "add_text",
                            arguments: ["docId": "d", "text": "race \(i)", "x": 1, "y": 2])
                        let text = toolResultText(content)
                        guard isError == true else {
                            let reportedSeq = try #require(Int(text.split(separator: " ").last ?? ""))
                            return (addedId(from: text), reportedSeq)
                        }
                        // The ONLY rejection a racer may see here: a lost CAS.
                        // Any other error is a real failure, not a retryable one.
                        #expect(text == "docChangedDuringOp", "unexpected rejection reason: \(text)")
                        guard text == "docChangedDuringOp" else { return nil }
                    }
                    Issue.record("racer \(i) still lost the CAS after \(maxAttempts) attempts")
                    return nil
                }
            }
            var collected: [(String, Int)] = []
            for try await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }
        // With retries, every racer must eventually land.
        #expect(accepted.count == concurrency)
        // M5: a bare #expect would let the drain loop below block forever on
        // events that will never come. Fail fast instead of hanging.
        guard !accepted.isEmpty else { return }

        // Drain the ops off the event stream and record, per text id, the seq
        // of the event that first contains it (= its own write's seq). A
        // rejected attempt never reaches store.save, so it never broadcasts —
        // there is exactly one op per ACCEPTED call.
        var firstSeenSeq: [String: Int] = [:]
        var opsSeen = 0
        for await message in sub.events {
            guard case .event(_, let seq, _, let opId, let payload) = message else { continue }
            #expect(opId.hasPrefix("mcp-"))
            opsSeen += 1
            let bytes = try #require(payload.bulk.inlineData)
            for text in try DocJSON.summary(from: bytes).texts
            where firstSeenSeq[text.id] == nil {
                firstSeenSeq[text.id] = seq
            }
            if opsSeen == accepted.count { break }
        }

        for (id, reportedSeq) in accepted {
            #expect(
                firstSeenSeq[id] == reportedSeq,
                "ack for \(id) reported seq \(reportedSeq) but its write was assigned seq \(String(describing: firstSeenSeq[id]))")
        }

        // Nothing lost, nothing leaked: the final doc holds exactly the
        // accepted ids, no more and no fewer. (Without the CAS, the racers
        // produce lost updates and an accepted id goes missing here.)
        let finalBytes = try #require(await server.manager.currentBytes(docId: "d"))
        let finalIds = Set(try DocJSON.summary(from: finalBytes).texts.map(\.id))
        #expect(finalIds == Set(accepted.map(\.id)))

        await server.stop()
    }

    @Test func twoConcurrentSessionsSubscriberSeesAddTextFromAnotherSession() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let subscriberClient = try await connectedClient(port: port)
        let writerClient = try await connectedClient(port: port)

        let sink = NotificationSink()
        await subscriberClient.onNotification(ResourceUpdatedNotification.self) { message in
            await sink.record(message.params.uri)
        }
        try await subscriberClient.subscribeToResource(uri: "infsketch://doc/d")
        _ = try await server.manager.subscribe(docId: "d")
        try await primePushChannel(server: server, sink: sink)

        // `primePushChannel`'s own throwaway writes leave "d"'s live bytes as
        // garbage (not valid JSON) — restore real document content before
        // exercising add_text below, and drain/reset the sink so this
        // reseed's own notification doesn't count toward the assertions.
        _ = await server.manager.submit(
            docId: "d", opId: "reseed", payload: OpPayload(type: "fullDoc", data: Fixtures.docBytes))
        try await quiesce(sink)
        await sink.reset()

        #expect(await server.mcpAdapter.activeSessionIDs.count == 2)

        let (content, isError) = try await writerClient.callTool(
            name: "add_text",
            arguments: ["docId": "d", "text": "from another session", "x": 3, "y": 4])
        #expect(isError != true)
        #expect(toolResultText(content).hasPrefix("added "))

        let arrived = await waitFor(sink, atLeast: 1)
        #expect(arrived)
        #expect(await sink.uris.first == "infsketch://doc/d")

        // Both sessions keep working after the cross-session push.
        #expect(await server.mcpAdapter.activeSessionIDs.count == 2)
        let (resources, _) = try await subscriberClient.listResources()
        #expect(resources.contains { $0.uri == "infsketch://doc/d" })
        let summaryContents = try await writerClient.readResource(uri: "infsketch://doc/d")
        #expect(summaryContents.count == 1)

        await subscriberClient.disconnect()
        await writerClient.disconnect()
        await server.stop()
    }

    // MARK: - create_doc (Task 4)

    /// Task 2 (write CAS): `create_doc` is deliberately UNCHANGED — there is
    /// no prior content to compare against, so its `docExists` guard remains
    /// the race's only meaningful shape here. Pin both halves: no
    /// `docChangedDuringOp` sentence in its description (unlike the six
    /// CAS-guarded tools), and creation still succeeds normally.
    @Test func createDocIsUnaffected() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: Fixtures.docBytes)
        defer { Task { await device.close() } }

        let (tools, _) = try await client.listTools()
        let createDoc = try #require(tools.first { $0.name == "create_doc" })
        #expect(createDoc.description?.contains("docChangedDuringOp") != true)

        let (content, isError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "StillCreates"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("seq 1"))

        let entries = try await server.manager.listDocuments()
        #expect(entries.contains { $0.id == "StillCreates" })

        await server.stop()
    }

    /// Task 2 (write CAS): pins the verbatim rejection sentence onto exactly
    /// the six CAS-guarded write tools, and its absence from `create_doc` /
    /// `list_strokes` (which are unaffected — see createDocIsUnaffected and
    /// listStrokesReturnsFakeListingVerbatimWithNoWrite).
    @Test func toolDescriptionsCarryTheCASRejectionSentenceOnlyWhereGuarded() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        let sentence = "Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry."
        for name in ["add_text", "edit_text", "remove_text", "replace_doc", "draw_strokes", "delete_strokes"] {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool.description?.contains(sentence) == true, "\(name) missing the CAS sentence")
        }
        for name in ["create_doc", "list_strokes"] {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool.description?.contains(sentence) != true, "\(name) should not carry the CAS sentence")
        }

        await server.stop()
    }

    @Test func createDocSucceedsWithCapableDevice() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: Fixtures.docBytes)
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "Fresh"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("seq 1"))

        let rawContents = try await client.readResource(uri: "infsketch://doc/Fresh/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == Fixtures.docBytes)

        let entries = try await server.manager.listDocuments()
        #expect(entries.contains { $0.id == "Fresh" })

        await server.stop()
    }

    @Test func createDocOnExistingDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: Fixtures.docBytes)
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content) == "docExists")

        // The existence check must short-circuit BEFORE ever contacting the
        // device — no createDocRequest should have been sent.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func createDocWithNoDeviceErrors() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device connects in this test.

        let (content, isError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "NoDevice"])
        #expect(isError == true)
        #expect(toolResultText(content) == "noDeviceAvailable")

        await server.stop()
    }

    @Test func createDocDeviceTimeoutErrors() async throws {
        let (server, port, task) = try await startServer(
            config: SessionConfig(createDocTimeout: .milliseconds(100)))
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Capable device connects but never answers.
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: nil)
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "SlowDoc"])
        #expect(isError == true)
        #expect(toolResultText(content) == "deviceTimeout")

        await server.stop()
    }

    /// Pins the PUBLISHED tool-error string for a same-docId in-flight
    /// collision to exactly "creationInProgress" — the broker's error case
    /// was renamed to the kind-agnostic `.requestInFlight` (Task 2,
    /// DeviceCommandBroker), but the string MCP clients see must not change.
    /// MCPAdapter's `callCreateDoc` mapping cites this test.
    @Test func createDocInFlightErrorPublishesCreationInProgress() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Capable device that records requests but never answers on its own
        // — holds the first create_doc in flight until we release it below.
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: nil)
        defer { Task { await device.close() } }

        let firstCall = Task { try await client.callTool(
            name: "create_doc", arguments: ["docId": "Pending"]) }

        // Wait until the request is actually in flight (has reached the
        // device), so the second call below is a genuine collision.
        var inFlight = false
        for _ in 0..<100 {
            if await device.receivedRequests.count == 1 { inFlight = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inFlight)

        let (content, isError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "Pending"])
        #expect(isError == true)
        #expect(toolResultText(content) == "creationInProgress")

        // Release the stalled first request so it completes normally
        // (rather than dangling until the 10 s default timeout).
        let pending = try #require(await device.receivedRequests.first)
        try await device.sendReply(
            requestId: pending.requestId, docId: pending.docId, bytes: Fixtures.docBytes)
        let (firstContent, firstIsError) = try await firstCall.value
        #expect(firstIsError != true)
        #expect(toolResultText(firstContent).contains("seq 1"))

        await server.stop()
    }

    // MARK: - Stroke-op tools (Task 4, agent stroke-authoring)

    /// A minimal draw-spec strokes argument using the CANONICAL field names
    /// (see drawStrokesSpecEnvelopeMatchesCanonicalShape) — for tests whose
    /// point isn't the spec shape but that still must never teach a reader
    /// (or copy-paster) a drifted field name.
    private static let minimalCanonicalStrokes: Value = .array([
        .object(["points": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(10)])])])
    ])

    @Test func listStrokesReturnsFakeListingVerbatimWithNoWrite() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let listingJSON = Data(#"{"strokes":[{"key":"seed123:1.0","pointCount":2}]}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(listingJSON))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_strokes", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: listingJSON, as: UTF8.self))

        // No write: list_strokes never opens a session, so the doc's live
        // seq stays unset (-1), same as the never-touched state in
        // readResourceCoversDocsSummaryRawAndFrame.
        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.seq == -1)

        // The fake received a "list" op-spec plus the doc's current bytes.
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "list")

        await server.stop()
    }

    @Test func drawStrokesSendsSpecAndWritesReturnedBytes() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["new-stroke"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(modifiedBytes))
        defer { Task { await device.close() } }

        // CANONICAL stroke-spec field names (points/width/color/inkType) —
        // the exact keys the app-side StrokeAuthoring.StrokeSpec (Task 5)
        // decodes. Never use e.g. "tool" here: Decodable drops unknown keys
        // silently, so a wrong name would pass this test yet break every
        // real draw. See drawStrokesSpecEnvelopeMatchesCanonicalShape.
        let strokesArg: Value = .array([
            .object([
                "points": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(10)])]),
                "width": .int(4),
                "color": .string("#000000"),
                "inkType": .string("pen"),
            ])
        ])
        let (content, isError) = try await client.callTool(
            name: "draw_strokes", arguments: ["docId": "d", "strokes": strokesArg])
        #expect(isError != true)
        #expect(toolResultText(content) == "drew 1 stroke(s) at seq 1")

        // The fake received a "draw" op-spec carrying the strokes array verbatim.
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "draw")
        #expect((specJSON["strokes"] as? [Any])?.count == 1)

        // The raw resource now reflects the fake's returned bytes.
        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == modifiedBytes)

        await server.stop()
    }

    /// THE CROSS-REPO SPEC-ENVELOPE CONTRACT PIN (Task 4 review, Important):
    /// the op-spec JSON this server builds is decoded app-side by Task 5's
    /// plain-`Decodable` `StrokeAuthoring.StrokeSpec`, which silently drops
    /// unknown keys — so a field-name drift on either side ("inkType"
    /// mistyped as "tool", say) would never fail loudly; the value would
    /// just fall back to its default. This test therefore asserts the exact
    /// envelope shape with the CANONICAL key names as string literals:
    ///
    ///     {"op": "draw", "strokes": [{"points": [[x,y],…],
    ///                                 "width": …, "color": …, "inkType": …}]}
    ///
    /// Task 5's own StrokeSpec decode tests must decode a fixture using
    /// EXACTLY these field names (binding rider carried by the plan). If
    /// this test ever needs changing, both repos change in lockstep.
    @Test func drawStrokesSpecEnvelopeMatchesCanonicalShape() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes))
        defer { Task { await device.close() } }

        let strokesArg: Value = .array([
            .object([
                "points": .array([
                    .array([.double(1.5), .double(2.5)]),
                    .array([.int(30), .int(40)]),
                ]),
                "width": .double(6.5),
                "color": .string("#FF00AA"),
                "inkType": .string("marker"),
            ])
        ])
        let (_, isError) = try await client.callTool(
            name: "draw_strokes", arguments: ["docId": "d", "strokes": strokesArg])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        // Exact envelope: exactly the two top-level keys, no extras.
        #expect(Set(envelope.keys) == ["op", "strokes"])
        #expect(envelope["op"] as? String == "draw")
        let strokes = try #require(envelope["strokes"] as? [[String: Any]])
        #expect(strokes.count == 1)
        let stroke = try #require(strokes.first)
        // The CANONICAL per-stroke field names, asserted string-literally.
        #expect(Set(stroke.keys) == ["points", "width", "color", "inkType"])
        let points = try #require(stroke["points"] as? [[Double]])
        #expect(points == [[1.5, 2.5], [30, 40]])
        #expect(stroke["width"] as? Double == 6.5)
        #expect(stroke["color"] as? String == "#FF00AA")
        #expect(stroke["inkType"] as? String == "marker")

        await server.stop()
    }

    @Test func deleteStrokesUnknownKeyErrorPropagatesDeviceReason() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .failure("strokeNotFound: [k9]"))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "delete_strokes", arguments: ["docId": "d", "keys": .array([.string("k9")])])
        #expect(isError == true)
        #expect(toolResultText(content) == "deviceFailed: strokeNotFound: [k9]")

        await server.stop()
    }

    @Test func drawStrokesWithNoDeviceErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device connects in this test.

        let (content, isError) = try await client.callTool(
            name: "draw_strokes",
            arguments: ["docId": "d", "strokes": Self.minimalCanonicalStrokes])
        #expect(isError == true)
        #expect(toolResultText(content) == "noDeviceAvailable")

        await server.stop()
    }

    /// A second stroke op on the SAME docId while the first is stalled in
    /// flight collides on `DeviceCommandBroker`'s shared per-docId
    /// `docIdsInFlight` guard — deliberately mixing kinds (draw, then
    /// delete) to prove the guard is keyed by docId alone, not per tool.
    @Test func secondStrokeOpOnSameDocWhileInFlightErrorsOpInProgress() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Capable device that records requests but never answers on its own
        // — holds the first draw_strokes in flight until we release it below.
        let device = try await FakeStrokeOpDevice(port: port, autoReply: nil)
        defer { Task { await device.close() } }

        let firstCall = Task { try await client.callTool(
            name: "draw_strokes",
            arguments: ["docId": "d", "strokes": Self.minimalCanonicalStrokes]) }

        // Wait until the request is actually in flight (has reached the
        // device), so the second call below is a genuine collision.
        var inFlight = false
        for _ in 0..<100 {
            if await device.receivedRequests.count == 1 { inFlight = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inFlight)

        let (content, isError) = try await client.callTool(
            name: "delete_strokes", arguments: ["docId": "d", "keys": .array([.string("k1")])])
        #expect(isError == true)
        #expect(toolResultText(content) == "opInProgress")

        // Release the stalled first request so it completes normally
        // (rather than dangling until the strokeOpTimeout default).
        let pending = try #require(await device.receivedRequests.first)
        try await device.sendReply(
            requestId: pending.requestId, docId: pending.docId, bytes: Fixtures.docBytes)
        let (firstContent, firstIsError) = try await firstCall.value
        #expect(firstIsError != true)
        #expect(toolResultText(firstContent).contains("seq 1"))

        await server.stop()
    }

    /// Task 2 (write CAS) — THE REPRODUCTION of the real bug this plan
    /// exists to close: draw_strokes reads the doc, relays it to a connected
    /// device, and must write back the device's result ONLY if nothing else
    /// changed the doc during that round trip. Pre-fix, the write went
    /// through unconditionally regardless of what happened while the device
    /// was thinking — a competing write landing during the stall was
    /// silently clobbered. RED-verified against the pre-fix code (see
    /// task-2-report.md for the actual observed pre-fix outcome: the call
    /// succeeded and the competing write's content was overwritten).
    @Test func drawStrokesRejectsWhenTheDocumentChangedMidOp() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // A live session must already exist for the direct `manager.submit`
        // competing write below to be accepted (it requires a subscribed
        // session) — opening it here doesn't change what draw_strokes itself
        // reads (still Fixtures.docBytes).
        let sub = try await server.manager.subscribe(docId: "d")
        defer { Task { await server.manager.unsubscribe(docId: "d", token: sub.token) } }
        // Capable device that records requests but never answers on its own
        // — holds the draw in flight until we release it below, AFTER the
        // competing write has landed.
        let device = try await FakeStrokeOpDevice(port: port, autoReply: nil)
        defer { Task { await device.close() } }

        let drawCall = Task { try await client.callTool(
            name: "draw_strokes",
            arguments: ["docId": "d", "strokes": Self.minimalCanonicalStrokes]) }

        // Wait until the request has actually reached the device — proving
        // draw_strokes already read the doc's bytes and is now stalled
        // waiting for the reply.
        var inFlight = false
        for _ in 0..<100 {
            if await device.receivedRequests.count == 1 { inFlight = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inFlight)
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docBytes == Fixtures.docBytes)

        // A competing write lands directly through the manager WHILE the
        // draw op is stalled waiting on the device — exactly the shape of
        // another writer editing the doc mid-round-trip.
        let competingBytes = Data(#"{"aaa001_thumbnailData":"","marker":"competing-write"}"#.utf8)
        let competingOutcome = await server.manager.submit(
            docId: "d", opId: "competing-writer",
            payload: OpPayload(type: "fullDoc", data: competingBytes))
        guard case .accepted = competingOutcome else {
            Issue.record("expected the competing write to be accepted, got \(competingOutcome)")
            return
        }

        // Release the device now: its reply carries a result computed
        // against the STALE document it was handed, before the competing
        // write landed.
        let staleResultBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["new-stroke"]}"#.utf8)
        try await device.sendReply(
            requestId: received.requestId, docId: received.docId, bytes: staleResultBytes)

        let (content, isError) = try await drawCall.value
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")

        // The competing write's content must survive untouched — nothing clobbered.
        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == competingBytes)

        await server.stop()
    }

    /// Task 2 review (I1): the delete_strokes twin of the draw test above —
    /// `callDeleteStrokes`'s CAS wiring was pinned by nothing, so flipping its
    /// `expectedBytes: docBytes` to nil left the whole suite green while
    /// restoring the silent clobber. Same deterministic device-stall harness
    /// (`FakeStrokeOpDevice(autoReply: nil)`), which is already fired at this
    /// exact tool by secondStrokeOpOnSameDocWhileInFlightErrorsOpInProgress.
    @Test func deleteStrokesRejectsWhenTheDocumentChangedMidOp() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Live session so the competing `manager.submit` below is accepted
        // (see the draw test) — delete_strokes still reads Fixtures.docBytes.
        let sub = try await server.manager.subscribe(docId: "d")
        defer { Task { await server.manager.unsubscribe(docId: "d", token: sub.token) } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: nil)
        defer { Task { await device.close() } }

        let deleteCall = Task { try await client.callTool(
            name: "delete_strokes",
            arguments: ["docId": "d", "keys": .array([.string("seed123:1.0")])]) }

        // Wait until the request has reached the device — delete_strokes has
        // now read the doc and is stalled on the reply.
        var inFlight = false
        for _ in 0..<100 {
            if await device.receivedRequests.count == 1 { inFlight = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inFlight)
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docBytes == Fixtures.docBytes)

        // Competing write lands mid-round-trip.
        let competingBytes = Data(#"{"aaa001_thumbnailData":"","marker":"competing-delete"}"#.utf8)
        let competingOutcome = await server.manager.submit(
            docId: "d", opId: "competing-writer",
            payload: OpPayload(type: "fullDoc", data: competingBytes))
        guard case .accepted = competingOutcome else {
            Issue.record("expected the competing write to be accepted, got \(competingOutcome)")
            return
        }

        // The device's reply is computed against the stale doc it was handed.
        let staleResultBytes = Data(#"{"aaa001_thumbnailData":"","strokes":[]}"#.utf8)
        try await device.sendReply(
            requestId: received.requestId, docId: received.docId, bytes: staleResultBytes)

        let (content, isError) = try await deleteCall.value
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")

        // Nothing clobbered.
        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == competingBytes)

        await server.stop()
    }
}

@Suite struct ResourceURITests {
    @Test func parsesAllFourKinds() {
        #expect(ResourceURI("infsketch://docs") == .docsList)
        #expect(ResourceURI("infsketch://doc/abc") == .docSummary(docId: "abc"))
        #expect(ResourceURI("infsketch://doc/abc/raw") == .docRaw(docId: "abc"))
        #expect(ResourceURI("infsketch://doc/abc/frame") == .docFrame(docId: "abc"))
    }

    @Test func rejectsUnrecognizedShapes() {
        #expect(ResourceURI("infsketch://doc/abc/bogus") == nil)
        #expect(ResourceURI("bogus://doc/abc") == nil)
        #expect(ResourceURI("infsketch://doc/abc/raw/extra") == nil)
        #expect(ResourceURI("infsketch://") == nil)
        #expect(ResourceURI("infsketch://doc") == nil)
    }

    @Test func roundTripsUriString() {
        #expect(ResourceURI.docSummary(docId: "x").uriString == "infsketch://doc/x")
        #expect(ResourceURI.docRaw(docId: "x").uriString == "infsketch://doc/x/raw")
        #expect(ResourceURI.docFrame(docId: "x").uriString == "infsketch://doc/x/frame")
        #expect(ResourceURI.docsList.uriString == "infsketch://docs")
    }
}

#endif  // !os(Linux)
