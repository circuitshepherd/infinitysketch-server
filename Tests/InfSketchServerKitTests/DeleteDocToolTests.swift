import Foundation
import Testing
import InfSketchWire
@testable import InfSketchServerKit

/// The server-side trash, and the agent-facing `delete_doc` tool built on it.
///
/// Deleting is the only destructive operation in an otherwise additive agent surface, which is why
/// the bytes are moved aside rather than destroyed: an agent that deletes the wrong document has
/// not lost it.
@Suite struct ServerTrashTests {

    private func makeStore() throws -> (DirectoryDocumentStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DirectoryDocumentStore(directory: dir), dir)
    }

    private func trashedFiles(in dir: URL) -> [String] {
        let trash = dir.appendingPathComponent(DirectoryDocumentStore.trashDirectoryName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted()
    }

    /// The document leaves the store but its bytes survive, byte for byte.
    @Test func aDeletedDocumentsBytesSurviveInTheTrash() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Doomed", bytes: Data("precious".utf8))

        try store.delete(docId: "Doomed")

        #expect(try store.exists(docId: "Doomed") == false, "gone from the store")
        let trashed = trashedFiles(in: dir)
        #expect(trashed.count == 1, "expected one trashed file, got \(trashed)")

        let recovered = try Data(contentsOf: dir
            .appendingPathComponent(DirectoryDocumentStore.trashDirectoryName)
            .appendingPathComponent(trashed[0]))
        #expect(recovered == Data("precious".utf8), "the bytes must be recoverable intact")
    }

    /// A trashed document must never show up as a document again — that would be the resurrection
    /// bug this whole feature exists to fix, reintroduced from the server side.
    @Test func trashedDocumentsAreNotListed() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Doomed", bytes: Data("x".utf8))
        try store.save(docId: "Kept", bytes: Data("y".utf8))

        try store.delete(docId: "Doomed")

        #expect(try store.list().map(\.docId) == ["Kept"])
    }

    /// Deleting successive documents of the same name keeps every one of them — the UTC stamp is
    /// what stops the newest silently replacing the last recoverable copy.
    @Test func deletingTheSameNameTwiceKeepsBothCopies() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.save(docId: "Recycled", bytes: Data("first".utf8))
        try store.delete(docId: "Recycled")
        // A stamp with millisecond resolution; make sure the second delete cannot share it.
        Thread.sleep(forTimeInterval: 0.005)
        try store.save(docId: "Recycled", bytes: Data("second".utf8))
        try store.delete(docId: "Recycled")

        #expect(trashedFiles(in: dir).count == 2, "both generations must be recoverable")
    }

    /// The trash directory is created on demand, so an existing server's document directory needs
    /// no migration.
    @Test func theTrashDirectoryIsCreatedOnDemand() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trash = dir.appendingPathComponent(DirectoryDocumentStore.trashDirectoryName)
        #expect(FileManager.default.fileExists(atPath: trash.path) == false, "precondition")

        try store.save(docId: "Doomed", bytes: Data("x".utf8))
        try store.delete(docId: "Doomed")

        #expect(FileManager.default.fileExists(atPath: trash.path))
    }
}
