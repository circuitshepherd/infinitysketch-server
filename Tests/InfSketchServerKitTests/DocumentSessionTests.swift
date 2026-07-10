import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

private func makeSession(bufferLimit: Int = 256) throws -> (DocumentSession, DirectoryDocumentStore) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("session-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = DirectoryDocumentStore(directory: dir)
    try store.save(docId: "d", bytes: Fixtures.docBytes)
    let session = try DocumentSession(docId: "d", store: store, bufferLimit: bufferLimit)
    return (session, store)
}

@Suite struct DocumentSessionTests {
    @Test func subscribeReturnsSeqStampedSnapshot() async throws {
        let (session, _) = try makeSession()
        let result = await session.subscribe()
        #expect(result.snapshot == .subscribed(docId: "d", seq: 0, snapshot: .inline(Fixtures.docBytes)))
        #expect(await session.subscriberCount == 1)
    }

    @Test func submitBroadcastsToAllIncludingSubmitter() async throws {
        let (session, _) = try makeSession()
        let a = await session.subscribe()
        let b = await session.subscribe()
        let payload = OpPayload(type: "fullDoc", data: Data([42]))
        let reject = await session.submit(opId: "op-1", payload: payload)
        #expect(reject == nil)

        for stream in [a.events, b.events] {
            var it = stream.makeAsyncIterator()
            let ev = await it.next()
            #expect(ev == .event(docId: "d", seq: 1, kind: "op", opId: "op-1", payload: payload))
        }
        #expect(await session.seq == 1)
    }

    @Test func submitWritesThroughToStore() async throws {
        let (session, store) = try makeSession()
        _ = await session.subscribe()
        let newBytes = Data(#"{"aaa001_thumbnailData":null,"strokes":[1]}"#.utf8)
        _ = await session.submit(opId: "op-1", payload: OpPayload(type: "fullDoc", data: newBytes))
        #expect(try store.load(docId: "d") == newBytes)
    }

    @Test func unsupportedPayloadTypeRejectedWithoutBroadcast() async throws {
        let (session, _) = try makeSession()
        let a = await session.subscribe()
        let reject = await session.submit(opId: "op-1", payload: OpPayload(type: "strokeDelta", data: Data()))
        #expect(reject == .reject(docId: "d", opId: "op-1", reason: "unsupportedPayloadType", seq: 0))
        #expect(await session.seq == 0)
        // Nothing must have been broadcast: next accepted op is the FIRST event on the stream.
        _ = await session.submit(opId: "op-2", payload: OpPayload(type: "fullDoc", data: Data([1])))
        var it = a.events.makeAsyncIterator()
        let ev = await it.next()
        if case .event(_, let seq, _, let opId, _) = ev {
            #expect(seq == 1)
            #expect(opId == "op-2")
        } else {
            Issue.record("expected event, got \(String(describing: ev))")
        }
    }

    @Test func unsubscribeFinishesStream() async throws {
        let (session, _) = try makeSession()
        let a = await session.subscribe()
        await session.unsubscribe(a.token)
        #expect(await session.subscriberCount == 0)
        var it = a.events.makeAsyncIterator()
        let ev = await it.next()
        #expect(ev == nil)
    }

    @Test func slowSubscriberIsDisconnectedOnBufferOverflow() async throws {
        let (session, _) = try makeSession(bufferLimit: 2)
        let slow = await session.subscribe()  // never consumed
        for i in 1...5 {
            _ = await session.submit(opId: "op-\(i)", payload: OpPayload(type: "fullDoc", data: Data([UInt8(i)])))
        }
        // Overflow (op-3) must have finished the slow stream and removed the subscriber.
        #expect(await session.subscriberCount == 0)
        var received = [ServerMessage]()
        for await ev in slow.events { received.append(ev) }  // terminates because finished
        #expect(received.count == 2)  // only the buffered ops before overflow
    }
}
