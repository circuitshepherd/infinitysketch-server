import Foundation

/// Bounded per-document history of what AGENT tool calls did, so `undo_last_edit` can take one
/// back (spec `2026-07-28-agent-undo-design.md`).
///
/// **Only agent writes are recorded, and that is the load-bearing part.** `DocumentSession.submit`
/// is shared with the APP's own settle-push; recording there would make "undo the last edit"
/// capable of reverting the user's own drawing. Recording lives at the MCP layer instead, so agent
/// scope holds by construction rather than by a flag someone can get wrong later.
///
/// Storage mirrors `ServerMirror.retainedBases`, this codebase's existing bounded-history pattern:
/// most-recent-first per document, evicted past a byte budget. Documents here are megabytes (a
/// bundled example is 5.5 MB), so the budget is what keeps this honest — losing old history is not
/// a correctness problem, it only means an older undo answers `nothingToUndo`.
///
/// It is deliberately NOT held on `DocumentSession`: a session is torn down after its grace period,
/// and undo has to survive a document being closed and reopened between the write and the regret.
actor AgentEditHistory {
    /// One recorded agent write. `before` is what the document held when the tool read it (the
    /// same bytes it passes as its byte-CAS expectation, so nothing extra is read or computed);
    /// `after` is what the write produced.
    ///
    /// `id` names this entry, so the undo that took it back consumes exactly it — "drop the most
    /// recent" would drop a write that landed while the undo was in flight instead.
    ///
    /// A LIVE-SELECTION marker (`isLiveSelectionChange`, empty bytes) stands for an agent change
    /// that committed in the device's own session — `transform_selection` and its siblings —
    /// which never passes the server's recording seam and so has no bytes here. It exists so an
    /// undo after one refuses instead of reversing the OLDER write beneath it (review finding 23).
    struct Entry: Sendable, Equatable {
        let id: UUID
        let before: Data
        let after: Data
        let isLiveSelectionChange: Bool

        init(before: Data, after: Data) {
            self.id = UUID()
            self.before = before
            self.after = after
            self.isLiveSelectionChange = false
        }

        private init(liveSelectionChange: Void) {
            self.id = UUID()
            self.before = Data()
            self.after = Data()
            self.isLiveSelectionChange = true
        }

        static func liveSelectionChange() -> Entry { Entry(liveSelectionChange: ()) }

        var byteCount: Int { before.count + after.count }
    }

    /// Newest LAST, so appending and popping are both cheap at the end.
    private var entries: [String: [Entry]] = [:]
    /// docIds in least-recently-written order (most recent last), for eviction.
    private var order: [String] = []
    private var totalBytes = 0

    private let byteBudget: Int
    private let maxEntriesPerDoc: Int

    /// 64 MB and 8 entries per document: enough for a burst of agent edits on a large document,
    /// small enough to be invisible next to the documents a running server already holds. Both are
    /// injectable so tests can drive eviction without allocating megabytes.
    init(byteBudget: Int = 64 * 1024 * 1024, maxEntriesPerDoc: Int = 8) {
        self.byteBudget = byteBudget
        self.maxEntriesPerDoc = maxEntriesPerDoc
    }

    /// Record what one agent tool call changed. A write that changed nothing is not recorded —
    /// undoing it would be a no-op that consumed the entry the agent actually wanted.
    func record(docId: String, before: Data, after: Data) {
        guard before != after else { return }
        append(Entry(before: before, after: after), docId: docId)
    }

    /// Record that an agent changed the document through the user's LIVE selection. There are no
    /// bytes to restore — the change was committed on the device — so this is a barrier: an undo
    /// that meets it refuses rather than reach past it to an older write.
    func recordLiveSelectionChange(docId: String) {
        // One barrier is as good as several; don't let a burst of transforms push real history out.
        if entries[docId]?.last?.isLiveSelectionChange == true { return }
        append(.liveSelectionChange(), docId: docId)
    }

    private func append(_ entry: Entry, docId: String) {
        var docEntries = entries[docId] ?? []
        docEntries.append(entry)
        while docEntries.count > maxEntriesPerDoc {
            totalBytes -= docEntries.removeFirst().byteCount
        }
        totalBytes += entry.byteCount
        entries[docId] = docEntries

        order.removeAll { $0 == docId }
        order.append(docId)
        evictIfNeeded(keeping: docId)
    }

    /// The most recent recorded write for `docId`, without consuming it — so a caller can decide
    /// which path to take (direct restore or merge) before committing to either.
    func mostRecent(docId: String) -> Entry? {
        entries[docId]?.last
    }

    /// Drop the entry an undo took back, once that undo has actually landed. Kept separate from
    /// `mostRecent` so a failed undo (a rejected write, an unreachable device) leaves the history
    /// intact and the agent can try again. By id: a write recorded while the undo was in flight is
    /// now the most recent, and it is not the one that was undone.
    func consume(docId: String, id: UUID) {
        guard var docEntries = entries[docId],
              let index = docEntries.firstIndex(where: { $0.id == id }) else { return }
        totalBytes -= docEntries.remove(at: index).byteCount
        if docEntries.isEmpty {
            entries.removeValue(forKey: docId)
            order.removeAll { $0 == docId }
        } else {
            entries[docId] = docEntries
        }
    }

    /// Everything recorded for a document is dropped when it is deleted — the bytes are gone, and
    /// an undo that resurrected a deleted document would be a surprise, not a service.
    func forget(docId: String) {
        guard let docEntries = entries.removeValue(forKey: docId) else { return }
        totalBytes -= docEntries.reduce(0) { $0 + $1.byteCount }
        order.removeAll { $0 == docId }
    }

    /// Test seam: how much is held right now.
    func currentByteCount() -> Int { totalBytes }
    func entryCount(docId: String) -> Int { entries[docId]?.count ?? 0 }

    /// Evict whole documents, least-recently-written first, until the budget is met. `keeping` is
    /// never evicted: the write that just happened is the one most likely to be undone, and
    /// dropping it to make room for older history would be exactly backwards.
    private func evictIfNeeded(keeping: String) {
        while totalBytes > byteBudget, let victim = order.first(where: { $0 != keeping }) {
            forget(docId: victim)
        }
        // A single document larger than the whole budget keeps only its newest entry rather than
        // nothing at all — one undo is the point of the feature.
        while totalBytes > byteBudget, var docEntries = entries[keeping], docEntries.count > 1 {
            totalBytes -= docEntries.removeFirst().byteCount
            entries[keeping] = docEntries
        }
    }
}
