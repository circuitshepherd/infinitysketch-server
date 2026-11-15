import Foundation

/// "An agent is at work" — what the server tells its status subscribers so that the devices keep
/// their screens on, and what it keeps its own host awake for.
///
/// An agent's drawing needs a device that is RUNNING (only the app can author strokes) and a host
/// that is awake; an iPad that locks itself two minutes into an agent's session, or a host that
/// goes to standby under it, ends the session with `noDeviceAvailable`.
///
/// It rides the status channel as a `StatusPayload` with this `kind` and an empty `docId`, which
/// is why it needed no wire-version change: an app that does not know the kind ignores it and
/// simply does not stay awake. Both sides read the kind and the window from here.
public enum AgentWorkSignal {
    /// The `StatusPayload.kind` of the announcement.
    public static let statusKind = "agentWork"

    /// How long after an agent's LAST tool call the work counts as going on. Agents pause — the
    /// model thinks, a person reads the result and answers — so this is minutes, not seconds.
    /// A device holds its screen for this long from each announcement it hears.
    public static let window: TimeInterval = 600
}
