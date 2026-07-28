import Testing
import Foundation
@testable import InfSketchServerKit

/// `undo_last_edit`'s memory (spec 2026-07-28-agent-undo-design.md).
///
/// The test that matters most here is `theAppsOwnPushIsNotRecorded`: recording lives at the MCP
/// layer rather than in `DocumentSession.submit`, because that is shared with the app's own
/// settle-push — and recording those would make "undo the last edit" capable of reverting the
/// user's own drawing.
@Suite struct AgentEditHistoryTests {

    private func bytes(_ byte: UInt8, count: Int = 16) -> Data {
        Data(repeating: byte, count: count)
    }

    @Test func aRecordedEditCanBeReadBackAndConsumedOnce() async {
        let history = AgentEditHistory()
        await history.record(docId: "d", before: bytes(1), after: bytes(2))

        let entry = await history.mostRecent(docId: "d")
        #expect(entry?.before == bytes(1))
        #expect(entry?.after == bytes(2))

        await history.consumeMostRecent(docId: "d")
        #expect(await history.mostRecent(docId: "d") == nil)
    }

    /// Newest first: a second undo walks one step further back.
    @Test func edgesAreConsumedNewestFirst() async {
        let history = AgentEditHistory()
        await history.record(docId: "d", before: bytes(1), after: bytes(2))
        await history.record(docId: "d", before: bytes(2), after: bytes(3))

        #expect(await history.mostRecent(docId: "d")?.before == bytes(2))
        await history.consumeMostRecent(docId: "d")
        #expect(await history.mostRecent(docId: "d")?.before == bytes(1))
    }

    /// A write that changed nothing is not recorded — undoing it would be a no-op that ate the
    /// entry the agent actually wanted.
    @Test func aWriteThatChangedNothingIsNotRecorded() async {
        let history = AgentEditHistory()
        await history.record(docId: "d", before: bytes(1), after: bytes(1))
        #expect(await history.mostRecent(docId: "d") == nil)
    }

    /// History is per document, so an undo can never reach into another one.
    @Test func historyIsPerDocument() async {
        let history = AgentEditHistory()
        await history.record(docId: "a", before: bytes(1), after: bytes(2))
        #expect(await history.mostRecent(docId: "b") == nil)
    }

    @Test func deletingADocumentForgetsItsHistory() async {
        let history = AgentEditHistory()
        await history.record(docId: "d", before: bytes(1), after: bytes(2))
        await history.forget(docId: "d")
        #expect(await history.mostRecent(docId: "d") == nil)
        #expect(await history.currentByteCount() == 0)
    }

    // MARK: - bounds

    @Test func aDocumentKeepsOnlyItsMostRecentEdits() async {
        let history = AgentEditHistory(byteBudget: 1 << 20, maxEntriesPerDoc: 3)
        for i in 1...5 {
            await history.record(docId: "d", before: bytes(UInt8(i)), after: bytes(UInt8(i + 1)))
        }
        #expect(await history.entryCount(docId: "d") == 3)
        #expect(await history.mostRecent(docId: "d")?.before == bytes(5))
    }

    /// Past the budget, whole documents go — least recently written first.
    @Test func theOldestDocumentIsEvictedFirstPastTheBudget() async {
        // Each entry is 2 × 64 bytes; a 300-byte budget holds two of them, not three.
        let history = AgentEditHistory(byteBudget: 300, maxEntriesPerDoc: 8)
        await history.record(docId: "old", before: bytes(1, count: 64), after: bytes(2, count: 64))
        await history.record(docId: "mid", before: bytes(3, count: 64), after: bytes(4, count: 64))
        await history.record(docId: "new", before: bytes(5, count: 64), after: bytes(6, count: 64))

        #expect(await history.mostRecent(docId: "old") == nil, "the oldest goes first")
        #expect(await history.mostRecent(docId: "new") != nil, "the newest must survive")
        #expect(await history.currentByteCount() <= 300)
    }

    /// The document just written is never the one evicted — it is the one most likely to be
    /// undone, so dropping it to keep older history would be exactly backwards.
    @Test func theDocumentJustWrittenSurvivesEvenWhenItAloneExceedsTheBudget() async {
        let history = AgentEditHistory(byteBudget: 100, maxEntriesPerDoc: 8)
        await history.record(docId: "d", before: bytes(1, count: 200), after: bytes(2, count: 200))
        #expect(await history.mostRecent(docId: "d")?.before == bytes(1, count: 200))
    }
}
