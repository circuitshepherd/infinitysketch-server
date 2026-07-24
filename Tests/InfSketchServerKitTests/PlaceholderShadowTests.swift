import XCTest
import InfSketchWire
@testable import InfSketchServerKit

/// M2c-1 review F4 — the "content-less `createIfMissing` shadow window".
///
/// When the app opens a document it mirrors, it subscribes with `createIfMissing: true` ("if you
/// don't have this, open an empty slot — I'm about to push"). The server opens an EMPTY in-memory
/// placeholder session. While that placeholder is alive it used to SHADOW the fetch path: a reader
/// asked "is there content?", saw the placeholder's empty bytes, and answered "yes, it's empty" —
/// so an agent tool read a BLANK document even though a connected holder had the real content, and
/// `/api/docs` was meanwhile still reporting the doc as `hasContent: false` (i.e. fetchable). The
/// two answers disagreed.
///
/// The fix is NOT "let readers ignore the placeholder and fetch" on its own: `WriteExpectation
/// .matchBytes` compares against the SESSION's in-memory bytes, so a reader seeing fetched content
/// while the session still held empty would make every agent write fail `docChangedDuringOp`
/// forever. So the placeholder ADOPTS the fetched bytes — session, store and readers all agree.
/// `testTheAdoptedSessionKeepsTheWriteCasWorking` is the test that pins that whole argument.
final class PlaceholderShadowTests: XCTestCase {
    private func makeManager() throws -> (SessionManager, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("placeholder-shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionManager(store: DirectoryDocumentStore(directory: dir)), dir)
    }

    private func ad(_ id: String) -> DocAdvertisement {
        DocAdvertisement(docId: id, modifiedAt: Date(timeIntervalSince1970: 0), sizeBytes: 3, thumbnail: nil)
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            entered = true
            entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }
        func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    /// Opens the placeholder exactly the way the app's mirror does.
    private func openPlaceholder(_ manager: SessionManager, docId: String) async throws {
        _ = try await manager.subscribe(docId: docId, createIfMissing: true)
    }

    // MARK: - The shadow itself

    /// The core fix: a live placeholder must not make a fetchable document read as empty.
    func testAnEmptyPlaceholderDoesNotShadowAFetch() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")
        await manager.setContentProvider { _, _ in Data("REAL".utf8) }

        try await openPlaceholder(manager, docId: "Ghost")
        // Precondition: the placeholder is live and holds empty bytes — this is the shadow.
        let shadowed = await manager.currentBytes(docId: "Ghost")
        XCTAssertEqual(shadowed, Data(), "precondition: the placeholder session reads as empty")

        let got = await manager.currentBytesOrFetch(docId: "Ghost")

        XCTAssertEqual(got, Data("REAL".utf8), "must pull the holder's content, not the empty placeholder")
        XCTAssertEqual(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"), Data("REAL".utf8),
                       "and promote it to ordinary content")
    }

    /// THE load-bearing test — the reason the naive fix is wrong. After the fetch, the placeholder
    /// session must hold the SAME bytes readers were given, so an agent that reads and then writes
    /// back with `matchBytes(whatItRead)` is ACCEPTED. Without adoption the session still holds
    /// empty, and this write is rejected `docChangedDuringOp` with no way to converge.
    func testTheAdoptedSessionKeepsTheWriteCasWorking() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")
        await manager.setContentProvider { _, _ in Data("REAL".utf8) }
        try await openPlaceholder(manager, docId: "Ghost")

        let read = await manager.currentBytesOrFetch(docId: "Ghost")
        XCTAssertEqual(read, Data("REAL".utf8))

        // The session itself must now agree with what the reader was told.
        let live = await manager.currentBytes(docId: "Ghost")
        XCTAssertEqual(live, Data("REAL".utf8), "the placeholder must have ADOPTED the fetched bytes")

        // …so the read-then-write-back an agent tool performs is accepted.
        let outcome = await manager.submitOpeningSession(
            docId: "Ghost", createIfMissing: false, opId: "agent-write",
            payload: OpPayload(type: "fullDoc", data: Data("EDITED".utf8)),
            expectation: .matchBytes(read!))
        guard case .accepted = outcome else {
            return XCTFail("the CAS must accept a write based on what the reader was given, got \(outcome)")
        }
        XCTAssertEqual(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"), Data("EDITED".utf8))
    }

