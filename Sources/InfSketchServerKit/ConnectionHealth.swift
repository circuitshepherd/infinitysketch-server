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

    private var bytesSinceProof = 0
    private var lastProofAt: ContinuousClock.Instant
    private var pingSentAt: ContinuousClock.Instant?
    /// Set when `.drop` is first returned. Every later input repeats it, so a pong racing the
    /// close cannot revive a connection the server has already given up on.
    private var dropped: DropReason?

    init(
        byteBudget: Int, idleInterval: Duration, pingGrace: Duration,
        now: ContinuousClock.Instant
    ) {
        self.byteBudget = byteBudget
        self.idleInterval = idleInterval
        self.pingGrace = pingGrace
        self.lastProofAt = now
    }

    mutating func noteEmitted(bytes: Int, now: ContinuousClock.Instant) -> Action {
        if let dropped { return .drop(reason: dropped) }
        bytesSinceProof += bytes
        guard bytesSinceProof > byteBudget, pingSentAt == nil else { return .none }
        pingSentAt = now
        return .ping
    }

    mutating func noteInbound(now: ContinuousClock.Instant) -> Action {
        if let dropped { return .drop(reason: dropped) }
        bytesSinceProof = 0
        lastProofAt = now
        pingSentAt = nil
        return .none
    }

    mutating func tick(now: ContinuousClock.Instant) -> Action {
        if let dropped { return .drop(reason: dropped) }
        if let pingSentAt {
            guard now - pingSentAt > pingGrace else { return .none }
            dropped = .unresponsive
            return .drop(reason: .unresponsive)
        }
        guard now - lastProofAt > idleInterval else { return .none }
        pingSentAt = now
        return .ping
    }
}
