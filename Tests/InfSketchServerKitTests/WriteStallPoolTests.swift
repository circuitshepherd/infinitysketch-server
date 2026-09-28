import Foundation
import Testing
import FlyingSocks
@testable import InfSketchServerKit

/// A peer that stops reading must lose its socket: FlyingFox's writer waits on the pool for
/// writability, and the drop's close frame queues behind the whole backlog.
@Suite struct WriteStallPoolTests {

    /// A pool whose sockets never become ready — the non-reading peer's view from the writer.
    private struct NeverReadyPool: AsyncSocketPool {
        func prepare() async throws {}
        func run() async throws {}
        func suspendSocket(_ socket: Socket, untilReadyFor events: Socket.Events) async throws {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private struct ReadyPool: AsyncSocketPool {
        func prepare() async throws {}
        func run() async throws {}
        func suspendSocket(_ socket: Socket, untilReadyFor events: Socket.Events) async throws {}
    }

    @Test func aStalledWriteFails() async throws {
        let socket = try Socket(domain: AF_INET, type: .stream)
        defer { try? socket.close() }
        let pool = WriteStallTimeoutPool(inner: NeverReadyPool(), timeout: .milliseconds(50))
        let started = ContinuousClock.now
        await #expect(throws: SocketError.self) {
            try await pool.suspendSocket(socket, untilReadyFor: .write)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aWriteThatBecomesReadyPasses() async throws {
        let socket = try Socket(domain: AF_INET, type: .stream)
        defer { try? socket.close() }
        let pool = WriteStallTimeoutPool(inner: ReadyPool(), timeout: .milliseconds(50))
        try await pool.suspendSocket(socket, untilReadyFor: .write)
    }

    /// Reads (and accept, which on Linux IS a read wait) are never timed out: a quiet listening
    /// socket must not end the server.
    @Test func readWaitsAreNotTimedOut() async throws {
        let socket = try Socket(domain: AF_INET, type: .stream)
        defer { try? socket.close() }
        let pool = WriteStallTimeoutPool(inner: NeverReadyPool(), timeout: .milliseconds(20))
        let wait = Task { try await pool.suspendSocket(socket, untilReadyFor: .read) }
        try await Task.sleep(for: .milliseconds(200))
        wait.cancel()
        let result = await wait.result
        guard case .failure(let error) = result else {
            Issue.record("a read wait must not end on its own"); return
        }
        #expect(error is CancellationError, "it ended because it was cancelled, not timed out")
    }

    @Test func theDefaultIsShorterThanTheKeepaliveVerdict() {
        let config = SessionConfig()
        #expect(config.writeStallTimeout == .seconds(30))
        #expect(config.writeStallTimeout < config.keepaliveIdleInterval + config.keepalivePingGrace)
    }
}
