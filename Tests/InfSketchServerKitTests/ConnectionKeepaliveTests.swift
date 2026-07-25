import Foundation
import Testing
@testable import InfSketchServerKit
import FlyingFox
import InfSketchWire

/// End-to-end behaviour of the stall guard through a real `WSAdapter.Connection` — the wiring
/// `ConnectionHealthTests` cannot cover, since that suite tests the policy in isolation.
///
/// **Why output is collected in a background task rather than read inline.** A connection that
/// is never dropped also stops producing output once its health state has latched, so awaiting
/// `AsyncStream.AsyncIterator.next()` directly would block forever. That is not hypothetical: an
/// earlier version of this file did exactly that, and mutating the drop path away hung the suite
/// for ten minutes instead of failing it. Every assertion here is therefore deadline-bounded, so
/// a regression reports a failure rather than a hang.
struct ConnectionKeepaliveTests {

    /// Aggressive but not instant: a budget small enough that one ordinary message crosses it,
    /// and deadlines short enough to keep the suite fast.
    ///
    /// The grace is 500 ms, deliberately much larger than the idle interval. It is not a speed
    /// knob — it is the margin `aPeerThatAnswersPingsIsNeverDropped` has to answer, and that
    /// test's answering loop polls every 10 ms. At the 60 ms this once used, ONE scheduling stall
    /// longer than the grace made the server drop a peer the test asserts is never dropped, so
    /// the test was flaky by margin. Suite duration is set by `keepaliveIdleInterval`, which is
    /// what paces the pings, so widening the grace costs nothing.
    private static func fastConfig(
        budget: Int = 64, idle: Duration = .milliseconds(60)
    ) -> SessionConfig {
        SessionConfig(
            outboundByteBudget: budget,
            keepaliveIdleInterval: idle,
            keepalivePingGrace: .milliseconds(500),
            keepaliveTickInterval: .milliseconds(10))
    }

