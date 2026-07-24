import XCTest
import InfSketchWire
@testable import InfSketchServerKit

/// M2c-1 review deferrals F5 + F9, the two fetch-path hardening items that are
/// self-contained (see the file-level note at the bottom for why F4 is NOT here).
///
/// F5 — the post-fetch re-check must consult the STORE, not just the live session.
///      `currentBytesOrFetch` suspends across a device round trip; a concurrent
///      promotion (another `currentBytesOrFetch`, or a session that wrote and then
///      grace-tore-down) leaves bytes on DISK with NO session behind them, so a
///      session-only re-check misses it and the stale fetch overwrites the newer
///      content.
/// F9 — `fetchFromHolders` tries holders sequentially, each attempt bounded only by
///      the broker's own per-request timeout (`strokeOpTimeout`, 20 s). With N stale
///      holders one tool call could burn N x 20 s. A total budget caps it.
final class FetchPathHardeningTests: XCTestCase {
    private func makeManager(config: SessionConfig = SessionConfig()) throws -> (SessionManager, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fetch-hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionManager(store: DirectoryDocumentStore(directory: dir), config: config), dir)
    }

    private func ad(_ id: String) -> DocAdvertisement {
        DocAdvertisement(docId: id, modifiedAt: Date(timeIntervalSince1970: 0), sizeBytes: 3, thumbnail: nil)
    }

    /// A one-shot gate (same idiom as `CurrentBytesOrFetchTests`): the provider blocks until the
    /// test opens it, so a competing write can be landed mid-fetch deterministically.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    private actor Counter {
        private(set) var n = 0
        func bump() { n += 1 }
    }

    // MARK: - F5: the post-fetch re-check must see a store-only promotion

    /// The sibling of `CurrentBytesOrFetchTests.testFetchDoesNotRevertAConcurrentlyOpenedSessionsWrite`,
    /// for the case that test could NOT catch: the competing writer leaves NO session behind.
    /// `currentBytesOrFetch` promotes by writing straight to the store (it opens no session), and a
    /// session that wrote and then grace-tore-down is the same observable state — bytes on disk,
    /// `sessions[docId] == nil`. A session-only re-check sees nothing and clobbers them.
    func testFetchDoesNotRevertAConcurrentStoreOnlyPromotion() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryDocumentStore(directory: dir)
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")

        let gate = Gate()
        await manager.setContentProvider { _, _ in
            await gate.wait()           // hold the fetch open…
            return Data("V1".utf8)      // …then resume with STALE bytes
        }

        // 1. Start the fetch; it blocks in the provider.
        let fetchTask = Task { await manager.currentBytesOrFetch(docId: "Ghost") }
        try await Task.sleep(for: .milliseconds(60))

        // 2. While it is held, a concurrent promotion lands V2 on DISK with no session behind it.
        try store.save(docId: "Ghost", bytes: Data("V2".utf8))
        let liveSessions = await manager.liveInfo()
        XCTAssertNil(liveSessions["Ghost"],
                     "precondition: the promotion left no session, so a session-only re-check is blind to it")

        // 3. Release. The stale V1 must not clobber the newer durable V2.
        await gate.open()
        let got = await fetchTask.value
        XCTAssertEqual(got, Data("V2".utf8), "must return the durable bytes, not the stale fetch")
        XCTAssertEqual(try store.load(docId: "Ghost"), Data("V2".utf8), "must NOT revert disk to V1")
    }

    // MARK: - F9: a total fetch budget across holders

    /// Six holders, each attempt costing more than a third of the budget: the loop must STOP
    /// starting new attempts once the budget is spent instead of walking all six. Asserted by
    /// counting provider invocations (deterministic in direction), not by wall-clock.
    func testTotalBudgetStopsTryingFurtherHoldersAndFails() async throws {
        let (manager, dir) = try makeManager(config: SessionConfig(fetchTotalTimeout: .milliseconds(250)))
        defer { try? FileManager.default.removeItem(at: dir) }
        let holders = ["devA", "devB", "devC", "devD", "devE", "devF"]
        for holder in holders {
            await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: holder)
        }
        let attempts = Counter()
        await manager.setContentProvider { _, _ in
            await attempts.bump()
            try await Task.sleep(for: .milliseconds(150))   // each holder is slow but not hung
            throw DocumentStoreError.notFound               // …and ultimately useless
        }

        let got = await manager.currentBytesOrFetch(docId: "Ghost")

        XCTAssertNil(got, "every holder failed, so the fetch fails")
        let n = await attempts.n
        XCTAssertLessThan(n, holders.count,
                          "the budget must stop the walk early; tried \(n) of \(holders.count) holders")
        XCTAssertGreaterThanOrEqual(n, 1, "it must still try at least one holder")
        XCTAssertFalse(try DirectoryDocumentStore(directory: dir).exists(docId: "Ghost"),
                       "a failed fetch persists nothing")
    }

    /// No-regression: the budget must not break an ordinary fetch that completes inside it.
    func testAnOrdinaryFetchStillSucceedsWithinTheBudget() async throws {
        let (manager, dir) = try makeManager(config: SessionConfig(fetchTotalTimeout: .seconds(30)))
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")
        await manager.setContentProvider { _, _ in Data("PULLED".utf8) }

        let got = await manager.currentBytesOrFetch(docId: "Ghost")

        XCTAssertEqual(got, Data("PULLED".utf8))
        XCTAssertEqual(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"), Data("PULLED".utf8),
                       "a successful fetch still promotes the doc to ordinary content")
    }

    /// The budget is per fetch CALL, not a global one-shot: a doc that failed a fetch earlier can
    /// still be fetched later (the deadline must be computed fresh, never stored on the entry).
    func testTheBudgetIsPerCallSoALaterFetchStillWorks() async throws {
        let (manager, dir) = try makeManager(config: SessionConfig(fetchTotalTimeout: .milliseconds(200)))
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")

        // First call: the holder is slow and fails, burning the budget.
        await manager.setContentProvider { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            throw DocumentStoreError.notFound
        }
        let first = await manager.currentBytesOrFetch(docId: "Ghost")
        XCTAssertNil(first)

        // Second call: the holder is healthy now — a fresh budget must let it through.
        await manager.setContentProvider { _, _ in Data("PULLED".utf8) }
        let second = await manager.currentBytesOrFetch(docId: "Ghost")
        XCTAssertEqual(second, Data("PULLED".utf8))
    }
}
