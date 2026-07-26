import XCTest
import InfSketchWire
@testable import InfSketchServerKit

/// Deleting a document from the server.
///
/// The semantics are deliberately narrow: the bytes go away, live subscribers are told so they can
/// keep their own copy as a local-only document, and the server retains NOTHING afterwards — no
/// tombstone, no deleted-id list. A device that still holds the document may bring it back, which
/// is accepted rather than defended against.
final class DeleteDocTests: XCTestCase {

    private func makeManager() throws -> (SessionManager, DirectoryDocumentStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        return (SessionManager(store: store), store, dir)
    }

    // MARK: - The store

    func testStoreDeleteRemovesTheFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("delete-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryDocumentStore(directory: dir)

        try store.save(docId: "Doomed", bytes: Data("bye".utf8))
        XCTAssertTrue(try store.exists(docId: "Doomed"))

        try store.delete(docId: "Doomed")
        XCTAssertFalse(try store.exists(docId: "Doomed"))
        XCTAssertThrowsError(try store.load(docId: "Doomed"))
    }

    /// Deleting is a deliberate user action, so an absent document is reported rather than
    /// silently succeeding — that distinction is what lets the wire answer `unknownDoc`.
    func testStoreDeleteThrowsForAnAbsentDocument() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("delete-absent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try DirectoryDocumentStore(directory: dir).delete(docId: "Ghost")) {
            XCTAssertEqual($0 as? DocumentStoreError, .notFound)
        }
    }

    /// The id sanitising `load`/`save` apply is not bypassed by the delete path.
    func testStoreDeleteRejectsATraversingId() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("delete-traverse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try DirectoryDocumentStore(directory: dir).delete(docId: "../escape")) {
            XCTAssertEqual($0 as? DocumentStoreError, .invalidDocId)
        }
    }

    // MARK: - The manager

    func testDeleteRemovesContentAndIsGoneFromTheListing() async throws {
        let (manager, store, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Doomed", bytes: Data("bye".utf8))

        try await manager.deleteDoc(docId: "Doomed")

        XCTAssertFalse(try store.exists(docId: "Doomed"))
        let listed = try store.list().map(\.docId)
        XCTAssertFalse(listed.contains("Doomed"))
    }

    func testDeletingAnUnknownDocumentThrows() async throws {
        let (manager, _, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try await manager.deleteDoc(docId: "Ghost")
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? DocumentStoreError, .notFound)
        }
    }

    /// The headline: a device with the document OPEN is told, so it can keep its copy as a
    /// local-only document instead of mirroring it straight back onto the server.
    func testLiveSubscribersAreToldTheDocumentWasDeleted() async throws {
        let (manager, store, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Doomed", bytes: Data("bye".utf8))

        let sub = try await manager.subscribe(docId: "Doomed")

        // Collect in the background — the announcement arrives during `deleteDoc`.
        let received = Received()
        let collector = Task {
            for await message in sub.events {
                if case .docDeleted(let id) = message { await received.set(id) }
            }
        }
        defer { collector.cancel() }

        try await manager.deleteDoc(docId: "Doomed")

        let deadline = Date().addingTimeInterval(2)
        while await received.value == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let got = await received.value
        XCTAssertEqual(got, "Doomed", "the subscriber should have been told the doc was deleted")
    }

    /// Nothing is retained: re-creating the same id afterwards is an ordinary create, not a
    /// resurrection that has to defeat a tombstone. This pins the "server stores nothing after
    /// delete" decision — a later tombstone would break this test, which is the point.
    func testTheIdIsFreeAgainImmediatelyAfterDeletion() async throws {
        let (manager, store, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Doomed", bytes: Data("first".utf8))

        try await manager.deleteDoc(docId: "Doomed")
        try store.save(docId: "Doomed", bytes: Data("second".utf8))

        XCTAssertTrue(try store.exists(docId: "Doomed"))
        XCTAssertEqual(try store.load(docId: "Doomed"), Data("second".utf8))

        // And it can be subscribed to again, with a fresh session serving the new bytes.
        let again = try await manager.subscribe(docId: "Doomed")
        guard case .subscribed(_, _, let snapshot) = again.snapshot else {
            return XCTFail("expected a subscribed snapshot, got \(again.snapshot)")
        }
        XCTAssertEqual(snapshot.inlineData, Data("second".utf8))
    }

    /// A document the server knows only as an advertisement (content lives on a device) is
    /// deletable too — otherwise a doc that was never uploaded could never be removed.
    func testAnAdvertisedOnlyDocumentCanBeDeleted() async throws {
        let (manager, _, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "OnlyAdvertised",
                              modifiedAt: Date(timeIntervalSince1970: 0),
                              sizeBytes: 3, thumbnail: nil)],
            connectionId: UUID(), deviceId: "deviceA")
        let before = await manager.liveEntry(docId: "OnlyAdvertised")
        XCTAssertNotNil(before)

        try await manager.deleteDoc(docId: "OnlyAdvertised")

        let after = await manager.liveEntry(docId: "OnlyAdvertised")
        XCTAssertNil(after,
                     "the advertisement must go too, or the deleting device keeps seeing a ghost row")
    }

    private actor Received {
        var value: String?
        func set(_ v: String) { if value == nil { value = v } }
    }
}

/// Both new messages survive a wire round trip. Every other message is pinned this way; an
/// addition that decodes to a different case would fail silently in production.
final class DeleteDocWireTests: XCTestCase {

    func testDeleteDocClientMessageRoundTrips() throws {
        let original = ClientMessage.deleteDoc(docId: "Doomed")
        let decoded = try JSONDecoder().decode(
            ClientMessage.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testDocDeletedServerMessageRoundTrips() throws {
        let original = ServerMessage.docDeleted(docId: "Doomed")
        let decoded = try JSONDecoder().decode(
            ServerMessage.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
