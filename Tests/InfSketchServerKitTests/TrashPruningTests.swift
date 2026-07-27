import Foundation
import Testing
@testable import InfSketchServerKit

/// The server's trash is bounded (spec 2026-07-27-server-trash-pruning-design.md).
///
/// `delete` moves documents into `.trash/<docId>__<UTC-stamp>.infsketch` and nothing ever removed
/// them; one dev store had 46 dead documents after a single session of testing. Retention is 30
/// days, matching the iOS Recently Deleted window the app's own delete already lands in.
///
/// The age comes from the STAMP IN THE NAME, which is what makes these tests possible without a
/// clock: they write a file stamped in 2020 and prune. It is also the correct source —
/// `moveItem` preserves modification dates, so a trashed file's mtime is when the document was
/// last edited, not when it was deleted.
struct TrashPruningTests {

    private func makeStore(retention: TimeInterval = 30 * 24 * 60 * 60)
        throws -> (DirectoryDocumentStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DirectoryDocumentStore(directory: dir, trashRetention: retention), dir)
    }

    private func trashDir(_ dir: URL) -> URL {
        dir.appendingPathComponent(DirectoryDocumentStore.trashDirectoryName, isDirectory: true)
    }

    /// Put a file directly into the trash with a chosen stamp — what a delete N days ago left behind.
    @discardableResult
    private func plantTrashed(_ name: String, in dir: URL) throws -> URL {
        let trash = trashDir(dir)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let url = trash.appendingPathComponent(name).appendingPathExtension("infsketch")
        try Data("trashed".utf8).write(to: url)
        return url
    }

    private func trashNames(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: trashDir(dir).path)) ?? []).sorted()
    }

    @Test func aDocumentTrashedBeyondTheWindowIsRemoved() throws {
        let (store, dir) = try makeStore()
        try plantTrashed("Ancient__2020-01-01_00-00-00-000", in: dir)
        try store.save(docId: "Fresh", bytes: Data("x".utf8))

        try store.delete(docId: "Fresh")     // pruning runs at the end of a delete

        #expect(!trashNames(dir).contains { $0.hasPrefix("Ancient__") })
    }

    @Test func aDocumentTrashedInsideTheWindowIsKept() throws {
        let (store, dir) = try makeStore()
        try store.save(docId: "A", bytes: Data("a".utf8))
        try store.delete(docId: "A")
        try store.save(docId: "B", bytes: Data("b".utf8))

        try store.delete(docId: "B")         // A was trashed moments ago; it must survive this

        #expect(trashNames(dir).contains { $0.hasPrefix("A__") })
        #expect(trashNames(dir).contains { $0.hasPrefix("B__") })
    }

    /// A name we cannot date is KEPT, not guessed at — the safe direction, and the reason age
    /// comes from the name rather than an mtime we might fail to write.
    @Test func aFileWithNoParseableStampIsKept() throws {
        let (store, dir) = try makeStore()
        try plantTrashed("handPlacedNoStamp", in: dir)
        try plantTrashed("AlsoNotAStamp__nonsense", in: dir)
        try store.save(docId: "Fresh", bytes: Data("x".utf8))

        try store.delete(docId: "Fresh")

        #expect(trashNames(dir).contains { $0.hasPrefix("handPlacedNoStamp") })
        #expect(trashNames(dir).contains { $0.hasPrefix("AlsoNotAStamp__") })
    }

    /// A docId may itself contain `__`; the stamp is the LAST one.
    @Test func aDocIdContainingDoubleUnderscoreIsDatedFromTheLastStamp() throws {
        let (store, dir) = try makeStore()
        try plantTrashed("my__doc__2020-01-01_00-00-00-000", in: dir)   // old: must go
        let recent = DirectoryDocumentStore.trashStamp(for: Date())
        try plantTrashed("my__doc__\(recent)", in: dir)                 // recent: must stay
        try store.save(docId: "Fresh", bytes: Data("x".utf8))

        try store.delete(docId: "Fresh")

        let names = trashNames(dir)
        #expect(!names.contains { $0.contains("2020-01-01") })
        #expect(names.contains { $0.contains(recent) })
    }

    /// The boundary itself, via the injected retention: the same file is kept under a long
    /// window and dropped under a short one.
    @Test func theRetentionWindowIsWhatDecides() throws {
        let stamp = DirectoryDocumentStore.trashStamp(for: Date().addingTimeInterval(-3600))

        let (longStore, longDir) = try makeStore(retention: 24 * 60 * 60)   // an hour old, 1-day window
        try plantTrashed("Doc__\(stamp)", in: longDir)
        try longStore.save(docId: "F", bytes: Data("x".utf8))
        try longStore.delete(docId: "F")
        #expect(trashNames(longDir).contains { $0.hasPrefix("Doc__") })

        let (shortStore, shortDir) = try makeStore(retention: 60)           // …and a 1-minute window
        try plantTrashed("Doc__\(stamp)", in: shortDir)
        try shortStore.save(docId: "F", bytes: Data("x".utf8))
        try shortStore.delete(docId: "F")
        #expect(!trashNames(shortDir).contains { $0.hasPrefix("Doc__") })
    }

    /// Pruning is tidying; the delete is what the user asked for. Junk in the trash directory —
    /// a subdirectory, an extensionless file, something from a future naming scheme — must not
    /// cost the user their delete, or its recoverability.
    @Test func theDeleteStillSucceedsWhenTheTrashHoldsJunk() throws {
        let (store, dir) = try makeStore()
        let trash = trashDir(dir)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: trash.appendingPathComponent("a-subdirectory"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: trash.appendingPathComponent("extensionless"))
        try plantTrashed("Ancient__2020-01-01_00-00-00-000", in: dir)
        try store.save(docId: "Doc", bytes: Data("payload".utf8))

        try store.delete(docId: "Doc")

        #expect(try !store.exists(docId: "Doc"))                       // the delete happened…
        #expect(trashNames(dir).contains { $0.hasPrefix("Doc__") })    // …and it is recoverable
        #expect(trashNames(dir).contains("a-subdirectory"))            // junk left alone
        #expect(trashNames(dir).contains("extensionless"))
    }

    /// Existing guarantee, re-pinned because this is the first code to add files to that
    /// directory's lifecycle: trashed documents are never listable.
    @Test func prunedOrNotTrashedDocumentsNeverAppearInAListing() throws {
        let (store, dir) = try makeStore()
        try plantTrashed("Ancient__2020-01-01_00-00-00-000", in: dir)
        try store.save(docId: "Live", bytes: Data("x".utf8))
        try store.save(docId: "Gone", bytes: Data("y".utf8))
        try store.delete(docId: "Gone")

        #expect(try store.list().map(\.docId).sorted() == ["Live"])
        #expect(!trashNames(dir).isEmpty)   // the trash is genuinely non-empty; the listing just hides it
    }

    /// Storage init sweeps too, so a server that runs for weeks without deletes still clears out.
    @Test func initSweepsWithoutNeedingADelete() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-init-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plantTrashed("Ancient__2020-01-01_00-00-00-000", in: dir)

        _ = DirectoryDocumentStore(directory: dir)

        #expect(trashNames(dir).isEmpty)
    }
}
