import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

private func makeManager(gracePeriod: Duration = .seconds(60)) throws -> SessionManager {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("manager-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = DirectoryDocumentStore(directory: dir)
    try store.save(docId: "d", bytes: Fixtures.docBytes)
    return SessionManager(store: store, config: SessionConfig(gracePeriod: gracePeriod))
}

@Suite struct SessionManagerTests {
    @Test func subscribeCreatesSessionLazily() async throws {
        let manager = try makeManager()
        #expect(await manager.liveInfo().isEmpty)
        let r = try await manager.subscribe(docId: "d")
        #expect(r.snapshot == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))
        let info = await manager.liveInfo()
        #expect(info["d"] == LiveDocInfo(seq: 0, subscriberCount: 1))
    }

    @Test func subscribeUnknownDocThrows() async throws {
        let manager = try makeManager()
        await #expect(throws: DocumentStoreError.notFound) {
            _ = try await manager.subscribe(docId: "ghost")
        }
    }

    @Test func submitWithoutSessionRejects() async throws {
        let manager = try makeManager()
        let r = await manager.submit(docId: "d", opId: "o", payload: OpPayload(type: "fullDoc", data: Data([1])))
        #expect(r == .rejected(.reject(docId: "d", opId: "o", reason: "notSubscribed", seq: 0)))
    }

    @Test func sessionSurvivesWithinGracePeriodAndTearsDownAfter() async throws {
        let manager = try makeManager(gracePeriod: .milliseconds(50))
        let r = try await manager.subscribe(docId: "d")
        await manager.unsubscribe(docId: "d", token: r.token)
        // Still alive within grace period.
        #expect(await manager.liveInfo()["d"] != nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await manager.liveInfo()["d"] == nil)
    }

    @Test func resubscribeWithinGraceCancelsTeardown() async throws {
        let manager = try makeManager(gracePeriod: .milliseconds(100))
        let r1 = try await manager.subscribe(docId: "d")
        await manager.unsubscribe(docId: "d", token: r1.token)
        _ = try await manager.subscribe(docId: "d")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await manager.liveInfo()["d"] != nil)
    }

    @Test func statusStreamReportsLifecycleAndUpdates() async throws {
        let manager = try makeManager(gracePeriod: .milliseconds(50))
        let (events, _) = await manager.subscribeStatus()
        let r = try await manager.subscribe(docId: "d")
        _ = await manager.submit(docId: "d", opId: "o1", payload: OpPayload(type: "fullDoc", data: Data([9])))
        await manager.unsubscribe(docId: "d", token: r.token)
        try await Task.sleep(for: .milliseconds(300))

        var kinds = [String]()
        for await message in events {
            if case .statusEvent(let p) = message {
                kinds.append(p.kind)
                if p.kind == "sessionClosed" { break }
            }
        }
        #expect(kinds == ["sessionOpened", "subscriberCount", "docUpdated", "subscriberCount", "sessionClosed"])
    }

    @Test func unsubscribeIsIdempotent() async throws {
        let manager = try makeManager()
        let r = try await manager.subscribe(docId: "d")
        await manager.unsubscribe(docId: "d", token: r.token)
        await manager.unsubscribe(docId: "d", token: r.token)  // must not underflow the count
        let r2 = try await manager.subscribe(docId: "d")
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 1)
        _ = r2
    }
}

@Suite struct CreateIfMissingSessionTests {
    private func makeStoreAndManager() throws -> (DirectoryDocumentStore, SessionManager) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cim-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        return (store, SessionManager(store: store, config: SessionConfig()))
    }

    @Test func createIfMissingOpensEmptySessionWithoutTouchingDisk() async throws {
        let (store, manager) = try makeStoreAndManager()
        let result = try await manager.subscribe(docId: "fresh", createIfMissing: true)
        #expect(result.snapshot == .subscribed(docId: "fresh", seq: 0, snapshot: .inline(Data())))
        // Nothing persisted yet:
        #expect(throws: DocumentStoreError.self) { _ = try store.load(docId: "fresh") }
    }

    @Test func firstOpPersistsTheCreatedDoc() async throws {
        let (store, manager) = try makeStoreAndManager()
        _ = try await manager.subscribe(docId: "fresh", createIfMissing: true)
        let outcome = await manager.submit(docId: "fresh", opId: "o1",
                                           payload: OpPayload(type: "fullDoc", data: Data([1, 2])))
        #expect(outcome == .accepted(seq: 1))
        #expect(try store.load(docId: "fresh") == Data([1, 2]))
    }

    @Test func withoutFlagUnknownDocStillThrows() async throws {
        let (_, manager) = try makeStoreAndManager()
        await #expect(throws: (any Error).self) {
            _ = try await manager.subscribe(docId: "ghost")
        }
    }
}

