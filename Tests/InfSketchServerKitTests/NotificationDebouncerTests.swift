import Foundation
import Testing
@testable import InfSketchServerKit

@Suite struct NotificationDebouncerTests {
    @Test func firstUpdateNotifiesAllSubscribedSessions() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "doc")
        d.subscribe(session: "s2", docId: "doc")
        d.subscribe(session: "s3", docId: "other")
        #expect(d.docUpdated(docId: "doc") == .notify(sessions: ["s1", "s2"]))
    }
    @Test func updatesDuringCooldownCoalesceToTrailingEdge() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "doc")
        _ = d.docUpdated(docId: "doc")                       // notify + cooldown starts
        #expect(d.docUpdated(docId: "doc") == NotificationDebouncer.Command.none)
        #expect(d.docUpdated(docId: "doc") == NotificationDebouncer.Command.none)
        #expect(d.cooldownEnded(session: "s1", docId: "doc") == .notify(sessions: ["s1"]))
    }
    @Test func quietCooldownEndsSilently() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "doc")
        _ = d.docUpdated(docId: "doc")
        #expect(d.cooldownEnded(session: "s1", docId: "doc") == NotificationDebouncer.Command.none)
    }
    @Test func unsubscribeStopsNotifications() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "doc")
        d.unsubscribe(session: "s1", docId: "doc")
        #expect(d.docUpdated(docId: "doc") == NotificationDebouncer.Command.none)
    }
    @Test func unsubscribeAllDropsEverySubscription() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "a")
        d.subscribe(session: "s1", docId: "b")
        d.unsubscribeAll(session: "s1")
        #expect(d.docUpdated(docId: "a") == NotificationDebouncer.Command.none)
        #expect(d.docUpdated(docId: "b") == NotificationDebouncer.Command.none)
    }
    @Test func trailingNotifyRestartsCooldown() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "doc")
        _ = d.docUpdated(docId: "doc")
        _ = d.docUpdated(docId: "doc")                        // dirty
        _ = d.cooldownEnded(session: "s1", docId: "doc")      // trailing notify → cooldown again
        #expect(d.docUpdated(docId: "doc") == NotificationDebouncer.Command.none)   // still cooling
        #expect(d.cooldownEnded(session: "s1", docId: "doc") == .notify(sessions: ["s1"]))
    }
    @Test func notifiedSessionListIsSortedForDeterminism() {
        var d = NotificationDebouncer()
        d.subscribe(session: "zz", docId: "doc")
        d.subscribe(session: "aa", docId: "doc")
        #expect(d.docUpdated(docId: "doc") == .notify(sessions: ["aa", "zz"]))
    }
    @Test func resubscribeAfterUnsubscribeNotifiesImmediately() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "doc")
        _ = d.docUpdated(docId: "doc")                        // notify + cooldown starts
        d.unsubscribe(session: "s1", docId: "doc")
        d.subscribe(session: "s1", docId: "doc")              // fresh subscription — no stale cooldown
        #expect(d.docUpdated(docId: "doc") == .notify(sessions: ["s1"]))
    }
    @Test func unsubscribeDuringCooldownSuppressesTrailingNotify() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "doc")
        _ = d.docUpdated(docId: "doc")                        // notify + cooldown starts
        _ = d.docUpdated(docId: "doc")                        // dirty
        d.unsubscribe(session: "s1", docId: "doc")
        #expect(d.cooldownEnded(session: "s1", docId: "doc") == NotificationDebouncer.Command.none)
    }
    @Test func unsubscribeAllLeavesNoStoredState() {
        var d = NotificationDebouncer()
        d.subscribe(session: "s1", docId: "a")
        d.subscribe(session: "s1", docId: "b")
        _ = d.docUpdated(docId: "a")                          // cooldown entry for (s1, a)
        _ = d.docUpdated(docId: "b")                          // cooldown entry for (s1, b)
        d.unsubscribeAll(session: "s1")
        #expect(d.cooldownState["s1"] == nil)
        #expect(d.subscriptions["a"] == nil)
        #expect(d.subscriptions["b"] == nil)
    }
}
