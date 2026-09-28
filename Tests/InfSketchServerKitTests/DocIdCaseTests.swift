import Foundation
import Testing
import InfSketchWire
@testable import InfSketchServerKit

/// The store folds case (`RAINFALL` finds `Rainfall`), but sessions were keyed by the exact
/// spelling: an agent writing `RAINFALL` opened a SECOND session on the same file, the app's
/// session never heard of it, and the app's next push (its base equal to the stale session's
/// bytes) was accepted and overwrote the agent's edit on disk. One document must be one session
/// whatever the caller's letter case.
@Suite struct DocIdCaseTests {

    private func makeStore() throws -> (DirectoryDocumentStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docid-case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DirectoryDocumentStore(directory: dir), dir)
    }

    @Test func anAgentWriteInAnotherCaseReachesTheSubscriberOfTheStoredSpelling() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Rainfall", bytes: Data("v1".utf8))
        let manager = SessionManager(store: store)
        let sub = try await manager.subscribe(docId: "Rainfall")

        let outcome = await manager.submitOpeningSession(
            docId: "RAINFALL", createIfMissing: false, opId: "agent-1",
            payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)),
            expectation: .matchBytes(Data("v1".utf8)))
        #expect(outcome == .accepted(seq: 1))

        var iterator = sub.events.makeAsyncIterator()
        let event = await iterator.next()
        guard case .event(_, let seq, _, let opId, _)? = event else {
            Issue.record("the subscriber must receive the agent's write, got \(String(describing: event))"); return
        }
        #expect(seq == 1)
        #expect(opId == "agent-1")
        #expect(Array(await manager.liveInfo().keys) == ["Rainfall"], "one document, one session")
    }

    @Test func theCanonicalIdIsTheStoredSpelling() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Rainfall", bytes: Data("v1".utf8))
        let manager = SessionManager(store: store)
        #expect(await manager.canonicalDocId("rainFALL") == "Rainfall")
        #expect(await manager.canonicalDocId("Unknown") == "Unknown")
    }

    /// A document with no bytes yet (a createIfMissing session, or an advertisement) is matched
    /// by its live spelling.
    @Test func aLiveSessionOrAdvertisementGivesTheSpellingWhenNothingIsStored() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SessionManager(store: store)
        _ = try await manager.subscribe(docId: "Fresh", createIfMissing: true)
        #expect(await manager.canonicalDocId("FRESH") == "Fresh")
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "OnDevice", modifiedAt: Date(), sizeBytes: 1, thumbnail: nil)],
            connectionId: UUID(), deviceId: "dev")
        #expect(await manager.canonicalDocId("ondevice") == "OnDevice")
        #expect(await manager.liveEntry(docId: "ONDEVICE") != nil)
    }

    /// Two WebSocket peers naming one document differently share one session.
    @Test func subscribersInTwoSpellingsShareOneSession() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Rainfall", bytes: Data("v1".utf8))
        let manager = SessionManager(store: store)
        let a = try await manager.subscribe(docId: "Rainfall")
        let b = try await manager.subscribe(docId: "rainfall")
        #expect(await manager.liveInfo()["Rainfall"]?.subscriberCount == 2)
        await manager.unsubscribe(docId: "rainfall", token: b.token)
        await manager.unsubscribe(docId: "Rainfall", token: a.token)
        #expect(await manager.liveInfo()["Rainfall"]?.subscriberCount == 0)
    }

    /// On a case-sensitive filesystem (Linux) delete used the exact spelling and missed; on any
    /// filesystem the trashed copy must carry the stored name, not the caller's.
    @Test func deleteResolvesCaseLikeLoadAndExists() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Rainfall", bytes: Data("v1".utf8))
        try store.delete(docId: "RAINFALL")
        #expect(try store.exists(docId: "Rainfall") == false)
        let trash = dir.appendingPathComponent(DirectoryDocumentStore.trashDirectoryName)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        #expect(trashed.count == 1)
        #expect(trashed.first?.hasPrefix("Rainfall__") == true, "trashed as \(trashed)")
    }
}
