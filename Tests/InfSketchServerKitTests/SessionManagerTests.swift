import Foundation
import Testing
@testable import InfSketchServerKit

private func makeManager(gracePeriod: Duration = .seconds(60)) throws -> SessionManager {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("manager-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = DirectoryDocumentStore(directory: dir)
    try store.save(docId: "d", bytes: Fixtures.docBytes)
    return SessionManager(store: store, config: SessionConfig(gracePeriod: gracePeriod))
}

@Suite struct SessionManagerTests {
    @Test func subscribeCreatesSessionLazily() async throws {
        let manager = try makeManager()
        #expect(await manager.liveInfo().isEmpty)
        let r = try await manager.subscribe(docId: "d")
        #expect(r.snapshot == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))
        let info = await manager.liveInfo()
        #expect(info["d"] == LiveDocInfo(seq: 0, subscriberCount: 1))
    }

    @Test func subscribeUnknownDocThrows() async throws {
        let manager = try makeManager()
        await #expect(throws: DocumentStoreError.notFound) {
            _ = try await manager.subscribe(docId: "ghost")
        }
    }

    @Test func submitWithoutSessionRejects() async throws {
        let manager = try makeManager()
        let r = await manager.submit(docId: "d", opId: "o", payload: OpPayload(type: "fullDoc", data: Data([1])))
        #expect(r == .reject(docId: "d", opId: "o", reason: "notSubscribed", seq: 0))
    }

    @Test func sessionSurvivesWithinGracePeriodAndTearsDownAfter() async throws {
        let manager = try makeManager(gracePeriod: .milliseconds(50))
        let r = try await manager.subscribe(docId: "d")
        await manager.unsubscribe(docId: "d", token: r.token)
        // Still alive within grace period.
        #expect(await manager.liveInfo()["d"] != nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await manager.liveInfo()["d"] == nil)
    }

    @Test func resubscribeWithinGraceCancelsTeardown() async throws {
        let manager = try makeManager(gracePeriod: .milliseconds(100))
        let r1 = try await manager.subscribe(docId: "d")
        await manager.unsubscribe(docId: "d", token: r1.token)
        _ = try await manager.subscribe(docId: "d")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await manager.liveInfo()["d"] != nil)
    }

    @Test func statusStreamReportsLifecycleAndUpdates() async throws {
        let manager = try makeManager(gracePeriod: .milliseconds(50))
        let (events, _) = await manager.subscribeStatus()
        let r = try await manager.subscribe(docId: "d")
        _ = await manager.submit(docId: "d", opId: "o1", payload: OpPayload(type: "fullDoc", data: Data([9])))
        await manager.unsubscribe(docId: "d", token: r.token)
        try await Task.sleep(for: .milliseconds(300))

        var kinds = [String]()
        for await message in events {
            if case .statusEvent(let p) = message {
                kinds.append(p.kind)
                if p.kind == "sessionClosed" { break }
            }
        }
        #expect(kinds == ["sessionOpened", "subscriberCount", "docUpdated", "subscriberCount", "sessionClosed"])
    }

    @Test func unsubscribeIsIdempotent() async throws {
        let manager = try makeManager()
        let r = try await manager.subscribe(docId: "d")
        await manager.unsubscribe(docId: "d", token: r.token)
        await manager.unsubscribe(docId: "d", token: r.token)  // must not underflow the count
        let r2 = try await manager.subscribe(docId: "d")
        #expect(await manager.liveInfo()["d"]?.subscriberCount == 1)
        _ = r2
    }
}
