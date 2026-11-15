import Foundation

/// Notices that this process did not run for a while — the host's standby, or a debugger's stop —
/// from the gap between two of its own ticks. Pure: `now` is a parameter.
///
/// `ContinuousClock` counts the time the host was asleep, so a tick that comes far later than
/// the interval says how long that was. The same reading as `ConnectionHealth`'s, which restarts
/// each connection's deadlines; this one exists so the LOG can say it, once, for the server.
struct SuspensionWatch {
    private let threshold: Duration
    private var lastTickAt: ContinuousClock.Instant

    /// A gap of more than three intervals (at least a second) counts — the factor
    /// `ConnectionHealth` uses, for the same reason: an ordinary late tick must not.
    init(interval: Duration, now: ContinuousClock.Instant) {
        self.threshold = max(interval * 3, .seconds(1))
        self.lastTickAt = now
    }

    /// The length of the gap that just ended, when it was a suspension; nil for an ordinary tick.
    mutating func tick(now: ContinuousClock.Instant) -> Duration? {
        defer { lastTickAt = now }
        let gap = now - lastTickAt
        return gap > threshold ? gap : nil
    }
}
