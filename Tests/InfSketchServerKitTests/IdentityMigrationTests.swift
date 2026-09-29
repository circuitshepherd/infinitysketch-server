import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct IdentityMigrationTests {
    private func write(_ text: String, _ stem: String, in dir: URL, age: TimeInterval) throws {
        try write(Data(text.utf8), stem, in: dir, age: age)
    }

    private func write(_ data: Data, _ stem: String, in dir: URL, age: TimeInterval) throws {
        let url = dir.appendingPathComponent(stem).appendingPathExtension("infsketch")
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    private func documentFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".infsketch") }.sorted()
    }

    /// A pre-identity server folder: a legacy document, a document with an id, and a Files-style
    /// copy of it carrying the SAME id. Three documents come out, each under its own id, labelled
    /// by its old file name — and the copy (the newer file) is the one that gets a fresh id.
    @Test func aNameKeyedFolderBecomesIdKeyed() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        try write(#"{"aaa001_thumbnailData":"","drawingData":""}"#, "Chart", in: dir, age: 300)
        try write(#"{"aaa001_thumbnailData":"","documentId":"PLAN-ID","drawingData":""}"#, "Plan", in: dir, age: 200)
        try write(#"{"aaa001_thumbnailData":"","documentId":"PLAN-ID","drawingData":""}"#, "Copy of Plan", in: dir, age: 100)

        let store = DirectoryDocumentStore(directory: dir)
        let docs = try store.list()
        #expect(Set(docs.map(\.name)) == ["Chart", "Plan", "Copy of Plan"])
        #expect(docs.first { $0.name == "Plan" }?.docId == "PLAN-ID")
        let copyId = try #require(docs.first { $0.name == "Copy of Plan" }?.docId)
        #expect(copyId != "PLAN-ID")
        let chartId = try #require(docs.first { $0.name == "Chart" }?.docId)
        let chartBytes = try store.load(docId: chartId)
        #expect(DocumentIdentity.documentId(of: chartBytes) == chartId)
        #expect(String(decoding: chartBytes, as: UTF8.self).hasPrefix(#"{"aaa001_thumbnailData""#))
        #expect(DocumentIdentity.documentId(of: try store.load(docId: copyId)) == copyId)
        for stem in ["Chart", "Plan", "Copy of Plan"] {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem).infsketch").path))
        }
    }

    @Test func itRunsOnce() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        try write(#"{"aaa001_thumbnailData":""}"#, "Chart", in: dir, age: 10)
        let first = try DirectoryDocumentStore(directory: dir).list().map(\.docId)
        let second = try DirectoryDocumentStore(directory: dir).list().map(\.docId)
        #expect(first == second)
    }

    /// A store created on an EMPTY directory is already id-keyed: documents saved afterwards under
    /// any id are never "migrated" by a later restart.
    @Test func aFreshDirectoryIsNeverMigrated() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        try DirectoryDocumentStore(directory: dir).save(docId: "d", bytes: Fixtures.docBytes)
        #expect(try DirectoryDocumentStore(directory: dir).list().map(\.docId) == ["d"])
    }

    /// Killed between writing `<id>.infsketch` and removing the old file: the next start finishes
    /// the job and does NOT mint a second id for the same document.
    @Test func anInterruptedMigrationFinishesWithoutDuplicating() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let bytes = #"{"aaa001_thumbnailData":"","documentId":"X-ID"}"#
        try write(bytes, "Chart", in: dir, age: 10)
        try write(bytes, "X-ID", in: dir, age: 10)
        let docs = try DirectoryDocumentStore(directory: dir).list()
        #expect(docs.map(\.docId) == ["X-ID"])
        #expect(docs.first?.name == "Chart")
    }

    /// Killed one step later — the label is on disk, the old file is not yet removed. Still one
    /// document: an old file whose bytes ARE the labelled target's, under the name the label
    /// records, is that document, not a copy of it.
    @Test func aMigrationKilledAfterTheLabelFinishesWithoutDuplicating() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let bytes = #"{"aaa001_thumbnailData":"","documentId":"X-ID"}"#
        try write(bytes, "Chart", in: dir, age: 10)
        try write(bytes, "X-ID", in: dir, age: 10)
        try DocumentLabels(directory: dir).replaceAll(["X-ID": "Chart"])
        let docs = try DirectoryDocumentStore(directory: dir).list()
        #expect(docs.map(\.docId) == ["X-ID"])
        #expect(docs.first?.name == "Chart")
    }

    /// Killed after a fresh id was written INTO the old file but before its target existed: the
    /// next start reads that id back and uses it — still one document.
    @Test func aMigrationKilledAfterMintingReusesTheMintedId() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        try write(#"{"aaa001_thumbnailData":"","documentId":"MINTED"}"#, "Chart", in: dir, age: 10)
        let docs = try DirectoryDocumentStore(directory: dir).list()
        #expect(docs.map(\.docId) == ["MINTED"])
        #expect(docs.first?.name == "Chart")
    }

    /// An id-named file that is NOT this document (different bytes) must never be taken for its
    /// finished target and the old file removed. The file already holding the id keeps it — even
    /// though the old-named file is OLDER, since taking the id would mean overwriting a file — and
    /// the old document gets a fresh id. Both survive byte-for-byte apart from that id.
    @Test func anOccupiedTargetWithOtherContentIsNeverTakenForThisDocument() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let occupant = Data(#"{"aaa001_thumbnailData":"","documentId":"X-ID","marker":"occupant"}"#.utf8)
        try write(occupant, "X-ID", in: dir, age: 10)
        try write(#"{"aaa001_thumbnailData":"","documentId":"X-ID","marker":"chart"}"#, "Chart", in: dir, age: 50)

        let store = DirectoryDocumentStore(directory: dir)
        let docs = try store.list()
        #expect(docs.count == 2)
        #expect(try store.load(docId: "X-ID") == occupant)
        let chart = try #require(docs.first { $0.name == "Chart" })
        #expect(chart.docId != "X-ID")
        let chartBytes = try store.load(docId: chart.docId)
        #expect(String(decoding: chartBytes, as: UTF8.self).contains(#""marker":"chart""#))
        #expect(DocumentIdentity.documentId(of: chartBytes) == chart.docId)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Chart.infsketch").path))
    }

    /// An id that cannot be a file name (a path separator, `..`, a leading dot) is replaced by a
    /// fresh one rather than written somewhere outside the folder or skipped.
    @Test func anIdThatCannotBeAFileNameIsReplaced() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        try write(#"{"aaa001_thumbnailData":"","documentId":"../escape"}"#, "Chart", in: dir, age: 10)
        let store = DirectoryDocumentStore(directory: dir)
        let docs = try store.list()
        #expect(docs.count == 1)
        let id = try #require(docs.first?.docId)
        #expect(id != "../escape")
        #expect(DocumentIdentity.documentId(of: try store.load(docId: id)) == id)
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.infsketch").path))
    }

    /// Bytes the migration cannot give an id to — not JSON, or a `documentId` that is not a string —
    /// are LEFT EXACTLY WHERE THEY ARE. They stay listed under their old name; nothing is lost, and
    /// the rest of the folder still migrates.
    @Test func aFileThatCannotCarryAnIdIsLeftUntouched() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let garbage = Data([0xFF, 0x00, 0x7B])
        let numericId = Data(#"{"aaa001_thumbnailData":"","documentId":5}"#.utf8)
        try write(garbage, "Broken", in: dir, age: 30)
        try write(numericId, "Numeric", in: dir, age: 20)
        try write(#"{"aaa001_thumbnailData":""}"#, "Chart", in: dir, age: 10)

        let store = DirectoryDocumentStore(directory: dir)
        #expect(try store.load(docId: "Broken") == garbage)
        #expect(try store.load(docId: "Numeric") == numericId)
        let docs = try store.list()
        #expect(docs.count == 3)
        #expect(docs.contains { $0.name == "Chart" && $0.docId != "Chart" })
    }

    /// A file left behind for a PERMANENT reason (it cannot carry an id) still lets the migration
    /// finish: the marker is written, so it is not retried at every start.
    @Test func aFileThatCannotCarryAnIdStillCompletesTheMigration() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        try write(Data([0xFF, 0x00, 0x7B]), "Broken", in: dir, age: 30)
        _ = DirectoryDocumentStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(IdentityMigration.markerName).path))
    }

    /// A write that FAILED (a full disk) is not a reason to give up on the document: no marker is
    /// written, the old file stays, and the next start migrates it.
    @Test func aFailedWriteLeavesTheMarkerUnwrittenAndTheNextStartMigrates() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        try write(#"{"aaa001_thumbnailData":""}"#, "Chart", in: dir, age: 10)
        struct DiskFull: Error {}
        IdentityMigration.run(in: dir, labels: DocumentLabels(directory: dir)) { data, url in
            guard url.lastPathComponent == IdentityMigration.markerName else { throw DiskFull() }
            try data.write(to: url, options: .atomic)
        }
        let marker = dir.appendingPathComponent(IdentityMigration.markerName)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Chart.infsketch").path))

        let docs = try DirectoryDocumentStore(directory: dir).list()
        #expect(docs.count == 1)
        #expect(docs.first?.name == "Chart")
        #expect(docs.first?.docId != "Chart")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Everything in the folder that is not a top-level `<stem>.infsketch` document is not the
    /// migration's business: the trash, the server id, atomic-write leftovers, hidden files.
    @Test func theTrashTheServerIdAndLeftoversAreUntouched() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let fm = FileManager.default
        let trash = dir.appendingPathComponent(DirectoryDocumentStore.trashDirectoryName, isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = trash.appendingPathComponent("Old__\(DirectoryDocumentStore.trashStamp())").appendingPathExtension("infsketch")
        try Data(#"{"aaa001_thumbnailData":""}"#.utf8).write(to: trashed)
        let serverId = dir.appendingPathComponent(DirectoryDocumentStore.serverIdFileName)
        try Data("SERVER\n".utf8).write(to: serverId)
        let hidden = dir.appendingPathComponent(".hidden.infsketch")
        try Data(#"{"aaa001_thumbnailData":""}"#.utf8).write(to: hidden)
        try write(#"{"aaa001_thumbnailData":""}"#, "Chart", in: dir, age: 10)

        let store = DirectoryDocumentStore(directory: dir)
        #expect(try Data(contentsOf: trashed) == Data(#"{"aaa001_thumbnailData":""}"#.utf8))
        #expect(try Data(contentsOf: serverId) == Data("SERVER\n".utf8))
        #expect(try Data(contentsOf: hidden) == Data(#"{"aaa001_thumbnailData":""}"#.utf8))
        #expect(store.persistentServerId() == "SERVER")
        #expect(try store.list().filter { $0.name == "Chart" }.count == 1)
    }

    /// Two legacy documents with identical bytes are two documents: each gets its own id.
    @Test func identicalLegacyDocumentsStayTwoDocuments() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        try write(#"{"aaa001_thumbnailData":""}"#, "One", in: dir, age: 20)
        try write(#"{"aaa001_thumbnailData":""}"#, "Two", in: dir, age: 10)
        let docs = try DirectoryDocumentStore(directory: dir).list()
        #expect(Set(docs.map(\.name)) == ["One", "Two"])
        #expect(Set(docs.map(\.docId)).count == 2)
    }

    /// A file already named by the id it carries (in any letter case — a case-insensitive disk
    /// shows `x-id` for `X-ID`) is already in the id layout: it stays exactly where it is.
    @Test func aFileAlreadyNamedByItsIdStays() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let bytes = Data(#"{"aaa001_thumbnailData":"","documentId":"X-ID"}"#.utf8)
        try write(bytes, "x-id", in: dir, age: 10)
        let store = DirectoryDocumentStore(directory: dir)
        #expect(try documentFiles(dir) == ["x-id.infsketch"])
        #expect(try store.load(docId: "x-id") == bytes)
    }
}
