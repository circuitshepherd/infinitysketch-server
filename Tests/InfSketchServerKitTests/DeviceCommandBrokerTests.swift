import Foundation
import Testing
import InfSketchWire
@testable import InfSketchServerKit

/// Tiny test helper: captures ServerMessages handed to a `register(...)`
/// send closure (which itself is synchronous, so callers `Task { await
/// sent.set(msg) }` into it) and lets the test await the first one with a
/// bounded poll — mirrors the `for _ in 0..<50 { ...; try await
/// Task.sleep(for: .milliseconds(10)) }` idiom used throughout
/// WSAdapterTests for awaiting async effects.
private actor SentBox {
    private var messages: [ServerMessage] = []

    func set(_ message: ServerMessage) {
        messages.append(message)
    }

    /// Returns the first captured message, polling briefly if none has
    /// landed yet. `nil` if nothing arrives within the budget.
    func awaitMessage() async -> ServerMessage? {
        for _ in 0..<50 {
            if let first = messages.first { return first }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return messages.first
    }
}

@Suite struct DeviceCommandBrokerTests {
    @Test func noConnectionThrowsNoDevice() async {
        let broker = DeviceCommandBroker()
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.noDeviceAvailable) {
            _ = try await broker.requestCreation(docId: "D")
        }
    }

    @Test func successRoundTrip() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        async let result = broker.requestCreation(docId: "D")
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await result == Data("T".utf8))
    }

    @Test func failureReplyThrowsDeviceFailed() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        // `#expect(throws:)`'s closure can't capture an `async let`, so run
        // the call on a plain Task (a Sendable value, capturable normally).
        let task = Task { try await broker.requestCreation(docId: "D") }
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: nil, failureReason: "boom")
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("boom")) {
            _ = try await task.value
        }
    }

    @Test func timeoutThrowsDeviceTimeout() async {
        let broker = DeviceCommandBroker(createTimeout: .milliseconds(50))
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { _ in }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestCreation(docId: "D")
        }
    }

    @Test func concurrentSameDocIdThrowsInProgress() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        async let first: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }

        // Second request for the same docId while the first is still in
        // flight must be rejected immediately, without waiting for a reply
        // or timeout.
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.requestInFlight) {
            _ = try await broker.requestCreation(docId: "D")
        }

        // Release the first request so the test doesn't leak a pending Task.
        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await first == Data("T".utf8))
    }

    @Test func lateReplyIsDropped() async {
        let broker = DeviceCommandBroker(createTimeout: .milliseconds(50))
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestCreation(docId: "D")
        }
        let request = await sent.awaitMessage()
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }

        // The request has already timed out (and its entry been cleaned
        // up); a late reply for the same requestId must be a harmless no-op
        // — no crash, and it must not resurrect/resume anything.
        await broker.handleReply(requestId: rid, bytes: Data("late".utf8), failureReason: nil)
    }

    @Test func unregisterFailsPendingImmediately() async {
        let broker = DeviceCommandBroker(createTimeout: .seconds(10))
        let connectionId = UUID()
        await broker.register(connectionId: connectionId, capabilities: ["createDoc"]) { _ in }
        let task = Task { try await broker.requestCreation(docId: "D") }
        // Give requestCreation a moment to register its continuation before
        // we unregister the connection out from under it.
        try? await Task.sleep(for: .milliseconds(20))
        await broker.unregister(connectionId: connectionId)
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await task.value
        }
    }

    @Test func mostRecentConnectionWins() async throws {
        let broker = DeviceCommandBroker()
        let sentA = SentBox()
        let sentB = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sentB.set(msg) } }
        async let result: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sentB.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }

        // A's box must never receive the request.
        #expect(await sentA.awaitMessage() == nil)

        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await result == Data("T".utf8))
    }

    @Test func retryAfterCompletionWorks() async throws {
        let broker = DeviceCommandBroker(createTimeout: .milliseconds(50))
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestCreation(docId: "D")
        }

        // The per-docId guard must have been cleaned up by the timeout path
        // — a fresh request for the same docId must proceed (not throw
        // .requestInFlight) and get its own new requestId sent.
        let sent2 = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent2.set(msg) } }
        async let result: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sent2.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: Data("T2".utf8), failureReason: nil)
        #expect(try await result == Data("T2".utf8))
    }

    // MARK: - requestStrokeOp (generalization, Task 2)

    @Test func strokeOpSuccessRoundTrip() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        let docBytes = Data("doc-bytes".utf8)
        let spec = Data("spec-bytes".utf8)
        async let result = broker.requestStrokeOp(docId: "D", docBytes: docBytes, spec: spec)
        let request = try #require(await sent.awaitMessage())
        guard case .strokeOpRequest(let rid, "D", .inline(let sentBytes), let sentSpec) = request else {
            Issue.record("wrong msg: \(request)"); return
        }
        #expect(sentBytes == docBytes)
        #expect(sentSpec == spec)
        await broker.handleReply(requestId: rid, bytes: Data("result-bytes".utf8), failureReason: nil)
        #expect(try await result == Data("result-bytes".utf8))
    }

    // MARK: - Capability filtering

    @Test func createDocOnlyConnectionNotSelectedForStrokeOp() async {
        let broker = DeviceCommandBroker()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { _ in }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.noDeviceAvailable) {
            _ = try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data())
        }
    }

    @Test func strokeOpOnlyConnectionNotSelectedForCreateDoc() async {
        let broker = DeviceCommandBroker()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { _ in }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.noDeviceAvailable) {
            _ = try await broker.requestCreation(docId: "D")
        }
    }

    @Test func bothCapabilitiesConnectionServesBothKinds() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }

        async let createResult: Data = broker.requestCreation(docId: "D1")
        let createRequest = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let createRid, "D1") = createRequest else {
            Issue.record("wrong msg: \(createRequest)"); return
        }
        await broker.handleReply(requestId: createRid, bytes: Data("create".utf8), failureReason: nil)
        #expect(try await createResult == Data("create".utf8))

        let sent2 = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent2.set(msg) }
        }
        async let strokeResult: Data = broker.requestStrokeOp(docId: "D2", docBytes: Data(), spec: Data())
        let strokeRequest = try #require(await sent2.awaitMessage())
        guard case .strokeOpRequest(let strokeRid, "D2", _, _) = strokeRequest else {
            Issue.record("wrong msg: \(strokeRequest)"); return
        }
        await broker.handleReply(requestId: strokeRid, bytes: Data("stroke".utf8), failureReason: nil)
        #expect(try await strokeResult == Data("stroke".utf8))
    }

    // MARK: - Shared per-docId in-flight guard

    @Test func pendingCreateBlocksStrokeOpOnSameDocId() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        async let createResult: Data = broker.requestCreation(docId: "D")
        let createRequest = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = createRequest else {
            Issue.record("wrong msg: \(createRequest)"); return
        }

        await #expect(throws: DeviceCommandBroker.DeviceCommandError.requestInFlight) {
            _ = try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data())
        }

        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await createResult == Data("T".utf8))
    }

    @Test func pendingStrokeOpBlocksCreateOnSameDocId() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        async let strokeResult: Data = broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data())
        let strokeRequest = try #require(await sent.awaitMessage())
        guard case .strokeOpRequest(let rid, "D", _, _) = strokeRequest else {
            Issue.record("wrong msg: \(strokeRequest)"); return
        }

        await #expect(throws: DeviceCommandBroker.DeviceCommandError.requestInFlight) {
            _ = try await broker.requestCreation(docId: "D")
        }

        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await strokeResult == Data("T".utf8))
    }

    // MARK: - Per-kind timeout

    @Test func strokeOpTimesOutIndependentlyOfCreateTimeout() async {
        // A short strokeOpTimeout with a long (untouched) createTimeout:
        // the stroke op must time out on its own schedule without waiting
        // for (or being affected by) the create timeout.
        let broker = DeviceCommandBroker(createTimeout: .seconds(10), strokeOpTimeout: .milliseconds(50))
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { _ in }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data())
        }
    }

    // MARK: - Kind-agnostic replies

    @Test func twoPendingRequestsOfDifferentKindsResolveIndependently() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }

        async let createResult: Data = broker.requestCreation(docId: "D1")
        let createRequest = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let createRid, "D1") = createRequest else {
            Issue.record("wrong msg: \(createRequest)"); return
        }

        let sent2 = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent2.set(msg) }
        }
        async let strokeResult: Data = broker.requestStrokeOp(docId: "D2", docBytes: Data(), spec: Data())
        let strokeRequest = try #require(await sent2.awaitMessage())
        guard case .strokeOpRequest(let strokeRid, "D2", _, _) = strokeRequest else {
            Issue.record("wrong msg: \(strokeRequest)"); return
        }

        // Resolve the stroke op first, then the create — each must resolve
        // its own continuation, unaffected by ordering or by the other kind.
        await broker.handleReply(requestId: strokeRid, bytes: Data("stroke".utf8), failureReason: nil)
        await broker.handleReply(requestId: createRid, bytes: Data("create".utf8), failureReason: nil)

        #expect(try await strokeResult == Data("stroke".utf8))
        #expect(try await createResult == Data("create".utf8))
    }
}
