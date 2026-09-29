import Foundation
import Testing
@testable import InfSketchServerKit

@Suite struct DocumentLabelsTests {
    @Test func labelsPersistAndTwoDocumentsMayShareAName() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "A", bytes: Fixtures.docBytes)
        try store.save(docId: "B", bytes: Fixtures.docBytes)
        try store.setName("Chart", for: "A")
        try store.setName("Chart", for: "B")
        let reopened = DirectoryDocumentStore(directory: dir)
        #expect(try reopened.list().map(\.name).sorted() == ["Chart", "Chart"])
        #expect(reopened.name(of: "A") == "Chart")
    }

    @Test func anUnlabelledDocumentIsNamedByItsId() throws {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        try store.save(docId: "A", bytes: Fixtures.docBytes)
        #expect(try store.list().first?.name == "A")
    }

    @Test func deletingADocumentForgetsItsLabel() throws {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        try store.save(docId: "A", bytes: Fixtures.docBytes)
        try store.setName("Chart", for: "A")
        try store.delete(docId: "A")
        #expect(store.name(of: "A") == nil)
    }

    /// The labels file is a dot-file: never listed as a document.
    @Test func theLabelsFileIsNotADocument() throws {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        try store.save(docId: "A", bytes: Fixtures.docBytes)
        try store.setName("Chart", for: "A")
        #expect(try store.list().map(\.docId) == ["A"])
    }

    /// A labels file that cannot be read is KEPT beside the new one rather than overwritten by the
    /// next `set` — the names in it are recoverable by hand, and nothing else records them.
    @Test func anUnreadableLabelsFileIsSetAsideNotOverwritten() throws {
        let dir = try VersionFixtures.temporaryDirectory()
        _ = DirectoryDocumentStore(directory: dir)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: dir.appendingPathComponent(DocumentLabels.fileName))
        let labels = DocumentLabels(directory: dir)
        try labels.set("Chart", for: "A")
        #expect(labels.name(of: "A") == "Chart")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let asides = names.filter { $0.hasPrefix(".names.unreadable-") }
        #expect(asides.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(asides[0])) == garbage)
    }
}
