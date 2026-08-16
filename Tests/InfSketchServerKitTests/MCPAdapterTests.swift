// Apple-platforms-only: the SDK's HTTPClientTransport does not support SSE without its
// `EventSource` dependency (documented in its source), so its Client cannot complete initialize
// against StatefulHTTPServerTransport there; the server-side mount + adapter are safe to compile
// everywhere — see task-1-report.md (gate resolution) and MCPSpikeTests.swift, which carries the
// identical gate. The flag is defined in Package.swift, beside the dependency that causes it.
#if MCP_SSE_CLIENT

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

/// A document's current bytes, read the way any client can — through the raw resource — so an
/// assertion about content needs no test-only hole in the server.
private func rawDocument(_ client: Client, _ docId: String) async throws -> Data {
    let contents = try await client.readResource(uri: "infsketch://doc/\(docId)/raw")
    for content in contents {
        if let blob = content.blob, let data = Data(base64Encoded: blob) { return data }
        if let text = content.text { return Data(text.utf8) }
    }
    return Data()
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

    func exists(docId: String) throws -> Bool {
        docId == self.docId
    }

    /// This fake exists to serve stale reads, not to be mutated; nothing here deletes.
    func delete(docId: String) throws { throw DocumentStoreError.notFound }
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

/// Seeds a second document via the opaque-bytes `replace_doc` tool (the same
/// tool `replaceDocForFreshIdStoresFile` etc. drive directly) — the
/// `merge_docs` relay tests (agent-merge-docs, Task 1) need TWO distinct
/// existing documents in the same running server, and `startServer` only
/// seeds one via its `DirectoryDocumentStore`.
private func seedDocViaReplaceDoc(_ client: Client, docId: String, bytes: Data) async throws {
    let (_, isError) = try await client.callTool(
        name: "replace_doc",
        arguments: ["docId": .string(docId), "bytes": .string(bytes.base64EncodedString())])
    #expect(isError != true)
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
        try await ws.send(.string(ClientMessage.hello(protocolVersion: WireProtocol.version, capabilities: ["createDoc"], deviceId: nil).jsonText()))
        let ack = try await Self.receiveOne(ws)
        guard ack == .helloAck(protocolVersion: WireProtocol.version) else {
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
    /// An APP-style push: straight up the WS `op` path, exactly as the mirror's settle-push
    /// arrives — NOT through any MCP tool. What `theAppsOwnPushIsNotUndoable` needs.
    func push(docId: String, bytes: Data) async throws {
        try await ws.send(.string(ClientMessage.subscribe(
            docId: docId, fromSeq: nil, createIfMissing: true).jsonText()))
        _ = try await Self.receiveOne(ws)   // the `subscribed` snapshot
        try await ws.send(.string(ClientMessage.op(
            docId: docId, opId: "app-push-\(UUID().uuidString)",
            payload: OpPayload(type: "fullDoc", data: bytes)).jsonText()))
    }

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
    /// `subscribeTo` makes the device a real SUBSCRIBER of that document, which is what "open"
    /// means to the server — a session with someone watching it, as opposed to the session any
    /// server-side tool opens merely by touching a document.
    init(port: UInt16, autoReply: AutoReply?, capabilities: Set<String> = ["authorStrokes"],
         subscribeTo: String? = nil) async throws {
        self.autoReply = autoReply
        let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        self.ws = ws
        ws.resume()
        try await ws.send(.string(ClientMessage.hello(protocolVersion: WireProtocol.version, capabilities: Array(capabilities), deviceId: nil).jsonText()))
        let ack = try await Self.receiveOne(ws)
        guard ack == .helloAck(protocolVersion: WireProtocol.version) else {
            throw DocumentStoreError.notFound  // any error type; an unexpected ack fails the test loudly
        }
        if let subscribeTo {
            try await ws.send(.string(ClientMessage.subscribe(
                docId: subscribeTo, fromSeq: nil, createIfMissing: false).jsonText()))
            _ = try await Self.receiveOne(ws)   // the `subscribed` snapshot
        }
        pumpTask = Task { [weak self] in await self?.pumpLoop() }
    }

    private func pumpLoop() async {
        while true {
            guard let message = try? await Self.receiveOne(ws) else { return }
            guard case .strokeOpRequest(let requestId, let docId, let payload, let spec, let kind) = message else { continue }
            // The real device does exactly this, in `ServerMirror.resolveAndAnswerStrokeOpRequest`:
            // an op-spec's bulk fields ride the chunked PAYLOAD and are spliced back into the spec
            // before any handler sees it. Resolving it here is what lets every assertion below
            // keep asserting the op CONTRACT rather than the transport's shape.
            var docBytes = payload.inlineData ?? Data()
            var resolvedSpec = spec
            if kind == OpSpecBundleWire.kind, let bundle = try? OpSpecBundle(encoded: docBytes) {
                docBytes = bundle.primary
                resolvedSpec = (try? bundle.specRestoringParts(into: spec)) ?? spec
            }
            receivedRequests.append(ReceivedRequest(
                requestId: requestId, docId: docId, docBytes: docBytes, spec: resolvedSpec))
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
    // get_selection/transform_selection. Milestone 2 (Task 3/Task 4) added
    // preview_selection. Milestone 3 (Task 7) added duplicate_selection.
    // agent-collision-resolution (Task 1) added list_collisions/
    // render_collision/resolve_collision, renaming this from
    // `listToolsContainsAllTwentyThreeTools`. add_image (Task 2) added
    // one more, renaming this from `listToolsContainsAllTwentySevenTools`.
    // remove_image (agent-remove-image) added one more, renaming this from
    // `listToolsContainsAllTwentyEightTools`. list_texts/list_images
    // (agent-list-elements, Task 2) added two more, renaming this from
    // `listToolsContainsAllTwentyNineTools`. list_grids/add_grid/update_grid/
    // remove_grid/set_grid_origin (agent-grid-authoring, Task 3) added five
    // more, renaming this from `listToolsContainsAllThirtyOneTools`.
    // reorder_grids (agent-grid-reorder, Task 2) added one more, renaming
    // this from `listToolsContainsAllThirtySixTools`. set_pinned
    // (agent-set-pinned, Task 2) added one more, renaming this from
    // `listToolsContainsAllThirtySevenTools`. set_paper
    // (agent-doc-appearance, Task 2) added one more, renaming this from
    // `listToolsContainsAllThirtyEightTools`. copy_elements
    // (agent-copy-elements, Task 2) added one more, renaming this from
    // `listToolsContainsAllThirtyNineTools`. reorder_elements
    // (agent-element-zorder, Task 2) added one more, renaming this from
    // `listToolsContainsAllFortyTools`. fetch_doc (M2c-3, Task 3) added one
    // more, renaming this from `listToolsContainsAllFortyOneTools`.
    // retire-collision-tools REMOVED the 3 inert collision tools
    // (list_collisions/render_collision/resolve_collision), renaming this
    // from `listToolsContainsAllFortyTwoTools`.
    // delete_doc (agent document delete) added one, renaming this from
    // `listToolsContainsAllThirtyNineTools`. restyle_selection + delete_selection (live-selection
    // editing) added two more, renaming this from `listToolsContainsAllFortyTools`.
    // list_open_docs (the "which document am I talking to?" listing) added one, renaming this
    // from `listToolsContainsAllFortyFourTools`. tag_elements + find_elements (durable element
    // names) added two more, renaming this from `listToolsContainsAllFortyFiveTools`. list_docs
    // ("what documents exist?", which no tool could answer) added one, renaming this from
    // `listToolsContainsAllFortySevenTools`. transform_elements (geometry for texts and images,
    // not only strokes) added one, renaming this from `listToolsContainsAllFortyEightTools`.
    // undo_last_edit (an agent taking back its own write) added one, renaming this from
    // `listToolsContainsAllFortyNineTools`. fill_region (one call for a solid area) added one,
    // renaming this from `listToolsContainsAllFiftyTools`. draw_dots (a solid round dot as one
    // stroke) added one, renaming this from `listToolsContainsAllFiftyOneTools`. list_tags (what
    // tags a document has, so an agent can pick up earlier work) added one, renaming this from
    // `listToolsContainsAllFiftyTwoTools`.
    @Test func listToolsContainsAllFiftyThreeTools() async throws {
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
            "snap_points", "list_fonts", "list_docs", "list_open_docs", "tag_elements", "find_elements",
            "transform_elements", "undo_last_edit", "fill_region", "draw_dots", "list_tags",
            "get_selection", "transform_selection",
            "select_all", "select_elements", "set_reference_point", "clear_selection",
            "preview_selection", "duplicate_selection",
            "merge_docs",
            "add_image", "remove_image", "list_texts", "list_images",
            "list_grids", "add_grid", "update_grid", "remove_grid", "set_grid_origin",
            "reorder_grids", "set_pinned", "set_paper", "copy_elements", "reorder_elements",
            "fetch_doc", "delete_doc", "restyle_selection", "delete_selection", "draw_selection", "get_tool",
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
            arguments: ["docId": "d", "text": "hello agent", "canvasX": 10, "canvasY": 20, "pinned": false])
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
            arguments: ["docId": "d", "text": "hi", "canvasX": .string("40000"), "canvasY": 20])
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
            arguments: ["docId": "ghost", "text": "hi", "canvasX": 1, "canvasY": 2])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

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
            name: "add_text", arguments: ["docId": "d", "text": "hi", "canvasX": 1, "canvasY": 2])
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
            name: "add_text", arguments: ["docId": "d", "text": "before", "canvasX": 1, "canvasY": 2])
        #expect(addIsError != true)
        let id = addedId(from: toolResultText(addContent))

        let (editContent, editIsError) = try await client.callTool(
            name: "edit_text",
            arguments: ["docId": "d", "textId": .string(id), "text": "after", "canvasX": 5, "canvasY": 6])
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
                "docId": "d", "text": "i_load", "canvasX": 1, "canvasY": 2,
                "color": "#FF453A", "fontSize": 12, "bold": true, "italic": false, "family": "Menlo",
            ])
        #expect(isError != true)
        #expect(toolResultText(content).contains("ID-1"), "add_text must surface the new text's id")

        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "addText")
        // Exact envelope: the canonical field names TextAuthoring.AddSpec
        // decodes, string-literally, no extras.
        #expect(Set(spec.keys) == ["op", "text", "canvasX", "canvasY", "color", "fontSize", "bold", "italic", "family"])
        #expect(spec["text"] as? String == "i_load")
        #expect(spec["canvasX"] as? Double == 1)
        #expect(spec["canvasY"] as? Double == 2)
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
            arguments: ["docId": "d", "canvasX": 0, "canvasY": 0, "spans": spansArg])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "addText")
        #expect(Set(spec.keys) == ["op", "canvasX", "canvasY", "spans"])
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
            arguments: ["docId": "d", "text": "plain", "canvasX": 0, "canvasY": 0])
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
            name: "add_text", arguments: ["docId": "d", "text": "before", "canvasX": 1, "canvasY": 2])
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
            arguments: ["docId": "d", "canvasX": 0, "canvasY": 0, "color": "#FF0000"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func removeTextRemovesEntryById() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (addContent, _) = try await client.callTool(
            name: "add_text", arguments: ["docId": "d", "text": "gone soon", "canvasX": 1, "canvasY": 2])
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

    // MARK: - remove_image (agent-remove-image)
    //
    // Entirely server-side (pure JSON record-filtering, no device, no
    // capability) -- mirrors remove_text almost exactly. Since there's no
    // device-relayed `add_image` harness helper that lands a placed image
    // server-side without a device round trip, these seed the doc's raw
    // bytes directly (JSONSerialization, as in DocJSONTests) via
    // `startServer(bytes:)`, the same seeding seam other tool tests use.

    private static let seededImageDocBytes = Data(#"""
        {"aaa001_thumbnailData":"",
         "placedImagesData":[{"id":"IMG-X","pastedImageDataId":"B1","canvasRect":[[0,0],[10,10]]}],
         "pastedImagesData":[{"id":"B1","data":"AAAA"}]}
        """#.utf8)

    @Test func removeImageRemovesFromDocAndReplies() async throws {
        let (server, port, task) = try await startServer(bytes: Self.seededImageDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "remove_image", arguments: ["docId": "d", "imageId": "IMG-X"])
        #expect(isError != true)
        #expect(toolResultText(content) == "removed IMG-X at seq 1")

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        let rawBytes = try #require(Data(base64Encoded: rawBlob))
        let obj = try JSONSerialization.jsonObject(with: rawBytes) as! [String: Any]
        #expect((obj["placedImagesData"] as! [Any]).isEmpty)
        // The blob is orphan-pruned too (IMG-X was its only referencer).
        #expect((obj["pastedImagesData"] as! [Any]).isEmpty)

        await server.stop()
    }

    @Test func removeImageUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer(bytes: Self.seededImageDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "remove_image", arguments: ["docId": "ghost", "imageId": "IMG-X"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        await server.stop()
    }

    @Test func removeImageUnknownIdSurfacesImageNotFound() async throws {
        let (server, port, task) = try await startServer(bytes: Self.seededImageDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "remove_image", arguments: ["docId": "d", "imageId": "NOPE"])
        #expect(isError == true)
        #expect(toolResultText(content) == "imageNotFound")

        await server.stop()
    }

    // MARK: - set_pinned (agent-set-pinned)
    //
    // Entirely server-side (pure JSON record-filtering via DocJSON.setPinned,
    // no device, no capability) -- mirrors remove_image's shape almost
    // exactly. Seeds a doc with one placed text + one placed image (both
    // pinned:false) directly via `startServer(bytes:)`, the same seeding seam
    // `removeImageRemovesFromDocAndReplies` etc. use.

    private static let pinDocBytes = Data(#"""
        {"aaa001_thumbnailData":"",
         "placedTextsData":[{"id":"TTTTTTTT-0000-0000-0000-000000000001","text":["Hi",{}],"canvasRect":[[10,20],[1,1]],"transform":{"a":1,"b":0,"c":0,"d":1,"tx":0,"ty":0},"opacity":1,"pinned":false}],
         "placedImagesData":[{"id":"IIIIIIII-0000-0000-0000-000000000001","pastedImageDataId":"PPPPPPPP-0000-0000-0000-000000000001","canvasRect":[[0,0],[100,100]],"transform":{"a":1,"b":0,"c":0,"d":1,"tx":0,"ty":0},"opacity":1,"pinned":false}]}
        """#.utf8)

    @Test func setPinnedFlipsAndReportsCount() async throws {
        let (server, port, task) = try await startServer(bytes: Self.pinDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "set_pinned",
            arguments: ["docId": "d", "ids": ["IIIIIIII-0000-0000-0000-000000000001"], "pinned": true])
        #expect(isError != true)
        #expect(toolResultText(content).contains("set pinned=true on 1 element(s) in d"))

        let rawContents = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlob = try #require(rawContents[0].blob)
        let rawBytes = try #require(Data(base64Encoded: rawBlob))
        let obj = try JSONSerialization.jsonObject(with: rawBytes) as! [String: Any]
        let image = (obj["placedImagesData"] as! [[String: Any]])[0]
        #expect(image["pinned"] as? Bool == true)

        await server.stop()
    }

    @Test func setPinnedUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer(bytes: Self.pinDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "set_pinned", arguments: ["docId": "ghost", "ids": ["x"], "pinned": true])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        await server.stop()
    }

    @Test func setPinnedUnknownElementErrors() async throws {
        let (server, port, task) = try await startServer(bytes: Self.pinDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "set_pinned", arguments: ["docId": "d", "ids": ["nope"], "pinned": true])
        #expect(isError == true)
        #expect(toolResultText(content) == "elementNotFound")

        await server.stop()
    }

    @Test func setPinnedEmptyIdsErrors() async throws {
        let (server, port, task) = try await startServer(bytes: Self.pinDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "set_pinned", arguments: ["docId": "d", "ids": [], "pinned": true])
        #expect(isError == true)   // nonEmptyStringArrayArg rejects [] -> invalidArgument: ids
        #expect(toolResultText(content).contains("ids"))

        await server.stop()
    }

    /// An ABSENT `pinned` is a hard error (`missingArgument: pinned`), never a
    /// silent `false` — this is why `callSetPinned` uses `requiredBoolArg`, not
    /// the defaulting `boolArg`. Pins that load-bearing choice against a
    /// regression that swapped the reader (which every other set_pinned test
    /// would still pass).
    @Test func setPinnedMissingPinnedErrors() async throws {
        let (server, port, task) = try await startServer(bytes: Self.pinDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "set_pinned",
            arguments: ["docId": "d", "ids": ["IIIIIIII-0000-0000-0000-000000000001"]])
        #expect(isError == true)
        #expect(toolResultText(content) == "missingArgument: pinned")

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

    /// Task 2 origin, updated for Task 3: the missing-doc branch is no
    /// longer unconditional (`expectedBytes: nil`) — it now expects
    /// `.absent` (there's nothing to compare BYTES against, but the doc
    /// genuinely must not already exist), with `createIfMissing: true`
    /// unchanged. A fresh docId must still create successfully.
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

    /// Task 3: proves `replace_doc`'s missing-doc branch genuinely landed
    /// via `.absent` (not silently still unconditional) — a doc it just
    /// created is visible to a SUBSEQUENT `create_doc` call for the same
    /// docId, which must see it exists and reject before ever contacting a
    /// device (no fake device is even connected in this test, so a call
    /// that reached the device would hang/fail loudly rather than produce
    /// `docExists`). This is the cross-tool twin of
    /// `createDocTwiceOnSameFreshIdSecondSeesDocExists` above, and — like
    /// that test — is a deterministic SEQUENTIAL check; the atomicity of
    /// `.absent` under genuine concurrency is proven independently by
    /// `AbsentCreateRaceTests.concurrentAbsentCreatesOnlyOneWins`
    /// (`WriteExpectationEnforcementTests.swift`, Task 2), which races two
    /// `SessionManager.submitOpeningSession(..., expectation: .absent)`
    /// calls directly — the exact code path both `replace_doc`'s
    /// missing-doc branch and `create_doc` now share.
    @Test func replaceDocCreatesAbsentDocThenCreateDocSeesItExists() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let freshBytes = Data(#"{"aaa001_thumbnailData":"","marker":"via-replace"}"#.utf8)
        let (createContent, createIsError) = try await client.callTool(
            name: "replace_doc",
            arguments: ["docId": "replace-then-create", "bytes": .string(freshBytes.base64EncodedString())])
        #expect(createIsError != true)
        #expect(toolResultText(createContent).contains("seq 1"))

        let (raceContent, raceIsError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "replace-then-create"])
        #expect(raceIsError == true)
        #expect(toolResultText(raceContent) == "docExists")

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
                            arguments: ["docId": "d", "text": "race \(i)", "canvasX": 1, "canvasY": 2])
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
            arguments: ["docId": "d", "text": "from another session", "canvasX": 3, "canvasY": 4])
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

    /// Task 2 (write CAS) origin, still true after Task 3's `.absent` flip:
    /// `create_doc`'s PUBLISHED shape is unaffected — there is no prior
    /// content to compare BYTES against, so `docExists` (now the atomic
    /// `.absent` guard, not just the fast pre-check) remains the race's only
    /// meaningful shape here. Pin both halves: no `docChangedDuringOp`
    /// sentence in its description (unlike the six CAS-guarded tools), and
    /// creation still succeeds normally. See
    /// `createDocTwiceOnSameFreshIdSecondSeesDocExists` below for the new
    /// half of the contract Task 3 adds on top of this.
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

    /// Task 3: end-to-end proof that `create_doc`'s write genuinely uses
    /// `.absent` now, not just the fast `manager.currentBytes(docId:) != nil`
    /// pre-check above — this exercises the FULL lifecycle on a brand-new
    /// docId (unlike `createDocOnExistingDocErrors`, which reuses the
    /// server's pre-seeded "d"): first call creates it via a real device
    /// round trip; the second sees it already exists and is rejected before
    /// ever contacting the device again. The docExists here could in
    /// principle be produced by the pre-check alone (both calls are
    /// sequential, not concurrent) — the atomicity of the underlying
    /// `.absent` guard under GENUINE concurrency is proven independently, at
    /// the `SessionManager` layer, by
    /// `AbsentCreateRaceTests.concurrentAbsentCreatesOnlyOneWins`
    /// (`WriteExpectationEnforcementTests.swift`, Task 2) — the same
    /// `submitOpeningSession(..., expectation: .absent)` call this tool's
    /// `submitAndRespond` now makes.
    @Test func createDocTwiceOnSameFreshIdSecondSeesDocExists() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: Fixtures.docBytes)
        defer { Task { await device.close() } }

        let (firstContent, firstIsError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "twice-fresh"])
        #expect(firstIsError != true)
        #expect(toolResultText(firstContent).contains("seq 1"))

        let (secondContent, secondIsError) = try await client.callTool(
            name: "create_doc", arguments: ["docId": "twice-fresh"])
        #expect(secondIsError == true)
        #expect(toolResultText(secondContent) == "docExists")

        // Only the first create ever reached the device — the second was
        // rejected by the fast pre-check before any second createDocRequest.
        #expect(await device.receivedRequests.count == 1)

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
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))

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
        .object(["canvasPoints": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(10)])])])
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

    // MARK: - list_texts / list_images (Task 2, agent-list-elements spec) —
    // mirror list_strokes exactly: relay a minimal `{op:...}` envelope via
    // requestStrokeOp and pass the device's reply bytes through verbatim as
    // text, never writing to the document. Only the relayed op string and
    // the capability used to pick a connection differ (authorText /
    // authorImage instead of the stroke tools' default authorStrokes) —
    // mirroring the styled-text tools' capability split
    // (styledAddTextRelaysTheStyleEnvelopeThroughTheDevice /
    // styledAddTextWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable).

    @Test func listTextsRelaysAndPassesReplyThrough() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let listingJSON = Data(#"[{"id":"T1","text":"hi","bounds":[0,0,10,10],"pinned":false,"opacity":1}]"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(listingJSON), capabilities: ["authorText"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_texts", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: listingJSON, as: UTF8.self))

        // No write: list_texts never opens a session, same as list_strokes.
        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.seq == -1)

        // The fake (hello'd with ONLY "authorText") received the request —
        // proving requestStrokeOp's capability argument was "authorText",
        // not the stroke tools' default "authorStrokes".
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "listTexts")
        #expect(Set(specJSON.keys) == ["op"])

        await server.stop()
    }

    /// Pins the capability gate: a device advertising ONLY "authorStrokes"
    /// (no "authorText") must NOT be selected for list_texts — mirrors
    /// styledAddTextWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable.
    @Test func listTextsWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Default capabilities: ["authorStrokes"] only — no "authorText".
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_texts", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip — mirroring `mergeDocsIntoRejectsExistingNameWithoutWakingDevice`.
    @Test func listTextsUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorText"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_texts", arguments: ["docId": "ghost"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        // Fast-fail: the device must never be contacted for an unknown doc.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func listImagesRelaysWithAuthorImageCapability() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let listingJSON = Data(#"[{"id":"IMG1","bounds":[0,0,20,20],"pinned":false,"opacity":1}]"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(listingJSON), capabilities: ["authorImage"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_images", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: listingJSON, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "listImages")
        #expect(Set(specJSON.keys) == ["op"])

        await server.stop()
    }

    /// Pins the capability gate: a device advertising ONLY "authorStrokes"
    /// (no "authorImage") must NOT be selected for list_images.
    @Test func listImagesWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Default capabilities: ["authorStrokes"] only — no "authorImage".
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_images", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip — mirroring `mergeDocsIntoRejectsExistingNameWithoutWakingDevice`.
    @Test func listImagesUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorImage"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_images", arguments: ["docId": "ghost"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        // Fast-fail: the device must never be contacted for an unknown doc.
        #expect(await device.receivedRequests.isEmpty)

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
                "canvasPoints": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(10)])]),
                "stampWidth": .int(4),
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
    ///     {"op": "draw", "strokes": [{"canvasPoints": [[x,y],…],
    ///                                 "stampWidth": …, "color": …, "inkType": …}]}
    ///
    /// Task 5's own StrokeSpec decode tests must decode a fixture using
    /// EXACTLY these field names (binding rider carried by the plan). If
    /// this test ever needs changing, both repos change in lockstep.
    /// THE CROSS-REPO REPLY-META LOCK — the mirror image of
    /// `drawStrokesSpecEnvelopeMatchesCanonicalShape`, which locks the shape travelling
    /// server -> device. This locks the shape coming BACK.
    ///
    /// That direction had no guard, and it bit: adding `resolvedTool` to the device's draw meta
    /// silently killed the `ids:` line, because this decoder was `[String: [String]]` — a shape
    /// that cannot represent an object — and its own comment permits degrading rather than
    /// throwing. Both suites stayed green, because each repo tests against a fake of the other.
    ///
    /// The fixture below is the app's real `DrawMeta` shape, duplicated verbatim (the app half is
    /// `drawMetaMatchesTheServersCanonicalReplyShape` in StrokeAuthoringTests). Non-vacuous: a
    /// renamed or re-typed key drops its line from the summary and fails an assertion here.
    @Test func drawReplyMetaMatchesCanonicalShape() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let canonicalMeta = Data(#"""
        {"keys":["111-222.5"],"resolvedTool":{"inkType":"marker","stampWidth":19.5,"color":"#12AB34FF"}}
        """#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Fixtures.docBytes, meta: canonicalMeta))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "draw_strokes",
            arguments: ["docId": "d", "strokes": .array([.object([
                "canvasPoints": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(0)])])
            ])])])
        #expect(isError != true)
        let text = toolResultText(content)

        // "keys" -> the ids line. This is the one that silently vanished.
        #expect(text.contains("ids: 111-222.5"), "the keys field must still reach the reply: \(text)")
        // "resolvedTool" -> what an omitted colour/width/inkType inherited from the user's picker.
        #expect(text.contains("marker"), "resolvedTool.inkType must reach the reply: \(text)")
        #expect(text.contains("19.5"), "resolvedTool.width must reach the reply: \(text)")
        #expect(text.contains("#12AB34FF"), "resolvedTool.color must reach the reply: \(text)")

        await server.stop()
    }

    @Test func drawStrokesSpecEnvelopeMatchesCanonicalShape() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes))
        defer { Task { await device.close() } }

        let strokesArg: Value = .array([
            .object([
                "canvasPoints": .array([
                    .array([.double(1.5), .double(2.5)]),
                    .array([.int(30), .int(40)]),
                ]),
                "stampWidth": .double(6.5),
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
        #expect(Set(stroke.keys) == ["canvasPoints", "stampWidth", "color", "inkType"])
        let points = try #require(stroke["canvasPoints"] as? [[Double]])
        #expect(points == [[1.5, 2.5], [30, 40]])
        #expect(stroke["stampWidth"] as? Double == 6.5)
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
                "canvasPoints": .array([.array([.double(0), .double(0)]), .array([.double(10), .double(10)])]),
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
        #expect(Set(stroke.keys) == ["canvasPoints", "smooth"])
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
            .object(["canvasPoints": .array([.array([.double(0), .double(0)]), .array([.double(1), .double(1)])])])
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
            name: "delete_strokes", arguments: ["docId": "d", "ids": .array([.string("k9")])])
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
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))

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
            name: "delete_strokes", arguments: ["docId": "d", "ids": .array([.string("k1")])])
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
            arguments: ["docId": "d", "ids": .array([.string("seed123:1.0")])]) }

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
        let metaBytes = Data(#"{"canvasRect":[0,0,100,100],"scale":2.0}"#.utf8)
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
            name: "add_text", arguments: ["docId": "d", "text": "hi", "canvasX": 1, "canvasY": 2])
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
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

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
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))

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
    ///     {"op": "render", "include": …, "strokeIds": […],
    ///      "strokes": [{"canvasPoints": […], "stampWidth": …, "color": …, "inkType": …}],
    ///      "canvasRect": […], "padding": …, "background": …, "axes": …, "maxPixels": …}
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
                "canvasPoints": .array([
                    .array([.double(1.5), .double(2.5)]),
                    .array([.int(30), .int(40)]),
                ]),
                "stampWidth": .double(6.5),
                "color": .string("#FF00AA"),
                "inkType": .string("marker"),
            ])
        ])
        let (_, isError) = try await client.callTool(
            name: "render_sketch",
            arguments: [
                "docId": "d",
                "include": .string("strokes"),
                "strokeIds": .array([.string("seed123:1.0")]),
                "strokes": strokesArg,
                "canvasRect": .array([.int(0), .int(0), .int(100), .int(200)]),
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
            "op", "include", "strokeIds", "strokes", "canvasRect", "padding", "background", "axes", "maxPixels",
        ])
        #expect(envelope["op"] as? String == "render")
        #expect(envelope["include"] as? String == "strokes")
        #expect(envelope["strokeIds"] as? [String] == ["seed123:1.0"])
        #expect(envelope["canvasRect"] as? [Double] == [0, 0, 100, 200])
        #expect(envelope["padding"] as? Double == 15)
        #expect(envelope["background"] as? String == "paper+grid")
        #expect(envelope["axes"] as? Bool == true)
        #expect(envelope["maxPixels"] as? Double == 2_000_000)

        let strokes = try #require(envelope["strokes"] as? [[String: Any]])
        #expect(strokes.count == 1)
        let stroke = try #require(strokes.first)
        // The CANONICAL per-stroke field names, asserted string-literally —
        // the exact set draw_strokes's own envelope test pins.
        #expect(Set(stroke.keys) == ["canvasPoints", "stampWidth", "color", "inkType"])
        let points = try #require(stroke["canvasPoints"] as? [[Double]])
        #expect(points == [[1.5, 2.5], [30, 40]])
        #expect(stroke["stampWidth"] as? Double == 6.5)
        #expect(stroke["color"] as? String == "#FF00AA")
        #expect(stroke["inkType"] as? String == "marker")

        await server.stop()
    }

    /// A bare call with ONLY `docId` must omit every optional field from the
    /// envelope rather than sending them as explicit nulls — `render_sketch`
    /// with no arguments beyond docId is the common case (render the whole
    /// document, auto-fit, defaults everywhere), and `RenderSpec`'s optional
    /// `Decodable` fields treat "absent" and "null" the same, but an
    /// envelope that quietly grew `"canvasRect": null` etc. for every unspecified
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
    /// names (id/points) — see strokeEditingSpecEnvelopesMatchTheCanonicalShape.
    private static let minimalReshapeStrokes: Value = .array([
        .object([
            "id": .string("seed123:1.0"),
            "canvasPoints": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(10)])]),
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
            name: "add_text", arguments: ["docId": "d", "text": "hi", "canvasX": 1, "canvasY": 2])
        #expect(addIsError != true)
        #expect(toolResultText(addContent).contains("seq 1"))
        let seqBefore = await server.manager.liveInfo()["d"]?.seq
        #expect(seqBefore == 1)
        let rawBefore = try await client.readResource(uri: "infsketch://doc/d/raw")
        let rawBlobBefore = try #require(rawBefore[0].blob)

        let listingJSON = Data(#"[{"key":"seed123:1.0","canvasPoints":[]}]"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(listingJSON))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "get_strokes",
            arguments: ["docId": "d", "ids": .array([.string("seed123:1.0")])])
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
            name: "get_strokes", arguments: ["docId": "d", "ids": .array([.string("k1")])])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ids"])
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
            arguments: ["docId": "d", "ids": .array([.string("k1")]), "maxPoints": .double(500.5)])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        // Present — reached the envelope — not silently dropped.
        #expect(Set(envelope.keys) == ["op", "ids", "maxPoints"])
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
            "canvasPoints": .array([.array([.double(103), .double(92)])]),
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
        #expect(Set(specJSON.keys) == ["op", "canvasPoints", "gridIds", "maxCandidates"])
        #expect(specJSON["op"] as? String == "snap")
        let points = try #require(specJSON["canvasPoints"] as? [[Double]])
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
            "canvasPoints": .array([.array([.double(1), .double(1)])]),
        ])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(specJSON.keys) == ["op", "canvasPoints"])

        await server.stop()
    }

    @Test func snapPointsWithNoDeviceErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device connects in this test.

        let (content, isError) = try await client.callTool(name: "snap_points", arguments: [
            "docId": "d", "canvasPoints": .array([.array([.double(1), .double(1)])]),
        ])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))

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
            "docId": "ghost", "canvasPoints": .array([.array([.double(1), .double(1)])]),
        ])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

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
            "docId": "d", "canvasPoints": .array([.array([.double(1), .double(1)])]),
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
            "ids": .array([.string("seed123:1.0")]),
            "canvasTranslate": .array([.double(10), .double(20)]),
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
            "docId": "d", "ids": .array([.string("seed123:1.0")]), "rotate": .double(90),
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
            "ids": .array([.string("1-2")]),
            "canvasTranslate": .array([.double(0), .double(0)]),
            "snapToGrid": .bool(true),
            "snapTo": .object(["gridId": .int(0), "familyIds": .array([.int(1)])]),
        ])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ids", "canvasTranslate", "snapToGrid", "snapTo"])
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
            "ids": .array([.string("seed123:1.0")]),
            "color": .string("#FF0000"),
            "stampWidth": .double(8),
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
            "docId": "d", "ids": .array([.string("seed123:1.0")]), "stampWidth": .double(9),
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
                "id": .string("seed123:1.0"),
                "canvasPoints": .array([
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
        #expect(strokes[0]["id"] as? String == "seed123:1.0")
        let points = try #require(strokes[0]["canvasPoints"] as? [Any])
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
            ("get_strokes", ["docId": "ghost", "ids": .array([.string("1-2")])]),
            ("transform_strokes", [
                "docId": "ghost", "ids": .array([.string("1-2")]),
                "canvasTranslate": .array([.double(1), .double(1)]),
            ]),
            ("restyle_strokes", [
                // `stampWidth`, not `width` — this said `width` until the strict-argument check
                // caught it, a leftover from the explicit-coordinate-spaces rename that had been
                // silently dropped ever since.
                "docId": "ghost", "ids": .array([.string("1-2")]), "stampWidth": .double(3),
            ]),
            ("reshape_strokes", ["docId": "ghost", "strokes": Self.minimalReshapeStrokes]),
        ]
        for (name, args) in calls {
            let (content, isError) = try await client.callTool(name: name, arguments: args)
            #expect(isError == true, "\(name)")
            #expect(toolResultText(content).hasPrefix("unknownDoc"), "\(name)")
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
                args = ["docId": "d", "ids": .array([.string("ghost")])]
            case "transform_strokes":
                args = [
                    "docId": "d", "ids": .array([.string("ghost")]),
                    "canvasTranslate": .array([.double(1), .double(1)]),
                ]
            case "restyle_strokes":
                args = ["docId": "d", "ids": .array([.string("ghost")]), "stampWidth": .double(9)]
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
            "ids": .array([.string("1-2")]),
            "canvasTranslate": .array([.double(1), .double(2)]),
            "scale": .array([.double(2), .double(2)]),
            "rotate": .double(45),
            "canvasAnchor": .array([.double(0), .double(0)]),
            "snapToGrid": .bool(true),
        ])
        var received = try #require(await device.receivedRequests.last)
        var envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == [
            "op", "ids", "canvasTranslate", "scale", "rotate", "canvasAnchor", "snapToGrid",
        ])
        #expect(envelope["op"] as? String == "transform")

        _ = try await client.callTool(name: "restyle_strokes", arguments: [
            "docId": "d",
            "ids": .array([.string("1-2")]),
            "color": .string("#FF0000"),
            "stampWidth": .double(8),
            "inkType": .string("marker"),
        ])
        received = try #require(await device.receivedRequests.last)
        envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ids", "color", "stampWidth", "inkType"])
        #expect(envelope["op"] as? String == "restyle")

        _ = try await client.callTool(name: "reshape_strokes", arguments: [
            "docId": "d",
            "strokes": .array([.object([
                "id": .string("1-2"),
                "canvasPoints": .array([
                    .array([.double(0), .double(0)]),
                    .object(["canvasX": .double(1), "canvasY": .double(2), "force": .double(0.5)]),
                ]),
            ])]),
        ])
        received = try #require(await device.receivedRequests.last)
        envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "strokes"])
        #expect(envelope["op"] as? String == "reshape")
        let items = try #require(envelope["strokes"] as? [[String: Any]])
        #expect(Set(items[0].keys) == ["id", "canvasPoints"])  // the app decodes exactly these

        _ = try await client.callTool(name: "get_strokes", arguments: [
            "docId": "d",
            "ids": .array([.string("1-2")]),
            "maxPoints": .int(500),
        ])
        received = try #require(await device.receivedRequests.last)
        envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ids", "maxPoints"])
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
                "id": .string("1-2"),
                "canvasPoints": .array([.array([.double(0), .double(0)]), .array([.double(10), .double(10)])]),
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
        #expect(Set(item.keys) == ["id", "canvasPoints", "smooth"])
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
            for key in ["properties", "strokes", "items", "properties", "canvasPoints", "items"] {
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

    // MARK: - colorAppearance / appearance (2026-08-12 agent-color-space spec)

    /// Every tool on this surface that takes a colour hex must declare the call-level
    /// `colorAppearance` door (Task 11) — the one place a dark-authored colour can enter.
    /// Modeled on everyStrokeAcceptingToolAdvertisesSmoothInItsSchema (3573).
    @Test func everyColourTakingToolAdvertisesColorAppearance() throws {
        let expected: Set<String> = ["draw_strokes", "draw_selection", "fill_region",
                                     "draw_dots", "restyle_strokes", "restyle_selection",
                                     "add_text", "edit_text", "render_sketch"]
        let declaring = Set(MCPAdapter.toolDefinitions
            .filter { MCPAdapter.declaredArguments(of: $0).contains("colorAppearance") }
            .map(\.name))
        #expect(declaring == expected)
    }

    /// `appearance` and `colorAppearance` both reach the device through render_sketch's
    /// allow-list (renderSpecParameterNames). Modeled on renderSketchRelaysScale (5419).
    @Test func renderSketchRelaysAppearanceAndColorAppearance() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data([0x89, 0x50]),
                                                  meta: Data(#"{"appearance":"dark"}"#.utf8)))
        defer { Task { await device.close() } }

        _ = try await client.callTool(name: "render_sketch", arguments: [
            "docId": "d", "appearance": .string("dark"), "colorAppearance": .string("dark"),
        ])
        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["appearance"] as? String == "dark")
        #expect(spec["colorAppearance"] as? String == "dark")

        await server.stop()
    }

    /// `draw_strokes` relays `colorAppearance` only when supplied — the exact envelope key set
    /// the device decodes, string-literally, no extras.
    @Test func drawStrokesRelaysColorAppearance() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes))
        defer { Task { await device.close() } }

        let strokesArg: Value = .array([
            .object(["canvasPoints": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(0)])])])
        ])
        let (_, isError) = try await client.callTool(name: "draw_strokes", arguments: [
            "docId": "d", "strokes": strokesArg, "colorAppearance": .string("dark"),
        ])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "strokes", "colorAppearance"])
        #expect(envelope["colorAppearance"] as? String == "dark")

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
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))
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
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

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
    /// `strokeIds`/`textIds`/`imageIds` supplied by the caller rides through
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
                "strokeIds": .array([.string("seed1:1.0")]),
                "textIds": .array([.string("text-1"), .string("text-2")]),
            ])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "strokeIds", "textIds"])
        #expect(envelope["op"] as? String == "selectElements")
        #expect(envelope["strokeIds"] as? [String] == ["seed1:1.0"])
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
            name: "set_reference_point", arguments: ["docId": "d", "canvasX": 10, "canvasY": 20])
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
            name: "set_reference_point", arguments: ["docId": "d", "canvasX": 10])
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

    // MARK: - preview_selection (Milestone 2 Task 4)
    //
    // A pure relay modeled on render_sketch's result shape (.image + .text)
    // but gated on "controlSelection" like the rest of the selection tools
    // above — same FakeStrokeOpDevice harness, same envelope-pinning idiom.

    /// Pins the exact op-spec envelope `preview_selection` relays when every
    /// optional is supplied, and that the result carries the device's PNG +
    /// meta exactly like `render_sketch` (renderSketchReturnsImageAndMetadataContent).
    @Test func previewSelectionRelaysOpsAndOptionalsAndReturnsImageAndMeta() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD, 0xBE, 0xEF])
        let metaBytes = Data(#"{"elements":[],"grids":[]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: pngBytes, meta: metaBytes),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let opsArg: Value = .array([
            .object(["op": .string("rotate"), "degrees": .double(90)])
        ])
        let (content, isError) = try await client.callTool(
            name: "preview_selection",
            arguments: [
                "docId": "d", "ops": opsArg,
                "include": .string("selectionOnly"),
                "canvasRect": .array([.double(0), .double(0), .double(100), .double(100)]),
                "includePoints": .bool(true),
            ])
        #expect(isError != true)

        let image = try #require(toolResultImage(content))
        #expect(image.mimeType == "image/png")
        #expect(Data(base64Encoded: image.data) == pngBytes)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ops", "include", "canvasRect", "includePoints"])
        #expect(envelope["op"] as? String == "previewSelection")
        let ops = try #require(envelope["ops"] as? [[String: Any]])
        #expect(ops.count == 1)
        #expect(ops.first?["op"] as? String == "rotate")
        #expect(ops.first?["degrees"] as? Double == 90)
        #expect(envelope["include"] as? String == "selectionOnly")
        #expect(envelope["canvasRect"] as? [Double] == [0, 0, 100, 100])
        #expect(envelope["includePoints"] as? Bool == true)

        await server.stop()
    }

    /// A call that omits every optional (the common case) must omit them
    /// from the envelope rather than sending explicit nulls, mirroring
    /// `transformSelectionOmitsExpectWhenNotSupplied` /
    /// `renderSketchWithOnlyDocIdOmitsEveryOptionalField`.
    @Test func previewSelectionWithOnlyRequiredArgumentsOmitsOptionalKeys() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data([1, 2, 3]), meta: Data(#"{}"#.utf8)),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let opsArg: Value = .array([.object(["op": .string("flipHorizontal")])])
        let (_, isError) = try await client.callTool(
            name: "preview_selection", arguments: ["docId": "d", "ops": opsArg])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ops"])

        await server.stop()
    }

    /// Only a `controlSelection`-capable device is picked — mirrors
    /// `getSelectionWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable`.
    @Test func previewSelectionWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Default capabilities: ["authorStrokes"] only — no "controlSelection".
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data()))
        defer { Task { await device.close() } }

        let opsArg: Value = .array([.object(["op": .string("flipVertical")])])
        let (content, isError) = try await client.callTool(
            name: "preview_selection", arguments: ["docId": "d", "ops": opsArg])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func previewSelectionUnknownDocReturnsToolError() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device needs to connect — unknownDoc short-circuits before
        // any device round trip, mirroring every other tool's unknownDoc path.

        let opsArg: Value = .array([.object(["op": .string("flipVertical")])])
        let (content, isError) = try await client.callTool(
            name: "preview_selection", arguments: ["docId": "ghost", "ops": opsArg])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        await server.stop()
    }

    @Test func previewSelectionDeviceFailurePropagatesReason() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .failure("noReferencePoint"), capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let opsArg: Value = .array([.object(["op": .string("scale"), "factor": .double(2)])])
        let (content, isError) = try await client.callTool(
            name: "preview_selection", arguments: ["docId": "d", "ops": opsArg])
        #expect(isError == true)
        #expect(toolResultText(content) == "deviceFailed: noReferencePoint")

        await server.stop()
    }

    /// `duplicate` (Task 7, Milestone 3) rides into the envelope only when
    /// supplied, same conditional splicing as `rect`/`includePoints` — pins
    /// that it comes through as a plain JSON bool alongside `ops`.
    @Test func previewSelectionWithDuplicateRelaysDuplicateInEnvelope() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data([1, 2, 3]), meta: Data(#"{}"#.utf8)),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let opsArg: Value = .array([
            .object(["op": .string("canvasTranslate"), "dx": .double(20), "dy": .double(0)])
        ])
        let (_, isError) = try await client.callTool(
            name: "preview_selection",
            arguments: ["docId": "d", "ops": opsArg, "duplicate": .bool(true)])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ops", "duplicate"])
        #expect(envelope["op"] as? String == "previewSelection")
        #expect(envelope["duplicate"] as? Bool == true)

        await server.stop()
    }

    // MARK: - duplicate_selection (Task 7, Milestone 3)
    //
    // Same relay skeleton as transform_selection's tests above: a
    // `controlSelection`-capable `FakeStrokeOpDevice` stands in for the
    // connected device, `.bytesWithMeta` supplies the reply's `meta` JSON,
    // and `device.receivedRequests[0].spec` is decoded to pin the exact
    // op-spec envelope shape relayed to the device. Unlike
    // `transform_selection`, `ops` is OPTIONAL: omitted, the device makes a
    // provisional in-place copy; supplied, it clones + transforms as one
    // "stamp" undo step.

    /// Pins the exact op-spec envelope `duplicate_selection` relays when
    /// `ops` is supplied.
    @Test func duplicateSelectionWithOpsRelaysOpsInEnvelope() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let metaBytes = Data(#"{"newStrokeKeys":["clone1:1.0"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: metaBytes),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let opsArg: Value = .array([
            .object(["op": .string("canvasTranslate"), "dx": .double(40), "dy": .double(0)])
        ])
        let (content, isError) = try await client.callTool(
            name: "duplicate_selection", arguments: ["docId": "d", "ops": opsArg])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: metaBytes, as: UTF8.self))

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "ops"])
        #expect(envelope["op"] as? String == "duplicateSelection")
        let ops = try #require(envelope["ops"] as? [[String: Any]])
        #expect(ops.count == 1)
        #expect(ops.first?["op"] as? String == "canvasTranslate")
        #expect(ops.first?["dx"] as? Double == 40)

        await server.stop()
    }

    /// A call that omits `ops` (a provisional in-place copy, like the
    /// toolbar's duplicate) must omit the field from the envelope rather
    /// than sending an explicit null, mirroring
    /// `transformSelectionOmitsExpectWhenNotSupplied`.
    @Test func duplicateSelectionWithoutOpsOmitsOpsFromEnvelope() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: Data(#"{}"#.utf8)),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(
            name: "duplicate_selection", arguments: ["docId": "d"])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op"])
        #expect(envelope["op"] as? String == "duplicateSelection")

        await server.stop()
    }

    /// `expect`, when supplied, rides along verbatim — mirrors
    /// `transformSelectionRelaysOpsAndExpectInEnvelope`.
    @Test func duplicateSelectionRelaysExpectWhenSupplied() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data(), meta: Data(#"{}"#.utf8)),
            capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(
            name: "duplicate_selection", arguments: ["docId": "d", "expect": .string("sig-456")])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "expect"])
        #expect(envelope["expect"] as? String == "sig-456")

        await server.stop()
    }

    /// Only a `controlSelection`-capable device is picked — mirrors
    /// `previewSelectionWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable`.
    @Test func duplicateSelectionWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Default capabilities: ["authorStrokes"] only — no "controlSelection".
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Data()))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "duplicate_selection", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func duplicateSelectionUnknownDocReturnsToolError() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // No fake device needs to connect — unknownDoc short-circuits before
        // any device round trip, mirroring every other tool's unknownDoc path.

        let (content, isError) = try await client.callTool(
            name: "duplicate_selection", arguments: ["docId": "ghost"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        await server.stop()
    }

    @Test func duplicateSelectionDeviceFailurePropagatesReason() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .failure("noSelectionActive"), capabilities: ["controlSelection"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "duplicate_selection", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("deviceFailed: noSelectionActive"))

        await server.stop()
    }

    // MARK: - merge_docs (agent-merge-docs spec, Task 1: server relay)
    //
    // Same device-relay shape as the other authoring tools: compose
    // a minimal op-spec envelope, relay it plus TARGET's current bytes
    // through `broker.requestStrokeOp` (capability "mergeDocs"), then write
    // the device's merged reply back to `target` under the standard byte-CAS
    // every other write tool uses. `source` is read but never written — its
    // bytes travel base64'd INSIDE the spec envelope, never as the relay's
    // `docBytes`.

    /// Relay: callMergeDocs ships {op, prefer, sourceBytes(base64)} to the
    /// device, docBytes = target's bytes.
    @Test func mergeDocsRelaysSourceBytesAndPrefer() async throws {
        let targetBytes = Fixtures.docBytes
        let sourceBytes = Data(#"{"aaa001_thumbnailData":"","marker":"source"}"#.utf8)
        let (server, port, task) = try await startServer(seedDocId: "T", bytes: targetBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await seedDocViaReplaceDoc(client, docId: "S", bytes: sourceBytes)

        let mergedBytes = Data(#"{"aaa001_thumbnailData":"","marker":"merged"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(mergedBytes), capabilities: ["mergeDocs"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "S", "target": "T", "prefer": "source"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("merged S into T"))

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "T")
        #expect(received.docBytes == targetBytes)

        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "prefer", "sourceBytes"])
        #expect(envelope["op"] as? String == "mergeDocs")
        #expect(envelope["prefer"] as? String == "source")
        let encodedSource = try #require(envelope["sourceBytes"] as? String)
        #expect(Data(base64Encoded: encodedSource) == sourceBytes)

        let rawContents = try await client.readResource(uri: "infsketch://doc/T/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == mergedBytes)

        await server.stop()
    }

    /// A call that omits `prefer` (the default-to-"target" case) must relay
    /// "target" verbatim — the server always sends a concrete `prefer` to
    /// the device rather than letting the device pick its own default.
    @Test func mergeDocsDefaultsPreferToTarget() async throws {
        let (server, port, task) = try await startServer(seedDocId: "T", bytes: Fixtures.docBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await seedDocViaReplaceDoc(
            client, docId: "S", bytes: Data(#"{"aaa001_thumbnailData":"","marker":"source"}"#.utf8))

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Data(#"{"aaa001_thumbnailData":"","marker":"merged"}"#.utf8)),
            capabilities: ["mergeDocs"])
        defer { Task { await device.close() } }

        let (_, isError) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "S", "target": "T"])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(envelope["prefer"] as? String == "target")

        await server.stop()
    }

    /// `source` absent -> "sourceNotFound", checked before any device is
    /// contacted (mirrors `unknownDoc`'s pre-device-round-trip convenience —
    /// see `callCreateDoc`'s `docExists` pre-check).
    @Test func mergeDocsErrorsSourceNotFound() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "NoSuchSource", "target": "d"])
        #expect(isError == true)
        #expect(toolResultText(content) == "sourceNotFound")

        await server.stop()
    }

    /// `target` absent -> "targetNotFound".
    @Test func mergeDocsErrorsTargetNotFound() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "d", "target": "NoSuchTarget"])
        #expect(isError == true)
        #expect(toolResultText(content) == "targetNotFound")

        await server.stop()
    }

    /// `source == target` -> "invalidArguments", checked before either doc's
    /// bytes are even read.
    @Test func mergeDocsRejectsSourceEqualsTarget() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "d", "target": "d"])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArguments")

        await server.stop()
    }

    // MARK: - merge_docs `into:` (agent-merge-docs-into, Task 1)
    //
    // `mergeDocsRelaysSourceBytesAndPrefer` above already pins the absent-`into`
    // in-place behavior end-to-end (relay envelope, reply text "merged S into
    // T", and `target`'s raw bytes becoming the merged blob) — no separate
    // regression test is added here for that case.

    /// `into` present + a free name: the union is written to a NEW document
    /// under `into`; `source` and `target` are both left byte-unchanged. The
    /// device relay itself is unchanged from the in-place case — still
    /// `docId: target`/`docBytes: targetBytes` — only the final WRITE target
    /// differs.
    @Test func mergeDocsIntoWritesUnionToNewDocLeavingBothOriginals() async throws {
        let targetBytes = Fixtures.docBytes
        let sourceBytes = Data(#"{"aaa001_thumbnailData":"","marker":"source"}"#.utf8)
        let (server, port, task) = try await startServer(seedDocId: "T", bytes: targetBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await seedDocViaReplaceDoc(client, docId: "S", bytes: sourceBytes)

        let mergedBytes = Data(#"{"aaa001_thumbnailData":"","marker":"merged"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(mergedBytes), capabilities: ["mergeDocs"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "S", "target": "T", "into": "C"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("merged S and T into C"))

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "T")
        #expect(received.docBytes == targetBytes)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(Set(envelope.keys) == ["op", "prefer", "sourceBytes"])

        let cRaw = try await client.readResource(uri: "infsketch://doc/C/raw")
        #expect(Data(base64Encoded: try #require(cRaw[0].blob)) == mergedBytes)

        let sRaw = try await client.readResource(uri: "infsketch://doc/S/raw")
        #expect(Data(base64Encoded: try #require(sRaw[0].blob)) == sourceBytes)

        let tRaw = try await client.readResource(uri: "infsketch://doc/T/raw")
        #expect(Data(base64Encoded: try #require(tRaw[0].blob)) == targetBytes)

        await server.stop()
    }

    /// `into` names an already-existing doc: fast-fail `docExists`, mirroring
    /// `createDocOnExistingDocErrors`'s pre-device-round-trip convenience
    /// check — the device must never be woken for an `into` that's already
    /// taken.
    @Test func mergeDocsIntoRejectsExistingNameWithoutWakingDevice() async throws {
        let (server, port, task) = try await startServer(seedDocId: "T", bytes: Fixtures.docBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await seedDocViaReplaceDoc(
            client, docId: "S", bytes: Data(#"{"aaa001_thumbnailData":"","marker":"source"}"#.utf8))
        try await seedDocViaReplaceDoc(
            client, docId: "C", bytes: Data(#"{"aaa001_thumbnailData":"","marker":"existing"}"#.utf8))

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Data(#"{"aaa001_thumbnailData":"","marker":"merged"}"#.utf8)),
            capabilities: ["mergeDocs"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "S", "target": "T", "into": "C"])
        #expect(isError == true)
        #expect(toolResultText(content) == "docExists")

        // Fast-fail: the device must never be contacted for an already-taken `into`.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// `into` equal to `source` or `target` is rejected up front as
    /// `invalidArguments`, alongside `source == target` above.
    @Test func mergeDocsIntoEqualToSourceOrTargetIsInvalid() async throws {
        let (server, port, task) = try await startServer(seedDocId: "T", bytes: Fixtures.docBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await seedDocViaReplaceDoc(
            client, docId: "S", bytes: Data(#"{"aaa001_thumbnailData":"","marker":"source"}"#.utf8))

        let (contentIntoSource, isErrorIntoSource) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "S", "target": "T", "into": "S"])
        #expect(isErrorIntoSource == true)
        #expect(toolResultText(contentIntoSource) == "invalidArguments")

        let (contentIntoTarget, isErrorIntoTarget) = try await client.callTool(
            name: "merge_docs", arguments: ["source": "S", "target": "T", "into": "T"])
        #expect(isErrorIntoTarget == true)
        #expect(toolResultText(contentIntoTarget) == "invalidArguments")

        await server.stop()
    }

    // MARK: - copy_elements (agent-copy-elements spec, Task 2: server relay)
    //
    // Same device-relay shape as merge_docs above, but a COPY not a merge:
    // `source`'s bytes ride base64'd INSIDE the op-spec envelope under the
    // key `source` (not `sourceBytes` — the field name copy_elements uses),
    // `target`'s current bytes are the relay's `docBytes`, and the device's
    // cloned reply is written back to `target` under the standard byte-CAS.
    // `source` is read but never written.

    /// Relay: callCopyElements ships {op, source(base64), strokeIds,
    /// textIds, imageIds} to the device, docBytes = target's bytes.
    @Test func copyElementsRelaysSpecAndCapability() async throws {
        let targetBytes = Fixtures.docBytes
        let sourceBytes = Data(#"{"aaa001_thumbnailData":"","marker":"source"}"#.utf8)
        let (server, port, task) = try await startServer(seedDocId: "t", bytes: targetBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await seedDocViaReplaceDoc(client, docId: "s", bytes: sourceBytes)

        let modified = Data(#"{"aaa001_thumbnailData":"","marker":"copied"}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(modified), capabilities: ["copyElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "copy_elements",
            arguments: ["source": "s", "target": "t", "strokeIds": ["k1"]])
        #expect(isError != true)
        #expect(toolResultText(content).contains("from s into t"))

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "t")
        #expect(received.docBytes == targetBytes)  // target rides as docBytes
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "copyElements")
        let encodedSource = try #require(spec["source"] as? String)  // base64 source rides in the spec
        #expect(Data(base64Encoded: encodedSource) == sourceBytes)
        #expect(spec["strokeIds"] as? [String] == ["k1"])

        let rawContents = try await client.readResource(uri: "infsketch://doc/t/raw")
        let rawBlob = try #require(rawContents[0].blob)
        #expect(Data(base64Encoded: rawBlob) == modified)

        await server.stop()
    }

    /// `out.meta`'s created ids (`CopyElements.perform`'s app-side
    /// `{"createdStrokeKeys": […], "createdTextIds": […], "createdImageIds": […]}`
    /// shape) are surfaced in the result text the same way draw_strokes
    /// surfaces `ids:` — so the agent can act on exactly what was just
    /// copied instead of re-finding it.
    @Test func copyElementsSurfacesCreatedIds() async throws {
        let targetBytes = Fixtures.docBytes
        let sourceBytes = Data(#"{"aaa001_thumbnailData":"","marker":"source"}"#.utf8)
        let (server, port, task) = try await startServer(seedDocId: "t", bytes: targetBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await seedDocViaReplaceDoc(client, docId: "s", bytes: sourceBytes)

        let modified = Data(#"{"aaa001_thumbnailData":"","marker":"copied"}"#.utf8)
        let metaBytes = Data(#"{"createdStrokeKeys":["newkey1"],"createdTextIds":[],"createdImageIds":[]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: modified, meta: metaBytes),
            capabilities: ["copyElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "copy_elements",
            arguments: ["source": "s", "target": "t", "strokeIds": ["k1"]])
        #expect(isError != true)
        #expect(toolResultText(content).contains("newkey1"))

        await server.stop()
    }

    /// `source` absent -> "sourceNotFound", checked before any device is
    /// contacted (mirrors `mergeDocsErrorsSourceNotFound`).
    @Test func copyElementsSourceNotFound() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "copy_elements",
            arguments: ["source": "ghost", "target": "d", "strokeIds": ["k1"]])
        #expect(isError == true)
        #expect(toolResultText(content) == "sourceNotFound")

        await server.stop()
    }

    /// `target` absent -> "targetNotFound".
    @Test func copyElementsTargetNotFound() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "copy_elements",
            arguments: ["source": "d", "target": "ghost", "strokeIds": ["k1"]])
        #expect(isError == true)
        #expect(toolResultText(content) == "targetNotFound")

        await server.stop()
    }

    /// `source == target` -> "invalidArguments", checked before either doc's
    /// bytes are even read.
    @Test func copyElementsSameDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "copy_elements",
            arguments: ["source": "d", "target": "d", "strokeIds": ["k1"]])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArguments")

        await server.stop()
    }

    /// No ids at all (strokeIds/textIds/imageIds all omitted) ->
    /// "invalidArguments", checked before either doc is looked up (neither
    /// "a" nor "b" need exist for this to fail).
    @Test func copyElementsNoIdsErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "copy_elements", arguments: ["source": "a", "target": "b"])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArguments")

        await server.stop()
    }

    /// An empty `source`/`target` is a caller error (`invalidArgument`), not a
    /// `sourceNotFound` — matching the sibling `merge_docs`' `nonEmptyStringArg`.
    @Test func copyElementsEmptySourceErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "copy_elements", arguments: ["source": "", "target": "d", "strokeIds": ["k1"]])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArgument: source")

        await server.stop()
    }

    // MARK: - add_image (Task 2; `path` since 2026-08-11-agent-add-image-path-design)
    //
    // Places an image into a document, authored by a connected device
    // (`ImageAuthoring`, app repo, Task 1). Relays a `{"op":"addImage",
    // "imageBytes": <base64>, "canvasX", "canvasY", "canvasWidth"?,
    // "canvasHeight"?, "opacity"?}` envelope through `broker.requestStrokeOp`,
    // gated on the "authorImage" capability (not "authorStrokes"/"authorText"
    // — a device that only authors strokes/text must not be picked for this),
    // and surfaces the new image's id from the reply's `meta` — same shape as
    // `styledAddTextRelaysTheStyleEnvelopeThroughTheDevice` above.
    //
    // The tool takes a `path` the SERVER reads; the base64 `bytes` argument it
    // used to take is gone. The envelope is deliberately unchanged by that —
    // the device, the wire and the protocol version know nothing about it, so
    // the change needed no version bump.

    /// Writes a real PNG to a temp file for the duration of the body. `add_image` no longer
    /// accepts inline bytes, so every one of these tests needs a file on disk.
    private func withPNGFile<T>(_ name: String = "logo.png",
                                data: Data? = nil,
                                _ body: (String) async throws -> T) async rethrows -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("addimage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        let bytes = data ?? Data(base64Encoded: ImageContainerTests.pngBase64)!
        try? bytes.write(to: url)
        return try await body(url.path)
    }

    /// The exact relayed envelope key set, string-literally (mirroring the
    /// styled add_text contract test): present-only optional keys, the FILE'S
    /// bytes relayed as the base64 string under `imageBytes`, and the new
    /// image's id (from `meta`) surfaced in the result text.
    @Test func addImageReadsTheFileAndRelaysItsBytes() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let png = try #require(Data(base64Encoded: ImageContainerTests.pngBase64))
        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","placedImagesData":["new-image"]}"#.utf8)
        let metaBytes = Data(#"{"id":"IMG-1"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: modifiedBytes, meta: metaBytes),
            capabilities: ["authorImage"])
        defer { Task { await device.close() } }

        try await withPNGFile { path in
            let (content, isError) = try await client.callTool(
                name: "add_image",
                arguments: [
                    "docId": "d", "path": .string(path),
                    "canvasX": 10, "canvasY": 20, "canvasWidth": 50,
                ])
            #expect(isError != true)
            #expect(toolResultText(content).contains("IMG-1"), "add_image must surface the new image's id")

            let received = try #require(await device.receivedRequests.first)
            #expect(received.docId == "d")
            #expect(received.docBytes == Fixtures.docBytes)
            let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
            #expect(spec["op"] as? String == "addImage")
            // Exact envelope: present-only optionals — no height/opacity when omitted. UNCHANGED
            // by the path work: the device still receives base64 under `imageBytes`.
            #expect(Set(spec.keys) == ["op", "imageBytes", "canvasX", "canvasY", "canvasWidth"])
            let relayedImageBytesB64 = try #require(spec["imageBytes"] as? String)
            #expect(Data(base64Encoded: relayedImageBytesB64) == png,
                    "the file's bytes must reach the device unaltered")
            #expect(spec["canvasX"] as? Double == 10)
            #expect(spec["canvasY"] as? Double == 20)
            #expect(spec["canvasWidth"] as? Double == 50)
        }

        await server.stop()
    }

    /// The reported bug, end to end at the tool: a truncated PNG is refused BY NAME and the device
    /// is never woken — instead of being placed as an image that reports plausible bounds and
    /// renders nothing. No decoder can make this call, which is why the server checks the
    /// container (see `ImageContainer`).
    @Test func addImageRefusesACorruptFileWithoutWakingTheDevice() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorImage"])
        defer { Task { await device.close() } }

        let whole = try #require(Data(base64Encoded: ImageContainerTests.pngBase64))
        try await withPNGFile("cut.png", data: whole.prefix(whole.count / 2)) { path in
            let (content, isError) = try await client.callTool(
                name: "add_image",
                arguments: ["docId": "d", "path": .string(path), "canvasX": 0, "canvasY": 0])
            #expect(isError == true)
            let text = toolResultText(content)
            #expect(text.hasPrefix("imageCorrupt: "), "\(text)")
            #expect(text.contains("cut.png"), "the error must name the file: \(text)")
            #expect(await device.receivedRequests.isEmpty,
                    "a corrupt file must be refused before any device round trip")
        }

        await server.stop()
    }

    /// A path that names nothing is refused before the device is contacted, like `unknownDoc`.
    @Test func addImageMissingFileErrorsWithoutWakingTheDevice() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorImage"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "add_image",
            arguments: ["docId": "d", "path": "/nowhere/at/all/logo.png", "canvasX": 0, "canvasY": 0])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("imageFileNotFound: "))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// The device reports what it actually placed, and the tool surfaces it. `pixelWidth`/
    /// `pixelHeight` are the SOURCE image's own dimensions, which no other tool exposes —
    /// `list_images` reports canvasBounds and never the pixels behind it — so without these an
    /// agent cannot learn the aspect ratio and must render, look and guess.
    @Test func addImageReportsThePlacedBoundsAndTheSourcePixelSize() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","placedImagesData":["new-image"]}"#.utf8)
        let metaBytes = Data(
            #"{"id":"IMG-1","canvasBounds":"10, 20, 50, 47.9","pixelWidth":"167","pixelHeight":"160"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: modifiedBytes, meta: metaBytes),
            capabilities: ["authorImage"])
        defer { Task { await device.close() } }

        try await withPNGFile { path in
            let (content, isError) = try await client.callTool(
                name: "add_image",
                arguments: ["docId": "d", "path": .string(path), "canvasX": 10, "canvasY": 20])
            #expect(isError != true)
            let text = toolResultText(content)
            #expect(text.contains("id: IMG-1"), "\(text)")
            #expect(text.contains("canvasBounds: [10, 20, 50, 47.9]"), "\(text)")
            #expect(text.contains("pixelWidth: 167"), "\(text)")
            #expect(text.contains("pixelHeight: 160"), "\(text)")
        }

        await server.stop()
    }

    /// An older device that does not report the new fields still works — the lines are simply
    /// absent. That is what keeps `meta` a `[String: String]` and the two repos independently
    /// deployable.
    @Test func addImageStillWorksAgainstADeviceThatReportsOnlyAnId() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","placedImagesData":["new-image"]}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: modifiedBytes, meta: Data(#"{"id":"IMG-1"}"#.utf8)),
            capabilities: ["authorImage"])
        defer { Task { await device.close() } }

        try await withPNGFile { path in
            let (content, isError) = try await client.callTool(
                name: "add_image",
                arguments: ["docId": "d", "path": .string(path), "canvasX": 0, "canvasY": 0])
            #expect(isError != true)
            let text = toolResultText(content)
            #expect(text.contains("id: IMG-1"), "\(text)")
            #expect(!text.contains("canvasBounds"), "absent fields must not be invented: \(text)")
        }

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip — mirroring `mergeDocsIntoRejectsExistingNameWithoutWakingDevice`.
    @Test func addImageUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorImage"])
        defer { Task { await device.close() } }

        try await withPNGFile { path in
            let (content, isError) = try await client.callTool(
                name: "add_image",
                arguments: ["docId": "ghost", "path": .string(path), "canvasX": 0, "canvasY": 0])
            #expect(isError == true)
            #expect(toolResultText(content).hasPrefix("unknownDoc"))

            // Fast-fail: the device must never be contacted for an unknown doc.
            #expect(await device.receivedRequests.isEmpty)
        }

        await server.stop()
    }

    // MARK: - list_grids / add_grid / update_grid / remove_grid / set_grid_origin
    // (agent-grid-authoring spec, Task 3)
    //
    // Five grid-authoring relay tools, all gated on the "authorGrids"
    // capability (a device that only authors strokes/text/images must not be
    // picked for these). `list_grids` mirrors `callListStrokes`/
    // `callListImages`: relay `{op:"listGrids"}`, pass the device's reply
    // through verbatim as text, never write. The four write tools mirror
    // `callAddImage`: read `currentBytes` -> `unknownDoc` if absent, build a
    // present-only `{op, ...}` envelope, relay, then `submitAndRespond` with
    // the byte-CAS (`expectedBytes: docBytes`). `add_grid` surfaces the new
    // grid's id from the reply's `meta`, exactly as `add_image` does.

    @Test func listGridsRelaysAndPassesReplyThrough() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let listingJSON = Data(#"[{"id":"GRID-1","type":"grid","spacing":20,"visible":true,"enabled":true}]"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(listingJSON), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_grids", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == String(decoding: listingJSON, as: UTF8.self))

        // No write: list_grids never opens a session, same as list_strokes/list_images.
        let summaryContents = try await client.readResource(uri: "infsketch://doc/d")
        let summaryJSON = try #require(summaryContents[0].text)
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: Data(summaryJSON.utf8))
        #expect(envelope.seq == -1)

        // The fake (hello'd with ONLY "authorGrids") received the request —
        // proving requestStrokeOp's capability argument was "authorGrids".
        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let specJSON = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(specJSON["op"] as? String == "listGrids")
        #expect(Set(specJSON.keys) == ["op"])

        await server.stop()
    }

    /// Pins the capability gate: a device advertising ONLY "authorStrokes"
    /// (no "authorGrids") must NOT be selected for list_grids.
    @Test func listGridsWithOnlyStrokeCapableDeviceFailsNoDeviceAvailable() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        // Default capabilities: ["authorStrokes"] only — no "authorGrids".
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_grids", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("noDeviceAvailable"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip.
    @Test func listGridsUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "list_grids", arguments: ["docId": "ghost"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        // Fast-fail: the device must never be contacted for an unknown doc.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// The exact relayed envelope key set, string-literally (mirroring
    /// `addImageRelaysEnvelopeAndSurfacesId`): present-only optional keys,
    /// and the new grid's id (from `meta`) surfaced in the result text.
    @Test func addGridRelaysEnvelopeAndSurfacesId() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","marker":"grid-added"}"#.utf8)
        let metaBytes = Data(#"{"id":"GRID-NEW"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: modifiedBytes, meta: metaBytes),
            capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "add_grid",
            arguments: ["docId": "d", "type": "isometric", "spacing": 50, "color": "#FF0000FF"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("GRID-NEW"), "add_grid must surface the new grid's id")

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "addGrid")
        // Exact envelope: present-only optionals — no snap/rotation/thickness/
        // visible/enabled/offset when omitted.
        #expect(Set(spec.keys) == ["op", "type", "spacing", "color"])
        #expect(spec["type"] as? String == "isometric")
        #expect(spec["spacing"] as? Double == 50)
        #expect(spec["color"] as? String == "#FF0000FF")

        await server.stop()
    }

    /// Grid tags (spec 2026-07-29-grid-tags-design) relay verbatim, on both write tools. This is
    /// the seam a unit test on either side alone cannot cover: the server's tests fake the device
    /// and the app's fake the server, so a field added on one side only passes BOTH suites —
    /// which is exactly how `reshape_strokes` shipped broken for a commit.
    @Test func gridTagsRelayVerbatimOnAddAndUpdate() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data(#"{"aaa001_thumbnailData":"","marker":"g"}"#.utf8),
                                      meta: Data(#"{"id":"GRID-NEW"}"#.utf8)),
            capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (_, addError) = try await client.callTool(
            name: "add_grid", arguments: ["docId": "d", "tags": ["elevation", "draft"]])
        #expect(addError != true)
        let addRequest = try #require(await device.receivedRequests.first)
        let added = try #require(JSONSerialization.jsonObject(with: addRequest.spec) as? [String: Any])
        #expect(Set(added.keys) == ["op", "tags"])
        #expect(added["tags"] as? [String] == ["elevation", "draft"])

        // An EMPTY list must survive the relay too — it is how `update_grid` clears tags, and a
        // present-only filter that dropped it would silently turn "clear" into "leave alone".
        let (_, updateError) = try await client.callTool(
            name: "update_grid", arguments: ["docId": "d", "id": "GRID-1", "tags": []])
        #expect(updateError != true)
        let updateRequest = try #require(await device.receivedRequests.last)
        let updated = try #require(JSONSerialization.jsonObject(with: updateRequest.spec) as? [String: Any])
        #expect(Set(updated.keys) == ["op", "id", "tags"])
        #expect(updated["tags"] as? [String] == [])

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip.
    @Test func addGridUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "add_grid", arguments: ["docId": "ghost"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        // Fast-fail: the device must never be contacted for an unknown doc.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// The exact relayed envelope: `id` plus only the supplied optional
    /// fields — mirrors `addGridRelaysEnvelopeAndSurfacesId`'s present-only
    /// assertion.
    @Test func updateGridRelaysIdAndSuppliedFieldsOnly() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","marker":"grid-updated"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(modifiedBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "update_grid",
            arguments: ["docId": "d", "id": "GRID-1", "spacing": 40, "visible": false])
        #expect(isError != true)
        #expect(toolResultText(content).contains("GRID-1"))

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "updateGrid")
        #expect(spec["id"] as? String == "GRID-1")
        #expect(Set(spec.keys) == ["op", "id", "spacing", "visible"])
        #expect(spec["spacing"] as? Double == 40)
        #expect(spec["visible"] as? Bool == false)

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip.
    @Test func updateGridUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "update_grid", arguments: ["docId": "ghost", "id": "GRID-1", "spacing": 40])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        // Fast-fail: the device must never be contacted for an unknown doc.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func removeGridRelaysOpAndId() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","marker":"grid-removed"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(modifiedBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "remove_grid", arguments: ["docId": "d", "id": "GRID-1"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("GRID-1"))

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "removeGrid")
        #expect(spec["id"] as? String == "GRID-1")
        #expect(Set(spec.keys) == ["op", "id"])

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip.
    @Test func removeGridUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "remove_grid", arguments: ["docId": "ghost", "id": "GRID-1"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        // Fast-fail: the device must never be contacted for an unknown doc.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func setGridOriginRelaysIdAndCoordinates() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","marker":"grid-origin-set"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(modifiedBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "set_grid_origin",
            arguments: ["docId": "d", "id": "GRID-1", "canvasX": 123.5, "canvasY": 45.0])
        #expect(isError != true)
        #expect(toolResultText(content).contains("GRID-1"))

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "setGridOrigin")
        #expect(spec["id"] as? String == "GRID-1")
        #expect(Set(spec.keys) == ["op", "id", "canvasX", "canvasY"])
        #expect(spec["canvasX"] as? Double == 123.5)
        #expect(spec["canvasY"] as? Double == 45.0)

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip.
    @Test func setGridOriginUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "set_grid_origin",
            arguments: ["docId": "ghost", "id": "GRID-1", "canvasX": 0, "canvasY": 0])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        // Fast-fail: the device must never be contacted for an unknown doc.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// The exact relayed envelope: `{op:"reorderGrids", orderedIds:[...]}`,
    /// capability "authorGrids" (proven by the fake device only advertising
    /// that capability — mirrors every other grid tool's device harness) —
    /// mirrors `removeGridRelaysOpAndId`'s minimal-envelope assertion.
    @Test func reorderGridsRelaysOrderedIdsAndCapability() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","marker":"grids-reordered"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(modifiedBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_grids",
            arguments: ["docId": "d", "orderedIds": ["id1", "id2"]])
        #expect(isError != true)
        #expect(toolResultText(content).contains("2"))

        let received = try #require(await device.receivedRequests.first)
        #expect(received.docId == "d")
        #expect(received.docBytes == Fixtures.docBytes)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "reorderGrids")
        #expect(Set(spec.keys) == ["op", "orderedIds"])
        #expect(spec["orderedIds"] as? [String] == ["id1", "id2"])

        await server.stop()
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip.
    @Test func reorderGridsUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_grids", arguments: ["docId": "ghost", "orderedIds": ["id1"]])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        // Fast-fail: the device must never be contacted for an unknown doc.
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// `orderedIds: []` is a VALID no-op (a 0-grid document reorders to
    /// nothing) — it must relay to the device, NOT be rejected as a
    /// server-side empty-array argument error. The device (Task 1) is what
    /// decides count-vs-gridCount validity; the server relays verbatim.
    @Test func reorderGridsEmptyOrderedIdsRelays() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let modifiedBytes = Data(#"{"aaa001_thumbnailData":"","marker":"grids-reordered-empty"}"#.utf8)
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(modifiedBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_grids",
            arguments: ["docId": "d", "orderedIds": []])
        #expect(isError != true)

        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "reorderGrids")
        #expect(spec["orderedIds"] as? [String] == [])

        await server.stop()
    }

    /// Absent `orderedIds` -> a server-side `missingArgument`, short-circuiting
    /// BEFORE any device round trip — distinct from the present-but-empty
    /// no-op case above.
    @Test func reorderGridsMissingOrderedIdsErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorGrids"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_grids", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content) == "missingArgument: orderedIds")

        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// The clones' ids come back under `created…`, not under the argument names.
    ///
    /// `copy_elements` TAKES `strokeIds` (elements in the SOURCE) and used to REPORT the new
    /// clones under the same word — one call using each name for two things, and a reply that
    /// reads like an echo of what was sent. Found by using the tool, not by reading it.
    @Test func copyElementsNamesTheClonesDistinctlyFromItsArguments() async throws {
        let (server, port, task) = try await startServer(seedDocId: "t", bytes: Fixtures.docBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await seedDocViaReplaceDoc(
            client, docId: "s", bytes: Data(#"{"aaa001_thumbnailData":"","marker":"source"}"#.utf8))
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(
                bytes: Data(#"{"aaa001_thumbnailData":"","m":"copied"}"#.utf8),
                meta: Data(#"{"createdStrokeKeys":["new-1"],"createdTextIds":[],"createdImageIds":["img-1"]}"#.utf8)),
            capabilities: ["copyElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "copy_elements", arguments: [
            "source": "s", "target": "t", "strokeIds": .array([.string("old-1")]),
        ])
        #expect(isError != true)
        let text = toolResultText(content)
        #expect(text.contains("createdStrokeIds: new-1"))
        #expect(text.contains("createdImageIds: img-1"))
        #expect(!text.contains("\nstrokeIds:"), "the clones must not reuse the argument's name")

        await server.stop()
    }

    // MARK: - strict arguments, declared and enforced (2026-07-29)

    /// EVERY tool advertises `additionalProperties: false`, which is the standard way to say "the
    /// arguments are these and nothing else". Declaring it — rather than only checking at call
    /// time — puts the constraint in `tools/list`, where a client-side validator can catch a
    /// misspelling before the request is sent.
    @Test func everyToolDeclaresItsArgumentsClosed() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        #expect(!tools.isEmpty)
        for tool in tools {
            guard case .object(let schema) = tool.inputSchema else {
                Issue.record("\(tool.name) has no object schema"); continue
            }
            #expect(schema["additionalProperties"] == .bool(false),
                    "\(tool.name) does not declare additionalProperties: false")
        }

        await server.stop()
    }

    /// A tool may not ADVERTISE an argument its handler ignores. Strictness cannot catch this —
    /// the argument IS declared — so it is the mirror image of the `scale` bug and just as silent:
    /// the caller passes it, the reply looks fine, and nothing happened.
    ///
    /// `restyle_strokes` advertised `tags` for one commit (my own tags rename added it to the
    /// schema; restyling does not tag, `tag_elements` does) and forwarded only colour, width and
    /// ink. Spot-checked here for the tools whose forwarded set is a plain literal list.
    @Test func restyleStrokesDoesNotAdvertiseAnArgumentItIgnores() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        let tool = try #require(tools.first { $0.name == "restyle_strokes" })
        let declared = MCPAdapter.declaredArguments(of: tool)
        #expect(declared == ["docId", "ids", "color", "stampWidth", "inkType", "colorAppearance"],
                "restyle_strokes declares \(declared.sorted()) — every one must reach the device")

        await server.stop()
    }

    /// A schema may not REQUIRE an argument it does not declare — with `additionalProperties:
    /// false` that combination makes a tool uncallable: `required` says send it, `properties` says
    /// it is forbidden. Four tools were in exactly that state, left behind by the
    /// explicit-coordinate-spaces rename (`x`/`y` became `canvasX`/`canvasY` in the properties
    /// and not in the required list), and nothing noticed until strictness made it fatal.
    @Test func noToolRequiresAnArgumentItDoesNotDeclare() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (tools, _) = try await client.listTools()
        for tool in tools {
            guard case .object(let schema) = tool.inputSchema else { continue }
            guard case .array(let required)? = schema["required"] else { continue }
            let declared = MCPAdapter.declaredArguments(of: tool)
            for entry in required {
                guard case .string(let name) = entry else { continue }
                #expect(declared.contains(name),
                        "\(tool.name) requires \(name) but does not declare it")
            }
        }

        await server.stop()
    }

    /// …and the same rule is enforced at call time, for callers that do not validate. The reply
    /// names the offending argument AND what the tool takes, so it is fixable in one step.
    @Test func anUnknownArgumentIsRefusedByName() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        // `width` is exactly the mistake this caught in this suite: restyle_strokes takes
        // `stampWidth` since the coordinate-space rename, and `width` was being dropped in silence.
        let (content, isError) = try await client.callTool(
            name: "restyle_strokes",
            arguments: ["docId": "d", "ids": .array([.string("1-2")]), "width": .double(3)])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("invalidArgument: width"))
        #expect(toolResultText(content).contains("stampWidth"), "must name what the tool DOES take")

        await server.stop()
    }

    /// A correct call is unaffected — the check must not become a second place that rejects
    /// legitimate arguments.
    @Test func aFullyCorrectCallIsUntouchedByTheCheck() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "restyle_strokes",
            arguments: ["docId": "ghost", "ids": .array([.string("1-2")]), "stampWidth": .double(3)])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"), "should fail on the DOC, not the args")

        await server.stop()
    }

    // MARK: - render_sketch scale, and unknown arguments (2026-07-29)

    /// `scale` reaches the device. It did not exist before: the relay is an ALLOW-LIST, so a
    /// `scale` argument was silently dropped and every render came back at a size the caller had
    /// not chosen — passed on every call of a long session before anyone noticed.
    @Test func renderSketchRelaysScale() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytesWithMeta(bytes: Data([0x89, 0x50]),
                                                  meta: Data(#"{"scale":4}"#.utf8)))
        defer { Task { await device.close() } }

        _ = try await client.callTool(name: "render_sketch",
                                      arguments: ["docId": "d", "scale": .double(4)])
        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["scale"] as? Double == 4)

        await server.stop()
    }

    /// An argument the tool does not know is REJECTED by name, not dropped. Dropping is what hid
    /// the missing `scale`: the render came back plausible and wrong, and nothing said so.
    @Test func renderSketchRejectsAnUnknownArgument() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Data([0x89, 0x50])))
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "render_sketch", arguments: ["docId": "d", "canvasRECT": .array([.int(0)])])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("invalidArgument: canvasRECT"))
        // …and it names what the tool does take, so the caller can fix it in one step.
        #expect(toolResultText(content).contains("canvasRect"))
        #expect(await device.receivedRequests.isEmpty, "a bad argument must not reach the device")

        await server.stop()
    }

    // MARK: - reply shapes are documented (2026-07-29 drive finding)

    /// Every tool that answers with structured JSON must NAME its reply's keys in its own
    /// description.
    ///
    /// This exists because `get_selection` did not, and the natural guesses were all wrong — it
    /// returns `elements`/`canvasBounds`/`canvasRect`, not `strokes`/`bounds`/`rect`. Reading an
    /// absent JSON key yields nothing rather than an error, so a wrong guess is indistinguishable
    /// from an empty selection: I read "0 strokes" twice while three elements were selected and
    /// nearly filed a bug against the swipe handling.
    ///
    /// The keys below were taken from LIVE replies, not from the source. The rename that broke
    /// this the first time (`bbox` → `canvasInkBounds` and friends) would fail here now.
    @Test func everyStructuredReplyNamesItsKeys() async throws {
        let expected: [String: [String]] = [
            "list_strokes": ["canvasInkBounds", "canvasPathBounds", "stampWidth", "tags"],
            "get_strokes": ["canvasPoints", "canvasPathBounds", "localToCanvasTransform"],
            "list_texts": ["canvasBounds", "pinned", "opacity", "tags"],
            "list_images": ["canvasBounds", "pinned", "opacity", "tags"],
            "list_tags": ["roof", "elements", "grids"],
            "find_elements": ["roof"],
            "list_docs": ["sizeBytes", "modifiedAt", "hasContent", "open"],
            "snap_points": ["canvasPoint", "candidates", "canvasPosition", "distance", "kind", "parents"],
            "list_grids": ["families", "drawSpacing", "snapSpacing", "lineAngleDeg", "tags"],
            "get_selection": ["elements", "canvasBounds", "canvasRect", "canvasReferencePoint",
                              "active", "sessionActive", "uncommittedCopy"],
            "get_tool": ["inkType", "toolWidth", "stampWidth"],
            "list_open_docs": ["openDocs", "docId", "capabilities"],
            "draw_strokes": ["storedColors"],
            "restyle_strokes": ["storedColor"],
            "fill_region": ["storedColors"],
            "draw_dots": ["storedColors"],
        ]
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (tools, _) = try await client.listTools()

        for (name, keys) in expected {
            let tool = try #require(tools.first { $0.name == name }, "no tool named \(name)")
            let description = tool.description ?? ""
            for key in keys {
                #expect(description.contains(key),
                        "\(name)'s description never mentions its reply key \(key)")
            }
        }

        await server.stop()
    }

    // MARK: - draw_dots (2026-07-28 dot design)

    /// The envelope the device decodes. Relayed verbatim, so every per-dot field keeps its name
    /// across the seam — the half-rename that shipped `reshape_strokes` broken once.
    @Test func drawDotsRelaysItsEnvelopeAndReportsTheCount() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data(#"{"aaa001_thumbnailData":"","m":"dotted"}"#.utf8),
                                      meta: Data(#"{"keys":["a-1","b-2"]}"#.utf8)),
            capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "draw_dots", arguments: [
            "docId": "d",
            "dots": .array([
                .object(["canvasX": .int(10), "canvasY": .int(20), "diameter": .double(6)]),
                .object(["canvasX": .int(30), "canvasY": .int(40), "name": .string("node.b")]),
            ]),
        ])
        #expect(isError != true)
        #expect(toolResultText(content).contains("2 dot(s)"))

        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "drawDots")
        let dots = try #require(spec["dots"] as? [[String: Any]])
        #expect(dots.count == 2)
        #expect(dots[0]["canvasX"] as? Double == 10)
        #expect(dots[0]["diameter"] as? Double == 6)
        #expect(dots[1]["name"] as? String == "node.b")

        await server.stop()
    }

    /// A diameter the ink cannot draw that small is RAISED, and the caller is told — the same
    /// contract `draw_strokes` has for widths. A plot whose markers quietly grew would not match
    /// its own legend.
    @Test func drawDotsReportsADiameterItHadToRaise() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data(#"{"aaa001_thumbnailData":"","m":"dotted"}"#.utf8),
                                      meta: Data(#"{"keys":["a-1"],"clampedDiameters":[1.5]}"#.utf8)),
            capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, _) = try await client.callTool(name: "draw_dots", arguments: [
            "docId": "d",
            "dots": .array([.object(["canvasX": .int(0), "canvasY": .int(0),
                                     "diameter": .double(1.5)])]),
        ])
        #expect(toolResultText(content).contains("1.5"))
        #expect(toolResultText(content).lowercased().contains("raised"))

        await server.stop()
    }

    /// `draw_dots` reuses `draw`'s meta through `DotAuthoring.annotated`, so `storedColors`
    /// (what the dark door actually stored, light-canonical) must survive that merge and reach
    /// the reply text — exactly the `draw_strokes` contract, just for dots.
    @Test func drawDotsReportsStoredColorsWhenTheDarkDoorConverts() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(
                bytes: Data(#"{"aaa001_thumbnailData":"","m":"dotted"}"#.utf8),
                meta: Data(##"{"keys":["a-1"],"storedColors":["#808080FF"]}"##.utf8)),
            capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "draw_dots", arguments: [
            "docId": "d",
            "dots": .array([.object(["canvasX": .int(0), "canvasY": .int(0),
                                     "color": .string("#808080")])]),
            "colorAppearance": .string("dark"),
        ])
        #expect(isError != true)
        #expect(toolResultText(content).contains("storedColors: #808080FF"))

        await server.stop()
    }

    /// A call that never went through the dark door must NOT grow a `storedColors` line — an
    /// absent key, not an empty one, so an unrelated draw_dots reply stays exactly as before.
    @Test func drawDotsOmitsStoredColorsWithoutTheDarkDoor() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data(#"{"aaa001_thumbnailData":"","m":"dotted"}"#.utf8),
                                      meta: Data(#"{"keys":["a-1"]}"#.utf8)),
            capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, _) = try await client.callTool(name: "draw_dots", arguments: [
            "docId": "d",
            "dots": .array([.object(["canvasX": .int(0), "canvasY": .int(0)])]),
        ])
        #expect(!toolResultText(content).contains("storedColors"))

        await server.stop()
    }

    @Test func drawDotsUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "draw_dots",
            arguments: ["docId": "ghost",
                        "dots": .array([.object(["canvasX": .int(0), "canvasY": .int(0)])])])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    // MARK: - fill_region (2026-07-28 fill design)

    /// The envelope the device decodes. Relayed verbatim like `draw_strokes`, so the boundary and
    /// every optional keep their names across the seam.
    @Test func fillRegionRelaysItsEnvelopeAndReportsTheStrokeCount() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data(#"{"aaa001_thumbnailData":"","m":"filled"}"#.utf8),
                                      meta: Data(#"{"keys":["a-1","b-2","c-3"]}"#.utf8)),
            capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "fill_region", arguments: [
            "docId": "d",
            "canvasPoints": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(0)]),
                                    .array([.int(10), .int(10)])]),
            "spacingRatio": .double(0.5),
            "angleDeg": .double(45),
        ])
        #expect(isError != true)
        // The count is the cost the caller just took on, so it is in the reply rather than
        // discovered later in list_strokes.
        #expect(toolResultText(content).contains("3 stroke(s)"))

        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "fillRegion")
        #expect((spec["canvasPoints"] as? [Any])?.count == 3)
        #expect(spec["spacingRatio"] as? Double == 0.5)
        #expect(spec["angleDeg"] as? Double == 45)
    }

    /// `fill_region` returns `StrokeAuthoring.perform`'s meta wholesale, so `storedColors` (what
    /// the dark door actually stored, light-canonical) reaches the reply text unmodified —
    /// exactly the `draw_strokes` contract.
    @Test func fillRegionReportsStoredColorsWhenTheDarkDoorConverts() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(
                bytes: Data(#"{"aaa001_thumbnailData":"","m":"filled"}"#.utf8),
                meta: Data(##"{"keys":["a-1","b-2"],"storedColors":["#808080FF","#808080FF"]}"##.utf8)),
            capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "fill_region", arguments: [
            "docId": "d",
            "canvasPoints": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(0)]),
                                    .array([.int(10), .int(10)])]),
            "color": .string("#808080"),
            "colorAppearance": .string("dark"),
        ])
        #expect(isError != true)
        #expect(toolResultText(content).contains("storedColors: #808080FF, #808080FF"))

        await server.stop()
    }

    /// A call that never went through the dark door must NOT grow a `storedColors` line.
    @Test func fillRegionOmitsStoredColorsWithoutTheDarkDoor() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Data(#"{"aaa001_thumbnailData":"","m":"filled"}"#.utf8),
                                      meta: Data(#"{"keys":["a-1"]}"#.utf8)),
            capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, _) = try await client.callTool(name: "fill_region", arguments: [
            "docId": "d",
            "canvasPoints": .array([.array([.int(0), .int(0)]), .array([.int(10), .int(0)]),
                                    .array([.int(10), .int(10)])]),
        ])
        #expect(!toolResultText(content).contains("storedColors"))

        await server.stop()
    }

    @Test func fillRegionUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["authorStrokes"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "fill_region",
            arguments: ["docId": "ghost",
                        "canvasPoints": .array([.array([.int(0), .int(0)])])])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    @Test func fillRegionWithNoBoundaryErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "fill_region", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).contains("canvasPoints"))

        await server.stop()
    }

    // MARK: - undo_last_edit (2026-07-28 agent-undo design)

    /// THE ONE THAT MATTERS MOST. Recording lives at the MCP layer, not in
    /// `DocumentSession.submit`, because that is shared with the APP's own settle-push — and
    /// recording those would make "undo the last edit" capable of reverting the user's drawing.
    /// Mutation-verify by moving the record call into `submit`: this must fail.
    @Test func theAppsOwnPushIsNotUndoable() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        // An APP push: straight up the WS `op` path, exactly as the mirror's settle-push arrives.
        let device = try await FakeCreateDocDevice(port: port, autoReplyBytes: nil)
        defer { Task { await device.close() } }
        try await device.push(docId: "d", bytes: Data(#"{"aaa001_thumbnailData":"","m":"app"}"#.utf8))
        try await Task.sleep(for: .milliseconds(200))

        let (content, isError) = try await client.callTool(
            name: "undo_last_edit", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("nothingToUndo"))

        await server.stop()
    }

    /// With nothing recorded at all, undo says so rather than doing something surprising.
    @Test func undoWithNoRecordedEditReportsNothingToUndo() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "undo_last_edit", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("nothingToUndo"))

        await server.stop()
    }

    @Test func undoOnAnUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "undo_last_edit", arguments: ["docId": "ghost"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        await server.stop()
    }

    @Test func undoRejectsAStepCountBelowOne() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "undo_last_edit", arguments: ["docId": "d", "steps": 0])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArguments")

        await server.stop()
    }

    /// An AGENT write IS undoable, and — with nothing changed since — the document comes back
    /// byte-for-byte, on the server's fast path with no device round trip for the merge.
    @Test func anAgentWriteIsUndoneExactly() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let modified = Data(#"{"aaa001_thumbnailData":"","marker":"agent wrote this"}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(modified),
                                                  capabilities: ["authorStrokes", "mergeDocs"])
        defer { Task { await device.close() } }

        let before = try await rawDocument(client, "d")
        let (_, drewError) = try await client.callTool(
            name: "draw_strokes",
            arguments: ["docId": "d", "strokes": [["canvasPoints": [[0, 0], [10, 10]]]]])
        #expect(drewError != true)
        #expect(try await rawDocument(client, "d") == modified)

        let (content, isError) = try await client.callTool(
            name: "undo_last_edit", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content).hasPrefix("undid 1 edit(s) in d"))
        #expect(try await rawDocument(client, "d") == before)

        await server.stop()
    }

    /// Repeated undo WALKS BACK — it does not ping-pong. The undo's own write is deliberately
    /// not recorded: recording it would make this second call reverse the FIRST UNDO instead of
    /// the edit before it, which contradicts one-undo-is-one-tool-call. Found by testing.
    @Test func repeatedUndoWalksBackRatherThanUndoingTheUndo() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytes(Data(#"{"aaa001_thumbnailData":"","marker":"agent"}"#.utf8)),
            capabilities: ["authorStrokes", "mergeDocs"])
        defer { Task { await device.close() } }

        let original = try await rawDocument(client, "d")
        _ = try await client.callTool(name: "draw_strokes",
                                      arguments: ["docId": "d", "strokes": [["canvasPoints": [[0, 0], [10, 10]]]]])
        _ = try await client.callTool(name: "undo_last_edit", arguments: ["docId": "d"])
        #expect(try await rawDocument(client, "d") == original)

        // Only one edit was ever recorded, so there is nothing further back to reach — and
        // crucially the document does NOT bounce forward to the post-draw state.
        let (content, isError) = try await client.callTool(
            name: "undo_last_edit", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("nothingToUndo"))
        #expect(try await rawDocument(client, "d") == original, "undo must not ping-pong")

        await server.stop()
    }

    /// Two agent edits, two undos, back to the start — the model the granularity decision implies.
    @Test func twoUndosWalkBackTwoEdits() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytes(Data(#"{"aaa001_thumbnailData":"","marker":"first"}"#.utf8)),
            capabilities: ["authorStrokes", "mergeDocs"])
        let original = try await rawDocument(client, "d")
        _ = try await client.callTool(name: "draw_strokes",
                                      arguments: ["docId": "d", "strokes": [["canvasPoints": [[0, 0], [1, 1]]]]])
        let afterFirst = try await rawDocument(client, "d")
        await device.close()

        let second = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytes(Data(#"{"aaa001_thumbnailData":"","marker":"second"}"#.utf8)),
            capabilities: ["authorStrokes", "mergeDocs"])
        defer { Task { await second.close() } }
        _ = try await client.callTool(name: "draw_strokes",
                                      arguments: ["docId": "d", "strokes": [["canvasPoints": [[2, 2], [3, 3]]]]])

        _ = try await client.callTool(name: "undo_last_edit", arguments: ["docId": "d"])
        #expect(try await rawDocument(client, "d") == afterFirst)
        _ = try await client.callTool(name: "undo_last_edit", arguments: ["docId": "d"])
        #expect(try await rawDocument(client, "d") == original)

        await server.stop()
    }

    /// Deleting a document forgets what the agent did to it. Without this a recycled name
    /// inherits the previous document's history, and an undo reaches content that was never in
    /// THIS document — found by an E2E whose second run saw the first run's edits.
    @Test func deletingADocumentForgetsItsUndoHistory() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytes(Data(#"{"aaa001_thumbnailData":"","marker":"agent"}"#.utf8)),
            capabilities: ["authorStrokes", "mergeDocs"])
        defer { Task { await device.close() } }

        _ = try await client.callTool(name: "draw_strokes",
                                      arguments: ["docId": "d", "strokes": [["canvasPoints": [[0, 0], [1, 1]]]]])
        _ = try await client.callTool(name: "delete_doc", arguments: ["docId": "d"])
        // Re-create under the SAME name — a different document that happens to share it. An app
        // push is the honest way to do that here: it is how a device re-creating a deleted
        // document actually arrives.
        let app = try await FakeCreateDocDevice(port: port, autoReplyBytes: nil)
        defer { Task { await app.close() } }
        try await app.push(docId: "d", bytes: Data(#"{"aaa001_thumbnailData":"","m":"reborn"}"#.utf8))
        try await Task.sleep(for: .milliseconds(200))

        let (content, isError) = try await client.callTool(
            name: "undo_last_edit", arguments: ["docId": "d"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("nothingToUndo"))

        await server.stop()
    }

    // MARK: - the agent guide resource

    /// Everything learned about this surface was going into the repository's CLAUDE.md, which an
    /// agent driving the MCP API never reads. The guide puts the cross-cutting parts where they
    /// can actually be found. Listed FIRST, because it is the one to read before picking a tool.
    @Test func theGuideIsListedFirstAndReadable() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (resources, _) = try await client.listResources()
        #expect(resources.first?.uri == "infsketch://guide")
        #expect(resources.first?.mimeType == "text/markdown")

        let contents = try await client.readResource(uri: "infsketch://guide")
        let text = try #require(contents.compactMap(\.text).first)
        #expect(text.count > 1000, "a guide short enough to be useless is not worth serving")

        // The traps that actually cost time, each of which must survive an edit of the guide.
        // Case-insensitive: the guide capitalises some of these for emphasis, and a test that
        // pins the emphasis rather than the content would fight every future edit.
        let lowered = text.lowercased()
        for essential in ["40 000", "viewport", "canvas space", "width", "polyline",
                          "translucent", "undo_last_edit", "snap_points", "light-canonical",
                          "colorappearance"] {
            #expect(lowered.contains(essential.lowercased()),
                    "the guide no longer mentions \(essential)")
        }

        await server.stop()
    }

    @Test func anUnknownResourceIsStillRejected() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        await #expect(throws: (any Error).self) {
            _ = try await client.readResource(uri: "infsketch://guidebook")
        }

        await server.stop()
    }

    // MARK: - list_docs (2026-07-28 usage-session finding 1)

    /// Every tool takes a `docId`, and until this one no TOOL could tell you what they are — the
    /// listing existed only as the `infsketch://docs` RESOURCE, so the tool-shaped way to discover
    /// a document was to guess wrong and read `unknownDoc`'s error.
    @Test func listDocsReportsEveryDocumentOnTheServer() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(name: "list_docs", arguments: [:])
        #expect(isError != true)
        let rows = try #require(
            JSONSerialization.jsonObject(with: Data(toolResultText(content).utf8)) as? [[String: Any]])
        #expect(rows.contains { $0["id"] as? String == "d" })
        let seeded = try #require(rows.first { $0["id"] as? String == "d" })
        #expect(seeded["hasContent"] as? Bool == true)
        // Nothing has subscribed, so nothing is on anyone's screen.
        #expect(seeded["open"] as? Bool == false)
        #expect(seeded["sizeBytes"] != nil)
        #expect(seeded["modifiedAt"] != nil)

        await server.stop()
    }

    /// `open` is the field that says "your writes will land on the user's canvas right now".
    @Test func listDocsMarksADocumentThatIsOpen() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Fixtures.docBytes),
                                                  capabilities: ["authorStrokes"], subscribeTo: "d")
        defer { Task { await device.close() } }

        let (content, _) = try await client.callTool(name: "list_docs", arguments: [:])
        let rows = try #require(
            JSONSerialization.jsonObject(with: Data(toolResultText(content).utf8)) as? [[String: Any]])
        #expect(rows.first { $0["id"] as? String == "d" }?["open"] as? Bool == true)

        await server.stop()
    }

    // MARK: - tag_elements / find_elements / list_tags (element tags, 2026-07-28)

    /// The tagging ops are device-relayed for the same reason `list_strokes` is: validating that
    /// an id EXISTS means enumerating stroke composite keys, and only PencilKit can decode a
    /// drawing. This pins the envelope the device decodes (`ElementTagging.TagSpec`, app repo) — a
    /// plain `Decodable`, so a field-name drift here would fail SILENTLY on one side of the wire.
    @Test func tagElementsRelaysSpecAndCapability() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let modified = Data(#"{"aaa001_thumbnailData":"","marker":"tagged"}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(modified), capabilities: ["tagElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "tag_elements",
            arguments: ["docId": "d", "ids": ["k1", "k2"], "tags": ["roof", "revision-2"]])
        #expect(isError != true)
        #expect(toolResultText(content).contains("2 element(s) in d"))
        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "tagElements")
        #expect(spec["ids"] as? [String] == ["k1", "k2"])
        #expect(spec["tags"] as? [String] == ["roof", "revision-2"])
        // The default, sent explicitly so the device never has to guess.
        #expect(spec["mode"] as? String == "add")

        await server.stop()
    }

    /// SEVERAL ids at once is the ordinary case now — a tag covers a set. The old single-name rule
    /// rejected this, and that rejection is what tags exist to remove.
    @Test func tagElementsAcceptsManyIdsAndModes() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let modified = Data(#"{"aaa001_thumbnailData":"","marker":"tagged"}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(modified), capabilities: ["tagElements"])
        defer { Task { await device.close() } }

        for (mode, verb) in [("add", "added"), ("remove", "removed"), ("replace", "replaced")] {
            let (content, isError) = try await client.callTool(
                name: "tag_elements",
                arguments: ["docId": "d", "ids": ["a", "b", "c"], "tags": ["roof"], "mode": .string(mode)])
            #expect(isError != true, "mode \(mode) was rejected")
            // Real words, not "\(mode)ed" — which produced "removeed" on a device.
            #expect(toolResultText(content).contains(verb))
        }
        // …and `replace` with no tags is the CLEAR, so it must not be treated as a missing argument.
        let (_, clearError) = try await client.callTool(
            name: "tag_elements",
            arguments: ["docId": "d", "ids": ["a"], "tags": .array([]), "mode": "replace"])
        #expect(clearError != true)

        await server.stop()
    }

    /// …while add/remove of NOTHING is a caller mistake worth naming rather than a silent no-op,
    /// and an unknown mode never reaches the device.
    @Test func tagElementsRejectsAnEmptyAddAndABadMode() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["tagElements"])
        defer { Task { await device.close() } }

        let (empty, emptyError) = try await client.callTool(
            name: "tag_elements", arguments: ["docId": "d", "ids": ["a"], "tags": .array([])])
        #expect(emptyError == true)
        #expect(toolResultText(empty).hasPrefix("invalidArgument: tags"))

        let (bad, badError) = try await client.callTool(
            name: "tag_elements",
            arguments: ["docId": "d", "ids": ["a"], "tags": ["roof"], "mode": "sideways"])
        #expect(badError == true)
        #expect(toolResultText(bad).hasPrefix("invalidArgument: mode"))
        #expect(await device.receivedRequests.isEmpty, "a bad shape must not reach the device")

        await server.stop()
    }

    @Test func tagElementsUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["tagElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "tag_elements", arguments: ["docId": "ghost", "ids": ["k1"], "tags": ["roof"]])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// A tag resolves to MANY ids, so the reply is a map of lists — the shape change from the
    /// single-name `{name: id}` this replaced.
    @Test func findElementsReturnsTheTagToIdsMap() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Fixtures.docBytes,
                                      meta: Data(#"{"roof":["k1","k2"]}"#.utf8)),
            capabilities: ["tagElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "find_elements", arguments: ["docId": "d", "tags": ["roof"]])
        #expect(isError != true)
        #expect(toolResultText(content) == #"{"roof":["k1","k2"]}"#)
        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "findElements")
        #expect(spec["tags"] as? [String] == ["roof"])

        await server.stop()
    }

    @Test func findElementsUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["tagElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "find_elements", arguments: ["docId": "ghost", "tags": ["roof"]])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        await server.stop()
    }

    /// `list_tags` takes no list argument at all — it is the "what is in here?" read an agent
    /// needs before it can ask for anything by name.
    @Test func listTagsRelaysAndPassesTheCountsThrough() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port,
            autoReply: .bytesWithMeta(bytes: Fixtures.docBytes,
                                      meta: Data(#"{"roof":7,"sky":1}"#.utf8)),
            capabilities: ["tagElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(name: "list_tags", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content) == #"{"roof":7,"sky":1}"#)
        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "listTags")
        #expect(spec["tags"] == nil, "list_tags sends no tag list")

        await server.stop()
    }

    // MARK: - reorder_elements (agent-element-zorder, Task 2)
    //
    // Bring-to-front/send-to-back for strokes/texts/images, authored by a
    // connected device — the same shape as reorder_grids above, but WITHIN
    // one document's element z-order rather than the grid stack. Relays
    // {op:"reorderElements", strokeIds, textIds, imageIds, mode} through
    // broker.requestStrokeOp, gated on the "reorderElements" capability, and
    // writes the reply back under the standard byte-CAS.

    /// The exact relayed envelope and capability — mirrors
    /// `reorderGridsRelaysOrderedIdsAndCapability`'s minimal-envelope
    /// assertion.
    @Test func reorderElementsRelaysSpecAndCapability() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let modified = Data(#"{"aaa001_thumbnailData":"","marker":"reordered"}"#.utf8)
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(modified), capabilities: ["reorderElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_elements", arguments: ["docId": "d", "strokeIds": ["k1"], "mode": "front"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("moved 1 element(s) to front in d"))
        let received = try #require(await device.receivedRequests.first)
        let spec = try #require(JSONSerialization.jsonObject(with: received.spec) as? [String: Any])
        #expect(spec["op"] as? String == "reorderElements")
        #expect(spec["mode"] as? String == "front")
        #expect(spec["strokeIds"] as? [String] == ["k1"])
    }

    /// `docId` not in the store -> `unknownDoc`, short-circuiting BEFORE any
    /// device round trip.
    @Test func reorderElementsUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(
            port: port, autoReply: .bytes(Fixtures.docBytes), capabilities: ["reorderElements"])
        defer { Task { await device.close() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_elements", arguments: ["docId": "ghost", "strokeIds": ["k1"], "mode": "front"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))
        #expect(await device.receivedRequests.isEmpty)

        await server.stop()
    }

    /// `mode` outside {"front", "back"} -> `invalidArguments`, checked before
    /// the document is even looked up.
    @Test func reorderElementsBadModeErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_elements", arguments: ["docId": "d", "strokeIds": ["k1"], "mode": "sideways"])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArguments")

        await server.stop()
    }

    /// No ids at all (strokeIds/textIds/imageIds all omitted) ->
    /// `invalidArguments`.
    @Test func reorderElementsNoIdsErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_elements", arguments: ["docId": "d", "mode": "front"])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArguments")

        await server.stop()
    }

    /// An ABSENT `mode` is `missingArgument: mode` (a required arg), distinct from a
    /// bad-VALUE `mode` (`invalidArguments`) — the required-arg convention set_pinned's
    /// `pinned` also uses. (A `mode`-value error is `invalidArguments`; a `mode`-absent
    /// error names the arg.)
    @Test func reorderElementsMissingModeErrors() async throws {
        let (server, port, task) = try await startServer()  // seeds "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "reorder_elements", arguments: ["docId": "d", "strokeIds": ["k1"]])
        #expect(isError == true)
        #expect(toolResultText(content) == "missingArgument: mode")

        await server.stop()
    }

    // MARK: - set_paper (agent-doc-appearance, Task 2)
    //
    // Entirely server-side (pure JSON field-writing via DocJSON.setPaper, no
    // device, no capability) -- mirrors set_pinned's shape: seed a doc with
    // paper fields directly via `startServer(bytes:)`, the same seeding seam
    // `setPinnedFlipsAndReportsCount` etc. use.

    private static let paperDocBytes = Data(#"""
        {"aaa001_thumbnailData":"","backgroundColor":{"red":1,"green":1,"blue":1,"alpha":1},"backgroundColorDark":{"red":0,"green":0,"blue":0,"alpha":1},"transparentBackground":false,"placedTextsData":[]}
        """#.utf8)

    @Test func setPaperSetsLightAndReports() async throws {
        let (server, port, task) = try await startServer(bytes: Self.paperDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "set_paper", arguments: ["docId": "d", "light": "#112233"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("set paper on d"))
        await server.stop()
    }

    @Test func setPaperUnknownDocErrors() async throws {
        let (server, port, task) = try await startServer(bytes: Self.paperDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (content, isError) = try await client.callTool(
            name: "set_paper", arguments: ["docId": "ghost", "light": "#112233"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))
        await server.stop()
    }

    @Test func setPaperNoFieldsErrors() async throws {
        let (server, port, task) = try await startServer(bytes: Self.paperDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (content, isError) = try await client.callTool(
            name: "set_paper", arguments: ["docId": "d"])   // no light/dark/transparent
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidArguments")
        await server.stop()
    }

    @Test func setPaperBadHexErrors() async throws {
        let (server, port, task) = try await startServer(bytes: Self.paperDocBytes)
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (content, isError) = try await client.callTool(
            name: "set_paper", arguments: ["docId": "d", "light": "nothex"])
        #expect(isError == true)
        #expect(toolResultText(content) == "invalidSpec")
        await server.stop()
    }

    // MARK: - M2c-3: MCP tools auto-fetch a content-on-another-device doc

    /// A content tool called on a doc the server has no bytes for — only metadata via a
    /// connected holder's advertisement — pulls it via `currentBytesOrFetch` first instead
    /// of failing "unknownDoc", and that read PROMOTES the doc to ordinary resident content
    /// (`listDocuments`, the manager-level twin of `/api/docs`, flips `hasContent:true`).
    /// `set_paper` is the lightest content tool exercising this end-to-end through
    /// `handleCallTool`: it's a pure server-side `DocJSON` write with no device relay of its
    /// own, so the ONLY device-shaped part of this test is the fetch itself — seeded via the
    /// same `applyAdvertisements` + `setContentProvider` seam `SubscribeFetchTests` /
    /// `CurrentBytesOrFetchTests` already exercise at the `SessionManager` layer, just driven
    /// here through the real MCP tool call.
    /// The negative of the sweep: `replace_doc` on a metadata-only doc must NOT auto-fetch.
    /// Unlike the read-to-operate tools above, `replace_doc`'s byte read is a create-vs-write
    /// CAS token — the tool overwrites the doc with the agent's opaque bytes, so fetching
    /// content it's about to discard would only block on the holder and, worse, synthesize a
    /// `.matchBytes` token the agent never read (defeating the `.absent` create-CAS). Whole-branch
    /// review caught the mechanical sweep over-reaching to this one `let =` token site. The
    /// content provider FAILS the test if touched; the doc must be created directly (`.absent`).
    @Test func replaceDocOnAContentLessDocDoesNotAutoFetch() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        await server.manager.applyAdvertisements(
            [DocAdvertisement(docId: "Ghost", modifiedAt: Date(timeIntervalSince1970: 0),
                               sizeBytes: Fixtures.docBytes.count, thumbnail: nil)],
            connectionId: UUID(), deviceId: "devA")
        await server.manager.setContentProvider { _, _ in
            Issue.record("replace_doc must not fetch a metadata-only doc it is about to overwrite")
            return Data()
        }

        let before = try await server.manager.listDocuments()
        #expect(before.first { $0.id == "Ghost" }?.hasContent == false)

        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let replacement = Data(#"{"aaa001_thumbnailData":"","marker":"replaced-not-fetched"}"#.utf8)
        let (content, isError) = try await client.callTool(
            name: "replace_doc",
            arguments: ["docId": "Ghost", "bytes": .string(replacement.base64EncodedString())])
        #expect(isError != true)
        #expect(toolResultText(content).contains("replaced Ghost"))

        // Created directly from the agent's bytes (.absent create path) — NOT the fetched content.
        let raw = await server.manager.currentBytes(docId: "Ghost")
        #expect(raw == replacement)

        await server.stop()
    }

    @Test func setPaperAutoFetchesAContentLessDocAndPromotesIt() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        await server.manager.applyAdvertisements(
            [DocAdvertisement(docId: "Ghost", modifiedAt: Date(timeIntervalSince1970: 0),
                               sizeBytes: Fixtures.docBytes.count, thumbnail: nil)],
            connectionId: UUID(), deviceId: "devA")
        await server.manager.setContentProvider { _, _ in Fixtures.docBytes }

        // Before the tool call: "Ghost" is metadata-only (a live-index advertisement, no bytes).
        let before = try await server.manager.listDocuments()
        #expect(before.first { $0.id == "Ghost" }?.hasContent == false)

        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (content, isError) = try await client.callTool(
            name: "set_paper", arguments: ["docId": "Ghost", "light": "#112233"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("set paper on Ghost"))

        // After: auto-fetched from the holder AND promoted to ordinary resident content.
        let after = try await server.manager.listDocuments()
        #expect(after.first { $0.id == "Ghost" }?.hasContent == true)

        await server.stop()
    }

    // MARK: - M2c-3 Task 3: fetch_doc + hasContent on list_resources
    //
    // `fetch_doc` is the EXPLICIT counterpart to the transparent auto-fetch
    // above: the four tests below pin the four outcomes a caller can't tell
    // apart from a plain content-tool call — resident-already,
    // freshly-fetched-and-promoted, known-but-unreachable, and genuinely
    // unknown — by combining `currentBytes` (resident check),
    // `currentBytesOrFetch` (the fetch), and `liveEntry` (known-but-nil).

    /// A content-less doc with a holder: fetch_doc reports "fetched" and promotes it to
    /// ordinary resident content, mirroring the auto-fetch test's seam exactly.
    @Test func fetchDocPromotesAContentLessDoc() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        await server.manager.applyAdvertisements(
            [DocAdvertisement(docId: "Ghost", modifiedAt: Date(timeIntervalSince1970: 0),
                               sizeBytes: Fixtures.docBytes.count, thumbnail: nil)],
            connectionId: UUID(), deviceId: "devA")
        await server.manager.setContentProvider { _, _ in Fixtures.docBytes }

        let before = try await server.manager.listDocuments()
        #expect(before.first { $0.id == "Ghost" }?.hasContent == false)

        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (content, isError) = try await client.callTool(
            name: "fetch_doc", arguments: ["docId": "Ghost"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("fetched"))

        let after = try await server.manager.listDocuments()
        #expect(after.first { $0.id == "Ghost" }?.hasContent == true)

        await server.stop()
    }

    /// A doc the server already holds bytes for: fetch_doc reports "already available"
    /// without touching the (unset) content provider.
    @Test func fetchDocOnResidentReportsAlreadyAvailable() async throws {
        let (server, port, task) = try await startServer()  // seeds doc "d"
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "fetch_doc", arguments: ["docId": "d"])
        #expect(isError != true)
        #expect(toolResultText(content).contains("already available"))

        await server.stop()
    }

    /// A doc known via a live advertisement whose only holder is offline (the provider
    /// throws): fetch_doc reports contentUnavailable, distinct from an unknown doc.
    @Test func fetchDocWithNoOnlineHolderReportsContentUnavailable() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        await server.manager.applyAdvertisements(
            [DocAdvertisement(docId: "Ghost", modifiedAt: Date(timeIntervalSince1970: 0),
                               sizeBytes: Fixtures.docBytes.count, thumbnail: nil)],
            connectionId: UUID(), deviceId: "devA")
        await server.manager.setContentProvider { _, _ in
            throw DeviceCommandBroker.DeviceCommandError.noDeviceAvailable
        }

        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (content, isError) = try await client.callTool(
            name: "fetch_doc", arguments: ["docId": "Ghost"])
        #expect(isError == true)
        #expect(toolResultText(content) == "contentUnavailable")

        await server.stop()
    }

    /// A docId with no live advertisement and no resident bytes at all: fetch_doc reports
    /// unknownDoc, the same reason every other tool uses for a nonexistent document.
    @Test func fetchDocOnGenuinelyUnknownDocReportsUnknownDoc() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "fetch_doc", arguments: ["docId": "TotallyUnknown"])
        #expect(isError == true)
        #expect(toolResultText(content).hasPrefix("unknownDoc"))

        await server.stop()
    }

    /// `list_resources` carries a hasContent-derived hint per document: a metadata-only doc's
    /// `Resource.description` names fetch_doc; a resident doc's description stays nil.
    @Test func listResourcesReportsHasContent() async throws {
        let (server, port, task) = try await startServer()  // seeds resident doc "d"
        defer { task.cancel() }
        await server.manager.applyAdvertisements(
            [DocAdvertisement(docId: "Ghost", modifiedAt: Date(timeIntervalSince1970: 0),
                               sizeBytes: Fixtures.docBytes.count, thumbnail: nil)],
            connectionId: UUID(), deviceId: "devA")

        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (resources, _) = try await client.listResources()

        let ghost = try #require(resources.first { $0.uri == "infsketch://doc/Ghost" })
        #expect(ghost.description?.contains("fetch_doc") == true)
        #expect(ghost.description?.contains("another device") == true)

        let resident = try #require(resources.first { $0.uri == "infsketch://doc/d" })
        #expect(resident.description == nil)

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


@Suite struct DeleteDocToolTests {

    @Test func deleteDocRemovesTheDocumentAndReportsIt() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        // "d" is the harness's seeded document, so it genuinely exists in the store.
        let (content, isError) = try await client.callTool(
            name: "delete_doc", arguments: ["docId": "d"])

        #expect(isError != true)
        #expect(toolResultText(content).contains("deleted d"))

        // And it is really gone: deleting it again no longer finds it.
        let (_, againError) = try await client.callTool(
            name: "delete_doc", arguments: ["docId": "d"])
        #expect(againError == true, "the document should no longer exist")

        await server.stop()
    }

    @Test func deletingAnUnknownDocumentReportsUnknownDoc() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "delete_doc", arguments: ["docId": "Ghost"])

        #expect(isError == true)
        #expect(toolResultText(content).contains("unknownDoc"))

        await server.stop()
    }

    /// An empty docId is an argument error, not a mysterious unknownDoc — and must never reach the
    /// store, whose id sanitising would be the only thing standing between "" and the directory.
    @Test func anEmptyDocIdIsRejectedAsAnArgumentError() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let (content, isError) = try await client.callTool(
            name: "delete_doc", arguments: ["docId": ""])

        #expect(isError == true)
        #expect(toolResultText(content).contains("invalidArgument"))

        await server.stop()
    }

    @Test func theToolIsAdvertisedWithItsRecoverabilityAndResurrectionCaveats() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let tools = try await client.listTools().tools
        let deleteDoc = try #require(tools.first { $0.name == "delete_doc" })
        // An agent must be told both that the delete is recoverable and that it may not stick.
        #expect(deleteDoc.description?.contains(".trash") == true)
        #expect(deleteDoc.description?.contains("re-push") == true)

        await server.stop()
    }
}

// EVERYTHING in this file lives inside the `#if MCP_SSE_CLIENT` above, and this must stay the
// LAST line. A suite appended below it compiles on Linux with no `import Testing` and no
// `startServer`/`connectedClient` — which is exactly what `DeleteDocToolTests` did, breaking
// the Linux build while macOS stayed green, because on macOS the gate is true either way.
#endif  // MCP_SSE_CLIENT
