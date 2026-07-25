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
    /// 1000 B/s. Scaled so the ordinary bursts below (≤ 5000 bytes) stay UNDER the 10 s flat
    /// grace and therefore behave exactly as they did before the deadline became proportional —
    /// only the backlog tests, which emit tens of thousands of bytes, exercise the extension.
    private let drainRate = 1000

    private func makeHealth(now: ContinuousClock.Instant) -> ConnectionHealth {
        ConnectionHealth(
            byteBudget: budget, idleInterval: idle, pingGrace: grace,
            assumedMinimumDrainRate: drainRate, now: now)
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

    /// THE fix for "the grace window measures drain time, not liveness". A budget ping is
    /// yielded onto the SAME FIFO output stream as the backlog that triggered it, and FlyingFox
    /// drains that stream in order — so the peer cannot see the question until it has drained
    /// every byte queued ahead of it. Starting a flat 10 s clock at enqueue time drops a healthy
    /// passive receiver on a slow link for not answering something it has not yet received.
    ///
    /// 60,000 bytes at 1000 B/s is a full minute of delivery, so the deadline must be 60 s here,
    /// not 10 s.
    @Test func aBudgetPingBehindALargeBacklogGetsProportionallyLonger() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.noteEmitted(bytes: 60_000, now: t0) == .ping)
        #expect(health.tick(now: t0.advanced(by: .seconds(11))) == .none,
                "past the flat grace, but the peer has not even reached the ping yet")
        #expect(health.tick(now: t0.advanced(by: .seconds(59))) == .none,
                "still draining the 60 s of backlog queued ahead of the ping")
        #expect(health.tick(now: t0.advanced(by: .seconds(61))) == .drop(reason: .unresponsive),
                "the backlog has had time to drain; silence now is a verdict")
    }

    /// The extension must not leak into the half-open-socket case. An idle-timer ping has nothing
    /// queued ahead of it, so there is no delivery time to excuse the silence — it keeps the flat
    /// grace exactly, which is what makes a slept device reapable in bounded time.
    @Test func anIdlePingKeepsTheFlatGraceRegardlessOfDrainRate() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.tick(now: t0.advanced(by: .seconds(31))) == .ping)
        #expect(health.tick(now: t0.advanced(by: .seconds(40))) == .none, "inside the 10 s grace")
        #expect(health.tick(now: t0.advanced(by: .seconds(42))) == .drop(reason: .unresponsive))
    }

    /// The same defect the proportional allowance exists to prevent, reached through the IDLE
    /// door instead of the budget one — the residual hole an independent review of the first fix
    /// flagged.
    ///
    /// `lastProofAt` advances on inbound traffic only, so a connection is "idle" by that timer's
    /// definition even while a large backlog is still draining outward. Emit UNDER the budget
    /// (so `noteEmitted` never pings), then let the idle timer fire: its ping is queued behind
    /// those bytes exactly like a budget ping would be, so it must get the same delivery
    /// allowance. Passing 0 here would drop a peer that is still legitimately draining.
    @Test func anIdlePingBehindABacklogAlsoGetsTheProportionalAllowance() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        // 900 B is under the 1000 B budget, so no budget ping — but at 1000 B/s it needs ~0.9 s
        // to reach the peer. Scale it up to something the flat grace cannot absorb:
        #expect(health.noteEmitted(bytes: 900, now: t0) == .none, "under budget: no budget ping")
        #expect(health.noteEmitted(bytes: 60_000, now: t0) == .ping, "budget crossed by the second emission")
        #expect(health.noteInbound(now: t0.advanced(by: .seconds(1))) == .none, "peer answers; state resets")

        // Now the real shape: emit a large backlog that stays UNDER the budget, so only the idle
        // timer can fire. 999 B < 1000 B budget.
        var idleHealth = ConnectionHealth(
            byteBudget: 1_000_000, idleInterval: idle, pingGrace: grace,
            assumedMinimumDrainRate: drainRate, now: t0)
        #expect(idleHealth.noteEmitted(bytes: 60_000, now: t0) == .none, "well under the 1 MB budget")
        #expect(idleHealth.tick(now: t0.advanced(by: .seconds(31))) == .ping, "idle timer fires")
        // 60_000 B at 1000 B/s = 60 s of delivery time, far past the 10 s flat grace.
        #expect(idleHealth.tick(now: t0.advanced(by: .seconds(60))) == .none,
                "still delivering the ping through a 60 s backlog")
        #expect(idleHealth.tick(now: t0.advanced(by: .seconds(95))) == .drop(reason: .unresponsive))
    }

    /// A peer that DOES answer inside its (extended) window resets normally — the proportional
    /// deadline only ever postpones the verdict, it never changes what proof of life means.
    @Test func answeringABudgetPingInsideTheProportionalWindowResetsNormally() {
        let t0 = ContinuousClock.now
        var health = makeHealth(now: t0)
        #expect(health.noteEmitted(bytes: 60_000, now: t0) == .ping)
        // Answers at 40 s: far past the flat grace, comfortably inside the 60 s delivery window.
        #expect(health.noteInbound(now: t0.advanced(by: .seconds(40))) == .none)
        #expect(health.tick(now: t0.advanced(by: .seconds(45))) == .none, "the ping was answered")
        // And the next burst is measured from scratch — the previous backlog is not carried over.
        #expect(health.noteEmitted(bytes: 600, now: t0.advanced(by: .seconds(46))) == .none,
                "counter was reset")
        #expect(health.noteEmitted(bytes: 600, now: t0.advanced(by: .seconds(46))) == .ping)
        #expect(health.tick(now: t0.advanced(by: .seconds(58))) == .drop(reason: .unresponsive),
                "1200 bytes buys only the flat grace, so this one drops at 10 s")
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
        #expect(config.assumedMinimumDrainRate == 1024 * 1024)
    }

    @Test func theyAreOverridable() {
        let config = SessionConfig(
            outboundByteBudget: 1024,
            keepaliveIdleInterval: .milliseconds(50),
            keepalivePingGrace: .milliseconds(20),
            keepaliveTickInterval: .milliseconds(5),
            assumedMinimumDrainRate: 4096)
        #expect(config.outboundByteBudget == 1024)
        #expect(config.keepaliveIdleInterval == .milliseconds(50))
        #expect(config.keepalivePingGrace == .milliseconds(20))
        #expect(config.keepaliveTickInterval == .milliseconds(5))
        #expect(config.assumedMinimumDrainRate == 4096)
    }
}
