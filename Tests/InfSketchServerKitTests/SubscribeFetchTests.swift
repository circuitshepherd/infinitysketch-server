import XCTest
import InfSketchWire
@testable import InfSketchServerKit

final class SubscribeFetchTests: XCTestCase {
    private func makeManager() throws -> (SessionManager, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m2c1-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SessionManager(store: DirectoryDocumentStore(directory: dir)), dir)
    }
    private func ad(_ id: String) -> DocAdvertisement {
        DocAdvertisement(docId: id, modifiedAt: Date(timeIntervalSince1970: 0),
                         sizeBytes: 3, thumbnail: nil)
    }

    /// Subscribing to a doc the server has no bytes for pulls it from a holder, PERSISTS it
    /// (it stays), and serves a normal snapshot.
    func testSubscribeFetchesFromHolderAndPersists() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], deviceId: "devA")
        await manager.setContentProvider { docId, deviceId in
            XCTAssertEqual(docId, "Ghost"); XCTAssertEqual(deviceId, "devA")
            return Data("PULLED".utf8)
        }

        let result = try await manager.subscribe(docId: "Ghost")
        guard case .subscribed(_, _, let snapshot) = result.snapshot,
              case .inline(let bytes) = snapshot else { return XCTFail("expected inline snapshot") }
        XCTAssertEqual(bytes, Data("PULLED".utf8))
        // Persisted — it is now a content doc and STAYS.
        XCTAssertEqual(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"), Data("PULLED".utf8))
        let listed = try await manager.listDocuments()
        XCTAssertTrue(listed.first { $0.id == "Ghost" }!.hasContent)
    }

    /// Equal devices: if the first holder fails, the next one is tried.
    func testFallsBackToTheNextHolder() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], deviceId: "devA")
        await manager.applyAdvertisements([ad("Ghost")], deviceId: "devB")
        await manager.setContentProvider { _, deviceId in
            if deviceId == "devA" { throw DeviceCommandBroker.DeviceCommandError.noDeviceAvailable }
            return Data("FROM-B".utf8)
        }

        _ = try await manager.subscribe(docId: "Ghost")
        XCTAssertEqual(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"), Data("FROM-B".utf8))
    }

    /// Every holder failed → the subscribe fails; nothing is persisted.
    func testAllHoldersFailingSurfacesAnError() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], deviceId: "devA")
        await manager.setContentProvider { _, _ in throw DeviceCommandBroker.DeviceCommandError.noDeviceAvailable }

        do {
            _ = try await manager.subscribe(docId: "Ghost")
            XCTFail("expected the subscribe to fail")
        } catch {
            XCTAssertThrowsError(try DirectoryDocumentStore(directory: dir).load(docId: "Ghost"))
        }
    }

    /// No holders at all (not in the live index) → the ordinary notFound, no provider call.
    func testUnknownDocStillThrowsNotFound() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.setContentProvider { _, _ in
            XCTFail("provider must not be called for a doc with no holders"); return Data()
        }
        do {
            _ = try await manager.subscribe(docId: "Nope")
            XCTFail("expected notFound")
        } catch {}
    }

    /// Concurrent subscribes coalesce onto ONE fetch.
    func testConcurrentSubscribesCoalesceIntoOneFetch() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], deviceId: "devA")
        actor Counter { var n = 0; func bump() { n += 1 } }
        let calls = Counter()
        await manager.setContentProvider { _, _ in
            await calls.bump()
            try? await Task.sleep(for: .milliseconds(80))
            return Data("ONCE".utf8)
        }

        async let a = manager.subscribe(docId: "Ghost")
        async let b = manager.subscribe(docId: "Ghost")
        _ = try await (a, b)
        let n = await calls.n
        XCTAssertEqual(n, 1)
    }

    /// createIfMissing (the app's create-push) must NOT trigger a fetch.
    func testCreateIfMissingDoesNotFetch() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], deviceId: "devA")
        await manager.setContentProvider { _, _ in
            XCTFail("createIfMissing must not fetch"); return Data()
        }
        _ = try await manager.subscribe(docId: "Ghost", createIfMissing: true)
    }

    /// Two devices tapping "download" on the same not-yet-resident doc must end up on ONE
    /// session. The fetch is the first suspension point between subscribe's `sessions[docId]`
    /// check and its write, and the actor is reentrant — so without adopting the racing winner
    /// both callers open their own `DocumentSession`, the second overwrites the first, and the
    /// LOSER's event stream is bound to a session nothing broadcasts into: that subscriber
    /// silently freezes at its initial snapshot. Assert the user-visible property — BOTH
    /// subscribers keep receiving broadcasts.
    func testConcurrentFirstSubscribesShareOneSessionAndBothKeepReceiving() async throws {
        let (manager, dir) = try makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.applyAdvertisements([ad("Ghost")], deviceId: "devA")
        await manager.setContentProvider { _, _ in
            try? await Task.sleep(for: .milliseconds(80))   // widen the reentrancy window
            return Data("PULLED".utf8)
        }

        async let a = manager.subscribe(docId: "Ghost")
        async let b = manager.subscribe(docId: "Ghost")
        let (subA, subB) = try await (a, b)

        // One broadcast to the doc …
        _ = await manager.submit(docId: "Ghost", opId: "op1",
                                 payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)))

        // … must reach BOTH subscribers. Bounded waits, NOT a bare `for await` drain: an orphaned
        // session is never unsubscribed from (its token doesn't belong to the registered session),
        // so its stream never finishes and the drain would hang forever instead of failing.
        let gotA = await Self.receivesEvent(subA)
        let gotB = await Self.receivesEvent(subB)
        XCTAssertTrue(gotA, "subscriber A missed the broadcast (orphaned session)")
        XCTAssertTrue(gotB, "subscriber B missed the broadcast (orphaned session)")
    }

    /// True if `result`'s stream yields an `.event` before the timeout. Each stream has exactly
    /// one consumer here, so cancelling the loser task can't poison a shared stream.
    private static func receivesEvent(_ result: SubscribeResult,
                                      timeout: Duration = .milliseconds(500)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await message in result.events { if case .event = message { return true } }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
