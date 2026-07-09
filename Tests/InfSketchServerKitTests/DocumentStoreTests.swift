import Foundation
import Testing
@testable import InfSketchServerKit

private func makeTempStore() throws -> (DirectoryDocumentStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (DirectoryDocumentStore(directory: dir), dir)
}

@Suite struct DocumentStoreTests {
    @Test func saveLoadRoundTrip() throws {
        let (store, _) = try makeTempStore()
        try store.save(docId: "doc1", bytes: Fixtures.docBytes)
        let loaded = try store.load(docId: "doc1")
        #expect(loaded == Fixtures.docBytes)
    }

    @Test func listReflectsSavedDocs() throws {
        let (store, _) = try makeTempStore()
        try store.save(docId: "b", bytes: Data([1]))
        try store.save(docId: "a", bytes: Data([2, 3]))
        let infos = try store.list().sorted { $0.docId < $1.docId }
        #expect(infos.map(\.docId) == ["a", "b"])
        #expect(infos[0].sizeBytes == 2)
        #expect(infos[0].name == "a")
    }

    @Test func loadMissingThrowsNotFound() throws {
        let (store, _) = try makeTempStore()
        #expect(throws: DocumentStoreError.notFound) {
            _ = try store.load(docId: "nope")
        }
    }

    @Test func pathTraversalRejected() throws {
        let (store, _) = try makeTempStore()
        for bad in ["../x", "a/b", "a\\b", ""] {
            #expect(throws: DocumentStoreError.invalidDocId) {
                _ = try store.load(docId: bad)
            }
        }
    }

    @Test func thumbnailExtraction() {
        let png = ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: Fixtures.docBytes)
        #expect(png == Fixtures.thumbnailPNG)
        #expect(ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: Data(#"{"strokes":[]}"#.utf8)) == nil)
        #expect(ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: Data([0xFF])) == nil)
    }
}
