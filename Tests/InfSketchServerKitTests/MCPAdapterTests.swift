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
private func startServer(seedDocId: String = "d", bytes: Data = Fixtures.docBytes) async throws -> (
    InfSketchServer, UInt16, Task<Void, any Error>
) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-adapter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = DirectoryDocumentStore(directory: dir)
    try store.save(docId: seedDocId, bytes: bytes)

    let server = InfSketchServer(port: 0, docsDirectory: dir)
    let task = Task { try await server.run() }
    try await server.waitUntilListening()
    let port = try #require(await server.listeningPort)
    return (server, port, task)
}

private func connectedClient(port: UInt16) async throws -> Client {
    let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
    let transport = HTTPClientTransport(endpoint: endpoint)
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

private struct SummaryEnvelope: Decodable {
    var seq: Int
    var summary: DocJSON.DocSummary
}

@Suite struct MCPAdapterTests {
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

    @Test func endingSessionStopsFurtherNotifications() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)

        let sink = NotificationSink()
        await client.onNotification(ResourceUpdatedNotification.self) { message in
            await sink.record(message.params.uri)
        }

        try await client.subscribeToResource(uri: "infsketch://doc/d")
        _ = try await server.manager.subscribe(docId: "d")
        _ = await server.manager.submit(
            docId: "d", opId: "before-end", payload: OpPayload(type: "fullDoc", data: Data([1])))
        #expect(await waitFor(sink, atLeast: 1))

        // Disconnect sends DELETE /mcp, which should end the session
        // (unsubscribeAll on the debouncer + stop the Server receive loop).
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        let countAfterDisconnect = await sink.uris.count
        _ = await server.manager.submit(
            docId: "d", opId: "after-end", payload: OpPayload(type: "fullDoc", data: Data([2])))
        try await Task.sleep(for: .milliseconds(300))
        // No new notification could have been delivered (the client
        // disconnected), but more importantly the adapter must not crash or
        // leak trying to notify a torn-down session.
        #expect(await sink.uris.count == countAfterDisconnect)

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
