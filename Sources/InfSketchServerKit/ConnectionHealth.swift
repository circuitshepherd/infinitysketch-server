import Foundation

/// Decides when a WebSocket peer has stopped reading. Pure: no I/O, no actor, and no clock of
/// its own — `now` is always a parameter, which is what makes the whole policy unit-testable
/// without sleeping.
///
/// **Why this exists.** `DocumentSession` already bounds each subscriber's stream
/// (`.bufferingOldest`) and disconnects on overflow, but `Connection.pump` drains that stream as
/// fast as events arrive and re-yields into the connection's unbounded `output` — so the bound
/// never engages. Bounding `output` in turn would achieve nothing: FlyingFox's `WSHandler.start`
/// re-buffers our messages into a default-policy (unbounded) `AsyncThrowingStream` before the
/// socket writer. The memory would just move one layer further down, out of reach.
///
/// The consequence is the constraint this type is designed around: **no write-completion signal
/// exists**. We cannot know that a byte reached the socket. All we can count is bytes we EMITTED
/// since the peer last proved it was alive.
///
/// **Why crossing the budget pings instead of dropping.** Emitted-bytes-without-inbound-traffic
/// is not evidence of a stall. A second device receiving another device's edits, with its own
/// user idle, sends nothing back for as long as that lasts — and that is precisely the
/// multi-device case the product exists to support. So the budget opens a question, and only
/// silence in answer to it is a verdict.
///
/// **Why a budget ping's deadline is not the flat grace.** The ping is not delivered when it is
/// decided — it is YIELDED onto the same FIFO `output` stream that already holds the backlog
/// which triggered it, and FlyingFox drains that stream strictly in order. The peer cannot even
/// SEE the question until it has drained every byte queued ahead of it, which at the moment of
/// the budget crossing is `bytesSinceProof` — up to `outboundByteBudget`, 64 MB by default.
/// Starting a flat 10 s clock at enqueue time therefore drops a perfectly healthy passive
/// receiver on a slow link for failing to answer a question it has not yet received, which is
/// exactly the client the "ask, don't drop" rule above exists to protect.
///
/// So a budget ping records how many bytes sit AHEAD of it (bytes emitted afterwards queue
/// BEHIND the ping and cannot delay it) and its deadline becomes
/// `max(pingGrace, bytesAheadOfPing / assumedMinimumDrainRate)` — at least long enough to
/// DELIVER the question, and never shorter than the ordinary grace. An idle-timer ping has no
/// backlog (`bytesAheadOfPing == 0`) and so keeps the flat grace exactly, which is right: a
/// genuine half-open socket has nothing queued to excuse its silence.
struct ConnectionHealth {
    enum DropReason: String, Equatable, Sendable {
        case unresponsive
    }

    enum Action: Equatable {
        case none
        case ping
        case drop(reason: DropReason)
    }

    private let byteBudget: Int
    private let idleInterval: Duration
    private let pingGrace: Duration
    /// Bytes per second. See the type comment: this converts the backlog queued ahead of a
    /// budget ping into the time the peer needs merely to REACH the question.
    private let assumedMinimumDrainRate: Int

    private var bytesSinceProof = 0
    private var lastProofAt: ContinuousClock.Instant
    private var pingSentAt: ContinuousClock.Instant?
    /// Bytes that were queued ahead of the outstanding ping when it was sent, and so must drain
    /// before the peer can see it. Zero for an idle-timer ping. Only meaningful while
    /// `pingSentAt != nil`; `sendPing` is the single writer of both, so they cannot disagree.
    private var bytesAheadOfPing = 0
    /// Set when `.drop` is first returned. Every later input repeats it, so a pong racing the
    /// close cannot revive a connection the server has already given up on.
    private var dropped: DropReason?

    init(
        byteBudget: Int, idleInterval: Duration, pingGrace: Duration,
        assumedMinimumDrainRate: Int, now: ContinuousClock.Instant
    ) {
        self.byteBudget = byteBudget
        self.idleInterval = idleInterval
        self.pingGrace = pingGrace
        // Clamped: a zero or negative rate would divide by zero (or compute a negative
        // allowance) in `pingDeadlineAllowance`. A misconfigured knob must not crash a
        // connection, and 1 B/s only ever makes the deadline more generous.
        self.assumedMinimumDrainRate = max(1, assumedMinimumDrainRate)
        self.lastProofAt = now
    }

    /// How long the outstanding ping may go unanswered. Integer-second granularity is deliberate:
    /// the tick that observes this runs at whole-second resolution anyway, and the quantity is a
    /// floor on delivery time, not a measurement.
    private var pingDeadlineAllowance: Duration {
        max(pingGrace, .seconds(bytesAheadOfPing / assumedMinimumDrainRate))
    }

    /// The one place `pingSentAt` and `bytesAheadOfPing` are written, so the deadline can never
    /// be computed from a backlog belonging to some earlier ping.
    private mutating func sendPing(at now: ContinuousClock.Instant, bytesAhead: Int) -> Action {
        pingSentAt = now
        bytesAheadOfPing = bytesAhead
        return .ping
    }

    mutating func noteEmitted(bytes: Int, now: ContinuousClock.Instant) -> Action {
        if let dropped { return .drop(reason: dropped) }
        bytesSinceProof += bytes
        guard bytesSinceProof > byteBudget, pingSentAt == nil else { return .none }
        // `bytesSinceProof` already includes the emission that just crossed the budget, and that
        // emission IS ahead of the ping — `Connection.emit` yields its frames before asking the
        // health machine anything. Everything emitted after this point queues behind the ping.
        return sendPing(at: now, bytesAhead: bytesSinceProof)
    }

    mutating func noteInbound(now: ContinuousClock.Instant) -> Action {
        if let dropped { return .drop(reason: dropped) }
        bytesSinceProof = 0
        lastProofAt = now
        pingSentAt = nil
        bytesAheadOfPing = 0
        return .none
    }

    mutating func tick(now: ContinuousClock.Instant) -> Action {
        if let dropped { return .drop(reason: dropped) }
        if let pingSentAt {
            guard now - pingSentAt > pingDeadlineAllowance else { return .none }
            dropped = .unresponsive
            return .drop(reason: .unresponsive)
        }
        guard now - lastProofAt > idleInterval else { return .none }
        // Same allowance rule as the budget path, and for the same reason: what a ping's deadline
        // has to cover is the time to DELIVER it, which is however many bytes sit ahead of it in
        // the FIFO — whichever path emitted it.
        //
        // It is tempting to pass 0 here on the grounds that an idle connection has an empty
        // queue. That is wrong: `lastProofAt` advances on INBOUND traffic only, so a connection
        // can be "idle" by this timer's definition while a large backlog is still draining
        // outward. Concretely, ~40 MB pushed to a slow peer never crosses the 64 MB budget, so
        // `noteEmitted` never pings; the idle timer then fires at 30 s and, with a flat 10 s
        // grace, drops a peer that is still legitimately draining — the exact defect the
        // proportional allowance exists to prevent, reached by the other door.
        //
        // The genuine half-open socket is unaffected: no traffic means `bytesSinceProof == 0`,
        // which yields the flat grace, so silence with nothing queued is still reaped promptly.
        return sendPing(at: now, bytesAhead: bytesSinceProof)
    }
}
