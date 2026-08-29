import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

/// A browser watching a document nobody has open used to get the cached frame if one survived and
/// then the 256 px thumbnail stored in the file — although any connected app can render the bytes,
/// which `render_sketch` proves on every call. The manager now asks an injected frame provider
/// (`InfSketchServer` routes it to the device broker) whenever a document has WATCHERS and NO
/// SUBSCRIBER; a subscriber renders its own frames and the relay stays out of its way.
@Suite struct WatcherFrameRelayTests {
    private func makeManager() throws -> SessionManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-frame-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        return SessionManager(store: store, config: SessionConfig(gracePeriod: .milliseconds(50)))
    }

    /// Records what the provider was asked, so a test can assert on the CALL and not only on
    /// the frame that came back.
    private actor Calls {
        struct Call: Equatable { let docId: String; let bytes: Data; let px: Int? }
        private(set) var all: [Call] = []
        func record(_ docId: String, _ bytes: Data, _ px: Int?) { all.append(Call(docId: docId, bytes: bytes, px: px)) }
    }

    @Test func watchingAnUnopenedDocumentAsksTheProviderAndCachesItsFrame() async throws {
        let manager = try makeManager()
        let calls = Calls()
        await manager.setFrameProvider { docId, bytes, px in
            await calls.record(docId, bytes, px)
            return (png: Data([4, 2]), canvasRect: [0, 0, 10, 10])
        }
        let watch = try await manager.watch(docId: "d", framePx: 2048)
        var it = watch.events.makeAsyncIterator()
        #expect(await it.next() == .frameAvailable(docId: "d", seq: 0))
        let cached = await manager.latestFrame(docId: "d")
        #expect(cached?.png == Data([4, 2]))
        #expect(cached?.canvasRect == [0, 0, 10, 10])
        let asked = await calls.all
        #expect(asked == [.init(docId: "d", bytes: Fixtures.docBytes, px: 2048)])
    }

    @Test func aSubscribedDocumentIsLeftToItsDevice() async throws {
        let manager = try makeManager()
        await manager.setFrameProvider { _, _, _ in
            Issue.record("the relay must not render for a document a device has open")
            return (png: Data(), canvasRect: nil)
        }
        _ = try await manager.subscribe(docId: "d")
        _ = try await manager.watch(docId: "d")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.latestFrame(docId: "d") == nil)
    }

    @Test func withoutAProviderNothingChanges() async throws {
        let manager = try makeManager()
        _ = try await manager.watch(docId: "d")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.latestFrame(docId: "d") == nil)
    }

    @Test func aWriteToAWatchedUnopenedDocumentRendersAgain() async throws {
        let manager = try makeManager()
        let calls = Calls()
        await manager.setFrameProvider { docId, bytes, px in
            await calls.record(docId, bytes, px)
            return (png: bytes, canvasRect: nil)   // echo the bytes so the frame says what was rendered
        }
        let watch = try await manager.watch(docId: "d")
        var it = watch.events.makeAsyncIterator()
        #expect(await it.next() == .frameAvailable(docId: "d", seq: 0))

        _ = await manager.submitOpeningSession(
            docId: "d", createIfMissing: false, opId: "w",
            payload: OpPayload(type: "fullDoc", data: Data("V2".utf8)))
        #expect(await it.next() == .frameAvailable(docId: "d", seq: 1))
        #expect(await manager.latestFrame(docId: "d")?.png == Data("V2".utf8))
        #expect(await calls.all.count == 2)
    }

    @Test func aCurrentCachedFrameIsNotRenderedTwice() async throws {
        let manager = try makeManager()
        let calls = Calls()
        await manager.setFrameProvider { docId, bytes, px in
            await calls.record(docId, bytes, px)
            return (png: Data([1]), canvasRect: nil)
        }
        let first = try await manager.watch(docId: "d", framePx: 1024)
        var it = first.events.makeAsyncIterator()
        _ = await it.next()
        _ = try await manager.watch(docId: "d", framePx: 1024)
        // Nothing changed for the second watcher to see, so nothing is rendered for it.
        try await Task.sleep(for: .milliseconds(80))
        #expect(await calls.all.count == 1)
    }

    @Test func aLargerRequestRendersAgain() async throws {
        let manager = try makeManager()
        let calls = Calls()
        await manager.setFrameProvider { docId, bytes, px in
            await calls.record(docId, bytes, px)
            return (png: Data([1]), canvasRect: nil)
        }
        let small = try await manager.watch(docId: "d")
        var it = small.events.makeAsyncIterator()
        _ = await it.next()
        let big = try await manager.watch(docId: "d", framePx: 2048)
        var it2 = big.events.makeAsyncIterator()
        #expect(await it2.next() == .frameAvailable(docId: "d", seq: 0))
        #expect(await calls.all.map(\.px) == [nil, 2048])
    }

    @Test func aFailedRenderKeepsWhatThePageHasAndTheNextTriggerTriesAgain() async throws {
        let manager = try makeManager()
        let calls = Calls()
        struct Refused: Error {}
        await manager.setFrameProvider { docId, bytes, px in
            await calls.record(docId, bytes, px)
            if await calls.all.count == 1 { throw Refused() }
            return (png: Data([2]), canvasRect: nil)
        }
        let watch = try await manager.watch(docId: "d")
        var it = watch.events.makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.latestFrame(docId: "d") == nil)

        _ = await manager.submitOpeningSession(
            docId: "d", createIfMissing: false, opId: "w",
            payload: OpPayload(type: "fullDoc", data: Data("V2".utf8)))
        #expect(await it.next() == .frameAvailable(docId: "d", seq: 1))
        #expect(await calls.all.count == 2)
    }

    /// A burst of agent writes must not queue a render per write: one in flight, one pending,
    /// and the pending one renders the NEWEST bytes.
    @Test func rendersCoalesceWhileOneIsInFlight() async throws {
        let manager = try makeManager()
        let calls = Calls()
        let gate = Gate()
        await manager.setFrameProvider { docId, bytes, px in
            await calls.record(docId, bytes, px)
            await gate.wait()
            return (png: bytes, canvasRect: nil)
        }
        let watch = try await manager.watch(docId: "d")
        var it = watch.events.makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(30))   // the first render is now held at the gate
        for v in ["V2", "V3", "V4"] {
            _ = await manager.submitOpeningSession(
                docId: "d", createIfMissing: false, opId: v,
                payload: OpPayload(type: "fullDoc", data: Data(v.utf8)))
        }
        await gate.open()
        // The held render lands stamped with the seq at LANDING (as a device frame is) — a picture
        // of older bytes under a newer seq for the moment it takes the follow-up to replace it.
        #expect(await it.next() == .frameAvailable(docId: "d", seq: 3))
        #expect(await it.next() == .frameAvailable(docId: "d", seq: 3))   // ONE follow-up, newest bytes
        #expect(await manager.latestFrame(docId: "d")?.png == Data("V4".utf8))
        #expect(await calls.all.count == 2)
    }

    /// The case a server restart produces every time: the page reconnects in 2 s, the device in 5,
    /// so the re-watch finds no device and the page sits on the stored thumbnail until reloaded.
    /// A render-capable device connecting must render what is watched and unopened.
    @Test func aRenderCapableDeviceAppearingRendersWhatIsWatchedAndUnopened() async throws {
        let manager = try makeManager()
        let calls = Calls()
        let device = Flag()
        struct NoDevice: Error {}
        await manager.setFrameProvider { docId, bytes, px in
            await calls.record(docId, bytes, px)
            guard await device.isSet else { throw NoDevice() }
            return (png: Data([7]), canvasRect: nil)
        }
        let watch = try await manager.watch(docId: "d")
        var it = watch.events.makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.latestFrame(docId: "d") == nil)

        await device.set()
        await manager.deviceAppeared(capabilities: ["authorStrokes"])   // cannot render: nothing
        try await Task.sleep(for: .milliseconds(50))
        #expect(await calls.all.count == 1)

        await manager.deviceAppeared(capabilities: ["render", "authorStrokes"])
        #expect(await it.next() == .frameAvailable(docId: "d", seq: 0))
        #expect(await calls.all.count == 2)
    }

    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
}

