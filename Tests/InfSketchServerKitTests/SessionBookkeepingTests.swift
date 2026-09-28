import Foundation
import Testing
import InfSketchWire
@testable import InfSketchServerKit

/// Subscriber and watcher counts belong to a SESSION, not a docId (review finding 19): a delete
/// replaces the session, and a release that arrives afterwards must not be charged to the new one.
/// And a delete must not be undone by a save that was already in flight.
@Suite struct SessionBookkeepingTests {

    private func makeStore() throws -> (DirectoryDocumentStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookkeeping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DirectoryDocumentStore(directory: dir), dir)
    }

    /// A stale release — the subscription belonged to the session the delete ended — used to
    /// decrement the NEW session's count and schedule its teardown under a live subscriber.
    @Test func aReleaseFromADeletedSessionDoesNotTouchItsSuccessor() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "d", bytes: Data("v1".utf8))
        let manager = SessionManager(store: store)

        let old = try await manager.subscribe(docId: "d")
        try await manager.deleteDoc(docId: "d")
        let fresh = try await manager.subscribe(docId: "d", createIfMissing: true)
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 1)

        await manager.unsubscribe(docId: "d", token: old.token)
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 1,
                "the old session's subscriber is not the new session's")
        await manager.unsubscribe(docId: "d", token: fresh.token)
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 0)
    }

    @Test func aWatcherReleaseFromADeletedSessionDoesNotTouchItsSuccessor() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "d", bytes: Data("v1".utf8))
        let manager = SessionManager(store: store, config: SessionConfig(gracePeriod: .milliseconds(50)))

        let oldWatch = try await manager.watch(docId: "d")
        try await manager.deleteDoc(docId: "d")
        try store.save(docId: "d", bytes: Data("v2".utf8))
        _ = try await manager.watch(docId: "d")
        await manager.unwatch(docId: "d", token: oldWatch.token)
        // Had the stale release been charged to the new session, it would now have no watcher
        // and tear down after the grace period.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await manager.liveInfo()["d"] != nil, "a watched session must not be torn down")
    }

    /// A store whose `save` can be held mid-call, standing for an atomic write still in progress.
    final class HeldSaveStore: DocumentStore, @unchecked Sendable {
        let inner: DirectoryDocumentStore
        private let lock = NSLock()
        private var holding = false
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        init(_ inner: DirectoryDocumentStore) { self.inner = inner }
        func waitUntilEntered() { entered.wait() }
        func releaseSave() { release.signal() }
        func holdNextSave() { lock.lock(); holding = true; lock.unlock() }
        func list() throws -> [StoredDocInfo] { try inner.list() }
        func load(docId: String) throws -> Data { try inner.load(docId: docId) }
        func exists(docId: String) throws -> Bool { try inner.exists(docId: docId) }
        func delete(docId: String) throws { try inner.delete(docId: docId) }
        func storedDocId(matching docId: String) -> String? { inner.storedDocId(matching: docId) }
        func save(docId: String, bytes: Data) throws {
            lock.lock(); let hold = holding; holding = false; lock.unlock()
            if hold { entered.signal(); release.wait() }
            try inner.save(docId: docId, bytes: bytes)
        }
    }

    /// The session's save and the manager's delete ran on two actors at once, so a save already
    /// in flight could land after the delete and bring the file back. The delete now goes through
    /// the session, after anything it was doing.
    @Test func aDeleteIsNotUndoneByASaveInFlight() async throws {
        let (inner, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try inner.save(docId: "d", bytes: Data("v1".utf8))
        let store = HeldSaveStore(inner)
        let manager = SessionManager(store: store)
        _ = try await manager.subscribe(docId: "d")

        store.holdNextSave()
        let write = Task {
            await manager.submit(docId: "d", opId: "late", payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)))
        }
        await Task.detached { store.waitUntilEntered() }.value
        let delete = Task { try await manager.deleteDoc(docId: "d") }
        // Give the delete every chance to run ahead of the held save (it used to, at once).
        try await Task.sleep(for: .milliseconds(150))
        store.releaseSave()
        _ = await write.value
        try await delete.value

        #expect(try inner.exists(docId: "d") == false, "the delete must win over the save in flight")
    }

    /// A write that reaches a session after its document was deleted is refused, not saved.
    @Test func aSessionRefusesWritesOnceDeleted() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "d", bytes: Data("v1".utf8))
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)
        try await session.deleteFromStore()
        let outcome = await session.submit(opId: "x", payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)))
        guard case .rejected = outcome else { Issue.record("expected a rejection, got \(outcome)"); return }
        #expect(try store.exists(docId: "d") == false)
    }
}
