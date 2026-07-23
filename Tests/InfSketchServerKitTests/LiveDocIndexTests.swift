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

    /// A leftover M2b sidecar on disk (metadata, no content) must NOT be reported as having
    /// content — a subscribe would fail — and must NOT shadow the live index's fresher entry
    /// for the same docId. The live index is the sole source of metadata now.
    func testLeftoverSidecarNeitherMislabelsNorShadowsTheLiveEntry() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Simulate an M2b-era sidecar for a doc the server holds no bytes for.
        try DirectoryDocumentStore(directory: dir).saveMetadata(
            docId: "Stale",
            DocMetadataEntry(name: "Stale", sizeBytes: 1, modifiedAt: Date(timeIntervalSince1970: 0),
                             originDeviceId: "devOLD", thumbnail: nil))
        // A currently-connected device advertises the same doc.
        await manager.applyAdvertisements([ad("Stale", size: 42, at: 900)], deviceId: "devNEW")

        let listed = try await manager.listDocuments().filter { $0.id == "Stale" }
        XCTAssertEqual(listed.count, 1, "the sidecar must not produce a second row")
        XCTAssertFalse(listed[0].hasContent, "no bytes on disk — must not claim content")
        XCTAssertEqual(listed[0].sizeBytes, 42, "the LIVE entry wins, not the stale sidecar")
    }
}
