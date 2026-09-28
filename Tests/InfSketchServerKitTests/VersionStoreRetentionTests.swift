import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct VersionStoreRetentionTests {
    private func versions(_ n: Int, images: [(UUID, Data)] = []) -> [(bytes: Data, hash: String)] {
        (0..<n).map { i in
            let bytes = VersionFixtures.document(marker: "v\(i)", images: images)
            return (bytes, VersionDigest.hex(of: bytes))
        }
    }

    @Test func onlyTheCurrentAndTheLastEightAreKeptWhenNobodyHoldsAnything() throws {
        let store = DirectoryVersionStore(directory: try VersionFixtures.temporaryDirectory())
        let all = versions(12)
        for v in all { try store.record(docId: "doc", bytes: v.bytes, hash: v.hash) }
        #expect(store.keptHashes(docId: "doc") == Set(all.suffix(8).map(\.hash)))
        #expect(store.load(docId: "doc", hash: all[0].hash) == nil)
    }

    /// Spec decision 2: a version a device holds stays, however many writes follow.
    @Test func aHeldVersionSurvivesAnyNumberOfWrites() throws {
        let store = DirectoryVersionStore(directory: try VersionFixtures.temporaryDirectory())
        let all = versions(30)
        try store.record(docId: "doc", bytes: all[0].bytes, hash: all[0].hash)
        #expect(store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: all[0].hash, now: Date()))
        for v in all.dropFirst() { try store.record(docId: "doc", bytes: v.bytes, hash: v.hash) }
        #expect(store.load(docId: "doc", hash: all[0].hash) == all[0].bytes)
    }

    /// …and goes when that device reports a newer one (and nothing else holds it).
    @Test func reportingANewerBaseReleasesTheOldOne() throws {
        let store = DirectoryVersionStore(directory: try VersionFixtures.temporaryDirectory())
        let all = versions(12)
        for v in all { try store.record(docId: "doc", bytes: v.bytes, hash: v.hash) }
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: all[11].hash, now: Date())
        // all[0..3] fell out of the recent window before anyone held them.
        #expect(store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: all[0].hash, now: Date()) == false)
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: all[5].hash, now: Date())
        for i in 12..<25 {
            let bytes = VersionFixtures.document(marker: "w\(i)")
            try store.record(docId: "doc", bytes: bytes, hash: VersionDigest.hex(of: bytes))
        }
        #expect(store.contains(docId: "doc", hash: all[5].hash))
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: nil, now: Date())
        #expect(store.contains(docId: "doc", hash: all[5].hash) == false)
    }

    /// Review focus 2: reporting a version the server no longer has holds NOTHING in that slot —
    /// the device's note no longer names the old one, so the old base goes too — and resurrects
    /// nothing.
    @Test func holdingAnUnknownVersionReleasesThePreviousBase() throws {
        let store = DirectoryVersionStore(directory: try VersionFixtures.temporaryDirectory())
        let all = versions(20)
        try store.record(docId: "doc", bytes: all[0].bytes, hash: all[0].hash)
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: all[0].hash, now: Date())
        for v in all.dropFirst() { try store.record(docId: "doc", bytes: v.bytes, hash: v.hash) }
        let released = String(repeating: "a", count: 64)
        #expect(store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: released, now: Date()) == false)
        #expect(store.holds(docId: "doc")["ipad"]?.base == nil)
        #expect(store.contains(docId: "doc", hash: all[0].hash) == false)
        #expect(store.contains(docId: "doc", hash: released) == false)
    }

    /// A hold on a document the store has never seen creates nothing on disk.
    @Test func aHoldOnAnUnknownDocumentCreatesNothing() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        #expect(store.setHold(docId: "ghost", deviceId: "ipad", slot: .base,
                              hash: String(repeating: "b", count: 64), now: Date()) == false)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versions/ghost").path) == false)
    }

    /// Review focus 1, second half: the image of a released version goes with it; an image a kept
    /// version still uses stays.
    @Test func aBlobGoesWhenTheLastVersionUsingItGoes() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let id = UUID()
        let a = VersionFixtures.image(seed: 10), b = VersionFixtures.image(seed: 11)
        let v1 = VersionFixtures.document(marker: "v1", images: [(id, a)])
        try store.record(docId: "doc", bytes: v1, hash: VersionDigest.hex(of: v1))
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: VersionDigest.hex(of: v1), now: Date())
        for i in 0..<10 {
            let v = VersionFixtures.document(marker: "b\(i)", images: [(id, b)])
            try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        }
        let blobsDir = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobsDir.path).count == 2)
        #expect(store.load(docId: "doc", hash: VersionDigest.hex(of: v1)) == v1)
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: nil, now: Date())
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobsDir.path).count == 1)
    }

    /// Review focus 5: one device away for a long time while another writes 200 times.
    @Test func manyWritesKeepOnlyWhatIsHeld() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let shared = (UUID(), VersionFixtures.image(seed: 20))
        let first = VersionFixtures.document(marker: "start", images: [shared])
        try store.record(docId: "doc", bytes: first, hash: VersionDigest.hex(of: first))
        store.setHold(docId: "doc", deviceId: "away", slot: .base, hash: VersionDigest.hex(of: first), now: Date())
        for i in 0..<200 {
            let v = VersionFixtures.document(marker: "w\(i)", images: i % 2 == 0 ? [shared] : [])
            try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".versions/doc").path)
            .filter { $0 != DirectoryVersionStore.holdsFileName }
        #expect(files.count == 9, "the last 8 (current among them) + the away device's base")
        #expect(store.load(docId: "doc", hash: VersionDigest.hex(of: first)) == first)
        // Every kept file referencing the shared image counts once.
        let referencing = try files.filter { name in
            let raw = try Data(contentsOf: dir.appendingPathComponent(".versions/doc/\(name)"))
            return try !StoredVersion.manifest(ofEncoded: raw).isEmpty
        }.count
        #expect(store.blobReferenceCount(VersionDigest.hex(of: Data(shared.1.base64EncodedString()
            .replacingOccurrences(of: "/", with: "\\/").utf8))) == referencing)
    }

    @Test func removeAllForgetsTheDocumentAndItsBlobs() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let v = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 30))])
        try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        store.removeAll(docId: "doc")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versions/doc").path) == false)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName).path).isEmpty)
    }

    /// A restart rebuilds the reference counts from disk, so a sweep after it still deletes a blob
    /// exactly when the last version using it goes.
    @Test func referenceCountsSurviveARestart() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let id = UUID()
        let v1 = VersionFixtures.document(marker: "v1", images: [(id, VersionFixtures.image(seed: 40))])
        do {
            let store = DirectoryVersionStore(directory: dir)
            try store.record(docId: "doc", bytes: v1, hash: VersionDigest.hex(of: v1))
        }
        let reopened = DirectoryVersionStore(directory: dir)
        for i in 0..<9 {
            let v = VersionFixtures.document(marker: "n\(i)")
            try reopened.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName).path).isEmpty)
    }

    @Test func holdsRecordLastSeen() throws {
        let store = DirectoryVersionStore(directory: try VersionFixtures.temporaryDirectory())
        let v = VersionFixtures.document(marker: "v")
        try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        store.setHold(docId: "doc", deviceId: "ipad", slot: .delivered, hash: VersionDigest.hex(of: v), now: when)
        #expect(store.holds(docId: "doc")["ipad"]?.lastSeen == when)
        #expect(store.holds(docId: "doc")["ipad"]?.delivered == VersionDigest.hex(of: v))
    }

    // MARK: - Controller-ruling hardening (Task 1.2 review), one test per ruling

    /// Ruling 5: holds.json must round-trip a Date exactly, sub-second precision included — an
    /// ISO8601 string without fractional seconds would silently truncate it on every write.
    @Test func holdsDatesRoundTripExactlyIncludingSubSecondPrecision() throws {
        let store = DirectoryVersionStore(directory: try VersionFixtures.temporaryDirectory())
        let v = VersionFixtures.document(marker: "v")
        try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        let when = Date(timeIntervalSince1970: 1_800_000_000.123456)
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: VersionDigest.hex(of: v), now: when)
        #expect(store.holds(docId: "doc")["ipad"]?.lastSeen == when)
    }

    /// Ruling 1 (load half): a manifest can be made to name anything as a blob's "sha" — a value
    /// that is not well-formed hex must never reach the filesystem as a path component, and the
    /// version is simply unusable rather than the store reading outside `.blobs/`.
    @Test func loadRefusesAVersionWithAMalformedBlobReference() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let image = (UUID(), VersionFixtures.image(seed: 52))
        let bytes = VersionFixtures.document(marker: "v", images: [image])
        let hash = VersionDigest.hex(of: bytes)
        try store.record(docId: "doc", bytes: bytes, hash: hash)
        let (version, _) = StoredVersion.make(from: bytes, digest: VersionHash.digest(hex: hash) ?? Data())
        var poisoned: [String: String] = [:]
        for key in version.manifest.keys { poisoned[key] = "../../../etc/passwd" }
        let tampered = StoredVersion(manifest: poisoned, stripped: version.stripped)
        let versionFile = dir.appendingPathComponent(".versions/doc/\(hash)")
        try tampered.encoded().write(to: versionFile, options: .atomic)
        #expect(store.load(docId: "doc", hash: hash) == nil)
    }

    /// Ruling 1 (sweep/releaseBlob half): releasing a malformed "sha" must be inert — never an
    /// attempt to remove a file outside `.blobs/`, and never a wrong decrement of a real blob.
    @Test func releaseBlobIgnoresAMalformedShaRatherThanTouchingAPath() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let bytes = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 53))])
        try store.record(docId: "doc", bytes: bytes, hash: VersionDigest.hex(of: bytes))
        let blobsDir = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        let before = try FileManager.default.contentsOfDirectory(atPath: blobsDir.path).sorted()
        store.releaseBlob("../outside")
        store.releaseBlob(String(repeating: "z", count: 64)) // right length, wrong alphabet
        store.releaseBlob("")
        let after = try FileManager.default.contentsOfDirectory(atPath: blobsDir.path).sorted()
        #expect(before == after)
    }

    /// Ruling 2: a version whose blob was lost (crash, disk error, a stray delete) is repaired the
    /// next time the same bytes are recorded — from the bytes being recorded, not from what little
    /// survives on disk.
    @Test func recordRepairsAVersionWithAMissingBlob() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let bytes = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 54))])
        let hash = VersionDigest.hex(of: bytes)
        try store.record(docId: "doc", bytes: bytes, hash: hash)
        let blobsDir = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        for name in try FileManager.default.contentsOfDirectory(atPath: blobsDir.path) {
            try FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
        }
        #expect(store.load(docId: "doc", hash: hash) == nil, "damaged before the repair")
        try store.record(docId: "doc", bytes: bytes, hash: hash)
        #expect(store.load(docId: "doc", hash: hash) == bytes, "repaired by recording the same bytes again")
    }

    /// Ruling 2, the other half: the version FILE itself can be the thing damaged (a crash mid
    /// write), not only a blob.
    @Test func recordRepairsAVersionFileDamagedByAPartialWrite() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let bytes = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 55))])
        let hash = VersionDigest.hex(of: bytes)
        try store.record(docId: "doc", bytes: bytes, hash: hash)
        let versionFile = dir.appendingPathComponent(".versions/doc/\(hash)")
        try Data("not a real version file".utf8).write(to: versionFile, options: .atomic)
        #expect(store.load(docId: "doc", hash: hash) == nil, "damaged before the repair")
        try store.record(docId: "doc", bytes: bytes, hash: hash)
        #expect(store.load(docId: "doc", hash: hash) == bytes, "repaired by recording the same bytes again")
    }

    /// Ruling 3 (sweep half): a version file that cannot even be parsed as a `StoredVersion` must
    /// still be swept away once it falls out of the kept set, rather than wedging retention.
    @Test func sweepDeletesAVersionFileWhoseManifestDoesNotParse() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let real = VersionFixtures.document(marker: "real")
        try store.record(docId: "doc", bytes: real, hash: VersionDigest.hex(of: real))
        let docDir = dir.appendingPathComponent(".versions/doc")
        let garbageHash = String(repeating: "9", count: 64)
        try Data("not a version at all".utf8).write(to: docDir.appendingPathComponent(garbageHash), options: .atomic)
        // Any further record triggers another sweep.
        let another = VersionFixtures.document(marker: "another")
        try store.record(docId: "doc", bytes: another, hash: VersionDigest.hex(of: another))
        #expect(FileManager.default.fileExists(atPath: docDir.appendingPathComponent(garbageHash).path) == false)
    }

    /// Ruling 3 (init half): a blob written just before a crash, whose version file never made it
    /// to disk, can never be referenced by anything — freed at the next start.
    @Test func initDeletesOrphanBlobsWithZeroReferences() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let blobsDir = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        let orphan = String(repeating: "5", count: 64)
        try Data("half-written blob, never referenced".utf8).write(to: blobsDir.appendingPathComponent(orphan))
        _ = DirectoryVersionStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(orphan).path) == false)
    }

    /// Ruling 4: `docDir` must still refuse the exact strings "." and ".." even though
    /// `DocumentStore.fileURL`'s own character checks would let "." through.
    @Test func docDirRefusesExactDotAndDotDot() throws {
        let store = DirectoryVersionStore(directory: try VersionFixtures.temporaryDirectory())
        let bytes = VersionFixtures.document(marker: "v")
        for docId in [".", ".."] {
            #expect(throws: VersionStoreError.self) {
                try store.record(docId: docId, bytes: bytes, hash: VersionDigest.hex(of: bytes))
            }
        }
    }

    /// Ruling 4, the parity half: anything `DocumentStore` accepts as a docId — including a name
    /// that merely starts with "." — must still be accepted here.
    @Test func docDirAcceptsWhatDocumentStoreAccepts() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let docStore = DirectoryDocumentStore(directory: dir.appendingPathComponent("docs"))
        let versionStore = DirectoryVersionStore(directory: dir.appendingPathComponent("versions"))
        let bytes = VersionFixtures.document(marker: "v")
        for docId in [".hidden", "a.b.c", "normal-name"] {
            #expect(throws: Never.self) { try docStore.save(docId: docId, bytes: Data("{}".utf8)) }
            #expect(throws: Never.self) {
                try versionStore.record(docId: docId, bytes: bytes, hash: VersionDigest.hex(of: bytes))
            }
        }
    }
}