    // MARK: - What must NOT change

    /// A genuinely empty SAVED document is not a placeholder: it is real content and must be
    /// returned as-is, with no fetch. (`store.exists` is what tells the two apart — a session's
    /// in-memory bytes cannot.)
    func testADurablyEmptyDocumentIsNotTreatedAsAPlaceholder() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DirectoryDocumentStore(directory: dir).save(docId: "Empty", bytes: Data())
        await manager.applyAdvertisements([ad("Empty")], connectionId: UUID(), deviceId: "devA")
        await manager.setContentProvider { _, _ in
            XCTFail("a durably-empty document is real content — it must not trigger a fetch")
            return Data("REAL".utf8)
        }

        let got = await manager.currentBytesOrFetch(docId: "Empty")

        XCTAssertEqual(got, Data(), "the saved empty document is returned unchanged")
    }

    /// A placeholder with NO holder to ask still reads as empty — unchanged behaviour, and in
    /// particular NOT a nil ("unknown document") that would turn a working call into an error.
    func testAPlaceholderWithNoHoldersStillReadsAsEmpty() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.setContentProvider { _, _ in
            XCTFail("no holder advertised this doc — nothing to fetch from")
            return Data()
        }
        try await openPlaceholder(manager, docId: "Fresh")

        let got = await manager.currentBytesOrFetch(docId: "Fresh")

        XCTAssertEqual(got, Data(), "still readable as the empty doc being created")
    }

    /// A holder that fails must also leave the placeholder readable rather than surfacing nil.
    func testAFailedFetchLeavesThePlaceholderReadableAsEmpty() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")
        await manager.setContentProvider { _, _ in throw DocumentStoreError.notFound }
        try await openPlaceholder(manager, docId: "Ghost")

        let got = await manager.currentBytesOrFetch(docId: "Ghost")

        XCTAssertEqual(got, Data(), "a failed fetch degrades to the placeholder, not to unknownDoc")
        XCTAssertFalse(try DirectoryDocumentStore(directory: dir).exists(docId: "Ghost"),
                       "and persists nothing")
    }

    /// A real write that lands while the fetch is in flight must win over the stale fetch — the
    /// session, the store and the value handed back all end on the WRITE.
    ///
    /// Honest note on what this does and does not pin: this scenario is caught by the F5 re-check
    /// (the resuming fetch sees a non-empty session and returns it before ever reaching the
    /// adoption), so it passes even with `adoptIfEmpty`'s emptiness guard removed — verified by
    /// mutation. The guard covers a strictly narrower window the re-check cannot: a write landing
    /// during the adoption's OWN suspension, where an unconditional adopt would leave the session
    /// holding the fetched bytes while the store holds the write. That window can't be hit
    /// deterministically without a test-only scheduling seam, which isn't worth adding — but the
    /// guard is why it is safe, so don't "simplify" it away.
    func testAWriteLandingDuringTheFetchWinsOverTheAdoption() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")
        let gate = Gate()
        await manager.setContentProvider { _, _ in
            await gate.wait()
            return Data("FETCHED".utf8)
        }
        try await openPlaceholder(manager, docId: "Ghost")

        let readTask = Task { await manager.currentBytesOrFetch(docId: "Ghost") }
        await gate.waitUntilEntered()

        // A real write lands on the placeholder session while the fetch is held.
        let outcome = await manager.submitOpeningSession(
            docId: "Ghost", createIfMissing: false, opId: "u",
            payload: OpPayload(type: "fullDoc", data: Data("WRITTEN".utf8)))
        guard case .accepted = outcome else { return XCTFail("setup write should be accepted") }

        await gate.open()
        let got = await readTask.value

        XCTAssertEqual(got, Data("WRITTEN".utf8), "the landed write wins over the stale fetch")
        let live = await manager.currentBytes(docId: "Ghost")
        XCTAssertEqual(live, Data("WRITTEN".utf8), "and the session must NOT be re-adopted back to the fetch")
        XCTAssertEqual(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"), Data("WRITTEN".utf8))
    }
}
