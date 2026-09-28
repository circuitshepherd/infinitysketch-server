import Foundation
import Testing
import FlyingSocks
import FlyingFox
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import InfSketchServerKit

/// Descriptor exhaustion on `accept` used to end the process: FlyingFox rethrows it out of `run()`.
@Suite struct AcceptResilienceTests {

    private actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    @Test func acceptAndExhaustionFailuresAreTransient() {
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 24, message: "")))
        #if canImport(Darwin)
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 53, message: "")))
        #endif
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "CreateSocket", errno: 23, message: "")))
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 10024, message: "")))
    }

    /// Transience is the ERRNO, not the call: an `Accept` failure that is not a shortage (EBADF
    /// from a closed listener, EINVAL) would otherwise be retried forever (round 5, item 4).
    @Test func anAcceptFailureThatIsNotAShortageIsNotTransient() {
        #expect(!AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 9, message: "")))
        #expect(!AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 22, message: "")))
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 12, message: "")))
        #if canImport(Darwin)
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 55, message: "")))
        #elseif canImport(Glibc)
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 103, message: "")))
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 105, message: "")))
        #endif
    }

    /// A port already in use is a startup error the caller must report, never a retry loop.
    @Test func aBindFailureIsNotTransient() {
        #expect(!AcceptResilience.isTransient(SocketError.failed(type: "Bind", errno: 48, message: "")))
        #expect(!AcceptResilience.isTransient(SocketError.disconnected))
        #expect(!AcceptResilience.isTransient(CancellationError()))
    }

    @Test func aTransientFailureListensAgain() async throws {
        let calls = Counter()
        try await AcceptResilience.run(delays: [.zero], shouldStop: { false }) {
            if await calls.next() < 3 {
                throw SocketError.failed(type: "Accept", errno: 24, message: "Too many open files")
            }
        }
        #expect(await calls.value == 3)
    }

    @Test func aNonTransientFailureIsRethrownAtOnce() async {
        let calls = Counter()
        await #expect(throws: SocketError.self) {
            try await AcceptResilience.run(delays: [.zero], shouldStop: { false }) {
                _ = await calls.next()
                throw SocketError.failed(type: "Bind", errno: 48, message: "Address already in use")
            }
        }
        #expect(await calls.value == 1)
    }

    /// `stop()` closes the listening socket, which surfaces as an accept failure — that one must
    /// end the loop, not restart the server the caller just stopped.
    @Test func aStoppedServerIsNotRestarted() async {
        let calls = Counter()
        await #expect(throws: SocketError.self) {
            try await AcceptResilience.run(delays: [.zero], shouldStop: { true }) {
                _ = await calls.next()
                throw SocketError.failed(type: "Accept", errno: 9, message: "Bad file descriptor")
            }
        }
        #expect(await calls.value == 1)
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test func theSoftDescriptorLimitIsRaisedNotLowered() throws {
        let result = try #require(AcceptResilience.raiseFileDescriptorLimit())
        #expect(result.new >= result.old)
        #expect(result.new >= min(1024, result.old), "the soft limit may only go up")
    }
    #endif

    // MARK: - on a real server

    /// A pool whose FIRST wait for an incoming connection fails the way descriptor exhaustion
    /// does, then behaves normally. The accept loop's first wait is on the listening socket, before
    /// any client exists, so the failure lands exactly where EMFILE would.
    private final class AcceptFailsOncePool: AsyncSocketPool, @unchecked Sendable {
        let inner: any AsyncSocketPool = HTTPServer.defaultPool()
        private let lock = NSLock()
        private var failed = 0
        var failures: Int { lock.lock(); defer { lock.unlock() }; return failed }

        func prepare() async throws { try await inner.prepare() }
        func run() async throws { try await inner.run() }
        func suspendSocket(_ socket: Socket, untilReadyFor events: Socket.Events) async throws {
            if events != .write {
                let fail: Bool = { lock.lock(); defer { lock.unlock() }
                    if failed == 0 { failed = 1; return true }; return false }()
                if fail { throw SocketError.failed(type: "Accept", errno: 24, message: "Too many open files") }
            }
            try await inner.suspendSocket(socket, untilReadyFor: events)
        }
    }

    /// A free TCP port: listening again binds the configured port, and port 0 would come back on
    /// a different one.
    private func freePort() throws -> UInt16 {
        let socket = try Socket(domain: AF_INET6)
        try socket.bind(to: sockaddr_in6.inet6(port: 0))
        guard case .ip6(_, let port) = try socket.sockname() else { throw SocketError.disconnected }
        try socket.close()
        return port
    }

    /// End to end (round 5, item 4): an `accept` that fails with EMFILE on a REAL `HTTPServer`
    /// does not end `run()` — the server listens again and answers the next request.
    @Test func aRealServerListensAgainAfterAnAcceptFailure() async throws {
        let pool = AcceptFailsOncePool()
        let port = try freePort()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("accept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = InfSketchServer(port: port, store: DirectoryDocumentStore(directory: dir), socketPool: pool)
        let task = Task { try await server.run() }
        defer { task.cancel() }

        let deadline = ContinuousClock.now + .seconds(10)
        var answered = false
        while ContinuousClock.now < deadline {
            if pool.failures == 1,
               let (_, response) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/docs")!),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                answered = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(pool.failures == 1, "the injected accept failure happened")
        #expect(answered, "the server listened again and answered after it")
        await server.stop()
        _ = await task.result
    }
}
