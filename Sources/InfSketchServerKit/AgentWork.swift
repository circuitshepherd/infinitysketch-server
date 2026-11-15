import Foundation
import InfSketchWire

/// Keeps the machine this server runs on from its idle standby. Injected, because the real one
/// changes the power state of whatever machine runs it — the tests' machine included.
public protocol HostAwake: Sendable {
    func hold()
    func release()
}

/// Holds nothing: tests, and `--no-keep-awake`.
public struct NoHostAwake: HostAwake {
    public init() {}
    public func hold() {}
    public func release() {}
}

/// When agents last worked, and whether the devices need telling. Pure: `now` is a parameter.
struct AgentWorkPolicy {
    let window: Duration
    /// The devices are told at most this often while the work goes on — a drawing agent calls
    /// several tools a second.
    let announceInterval: Duration
    private(set) var lastCallAt: ContinuousClock.Instant?
    private var lastAnnouncedAt: ContinuousClock.Instant?

    init(window: Duration, announceInterval: Duration) {
        self.window = window
        self.announceInterval = announceInterval
    }

    /// The work ends a window after the LAST call.
    var endsAt: ContinuousClock.Instant? { lastCallAt?.advanced(by: window) }

    func isCurrent(now: ContinuousClock.Instant) -> Bool {
        endsAt.map { now < $0 } ?? false
    }

    /// An agent called a tool. Returns whether the devices are to be told now.
    mutating func noteCall(now: ContinuousClock.Instant) -> Bool {
        lastCallAt = now
        if let lastAnnouncedAt, now - lastAnnouncedAt <= announceInterval { return false }
        lastAnnouncedAt = now
        return true
    }
}

/// "An agent is at work": a tool call within the last `window` (`AgentWorkSignal`). While it
/// holds, the host is kept awake and the status subscribers are told, so the devices keep their
/// screens on.
///
/// Fed by EVERY tool call (`MCPAdapter.handleCallTool`), reads included: an agent that is
/// looking at a drawing is about to change it. Nothing a device does feeds it — a person drawing
/// keeps their own device awake by touching it.
public actor AgentWork {
    private var policy: AgentWorkPolicy
    private let hostAwake: any HostAwake
    private let announce: @Sendable () async -> Void
    private var holding = false

    public init(
        window: Duration = .seconds(AgentWorkSignal.window),
        announceInterval: Duration = .seconds(30),
        hostAwake: any HostAwake = NoHostAwake(),
        announce: @escaping @Sendable () async -> Void
    ) {
        self.policy = AgentWorkPolicy(window: window, announceInterval: announceInterval)
        self.hostAwake = hostAwake
        self.announce = announce
    }

    /// Whether a device that connects NOW is to be told (it missed the announcement).
    public var isCurrent: Bool { policy.isCurrent(now: .now) }

    public func noteToolCall() async {
        let tell = policy.noteCall(now: .now)
        if !holding {
            holding = true
            hostAwake.hold()
            ServerLog.timed("[agent-work] started")
            Task { await self.releaseWhenTheWorkEnds() }
        }
        if tell { await announce() }
    }

    /// Sleeps to the end of the window, again for as long as calls keep moving it. The check
    /// that ends the loop and the release run in ONE actor turn, so a call cannot land between
    /// them and be left unheld. `ContinuousClock` counts a standby the host took anyway (a
    /// closed lid), so the work is over when it wakes.
    private func releaseWhenTheWorkEnds() async {
        while let end = policy.endsAt, ContinuousClock.now < end {
            try? await Task.sleep(until: end, clock: .continuous)
        }
        holding = false
        hostAwake.release()
        ServerLog.timed("[agent-work] ended: no tool call for \(policy.window)")
    }
}
