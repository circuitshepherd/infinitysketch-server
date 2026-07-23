import XCTest
@testable import InfSketchServerKit

final class DocumentStoreMetadataTests: XCTestCase {
    private func makeStore() throws -> (DirectoryDocumentStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m2b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DirectoryDocumentStore(directory: dir), dir)
    }
    private func entry(_ name: String) -> DocMetadataEntry {
        DocMetadataEntry(name: name, sizeBytes: 99, modifiedAt: Date(timeIntervalSince1970: 500),
                         originDeviceId: "dev-A", thumbnail: Data([9, 9, 9]))
    }

    func testMetadataOnlyDocIsListedWithoutContent() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveMetadata(docId: "Ghost", entry("Ghost"))

        let listed = try store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].docId, "Ghost")
        XCTAssertFalse(listed[0].hasContent)
        XCTAssertEqual(listed[0].originDeviceId, "dev-A")
        // There are no bytes to load — M2c is what will change this.
        XCTAssertThrowsError(try store.load(docId: "Ghost"))
    }

    /// Content ALWAYS beats metadata: a sidecar for a docId that has bytes must not shadow it,
    /// must not duplicate the row, and must not be deleted (it survives for later).
    func testContentBeatsMetadata() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(docId: "Real", bytes: Data("hello".utf8))
        try store.saveMetadata(docId: "Real", entry("Real"))

        let listed = try store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(listed[0].hasContent)
        XCTAssertEqual(try store.load(docId: "Real"), Data("hello".utf8))
        XCTAssertNotNil(try store.loadMetadata(docId: "Real"))   // kept, just not listed
    }

    func testMetadataRoundTripsIncludingThumbnail() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveMetadata(docId: "Thumb", entry("Thumb"))
        XCTAssertEqual(try store.loadMetadata(docId: "Thumb"), entry("Thumb"))
        XCTAssertNil(try store.loadMetadata(docId: "Absent"))
    }

    func testReAdvertisingRefreshesTheEntry() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveMetadata(docId: "Foo", entry("Foo"))
        var updated = entry("Foo"); updated.sizeBytes = 1234
        try store.saveMetadata(docId: "Foo", updated)
        XCTAssertEqual(try store.loadMetadata(docId: "Foo")?.sizeBytes, 1234)
        XCTAssertEqual(try store.list().count, 1)
    }
}
