import Foundation
import Testing
import InfSketchWire
@testable import InfSketchServerKit

/// A listing runs on the `SessionManager` actor, so its cost is paid by every other document's
/// ops. It used to ask the store for each document's name, and every such lookup listed the whole
/// folder again — O(N²) directory reads for one `listDocs`, and the same again for every
/// advertisement a device sends on connect. These count the folder enumerations instead of timing
/// them, so the test is exact on any machine.
@Suite struct ListingCostTests {
    private static let count = 40

    private func makeStore() throws -> (DirectoryDocumentStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("listing-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        for n in 0..<Self.count {
            let id = UUID().uuidString
            try store.save(docId: id, bytes: Data(#"{"documentId":"\#(id)"}"#.utf8))
            // Half labelled, half not: the unlabelled half is what used to take the slow path.
            if n.isMultiple(of: 2) { try store.setName("Doc \(n)", for: id) }
        }
        return (store, dir)
    }

    @Test func aListingEnumeratesTheFolderAConstantNumberOfTimes() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SessionManager(store: store)
        let before = store.directoryListings.count
        let listed = try await manager.listDocuments()
        #expect(listed.count == Self.count)
        #expect(store.directoryListings.count - before <= 2,
                "one listing, not one per document (\(store.directoryListings.count - before))")
    }

    @Test func anAdvertisementBatchEnumeratesTheFolderAConstantNumberOfTimes() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SessionManager(store: store)
        let stored = try store.list()
        // Every stored document, in another letter case, plus as many the server does not hold.
        let ads = stored.map { DocAdvertisement(docId: $0.docId.lowercased(), name: "Adv \($0.docId.prefix(4))",
                                                modifiedAt: Date(), sizeBytes: 1, thumbnail: nil) }
            + (0..<Self.count).map { _ in DocAdvertisement(docId: UUID().uuidString, name: "Remote",
                                                           modifiedAt: Date(), sizeBytes: 1, thumbnail: nil) }
        let before = store.directoryListings.count
        await manager.applyAdvertisements(ads, connectionId: UUID(), deviceId: "devA")
        #expect(store.directoryListings.count - before <= 2,
                "one listing per batch, not one per advertisement (\(store.directoryListings.count - before))")
        // …and the unlabelled stored documents still took the advertised name, under their stored spelling.
        for info in stored where !info.labelled {
            #expect(store.name(of: info.docId) == "Adv \(info.docId.prefix(4))")
        }
    }

    @Test func aNameLookupNeedsNoListing() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let labelled = try store.list().first { $0.labelled }!
        let before = store.directoryListings.count
        #expect(store.name(of: labelled.docId) == labelled.name)
        #expect(store.name(of: labelled.docId.lowercased()) == labelled.name, "folded in memory")
        #expect(store.name(of: UUID().uuidString) == nil)
        #expect(store.directoryListings.count == before)
    }
}