@Suite struct MCPWritePathTests {
    private func makeStoreAndManager() throws -> (DirectoryDocumentStore, SessionManager) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        return (store, SessionManager(store: store, config: SessionConfig(gracePeriod: .milliseconds(50))))
    }

    @Test func submitToClosedDocOpensSessionAndPersists() async throws {
        let (store, manager) = try makeStoreAndManager()
        let result = await manager.submitOpeningSession(
            docId: "d", createIfMissing: false, opId: "mcp-1",
            payload: OpPayload(type: "fullDoc", data: Data([9])))
        // Accepted, carrying the write's own assigned seq (the broadcast
        // echo remains the subscriber-facing ack; MCP acks use this value).
        #expect(result == .accepted(seq: 1))
        #expect(try store.load(docId: "d") == Data([9]))
        // No subscribers: session must reap itself after grace.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await manager.liveInfo()["d"] == nil)
    }

    @Test func submitCreateIfMissingCreatesDoc() async throws {
        let (store, manager) = try makeStoreAndManager()
        let result = await manager.submitOpeningSession(
            docId: "fresh", createIfMissing: true, opId: "mcp-2",
            payload: OpPayload(type: "fullDoc", data: Data([1])))
        #expect(result == .accepted(seq: 1))
        #expect(try store.load(docId: "fresh") == Data([1]))
    }

    @Test func submitUnknownDocWithoutFlagRejects() async throws {
        let (_, manager) = try makeStoreAndManager()
        let result = await manager.submitOpeningSession(
            docId: "ghost", createIfMissing: false, opId: "mcp-3",
            payload: OpPayload(type: "fullDoc", data: Data([1])))
        guard case .rejected(.reject(_, _, let reason, _)) = result else {
            Issue.record("expected reject"); return
        }
        #expect(reason == "unknownDoc")
    }

    /// The seq in an accepted outcome is the seq THAT write was assigned —
    /// threaded back from `DocumentSession.submit` itself, never read back
    /// after the fact (a read-back races concurrent writers; see
    /// `SubmitOutcome` and the toolAckSeq… test in MCPAdapterTests).
    @Test func acceptedSubmitCarriesItsOwnAssignedSeq() async throws {
        let (_, manager) = try makeStoreAndManager()
        let first = await manager.submitOpeningSession(
            docId: "d", createIfMissing: false, opId: "mcp-s1",
            payload: OpPayload(type: "fullDoc", data: Data([1])))
        #expect(first == .accepted(seq: 1))
        let second = await manager.submitOpeningSession(
            docId: "d", createIfMissing: false, opId: "mcp-s2",
            payload: OpPayload(type: "fullDoc", data: Data([2])))
        #expect(second == .accepted(seq: 2))
    }

    @Test func currentBytesPrefersLiveSession() async throws {
        let (_, manager) = try makeStoreAndManager()
        let sub = try await manager.subscribe(docId: "d")
        _ = await manager.submit(docId: "d", opId: "o1", payload: OpPayload(type: "fullDoc", data: Data([7, 7])))
        #expect(await manager.currentBytes(docId: "d") == Data([7, 7]))
        await manager.unsubscribe(docId: "d", token: sub.token)
    }

    @Test func currentBytesFallsBackToStore() async throws {
        let (_, manager) = try makeStoreAndManager()
        #expect(await manager.currentBytes(docId: "d") == Fixtures.docBytes)
        #expect(await manager.currentBytes(docId: "ghost") == nil)
    }
}

/// Task 1: the write compare-and-swap guard. An MCP write tool reads a
/// document, spends a device round-trip computing a result, then must NOT
/// write that result if the document changed underneath it — `expectedBytes`
/// is the guard against exactly that race.
@Suite struct WriteCompareAndSwapTests {
    private func makeStoreAndManager(
        seed: Data, gracePeriod: Duration = .seconds(60)
    ) throws -> (DirectoryDocumentStore, SessionManager) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("write-cas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "D", bytes: seed)
        return (store, SessionManager(store: store, config: SessionConfig(gracePeriod: gracePeriod)))
    }

