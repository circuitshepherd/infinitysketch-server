import Foundation
import Testing
import FlyingFox
import InfSketchWire
@testable import InfSketchServerKit

/// "Agents are at work" — a tool call within the last `window`. While it holds, the host is kept
/// from its idle standby and the connected devices are told, so they keep their screens on: an
/// agent's drawing needs a device that is running, and a host that is awake.
struct AgentWorkPolicyTests {
    private let window = Duration.seconds(600)
    private let interval = Duration.seconds(30)

    @Test func theFirstCallStartsWorkAndIsAnnounced() {
        var policy = AgentWorkPolicy(window: window, announceInterval: interval)
        let t0 = ContinuousClock.now
        #expect(!policy.isCurrent(now: t0))
        #expect(policy.noteCall(now: t0) == true, "the first call is announced")
        #expect(policy.isCurrent(now: t0))
    }

    /// A drawing agent calls several tools a second. The devices need telling once in a while,
    /// not on every call.
    @Test func callsInsideTheAnnounceIntervalAreNotAnnouncedAgain() {
        var policy = AgentWorkPolicy(window: window, announceInterval: interval)
        let t0 = ContinuousClock.now
        _ = policy.noteCall(now: t0)
        #expect(policy.noteCall(now: t0.advanced(by: .seconds(5))) == false)
        #expect(policy.noteCall(now: t0.advanced(by: .seconds(29))) == false)
        #expect(policy.noteCall(now: t0.advanced(by: .seconds(31))) == true, "past the interval: told again")
    }

    @Test func workEndsAWindowAfterTheLastCall() {
        var policy = AgentWorkPolicy(window: window, announceInterval: interval)
        let t0 = ContinuousClock.now
        _ = policy.noteCall(now: t0)
        _ = policy.noteCall(now: t0.advanced(by: .seconds(100)))
        #expect(policy.isCurrent(now: t0.advanced(by: .seconds(699))), "counted from the LAST call")
        #expect(!policy.isCurrent(now: t0.advanced(by: .seconds(700))))
        #expect(policy.endsAt == t0.advanced(by: .seconds(700)))
    }
}

final class FakeHostAwake: HostAwake, @unchecked Sendable {
    private let lock = NSLock()
    private var _holds = 0, _releases = 0
    private var _releasedAt: ContinuousClock.Instant?

    func hold() { lock.lock(); _holds += 1; lock.unlock() }
    func release() { lock.lock(); _releases += 1; _releasedAt = .now; lock.unlock() }

    var holds: Int { lock.lock(); defer { lock.unlock() }; return _holds }
    var releases: Int { lock.lock(); defer { lock.unlock() }; return _releases }
    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return _holds > _releases }
    var releasedAt: ContinuousClock.Instant? { lock.lock(); defer { lock.unlock() }; return _releasedAt }
}

struct AgentWorkTests {
    private actor Count {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    @Test func theHostIsHeldFromTheFirstCallAndAnnouncedOnce() async {
        let host = FakeHostAwake()
        let announced = Count()
        let work = AgentWork(window: .seconds(600), announceInterval: .seconds(30), hostAwake: host) {
            await announced.bump()
        }
        #expect(!host.isHeld)
        await work.noteToolCall()
        await work.noteToolCall()
        await work.noteToolCall()
        #expect(host.isHeld)
        #expect(host.holds == 1, "held once, however many calls")
        #expect(await announced.value == 1)
        #expect(await work.isCurrent)
    }

    /// The release is a window after the LAST call — a call during the work moves it. Read off
    /// the instant of the release, against an instant taken BEFORE the last call, so nothing
    /// depends on how fast the machine is: should the first window run out before the second
    /// call (a starved runner), the host is held again and the same holds for THAT release.
    @Test func theHostIsReleasedAWindowAfterTheLastCall() async {
        let host = FakeHostAwake()
        let window = Duration.milliseconds(300)
        let work = AgentWork(window: window, announceInterval: .seconds(30), hostAwake: host) {}
        await work.noteToolCall()
        try? await Task.sleep(for: .milliseconds(150))
        let beforeTheLastCall = ContinuousClock.now
        await work.noteToolCall()
        await waitFor { !host.isHeld }
        #expect(!host.isHeld)
        let releasedAt = host.releasedAt ?? beforeTheLastCall
        #expect(releasedAt - beforeTheLastCall >= window,
                "released \(releasedAt - beforeTheLastCall) after the last call; the window is \(window)")
        #expect(await !work.isCurrent)
    }

    @Test func workThatStartsAgainHoldsAgain() async {
        let host = FakeHostAwake()
        let announced = Count()
        let work = AgentWork(window: .milliseconds(100), announceInterval: .milliseconds(50), hostAwake: host) {
            await announced.bump()
        }
        await work.noteToolCall()
        await waitFor { host.releases == 1 }
        await work.noteToolCall()
        // Counts, not "is it held right now": the second window is 100 ms too, and a check that
        // runs later than that on a starved machine would find it released again.
        #expect(host.holds == 2)
        #expect(await announced.value == 2)
        await waitFor { host.releases == 2 }
        #expect(host.releases == 2)
    }
}

