import Foundation

/// Debounces MCP `notifications/resources/updated` per (session, doc) pair.
///
/// Pure state machine — the caller owns clocks and timers; this type just
/// decides. A `.notify` command means: send the notification to each listed
/// session NOW and start a per-(session, doc) cooldown timer of `minInterval`;
/// when that timer fires, call `cooldownEnded`, which returns `.notify` iff an
/// update arrived during the cooldown (trailing edge).
struct NotificationDebouncer {
    static let minInterval: Duration = .milliseconds(500)

    enum Command: Equatable {
        case notify(sessions: [String])
        case none
    }

    /// docId → sessions subscribed to that doc. Keys with no sessions are removed.
    private(set) var subscriptions: [String: Set<String>] = [:]

    /// session → (docId → dirty). An entry exists iff that (session, doc) pair
    /// is currently cooling; `true` means an update arrived during the cooldown,
    /// so a trailing notify is owed at `cooldownEnded`. Entries are deleted —
    /// never reset — when the pair stops cooling or unsubscribes, so storage
    /// stays bounded by the live cooldowns.
    private(set) var cooldownState: [String: [String: Bool]] = [:]

    mutating func subscribe(session: String, docId: String) {
        subscriptions[docId, default: []].insert(session)
    }

    mutating func unsubscribe(session: String, docId: String) {
        subscriptions[docId]?.remove(session)
        if subscriptions[docId]?.isEmpty == true {
            subscriptions[docId] = nil
        }
        clearCooldown(session: session, docId: docId)
    }

    mutating func unsubscribeAll(session: String) {
        for docId in Array(subscriptions.keys) {
            subscriptions[docId]?.remove(session)
            if subscriptions[docId]?.isEmpty == true {
                subscriptions[docId] = nil
            }
        }
        cooldownState[session] = nil
    }

    mutating func docUpdated(docId: String) -> Command {
        guard let sessions = subscriptions[docId], !sessions.isEmpty else {
            return .none
        }

        var sessionsToNotify: [String] = []
        for session in sessions {
            if cooldownState[session]?[docId] != nil {
                // Cooling: mark dirty so the trailing edge notifies.
                cooldownState[session]?[docId] = true
            } else {
                // Not cooling: notify now and start a cooldown.
                cooldownState[session, default: [:]][docId] = false
                sessionsToNotify.append(session)
            }
        }

        return sessionsToNotify.isEmpty ? .none : .notify(sessions: sessionsToNotify.sorted())
    }

    mutating func cooldownEnded(session: String, docId: String) -> Command {
        guard let dirty = cooldownState[session]?[docId] else {
            return .none
        }
        guard subscriptions[docId]?.contains(session) == true else {
            // The pair unsubscribed mid-cooldown; forget the stale entry.
            clearCooldown(session: session, docId: docId)
            return .none
        }

        if dirty {
            // Trailing notify: clear dirty and restart the cooldown.
            cooldownState[session]?[docId] = false
            return .notify(sessions: [session])
        }
        // Quiet cooldown: the pair is no longer cooling.
        clearCooldown(session: session, docId: docId)
        return .none
    }

    private mutating func clearCooldown(session: String, docId: String) {
        cooldownState[session]?[docId] = nil
        if cooldownState[session]?.isEmpty == true {
            cooldownState[session] = nil
        }
    }
}