/// The pure half of the relay: the op-spec it sends and how it reads the reply.
@Suite struct WatcherFrameSpecTests {
    @Test func theSpecIsAWholeDocumentPaperRenderBudgetedBySide() throws {
        let spec = try JSONSerialization.jsonObject(with: WatcherFrame.renderSpec(longSidePx: 2048)) as? [String: Any]
        #expect(spec?["op"] as? String == "render")
        #expect(spec?["include"] as? String == "document")
        #expect(spec?["background"] as? String == "paper")
        #expect(spec?["maxPixels"] as? Double == Double(2048 * 2048))
    }

    @Test func noRequestMeansTheDeviceDefault() throws {
        let spec = try JSONSerialization.jsonObject(with: WatcherFrame.renderSpec(longSidePx: nil)) as? [String: Any]
        #expect(spec?["maxPixels"] as? Double == Double(WatcherFrame.defaultLongSidePx * WatcherFrame.defaultLongSidePx))
    }

    @Test func theRectIsReadFromTheDevicesMetadata() {
        let meta = Data(#"{"canvasRect":[1,2,30,40],"pixelSize":[300,400],"scale":10}"#.utf8)
        #expect(WatcherFrame.canvasRect(fromMetadata: meta) == [1, 2, 30, 40])
        #expect(WatcherFrame.canvasRect(fromMetadata: nil) == nil)
        #expect(WatcherFrame.canvasRect(fromMetadata: Data("nope".utf8)) == nil)
        #expect(WatcherFrame.canvasRect(fromMetadata: Data(#"{"canvasRect":[1,2]}"#.utf8)) == nil)
    }
}
