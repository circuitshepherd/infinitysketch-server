import Foundation
import Testing
@testable import InfSketchServerKit
import FlyingFox
import InfSketchWire

/// A subscribe or watch that fetches its document from a holder can take ~50 s. It used to be
/// awaited INLINE in the connection's receive loop, so for that whole time the peer's pongs, its
/// replies to relayed agent ops and everything else it sent sat unread: agent calls timed out,
/// two devices opening each other's documents deadlocked, and the keepalive could drop the peer
/// that was waiting (review finding 12). Messages for OTHER documents, and connection-level ones,
/// must not wait; messages for the SAME document must still run in the order they were sent.
@Suite struct ConnectionConcurrencyTests {

    private actor Gate {
        private var open = false
        func release() { open = true }
        func wait() async { while !open { try? await Task.sleep(for: .milliseconds(5)) } }
    }

    private actor Collector {
        private(set) var messages: [ServerMessage] = []
        func append(_ message: ServerMessage) { messages.append(message) }
        func index(where predicate: (ServerMessage) -> Bool) -> Int? { messages.firstIndex(where: predicate) }
    }

    private struct Harness {
        let input: AsyncStream<WSMessage>.Continuation
        let collector = Collector()
        private let pump: Task<Void, Never>

        init(manager: SessionManager, broker: DeviceCommandBroker = DeviceCommandBroker()) async throws {
            let (inStream, inCont) = AsyncStream<WSMessage>.makeStream()
            self.input = inCont
            let output = try await WSAdapter(manager: manager, config: SessionConfig(), broker: broker)
                .makeMessages(for: inStream)
            let collector = self.collector
            self.pump = Task {
                var reassembler = TransferReassembler<ServerMessage>()
                for await frame in output {
                    switch frame {
                    case .text(let text):
                        if let m = try? reassembler.consume(.text(text)) { await collector.append(m) }
                    case .data(let data):
                        if let m = try? reassembler.consume(.binary(data)) { await collector.append(m) }
                    case .close: return
                    }
                }
            }
        }

        func send(_ message: ClientMessage) throws { input.yield(.text(try message.jsonText())) }
        func finish() { pump.cancel(); input.finish() }

        func wait(upTo timeout: Duration = .seconds(5),
                  for condition: @Sendable (Collector) async -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if await condition(collector) { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await condition(collector)
        }
    }

    /// A manager with "d" stored and "remote" only advertised, whose holder fetch waits on `gate`.
    private func makeManager(gate: Gate) async throws -> SessionManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        let manager = SessionManager(store: store)
        await manager.applyAdvertisements(
            [DocAdvertisement(docId: "remote", modifiedAt: Date(), sizeBytes: 2, thumbnail: nil)],
            connectionId: UUID(), deviceId: "holder")
        await manager.setContentProvider { _, _ in
            await gate.wait()
            return Data(#"{"fetched":true}"#.utf8)
        }
        return manager
    }

    @Test func aSlowSubscribeDoesNotHoldUpTheRestOfTheConnection() async throws {
        let gate = Gate()
        let manager = try await makeManager(gate: gate)
        let harness = try await Harness(manager: manager)
        defer { harness.finish() }
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: [], deviceId: "dev"))
        try harness.send(.subscribe(docId: "remote", createIfMissing: false))
        try harness.send(.listDocs)
        try harness.send(.subscribe(docId: "d", createIfMissing: false))

        let answered = await harness.wait { collector in
            let messages = await collector.messages
            return messages.contains { if case .docList = $0 { true } else { false } }
                && messages.contains { if case .subscribed("d", _, _, _, _) = $0 { true } else { false } }
        }
        #expect(answered, "a listing and another document's subscribe must not wait for the fetch")
        #expect(await harness.collector.index { if case .subscribed("remote", _, _, _, _) = $0 { true } else { false } } == nil)

