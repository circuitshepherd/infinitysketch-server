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
