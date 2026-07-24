import XCTest
import InfSketchWire
@testable import InfSketchServerKit

final class CurrentBytesOrFetchTests: XCTestCase {
    private func makeManager() throws -> (SessionManager, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m2c3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionManager(store: DirectoryDocumentStore(directory: dir)), dir)
    }
    private func ad(_ id: String) -> DocAdvertisement {
        DocAdvertisement(docId: id, modifiedAt: Date(timeIntervalSince1970: 0), sizeBytes: 3, thumbnail: nil)
    }

    /// Resident content is returned without any fetch.
    func testResidentBytesReturnedWithoutFetching() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        try DirectoryDocumentStore(directory: dir).save(docId: "Real", bytes: Data("hi".utf8))
        await manager.setContentProvider { _, _ in XCTFail("must not fetch a resident doc"); return Data() }

        let bytes = await manager.currentBytesOrFetch(docId: "Real")
        XCTAssertEqual(bytes, Data("hi".utf8))
    }

    /// A content-less doc with a holder is FETCHED, PERSISTED (promoted), and returned.
    func testContentLessWithHolderFetchesPersistsAndPromotes() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")
        await manager.setContentProvider { _, _ in Data("PULLED".utf8) }

        let bytes = await manager.currentBytesOrFetch(docId: "Ghost")
        XCTAssertEqual(bytes, Data("PULLED".utf8))
        // Promoted: on disk now, and hasContent:true.
        XCTAssertEqual(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"), Data("PULLED".utf8))
        let hasContent = try await manager.listDocuments().first { $0.id == "Ghost" }!.hasContent
        XCTAssertTrue(hasContent)
    }

    /// A content-less doc with NO holder (not in the live index) returns nil, no provider call.
    func testUnknownDocReturnsNil() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.setContentProvider { _, _ in XCTFail("no holder → no provider call"); return Data() }
        let bytes = await manager.currentBytesOrFetch(docId: "Nope")
        XCTAssertNil(bytes)
    }

    /// A known doc whose only holder fails returns nil and persists nothing.
    func testKnownButHolderFailsReturnsNil() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")
        await manager.setContentProvider { _, _ in throw DeviceCommandBroker.DeviceCommandError.noDeviceAvailable }
        let bytes = await manager.currentBytesOrFetch(docId: "Ghost")
        XCTAssertNil(bytes)
        XCTAssertThrowsError(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"))
    }

    /// Concurrent calls coalesce onto ONE fetch (via inFlightFetches).
    func testConcurrentCallsCoalesceIntoOneFetch() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")
        actor Counter { var n = 0; func bump() { n += 1 } }
        let calls = Counter()
        await manager.setContentProvider { _, _ in
            await calls.bump(); try? await Task.sleep(for: .milliseconds(80)); return Data("ONCE".utf8)
        }
        async let a = manager.currentBytesOrFetch(docId: "Ghost")
        async let b = manager.currentBytesOrFetch(docId: "Ghost")
        _ = await (a, b)
        let n = await calls.n
        XCTAssertEqual(n, 1)
    }
}
