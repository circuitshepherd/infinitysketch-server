import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

/// Task 2: `WriteExpectation` enforcement — the NEW `.absent` branch in
/// `DocumentSession.submit` (backed by `DocumentStore.exists`), plus the
/// signature migration from `expectedBytes: Data?` to `expectation:
/// WriteExpectation` on `DocumentSession.submit` / `SessionManager.submit` /
/// `submitOpeningSession`. `.matchBytes`/`.none` behavior is not new — it was
/// already pinned as `expectedBytes` by `WriteCompareAndSwapTests` in
/// SessionManagerTests.swift — `matchBytesAndNoneUnchanged` below just
/// re-confirms it survived the enum migration.
@Suite struct WriteExpectationEnforcementTests {
    private func makeStore() throws -> DirectoryDocumentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("write-expectation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DirectoryDocumentStore(directory: dir)
    }

    @Test func documentStoreExists() throws {
        let store = try makeStore()
        #expect(try store.exists(docId: "fresh") == false)
        try store.save(docId: "fresh", bytes: Fixtures.docBytes)
        #expect(try store.exists(docId: "fresh") == true)
    }

    @Test func absentOnFreshDocAcceptsThenExists() async throws {
        let store = try makeStore()
        // Mirrors SessionManager's createIfMissing branch: an in-memory
        // session over empty bytes, nothing on disk yet.
        let session = DocumentSession(docId: "fresh", store: store, bufferLimit: 16, bytes: Data())
        #expect(try store.exists(docId: "fresh") == false)

        let outcome = await session.submit(
            opId: "create-1", payload: OpPayload(type: "fullDoc", data: Fixtures.docBytes),
            expectation: .absent)

        #expect(outcome == .accepted(seq: 1))
        #expect(try store.exists(docId: "fresh") == true)
        #expect(try store.load(docId: "fresh") == Fixtures.docBytes)
    }

    @Test func absentOnExistingDocRejectsDocExists() async throws {
        let store = try makeStore()
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        let outcome = await session.submit(
            opId: "create-2", payload: OpPayload(type: "fullDoc", data: Data("new".utf8)),
            expectation: .absent)

        guard case .rejected(let message) = outcome else {
            Issue.record("expected rejected, got \(outcome)"); return
        }
        guard case .reject(_, _, let reason, _) = message else {
            Issue.record("expected .reject, got \(message)"); return
        }
        #expect(reason == "docExists")
        // The rejected write must never have hit disk (guard sits ABOVE
        // store.save in the same actor turn) or bumped seq.
        #expect(try store.load(docId: "d") == Fixtures.docBytes)
        #expect(await session.seq == 0)
    }

    @Test func twoSequentialAbsentSubmitsSecondRejects() async throws {
        let store = try makeStore()
        let session = DocumentSession(docId: "fresh", store: store, bufferLimit: 16, bytes: Data())

        let first = await session.submit(
            opId: "create-1", payload: OpPayload(type: "fullDoc", data: Data("v1".utf8)),
            expectation: .absent)
        #expect(first == .accepted(seq: 1))

        // The serialized create race: a second `.absent` submit against the
        // SAME session now sees the store the first write just created.
        let second = await session.submit(
            opId: "create-2", payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)),
            expectation: .absent)
        guard case .rejected(let message) = second else {
            Issue.record("expected rejected, got \(second)"); return
        }
        guard case .reject(_, _, let reason, _) = message else {
            Issue.record("expected .reject, got \(message)"); return
        }
        #expect(reason == "docExists")
        #expect(await session.seq == 1)  // no bump from the rejected second submit
        #expect(try store.load(docId: "fresh") == Data("v1".utf8))  // first write survives, unclobbered
    }

    @Test func matchBytesAndNoneUnchanged() async throws {
        let store = try makeStore()
        let original = Data("v1".utf8)
        try store.save(docId: "d", bytes: original)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        let stale = Data("stale".utf8)
        let rejected = await session.submit(
            opId: "op-1", payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)),
            expectation: .matchBytes(stale))
        guard case .rejected(let message) = rejected else {
            Issue.record("expected rejected, got \(rejected)"); return
        }
        guard case .reject(_, _, let reason, _) = message else {
            Issue.record("expected .reject, got \(message)"); return
        }
        #expect(reason == "docChangedDuringOp")
        #expect(try store.load(docId: "d") == original)  // untouched

        let accepted = await session.submit(
            opId: "op-2", payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)),
            expectation: .matchBytes(original))
        #expect(accepted == .accepted(seq: 1))
        #expect(try store.load(docId: "d") == Data("v2".utf8))

        let unconditional = await session.submit(
            opId: "op-3", payload: OpPayload(type: "fullDoc", data: Data("v3".utf8)),
            expectation: .none)
        #expect(unconditional == .accepted(seq: 2))
        #expect(try store.load(docId: "d") == Data("v3".utf8))
    }
}

/// The real MCP-shaped path: `SessionManager.submitOpeningSession` opens a
/// session on demand per call (no pre-existing subscription) — exactly how
/// `create_doc` will call this once it's flipped to `.absent` (Task 3). This
/// confirms the guard's atomicity claim under GENUINE concurrency, not just
/// sequential calls: two `.absent` creates for the same fresh docId, started
/// together, must resolve to exactly one accept and one `docExists` — never
/// two accepts (which would mean two "device round-trips" both thinking they
/// won the create).
@Suite struct AbsentCreateRaceTests {
    private func makeManager() throws -> SessionManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        return SessionManager(store: store, config: SessionConfig())
    }

    @Test func concurrentAbsentCreatesOnlyOneWins() async throws {
        let manager = try makeManager()

        async let a = manager.submitOpeningSession(
            docId: "fresh", createIfMissing: true, opId: "a",
            payload: OpPayload(type: "fullDoc", data: Data("from-a".utf8)),
            expectation: .absent)
        async let b = manager.submitOpeningSession(
            docId: "fresh", createIfMissing: true, opId: "b",
            payload: OpPayload(type: "fullDoc", data: Data("from-b".utf8)),
            expectation: .absent)
        let outcomes = await [a, b]

        let acceptedCount = outcomes.filter {
            if case .accepted = $0 { return true }
            return false
        }.count
        let rejectedReasons: [String] = outcomes.compactMap { outcome in
            guard case .rejected(let message) = outcome,
                  case .reject(_, _, let reason, _) = message else { return nil }
            return reason
        }
        #expect(acceptedCount == 1)
        #expect(rejectedReasons == ["docExists"])
    }
}
