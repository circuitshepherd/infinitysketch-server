import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

/// A device's refetch unsubscribes and resubscribes; the document never leaves its screen. A
/// live-state op arriving in that gap used to find no subscribed connection and be refused
/// `documentNotOpen` (round 6, item 5).
@Suite struct SubscriptionRoutingGraceTests {
    private func makeManager(grace: Duration) throws -> SessionManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-grace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        return SessionManager(store: store, config: SessionConfig(unsubscribeRoutingGrace: grace))
    }

    @Test func aConnectionThatJustUnsubscribedStillCounts() async throws {
        let manager = try makeManager(grace: .seconds(5))
        let connection = UUID()
        let r = try await manager.subscribe(docId: "d", connectionId: connection)
        #expect(await manager.subscribedConnections(docId: "d") == [connection])
        await manager.unsubscribe(docId: "d", token: r.token)
        #expect(await manager.subscribedConnections(docId: "d") == [connection])
    }

    @Test func theGraceEnds() async throws {
        let manager = try makeManager(grace: .milliseconds(50))
        let connection = UUID()
        let r = try await manager.subscribe(docId: "d", connectionId: connection)
        await manager.unsubscribe(docId: "d", token: r.token)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await manager.subscribedConnections(docId: "d").isEmpty)
    }

    @Test func aDeleteEndsTheGrace() async throws {
        let manager = try makeManager(grace: .seconds(5))
        let connection = UUID()
        let r = try await manager.subscribe(docId: "d", connectionId: connection)
        await manager.unsubscribe(docId: "d", token: r.token)
        try await manager.deleteDoc(docId: "d")
        #expect(await manager.subscribedConnections(docId: "d").isEmpty)
    }
}