    private static func makeManager() throws -> SessionManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepalive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        return SessionManager(store: store, config: SessionConfig())
    }

    /// Accumulates the connection's output off to the side, so tests can poll instead of block.
    private actor Collector {
        private(set) var messages: [ServerMessage] = []
        private(set) var closed = false

        func append(_ message: ServerMessage) { messages.append(message) }
        func markClosed() { closed = true }
        var pingCount: Int {
            messages.count { if case .ping = $0 { return true } else { return false } }
        }
    }

    private struct Harness {
        let input: AsyncStream<WSMessage>.Continuation
        let collector: Collector
        private let pump: Task<Void, Never>

        init(manager: SessionManager, config: SessionConfig) async throws {
            let (inStream, inCont) = AsyncStream<WSMessage>.makeStream()
            self.input = inCont
            let output = try await WSAdapter(
                manager: manager, config: config, broker: DeviceCommandBroker()
            ).makeMessages(for: inStream)
            let collector = Collector()
            self.collector = collector
            self.pump = Task {
                var reassembler = TransferReassembler<ServerMessage>()
                for await frame in output {
                    switch frame {
                    case .text(let text):
                        if let m = try? reassembler.consume(.text(text)) { await collector.append(m) }
                    case .data(let data):
                        if let m = try? reassembler.consume(.binary(data)) { await collector.append(m) }
                    case .close:
                        await collector.markClosed()
                        return
                    }
                }
            }
        }

        func send(_ message: ClientMessage) throws {
            input.yield(.text(try message.jsonText()))
        }

        func finish() { pump.cancel() }

        /// Polls until `condition` holds or the deadline passes. Returns whether it held, so a
        /// regression fails the expectation instead of hanging the suite.
        func wait(
            upTo timeout: Duration = .seconds(5),
            for condition: @Sendable (Collector) async -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if await condition(collector) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await condition(collector)
        }
    }

    /// A peer that never answers is pinged and then dropped. This is the half-open socket: it
    /// says hello, then goes silent forever while the connection stays open.
    @Test func aSilentPeerIsPingedThenDropped() async throws {
        let manager = try Self.makeManager()
        let harness = try await Harness(manager: manager, config: Self.fastConfig())
        defer { harness.finish() }
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: [], deviceId: "dev"))

        let dropped = await harness.wait { await $0.closed }
        #expect(dropped, "an unresponsive peer must be disconnected")
        #expect(await harness.collector.pingCount > 0, "it must be ASKED before being dropped")
    }

    /// Dropping the connection must release what it held, so the grace teardown can run. This is
    /// the whole point of reaping a half-open socket.
    @Test func droppingAPeerReleasesItsSubscription() async throws {
        let manager = try Self.makeManager()
        let harness = try await Harness(manager: manager, config: Self.fastConfig())
        defer { harness.finish() }
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: [], deviceId: "dev"))
        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))

        #expect(await harness.wait { await $0.closed }, "the peer must be dropped")

        // The close FRAME is yielded before `close()` runs — `act(on:)` spawns it as a Task, so
        // the subscription is released a moment after the client learns it is being dropped.
        var subscribers = await manager.liveInfo()["d"]?.subscriberCount
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while subscribers != 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            subscribers = await manager.liveInfo()["d"]?.subscriberCount
        }
        #expect(subscribers == 0, "the dropped connection's subscription must be released")
    }

    /// THE regression guard for the passive receiver: a peer that answers pings but never
    /// otherwise speaks must survive indefinitely. A "drop on budget" implementation, or one
    /// that fails to count a pong as proof of life, disconnects exactly this client.
    @Test func aPeerThatAnswersPingsIsNeverDropped() async throws {
        let manager = try Self.makeManager()
        let harness = try await Harness(manager: manager, config: Self.fastConfig())
        defer { harness.finish() }
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: [], deviceId: "dev"))

        // Answer every ping as it arrives, for long enough to span several idle intervals.
        var answered = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while answered < 3, ContinuousClock.now < deadline {
            if await harness.collector.closed { break }
            let seen = await harness.collector.pingCount
            while answered < seen {
                answered += 1
                try harness.send(.pong)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(answered >= 3, "the idle timer should have pinged repeatedly; answered \(answered)")
        #expect(await harness.collector.closed == false,
                "a peer answering every ping must never be dropped")
    }

    /// The BUDGET path, end to end and in isolation. Both other integration tests reach their
    /// ping through the IDLE timer (`aSilentPeerIsPingedThenDropped` emits only a 39-byte
    /// `helloAck` against its 64-byte budget, so it never crosses it;
    /// `droppingAPeerReleasesItsSubscription` does cross it but asserts nothing about which path
    /// fired) — so a regression that broke `noteEmitted`'s ping and left `tick`'s intact used to
    /// pass every integration test.
    ///
    /// The isolation is the idle interval: at 60 s, nothing in a test bounded to seconds can
    /// produce a ping except crossing the byte budget. The bytes are real output — subscribing
    /// to the seeded doc returns its snapshot, several hundred bytes of base64 — and the
    /// `helloAck` assertion first pins that the budget was NOT already crossed before it.
    @Test func crossingTheByteBudgetPingsEvenWhenTheIdleTimerCannotFire() async throws {
        let manager = try Self.makeManager()
        let harness = try await Harness(
            manager: manager, config: Self.fastConfig(budget: 100, idle: .seconds(60)))
        defer { harness.finish() }
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: [], deviceId: "dev"))

        #expect(await harness.wait { await $0.messages.isEmpty == false }, "expected a helloAck")
        #expect(await harness.collector.pingCount == 0,
                "the 39-byte helloAck is under the 100-byte budget — nothing should have pinged yet")

        try harness.send(.subscribe(docId: "d", fromSeq: nil, createIfMissing: false))
        #expect(await harness.wait { await $0.pingCount > 0 },
                "the snapshot pushes emitted bytes past the budget, which must ASK the peer to prove it is reading")
    }

    /// A pong must be accepted before hello — it is pure liveness, and answering it with
    /// `helloRequired` would make an alive-but-unauthenticated peer unable to prove itself.
    @Test func aPongBeforeHelloIsNotAnError() async throws {
        let manager = try Self.makeManager()
        let harness = try await Harness(
            manager: manager,
            config: SessionConfig(keepaliveIdleInterval: .seconds(30), keepaliveTickInterval: .seconds(5)))
        defer { harness.finish() }
        try harness.send(.pong)
        try harness.send(.hello(protocolVersion: WireProtocol.version, capabilities: [], deviceId: "dev"))

        let gotReply = await harness.wait { await $0.messages.isEmpty == false }
        #expect(gotReply, "expected a helloAck")
        let messages = await harness.collector.messages
        guard let first = messages.first, case .helloAck = first else {
            Issue.record("a pre-hello pong must not produce an error; got \(messages)")
            return
        }
    }
}
