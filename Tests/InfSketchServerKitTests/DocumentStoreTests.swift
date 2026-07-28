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

    // MARK: - docId case (2026-07-28 usage-session finding 2)

    /// A docId used to resolve straight to `<docId>.infsketch`, so lookup inherited the HOST
    /// filesystem's case rules: on macOS (APFS, case-insensitive by default) `RAINFALL` found
    /// `Rainfall`, and on Linux it did not. This server is cross-platform on purpose, so an
    /// agent's calls must not behave differently on the development machine and a deployment.
    @Test(arguments: ["RAINFALL", "rainfall", "RaInFaLl"])
    func aDocIdResolvesRegardlessOfCase(spelling: String) throws {
        let (store, _) = try makeTempStore()
        try store.save(docId: "Rainfall", bytes: Fixtures.docBytes)

        #expect(try store.exists(docId: spelling))
        #expect(try store.load(docId: spelling) == Fixtures.docBytes)
    }

    /// …and a save through a different spelling updates THAT document rather than creating a
    /// second one beside it — which is what a case-sensitive filesystem would otherwise do.
    @Test func savingUnderADifferentCaseUpdatesTheSameDocument() throws {
        let (store, _) = try makeTempStore()
        try store.save(docId: "Rainfall", bytes: Fixtures.docBytes)
        try store.save(docId: "RAINFALL", bytes: Data([9, 9, 9]))

        #expect(try store.list().map(\.docId) == ["Rainfall"])   // still one document…
        #expect(try store.load(docId: "Rainfall") == Data([9, 9, 9]))  // …and it took the write
    }

    /// The exact spelling still wins when it exists, so two documents that genuinely differ only
    /// by case (possible on a case-sensitive filesystem) each keep their own bytes.
    @Test func anExactMatchIsPreferredOverACaseVariant() throws {
        let (store, directory) = try makeTempStore()
        // Written through the filesystem directly: `save` would resolve the second onto the first.
        try Data([1]).write(to: directory.appendingPathComponent("Chart.infsketch"))
        try Data([2]).write(to: directory.appendingPathComponent("chart.infsketch"))

        // On a case-INSENSITIVE filesystem these are one file, and there is nothing to tell apart.
        guard (try store.list().count) == 2 else { return }
        #expect(try store.load(docId: "Chart") == Data([1]))
        #expect(try store.load(docId: "chart") == Data([2]))
    }

    /// A docId that matches nothing is still not found — case folding must not turn an unknown
    /// document into some other document that happens to share a prefix or a shape.
    @Test func caseFoldingDoesNotInventAMatch() throws {
        let (store, _) = try makeTempStore()
        try store.save(docId: "Rainfall", bytes: Fixtures.docBytes)
        #expect(try store.exists(docId: "Rainfal") == false)
        #expect(throws: DocumentStoreError.notFound) { _ = try store.load(docId: "Rainfal") }
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
        for bad in ["../x", "a/b", "a\\b", ""] {
            #expect(throws: DocumentStoreError.invalidDocId) {
                try store.save(docId: bad, bytes: Data())
            }
        }
    }

    @Test func worksWhenDirectoryDoesNotExistYet() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-tests-\(UUID().uuidString)/nested", isDirectory: true)
        let store = DirectoryDocumentStore(directory: dir)
        #expect(try store.list().isEmpty)
        try store.save(docId: "fresh", bytes: Data([1]))
        #expect(try store.load(docId: "fresh") == Data([1]))
    }

    @Test func thumbnailExtraction() {
        let png = ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: Fixtures.docBytes)
        #expect(png == Fixtures.thumbnailPNG)
        #expect(ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: Data(#"{"strokes":[]}"#.utf8)) == nil)
        #expect(ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: Data([0xFF])) == nil)
    }
}
