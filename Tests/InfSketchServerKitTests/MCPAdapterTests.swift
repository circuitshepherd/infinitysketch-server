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

/// The `render_sketch` twin of `toolResultText` (Task 5): pulls the single
/// `.image` content item's base64 `data` + `mimeType` back out.
private func toolResultImage(_ content: [Tool.Content]) -> (data: String, mimeType: String)? {
    for item in content {
        if case .image(let data, let mimeType, _, _) = item { return (data, mimeType) }
    }
    return nil
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
        /// The `render_sketch` shape (Task 5): a PNG payload plus its
        /// metadata JSON, riding the reply's additive `meta` field.
        case bytesWithMeta(bytes: Data, meta: Data)
        case failure(String)
    }

    private let ws: URLSessionWebSocketTask
    private var pumpTask: Task<Void, Never>?
    private(set) var receivedRequests: [ReceivedRequest] = []
    private let autoReply: AutoReply?

    /// - Parameter capabilities: defaults to `["authorStrokes"]` (every
    ///   pre-existing stroke-op test). The styled-text contract tests
    ///   (styled_text branch) pass `["authorText"]` instead, to prove
    ///   `DeviceCommandBroker.requestStrokeOp`'s `capability:` argument
    ///   actually gates connection selection — not just that SOME device
    ///   answers.
    init(port: UInt16, autoReply: AutoReply?, capabilities: Set<String> = ["authorStrokes"]) async throws {
        self.autoReply = autoReply
        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        self.ws = ws
        ws.resume()
        try await ws.send(.string(ClientMessage.hello(protocolVersion: 1, capabilities: Array(capabilities)).jsonText()))
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
            case .bytesWithMeta(let bytes, let meta):
                try? await ws.send(.string(ClientMessage.strokeOpReply(
                    requestId: requestId, docId: docId, payload: .inline(bytes), meta: meta, failureReason: nil
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

    // Renamed from `listToolsContainsAllSeventeenTools` (Task 3,
    // agent-selection-control spec): select_all/select_elements/
    // set_reference_point/clear_selection joined the surface alongside M1's
    // get_selection/transform_selection.
    @Test func listToolsContainsAllTwentyOneTools() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        let names = Set(tools.map(\.name))
        #expect(names == [
            "add_text", "edit_text", "remove_text", "replace_doc", "create_doc",
            "draw_strokes", "delete_strokes", "list_strokes", "render_sketch",
            "get_strokes", "transform_strokes", "restyle_strokes", "reshape_strokes",
            "snap_points", "list_fonts", "get_selection", "transform_selection",
            "select_all", "select_elements", "set_reference_point", "clear_selection",
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

    // MARK: - Styled text (styled_text branch): list_fonts + styled add_text/edit_text
    //
    // add_text/edit_text decide plain-vs-styled FROM THE ARGUMENTS: none of
    // color/fontSize/bold/italic/family/spans present → the existing
    // server-side DocJSON path (byte-identical, see
    // plainAddTextStillUsesTheServerSidePathAndDoesNotRelay below); any of
    // them present → relay a device op via requestStrokeOp, exactly like the
    // Task 4 stroke-op tools, but gated on the "authorText" capability
    // instead of "authorStrokes" (DeviceCommandBroker.requestStrokeOp's new
    // `capability:` parameter). list_fonts always relays, is always
    // read-only.
    //
    // THE CROSS-REPO SPEC-ENVELOPE CONTRACT PIN for the new style keys
    // (silent-drop risk): the app decodes these envelopes with a plain
    // `Decodable` (`TextAuthoring.AddSpec`/`EditSpec`/`SpanSpec`, app repo)
    // that DROPS unknown keys silently — if this server ever stopped
    // relaying one of color/fontSize/bold/italic/family/spans, or relayed it
    // under a drifted name, nothing would fail: every agent would just keep
    // getting default-styled text forever. These tests assert the exact
    // relayed envelope key sets, string-literally, mirroring
    // drawStrokesSpecEnvelopeMatchesCanonicalShape's pattern for the
    // pre-existing stroke tools.

    @Test func listFontsIsReadOnlyAndRelaysListFonts() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let familiesJSON = Data(#"{"families":["Helvetica Neue","Menlo"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(familiesJSON), capabilities: ["authorText"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "list_fonts", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: familiesJSON, as: UTF8.self))
        #expect(toolResultText(content).contains("Helvetica Neue"))

        // No write: list_fonts never opens a session, so the doc's live seq
        // stays unset (-1) — same pattern as listStrokesReturnsFakeListingVerbatimWithNoWrite.
        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.seq == -1)

        let received = try #require(await device.receivedRequests.first)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "listFonts")
        #expect(Set(specJSON.keys) == ["op"])

        await server.stop()
    }

    @Test func styledAddTextRelaysTheStyleEnvelopeThroughTheDevice() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","placedTextsData":["new-text"]}"#.utf8)
        let metaBytes = Data(#"{"id":"ID-1"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: modifiedBytes, meta: metaBytes),
            capabilities: ["authorText"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "add_text",
            arguments: [
                "docId": "d", "text": "i_load", "x": 1, "y": 2,
                "color": "#FF453A", "fontSize": 12, "bold": true, "italic": false, "family": "Menlo",
            ])
        #expect(isError != true)
        #expect(toolResultText(content).contains("ID-1"), "add_text must surface the new text's id")

        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "addText")
        // Exact envelope: the canonical field names TextAuthoring.AddSpec
        // decodes, string-literally, no extras.
        #expect(Set(spec.keys) == ["op", "text", "x", "y", "color", "fontSize", "bold", "italic", "family"])
        #expect(spec["text"] as? String == "i_load")
        #expect(spec["x"] as? Double == 1)
        #expect(spec["y"] as? Double == 2)
        #expect(spec["color"] as? String == "#FF453A")
        #expect(spec["fontSize"] as? Double == 12)
        #expect(spec["bold"] as? Bool == true)
        #expect(spec["italic"] as? Bool == false)
        #expect(spec["family"] as? String == "Menlo")

        // The raw resource now reflects the fake's returned bytes.
        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == modifiedBytes)

        await server.stop()
    }

    @Test func addTextSpansRelaysThroughTheDevice() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorText"])
        defer { Task { await device.close() } }

        let spansArg: Value = .array([
            .object(["text": .string("R")]),
            .object(["text": .string("set"), "color": .string("#FF0000")]),
        ])
        let (_, isError) = try await client.callTool(
            name: "add_text",
            arguments: ["docId": "d", "x": 0, "y": 0, "spans": spansArg])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "addText")
        #expect(Set(spec.keys) == ["op", "x", "y", "spans"])
        let spans = try #require(spec["spans"] as? [[String: Any]])
        #expect(spans.count == 2)
        #expect(spans[0]["text"] as? String == "R")
        #expect(spans[0]["color"] == nil)
        #expect(spans[1]["text"] as? String == "set")
        #expect(spans[1]["color"] as? String == "#FF0000")

        await server.stop()
    }

    /// THE BYTE-IDENTICAL GUARANTEE: no style/spans argument present must
    /// take the unchanged server-side DocJSON path — no device round trip at
    /// all — exactly as before this branch existed. Asserted by the fake
    /// device's request count staying at zero, not merely by success.
    @Test func plainAddTextStillUsesTheServerSidePathAndDoesNotRelay() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // A capable device IS connected, so a wrongly-relayed plain call
        // would still "work" — the point is that it must never even ask.
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorText"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "add_text",
            arguments: ["docId": "d", "text": "plain", "x": 0, "y": 0])
        #expect(isError != true)
        #expect(toolResultText(content).hasPrefix("added "))
        #expect(await device.receivedRequests.isEmpty, "plain add_text must not relay to any device")

        await server.stop()
    }

    @Test func styledEditTextRelaysThroughTheDevice() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorText"])
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(
            name: "edit_text",
            arguments: ["docId": "d", "textId": "T-1", "color": "#FF453A"])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "editText")
        #expect(Set(spec.keys) == ["op", "textId", "color"])
        #expect(spec["textId"] as? String == "T-1")
        #expect(spec["color"] as? String == "#FF453A")

        await server.stop()
    }

    /// THE BYTE-IDENTICAL GUARANTEE for edit_text, mirroring
    /// plainAddTextStillUsesTheServerSidePathAndDoesNotRelay.
    @Test func plainEditTextStillUsesTheServerSidePathAndDoesNotRelay() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (addContent, _) = try await client.callTool(
            name: "add_text", arguments: ["docId": "d", "text": "before", "x": 1, "y": 2])
        let id = addedId(from: toolResultText(addContent))
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorText"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "edit_text",
            arguments: ["docId": "d", "textId": .string(id), "text": "after"])
        #expect(isError != true)
        #expect(await device.receivedRequests.isEmpty, "plain edit_text must not relay to any device")

        await server.stop()
    }

    /// Pins `requestStrokeOp`'s `capability: "authorText"` argument actually
    /// gates selection: a device that advertises ONLY "authorStrokes" (every
    /// existing stroke-op device) must NOT be picked for a styled text op —
    /// otherwise this whole capability split would be decorative.
    @Test func styledAddTextWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Default capabilities: ["authorStrokes"] only — no "authorText".
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "add_text",
            arguments: ["docId": "d", "x": 0, "y": 0, "color": "#FF0000"])
        #expect(isError == true)
        #expect(toolResultText(content) == "noDeviceAvailable")
        #expect(await device.receivedRequests.isEmpty)

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
    /// the CAS-guarded write tools, and its absence from `create_doc` /
    /// `list_strokes` (which are unaffected — see createDocIsUnaffected and
    /// listStrokesReturnsFakeListingVerbatimWithNoWrite), `render_sketch`
    /// (read-only — no write at all, so the CAS does not apply), and, since
    /// the stroke-editing spec (2026-07-14), `get_strokes` (also read-only).
    /// transform/restyle/reshape_strokes join the guarded side — they relay
    /// through the same `submitAndRespond(expectedBytes: docBytes)` tail as
    /// draw/delete_strokes.
    @Test func toolDescriptionsCarryTheCASRejectionSentenceOnlyWhereGuarded() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        let sentence = "Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry."
        for name in [
            "add_text", "edit_text", "remove_text", "replace_doc", "draw_strokes", "delete_strokes",
            "transform_strokes", "restyle_strokes", "reshape_strokes",
        ] {
            let tool = try #require(tools.first { $0.name == name })
            #expect(tool.description?.contains(sentence) == true, "\(name) missing the CAS sentence")
        }
        for name in ["create_doc", "list_strokes", "render_sketch", "get_strokes", "snap_points", "list_fonts"] {
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

    /// THE SILENT-FAILURE PIN for `smooth` (drawing-ergonomics spec,
    /// 2026-07-14): it's a NEW envelope key, and the app decodes with a
    /// plain `Decodable` that DROPS unknown keys silently — if this server
    /// ever stopped relaying it, or relayed it under a drifted name, nothing
    /// would fail; every agent would just keep getting rounded teardrops
    /// forever (see drawStrokesSpecEnvelopeMatchesCanonicalShape above for
    /// the same risk on the pre-existing fields). draw_strokes defaults
    /// `smooth` to false (polyline) — this only pins that an explicit
    /// `true` relays through untouched, key name and value both.
    @Test func drawStrokesRelaysTheSmoothFlag() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes))
        defer { Task { await device.close() } }

        let strokesArg: Value = .array([
            .object([
                "points": .array([.array([.double(0), .double(0)]), .array([.double(10), .double(10)])]),
                "smooth": .bool(true),
            ])
        ])
        let (_, isError) = try await client.callTool(
            name: "draw_strokes", arguments: ["docId": "d", "strokes": strokesArg])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        let strokes = try #require(envelope["strokes"] as? [[String: Any]])
        let stroke = try #require(strokes.first)
        #expect(Set(stroke.keys) == ["points", "smooth"])
        #expect(stroke["smooth"] as? Bool == true)

        await server.stop()
    }

    /// THE SILENT-FAILURE PIN for `draw_strokes`' returned KEYS (grid-snapping
    /// spec, 2026-07-14): `draw`'s op-spec reply carries the created strokes'
    /// composite keys in `out.meta` as `{"keys": […]}` (`StrokeAuthoring.draw`,
    /// app repo) — an agent needs those to revise EXACTLY what it just drew
    /// instead of re-finding it by bounding box, which is how a stroke once
    /// got clobbered. If this server stopped reading `out.meta` (or read the
    /// wrong key out of it), draw_strokes would keep reporting only "drew N
    /// stroke(s) at seq M" forever — no error, just silently useless.
    @Test func drawStrokesReportsTheKeysItCreated() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["new-stroke"]}"#.utf8)
        let metaBytes = Data(#"{"keys":["111-222","333-444"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: modifiedBytes, meta: metaBytes))
        defer { Task { await device.close() } }

        let strokesArg: Value = .array([
            .object(["points": .array([.array([.double(0), .double(0)]), .array([.double(1), .double(1)])])])
        ])
        let (content, isError) = try await client.callTool(
            name: "draw_strokes", arguments: ["docId": "d", "strokes": strokesArg])
        #expect(isError != true)
        let text = toolResultText(content)
        #expect(text.contains("111-222"), "an agent must be able to revise exactly what it just drew")
        #expect(text.contains("333-444"))

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

    // MARK: - render_sketch (Task 5, agent render/preview)
    //
    // Unlike every tool above, `render_sketch` is READ-ONLY: it never calls
    // `submitAndRespond`/`submitOpeningSession` and never passes
    // `expectedBytes` — a read never writes, so the write-CAS does not apply
    // (see toolDescriptionsCarryTheCASRejectionSentenceOnlyWhereGuarded,
    // updated above to include it in the unaffected set).

    @Test func renderSketchReturnsImageAndMetadataContent() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD, 0xBE, 0xEF])
        let metaBytes = Data(#"{"rect":[0,0,100,100],"scale":2.0}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: pngBytes, meta: metaBytes))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "render_sketch", arguments: ["docId": "d"])
        #expect(isError != true)

        let image = try #require(toolResultImage(content))
        #expect(image.mimeType == "image/png")
        #expect(Data(base64Encoded: image.data) == pngBytes)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        await server.stop()
    }

    /// THE read-only invariant (Global Constraints: "A test must prove the
    /// document is byte-identical afterwards"): a render must not open a
    /// session, assign a seq, or otherwise touch document state. Establish a
    /// live session at a KNOWN seq first (an accepted add_text), then prove
    /// render_sketch leaves it exactly where it was.
    @Test func renderSketchIsReadOnlySeqUnchanged() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (addContent, addIsError) = try await client.callTool(
            name: "add_text", arguments: ["docId": "d", "text": "hi", "x": 1, "y": 2])
        #expect(addIsError != true)
        #expect(toolResultText(addContent).contains("seq 1"))
        let seqBeforeRender = await server.manager.liveInfo()["d"]?.seq
        #expect(seqBeforeRender == 1)
        let rawBefore = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlobBefore = try #require(rawBefore[0].blob)

        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data([1, 2, 3]), meta: Data(#"{}"#.utf8)))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "render_sketch", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultImage(content) != nil)

        // The live seq is UNCHANGED — no session was opened, no write landed.
        #expect(await server.manager.liveInfo()["d"]?.seq == seqBeforeRender)
        // The document bytes are byte-identical to before the render too.
        let rawAfter = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlobAfter = try #require(rawAfter[0].blob)
        #expect(rawBlobAfter == rawBlobBefore)

        await server.stop()
    }

    @Test func renderSketchUnknownDocReturnsToolError() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device needs to connect — unknownDoc short-circuits before
        // any device round trip, mirroring every other tool's unknownDoc path.

        let (content, isError) = try await client.callTool(
            name: "render_sketch", arguments: ["docId": "ghost"])
        #expect(isError == true)
        #expect(toolResultText(content) == "unknownDoc")

        await server.stop()
    }

    @Test func renderSketchDeviceFailurePropagatesReason() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .failure("emptyRender"))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "render_sketch", arguments: ["docId": "d", "include": .string("none")])
        #expect(isError == true)
        #expect(toolResultText(content) == "deviceFailed: emptyRender")

        await server.stop()
    }

    @Test func renderSketchWithNoDeviceErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device connects in this test.

        let (content, isError) = try await client.callTool(
            name: "render_sketch", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content) == "noDeviceAvailable")

        await server.stop()
    }

    /// THE CROSS-REPO SPEC-ENVELOPE CONTRACT PIN for `render_sketch` (mirrors
    /// drawStrokesSpecEnvelopeMatchesCanonicalShape): the op-spec JSON this
    /// server builds is decoded app-side by `SketchRenderer.RenderSpec`
    /// (Task 3), a plain `Decodable` that silently drops unknown keys — so a
    /// field-name drift on either side would never fail loudly, it would
    /// just silently fall back to a default. This asserts the exact envelope
    /// shape with every Global-Constraints parameter name as a string
    /// literal, including the nested `strokes` item shape shared with
    /// `draw_strokes` (points/width/color/inkType):
    ///
    ///     {"op": "render", "include": …, "strokeKeys": […],
    ///      "strokes": [{"points": […], "width": …, "color": …, "inkType": …}],
    ///      "rect": […], "padding": …, "background": …, "axes": …, "maxPixels": …}
    @Test func renderSketchSpecEnvelopeMatchesCanonicalShape() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data([1]), meta: Data(#"{}"#.utf8)))
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
            name: "render_sketch",
            arguments: [
                "docId": "d",
                "include": .string("strokes"),
                "strokeKeys": .array([.string("seed123:1.0")]),
                "strokes": strokesArg,
                "rect": .array([.int(0), .int(0), .int(100), .int(200)]),
                "padding": .double(15),
                "background": .string("paper+grid"),
                "axes": .bool(true),
                "maxPixels": .int(2_000_000),
            ])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == [
            "op", "include", "strokeKeys", "strokes", "rect", "padding", "background", "axes", "maxPixels",
        ])
        #expect(envelope["op"] as? String == "render")
        #expect(envelope["include"] as? String == "strokes")
        #expect(envelope["strokeKeys"] as? [String] == ["seed123:1.0"])
        #expect(envelope["rect"] as? [Double] == [0, 0, 100, 200])
        #expect(envelope["padding"] as? Double == 15)
        #expect(envelope["background"] as? String == "paper+grid")
        #expect(envelope["axes"] as? Bool == true)
        #expect(envelope["maxPixels"] as? Double == 2_000_000)

        let strokes = try #require(envelope["strokes"] as? [[String: Any]])
        #expect(strokes.count == 1)
        let stroke = try #require(strokes.first)
        // The CANONICAL per-stroke field names, asserted string-literally —
        // the exact set draw_strokes's own envelope test pins.
        #expect(Set(stroke.keys) == ["points", "width", "color", "inkType"])
        let points = try #require(stroke["points"] as? [[Double]])
        #expect(points == [[1.5, 2.5], [30, 40]])
        #expect(stroke["width"] as? Double == 6.5)
        #expect(stroke["color"] as? String == "#FF00AA")
        #expect(stroke["inkType"] as? String == "marker")

        await server.stop()
    }

    /// A bare call with ONLY `docId` must omit every optional field from the
    /// envelope rather than sending them as explicit nulls — `render_sketch`
    /// with no arguments beyond docId is the common case (render the whole
    /// document, auto-fit, defaults everywhere), and `RenderSpec`'s optional
    /// `Decodable` fields treat "absent" and "null" the same, but an
    /// envelope that quietly grew `"rect": null` etc. for every unspecified
    /// param would be needless wire noise on every single call.
    @Test func renderSketchWithOnlyDocIdOmitsEveryOptionalField() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data([1]), meta: Data(#"{}"#.utf8)))
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(name: "render_sketch", arguments: ["docId": "d"])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op"])
        #expect(envelope["op"] as? String == "render")

        await server.stop()
    }

    @Test func renderSketchToolDescriptionStatesReadOnlyContract() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        let tool = try #require(tools.first { $0.name == "render_sketch" })
        let description = try #require(tool.description)
        #expect(description.contains("ephemeral"))
        #expect(description.contains("not") && description.contains("written"))
        #expect(description.contains("draw_strokes"))
        #expect(description.contains("visible"))
        #expect(description.contains("enabled"))
        #expect(description.contains("connected device"))

        await server.stop()
    }

    // MARK: - Stroke-editing tools (spec 2026-07-14):
    // get/transform/restyle/reshape_strokes
    //
    // These four mirror the Task 4 stroke-op tools exactly: a minimal op-spec
    // envelope (`{"op": "get"|"transform"|"restyle"|"reshape", …}`) relayed
    // via `broker.requestStrokeOp` alongside the document's current bytes.
    // `get_strokes` never writes (like `list_strokes`); the other three
    // write back through the same `submitAndRespond(expectedBytes: docBytes)`
    // CAS tail as draw/delete_strokes — `docBytes` is the EXACT bytes relayed
    // to the device, never a fresh re-read (Task 2, write CAS).

    /// A minimal reshape-spec `strokes` argument using the CANONICAL field
    /// names (key/points) — see strokeEditingSpecEnvelopesMatchTheCanonicalShape.
    private static let minimalReshapeStrokes: Value = .array([
        .object([
            "key": .string("seed123:1.0"),
            "points": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(10)])]),
        ])
    ])

    @Test func getStrokesReturnsDeviceListingVerbatimAndNeverWrites() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        // Establish a known live seq first (as renderSketchIsReadOnlySeqUnchanged
        // does) so "unchanged" below is a meaningful assertion, not a vacuous
        // -1 == -1.
        let (addContent, addIsError) = try await client.callTool(
            name: "add_text", arguments: ["docId": "d", "text": "hi", "x": 1, "y": 2])
        #expect(addIsError != true)
        #expect(toolResultText(addContent).contains("seq 1"))
        let seqBefore = await server.manager.liveInfo()["d"]?.seq
        #expect(seqBefore == 1)
        let rawBefore = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlobBefore = try #require(rawBefore[0].blob)

        let listingJSON = Data(#"[{"key":"seed123:1.0","points":[]}]"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(listingJSON))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "get_strokes",
            arguments: ["docId": "d", "keys": .array([.string("seed123:1.0")])])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: listingJSON, as: UTF8.self))

        // READ-ONLY: no session-affecting write — the same invariant
        // render_sketch has (renderSketchIsReadOnlySeqUnchanged).
        #expect(await server.manager.liveInfo()["d"]?.seq == seqBefore)
        let rawAfter = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlobAfter = try #require(rawAfter[0].blob)
        #expect(rawBlobAfter == rawBlobBefore)

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "get")

        await server.stop()
    }

    @Test func getStrokesWithoutMaxPointsOmitsItFromEnvelope() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data("[]".utf8)))
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(
            name: "get_strokes", arguments: ["docId": "d", "keys": .array([.string("k1")])])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "keys"])
        #expect(envelope["op"] as? String == "get")

        await server.stop()
    }

    /// Review fix (silent-drop finding): `maxPoints` used to be read via
    /// `Value.intValue`, which returns nil for a `.double` — an agent
    /// sending a non-integer number (or a string) had the key SILENTLY
    /// OMITTED from the envelope, vanishing its self-imposed budget guard
    /// with no error. Every other optional argument in these tools
    /// (transform/restyle's fields, render_sketch's maxPixels) is relayed
    /// VERBATIM regardless of its JSON shape — a bad type is the APP's
    /// decode to reject loudly (`GetSpec.maxPoints: Int?` failing with
    /// invalidSpec), not this server's to swallow. `500.5` (not a whole
    /// number) is used deliberately: unlike a whole-number double, it
    /// cannot re-encode as a bare Int token on the wire, so it survives the
    /// real HTTP JSON round-trip as a genuine `.double` and exercises the
    /// exact case `.intValue` used to drop.
    @Test func getStrokesRelaysMaxPointsVerbatimWhenNotAnIntToken() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data("[]".utf8)))
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(
            name: "get_strokes",
            arguments: ["docId": "d", "keys": .array([.string("k1")]), "maxPoints": .double(500.5)])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        // Present — reached the envelope — not silently dropped.
        #expect(Set(envelope.keys) == ["op", "keys", "maxPoints"])
        #expect(envelope["maxPoints"] as? Double == 500.5)

        await server.stop()
    }

    /// THE CROSS-REPO SPEC-ENVELOPE CONTRACT PIN for `snap_points` (grid-snapping
    /// spec, 2026-07-14) — mirrors drawStrokesSpecEnvelopeMatchesCanonicalShape:
    /// the op-spec JSON this server builds is decoded app-side by
    /// `StrokeAuthoring.SnapSpec`, a plain `Decodable` that silently drops
    /// unknown keys, so a field-name drift here (or simply forgetting to relay
    /// `gridIds`/`maxCandidates`) would never fail loudly — every agent would
    /// just keep snapping against every grid forever. Also proves the read-only
    /// contract: no session opened, no seq assigned, same evidence style as
    /// listStrokesReturnsFakeListingVerbatimWithNoWrite.
    @Test func snapPointsIsReadOnlyAndRelaysItsEnvelope() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let candidatesJSON = Data(#"[{"point":[103,92],"candidates":[]}]"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(candidatesJSON))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "snap_points", arguments: [
            "docId": "d",
            "points": .array([.array([.double(103), .double(92)])]),
            "gridIds": .array([.int(0)]),
            "maxCandidates": .int(5),
        ])
        #expect(isError != true)
        #expect(toolResultText(content).contains("candidates"))

        // No write: snap never opens a session, so the doc's live seq stays
        // unset (-1), exactly like listStrokesReturnsFakeListingVerbatimWithNoWrite.
        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.seq == -1)

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(specJSON.keys) == ["op", "points", "gridIds", "maxCandidates"])
        #expect(specJSON["op"] as? String == "snap")
        let points = try #require(specJSON["points"] as? [[Double]])
        #expect(points == [[103, 92]])
        #expect(specJSON["gridIds"] as? [Int] == [0])
        #expect(specJSON["maxCandidates"] as? Int == 5)

        await server.stop()
    }

    /// `snap_points` with only the required arguments: `gridIds` and
    /// `maxCandidates` must be OMITTED from the envelope, not sent as
    /// explicit nulls — the app-side default (64, a safety valve, not a
    /// working parameter — see `SnapCandidates`) only governs when the key
    /// is truly absent.
    @Test func snapPointsWithOnlyRequiredArgumentsOmitsOptionalKeys() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let candidatesJSON = Data(#"[{"point":[1,1],"candidates":[]}]"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(candidatesJSON))
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(name: "snap_points", arguments: [
            "docId": "d",
            "points": .array([.array([.double(1), .double(1)])]),
        ])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(specJSON.keys) == ["op", "points"])

        await server.stop()
    }

    @Test func snapPointsWithNoDeviceErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device connects in this test.

        let (content, isError) = try await client.callTool(name: "snap_points", arguments: [
            "docId": "d", "points": .array([.array([.double(1), .double(1)])]),
        ])
        #expect(isError == true)
        #expect(toolResultText(content) == "noDeviceAvailable")

        await server.stop()
    }

    @Test func snapPointsUnknownDocReturnsToolError() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device needs to connect — unknownDoc short-circuits before
        // any device round trip, mirroring renderSketchUnknownDocReturnsToolError.

        let (content, isError) = try await client.callTool(name: "snap_points", arguments: [
            "docId": "ghost", "points": .array([.array([.double(1), .double(1)])]),
        ])
        #expect(isError == true)
        #expect(toolResultText(content) == "unknownDoc")

        await server.stop()
    }

    @Test func snapPointsDeviceFailurePropagatesReason() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .failure("invalidSpec(maxCandidates must be > 0)"))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "snap_points", arguments: [
            "docId": "d", "points": .array([.array([.double(1), .double(1)])]),
            "maxCandidates": .int(0),
        ])
        #expect(isError == true)
        #expect(toolResultText(content) == "deviceFailed: invalidSpec(maxCandidates must be > 0)")

        await server.stop()
    }

    @Test func transformStrokesSendsSpecAndWritesReturnedBytes() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let transformedBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["moved"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(transformedBytes))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "transform_strokes", arguments: [
            "docId": "d",
            "keys": .array([.string("seed123:1.0")]),
            "translate": .array([.double(10), .double(20)]),
        ])
        #expect(isError != true)
        #expect(toolResultText(content) == "transformed 1 stroke(s) at seq 1")

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "transform")

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == transformedBytes)

        await server.stop()
    }

    /// Task 2 (write CAS) pin for transform_strokes, mirroring
    /// drawStrokesRejectsWhenTheDocumentChangedMidOp: the device is stalled
    /// until AFTER a competing write lands, so its (stale-computed) reply
    /// must be rejected rather than clobbering the competing write.
    @Test func transformStrokesRejectsWhenTheDocumentChangedMidOp() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let sub = try await server.manager.subscribe(docId: "d")
        defer { Task { await server.manager.unsubscribe(docId: "d", token: sub.token) } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: nil)
        defer { Task { await device.close() } }

        let call = Task { try await client.callTool(name: "transform_strokes", arguments: [
            "docId": "d", "keys": .array([.string("seed123:1.0")]), "rotate": .double(90),
        ]) }

        var inFlight = false
        for _ in 0..<100 {
            if await device.receivedRequests.count == 1 { inFlight = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inFlight)
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docBytes == Fixtures.docBytes)

        let competingBytes = Data(#"{"aaa001_thumbnailData":"","marker":"competing-transform"}"#.utf8)
        let competingOutcome = await server.manager.submit(
            docId: "d", opId: "competing-writer",
            payload: OpPayload(type: "fullDoc", data: competingBytes))
        guard case .accepted = competingOutcome else {
            Issue.record("expected the competing write to be accepted, got \(competingOutcome)")
            return
        }

        let staleResultBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["moved-stale"]}"#.utf8)
        try await device.sendReply(
            requestId: received.requestId, docId: received.docId, bytes: staleResultBytes)

        let (content, isError) = try await call.value
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == competingBytes)

        await server.stop()
    }

    /// THE SILENT-FAILURE PIN for `snapTo` (grid-snapping spec, 2026-07-14) —
    /// the twin of drawStrokesRelaysTheSmoothFlag: `snapTo` is a NEW envelope
    /// key decoded app-side by `StrokeEditing.TransformSpec.SnapTarget`, a
    /// plain `Decodable` that silently drops unknown keys. If this server
    /// stopped relaying it (or relayed it under a drifted key), nothing would
    /// fail — `snapToGrid` would keep snapping across EVERY enabled grid, so
    /// the finest (usually invisible) one would keep winning even though the
    /// caller named a specific grid. Asserts the nested object's OWN key set
    /// too (`gridId`/`familyIds`), not just its presence.
    @Test func transformStrokesRelaysSnapTo() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data("{}".utf8)))
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(name: "transform_strokes", arguments: [
            "docId": "d",
            "keys": .array([.string("1-2")]),
            "translate": .array([.double(0), .double(0)]),
            "snapToGrid": .bool(true),
            "snapTo": .object(["gridId": .int(0), "familyIds": .array([.int(1)])]),
        ])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "keys", "translate", "snapToGrid", "snapTo"])
        let snapTo = try #require(envelope["snapTo"] as? [String: Any])
        #expect(Set(snapTo.keys) == ["gridId", "familyIds"])
        #expect(snapTo["gridId"] as? Int == 0)
        #expect(snapTo["familyIds"] as? [Int] == [1])

        await server.stop()
    }

    @Test func restyleStrokesSendsSpecAndWritesReturnedBytes() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let restyledBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["restyled"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(restyledBytes))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "restyle_strokes", arguments: [
            "docId": "d",
            "keys": .array([.string("seed123:1.0")]),
            "color": .string("#FF0000"),
            "width": .double(8),
            "inkType": .string("marker"),
        ])
        #expect(isError != true)
        #expect(toolResultText(content) == "restyled 1 stroke(s) at seq 1")

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "restyle")

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == restyledBytes)

        await server.stop()
    }

    /// Task 2 (write CAS) pin for restyle_strokes — see the Task 2 review
    /// note on transform's twin above: each write call site needs its OWN
    /// pinning test, because flipping just one handler's `expectedBytes` to
    /// nil left the rest of a similarly-shaped suite green before.
    @Test func restyleStrokesRejectsWhenTheDocumentChangedMidOp() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let sub = try await server.manager.subscribe(docId: "d")
        defer { Task { await server.manager.unsubscribe(docId: "d", token: sub.token) } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: nil)
        defer { Task { await device.close() } }

        let call = Task { try await client.callTool(name: "restyle_strokes", arguments: [
            "docId": "d", "keys": .array([.string("seed123:1.0")]), "width": .double(9),
        ]) }

        var inFlight = false
        for _ in 0..<100 {
            if await device.receivedRequests.count == 1 { inFlight = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inFlight)
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docBytes == Fixtures.docBytes)

        let competingBytes = Data(#"{"aaa001_thumbnailData":"","marker":"competing-restyle"}"#.utf8)
        let competingOutcome = await server.manager.submit(
            docId: "d", opId: "competing-writer",
            payload: OpPayload(type: "fullDoc", data: competingBytes))
        guard case .accepted = competingOutcome else {
            Issue.record("expected the competing write to be accepted, got \(competingOutcome)")
            return
        }

        let staleResultBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["restyled-stale"]}"#.utf8)
        try await device.sendReply(
            requestId: received.requestId, docId: received.docId, bytes: staleResultBytes)

        let (content, isError) = try await call.value
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == competingBytes)

        await server.stop()
    }

    /// Also proves the shared point schema's rich-object form (with an
    /// optional attribute the bare-pair form can't carry) survives the relay
    /// verbatim, alongside a bare pair in the SAME strokes item.
    @Test func reshapeStrokesSendsSpecAndWritesReturnedBytes() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let reshapedBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["reshaped"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(reshapedBytes))
        defer { Task { await device.close() } }

        let strokesArg: Value = .array([
            .object([
                "key": .string("seed123:1.0"),
                "points": .array([
                    .array([.double(0), .double(0)]),
                    .object(["x": .double(10), "y": .double(20), "force": .double(0.5)]),
                ]),
            ])
        ])
        let (content, isError) = try await client.callTool(
            name: "reshape_strokes", arguments: ["docId": "d", "strokes": strokesArg])
        #expect(isError != true)
        #expect(toolResultText(content) == "reshaped 1 stroke(s) at seq 1")

        let received = try #require(await device.receivedRequests.first)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "reshape")
        let strokes = try #require(specJSON["strokes"] as? [[String: Any]])
        #expect(strokes.count == 1)
        #expect(strokes[0]["key"] as? String == "seed123:1.0")
        let points = try #require(strokes[0]["points"] as? [Any])
        #expect(points.count == 2)
        // The bare-pair form survives as a plain 2-element array…
        #expect(points[0] as? [Double] == [0, 0])
        // …and the rich-object form survives with its extra attribute intact.
        let richPoint = try #require(points[1] as? [String: Any])
        #expect(richPoint["x"] as? Double == 10)
        #expect(richPoint["y"] as? Double == 20)
        #expect(richPoint["force"] as? Double == 0.5)

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == reshapedBytes)

        await server.stop()
    }

    /// Task 2 (write CAS) pin for reshape_strokes — see the note on
    /// restyle's twin above.
    @Test func reshapeStrokesRejectsWhenTheDocumentChangedMidOp() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let sub = try await server.manager.subscribe(docId: "d")
        defer { Task { await server.manager.unsubscribe(docId: "d", token: sub.token) } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: nil)
        defer { Task { await device.close() } }

        let call = Task { try await client.callTool(
            name: "reshape_strokes",
            arguments: ["docId": "d", "strokes": Self.minimalReshapeStrokes]) }

        var inFlight = false
        for _ in 0..<100 {
            if await device.receivedRequests.count == 1 { inFlight = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inFlight)
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docBytes == Fixtures.docBytes)

        let competingBytes = Data(#"{"aaa001_thumbnailData":"","marker":"competing-reshape"}"#.utf8)
        let competingOutcome = await server.manager.submit(
            docId: "d", opId: "competing-writer",
            payload: OpPayload(type: "fullDoc", data: competingBytes))
        guard case .accepted = competingOutcome else {
            Issue.record("expected the competing write to be accepted, got \(competingOutcome)")
            return
        }

        let staleResultBytes = Data(#"{"aaa001_thumbnailData":"","strokes":["reshaped-stale"]}"#.utf8)
        try await device.sendReply(
            requestId: received.requestId, docId: received.docId, bytes: staleResultBytes)

        let (content, isError) = try await call.value
        #expect(isError == true)
        #expect(toolResultText(content) == "docChangedDuringOp")

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == competingBytes)

        await server.stop()
    }

    /// unknownDoc must short-circuit BEFORE any device round trip for all
    /// four tools — mirroring every other tool's unknownDoc path (e.g.
    /// renderSketchUnknownDocReturnsToolError). Review fix (test-strength
    /// finding): a device IS connected here (unlike the earlier version of
    /// this test, which connected none) so the ordering claim is proven by a
    /// REQUEST-COUNT assertion, not just the error STRING — a future
    /// reordering that queried a connected device before the unknownDoc
    /// guard would still produce the "unknownDoc" text (if the device's
    /// reply were, say, ignored) but WOULD show up as a non-zero
    /// `receivedRequests` count.
    @Test func strokeEditingToolsUnknownDocAreRejectedWithoutADeviceRoundTrip() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data("[]".utf8)))
        defer { Task { await device.close() } }

        let calls: [(String, [String: Value])] = [
            ("get_strokes", ["docId": "ghost", "keys": .array([.string("1-2")])]),
            ("transform_strokes", [
                "docId": "ghost", "keys": .array([.string("1-2")]),
                "translate": .array([.double(1), .double(1)]),
            ]),
            ("restyle_strokes", [
                "docId": "ghost", "keys": .array([.string("1-2")]), "width": .double(3),
            ]),
            ("reshape_strokes", ["docId": "ghost", "strokes": Self.minimalReshapeStrokes]),
        ]
        for (name, args) in calls {
            let (content, isError) = try await client.callTool(name: name, arguments: args)
            #expect(isError == true, "\(name)")
            #expect(toolResultText(content) == "unknownDoc", "\(name)")
        }

        // The ordering proof: a CONNECTED device that received ZERO requests.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// Device failures pass through VERBATIM as `deviceFailed: <reason>` for
    /// all four tools — the shared `strokeOpErrorResult` mapping, exercised
    /// here per call site rather than assumed from draw/delete's coverage.
    @Test func strokeEditingToolsPropagateDeviceFailureVerbatim() async throws {
        for name in ["get_strokes", "transform_strokes", "restyle_strokes", "reshape_strokes"] {
            let (server, port, task) = try await startServer()  // seeds doc "d"
            defer { task.cancel() }
            let client = try await connectedClient(port: port)
            defer { Task { await client.disconnect() } }
            let device = try await FakeStrokeOpDevice(
                port: port, autoReply: .failure("strokeNotFound: [ghost]"))
            defer { Task { await device.close() } }

            let args: [String: Value]
            switch name {
            case "get_strokes":
                args = ["docId": "d", "keys": .array([.string("ghost")])]
            case "transform_strokes":
                args = [
                    "docId": "d", "keys": .array([.string("ghost")]),
                    "translate": .array([.double(1), .double(1)]),
                ]
            case "restyle_strokes":
                args = ["docId": "d", "keys": .array([.string("ghost")]), "width": .double(9)]
            default:
                args = ["docId": "d", "strokes": Self.minimalReshapeStrokes]
            }

            let (content, isError) = try await client.callTool(name: name, arguments: args)
            #expect(isError == true, "\(name)")
            #expect(toolResultText(content) == "deviceFailed: strokeNotFound: [ghost]", "\(name)")

            await server.stop()
        }
    }

    /// THE CROSS-REPO SPEC-ENVELOPE CONTRACT PIN for the stroke-editing tools
    /// (mirrors drawStrokesSpecEnvelopeMatchesCanonicalShape /
    /// renderSketchSpecEnvelopeMatchesCanonicalShape): the app decodes these
    /// EXACT key names via a plain `Decodable` that silently drops unknown
    /// keys, so a field-name drift here would never fail loudly — the value
    /// would just silently fall back to a default, forever. Pins every op
    /// envelope's exact top-level key set (built with ONLY the fields the
    /// caller actually supplied) plus reshape's per-item key set.
    @Test func strokeEditingSpecEnvelopesMatchTheCanonicalShape() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data("{}".utf8)))
        defer { Task { await device.close() } }

        _ = try await client.callTool(name: "transform_strokes", arguments: [
            "docId": "d",
            "keys": .array([.string("1-2")]),
            "translate": .array([.double(1), .double(2)]),
            "scale": .array([.double(2), .double(2)]),
            "rotate": .double(45),
            "anchor": .array([.double(0), .double(0)]),
            "snapToGrid": .bool(true),
        ])
        var received = try #require(await device.receivedRequests.last)
        var envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == [
            "op", "keys", "translate", "scale", "rotate", "anchor", "snapToGrid",
        ])
        #expect(envelope["op"] as? String == "transform")

        _ = try await client.callTool(name: "restyle_strokes", arguments: [
            "docId": "d",
            "keys": .array([.string("1-2")]),
            "color": .string("#FF0000"),
            "width": .double(8),
            "inkType": .string("marker"),
        ])
        received = try #require(await device.receivedRequests.last)
        envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "keys", "color", "width", "inkType"])
        #expect(envelope["op"] as? String == "restyle")

        _ = try await client.callTool(name: "reshape_strokes", arguments: [
            "docId": "d",
            "strokes": .array([.object([
                "key": .string("1-2"),
                "points": .array([
                    .array([.double(0), .double(0)]),
                    .object(["x": .double(1), "y": .double(2), "force": .double(0.5)]),
                ]),
            ])]),
        ])
        received = try #require(await device.receivedRequests.last)
        envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "strokes"])
        #expect(envelope["op"] as? String == "reshape")
        let items = try #require(envelope["strokes"] as? [[String: Any]])
        #expect(Set(items[0].keys) == ["key", "points"])  // the app decodes exactly these

        _ = try await client.callTool(name: "get_strokes", arguments: [
            "docId": "d",
            "keys": .array([.string("1-2")]),
            "maxPoints": .int(500),
        ])
        received = try #require(await device.receivedRequests.last)
        envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "keys", "maxPoints"])
        #expect(envelope["op"] as? String == "get")

        await server.stop()
    }

    /// THE SILENT-FAILURE PIN for `smooth` on reshape_strokes
    /// (drawing-ergonomics spec, 2026-07-14) — the twin of
    /// drawStrokesRelaysTheSmoothFlag above. reshape_strokes defaults
    /// `smooth` the OPPOSITE way (true — points used verbatim), so this
    /// exercises an explicit `false` to prove the flag relays through
    /// untouched, key name and value both, alongside the existing key/points
    /// fields (mirrors strokeEditingSpecEnvelopesMatchTheCanonicalShape's
    /// per-item key-set style).
    @Test func reshapeStrokesRelaysTheSmoothFlag() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data("{}".utf8)))
        defer { Task { await device.close() } }

        let strokesArg: Value = .array([
            .object([
                "key": .string("1-2"),
                "points": .array([.array([.double(0), .double(0)]), .array([.double(10), .double(10)])]),
                "smooth": .bool(false),
            ])
        ])
        let (_, isError) = try await client.callTool(
            name: "reshape_strokes", arguments: ["docId": "d", "strokes": strokesArg])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        let items = try #require(envelope["strokes"] as? [[String: Any]])
        let item = try #require(items.first)
        #expect(Set(item.keys) == ["key", "points", "smooth"])
        #expect(item["smooth"] as? Bool == false)

        await server.stop()
    }

    /// Non-negotiable #4 (stroke-editing spec, 2026-07-14): draw_strokes,
    /// render_sketch's ephemeral strokes, and reshape_strokes must all
    /// advertise the IDENTICAL points-item schema — one shared `pointSchema`
    /// value, so drift between the three call sites is structurally
    /// impossible. Also proves it accepts BOTH the bare-pair and rich-object
    /// forms.
    @Test func pointSchemaIsSharedAcrossDrawRenderAndReshapeTools() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        func pointsItemsSchema(forToolNamed name: String) throws -> Value {
            let tool = try #require(tools.first { $0.name == name })
            var value = tool.inputSchema
            for key in ["properties", "strokes", "items", "properties", "points", "items"] {
                value = try #require(value.objectValue?[key])
            }
            return value
        }

        let drawPoints = try pointsItemsSchema(forToolNamed: "draw_strokes")
        let renderPoints = try pointsItemsSchema(forToolNamed: "render_sketch")
        let reshapePoints = try pointsItemsSchema(forToolNamed: "reshape_strokes")

        #expect(drawPoints == renderPoints)
        #expect(drawPoints == reshapePoints)

        let alternatives = try #require(drawPoints.objectValue?["oneOf"]?.arrayValue)
        #expect(alternatives.count == 2)
        let arrayForm = try #require(alternatives.first { $0.objectValue?["type"] == .string("array") })
        #expect(arrayForm.objectValue?["minItems"] == .int(2))
        #expect(arrayForm.objectValue?["maxItems"] == .int(2))
        let objectForm = try #require(alternatives.first { $0.objectValue?["type"] == .string("object") })
        #expect(objectForm.objectValue?["required"]?.arrayValue == [.string("x"), .string("y")])

        await server.stop()
    }

    /// Every stroke-accepting tool must ADVERTISE `smooth` in its per-stroke
    /// item schema (drawing-ergonomics spec, 2026-07-14) — draw_strokes and
    /// render_sketch's ephemeral strokes get it from the shared
    /// `strokeItemSchema` (see pointSchemaIsSharedAcrossDrawRenderAndReshapeTools
    /// above for that sharing), reshape_strokes from its own item schema
    /// (its default is the OPPOSITE of the other two, so it cannot reuse
    /// theirs). Schema is the only place a calling agent learns a tool's
    /// own default, so this is the one place a missing entry would be
    /// caught before an agent ever hit it in practice.
    @Test func everyStrokeAcceptingToolAdvertisesSmoothInItsSchema() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        for name in ["draw_strokes", "render_sketch", "reshape_strokes"] {
            let tool = try #require(tools.first { $0.name == name })
            var value = tool.inputSchema
            for key in ["properties", "strokes", "items", "properties", "smooth"] {
                value = try #require(value.objectValue?[key])
            }
            #expect(value.objectValue?["type"] == .string("boolean"))
        }

        await server.stop()
    }

    // MARK: - get_selection / transform_selection (agent-selection-control spec)
    //
    // Same shape as render_sketch's tests above: a `FakeStrokeOpDevice`
    // stands in for the connected device, `.bytesWithMeta` supplies the
    // reply's `meta` JSON (there is no image for these two tools — `.bytes`
    // is empty and ignored), and `device.receivedRequests[0].spec` is
    // decoded to pin the exact op-spec envelope shape relayed to the
    // device. The capability is "controlSelection" (NOT the default
    // "authorStrokes" every other `FakeStrokeOpDevice` test uses) — a
    // device hello'd with ONLY "controlSelection" successfully answering
    // proves BOTH halves of this feature at once: WSAdapter's registration
    // gate actually admits a controlSelection-only device to the broker
    // (without that, `connections` would be empty and every call below
    // would see noDeviceAvailable regardless of the capability match), and
    // `requestStrokeOp`'s `capability: "controlSelection"` argument
    // actually selects it.

    @Test func getSelectionRelaysToControlSelectionCapableDeviceAndReturnsMeta() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let metaBytes = Data(#"{"selectedKeys":["seed1:1.0"],"referencePoint":[10,20]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: metaBytes),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "get_selection", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op"])
        #expect(envelope["op"] as? String == "getSelection")

        await server.stop()
    }

    /// Mirrors `styledAddTextWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable`:
    /// a device that only advertises "authorStrokes" must NOT be picked for
    /// a selection-control op.
    @Test func getSelectionWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Default capabilities: ["authorStrokes"] only — no "controlSelection".
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data()))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "get_selection", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content) == "noDeviceAvailable")
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func getSelectionUnknownDocReturnsToolError() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device needs to connect — unknownDoc short-circuits before
        // any device round trip, mirroring every other tool's unknownDoc path.

        let (content, isError) = try await client.callTool(
            name: "get_selection", arguments: ["docId": "ghost"])
        #expect(isError == true)
        #expect(toolResultText(content) == "unknownDoc")

        await server.stop()
    }

    /// Pins the exact op-spec envelope `transform_selection` relays,
    /// including that `expect` — supplied here — rides along verbatim.
    @Test func transformSelectionRelaysOpsAndExpectInEnvelope() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let metaBytes = Data(#"{"selectedKeys":["seed1:1.0"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: metaBytes),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let opsArg: Value = .array([
            .object(["op": .string("rotate"), "degrees": .double(90)])
        ])
        let (content, isError) = try await client.callTool(
            name: "transform_selection",
            arguments: ["docId": "d", "ops": opsArg, "expect": .string("sig-123")])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ops", "expect"])
        #expect(envelope["op"] as? String == "transformSelection")
        #expect(envelope["expect"] as? String == "sig-123")
        let ops = try #require(envelope["ops"] as? [[String: Any]])
        #expect(ops.count == 1)
        #expect(ops.first?["op"] as? String == "rotate")
        #expect(ops.first?["degrees"] as? Double == 90)

        await server.stop()
    }

    /// A call that omits `expect` (the common case — an agent that never
    /// called `get_selection` first) must omit the field from the envelope
    /// rather than sending an explicit null, mirroring
    /// `renderSketchWithOnlyDocIdOmitsEveryOptionalField`.
    @Test func transformSelectionOmitsExpectWhenNotSupplied() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: Data(#"{}"#.utf8)),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let opsArg: Value = .array([.object(["op": .string("flipHorizontal")])])
        let (_, isError) = try await client.callTool(
            name: "transform_selection", arguments: ["docId": "d", "ops": opsArg])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ops"])

        await server.stop()
    }

    @Test func transformSelectionDeviceFailurePropagatesReason() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .failure("noReferencePoint"), capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let opsArg: Value = .array([.object(["op": .string("scale"), "factor": .double(2)])])
        let (content, isError) = try await client.callTool(
            name: "transform_selection", arguments: ["docId": "d", "ops": opsArg])
        #expect(isError == true)
        #expect(toolResultText(content) == "deviceFailed: noReferencePoint")

        await server.stop()
    }

    // MARK: - select_all / select_elements / set_reference_point / clear_selection (Task 3)
    //
    // Same shape as get_selection/transform_selection's tests above: a
    // `controlSelection`-capable `FakeStrokeOpDevice` stands in for the
    // connected device, `.bytesWithMeta` supplies the reply's `meta` JSON,
    // and `device.receivedRequests[0].spec` is decoded to pin the exact
    // op-spec envelope shape relayed to the device.

    @Test func selectAllRelaysToControlSelectionCapableDeviceAndReturnsMeta() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let metaBytes = Data(#"{"selectedKeys":["seed1:1.0"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: metaBytes),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "select_all", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op"])
        #expect(envelope["op"] as? String == "selectAll")

        await server.stop()
    }

    /// Pins the exact op-spec envelope `select_elements` relays: each of
    /// `strokeKeys`/`textIds`/`imageIds` supplied by the caller rides through
    /// verbatim; `imageIds` is omitted here to also prove an unsupplied
    /// array is left out of the envelope entirely.
    @Test func selectElementsRelaysProvidedArraysAndOmitsUnsuppliedOnes() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let metaBytes = Data(#"{"selectedKeys":["seed1:1.0"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: metaBytes),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "select_elements",
            arguments: [
                "docId": "d",
                "strokeKeys": .array([.string("seed1:1.0")]),
                "textIds": .array([.string("text-1"), .string("text-2")]),
            ])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "strokeKeys", "textIds"])
        #expect(envelope["op"] as? String == "selectElements")
        #expect(envelope["strokeKeys"] as? [String] == ["seed1:1.0"])
        #expect(envelope["textIds"] as? [String] == ["text-1", "text-2"])

        await server.stop()
    }

    /// Pins the exact op-spec envelope `set_reference_point` relays — `x`/`y`
    /// ride through as numbers — and that a missing `y` fails with the
    /// combined invalidArguments message rather than a per-field one, before
    /// any device round trip.
    @Test func setReferencePointRelaysXAndY() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let metaBytes = Data(#"{"referencePoint":[10,20]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: metaBytes),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "set_reference_point", arguments: ["docId": "d", "x": 10, "y": 20])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "x", "y"])
        #expect(envelope["op"] as? String == "setReferencePoint")
        #expect(envelope["x"] as? Double == 10)
        #expect(envelope["y"] as? Double == 20)

        await server.stop()
    }

    @Test func setReferencePointMissingYFailsBeforeAnyDeviceRoundTrip() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: Data(#"{}"#.utf8)),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "set_reference_point", arguments: ["docId": "d", "x": 10])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArguments: x and y are required")
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func clearSelectionRelaysToControlSelectionCapableDeviceAndReturnsMeta() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let metaBytes = Data(#"{"selectedKeys":[]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: metaBytes),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "clear_selection", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op"])
        #expect(envelope["op"] as? String == "clearSelection")

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
