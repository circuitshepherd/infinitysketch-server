import XCTest
import InfSketchWire
@testable import InfSketchServerKit

/// M2c-1 review deferrals F5 + F9, the two fetch-path hardening items that are self-contained
/// (F4 is NOT here — see the long note at `SessionManager.subscribe`'s `createIfMissing` branch
/// for why closing it needs a design decision rather than a drive-by fix).
///
/// F5 — the post-fetch re-check must consult the STORE, not just the live session. Both fetch
///      call sites suspend across a device round trip, and a concurrent promotion can leave bytes
///      on DISK with NO session behind them (`currentBytesOrFetch` writes straight to the store
///      and opens none; a session that wrote and then grace-tore-down is the same observable
///      state). A session-only re-check is blind to that and the stale fetch overwrites it.
/// F9 — `fetchFromHolders` tries holders sequentially, each attempt bounded only by the broker's
///      own per-request timeout (`strokeOpTimeout`, 20 s). With N stale holders one call could
///      burn N x 20 s. A per-call budget caps the walk.
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

    /// A one-shot gate (the `CurrentBytesOrFetchTests` idiom, plus an entry signal): the provider
    /// blocks until the test opens it, so a competing write lands mid-fetch deterministically.
    /// `waitUntilEntered()` replaces a sleep — without it a too-short sleep degrades the test
    /// silently (the competing write lands BEFORE the fetch starts, so the top-of-function resident
    /// check returns it and the re-check under test is never exercised).
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    private actor Counter {
        private(set) var n = 0
        func bump() { n += 1 }
    }

    // MARK: - F5: both fetch call sites must see a store-only promotion

    /// The sibling of `CurrentBytesOrFetchTests.testFetchDoesNotRevertAConcurrentlyOpenedSessionsWrite`,
    /// for the case that test could NOT catch: the competing writer leaves NO session behind.
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

        // 1. Start the fetch and wait until it is genuinely inside the provider.
        let fetchTask = Task { await manager.currentBytesOrFetch(docId: "Ghost") }
        await gate.waitUntilEntered()

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

    /// The SAME hazard on the other fetch call site — `subscribe`'s notFound branch (review
    /// finding #1). Its re-check also consulted only `sessions[docId]`, so a writer that wrote and
    /// then grace-tore-down lost its content to the resuming fetch. Safety there used to rest on
    /// `gracePeriod` outlasting the fetch, which is a config coupling, not a guarantee.
    func testSubscribeFetchDoesNotRevertAConcurrentStoreOnlyPromotion() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryDocumentStore(directory: dir)
        await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: "devA")

        let gate = Gate()
        await manager.setContentProvider { _, _ in
            await gate.wait()
            return Data("V1".utf8)
        }

        let subscribeTask = Task { try await manager.subscribe(docId: "Ghost") }
        await gate.waitUntilEntered()

        try store.save(docId: "Ghost", bytes: Data("V2".utf8))
        let liveSessions = await manager.liveInfo()
        XCTAssertNil(liveSessions["Ghost"], "precondition: no session behind the durable bytes")

        await gate.open()
        let result = try await subscribeTask.value
        guard case .subscribed(_, _, let snapshot) = result.snapshot,
              case .inline(let bytes) = snapshot else { return XCTFail("expected inline snapshot") }
        XCTAssertEqual(bytes, Data("V2".utf8), "the session must open over the durable bytes, not the stale fetch")
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

    /// The budget must not abort a HEALTHY walk: two holders fail fast, the third answers, and a
    /// generous budget must let the walk reach it. (An off-by-one in the guard — or a budget
    /// applied per attempt rather than per call — breaks this.)
    func testTheBudgetDoesNotAbortAHealthyMultiHolderWalk() async throws {
        let (manager, dir) = try makeManager(config: SessionConfig(fetchTotalTimeout: .seconds(30)))
        defer { try? FileManager.default.removeItem(at: dir) }
        for holder in ["devA", "devB", "devC"] {
            await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: holder)
        }
        let attempts = Counter()
        await manager.setContentProvider { _, deviceId in
            await attempts.bump()
            guard deviceId == "devC" else { throw DocumentStoreError.notFound }   // holders are tried sorted
            return Data("FROM-C".utf8)
        }

        let got = await manager.currentBytesOrFetch(docId: "Ghost")

        XCTAssertEqual(got, Data("FROM-C".utf8), "the walk must reach the healthy holder")
        let n = await attempts.n
        XCTAssertEqual(n, 3, "all three holders are tried in order")
        XCTAssertEqual(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"), Data("FROM-C".utf8),
                       "a successful fetch still promotes the doc to ordinary content")
    }

    /// An exhausted budget surfaces `ContentFetchError.budgetExhausted` through the public
    /// throwing path (`subscribe`), and persists nothing — the one place the distinct error case
    /// is observable, since `currentBytesOrFetch` flattens every failure to nil.
    func testAnExhaustedBudgetSurfacesBudgetExhaustedFromSubscribeAndPersistsNothing() async throws {
        let (manager, dir) = try makeManager(config: SessionConfig(fetchTotalTimeout: .milliseconds(100)))
        defer { try? FileManager.default.removeItem(at: dir) }
        for holder in ["devA", "devB", "devC"] {
            await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: holder)
        }
        // The first attempt starts inside the budget but outlives it, so the SECOND is refused —
        // the failure reported must be the budget, not the first holder's own error.
        await manager.setContentProvider { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            throw DocumentStoreError.notFound
        }

        do {
            _ = try await manager.subscribe(docId: "Ghost")
            XCTFail("expected the subscribe to fail once the budget was spent")
        } catch {
            XCTAssertEqual(error as? ContentFetchError, .budgetExhausted)
        }
        XCTAssertFalse(try DirectoryDocumentStore(directory: dir).exists(docId: "Ghost"),
                       "a budget-exhausted fetch persists nothing")
    }

    /// The budget is per fetch CALL, not a one-shot: a doc whose fetch overran the budget must be
    /// fully retryable later (the deadline must be computed fresh, never stored on the entry).
    /// The first call genuinely OVERRUNS — two 150 ms attempts against a 200 ms budget — so a
    /// stored deadline would already be in the past when the second call runs.
    func testTheBudgetIsPerCallSoALaterFetchStillWorks() async throws {
        let (manager, dir) = try makeManager(config: SessionConfig(fetchTotalTimeout: .milliseconds(200)))
        defer { try? FileManager.default.removeItem(at: dir) }
        for holder in ["devA", "devB", "devC"] {
            await manager.applyAdvertisements([ad("Ghost")], connectionId: UUID(), deviceId: holder)
        }

        // First call: slow, useless holders burn past the budget.
        await manager.setContentProvider { _, _ in
            try await Task.sleep(for: .milliseconds(150))
            throw DocumentStoreError.notFound
        }
        let first = await manager.currentBytesOrFetch(docId: "Ghost")
        XCTAssertNil(first)

        // Second call: a healthy holder — a FRESH budget must let it through.
        await manager.setContentProvider { _, _ in Data("PULLED".utf8) }
        let second = await manager.currentBytesOrFetch(docId: "Ghost")
        XCTAssertEqual(second, Data("PULLED".utf8), "a later fetch gets its own budget")
    }
}
