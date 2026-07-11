import Foundation

struct NotificationDebouncer {
    static let minInterval: Duration = .milliseconds(500)

    enum Command: Equatable {
        case notify(sessions: [String])
        case none
    }

    private struct State: Equatable {
        var cooling: Bool = false
        var dirty: Bool = false
    }

    // subscriptions: maps docId -> Set<session>
    private var subscriptions: [String: Set<String>] = [:]

    // cooldownState: maps (session, docId) -> State
    private var cooldownState: [String: [String: State]] = [:]

    mutating func subscribe(session: String, docId: String) {
        if subscriptions[docId] == nil {
            subscriptions[docId] = []
        }
        subscriptions[docId]?.insert(session)
    }

    mutating func unsubscribe(session: String, docId: String) {
        subscriptions[docId]?.remove(session)
    }

    mutating func unsubscribeAll(session: String) {
        for docId in subscriptions.keys {
            subscriptions[docId]?.remove(session)
        }
    }

    mutating func docUpdated(docId: String) -> Command {
        let subscribedSessions = subscriptions[docId] ?? []
        guard !subscribedSessions.isEmpty else {
            return .none
        }

        var sessionsToNotify: [String] = []

        for session in subscribedSessions {
            let state = cooldownState[session]?[docId] ?? State()

            if state.cooling {
                // Mark as dirty but don't notify
                if cooldownState[session] == nil {
                    cooldownState[session] = [:]
                }
                cooldownState[session]?[docId] = State(cooling: true, dirty: true)
            } else {
                // Not cooling, so notify and start cooling
                sessionsToNotify.append(session)
                if cooldownState[session] == nil {
                    cooldownState[session] = [:]
                }
                cooldownState[session]?[docId] = State(cooling: true, dirty: false)
            }
        }

        if sessionsToNotify.isEmpty {
            return .none
        }

        let sortedSessions = sessionsToNotify.sorted()
        return .notify(sessions: sortedSessions)
    }

    mutating func cooldownEnded(session: String, docId: String) -> Command {
        guard let state = cooldownState[session]?[docId] else {
            return .none
        }

        if state.dirty {
            // Trailing notify: clear dirty, mark cooling again, return notify
            cooldownState[session]?[docId] = State(cooling: true, dirty: false)
            return .notify(sessions: [session])
        } else {
            // Quiet cooldown: just clear cooling state
            cooldownState[session]?[docId] = State(cooling: false, dirty: false)
            return .none
        }
    }
}
