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

@Suite struct CreateDocBrokerTests {
    @Test func noConnectionThrowsNoDevice() async {
        let broker = CreateDocBroker()
        await #expect(throws: CreateDocBroker.CreateDocError.noDeviceAvailable) {
            _ = try await broker.requestCreation(docId: "D")
        }
    }

    @Test func successRoundTrip() async throws {
        let broker = CreateDocBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID()) { msg in Task { await sent.set(msg) } }
        async let result = broker.requestCreation(docId: "D")
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await result == Data("T".utf8))
    }

    @Test func failureReplyThrowsDeviceFailed() async throws {
        let broker = CreateDocBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID()) { msg in Task { await sent.set(msg) } }
        // `#expect(throws:)`'s closure can't capture an `async let`, so run
        // the call on a plain Task (a Sendable value, capturable normally).
        let task = Task { try await broker.requestCreation(docId: "D") }
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: nil, failureReason: "boom")
        await #expect(throws: CreateDocBroker.CreateDocError.deviceFailed("boom")) {
            _ = try await task.value
        }
    }

    @Test func timeoutThrowsDeviceTimeout() async {
        let broker = CreateDocBroker(timeout: .milliseconds(50))
        await broker.register(connectionId: UUID()) { _ in }
        await #expect(throws: CreateDocBroker.CreateDocError.deviceTimeout) {
            _ = try await broker.requestCreation(docId: "D")
        }
    }

    @Test func concurrentSameDocIdThrowsInProgress() async throws {
        let broker = CreateDocBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID()) { msg in Task { await sent.set(msg) } }
        async let first: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }

        // Second request for the same docId while the first is still in
        // flight must be rejected immediately, without waiting for a reply
        // or timeout.
        await #expect(throws: CreateDocBroker.CreateDocError.creationInProgress) {
            _ = try await broker.requestCreation(docId: "D")
        }

        // Release the first request so the test doesn't leak a pending Task.
        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await first == Data("T".utf8))
    }

    @Test func lateReplyIsDropped() async {
        let broker = CreateDocBroker(timeout: .milliseconds(50))
        let sent = SentBox()
        await broker.register(connectionId: UUID()) { msg in Task { await sent.set(msg) } }
        await #expect(throws: CreateDocBroker.CreateDocError.deviceTimeout) {
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
        let broker = CreateDocBroker(timeout: .seconds(10))
        let connectionId = UUID()
        await broker.register(connectionId: connectionId) { _ in }
        let task = Task { try await broker.requestCreation(docId: "D") }
        // Give requestCreation a moment to register its continuation before
        // we unregister the connection out from under it.
        try? await Task.sleep(for: .milliseconds(20))
        await broker.unregister(connectionId: connectionId)
        await #expect(throws: CreateDocBroker.CreateDocError.deviceTimeout) {
            _ = try await task.value
        }
    }

    @Test func mostRecentConnectionWins() async throws {
        let broker = CreateDocBroker()
        let sentA = SentBox()
        let sentB = SentBox()
        await broker.register(connectionId: UUID()) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: UUID()) { msg in Task { await sentB.set(msg) } }
        async let result: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sentB.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }

        // A's box must never receive the request.
        #expect(await sentA.awaitMessage() == nil)

        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await result == Data("T".utf8))
    }

    @Test func retryAfterCompletionWorks() async throws {
        let broker = CreateDocBroker(timeout: .milliseconds(50))
        let sent = SentBox()
        await broker.register(connectionId: UUID()) { msg in Task { await sent.set(msg) } }
        await #expect(throws: CreateDocBroker.CreateDocError.deviceTimeout) {
            _ = try await broker.requestCreation(docId: "D")
        }

        // The per-docId guard must have been cleaned up by the timeout path
        // — a fresh request for the same docId must proceed (not throw
        // .creationInProgress) and get its own new requestId sent.
        let sent2 = SentBox()
        await broker.register(connectionId: UUID()) { msg in Task { await sent2.set(msg) } }
        async let result: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sent2.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: Data("T2".utf8), failureReason: nil)
        #expect(try await result == Data("T2".utf8))
    }
}
