import Foundation
import Testing
import InfSketchWire
@testable import InfSketchServerKit

/// A server killed part-way through a version-store write (Task 4.3): `verify()` says whether the
/// store is sound, and a start cleans up what an interrupted write left behind — without ever
/// removing what a kept version, a hold or a current document still needs.
@Suite struct VersionStoreRecoveryTests {
    @Test func aSoundStoreVerifiesClean() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let v = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 70))])
        try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        #expect(store.verify().isEmpty)
    }

    @Test func aMissingBlobIsReported() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let v = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 71))])
        try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        let blobs = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        for name in try FileManager.default.contentsOfDirectory(atPath: blobs.path) {
            try FileManager.default.removeItem(at: blobs.appendingPathComponent(name))
        }
        #expect(store.verify().count == 1)
    }

    @Test func anIndexNamingAMissingVersionFileIsReported() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let v = VersionFixtures.document(marker: "v")
        let hash = VersionDigest.hex(of: v)
        try store.record(docId: "doc", bytes: v, hash: hash)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".versions/doc/\(hash)"))
        #expect(store.verify() == ["doc: the index keeps \(hash) but its file is missing"])
    }

    /// A blob written by a `record` that was killed before its version file: nothing references it,
    /// and the next start removes it.
    @Test func anUnreferencedBlobIsRemovedAtStart() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let blobs = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: blobs.appendingPathComponent(String(repeating: "a", count: 64)))
        _ = DirectoryVersionStore(directory: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).isEmpty)
    }

    /// A `removeAll` killed after the index went: the folder of a document that no longer exists is
    /// removed at the next start — and a document that DOES exist keeps its (index-less) folder,
    /// because its next write re-creates the index.
    @Test func anAbandonedVersionFolderIsRemovedAtStart() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        for id in ["gone", "alive"] {
            let v = VersionFixtures.document(marker: id)
            try store.record(docId: id, bytes: v, hash: VersionDigest.hex(of: v))
            try FileManager.default.removeItem(at: dir.appendingPathComponent(".versions/\(id)/holds.json"))
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("alive.infsketch"))
        _ = DirectoryVersionStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versions/gone").path) == false)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versions/alive").path))
    }

    /// The document file may be spelled in another letter case than the folder (a docId resolves
    /// case-insensitively): that is still the folder's document, and its versions stay.
    @Test func aFolderWhoseDocumentExistsInAnotherCaseIsKept() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let v = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 72))])
        try store.record(docId: "ABC-doc", bytes: v, hash: VersionDigest.hex(of: v))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".versions/ABC-doc/holds.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("abc-DOC.infsketch"))
        let reopened = DirectoryVersionStore(directory: dir)
        #expect(reopened.load(docId: "ABC-doc", hash: VersionDigest.hex(of: v)) == v)
        #expect(reopened.verify().isEmpty)
    }

    /// A quarantined index means the holds are UNREADABLE, not absent: the folder is not an
    /// interrupted delete even though `holds.json` is missing, and its versions stay.
    @Test func aFolderWithAQuarantinedIndexIsKept() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let v = VersionFixtures.document(marker: "v")
        try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        let folder = dir.appendingPathComponent(".versions/doc")
        try FileManager.default.moveItem(at: folder.appendingPathComponent("holds.json"),
                                         to: folder.appendingPathComponent("holds.json.corrupt-1"))
        _ = DirectoryVersionStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(VersionDigest.hex(of: v)).path))
    }

    /// "The process died HERE", at every point of a sequence of writes, sweeps and a delete: a copy
    /// of the directory taken at that point must open (running the start-up cleanup) to a store that
    /// verifies clean, and still loads the version a device holds.
    ///
    /// Failed before the fix: a sweep released (deleted) a blob only that version used BEFORE it
    /// removed the version file, so a copy taken between the two had a version file on disk that
    /// could not be rebuilt.
    @Test func aKillAtAnyPointOfAWriteLeavesASoundStore() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let snapshots = try VersionFixtures.temporaryDirectory()
        try Data("x".utf8).write(to: dir.appendingPathComponent("kept.infsketch"))
        let store = DirectoryVersionStore(directory: dir)
        var taken: [(url: URL, point: String, held: String?)] = []
        var held: String?
        store.faultPoint = { point in
            let copy = snapshots.appendingPathComponent("\(taken.count)-\(point)", isDirectory: true)
            try? FileManager.default.copyItem(at: dir, to: copy)
            taken.append((copy, point, held))
        }
        let shared = (0..<3).map { (UUID(), VersionFixtures.image(seed: UInt8(80 + $0))) }
        func version(_ i: Int, _ docId: String) -> Data {
            // A shared image or two, and one only this version uses — so every sweep frees a blob.
            let own = (UUID(), VersionFixtures.image(seed: UInt8(100 + i)))
            return VersionFixtures.document(marker: "\(docId)\(i)",
                                            images: [shared[i % 3], shared[(i + 1) % 3], own],
                                            documentId: docId)
        }
        for i in 0..<13 {
            let v = version(i, "kept")
            try store.record(docId: "kept", bytes: v, hash: VersionDigest.hex(of: v))
            if i == 1 {
                let hash = VersionDigest.hex(of: v)
                #expect(store.setHold(docId: "kept", deviceId: "device", slot: .base, hash: hash,
                                      now: Date(), sparing: []))
                held = hash
            }
        }
        for i in 20..<24 {
            let v = version(i, "deleted")
            try store.record(docId: "deleted", bytes: v, hash: VersionDigest.hex(of: v))
        }
        store.removeAll(docId: "deleted")
        store.faultPoint = nil

        let points = Set(taken.map(\.point))
        #expect(points.isSuperset(of: ["blob", "version", "index", "sweep.version", "blob.deleted",
                                       "removeAll.index", "removeAll.folder"]))
        for snapshot in taken {
            let reopened = DirectoryVersionStore(directory: snapshot.url)
            let problems = reopened.verify()
            #expect(problems.isEmpty, "killed at \(snapshot.url.lastPathComponent): \(problems)")
            if let hash = snapshot.held {
                #expect(reopened.load(docId: "kept", hash: hash) != nil,
                        "killed at \(snapshot.url.lastPathComponent): the held base is gone")
            }
        }
    }
}

