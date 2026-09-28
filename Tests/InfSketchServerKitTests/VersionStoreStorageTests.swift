import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct VersionStoreStorageTests {
    private func store() throws -> (DirectoryVersionStore, URL) {
        let dir = try VersionFixtures.temporaryDirectory()
        return (DirectoryVersionStore(directory: dir), dir)
    }

    /// The whole point: a stored version comes back as EXACTLY the bytes that were stored, because
    /// it becomes a device's merge base and every byte comparison downstream (CAS, skip hash) reads it.
    @Test func aVersionRebuildsByteIdentical() throws {
        let (store, _) = try store()
        let bytes = VersionFixtures.document(marker: "v1", images: [(UUID(), VersionFixtures.image(seed: 1))])
        let hash = VersionDigest.hex(of: bytes)
        try store.record(docId: "doc", bytes: bytes, hash: hash)
        #expect(store.contains(docId: "doc", hash: hash))
        #expect(store.load(docId: "doc", hash: hash) == bytes)
    }

    /// Images are stored ONCE: two versions sharing an image make one blob file.
    @Test func anImageSharedByTwoVersionsIsOneBlob() throws {
        let (store, dir) = try store()
        let image = (UUID(), VersionFixtures.image(seed: 2))
        let v1 = VersionFixtures.document(marker: "v1", images: [image])
        let v2 = VersionFixtures.document(marker: "v2", images: [image])
        try store.record(docId: "doc", bytes: v1, hash: VersionDigest.hex(of: v1))
        try store.record(docId: "doc", bytes: v2, hash: VersionDigest.hex(of: v2))
        let blobs = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName).path)
        #expect(blobs.count == 1)
        let versionFile = dir.appendingPathComponent(".versions/doc/\(VersionDigest.hex(of: v2))")
        let stored = try Data(contentsOf: versionFile)
        #expect(stored.count < v2.count / 2, "the version file must not carry the image")
    }

    /// Review focus 1: V1 has image A, V2 replaced it with image B. V1 still rebuilds exactly.
    @Test func aVersionWhoseImageWasReplacedStillRebuilds() throws {
        let (store, _) = try store()
        let id = UUID()
        let v1 = VersionFixtures.document(marker: "v1", images: [(id, VersionFixtures.image(seed: 3))])
        let v2 = VersionFixtures.document(marker: "v2", images: [(id, VersionFixtures.image(seed: 4))])
        try store.record(docId: "doc", bytes: v1, hash: VersionDigest.hex(of: v1))
        try store.record(docId: "doc", bytes: v2, hash: VersionDigest.hex(of: v2))
        #expect(store.load(docId: "doc", hash: VersionDigest.hex(of: v1)) == v1)
        #expect(store.load(docId: "doc", hash: VersionDigest.hex(of: v2)) == v2)
    }

    /// A missing blob makes the version unusable — nil, never a wrong document.
    @Test func aVersionWithAMissingBlobIsUnusable() throws {
        let (store, dir) = try store()
        let bytes = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 5))])
        let hash = VersionDigest.hex(of: bytes)
        try store.record(docId: "doc", bytes: bytes, hash: hash)
        let blobsDir = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        for name in try FileManager.default.contentsOfDirectory(atPath: blobsDir.path) {
            try FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
        }
        #expect(store.load(docId: "doc", hash: hash) == nil)
    }

    /// A hash that does not match the bytes is refused at record time rather than stored under a lie.
    @Test func recordRefusesAHashThatDoesNotMatch() throws {
        let (store, _) = try store()
        let bytes = VersionFixtures.document(marker: "v")
        #expect(throws: VersionStoreError.self) {
            try store.record(docId: "doc", bytes: bytes, hash: String(repeating: "0", count: 64))
        }
    }

    /// A document id is a directory name: path characters are refused.
    @Test(arguments: ["", "a/b", "..", "a\\b"])
    func aDocIdThatIsAPathIsRefused(_ docId: String) throws {
        let (store, _) = try store()
        let bytes = VersionFixtures.document(marker: "v")
        #expect(throws: VersionStoreError.self) {
            try store.record(docId: docId, bytes: bytes, hash: VersionDigest.hex(of: bytes))
        }
    }

    @Test func theCodecRoundTripsItsManifest() throws {
        let bytes = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 6))])
        let (version, blobs) = StoredVersion.make(from: bytes, digest: Data(repeating: 1, count: 32))
        let decoded = try StoredVersion(encoded: version.encoded())
        #expect(decoded == version)
        #expect(try StoredVersion.manifest(ofEncoded: version.encoded()) == version.manifest)
        #expect(Set(version.manifest.values) == Set(blobs.keys))
    }
}
