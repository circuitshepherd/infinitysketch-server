import Foundation
import InfSketchWire

public struct LiveDocInfo: Sendable, Equatable, Codable {
    public var seq: Int
    public var subscriberCount: Int
    public init(seq: Int, subscriberCount: Int) {
        self.seq = seq
        self.subscriberCount = subscriberCount
    }
}

/// M2c-1: what the server knows about a document from a CONNECTED device's advertisement —
/// metadata + thumbnail + the set of devices that hold it. Purely live: it is rebuilt from
/// advertisements and pruned on disconnect, and is NEVER written to disk (the server's durable
/// state is content documents only). All holders are equal; any of them may serve a fetch.
public struct LiveDocEntry: Sendable, Equatable {
    public var name: String
    public var sizeBytes: Int
    public var modifiedAt: Date
    public var thumbnail: Data?
    public var holders: Set<String>
}

/// Registry of live DocumentSessions. Sole entry point for subscribe /
/// unsubscribe / submit, so subscriber counting and grace teardown are
/// serialized on one actor. Also fans out server-status events.
public actor SessionManager {
    private let store: any DocumentStore
    private let config: SessionConfig
    private var sessions: [String: DocumentSession] = [:]
    private var tokenDocs: [UUID: String] = [:]
    private var counts: [String: Int] = [:]
    private var tokenWatchDocs: [UUID: String] = [:]
    private var watcherCounts: [String: Int] = [:]
    private var graceTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var statusSubscribers: [UUID: AsyncStream<ServerMessage>.Continuation] = [:]
    /// docId → live advertisement entry. In-memory only (see LiveDocEntry).
    private var liveIndex: [String: LiveDocEntry] = [:]
    /// M2c-1: pulls one document's bytes from ONE named holder. Injected by InfSketchServer
    /// (which routes it to DeviceCommandBroker.requestProvideContent); tests inject a fake.
    /// Nil until wired — a nil provider makes a content-less subscribe behave exactly as before.
    private var contentProvider: (@Sendable (String, String) async throws -> Data)?
    /// In-flight fetches, keyed by docId, so concurrent subscribers coalesce onto ONE pull
    /// instead of each hitting a holder (the broker would reject the second with requestInFlight).
    private var inFlightFetches: [String: Task<Data, Error>] = [:]

    public init(store: any DocumentStore, config: SessionConfig = SessionConfig()) {
        self.store = store
        self.config = config
    }

    public func setContentProvider(_ provider: @escaping @Sendable (String, String) async throws -> Data) {
        contentProvider = provider
    }

    public func subscribe(docId: String, createIfMissing: Bool = false) async throws -> SubscribeResult {
        graceTasks.removeValue(forKey: docId)?.task.cancel()
        let session: DocumentSession
        if let existing = sessions[docId] {
            session = existing
        } else {
            let opened: DocumentSession
            do {
                opened = try DocumentSession(docId: docId, store: store, bufferLimit: config.outboundBufferLimit)
            } catch DocumentStoreError.notFound where createIfMissing {
                // Mirror clients push docs the server has never seen: open an
                // in-memory empty session; the first op persists real bytes.
                opened = DocumentSession(docId: docId, store: store,
                                         bufferLimit: config.outboundBufferLimit, bytes: Data())
            } catch DocumentStoreError.notFound {
                // M2c-1: the server holds no bytes, but a connected device does — pull them from
                // any holder, PERSIST them (the doc is now an ordinary content doc, and it stays),
                // then open the session normally. With no holders/provider this rethrows notFound.
                let bytes = try await fetchFromHolders(docId: docId)
                // Re-check BEFORE persisting. This fetch is the only suspension point in
                // `subscribe`, and the actor is REENTRANT: another subscribe for this docId may
                // already have saved, opened and registered a session — which may since have
                // accepted writes. Writing our fetched (by now possibly stale) bytes here would
                // silently revert those on disk, invisible until the session recycles and reloads
                // from the store. An adopting caller must therefore persist nothing at all.
                // Nothing below suspends, so once this check finds nil the save/open/register
                // sequence completes without further reentrancy.
                if let raced = sessions[docId] {
                    opened = raced
                } else {
                    try store.save(docId: docId, bytes: bytes)
                    opened = try DocumentSession(docId: docId, store: store,
                                                 bufferLimit: config.outboundBufferLimit)
                }
            }
            // The fetch arm above is the ONLY branch here containing a suspension point, and this
            // actor is REENTRANT: a second concurrent subscribe for the SAME docId can have
            // fetched, opened and registered its own session while we were awaiting. Adopt that
            // winner instead of overwriting it — otherwise the loser's `SubscribeResult.events`
            // is bound to a session nothing ever broadcasts into, so that subscriber silently
            // freezes at its initial snapshot (and `sessionOpened` fires twice for one document).
            // For the two non-fetch branches there is no suspension, so `sessions[docId]` is still
            // nil here and this re-check is a no-op — their behaviour is unchanged.
            if let raced = sessions[docId] {
                session = raced
            } else {
                session = opened
                sessions[docId] = opened
                emitStatus(docId: docId, kind: "sessionOpened", seq: 0, count: 0)
            }
        }
        let result = await session.subscribe()
        tokenDocs[result.token] = docId
        let newCount = counts[docId, default: 0] + 1
        counts[docId] = newCount
        if case .subscribed(_, let seq, _) = result.snapshot {
            emitStatus(docId: docId, kind: "subscriberCount", seq: seq, count: newCount)
        }
        return result
    }

    public func unsubscribe(docId: String, token: UUID) async {
        guard tokenDocs.removeValue(forKey: token) == docId,
              let session = sessions[docId] else { return }
        await session.unsubscribe(token)
        counts[docId] = max(0, (counts[docId] ?? 1) - 1)
        let remaining = counts[docId] ?? 0
        emitStatus(docId: docId, kind: "subscriberCount", seq: await session.seq, count: remaining)
        if remaining == 0 && (watcherCounts[docId] ?? 0) == 0 {
            scheduleGraceTeardown(docId: docId)
        }
    }

    /// Register a viewer. Opens the session from the store if needed (no
    /// createIfMissing analog — you can't watch a doc that doesn't exist).
    public func watch(docId: String) async throws -> WatchResult {
        graceTasks.removeValue(forKey: docId)?.task.cancel()
        let session: DocumentSession
        if let existing = sessions[docId] {
            session = existing
        } else {
            session = try DocumentSession(docId: docId, store: store, bufferLimit: config.outboundBufferLimit)
            sessions[docId] = session
            emitStatus(docId: docId, kind: "sessionOpened", seq: 0, count: 0)
        }
        let result = await session.watch()
        tokenWatchDocs[result.token] = docId
        watcherCounts[docId, default: 0] += 1
        return result
    }

    public func unwatch(docId: String, token: UUID) async {
        guard tokenWatchDocs.removeValue(forKey: token) == docId,
              let session = sessions[docId] else { return }
        await session.unwatch(token)
        watcherCounts[docId] = max(0, (watcherCounts[docId] ?? 1) - 1)
        if (watcherCounts[docId] ?? 0) == 0 && (counts[docId] ?? 0) == 0 {
            scheduleGraceTeardown(docId: docId)
        }
    }

    /// Returns false when the doc has no live session (frame dropped).
    public func submitFrame(docId: String, bytes: Data) async -> Bool {
        guard let session = sessions[docId] else { return false }
        await session.submitFrame(bytes: bytes)
        return true
    }

    public func latestFrame(docId: String) async -> (png: Data, seq: Int, receivedAt: Date)? {
        guard let session = sessions[docId] else { return nil }
        return await session.latestFrame
    }

    public func submit(
        docId: String, opId: String, payload: OpPayload, expectation: WriteExpectation = .none
    ) async -> SubmitOutcome {
        guard let session = sessions[docId] else {
            return .rejected(.reject(docId: docId, opId: opId, reason: "notSubscribed", seq: 0))
        }
        let outcome = await session.submit(opId: opId, payload: payload, expectation: expectation)
        // The status event uses the seq the write itself returned — a
        // separate `await session.seq` read here could observe a LATER
        // racing write's seq (see SubmitOutcome).
        if case .accepted(let seq) = outcome {
            emitStatus(docId: docId, kind: "docUpdated", seq: seq, count: counts[docId] ?? 0)
        }
        return outcome
    }

    /// Write path for callers with no subscription of their own (MCP tools):
    /// opens (or, with `createIfMissing`, creates) a session on demand if the
    /// doc has no live session, then delegates to `submit` so the write goes
    /// through the exact same seq-assignment/store-write/broadcast path as an
    /// app push. A freshly opened session has no subscribers, so grace
    /// teardown is scheduled immediately — otherwise it would leak forever.
    /// A session that was already live (has real subscribers/watchers) is
    /// left completely alone; only the absent-session branch runs.
    public func submitOpeningSession(
        docId: String, createIfMissing: Bool, opId: String, payload: OpPayload,
        expectation: WriteExpectation = .none
    ) async -> SubmitOutcome {
        if sessions[docId] == nil {
            let session: DocumentSession
            do {
                session = try DocumentSession(docId: docId, store: store, bufferLimit: config.outboundBufferLimit)
            } catch DocumentStoreError.notFound where createIfMissing {
                session = DocumentSession(docId: docId, store: store,
                                          bufferLimit: config.outboundBufferLimit, bytes: Data())
            } catch {
                return .rejected(.reject(docId: docId, opId: opId, reason: "unknownDoc", seq: 0))
            }
            sessions[docId] = session
            emitStatus(docId: docId, kind: "sessionOpened", seq: 0, count: 0)
            scheduleGraceTeardown(docId: docId)
        }
        // The freshly-opened session's `bytes` are the store's current
        // content (loaded synchronously above), so `.matchBytes` still
        // compares against live content at write time here — no separate
        // pre-check needed. `.absent` reads the store directly (see
        // `DocumentSession.submit`), so it's equally correct on this
        // just-opened session.
        return await submit(docId: docId, opId: opId, payload: payload, expectation: expectation)
    }

    /// Live session bytes when a session is open, else the store's on-disk
    /// copy. `nil` only when neither exists (unknown doc).
    public func currentBytes(docId: String) async -> Data? {
        if let live = await sessions[docId]?.currentBytes {
            return live
        }
        return try? store.load(docId: docId)
    }

    public func subscribeStatus() -> (events: AsyncStream<ServerMessage>, token: UUID) {
        let token = UUID()
        let (stream, continuation) = AsyncStream<ServerMessage>.makeStream(
            bufferingPolicy: .bufferingOldest(config.outboundBufferLimit))
        statusSubscribers[token] = continuation
        return (stream, token)
    }

    public func unsubscribeStatus(_ token: UUID) {
        statusSubscribers.removeValue(forKey: token)?.finish()
    }

    public func liveInfo() async -> [String: LiveDocInfo] {
        var info: [String: LiveDocInfo] = [:]
        for (docId, session) in sessions {
            info[docId] = LiveDocInfo(seq: await session.seq, subscriberCount: counts[docId] ?? 0)
        }
        return info
    }

    /// The WS twin of the REST listing: store contents + live session info, plus the live
    /// index's metadata-only documents. Content ALWAYS beats metadata — a docId with real
    /// bytes is reported hasContent:true and is never duplicated by an advertisement.
    public func listDocuments() async throws -> [DocListEntry] {
        let live = await liveInfo()
        var entries = try store.list().map { info in
            DocListEntry(
                id: info.docId,
                sizeBytes: info.sizeBytes,
                modifiedAt: info.modifiedAt,
                seq: live[info.docId]?.seq,
                subscriberCount: live[info.docId]?.subscriberCount,
                hasContent: true)
        }
        let contentIds = Set(entries.map(\.id))
        for (docId, entry) in liveIndex where !contentIds.contains(docId) {
            entries.append(DocListEntry(
                id: docId, sizeBytes: entry.sizeBytes, modifiedAt: entry.modifiedAt,
                seq: nil, subscriberCount: nil, hasContent: false))
        }
        return entries.sorted { $0.id < $1.id }
    }

    /// M2c-1: fold a connected device's advertisements into the live index. Multiple devices
    /// advertising the same docId UNION (holders accumulate); where their metadata differs the
    /// NEWEST `modifiedAt` is displayed. An advertisement from a device that sent no `deviceId`
    /// is ignored — it could never be selected to serve a fetch, so indexing it would list a
    /// document nobody can produce.
    public func applyAdvertisements(_ ads: [DocAdvertisement], deviceId: String?) {
        guard let deviceId else { return }
        for ad in ads {
            if var existing = liveIndex[ad.docId] {
                existing.holders.insert(deviceId)
                if ad.modifiedAt >= existing.modifiedAt {
                    existing.name = ad.docId
                    existing.sizeBytes = ad.sizeBytes
                    existing.modifiedAt = ad.modifiedAt
                    existing.thumbnail = ad.thumbnail
                }
                liveIndex[ad.docId] = existing
            } else {
                liveIndex[ad.docId] = LiveDocEntry(
                    name: ad.docId, sizeBytes: ad.sizeBytes, modifiedAt: ad.modifiedAt,
                    thumbnail: ad.thumbnail, holders: [deviceId])
            }
        }
    }

    /// M2c-1: a device disconnected — drop it from every holder set, and drop any entry whose
    /// last holder just left. This is what makes a powered-off device's documents disappear.
    public func removeAdvertisements(deviceId: String) {
        for (docId, var entry) in liveIndex {
            guard entry.holders.remove(deviceId) != nil else { continue }
            if entry.holders.isEmpty {
                liveIndex.removeValue(forKey: docId)
            } else {
                liveIndex[docId] = entry
            }
        }
    }

    public func liveDocs() -> [String: LiveDocEntry] { liveIndex }

    public func liveEntry(docId: String) -> LiveDocEntry? { liveIndex[docId] }

    /// Try each holder in turn until one hands over the bytes. Holders are equal — there is no
    /// origin — so a failure (offline, doc deleted, timeout) just moves to the next. Throws the
    /// LAST error when every holder fails.
    private func fetchFromHolders(docId: String) async throws -> Data {
        guard let contentProvider, let entry = liveIndex[docId], !entry.holders.isEmpty else {
            throw DocumentStoreError.notFound
        }
        if let existing = inFlightFetches[docId] { return try await existing.value }

        let holders = entry.holders.sorted()
        let task = Task<Data, Error> {
            var lastError: Error = DocumentStoreError.notFound
            for holder in holders {
                do { return try await contentProvider(docId, holder) } catch { lastError = error }
            }
            throw lastError
        }
        inFlightFetches[docId] = task
        defer { inFlightFetches.removeValue(forKey: docId) }
        return try await task.value
    }

    private func scheduleGraceTeardown(docId: String) {
        graceTasks[docId]?.task.cancel()
        let graceId = UUID()
        let task = Task { [gracePeriod = config.gracePeriod] in
            try? await Task.sleep(for: gracePeriod)
            guard !Task.isCancelled else { return }
            await self.tearDownIfIdle(docId: docId, graceId: graceId)
        }
        graceTasks[docId] = (graceId, task)
    }

    /// Tears down only if this invocation belongs to the CURRENTLY registered
    /// grace task. A resubscribe removes the registration on the actor, so a
    /// stale task that already passed its cancellation check fails this guard.
    /// The guard and the teardown run in one actor turn (no suspension), so
    /// no subscribe can interleave between check and mutation.
    private func tearDownIfIdle(docId: String, graceId: UUID) {
        guard graceTasks[docId]?.id == graceId else { return }
        guard (counts[docId] ?? 0) == 0, (watcherCounts[docId] ?? 0) == 0 else {
            graceTasks.removeValue(forKey: docId)
            return
        }
        sessions.removeValue(forKey: docId)
        counts.removeValue(forKey: docId)
        watcherCounts.removeValue(forKey: docId)
        graceTasks.removeValue(forKey: docId)
        emitStatus(docId: docId, kind: "sessionClosed", seq: nil, count: 0)
    }

    private func emitStatus(docId: String, kind: String, seq: Int?, count: Int?) {
        let message = ServerMessage.statusEvent(
            payload: StatusPayload(docId: docId, kind: kind, seq: seq, subscriberCount: count))
        for (token, continuation) in statusSubscribers {
            switch continuation.yield(message) {
            case .dropped, .terminated:
                statusSubscribers.removeValue(forKey: token)?.finish()
            default:
                break
            }
        }
    }
}