        await gate.release()
        #expect(await harness.wait { collector in
            await collector.index { if case .subscribed("remote", _, _, _, _) = $0 { true } else { false } } != nil
        })
    }

    /// The device's reply to a relayed agent op is not held behind its own slow subscribe.
    @Test func aStrokeOpReplyIsHandledDuringASlowSubscribe() async throws {
        let gate = Gate()
        let manager = try await makeManager(gate: gate)
        let broker = DeviceCommandBroker(strokeOpTimeout: .seconds(5))
        let harness = try await Harness(manager: manager, broker: broker)
        defer { harness.finish() }
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: ["authorStrokes"], deviceId: "dev"))
        #expect(await harness.wait { await $0.index { if case .helloAck = $0 { true } else { false } } != nil })
        try harness.send(.subscribe(docId: "remote", createIfMissing: false))

        let request = Task {
            try await broker.requestStrokeOp(docId: "d", docBytes: Data("x".utf8), spec: Data("{}".utf8),
                                             capability: "authorStrokes")
        }
        _ = await harness.wait { collector in
            await collector.messages.contains { if case .strokeOpRequest = $0 { true } else { false } }
        }
        let id = try #require(await harness.collector.messages.lazy.compactMap { message -> UInt32? in
            if case .strokeOpRequest(let id, _, _, _, _, _) = message { return id }
            return nil
        }.first)
        try harness.send(.strokeOpReply(requestId: id, docId: "d", payload: .inline(Data("y".utf8)),
                                        meta: nil, failureReason: nil))
        let reply = try await request.value
        #expect(reply.bytes == Data("y".utf8), "the reply must land while the subscribe is still fetching")
        await gate.release()
    }

    /// Messages for the SAME document keep their order: the app's create-push follows its
    /// subscribe immediately, and must not be refused `notSubscribed` because the subscribe is
    /// still running.
    @Test func anOpBehindItsDocumentsSlowSubscribeWaitsForIt() async throws {
        let gate = Gate()
        let manager = try await makeManager(gate: gate)
        let harness = try await Harness(manager: manager)
        defer { harness.finish() }
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: [], deviceId: "dev"))
        try harness.send(.subscribe(docId: "remote", createIfMissing: false))
        let payload = OpPayload(type: "fullDoc", data: Data([7]))
        try harness.send(.op(docId: "remote", opId: "o1", payload: payload))
        try await Task.sleep(for: .milliseconds(100))
        await gate.release()

        #expect(await harness.wait { collector in
            await collector.index { if case .event("remote", _, _, "o1", _) = $0 { true } else { false } } != nil
        }, "the op must be applied after the subscribe")
        let messages = await harness.collector.messages
        #expect(!messages.contains(.error(reason: "notSubscribed")))
        let subscribed = messages.firstIndex { if case .subscribed("remote", _, _, _, _) = $0 { true } else { false } }
        let event = messages.firstIndex { if case .event("remote", _, _, "o1", _) = $0 { true } else { false } }
        #expect(subscribed != nil && event != nil && subscribed! < event!)
    }

    /// A store whose next `load` blocks until released — it holds the manager actor, which is
    /// what makes the handshake's own `await` on the manager last long enough to observe.
    final class HeldLoadStore: DocumentStore, @unchecked Sendable {
        let inner: DirectoryDocumentStore
        private let lock = NSLock()
        private var holding = false
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        init(_ inner: DirectoryDocumentStore) { self.inner = inner }
        func holdNextLoad() { lock.lock(); holding = true; lock.unlock() }
        func waitUntilEntered() { entered.wait() }
        func release() { released.signal() }
        func list() throws -> [StoredDocInfo] { try inner.list() }
        func save(docId: String, bytes: Data) throws { try inner.save(docId: docId, bytes: bytes) }
        func exists(docId: String) throws -> Bool { try inner.exists(docId: docId) }
        func delete(docId: String) throws { try inner.delete(docId: docId) }
        func storedDocId(matching docId: String) -> String? { inner.storedDocId(matching: docId) }
        func load(docId: String) throws -> Data {
            lock.lock(); let hold = holding; holding = false; lock.unlock()
            if hold { entered.signal(); released.wait() }
            return try inner.load(docId: docId)
        }
    }

    /// The handshake reply goes out before anything that can send the device a request: the app
    /// treats the first message after hello as the handshake reply, so a relay render or an agent
    /// op arriving first failed its handshake and cost the connection (review finding 14a).
    @Test func helloAckPrecedesAnyRequestADeviceCanReceive() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hello-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inner = DirectoryDocumentStore(directory: dir)
        try inner.save(docId: "d", bytes: Fixtures.docBytes)
        let store = HeldLoadStore(inner)
        let manager = SessionManager(store: store)
        let broker = DeviceCommandBroker(strokeOpTimeout: .seconds(5))
        let harness = try await Harness(manager: manager, broker: broker)
        defer { harness.finish() }

        // Busy the manager: the hello's announcement to it must now wait.
        store.holdNextLoad()
        let busy = Task { _ = try? await manager.subscribe(docId: "d") }
        await Task.detached { store.waitUntilEntered() }.value

        // An agent asking for a device the moment one exists.
        let agent = Task {
            while !Task.isCancelled {
                do {
                    _ = try await broker.requestStrokeOp(docId: "d", docBytes: Data(), spec: Data("{}".utf8),
                                                         capability: "render")
                    return
                } catch DeviceCommandBroker.DeviceCommandError.noDeviceAvailable {
                    try? await Task.sleep(for: .milliseconds(1))
                } catch { return }
            }
        }
        defer { agent.cancel() }
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: ["render"], deviceId: "dev"))
        _ = await harness.wait(upTo: .seconds(2)) {
            await $0.messages.contains { if case .strokeOpRequest = $0 { true } else { false } }
        }
        store.release()
        _ = await busy.value
        #expect(await harness.wait { await !$0.messages.isEmpty })
        #expect(isCurrentHelloAck(await harness.collector.messages.first))
    }
}
