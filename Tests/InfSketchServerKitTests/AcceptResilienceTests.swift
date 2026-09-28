import Foundation
import Testing
import FlyingSocks
@testable import InfSketchServerKit

/// Descriptor exhaustion on `accept` used to end the process: FlyingFox rethrows it out of `run()`.
@Suite struct AcceptResilienceTests {

    private actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    @Test func acceptAndExhaustionFailuresAreTransient() {
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 24, message: "")))
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 53, message: "")))
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "CreateSocket", errno: 23, message: "")))
        #expect(AcceptResilience.isTransient(SocketError.failed(type: "Accept", errno: 10024, message: "")))
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
}
