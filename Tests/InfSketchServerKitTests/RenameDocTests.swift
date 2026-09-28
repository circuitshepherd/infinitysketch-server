import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct RenameDocTests {
    private func manager() throws -> (SessionManager, DirectoryDocumentStore) {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        try store.save(docId: "ID-1", bytes: Fixtures.docBytes)
        try store.setName("Old", for: "ID-1")
        return (SessionManager(store: store), store)
    }

    @Test func aRenameChangesTheLabelAndNothingElse() async throws {
        let (manager, store) = try manager()
        try await manager.renameDoc(docId: "ID-1", name: "New")
        #expect(store.name(of: "ID-1") == "New")
        #expect(try store.load(docId: "ID-1") == Fixtures.docBytes)
        #expect(try await manager.listDocuments().map(\.name) == ["New"])
    }

    /// Review focus 3: every status subscriber hears every rename, IN SERVER ORDER — including the
    /// device that sent it. That is what makes two concurrent renames converge.
    @Test func renameIsEchoedToTheSenderToo() async throws {
        let (manager, _) = try manager()
        let (events, _) = await manager.subscribeStatus()
        try await manager.renameDoc(docId: "ID-1", name: "From A")
        try await manager.renameDoc(docId: "ID-1", name: "From B")
        var renames: [String] = []
        for await event in events {
            if case .docRenamed(_, let name) = event { renames.append(name) }
            if renames.count == 2 { break }
        }
        #expect(renames == ["From A", "From B"])
    }

    @Test func renamingAnUnknownDocumentThrows() async throws {
        let (manager, _) = try manager()
        await #expect(throws: DocumentStoreError.notFound) { try await manager.renameDoc(docId: "ghost", name: "X") }
    }

    @Test func aCreatingSubscribeLabelsTheDocument() async throws {
        let (manager, store) = try manager()
        let result = try await manager.subscribe(docId: "ID-2", createIfMissing: true, name: "Fresh")
        await manager.unsubscribe(docId: "ID-2", token: result.token)
        #expect(store.name(of: "ID-2") == "Fresh")
    }

    @Test func anAdvertisementNamesItsDocument() async throws {
        let (manager, _) = try manager()
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "ID-9", name: "On the iPad", modifiedAt: Date(), sizeBytes: 1, thumbnail: nil)],
            connectionId: UUID(), deviceId: "ipad")
        #expect(try await manager.listDocuments().first { $0.id == "ID-9" }?.name == "On the iPad")
    }

    /// `.names.json` lost: the next advertisement restores the label of a STORED document.
    @Test func anAdvertisementRestoresALostLabel() async throws {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        try store.save(docId: "ID-5", bytes: Fixtures.docBytes)
        let manager = SessionManager(store: store)
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "ID-5", name: "Recovered", modifiedAt: Date(), sizeBytes: 1, thumbnail: nil)],
            connectionId: UUID(), deviceId: "ipad")
        #expect(store.name(of: "ID-5") == "Recovered")
    }

    @Test func aRefResolvesThroughTheManager() async throws {
        let (manager, _) = try manager()
        #expect(await manager.resolveDocRef("Old") == .id("ID-1"))
        #expect(await manager.resolveDocRef("id-1") == .id("ID-1"))
    }
}
