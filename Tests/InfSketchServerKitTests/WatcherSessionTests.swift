import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct WatcherSessionTests {
    private func makeManager(withDoc: Bool = true) throws -> (DirectoryDocumentStore, SessionManager) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        if withDoc { try store.save(docId: "d", bytes: Fixtures.docBytes) }
        return (store, SessionManager(store: store, config: SessionConfig(gracePeriod: .milliseconds(50))))
    }

    @Test func watchUnknownDocThrows() async throws {
        let (_, manager) = try makeManager(withDoc: false)
        await #expect(throws: (any Error).self) { _ = try await manager.watch(docId: "ghost") }
    }

    @Test func watcherCountChangesNotifySubscribers() async throws {
        let (_, manager) = try makeManager()
        let sub = try await manager.subscribe(docId: "d")
        var it = sub.events.makeAsyncIterator()
        let watch = try await manager.watch(docId: "d")
        #expect(await it.next() == .watchers(docId: "d", count: 1, framePx: nil))
        await manager.unwatch(docId: "d", token: watch.token)
        #expect(await it.next() == .watchers(docId: "d", count: 0, framePx: nil))
    }

    @Test func lateSubscriberLearnsExistingWatchers() async throws {
        let (_, manager) = try makeManager()
        _ = try await manager.watch(docId: "d")
        let sub = try await manager.subscribe(docId: "d")
        var it = sub.events.makeAsyncIterator()
        // First event on a fresh subscription to an already-watched doc:
        #expect(await it.next() == .watchers(docId: "d", count: 1, framePx: nil))
    }

    @Test func frameGoesToWatchersOnlyAndIsCached() async throws {
        let (_, manager) = try makeManager()
        let sub = try await manager.subscribe(docId: "d")
        let watch = try await manager.watch(docId: "d")
        var subIt = sub.events.makeAsyncIterator()
        _ = await subIt.next()   // watchers(count:1)
        var watchIt = watch.events.makeAsyncIterator()

        let accepted = await manager.submitFrame(docId: "d", bytes: Data([9, 9]), canvasRect: [1, 2, 30, 40])
        #expect(accepted)
        #expect(await watchIt.next() == .frameAvailable(docId: "d", seq: 0))
        let cached = await manager.latestFrame(docId: "d")
        #expect(cached?.png == Data([9, 9]))
        #expect(cached?.seq == 0)
        #expect(cached?.canvasRect == [1, 2, 30, 40])
        // Frames are ephemeral: the subscriber saw no event and seq did not move.
        #expect(await manager.liveInfo()["d"]?.seq == 0)
    }

    /// A rect a viewer could not divide by is dropped at submission, so both read paths
    /// see the one state the browser has a defined behaviour for: absent. A zero width
    /// arriving intact would put NaN into the page's transform.
    @Test func aRectAViewerCannotUseIsNotCached() async throws {
        for bad: [Double]? in [[0, 0, 0, 100], [0, 0, 100, 0], [1, 2, 3], nil,
                               [0, 0, .infinity, 100], [0, 0, .nan, 100]] {
            let (_, manager) = try makeManager()
            _ = try await manager.subscribe(docId: "d", createIfMissing: true)
            #expect(await manager.submitFrame(docId: "d", bytes: Data([1]), canvasRect: bad))
            #expect(await manager.latestFrame(docId: "d")?.canvasRect == nil)
        }
    }

    @Test func submitFrameWithoutSessionReturnsFalse() async throws {
        let (_, manager) = try makeManager()
        #expect(await manager.submitFrame(docId: "d", bytes: Data([1]), canvasRect: nil) == false)
    }

    @Test func watchersHoldTheSessionOpen() async throws {
        let (_, manager) = try makeManager()
        let sub = try await manager.subscribe(docId: "d")
        let watch = try await manager.watch(docId: "d")
        await manager.unsubscribe(docId: "d", token: sub.token)
        // Watcher still present: session must survive the (50 ms) grace period.
        // Waiting longer only strengthens this half — the watcher suppresses
        // teardown outright, so no amount of delay can reap it.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await manager.liveInfo()["d"] != nil)
        await manager.unwatch(docId: "d", token: watch.token)
        // Now both are zero: session tears down after grace.
        await waitFor { await manager.liveInfo()["d"] == nil }
        #expect(await manager.liveInfo()["d"] == nil)
    }

    @Test func theFramePxIsTheMaxOverWatchersAndFallsBackWhenOneLeaves() async throws {
        let (_, manager) = try makeManager()
        let sub = try await manager.subscribe(docId: "d")
        var it = sub.events.makeAsyncIterator()
        let small = try await manager.watch(docId: "d", framePx: 1024)
        #expect(await it.next() == .watchers(docId: "d", count: 1, framePx: 1024))
        let big = try await manager.watch(docId: "d", framePx: 2048)
        #expect(await it.next() == .watchers(docId: "d", count: 2, framePx: 2048))
        await manager.unwatch(docId: "d", token: big.token)
        #expect(await it.next() == .watchers(docId: "d", count: 1, framePx: 1024))
        await manager.unwatch(docId: "d", token: small.token)
        #expect(await it.next() == .watchers(docId: "d", count: 0, framePx: nil))
    }

    @Test func aRequestAboveTheCapIsCappedAndANonPositiveOneMeansNoPreference() async throws {
        let (_, manager) = try makeManager()
        let sub = try await manager.subscribe(docId: "d")
        var it = sub.events.makeAsyncIterator()
        _ = try await manager.watch(docId: "d", framePx: 4096)
        #expect(await it.next() == .watchers(docId: "d", count: 1, framePx: 2048))
        _ = try await manager.watch(docId: "d", framePx: 0)
        #expect(await it.next() == .watchers(docId: "d", count: 2, framePx: 2048))
    }

    @Test func aWatcherWithNoPreferenceLeavesFramePxNil() async throws {
        let (_, manager) = try makeManager()
        let sub = try await manager.subscribe(docId: "d")
        var it = sub.events.makeAsyncIterator()
        _ = try await manager.watch(docId: "d")
        #expect(await it.next() == .watchers(docId: "d", count: 1, framePx: nil))
    }
}
