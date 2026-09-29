import Foundation

/// Every piece of version-store work for one document, in ONE FIFO order, off the actors.
///
/// Keeping a version costs about 70 ms on a 5.4 MB document with images (measured in a debug
/// build; most of it `StoredVersion.make` parsing the whole document), and a write paid that on its
/// session actor BEFORE its echo went out — a delay to every push's ack. So the write only
/// ENQUEUES the job, still before it broadcasts, and everything else that touches this document's
/// versions — a subscribe's `ensureCurrent` and `delivered` hold, a `baseSaved`, a subscribe's
/// base lookup, a delete's `removeAll` — goes through the same serial queue behind it. That order
/// is what the old synchronous version got from running in the session's actor turn:
///
/// - an ack or a delivery answered at once with a `baseSaved` finds the version recorded (the
///   `setHold` is queued after the record), so it is not released as unknown;
/// - a subscribe asking for the base sees every write accepted before it;
/// - a delete's `removeAll` runs after every record queued before it, so a late record can never
///   re-create `.versions/<docId>` for a document that is gone.
///
/// Real threads (`DispatchQueue`), not the cooperative pool: the work is blocking file I/O and a
/// whole-document parse. Per document, so one large document's writes never delay another's.
/// Keyed by the CANONICAL docId the callers already use (folded here too, so that no two spellings
/// could ever get two queues). A queue is never dropped: one idle `DispatchQueue` per document
/// touched in this process's life is cheap, and dropping one could reorder work with a job
/// already queued on it.
final class VersionWork: @unchecked Sendable {
    let store: any VersionStore
    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]

    init(store: any VersionStore) {
        self.store = store
    }

    private func queue(_ docId: String) -> DispatchQueue {
        let key = docId.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let queue = queues[key] { return queue }
        // `.userInitiated`, not lower: a subscribe (itself `.userInitiated`) WAITS on this queue for
        // its base, and a lower-QoS queue under load would make it wait behind background work.
        let queue = DispatchQueue(label: "infsketch.versions.\(key)", qos: .userInitiated)
        queues[key] = queue
        return queue
    }

    /// Queue `job` and return at once.
    func enqueue(_ docId: String, _ job: @escaping @Sendable (any VersionStore) -> Void) {
        let store = self.store
        queue(docId).async { job(store) }
    }

    /// Queue `job` and wait for its answer — which therefore reflects every job queued before it.
    func run<T: Sendable>(_ docId: String, _ job: @escaping @Sendable (any VersionStore) -> T) async -> T {
        let store = self.store
        let queue = queue(docId)
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: job(store)) }
        }
    }

    /// Wait until every job queued so far for `docId` has run. For tests, which read the store
    /// directly afterwards.
    func drain(_ docId: String) async {
        await run(docId) { _ in () }
    }

    #if DEBUG
    /// Hold `docId`'s jobs back (they stay queued, in order) — so a test can line up several.
    func suspend(_ docId: String) { queue(docId).suspend() }
    func resume(_ docId: String) { queue(docId).resume() }
    #endif
}