extension VersionStoreRecoveryTests {
    /// An `.atomic` write killed before its rename leaves a temporary file named after its target
    /// (`<hash>.sb-…` on Darwin). The next start removes it — and nothing that is not one.
    @Test func anInterruptedAtomicWritesTemporaryFileIsRemovedAtStart() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let v = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 73))])
        let hash = VersionDigest.hex(of: v)
        try store.record(docId: "doc", bytes: v, hash: hash)
        let folder = dir.appendingPathComponent(".versions/doc")
        let blobs = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        let blob = try #require(try FileManager.default.contentsOfDirectory(atPath: blobs.path).first)
        let leftovers = [folder.appendingPathComponent("\(hash).sb-7bd36e75-VHK7ez"),
                         folder.appendingPathComponent("holds.json.sb-7bd36e75-AbCdEf"),
                         blobs.appendingPathComponent(".\(blob).tmp.x1y2z3")]
        let kept = [folder.appendingPathComponent("holds.json.corrupt-12345"),
                    folder.appendingPathComponent("notes.txt"),
                    blobs.appendingPathComponent("README")]
        for url in leftovers + kept { try Data("x".utf8).write(to: url) }
        let reopened = DirectoryVersionStore(directory: dir)
        for url in leftovers { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        #expect(reopened.load(docId: "doc", hash: hash) == v)
    }
}

extension VersionStoreRecoveryTests {
    /// A delete killed before its queued `removeAll` ran: the document file is gone (in the trash)
    /// while its version folder still has its index and a device's hold. A delete removes the
    /// versions AND the holds (spec §1), so the next start finishes it — folder and blobs — while a
    /// document that still exists keeps its versions and holds untouched.
    @Test func aDeleteKilledBeforeItsRemoveAllIsFinishedAtStart() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        var hashes: [String: String] = [:]
        for (id, seed) in [("deleted", UInt8(74)), ("alive", UInt8(75))] {
            let v = VersionFixtures.document(marker: id, images: [(UUID(), VersionFixtures.image(seed: seed))],
                                             documentId: id)
            let hash = VersionDigest.hex(of: v)
            try store.record(docId: id, bytes: v, hash: hash)
            #expect(store.setHold(docId: id, deviceId: "device", slot: .base, hash: hash, now: Date(), sparing: []))
            hashes[id] = hash
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("alive.infsketch"))
        let blobs = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 2)

        let reopened = DirectoryVersionStore(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versions/deleted").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 1)
        #expect(reopened.holds(docId: "alive")["device"]?.base == hashes["alive"])
        #expect(reopened.load(docId: "alive", hash: try #require(hashes["alive"])) != nil)
        #expect(reopened.verify().isEmpty)
    }
}

/// What the start-up cleanup must NEVER do: delete on a read-only verify, or read a failed listing
/// or read as "nothing there" (review of Task 4.3).
extension VersionStoreRecoveryTests {
    private func everyPath(under dir: URL) -> [String] {
        let base = dir.standardizedFileURL.path
        return ((FileManager.default.enumerator(atPath: base)?.allObjects as? [String]) ?? []).sorted()
    }

