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

    /// Ruling 5: holds.json must round-trip a Date exactly, sub-second precision included.
    /// `.secondsSince1970` measurably does NOT — a `Date` near "now" spends most of a Double's
    /// mantissa on the whole-second part (~1.8e9), which loses sub-second precision on roughly half
    /// of arbitrary values (measured by the reviewer); a single hand-picked value can round-trip by
    /// luck (as the first version of this test did, built from `Date(timeIntervalSince1970:)`, the
    /// same quantity the broken strategy re-extracts), so this checks MANY sub-second values,
    /// including the reviewer's own reference-date example, rather than one.
    @Test func holdsDatesRoundTripExactlyIncludingSubSecondPrecision() throws {
        let store = DirectoryVersionStore(directory: try VersionFixtures.temporaryDirectory())
        let v = VersionFixtures.document(marker: "v")
        let hash = VersionDigest.hex(of: v)
        try store.record(docId: "doc", bytes: v, hash: hash)
        var whens: [Date] = [Date(timeIntervalSinceReferenceDate: 780_000_000.123456789)]
        for i in stride(from: 0, to: 1000, by: 1) {
            whens.append(Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(i) / 7.0))
        }
        for when in whens {
            store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: hash, now: when)
            #expect(store.holds(docId: "doc")["ipad"]?.lastSeen == when, "mismatch for \(when.timeIntervalSinceReferenceDate)")
        }
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
    /// to disk, can never be referenced by anything — freed at the next start. A non-hex name in
    /// `.blobs/` (never one of ours) is left alone even though it also has zero references.
    @Test func initDeletesOrphanBlobsWithZeroReferences() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let blobsDir = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        let orphan = String(repeating: "5", count: 64)
        try Data("half-written blob, never referenced".utf8).write(to: blobsDir.appendingPathComponent(orphan))
        let stray = ".DS_Store"
        try Data("not a blob at all".utf8).write(to: blobsDir.appendingPathComponent(stray))
        _ = DirectoryVersionStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(orphan).path) == false)
        #expect(FileManager.default.fileExists(atPath: blobsDir.appendingPathComponent(stray).path))
    }

    /// Fix round 1, ruling 2: the repair path's ref-count ordering. A version whose on-disk manifest
    /// still PARSES but was tampered to name the wrong (or a since-deleted) sha must not lose track
    /// of its REAL blob when it is repaired — counting the correct manifest's shas AFTER releasing
    /// the wrong one would let a blob shared with a sibling dip to zero and be deleted the moment
    /// that sibling is later swept, even though the repaired version still needs it.
    @Test func repairAfterATamperedManifestKeepsASiblingsSharedBlobAlive() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let id = UUID()
        let shared = VersionFixtures.image(seed: 60)
        let v1 = VersionFixtures.document(marker: "v1", images: [(id, shared)])
        let v2 = VersionFixtures.document(marker: "v2", images: [(id, shared)])
        let hash1 = VersionDigest.hex(of: v1)
        let hash2 = VersionDigest.hex(of: v2)
        let v1File = dir.appendingPathComponent(".versions/doc/\(hash1)")
        do {
            let store = DirectoryVersionStore(directory: dir)
            try store.record(docId: "doc", bytes: v1, hash: hash1)
            store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: hash1, now: Date())
            try store.record(docId: "doc", bytes: v2, hash: hash2)
            // Tamper v1's on-disk manifest to a well-formed but WRONG sha — it still parses as a
            // `StoredVersion`, so a restart's scan will count the wrong blob for it instead of the
            // real, shared one.
            let (original, _) = StoredVersion.make(from: v1, digest: VersionHash.digest(hex: hash1) ?? Data())
            var wrong: [String: String] = [:]
            for key in original.manifest.keys { wrong[key] = String(repeating: "e", count: 64) }
            try StoredVersion(manifest: wrong, stripped: original.stripped).encoded().write(to: v1File, options: .atomic)
        }
        // The document exists: versions exist only for stored documents, and a start removes the
        // versions of one whose file is gone (a deleted document, Task 4.3).
        try v2.write(to: dir.appendingPathComponent("doc.infsketch"))
        // Restart: the scan counts the WRONG sha for v1 and the real one only once, from v2.
        let reopened = DirectoryVersionStore(directory: dir)
        // Repair v1 by recording the same bytes again — this must restore the real blob's count
        // rather than leaving it attributed to v2 alone.
        try reopened.record(docId: "doc", bytes: v1, hash: hash1)
        #expect(reopened.load(docId: "doc", hash: hash1) == v1, "repaired right after the restart")
        // Push v2 out of the kept set (it is neither held nor current any more) so its reference to
        // the shared blob is released by an ordinary sweep.
        for i in 0..<10 {
            let more = VersionFixtures.document(marker: "more\(i)")
            try reopened.record(docId: "doc", bytes: more, hash: VersionDigest.hex(of: more))
        }
        #expect(reopened.contains(docId: "doc", hash: hash2) == false, "v2 fell out of the kept set")
        // The under-count bug: if v1's real reference was never restored, releasing v2's reference
        // alone drops the shared blob to zero and deletes it — even though v1 (still held) needs it.
        #expect(reopened.load(docId: "doc", hash: hash1) == v1,
                "v1 must still rebuild after v2's sibling reference to the same blob was released")
    }

    /// Fix round 1, ruling 3 (`ensureCurrent`): a `current` version whose file exists but is damaged
    /// must still be repaired — `ensureCurrent`'s old "already current" shortcut only checked that
    /// the file EXISTED, so a damaged current version was never repaired by this door.
    @Test func ensureCurrentRepairsADamagedCurrentVersion() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let bytes = VersionFixtures.document(marker: "v", images: [(UUID(), VersionFixtures.image(seed: 61))])
        let hash = VersionDigest.hex(of: bytes)
        try store.record(docId: "doc", bytes: bytes, hash: hash)
        let versionFile = dir.appendingPathComponent(".versions/doc/\(hash)")
        try Data("garbage, but a file exists at this path".utf8).write(to: versionFile, options: .atomic)
        #expect(store.load(docId: "doc", hash: hash) == nil, "damaged before ensureCurrent repairs it")
        try store.ensureCurrent(docId: "doc", bytes: bytes, hash: hash)
        #expect(store.load(docId: "doc", hash: hash) == bytes, "ensureCurrent repaired the damaged current version")
    }

    /// Fix round 1, ruling 4 (global constraint "never forget a device implicitly"): `record` must
    /// not treat an UNREADABLE holds.json the same as an ABSENT one. The old `readIndex(dir) ??
    /// VersionIndex()` did exactly that, so a corrupted index silently dropped every device's holds
    /// and the very next sweep deleted whatever version only a hold (not the recent-8 window) was
    /// keeping alive.
    @Test func recordDoesNotSweepAwayAHeldVersionWhenHoldsJSONIsUnreadable() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let all = versions(12)
        // Hold FIRST, while all[0] is still known, then write past it — the same shape as
        // `aHeldVersionSurvivesAnyNumberOfWrites` — so it survives on the hold alone, exactly what
        // the corruption below then makes unreadable.
        try store.record(docId: "doc", bytes: all[0].bytes, hash: all[0].hash)
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: all[0].hash, now: Date())
        for v in all.dropFirst() { try store.record(docId: "doc", bytes: v.bytes, hash: v.hash) }
        // all[0] has now fallen out of the recent-8 window; only the (about to be unreadable) hold
        // keeps it.
        let holdsFile = dir.appendingPathComponent(".versions/doc/\(DirectoryVersionStore.holdsFileName)")
        try Data("not json".utf8).write(to: holdsFile, options: .atomic)
        // The record that DISCOVERS the corruption must not itself sweep the document using a
        // fresh, holds-less index — that would delete all[0] in the very call that lost the ability
        // to see it was held.
        let extra = VersionFixtures.document(marker: "extra")
        try store.record(docId: "doc", bytes: extra, hash: VersionDigest.hex(of: extra))
        #expect(store.load(docId: "doc", hash: all[0].hash) == all[0].bytes,
                "a version an unreadable index still (invisibly) named as held must survive the call that discovers this")
        // The unreadable file is preserved, not silently discarded.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".versions/doc").path)
        #expect(entries.contains { $0.hasPrefix("\(DirectoryVersionStore.holdsFileName).corrupt-") },
                "the unreadable holds.json must be quarantined, not deleted or silently overwritten")
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

    // MARK: - Fix round 2 (re-review finding 4): the quarantine must protect EVERY version of the
    // document for as long as it sits there, not only the one call that discovered the corruption.

    /// A tiny locked box for capturing `ServerLog.error` lines — the sink is process-global
    /// (`ServerLogTests`' own note), so this checks by `contains`, never by exact equality.
    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// (a) The quarantine must survive far more than the ONE call that discovers it: 20 further
    /// writes and a `setHold` must sweep NOTHING for this document while the quarantine file sits
    /// there — not merely skip the sweep of the call that found the corruption (fix round 1's
    /// narrower behaviour, which the re-review found insufficient: the very next call would read
    /// the fresh, devices-empty index as `.ok` and sweep normally against it).
    @Test func quarantineProtectsEveryVersionUntilExplicitlyLifted() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let all = versions(12)
        try store.record(docId: "doc", bytes: all[0].bytes, hash: all[0].hash)
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: all[0].hash, now: Date())
        for v in all.dropFirst() { try store.record(docId: "doc", bytes: v.bytes, hash: v.hash) }
        let docDir = dir.appendingPathComponent(".versions/doc")
        let beforeCorruption = Set(try FileManager.default.contentsOfDirectory(atPath: docDir.path)
            .filter { VersionHash.isWellFormed($0) })
        try Data("not json".utf8).write(to: docDir.appendingPathComponent(DirectoryVersionStore.holdsFileName),
                                         options: .atomic)
        // The first record after corruption discovers and quarantines it.
        let extra0 = VersionFixtures.document(marker: "extra0")
        try store.record(docId: "doc", bytes: extra0, hash: VersionDigest.hex(of: extra0))
        // 20 further writes, far past the recent-8 window, plus a setHold — none of these may sweep
        // anything away while the quarantine file sits there.
        for i in 0..<20 {
            let v = VersionFixtures.document(marker: "post\(i)")
            try store.record(docId: "doc", bytes: v, hash: VersionDigest.hex(of: v))
        }
        store.setHold(docId: "doc", deviceId: "iphone", slot: .pushed, hash: nil, now: Date())
        #expect(store.load(docId: "doc", hash: all[0].hash) == all[0].bytes,
                "the version the lost hold named must still load after many further writes and a setHold")
        let afterMany = Set(try FileManager.default.contentsOfDirectory(atPath: docDir.path)
            .filter { VersionHash.isWellFormed($0) })
        #expect(beforeCorruption.isSubset(of: afterMany),
                "no version present before the corruption was discovered may be deleted while quarantined")
        #expect(afterMany.count == beforeCorruption.count + 21,
                "every one of the 21 post-corruption writes must ALSO still be present — nothing was ever swept")
    }

    /// (b) `setHold` may be the very first call to reach a corrupted index (no `record` in between)
    /// — it must quarantine and log exactly as `record` does, not silently answer as if nothing
    /// were held.
    @Test func corruptionDiscoveredThroughSetHoldIsQuarantinedAndLogged() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let v = VersionFixtures.document(marker: "v")
        let hash = VersionDigest.hex(of: v)
        try store.record(docId: "doc", bytes: v, hash: hash)
        let docDir = dir.appendingPathComponent(".versions/doc")
        try Data("not json".utf8).write(to: docDir.appendingPathComponent(DirectoryVersionStore.holdsFileName),
                                         options: .atomic)

        let originalSink = ServerLog.errorSink
        let captured = LogCapture()
        ServerLog.errorSink = { captured.append($0) }
        defer { ServerLog.errorSink = originalSink }

        // record() is never called again — setHold is the first (and only) call to see this.
        _ = store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: hash, now: Date())

        let entries = try FileManager.default.contentsOfDirectory(atPath: docDir.path)
        #expect(entries.contains { $0.hasPrefix("\(DirectoryVersionStore.holdsFileName).corrupt-") },
                "setHold must quarantine an unreadable index itself, not merely fail silently")
        #expect(captured.lines.contains { $0.contains("holds.json did not decode") },
                "setHold must log the corruption the same way record does")
    }

    /// (c) The protection ends only by an explicit action — never by time or by writes. Once the
    /// quarantine file is gone, the very next write sweeps normally again.
    @Test func removingTheQuarantineFileRestoresNormalRetentionOnTheNextWrite() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryVersionStore(directory: dir)
        let all = versions(12)
        try store.record(docId: "doc", bytes: all[0].bytes, hash: all[0].hash)
        store.setHold(docId: "doc", deviceId: "ipad", slot: .base, hash: all[0].hash, now: Date())
        for v in all.dropFirst() { try store.record(docId: "doc", bytes: v.bytes, hash: v.hash) }
        let docDir = dir.appendingPathComponent(".versions/doc")
        try Data("not json".utf8).write(to: docDir.appendingPathComponent(DirectoryVersionStore.holdsFileName),
                                         options: .atomic)
        let extra = VersionFixtures.document(marker: "extra")
        try store.record(docId: "doc", bytes: extra, hash: VersionDigest.hex(of: extra))
        #expect(store.contains(docId: "doc", hash: all[0].hash), "still protected while quarantined")

        let quarantineFiles = try FileManager.default.contentsOfDirectory(atPath: docDir.path)
            .filter { $0.hasPrefix("\(DirectoryVersionStore.holdsFileName).corrupt-") }
        #expect(quarantineFiles.count == 1)
        for name in quarantineFiles { try FileManager.default.removeItem(at: docDir.appendingPathComponent(name)) }

        // The very next write: all[0] is named nowhere in the fresh index started at quarantine
        // time (no devices, and it long ago fell out of `recent`/`current`), so an ordinary sweep
        // removes it now that retention is no longer suspended.
        let after = VersionFixtures.document(marker: "after")
        try store.record(docId: "doc", bytes: after, hash: VersionDigest.hex(of: after))
        #expect(store.contains(docId: "doc", hash: all[0].hash) == false,
                "normal retention must resume on the very next write once the quarantine file is gone")
    }
}
