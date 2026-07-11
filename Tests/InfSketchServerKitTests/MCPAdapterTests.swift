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
        let reject = await server.manager.submit(
            docId: "d", opId: "mcp-adapter-1",
            payload: OpPayload(type: "fullDoc", data: Fixtures.docBytes))
        #expect(reject == nil)

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