/// The kind of the first status event on `events`, or nil when none arrives in time. Never a
/// bare `iterator.next()`: a stream nothing is sent on would hang the suite instead of failing
/// the test (it did, under the mutation that removed the announcement).
func firstStatusKind(_ events: AsyncStream<ServerMessage>, within limit: Duration = .seconds(5)) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        group.addTask {
            for await message in events {
                if case .statusEvent(let payload) = message { return payload.kind }
            }
            return nil
        }
        group.addTask { try? await Task.sleep(for: limit); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// What the devices hear: a status event of the kind both sides read from the wire package.
struct AgentWorkAnnouncementTests {
    private func makeManager() throws -> SessionManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionManager(store: DirectoryDocumentStore(directory: dir), config: SessionConfig())
    }

    @Test func everyStatusSubscriberIsTold() async throws {
        let manager = try makeManager()
        let (events, _) = await manager.subscribeStatus()
        await manager.announceAgentWork()
        #expect(await firstStatusKind(events) == AgentWorkSignal.statusKind)
    }
}

/// A device that connects while an agent is at work missed the announcement — after the host's
/// standby, or its own lock — so its status subscription is answered with one.
struct AgentWorkOnSubscribeTests {
    private func makeManager() throws -> SessionManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-work-sub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionManager(store: DirectoryDocumentStore(directory: dir), config: SessionConfig())
    }

    private actor Received {
        private(set) var messages: [ServerMessage] = []
        func append(_ message: ServerMessage) { messages.append(message) }
        var sawDocList: Bool {
            messages.contains { if case .docList = $0 { return true } else { return false } }
        }
        var agentWorkCount: Int {
            messages.count {
                if case .statusEvent(let p) = $0 { return p.kind == AgentWorkSignal.statusKind }
                return false
            }
        }
    }

    /// Says hello, subscribes to status, then asks for the document list on a real `Connection`,
    /// and returns once the LIST has arrived. A connection handles its messages in order, so by
    /// then the subscribe is done and whatever it sends has been sent.
    private func receivedThroughTheSubscribe(manager: SessionManager, agentWork: AgentWork) async throws -> Received {
        let (inStream, input) = AsyncStream<WSMessage>.makeStream()
        let output = try await WSAdapter(
            manager: manager, config: SessionConfig(), broker: DeviceCommandBroker(), agentWork: agentWork
        ).makeMessages(for: inStream)
        let received = Received()
        Task {
            var reassembler = TransferReassembler<ServerMessage>()
            for await frame in output {
                guard case .text(let text) = frame,
                      let message = try? reassembler.consume(.text(text)) else { continue }
                await received.append(message)
            }
        }
        for message in [ClientMessage.hello(protocolVersion: WireProtocol.version, capabilities: [], deviceId: "ipad"),
                        .subscribeStatus, .listDocs] {
            input.yield(.text(try message.jsonText()))
        }
        await waitFor { await received.sawDocList }
        #expect(await received.sawDocList, "the connection answered the list request")
        return received
    }

    @Test func aSubscriberDuringAgentWorkIsToldAtOnce() async throws {
        let work = AgentWork(hostAwake: FakeHostAwake()) {}
        await work.noteToolCall()
        let received = try await receivedThroughTheSubscribe(manager: try makeManager(), agentWork: work)
        #expect(await received.agentWorkCount == 1)
    }

    @Test func aSubscriberWithNoAgentAtWorkIsToldNothing() async throws {
        let work = AgentWork(hostAwake: FakeHostAwake()) {}
        let received = try await receivedThroughTheSubscribe(manager: try makeManager(), agentWork: work)
        #expect(await received.agentWorkCount == 0)
    }
}

#if MCP_SSE_CLIENT
import MCP

/// The whole path: an agent's tool call holds the host and tells the devices.
@Suite(.serialized)
struct AgentWorkServerTests {
    @Test func aToolCallHoldsTheHostAndTellsTheStatusSubscribers() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-work-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = FakeHostAwake()
        let server = InfSketchServer(port: 0, docsDirectory: dir, hostAwake: host)
        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        let (events, _) = await server.manager.subscribeStatus()

        #expect(!host.isHeld, "nothing is held before an agent calls")
        let client = Client(name: "agent-work", version: "1")
        try await client.connect(transport: HTTPClientTransport(
            endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: false))
        _ = try await client.callTool(name: "list_docs", arguments: [:])

        #expect(host.isHeld)
        #expect(await firstStatusKind(events) == AgentWorkSignal.statusKind)
    }
}
#endif
