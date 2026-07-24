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

    func testAdvertisementsPopulateTheIndexAndListAsMetadataOnly() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], deviceId: "devA")

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
        await manager.applyAdvertisements([ad("Shared", size: 10, at: 100)], deviceId: "devA")
        await manager.applyAdvertisements([ad("Shared", size: 99, at: 500)], deviceId: "devB")

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
        await manager.applyAdvertisements([ad("Shared", size: 99, at: 500)], deviceId: "devB")
        await manager.applyAdvertisements([ad("Shared", size: 10, at: 100)], deviceId: "devA")

        let entry = await manager.liveEntry(docId: "Shared")
        XCTAssertEqual(entry?.holders, ["devA", "devB"])
        XCTAssertEqual(entry?.sizeBytes, 99)
        XCTAssertEqual(entry?.modifiedAt, Date(timeIntervalSince1970: 500))
    }

    /// Disconnect prunes that device; the entry disappears only when its LAST holder goes.
    func testDisconnectPrunesHolderAndDropsEntryWhenLastHolderLeaves() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Shared")], deviceId: "devA")
        await manager.applyAdvertisements([ad("Shared")], deviceId: "devB")

        await manager.removeAdvertisements(deviceId: "devA")
        let afterFirstRemove = await manager.liveEntry(docId: "Shared")
        XCTAssertEqual(afterFirstRemove?.holders, ["devB"])
        let countAfterFirstRemove = try await manager.listDocuments().count
        XCTAssertEqual(countAfterFirstRemove, 1)

        await manager.removeAdvertisements(deviceId: "devB")
        let afterSecondRemove = await manager.liveEntry(docId: "Shared")
        XCTAssertNil(afterSecondRemove)
        let listedAfterSecondRemove = try await manager.listDocuments()
        XCTAssertTrue(listedAfterSecondRemove.isEmpty)
    }

    /// Content ALWAYS beats metadata: one row, hasContent true, never duplicated.
    func testContentBeatsMetadataInListing() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DirectoryDocumentStore(directory: dir).save(docId: "Real", bytes: Data("hi".utf8))
        await manager.applyAdvertisements([ad("Real"), ad("Ghost")], deviceId: "devA")

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
        await manager.applyAdvertisements([ad("Keep"), ad("Dropped")], deviceId: "devA")
        let seeded = await manager.liveEntry(docId: "Dropped")
        XCTAssertNotNil(seeded)

        // devA re-advertises WITHOUT "Dropped".
        await manager.applyAdvertisements([ad("Keep")], deviceId: "devA")
        let dropped = await manager.liveEntry(docId: "Dropped")
        XCTAssertNil(dropped, "stale doc must stop being listed")
        let kept = await manager.liveEntry(docId: "Keep")
        XCTAssertEqual(kept?.holders, ["devA"])
    }

    /// Replacing one device's contribution must not disturb another device's holdings.
    func testReplacingOneDevicesBatchLeavesOtherHoldersIntact() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Shared")], deviceId: "devA")
        await manager.applyAdvertisements([ad("Shared")], deviceId: "devB")

        // devA re-advertises nothing at all; devB still holds "Shared".
        await manager.applyAdvertisements([], deviceId: "devA")
        let shared = await manager.liveEntry(docId: "Shared")
        XCTAssertEqual(shared?.holders, ["devB"])
    }

    /// A device that sent no deviceId cannot be routed to for a fetch, so it is not indexed.
    func testAdvertisementWithoutDeviceIdIsIgnored() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], deviceId: nil)
        let entry = await manager.liveEntry(docId: "Ghost")
        XCTAssertNil(entry)
        let listed = try await manager.listDocuments()
        XCTAssertTrue(listed.isEmpty)
    }
}
