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

    /// A one-shot gate: the provider blocks on `wait()` until the test calls `open()`, so the test
    /// can land a competing session mid-fetch deterministically.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    /// The race the reviewer caught: while `currentBytesOrFetch` is suspended in the fetch, a
    /// concurrent path opens a session and a write lands (V2). When the stale fetch (V1) resumes it
    /// must NOT overwrite the accepted write on disk — it must adopt the live session's bytes.
    /// Deterministic via the gate: the session is injected WHILE the fetch is held open.
    func testFetchDoesNotRevertAConcurrentlyOpenedSessionsWrite() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryDocumentStore(directory: dir)
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")

        let gate = Gate()
        await manager.setContentProvider { _, _ in
            await gate.wait()          // hold the fetch open until the competing write has landed
            return Data("V1".utf8)     // …then resume with STALE bytes
        }

        // 1. Start the fetch; it blocks in the provider on the gate.
        let fetchTask = Task { await manager.currentBytesOrFetch(docId: "Ghost") }
        try await Task.sleep(for: .milliseconds(60))   // let it reach the provider

        // 2. While the fetch is held, a competing session opens and accepts a write (V2).
        //    `submitOpeningSession` does NOT fetch, so it doesn't coalesce onto the held fetch.
        _ = await manager.submitOpeningSession(
            docId: "Ghost", createIfMissing: true, opId: "u",
            payload: OpPayload(type: "fullDoc", data: Data("V2".utf8)))
        XCTAssertEqual(try store.load(docId: "Ghost"), Data("V2".utf8))   // V2 is on disk

        // 3. Release the fetch. The stale V1 must not clobber V2.
        await gate.open()
        let got = await fetchTask.value
        XCTAssertEqual(got, Data("V2".utf8), "must return the live session's bytes, not the stale fetch")
        XCTAssertEqual(try store.load(docId: "Ghost"), Data("V2".utf8), "must NOT revert disk to V1")
    }
}
