import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct SessionVersionsTests {
    private func setUp() throws -> (SessionManager, DirectoryVersionStore, URL) {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryDocumentStore(directory: dir)
        let versions = DirectoryVersionStore(directory: dir)
        try store.save(docId: "doc", bytes: VersionFixtures.document(marker: "v0"))
        return (SessionManager(store: store, versions: versions), versions, dir)
    }

    /// A write needs a live session (the WebSocket path always has one); `open` provides it for the
    /// tests that only care about what gets kept. A caller that DROPS the result also drops the
    /// subscription at the next broadcast (its stream is gone), after that broadcast's version was
    /// already held as delivered to "writer".
    @discardableResult
    private func open(_ manager: SessionManager) async throws -> SubscribeResult {
        try await manager.subscribe(docId: "doc", deviceId: "writer")
    }

    /// Waits for the write's version job too (`VersionWork`), since the tests then read the store.
    private func push(_ manager: SessionManager, _ bytes: Data, from device: String?,
                      docId: String = "doc") async -> SubmitOutcome {
        let outcome = await manager.submit(docId: docId, opId: UUID().uuidString,
                                           payload: OpPayload(type: "fullDoc", data: bytes),
                                           holderDeviceId: device)
        await manager.drainVersionWork(docId: docId)
        return outcome
    }

    private func noteBase(_ manager: SessionManager, _ hash: String, device: String, docId: String = "doc") async {
        await manager.noteBaseSaved(docId: docId, versionHash: hash, deviceId: device)
        await manager.drainVersionWork(docId: docId)
    }

    @Test func anAcceptedPushIsKeptAndHeldForItsDevice() async throws {
        let (manager, versions, _) = try setUp()
        let sub = try await manager.subscribe(docId: "doc", deviceId: "ipad")
        let v1 = VersionFixtures.document(marker: "v1")
        #expect(await push(manager, v1, from: "ipad") == .accepted(seq: 1))
        #expect(versions.contains(docId: "doc", hash: VersionDigest.hex(of: v1)))
        #expect(versions.holds(docId: "doc")["ipad"]?.pushed == VersionDigest.hex(of: v1))
        await manager.unsubscribe(docId: "doc", token: sub.token)
    }

    @Test func aBroadcastIsHeldAsDeliveredForTheOtherDevices() async throws {
        let (manager, versions, _) = try setUp()
        let a = try await manager.subscribe(docId: "doc", deviceId: "ipad")
        let b = try await manager.subscribe(docId: "doc", deviceId: "mac")
        let v1 = VersionFixtures.document(marker: "v1")
        _ = await push(manager, v1, from: "ipad")
        #expect(versions.holds(docId: "doc")["mac"]?.delivered == VersionDigest.hex(of: v1))
        await manager.unsubscribe(docId: "doc", token: a.token)
        await manager.unsubscribe(docId: "doc", token: b.token)
    }

    @Test func aSubscribeGetsTheBaseItNames() async throws {
        let (manager, _, _) = try setUp()
        try await open(manager)
        let v1 = VersionFixtures.document(marker: "v1", images: [(UUID(), VersionFixtures.image(seed: 60))])
        _ = await push(manager, v1, from: "ipad")
        _ = await push(manager, VersionFixtures.document(marker: "v2"), from: "ipad")
        let result = try await manager.subscribe(docId: "doc", deviceId: "mac",
                                                 baseHash: VersionDigest.hex(of: v1), wantBase: true)
        guard case .subscribed(_, _, .inline(let payload), let baseHash, let kind) = result.snapshot else {
            Issue.record("expected a subscribed reply"); return
        }
        #expect(baseHash == VersionDigest.hex(of: v1))
        #expect(kind == SnapshotBundleWire.kind)
        #expect(try SnapshotBundle(encoded: payload).resolvedBase() == v1)
    }

    /// The file's own version (a close push made the file exactly it) wins over the noted base.
    @Test func theFilesOwnVersionWinsOverTheNotedBase() async throws {
        let (manager, _, _) = try setUp()
        try await open(manager)
        let v1 = VersionFixtures.document(marker: "v1"), v2 = VersionFixtures.document(marker: "v2")
        _ = await push(manager, v1, from: "ipad"); _ = await push(manager, v2, from: "ipad")
        let result = try await manager.subscribe(docId: "doc", deviceId: "ipad", baseHash: VersionDigest.hex(of: v1),
                                                 fileHash: VersionDigest.hex(of: v2), wantBase: true)
        guard case .subscribed(_, _, _, let baseHash, _) = result.snapshot else { Issue.record("no reply"); return }
        #expect(baseHash == VersionDigest.hex(of: v2))
    }

    @Test func aBaseTheServerDoesNotHoldMeansNoBase() async throws {
        let (manager, _, _) = try setUp()
        let result = try await manager.subscribe(docId: "doc", deviceId: "ipad",
                                                 baseHash: String(repeating: "d", count: 64), wantBase: true)
        guard case .subscribed(_, _, _, let baseHash, let kind) = result.snapshot else { Issue.record("no reply"); return }
        #expect(baseHash == nil && kind == nil)
    }

    /// A kept version that cannot be rebuilt (a blob gone missing) is answered as one the server
    /// does not keep — whether or not the device asked for its bytes.
    @Test func anUnusableVersionIsNoBase() async throws {
        let (manager, _, dir) = try setUp()
        try await open(manager)
        let v1 = VersionFixtures.document(marker: "v1", images: [(UUID(), VersionFixtures.image(seed: 70))])
        _ = await push(manager, v1, from: "ipad")
        _ = await push(manager, VersionFixtures.document(marker: "v2"), from: "ipad")
        let blobs = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        for name in try FileManager.default.contentsOfDirectory(atPath: blobs.path) {
            try FileManager.default.removeItem(at: blobs.appendingPathComponent(name))
        }
        for wantBase in [true, false] {
            let result = try await manager.subscribe(docId: "doc", deviceId: "mac",
                                                     baseHash: VersionDigest.hex(of: v1), wantBase: wantBase)
            guard case .subscribed(_, _, _, let baseHash, let kind) = result.snapshot else { Issue.record("no reply"); return }
            #expect(baseHash == nil && kind == nil)
        }
    }

    /// Without `wantBase` (the device holds the base live) the server only CONFIRMS it.
    @Test func aLiveBaseIsConfirmedNotSent() async throws {
        let (manager, _, _) = try setUp()
        try await open(manager)
        let v1 = VersionFixtures.document(marker: "v1")
        _ = await push(manager, v1, from: "ipad")
        let result = try await manager.subscribe(docId: "doc", deviceId: "ipad", baseHash: VersionDigest.hex(of: v1))
        guard case .subscribed(_, _, .inline(let payload), let baseHash, let kind) = result.snapshot else { Issue.record("no reply"); return }
        #expect(baseHash == VersionDigest.hex(of: v1) && kind == nil && payload == v1)
    }

    /// Review focus 2. `first` is pushed by NO device, so no transit hold keeps it: only the
    /// device's `base` hold does (the open subscriber's `delivered` hold moves on with every later
    /// write — it is kept alive for exactly that), and moving that hold onto a version the server
    /// no longer keeps releases it. A later subscribe naming it then gets no base — the device
    /// takes a union.
    @Test func baseSavedForAReleasedVersionHoldsNothing() async throws {
        let (manager, versions, _) = try setUp()
        let writer = try await open(manager)
        let first = VersionFixtures.document(marker: "first")
        _ = await push(manager, first, from: nil)
        await noteBase(manager, VersionDigest.hex(of: first), device: "ipad")
        #expect(versions.holds(docId: "doc")["ipad"]?.base == VersionDigest.hex(of: first))
        for i in 0..<12 { _ = await push(manager, VersionFixtures.document(marker: "w\(i)"), from: "mac") }
        #expect(versions.contains(docId: "doc", hash: VersionDigest.hex(of: first)))
        let gone = VersionDigest.hex(of: VersionFixtures.document(marker: "w0"))
        await noteBase(manager, gone, device: "ipad")
        #expect(versions.holds(docId: "doc")["ipad"]?.base == nil)
        #expect(versions.contains(docId: "doc", hash: gone) == false)
        #expect(versions.contains(docId: "doc", hash: VersionDigest.hex(of: first)) == false)

        let later = try await manager.subscribe(docId: "doc", deviceId: "ipad",
                                                baseHash: VersionDigest.hex(of: first), wantBase: true)
        guard case .subscribed(_, _, _, let baseHash, let kind) = later.snapshot else { Issue.record("no reply"); return }
        #expect(baseHash == nil && kind == nil)
        await manager.unsubscribe(docId: "doc", token: writer.token)
        await manager.unsubscribe(docId: "doc", token: later.token)
    }

    /// Review focus 4.
    @Test func baseSavedForAnUnknownDocumentCreatesNothing() async throws {
        let (manager, _, dir) = try setUp()
        await noteBase(manager, String(repeating: "e", count: 64), device: "ipad", docId: "deleted-long-ago")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versions/deleted-long-ago").path) == false)
    }

    @Test func deletingADocumentForgetsItsVersions() async throws {
        let (manager, versions, _) = try setUp()
        try await open(manager)
        _ = await push(manager, VersionFixtures.document(marker: "v1"), from: nil)
        try await manager.deleteDoc(docId: "doc")
        await manager.drainVersionWork(docId: "doc")
        #expect(versions.keptHashes(docId: "doc").isEmpty)
    }

    /// No live session: the manager deletes from the store itself, and the versions go too.
    @Test func deletingAClosedDocumentForgetsItsVersions() async throws {
        let (manager, versions, dir) = try setUp()
        _ = await manager.submitOpeningSession(docId: "doc", createIfMissing: false, opId: "x",
                                               payload: OpPayload(type: "fullDoc", data: VersionFixtures.document(marker: "v1")))
        await manager.drainVersionWork(docId: "doc")
        #expect(!versions.keptHashes(docId: "doc").isEmpty)
        let restarted = SessionManager(store: DirectoryDocumentStore(directory: dir), versions: versions)
        try await restarted.deleteDoc(docId: "doc")
        await restarted.drainVersionWork(docId: "doc")
        #expect(versions.keptHashes(docId: "doc").isEmpty)
    }

    @Test func versionsSurviveAServerRestart() async throws {
        let (manager, _, dir) = try setUp()
        try await open(manager)
        let v1 = VersionFixtures.document(marker: "v1")
        _ = await push(manager, v1, from: "ipad")
        await noteBase(manager, VersionDigest.hex(of: v1), device: "ipad")
        let restarted = SessionManager(store: DirectoryDocumentStore(directory: dir),
                                       versions: DirectoryVersionStore(directory: dir))
        let result = try await restarted.subscribe(docId: "doc", deviceId: "ipad",
                                                   baseHash: VersionDigest.hex(of: v1), wantBase: true)
        guard case .subscribed(_, _, _, let baseHash, _) = result.snapshot else { Issue.record("no reply"); return }
        #expect(baseHash == VersionDigest.hex(of: v1))
    }

    @Test func anAgentWriteIsKeptButHeldForNobody() async throws {
        let (manager, versions, _) = try setUp()
        let v1 = VersionFixtures.document(marker: "agent")
        _ = await manager.submitOpeningSession(docId: "doc", createIfMissing: false, opId: "x",
                                               payload: OpPayload(type: "fullDoc", data: v1))
        await manager.drainVersionWork(docId: "doc")
        #expect(versions.contains(docId: "doc", hash: VersionDigest.hex(of: v1)))
        #expect(versions.holds(docId: "doc").isEmpty)
    }

    /// The version store keys `.versions/<docId>` verbatim, so every door must hand it the
    /// document's ONE spelling — the one the store saved it under — never the caller's.
    @Test func everyDoorKeysVersionsByTheStoredSpelling() async throws {
        let (manager, versions, dir) = try setUp()
        _ = try await manager.subscribe(docId: "DOC", deviceId: "ipad")
        let v1 = VersionFixtures.document(marker: "v1")
        _ = await push(manager, v1, from: "ipad", docId: "Doc")
        await noteBase(manager, VersionDigest.hex(of: v1), device: "ipad", docId: "dOc")
        #expect(versions.contains(docId: "doc", hash: VersionDigest.hex(of: v1)))
        #expect(versions.holds(docId: "doc")["ipad"]?.base == VersionDigest.hex(of: v1))
        let names = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent(DirectoryVersionStore.versionsDirectoryName).path)
        #expect(names == ["doc"])
        let again = try await manager.subscribe(docId: "DOC", deviceId: "mac",
                                                baseHash: VersionDigest.hex(of: v1))
        guard case .subscribed(_, _, _, let baseHash, _) = again.snapshot else { Issue.record("no reply"); return }
        #expect(baseHash == VersionDigest.hex(of: v1))
    }

    // MARK: - fix round 1

    /// Item 2: a `fileHash` whose version lost a blob is skipped, and the intact `baseHash` answers.
    @Test func aDamagedFileVersionFallsBackToTheIntactBase() async throws {
        let (manager, _, dir) = try setUp()
        let writer = try await open(manager)
        let blobs = dir.appendingPathComponent(DirectoryVersionStore.blobsDirectoryName)
        func blobNames() throws -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) ?? [])
        }
        let v1 = VersionFixtures.document(marker: "v1", images: [(UUID(), VersionFixtures.image(seed: 81))])
        let v2 = VersionFixtures.document(marker: "v2", images: [(UUID(), VersionFixtures.image(seed: 82))])
        _ = await push(manager, v1, from: nil)
        let v1Blobs = try blobNames()
        _ = await push(manager, v2, from: nil)
        _ = await push(manager, VersionFixtures.document(marker: "v3"), from: nil)
        #expect(!v1Blobs.isEmpty)
        for name in v1Blobs { try FileManager.default.removeItem(at: blobs.appendingPathComponent(name)) }

        let result = try await manager.subscribe(docId: "doc", deviceId: "mac",
                                                 baseHash: VersionDigest.hex(of: v2),
                                                 fileHash: VersionDigest.hex(of: v1), wantBase: true)
        guard case .subscribed(_, _, .inline(let payload), let baseHash, let kind) = result.snapshot else {
            Issue.record("no reply"); return
        }
        #expect(baseHash == VersionDigest.hex(of: v2) && kind == SnapshotBundleWire.kind)
        #expect(try SnapshotBundle(encoded: payload).resolvedBase() == v2)
        await manager.unsubscribe(docId: "doc", token: writer.token)
        await manager.unsubscribe(docId: "doc", token: result.token)
    }

    /// Item 4: a version store that cannot record does not refuse the write, and a later
    /// `baseSaved` / subscribe naming that version degrades to "no base" (a union), never an error.
    @Test func aFailedRecordStillAcceptsTheWriteAndDegradesToNoBase() async throws {
        let (manager, versions, dir) = try setUp()
        // `.versions` is a FILE, so no document directory can ever be created under it.
        try Data("not a directory".utf8).write(to: dir.appendingPathComponent(DirectoryVersionStore.versionsDirectoryName))
        let writer = try await open(manager)
        let v1 = VersionFixtures.document(marker: "v1")
        #expect(await push(manager, v1, from: "ipad") == .accepted(seq: 1))
        #expect(try DirectoryDocumentStore(directory: dir).load(docId: "doc") == v1)
        await noteBase(manager, VersionDigest.hex(of: v1), device: "ipad")
        #expect(versions.holds(docId: "doc").isEmpty)
        let later = try await manager.subscribe(docId: "doc", deviceId: "ipad",
                                                baseHash: VersionDigest.hex(of: v1), wantBase: true)
        guard case .subscribed(_, _, .inline(let payload), let baseHash, let kind) = later.snapshot else {
            Issue.record("no reply"); return
        }
        #expect(baseHash == nil && kind == nil && payload == v1)
        await manager.unsubscribe(docId: "doc", token: writer.token)
        await manager.unsubscribe(docId: "doc", token: later.token)
    }

    /// Item 1: a delete's `removeAll` runs AFTER every record queued before it, so a record that
    /// has not run yet when the document is deleted can never re-create `.versions/<docId>`.
    @Test func aDeleteRunsAfterEveryQueuedRecord() async throws {
        let (manager, _, dir) = try setUp()
        let writer = try await open(manager)
        await manager.drainVersionWork(docId: "doc")
        let work = try #require(await manager.versionWorkForTesting)
        work.suspend("doc")
        _ = await manager.submit(docId: "doc", opId: "late",
                                 payload: OpPayload(type: "fullDoc", data: VersionFixtures.document(marker: "late")),
                                 holderDeviceId: "ipad")
        try await manager.deleteDoc(docId: "doc")
        work.resume("doc")
        await manager.drainVersionWork(docId: "doc")
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(".versions/doc").path) == false)
        _ = writer
    }
}
