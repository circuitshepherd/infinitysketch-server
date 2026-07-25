import Foundation
import Testing
@testable import InfSketchServerKit

/// `ConnectionHealth` decides when a WebSocket peer has stopped reading.
///
/// The problem it solves: there is NO write-completion signal anywhere below us. FlyingFox
/// drains our output stream into its own default-buffering (unbounded) AsyncThrowingStream, so
/// "bytes outstanding on the socket" is not observable. All we can count is bytes we EMITTED
/// since the peer last proved it is alive.
///
/// The load-bearing subtlety: emitted-bytes-with-no-inbound-traffic does NOT by itself mean a
/// stall. A second device receiving another device's edits, with its own user idle, sends
/// nothing back and is perfectly healthy. So crossing the budget must ASK (ping) rather than
/// drop — `aPassiveReceiverThatAnswersPingsIsNeverDropped` is the test that pins this, and it is
/// the one that would have caught a "drop on budget" implementation.
struct ConnectionHealthTests {

    private let budget = 1000
    private let idle = Duration.seconds(30)
    private let grace = Duration.seconds(10)

    private func makeHealth(now: ContinuousClock.Instant) -> ConnectionHealth {
        ConnectionHealth(byteBudget: budget, idleInterval: idle, pingGrace: grace, now: now)
    }

    @Test func emittingUnderTheBudgetDoesNothing() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.noteEmitted(bytes: 400, now: t0) == .none)
        #expect(health.noteEmitted(bytes: 400, now: t0) == .none)
    }

    @Test func crossingTheBudgetAsksRatherThanDropping() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.noteEmitted(bytes: 600, now: t0) == .none)
        #expect(health.noteEmitted(bytes: 600, now: t0) == .ping)
    }

    /// One outstanding ping at a time — further emission must not re-ping, or a large burst
    /// would flood a client that is already being asked.
    @Test func onlyOnePingIsOutstandingAtATime() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.noteEmitted(bytes: 1200, now: t0) == .ping)
        #expect(health.noteEmitted(bytes: 1200, now: t0) == .none)
        #expect(health.noteEmitted(bytes: 1200, now: t0) == .none)
    }

    /// THE case that makes "ask, don't drop" necessary. A client that receives a great deal and
    /// only ever answers pings must survive indefinitely.
    @Test func aPassiveReceiverThatAnswersPingsIsNeverDropped() {
        var now = ContinuousClock.now
        var health = makeHealth(now: now)
        for _ in 0..<50 {
            // A burst far past the budget, then the client answers the ping it triggered.
            #expect(health.noteEmitted(bytes: 5000, now: now) == .ping)
            now = now.advanced(by: .seconds(1))
            #expect(health.noteInbound(now: now) == .none)
            // Well inside the grace, and the counter is now zero again.
            #expect(health.tick(now: now.advanced(by: .seconds(2))) == .none)
            now = now.advanced(by: .seconds(2))
        }
    }

    @Test func answeringAPingResetsTheCounterSoALaterBurstCanPingAgain() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.noteEmitted(bytes: 1200, now: t0) == .ping)
        #expect(health.noteInbound(now: t0.advanced(by: .seconds(1))) == .none)
        let t2 = t0.advanced(by: .seconds(2))
        #expect(health.noteEmitted(bytes: 600, now: t2) == .none, "counter was reset")
        #expect(health.noteEmitted(bytes: 600, now: t2) == .ping)
    }

    @Test func aPingLeftUnansweredPastTheGraceDrops() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.noteEmitted(bytes: 1200, now: t0) == .ping)
        #expect(health.tick(now: t0.advanced(by: .seconds(9))) == .none, "still inside the grace")
        #expect(health.tick(now: t0.advanced(by: .seconds(11))) == .drop(reason: .unresponsive))
    }

    /// The half-open socket: no traffic in either direction. Nothing accrues bytes, so only the
    /// idle timer can notice.
    @Test func silenceWithNoTrafficAtAllStillPingsAfterTheIdleInterval() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.tick(now: t0.advanced(by: .seconds(29))) == .none)
        #expect(health.tick(now: t0.advanced(by: .seconds(31))) == .ping)
        #expect(health.tick(now: t0.advanced(by: .seconds(42))) == .drop(reason: .unresponsive))
    }

    @Test func anyInboundMessageCountsAsProofNotJustAPong() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.tick(now: t0.advanced(by: .seconds(31))) == .ping)
        #expect(health.noteInbound(now: t0.advanced(by: .seconds(32))) == .none)
        #expect(health.tick(now: t0.advanced(by: .seconds(40))) == .none, "the ping was answered")
    }

    /// Once the server has decided to close, a pong arriving in the race must not revive the
    /// connection — the drop is already in flight and the state must stay consistent with it.
    @Test func dropIsTerminalAgainstALatePong() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.noteEmitted(bytes: 1200, now: t0) == .ping)
        #expect(health.tick(now: t0.advanced(by: .seconds(11))) == .drop(reason: .unresponsive))
        #expect(health.noteInbound(now: t0.advanced(by: .seconds(12))) == .drop(reason: .unresponsive))
        #expect(health.tick(now: t0.advanced(by: .seconds(13))) == .drop(reason: .unresponsive))
        #expect(health.noteEmitted(bytes: 1, now: t0.advanced(by: .seconds(14))) == .drop(reason: .unresponsive))
    }

    /// The idle timer must not fire on a busy-but-healthy connection.
    @Test func steadyInboundTrafficNeverPings() {
        var now = ContinuousClock.now
        var health = makeHealth(now: now)
        for _ in 0..<20 {
            now = now.advanced(by: .seconds(10))
            #expect(health.noteInbound(now: now) == .none)
            #expect(health.tick(now: now) == .none)
        }
    }
}

/// The tunables live on SessionConfig beside `outboundBufferLimit` / `fetchTotalTimeout`, so
/// they can be lowered in tests and adjusted in production without a code change.
struct KeepaliveConfigTests {
    @Test func defaultsMatchTheSpec() {
        let config = SessionConfig()
        #expect(config.outboundByteBudget == 64 * 1024 * 1024)
        #expect(config.keepaliveIdleInterval == .seconds(30))
        #expect(config.keepalivePingGrace == .seconds(10))
        #expect(config.keepaliveTickInterval == .seconds(5))
    }

    @Test func theyAreOverridable() {
        let config = SessionConfig(
            outboundByteBudget: 1024,
            keepaliveIdleInterval: .milliseconds(50),
            keepalivePingGrace: .milliseconds(20),
            keepaliveTickInterval: .milliseconds(5))
        #expect(config.outboundByteBudget == 1024)
        #expect(config.keepaliveIdleInterval == .milliseconds(50))
        #expect(config.keepalivePingGrace == .milliseconds(20))
        #expect(config.keepaliveTickInterval == .milliseconds(5))
    }
}