    /// A store with one of each thing a start would clean: an orphaned blob, the folder of a
    /// deleted document (index and all), and an `.atomic` temporary — plus a live document.
    private func storeWithEverythingACleanupRemoves() throws -> (dir: URL, orphan: URL, deletedFolder: URL, temporary: URL) {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        for id in ["alive", "deleted"] {
            let v = VersionFixtures.document(marker: id, images: [(UUID(), VersionFixtures.image(seed: id == "alive" ? 76 : 77))])
            try store.record(docId: id, bytes: v, hash: VersionDigest.hex(of: v))
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("alive.infsketch"))
        let orphan = dir.appendingPathComponent(".blobs/\(String(repeating: "b", count: 64))")
        try Data("orphan".utf8).write(to: orphan)
        let temporary = dir.appendingPathComponent(".blobs/\(String(repeating: "c", count: 64)).sb-1-x")
        try Data("in flight".utf8).write(to: temporary)
        return (dir, orphan, dir.appendingPathComponent(".versions/deleted"), temporary)
    }

    @Test func aReadOnlyVerifyDeletesNothing() throws {
        let (dir, _, _, _) = try storeWithEverythingACleanupRemoves()
        let before = everyPath(under: dir)
        let problems = DirectoryVersionStore(directory: dir, cleanup: false).verify()
        #expect(problems.isEmpty)
        #expect(everyPath(under: dir) == before)
        // …while an ordinary start does clean them up, so the fixture really has something to lose.
        _ = DirectoryVersionStore(directory: dir)
        #expect(everyPath(under: dir) != before)
    }

    /// No document file listed while version folders exist: the documents may just not be visible
    /// (evicted, a partial sync, moved away), so nothing is removed.
    @Test func noVisibleDocumentRemovesNoVersionFolder() throws {
        let (dir, _, deletedFolder, _) = try storeWithEverythingACleanupRemoves()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("alive.infsketch"))
        _ = DirectoryVersionStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: deletedFolder.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versions/alive").path))
    }

    /// Runs `body` with `url`'s permissions set to `mode`, restoring them after. Returns false (and
    /// runs nothing) when the permissions do not take — as root, e.g. the Linux container, where
    /// every read succeeds regardless.
    private func withPermissions(_ mode: Int, on url: URL, readable probe: () -> Bool, _ body: () throws -> Void) throws -> Bool {
        let fm = FileManager.default
        let original = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o755
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path) }
        guard !probe() else { return false }
        try body()
        return true
    }

    @Test func anUnlistableDocumentsFolderRemovesNoVersionFolder() throws {
        let (dir, _, deletedFolder, _) = try storeWithEverythingACleanupRemoves()
        // Write and search but not read: the store can still reach `.versions/`, but cannot list
        // which documents exist.
        let ran = try withPermissions(0o333, on: dir,
                                      readable: { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil }) {
            _ = DirectoryVersionStore(directory: dir)
        }
        guard ran else { return }
        #expect(FileManager.default.fileExists(atPath: deletedFolder.path))
    }

    @Test func anUnlistableVersionFolderRemovesNoBlob() throws {
        let (dir, orphan, _, _) = try storeWithEverythingACleanupRemoves()
        let folder = dir.appendingPathComponent(".versions/alive")
        let ran = try withPermissions(0o000, on: folder,
                                      readable: { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil }) {
            _ = DirectoryVersionStore(directory: dir)
        }
        guard ran else { return }
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(DirectoryVersionStore(directory: dir, cleanup: false).verify().isEmpty)
    }

    @Test func anUnreadableVersionFileRemovesNoBlob() throws {
        let (dir, orphan, _, _) = try storeWithEverythingACleanupRemoves()
        let folder = dir.appendingPathComponent(".versions/alive")
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first(where: VersionHash.isWellFormed))
        let file = folder.appendingPathComponent(name)
        let blobs = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        let blobsBefore = try FileManager.default.contentsOfDirectory(atPath: blobs.path).filter(VersionHash.isWellFormed)
        let ran = try withPermissions(0o000, on: file, readable: { (try? Data(contentsOf: file)) != nil }) {
            _ = DirectoryVersionStore(directory: dir)
        }
        guard ran else { return }
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        // The unreadable version's own blob above all: an incomplete count would call it unreferenced.
        let blobsAfter = try FileManager.default.contentsOfDirectory(atPath: blobs.path).filter(VersionHash.isWellFormed)
        #expect(Set(blobsBefore).isSubset(of: Set(blobsAfter)))
        #expect(DirectoryVersionStore(directory: dir, cleanup: false).load(docId: "alive", hash: name) != nil)
    }
}
