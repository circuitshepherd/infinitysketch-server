import XCTest
import InfSketchWire
@testable import InfSketchServerKit

final class LiveDocIndexTests: XCTestCase {
    private func makeManager() throws -> (SessionManager, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m2c1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionManager(store: DirectoryDocumentStore(directory: dir)), dir)
    }
    private func ad(_ id: String, size: Int = 10, at seconds: TimeInterval = 0,
                    thumb: Data? = Data([1, 2, 3])) -> DocAdvertisement {
        DocAdvertisement(docId: id, modifiedAt: Date(timeIntervalSince1970: seconds),
                         sizeBytes: size, thumbnail: thumb)
    }
    /// One stable connectionId per device string — a device has a single live connection in these
    /// tests. The reconnect-race test uses explicit distinct ids instead.
    private var connIds: [String: UUID] = [:]
    private func conn(_ device: String) -> UUID {
        if let id = connIds[device] { return id }
        let id = UUID(); connIds[device] = id; return id
    }

    func testAdvertisementsPopulateTheIndexAndListAsMetadataOnly() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: conn("devA"), deviceId: "devA")

        let entry = await manager.liveEntry(docId: "Ghost")
        XCTAssertEqual(entry?.holders, ["devA"])
        XCTAssertEqual(entry?.thumbnail, Data([1, 2, 3]))

        let listed = try await manager.listDocuments()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].id, "Ghost")
        XCTAssertFalse(listed[0].hasContent)
    }

    /// Equal devices: two devices advertising the same doc UNION into one entry with both
    /// holders — the second must not overwrite the first (that was M2b's sidecar behavior).
    func testTwoDevicesUnionIntoOneEntryWithBothHolders() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Shared", size: 10, at: 100)], connectionId: conn("devA"), deviceId: "devA")
        await manager.applyAdvertisements([ad("Shared", size: 99, at: 500)], connectionId: conn("devB"), deviceId: "devB")

        let entry = await manager.liveEntry(docId: "Shared")
        XCTAssertEqual(entry?.holders, ["devA", "devB"])
        // Newest modifiedAt wins for the displayed metadata.
        XCTAssertEqual(entry?.modifiedAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(entry?.sizeBytes, 99)
        let listedCount = try await manager.listDocuments().count
        XCTAssertEqual(listedCount, 1)
    }

    /// An OLDER advertisement must not clobber newer displayed metadata, but still adds its holder.
    func testOlderAdvertisementAddsHolderWithoutClobberingMetadata() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Shared", size: 99, at: 500)], connectionId: conn("devB"), deviceId: "devB")
        await manager.applyAdvertisements([ad("Shared", size: 10, at: 100)], connectionId: conn("devA"), deviceId: "devA")

        let entry = await manager.liveEntry(docId: "Shared")
        XCTAssertEqual(entry?.holders, ["devA", "devB"])
        XCTAssertEqual(entry?.sizeBytes, 99)
        XCTAssertEqual(entry?.modifiedAt, Date(timeIntervalSince1970: 500))
    }

    /// Disconnect prunes that device; the entry disappears only when its LAST holder goes.
    func testDisconnectPrunesHolderAndDropsEntryWhenLastHolderLeaves() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Shared")], connectionId: conn("devA"), deviceId: "devA")
        await manager.applyAdvertisements([ad("Shared")], connectionId: conn("devB"), deviceId: "devB")

        await manager.removeConnection(connectionId: conn("devA"), deviceId: "devA")
        let afterFirstRemove = await manager.liveEntry(docId: "Shared")
        XCTAssertEqual(afterFirstRemove?.holders, ["devB"])
        let countAfterFirstRemove = try await manager.listDocuments().count
        XCTAssertEqual(countAfterFirstRemove, 1)

        await manager.removeConnection(connectionId: conn("devB"), deviceId: "devB")
        let afterSecondRemove = await manager.liveEntry(docId: "Shared")
        XCTAssertNil(afterSecondRemove)
        let listedAfterSecondRemove = try await manager.listDocuments()
        XCTAssertTrue(listedAfterSecondRemove.isEmpty)
    }

    /// F2: a reconnect (a fresh connection for the SAME device) races the old socket's close.
    /// Pruning by deviceId alone would let that stale close wipe the live connection's ads. The
    /// device's documents must survive the OLD connection's close and vanish only when the NEW
    /// (last live) connection also closes.
    func testStaleConnectionCloseDoesNotWipeAReconnectedDevice() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = UUID(), new = UUID()
        await manager.applyAdvertisements([ad("MyDoc")], connectionId: old, deviceId: "devA")
        // Reconnect: a NEW connection for the same device advertises, before the old socket closes.
        await manager.applyAdvertisements([ad("MyDoc")], connectionId: new, deviceId: "devA")

        // The stale OLD connection finally closes — must NOT wipe the device.
        await manager.removeConnection(connectionId: old, deviceId: "devA")
        let stillThere = await manager.liveEntry(docId: "MyDoc")
        XCTAssertEqual(stillThere?.holders, ["devA"], "a stale close must not drop the live connection's docs")

        // The live connection closes — now the device really is gone.
        await manager.removeConnection(connectionId: new, deviceId: "devA")
        let gone = await manager.liveEntry(docId: "MyDoc")
        XCTAssertNil(gone)
    }

    /// Content ALWAYS beats metadata: one row, hasContent true, never duplicated.
    func testContentBeatsMetadataInListing() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DirectoryDocumentStore(directory: dir).save(docId: "Real", bytes: Data("hi".utf8))
        await manager.applyAdvertisements([ad("Real"), ad("Ghost")], connectionId: conn("devA"), deviceId: "devA")

        let listed = try await manager.listDocuments().sorted { $0.id < $1.id }
        XCTAssertEqual(listed.map(\.id), ["Ghost", "Real"])
        XCTAssertFalse(listed[0].hasContent)
        XCTAssertTrue(listed[1].hasContent)
    }

    /// A batch REPLACES that device's contribution. A doc it no longer advertises (deleted, or
    /// the user turned `syncEnabled` off) must stop being listed and stop being offered as a
    /// fetch source — accumulating would leave a ghost row pointing at a stale holder.
    func testAdvertisementBatchReplacesThatDevicesPreviousContribution() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Keep"), ad("Dropped")], connectionId: conn("devA"), deviceId: "devA")
        let seeded = await manager.liveEntry(docId: "Dropped")
        XCTAssertNotNil(seeded)

        // devA (same connection) re-advertises WITHOUT "Dropped".
        await manager.applyAdvertisements([ad("Keep")], connectionId: conn("devA"), deviceId: "devA")
        let dropped = await manager.liveEntry(docId: "Dropped")
        XCTAssertNil(dropped, "stale doc must stop being listed")
        let kept = await manager.liveEntry(docId: "Keep")
        XCTAssertEqual(kept?.holders, ["devA"])
    }

    /// Replacing one device's contribution must not disturb another device's holdings.
    func testReplacingOneDevicesBatchLeavesOtherHoldersIntact() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Shared")], connectionId: conn("devA"), deviceId: "devA")
        await manager.applyAdvertisements([ad("Shared")], connectionId: conn("devB"), deviceId: "devB")

        // devA re-advertises nothing at all; devB still holds "Shared".
        await manager.applyAdvertisements([], connectionId: conn("devA"), deviceId: "devA")
        let shared = await manager.liveEntry(docId: "Shared")
        XCTAssertEqual(shared?.holders, ["devB"])
    }

    /// A device that sent no deviceId cannot be routed to for a fetch, so it is not indexed.
    func testAdvertisementWithoutDeviceIdIsIgnored() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: nil)
        let entry = await manager.liveEntry(docId: "Ghost")
        XCTAssertNil(entry)
        let listed = try await manager.listDocuments()
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - Announcing the change (the web page and the app browser both re-list on this)

    /// Collect the status kinds emitted while `body` runs. Deterministic, no sleeps: the emit
    /// yields into a buffered continuation before `unsubscribeStatus` finishes it, and a finished
    /// AsyncStream still delivers what it already holds.
    private func statusKinds(_ manager: SessionManager,
                             during body: () async -> Void) async -> [String] {
        let (events, token) = await manager.subscribeStatus()
        let collector = Task { () -> [String] in
            var kinds: [String] = []
            for await message in events {
                if case .statusEvent(let payload) = message { kinds.append(payload.kind) }
            }
            return kinds
        }
        await body()
        await manager.unsubscribeStatus(token)
        return await collector.value
    }

    /// **The bug this pins.** An advertisement changes what `/api/docs` and `listDocs` return, but
    /// it used to announce NOTHING — so a web page already open, and another device's browser,
    /// kept showing the list from before the device connected. Opening a document was what made
    /// them appear, because the resulting push emits `docUpdated` and everything re-listed then.
    func testAdvertisingAnnouncesTheChangedDocumentSet() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let kinds = await statusKinds(manager) {
            await manager.applyAdvertisements([ad("Ghost")], connectionId: conn("devA"),
                                              deviceId: "devA")
        }
        XCTAssertEqual(kinds, ["docsAdvertised"])
    }

    /// A device re-advertising the SAME set must stay silent. `advertiseLocalDocs` runs on every
    /// connect and on every local file change, and a listener refetches the whole listing for each
    /// event — so announcing a no-op would cost every watcher a round trip for nothing.
    func testReAdvertisingAnIdenticalSetAnnouncesNothing() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: conn("devA"),
                                          deviceId: "devA")

        let kinds = await statusKinds(manager) {
            await manager.applyAdvertisements([ad("Ghost")], connectionId: conn("devA"),
                                              deviceId: "devA")
        }
        XCTAssertEqual(kinds, [])
    }

    /// The symmetric half: a device going offline REMOVES its metadata-only rows, and a listener
    /// that is not told keeps offering documents nothing can serve.
    func testADeviceGoingOfflineAnnouncesItsDocumentsLeaving() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: conn("devA"),
                                          deviceId: "devA")

        let kinds = await statusKinds(manager) {
            await manager.removeConnection(connectionId: self.conn("devA"), deviceId: "devA")
        }
        XCTAssertEqual(kinds, ["docsAdvertised"])
    }

    /// A close for a device that held nothing changes no listing, so it announces nothing.
    func testAnEmptyDisconnectAnnouncesNothing() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let kinds = await statusKinds(manager) {
            await manager.removeConnection(connectionId: self.conn("devB"), deviceId: "devB")
        }
        XCTAssertEqual(kinds, [])
    }
}