    @Test func expectedBytesMatchingCurrentContentIsAccepted() async throws {
        let original = Data("v1".utf8)
        let (_, manager) = try makeStoreAndManager(seed: original)
        _ = try await manager.subscribe(docId: "D")
        let outcome = await manager.submit(docId: "D", opId: "op1",
                                           payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)),
                                           expectedBytes: original)
        guard case .accepted = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(await manager.currentBytes(docId: "D") == Data("v2".utf8))
    }

    @Test func expectedBytesStaleIsRejectedAndNothingIsWritten() async throws {
        let stale = Data("v1".utf8)
        let (store, manager) = try makeStoreAndManager(seed: stale)
        _ = try await manager.subscribe(docId: "D")
        // A different writer (the user) lands first, moving the doc past `stale`.
        _ = await manager.submit(docId: "D", opId: "user",
                                 payload: OpPayload(type: "fullDoc", data: Data("v2-user".utf8)))
        let seqBefore = await manager.liveInfo()["D"]?.seq
        #expect(seqBefore == 1)  // pin the concrete value: an Int? == Int? compare is vacuous when both are nil
        // Now the stale-based write (the agent's) must be refused.
        let outcome = await manager.submit(docId: "D", opId: "agent",
                                           payload: OpPayload(type: "fullDoc", data: Data("v2-agent".utf8)),
                                           expectedBytes: stale)
        guard case .rejected(let message) = outcome else { Issue.record("expected rejected, got \(outcome)"); return }
        guard case .reject(_, _, let reason, _) = message else { Issue.record("expected .reject, got \(message)"); return }
        #expect(reason == "docChangedDuringOp")
        #expect(await manager.currentBytes(docId: "D") == Data("v2-user".utf8))   // the user's write survives in memory
        #expect(await manager.liveInfo()["D"]?.seq == seqBefore)                   // no seq bump
        // ...and on DISK. This assertion is the one that pins the guard's
        // PLACEMENT (before `store.save`), not merely its existence:
        // `manager.currentBytes` returns the live session's in-memory bytes and
        // never reads the store, so a CAS moved below `store.save` would leave
        // the agent's stale bytes on disk — silently resurrected at the next
        // session reopen — with every in-memory assertion above still green.
        #expect(try store.load(docId: "D") == Data("v2-user".utf8))
    }

    @Test func nilExpectedBytesStaysUnconditional() async throws {
        let (_, manager) = try makeStoreAndManager(seed: Data("v0".utf8))
        _ = try await manager.subscribe(docId: "D")
        // The app-push path must be untouched: a write with no expectation always lands.
        _ = await manager.submit(docId: "D", opId: "a",
                                 payload: OpPayload(type: "fullDoc", data: Data("x".utf8)))
        let outcome = await manager.submit(docId: "D", opId: "b",
                                           payload: OpPayload(type: "fullDoc", data: Data("y".utf8)))
        guard case .accepted = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(await manager.currentBytes(docId: "D") == Data("y".utf8))
    }

    @Test func rejectedWriteDoesNotBroadcast() async throws {
        let stale = Data("v1".utf8)
        let (_, manager) = try makeStoreAndManager(seed: stale)
        let sub = try await manager.subscribe(docId: "D")

        // One accepted write, unconditional.
        _ = await manager.submit(docId: "D", opId: "user",
                                 payload: OpPayload(type: "fullDoc", data: Data("v2-user".utf8)))
        // Then a stale-expectation write, which must be rejected without broadcasting.
        let outcome = await manager.submit(docId: "D", opId: "agent",
                                           payload: OpPayload(type: "fullDoc", data: Data("v2-agent".utf8)),
                                           expectedBytes: stale)
        guard case .rejected = outcome else { Issue.record("expected rejected, got \(outcome)"); return }

        await manager.unsubscribe(docId: "D", token: sub.token)
        var eventCount = 0
        for await message in sub.events {
            if case .event = message { eventCount += 1 }
        }
        #expect(eventCount == 1)
    }

    /// The path Task 2's MCP tools actually take: no live session at write
    /// time, so `submitOpeningSession` opens one from the STORE inside the
    /// call. The guard must therefore compare against the store's current
    /// content — proving "no second pre-check needed" behaviorally, not just
    /// in a comment.
    @Test func submitOpeningSessionRejectsStaleExpectationOnAReopenedSession() async throws {
        let stale = Data("v1".utf8)
        let (store, manager) = try makeStoreAndManager(seed: stale, gracePeriod: .milliseconds(50))
        // The agent reads `stale`. Then a device subscribes, pushes, disconnects,
        // and the session grace-tears-down — so the doc has NO live session, and
        // the store now holds content the agent has never seen.
        let sub = try await manager.subscribe(docId: "D")
        _ = await manager.submit(docId: "D", opId: "user",
                                 payload: OpPayload(type: "fullDoc", data: Data("v2-user".utf8)))
        await manager.unsubscribe(docId: "D", token: sub.token)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await manager.liveInfo()["D"] == nil)  // session really is gone: the reopen branch runs below

        let outcome = await manager.submitOpeningSession(
            docId: "D", createIfMissing: false, opId: "agent",
            payload: OpPayload(type: "fullDoc", data: Data("v2-agent".utf8)),
            expectedBytes: stale)
        guard case .rejected(let message) = outcome else { Issue.record("expected rejected, got \(outcome)"); return }
        guard case .reject(_, _, let reason, _) = message else { Issue.record("expected .reject, got \(message)"); return }
        #expect(reason == "docChangedDuringOp")
        #expect(try store.load(docId: "D") == Data("v2-user".utf8))  // disk untouched by the refused write
    }

    @Test func submitOpeningSessionAcceptsMatchingExpectationOnAReopenedSession() async throws {
        let current = Data("v1".utf8)
        let (store, manager) = try makeStoreAndManager(seed: current)
        // No session was ever opened for "D": submitOpeningSession opens it from
        // the store, and the expectation matches that content.
        #expect(await manager.liveInfo()["D"] == nil)
        let outcome = await manager.submitOpeningSession(
            docId: "D", createIfMissing: false, opId: "agent",
            payload: OpPayload(type: "fullDoc", data: Data("v2-agent".utf8)),
            expectedBytes: current)
        guard case .accepted = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(try store.load(docId: "D") == Data("v2-agent".utf8))
    }
}
