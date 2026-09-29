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

    /// A document the server FETCHES from its holder — an agent's read, or a browser watching it —
    /// is stored under its id and must keep the name it was advertised with. Stored without a
    /// label it listed as its id: an agent reaching for it by name got `unknownDoc` or
    /// `sourceNotFound` until the device's next advertisement, and the device's connect prologue
    /// read the id as the document's new name and RENAMED THE USER'S FILE to a UUID (measured
    /// 2026-09-29 by e2e-watcher-frames and e2e-large-op-spec).
    @Test func aDocumentFetchedForAnAgentKeepsItsAdvertisedName() async throws {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        let manager = SessionManager(store: store)
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "ID-7", name: "Held", modifiedAt: Date(), sizeBytes: 1, thumbnail: nil)],
            connectionId: UUID(), deviceId: "ipad")
        await manager.setContentProvider { _, _ in Fixtures.docBytes }
        #expect(await manager.currentBytesOrFetch(docId: "ID-7") == Fixtures.docBytes)
        #expect(store.name(of: "ID-7") == "Held")
        #expect(try await manager.listDocuments().first { $0.id == "ID-7" }?.name == "Held")
        #expect(await manager.resolveDocRef("Held") == .id("ID-7"))
    }

    @Test func aDocumentFetchedForAWatcherKeepsItsAdvertisedName() async throws {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        let manager = SessionManager(store: store)
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "ID-8", name: "Watched", modifiedAt: Date(), sizeBytes: 1, thumbnail: nil)],
            connectionId: UUID(), deviceId: "ipad")
        await manager.setContentProvider { _, _ in Fixtures.docBytes }
        let result = try await manager.watch(docId: "ID-8")
        await manager.unwatch(docId: "ID-8", token: result.token)
        #expect(store.name(of: "ID-8") == "Watched")
        #expect(try await manager.listDocuments().first { $0.id == "ID-8" }?.name == "Watched")
    }

    /// A label the document already has wins over the advertisement, as everywhere else.
    @Test func aFetchDoesNotReplaceAnExistingLabel() async throws {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        try store.setName("Renamed", for: "ID-6")
        let manager = SessionManager(store: store)
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "ID-6", name: "Stale", modifiedAt: Date(), sizeBytes: 1, thumbnail: nil)],
            connectionId: UUID(), deviceId: "ipad")
        await manager.setContentProvider { _, _ in Fixtures.docBytes }
        _ = await manager.currentBytesOrFetch(docId: "ID-6")
        #expect(store.name(of: "ID-6") == "Renamed")
    }

    @Test func aRefResolvesThroughTheManager() async throws {
        let (manager, _) = try manager()
        #expect(await manager.resolveDocRef("Old") == .id("ID-1"))
        #expect(await manager.resolveDocRef("id-1") == .id("ID-1"))
    }

    /// A rename of an ADVERTISED-ONLY document is the label, and a later advertisement under the
    /// device's old name does not take it back — a device offline across the rename, or one holding
    /// a locally suffixed copy, re-advertises its own stem every time it connects.
    @Test func aReAdvertisementDoesNotRevertARename() async throws {
        let (manager, _) = try manager()
        let ad = { (date: Date) in
            DocAdvertisement(docId: "ID-9", name: "Plan", modifiedAt: date, sizeBytes: 1, thumbnail: nil)
        }
        await manager.applyAdvertisements([ad(Date(timeIntervalSinceNow: -60))], connectionId: UUID(), deviceId: "ipad")
        try await manager.renameDoc(docId: "ID-9", name: "Budget")
        await manager.applyAdvertisements([ad(Date())], connectionId: UUID(), deviceId: "iphone")
        #expect(try await manager.listDocuments().first { $0.id == "ID-9" }?.name == "Budget")
        #expect(await manager.liveEntry(docId: "ID-9")?.name == "Budget")
    }

    @Test func aWhitespaceOnlyNameIsRefused() async throws {
        let (manager, store) = try manager()
        await #expect(throws: DocumentStoreError.invalidDocId) { try await manager.renameDoc(docId: "ID-1", name: "  \n ") }
        #expect(store.name(of: "ID-1") == "Old")
    }

    @Test func aRenameIsTrimmedAndEchoedTrimmed() async throws {
        let (manager, store) = try manager()
        let (events, _) = await manager.subscribeStatus()
        try await manager.renameDoc(docId: "ID-1", name: "  X ")
        #expect(store.name(of: "ID-1") == "X")
        for await event in events {
            if case .docRenamed(_, let name) = event { #expect(name == "X"); break }
        }
    }

    /// The label restore reaches the stored document even when the device advertises its id in
    /// another letter case.
    @Test func anAdvertisementRestoresALostLabelInAnyLetterCase() async throws {
        let store = DirectoryDocumentStore(directory: try VersionFixtures.temporaryDirectory())
        try store.save(docId: "ID-5", bytes: Fixtures.docBytes)
        let manager = SessionManager(store: store)
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "id-5", name: "Recovered", modifiedAt: Date(), sizeBytes: 1, thumbnail: nil)],
            connectionId: UUID(), deviceId: "ipad")
        #expect(store.name(of: "ID-5") == "Recovered")
        #expect(store.name(of: "id-5") == "Recovered")
    }

    /// Deleting an ADVERTISED-ONLY document drops its label too: a label outranks every later
    /// advertisement, so a leftover one would name a re-created document with the deleted one's name.
    @Test func deletingAnAdvertisedOnlyDocumentDropsItsLabel() async throws {
        let (manager, store) = try manager()
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "ID-9", name: "Plan", modifiedAt: Date(), sizeBytes: 1, thumbnail: nil)],
            connectionId: UUID(), deviceId: "ipad")
        try await manager.renameDoc(docId: "ID-9", name: "Budget")
        #expect(store.name(of: "ID-9") == "Budget")
        try await manager.deleteDoc(docId: "ID-9")
        #expect(store.name(of: "ID-9") == nil)
    }
}
