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

/// Failures of the holder-relay content fetch that are not store errors.
public enum ContentFetchError: Error, Equatable {
    /// The total per-call fetch budget (`SessionConfig.fetchTotalTimeout`) was spent
    /// before any holder produced bytes, so the remaining holders were not tried.
    /// Callers surface this the same way as any other fetch failure (the content is
    /// unavailable right now); it is a distinct case so a log or test can tell
    /// "every holder genuinely failed" from "we ran out of time to ask them all".
    case budgetExhausted
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
    /// deviceId → its currently-live connectionIds. A device's holdings are pruned only when this
    /// set empties, so a stale connection's close can't wipe a reconnected connection's ads.
    private var deviceConnections: [String: Set<UUID>] = [:]
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

    /// `acceptsStrippedDocuments` — the caller's connection advertised `blobOmission`, so its
    /// broadcasts may leave out image blobs it already holds. Defaults to false: a peer that never
    /// said so keeps receiving whole documents.
    public func subscribe(docId: String, createIfMissing: Bool = false,
                          acceptsStrippedDocuments: Bool = false) async throws -> SubscribeResult {
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
                //
                // This branch deliberately does NOT fetch from holders — pinned by
                // `SubscribeFetchTests.testCreateIfMissingDoesNotFetch`. `createIfMissing` IS the
                // app's create-push, and the subscribing device is itself typically the holder
                // that advertised this docId, so fetching would have the server turn around and
                // ask the very device that is mid-subscribe to supply the content.
                //
                // KNOWN, DEFERRED (M2c-1 review F4 — the "content-less createIfMissing shadow
                // window"): while this empty placeholder session is alive it SHADOWS the fetch
                // path for other readers. `currentBytes` returns the session's empty bytes, so
                // `currentBytesOrFetch` treats the doc as resident and an agent tool reads an
                // EMPTY document instead of pulling the holder's real content.
                //
                // The obvious fix — let `currentBytesOrFetch` ignore an unsaved empty placeholder
                // and fetch instead — is WRONG on its own, and the reason is worth recording:
                // `WriteExpectation.matchBytes` compares against this SESSION's in-memory bytes
                // (see `DocumentSession.submit`), not the store. A tool that read fetched content
                // would then write with `expectedBytes` = that content while the session still
                // holds empty, so every agent write would fail `docChangedDuringOp` with no way
                // to converge — trading a silently-wrong read for a permanently-broken write.
                // Closing F4 therefore requires the placeholder session to ADOPT the fetched
                // bytes (session + store + readers agreeing), which changes what the app's
                // create-push sees on its own subscribe (a non-empty snapshot => the M1.5
                // auto-union path) — a design decision, not a drive-by hardening fix.
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
                // Nothing below suspends, so once these checks pass the save/open/register
                // sequence completes without further reentrancy.
                if let raced = sessions[docId] {
                    opened = raced
                } else {
                    // …and a session is not the only thing that can have landed content while we
                    // awaited: a writer may have opened a session, written, and then had it GRACE
                    // TORN DOWN, leaving durable bytes with NO session behind them (the same
                    // store-only state `currentBytesOrFetch`'s own re-check guards). Relying on
                    // `gracePeriod` outlasting the fetch would be a config coupling, not a
                    // guarantee — and with the F9 budget the worst-case fetch (budget + one
                    // attempt) can legitimately approach it. So consult the durable truth: if
                    // anything is stored now it WINS, and opening from the store loads it.
                    if (try? store.exists(docId: docId)) != true {
                        try store.save(docId: docId, bytes: bytes)
                    }
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
        let result = await session.subscribe(acceptsStrippedDocuments: acceptsStrippedDocuments)
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

    /// Delete a document from the server: its stored bytes, its live session, and its holder
    /// index entry. Throws `DocumentStoreError.notFound` if the server holds neither content nor
    /// an advertisement for it.
    ///
    /// Deliberately NOT guarded by a `WriteExpectation` the way writes are — the user asked for
    /// the document to be gone, so a write that landed a moment before does not make the request
    /// stale. Equally deliberately, NOTHING is retained afterwards: no tombstone, no deleted-id
    /// list. A device that still holds a copy may re-advertise or re-push it and bring it back,
    /// which is accepted behaviour rather than a bug to design against.
    public func deleteDoc(docId: String) async throws {
        let hadContent = (try? store.exists(docId: docId)) ?? false
        let hadAdvertisement = liveIndex[docId] != nil
        guard hadContent || hadAdvertisement else { throw DocumentStoreError.notFound }

        if hadContent { try store.delete(docId: docId) }

        // Drop the advertisement so the deleting device's own browser does not keep showing the
        // document as a remote row until the next advertisement refresh. A device that still holds
        // it re-advertises on its next push, which is the accepted resurrection path.
        liveIndex.removeValue(forKey: docId)

        if let session = sessions.removeValue(forKey: docId) {
            await session.announceDeleted()
            counts.removeValue(forKey: docId)
            watcherCounts.removeValue(forKey: docId)
            graceTasks.removeValue(forKey: docId)?.task.cancel()
            emitStatus(docId: docId, kind: "sessionClosed", seq: nil, count: 0)
        }
        // Unconditionally, and NOT folded into the branch above: a document with no live session
        // is the ordinary case for an agent `delete_doc`, and emitting only `sessionClosed` there
        // would tell status listeners nothing — a browser watching this channel would keep showing
        // the row until something else made it re-fetch.
        emitStatus(docId: docId, kind: "docDeleted", seq: nil, count: 0)
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

    /// `submitter` is the writer's own subscription token, when it has one. It is used for a single
    /// decision — whether a stripped broadcast is worth building — because a writer ignores the echo
    /// of its own op.
    public func submit(
        docId: String, opId: String, payload: OpPayload, expectation: WriteExpectation = .none,
        submitter: UUID? = nil
    ) async -> SubmitOutcome {
        guard let session = sessions[docId] else {
            return .rejected(.reject(docId: docId, opId: opId, reason: "notSubscribed", seq: 0))
        }
        let outcome = await session.submit(opId: opId, payload: payload,
                                           expectation: expectation, submitter: submitter)
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

    /// Resident bytes if present; otherwise, for a content-less doc that a connected device
    /// holds, pull them via the SAME `fetchFromHolders` relay a subscribe uses, PERSIST them
    /// (promoting the doc to ordinary server content, which then stays), and return them. Nil only
    /// when there is nothing here and no holder can supply it. This is the ONE fetch path shared by
    /// the transparent tool reads and the explicit `fetch_doc` tool — never a second mechanism.
    public func currentBytesOrFetch(docId: String) async -> Data? {
        // An EMPTY `createIfMissing` placeholder is not content — it is a slot the app opened
        // moments before pushing (M2c-1 review F4). Treating it as resident is what made an agent
        // read a BLANK document while a holder had the real thing, and it disagreed with
        // `/api/docs`, which kept reporting the doc `hasContent: false` (fetchable) because nothing
        // was durable. `store.exists` is what tells a placeholder from a genuinely-empty SAVED doc;
        // a session's in-memory bytes cannot.
        //
        // Two honest consequences of fetching here, both narrow (this only fires when an agent
        // reads inside the app's create window) and neither a loss:
        //  - The holder is often the SAME device that just opened the doc, and `provideContent`
        //    serves its FILE — so the promoted bytes can be that device's own slightly-older disk
        //    state. The app's create-push then meets durable content and reroutes into the M1.5
        //    union, which is additive: an element the user deleted since the last save can come
        //    back, with the auto-merge notice, on a document they had open alone.
        //  - That reroute is guaranteed only for the INITIAL create-push, which is the one that
        //    carries expect-absent. A later (or retried) push carries no expectation and simply
        //    overwrites the promoted bytes — no loss, since the holder still has its own copy and
        //    reconciles on its next subscribe, but do not read the reroute as a general rule.
        let placeholder = await isEmptyPlaceholder(docId: docId)
        if !placeholder, let resident = await currentBytes(docId: docId) { return resident }
        // From here a placeholder must never be worse off than before: every failure path below
        // falls back to it, so a doc mid-creation still reads as the empty doc it is rather than
        // turning a working call into `unknownDoc`.
        guard liveIndex[docId] != nil else { return await currentBytes(docId: docId) }
        guard let bytes = try? await fetchFromHolders(docId: docId) else {
            return await currentBytes(docId: docId)
        }
        // A concurrent writer may have landed content while we were fetching — the same reentrancy
        // window `subscribe`'s own notFound branch guards. Persisting our now-possibly-stale fetch
        // would silently revert it on disk, invisible until the session recycles and reloads.
        // Whatever is here now is authoritative: return it and save nothing.
        //
        // Both halves matter (M2c-1 review F5). A concurrent SUBSCRIBE leaves a live session…
        // (`!isEmpty`, so the placeholder we are fetching FOR doesn't count as a racing writer and
        // discard the very fetch it triggered — a real write is never empty.)
        if let live = await sessions[docId]?.currentBytes, !live.isEmpty { return live }
        // …and a concurrent PROMOTION leaves none — but the two promotion cases now diverge, so
        // they are handled separately below:
        //
        // (a) A LIVE session (necessarily the empty placeholder we fetched for, since a non-empty
        //     one returned just above): promote THROUGH it. The session persists and adopts in one
        //     of ITS actor turns, so the store write is serialized against `submit` and the
        //     session's bytes — what `.matchBytes` compares against — can never disagree with the
        //     file. Writing the store from HERE instead would race the app's create-push writing
        //     the same docId from the session actor, and `.atomic` renames after writing the whole
        //     file: with a multi-MB document the loser's rename can land last, silently discarding
        //     an already-`accepted` write. It returns the authoritative bytes, so a write that beat
        //     us is handed back rather than a fetch we already know is stale.
        if let session = sessions[docId] { return await session.adoptIfEmpty(bytes: bytes) }
        // (b) NO session — `currentBytesOrFetch` writes straight to the store and opens none, and a
        //     session that wrote and then grace-tore-down is the same observable state (bytes on
        //     disk, `sessions[docId] == nil`). A session-only re-check is blind to both and would
        //     clobber the newer bytes with our stale fetch, so consult the store (M2c-1 review F5).
        //
        //     Atomicity holds HERE for the original reason: the `sessions[docId]?` chain above
        //     short-circuits with NO suspension when no session exists, `store.load`/`save` are
        //     synchronous, and with no session there is no other writer for this docId (every write
        //     reaches the store through a `DocumentSession`, and opening one requires this actor) —
        //     so check-through-save is one uncontended actor turn.
        if let durable = try? store.load(docId: docId) { return durable }
        try? store.save(docId: docId, bytes: bytes)
        return bytes
    }

    /// True when the only thing here is an EMPTY session with nothing durable behind it — the
    /// `createIfMissing` placeholder the app opens just before pushing. `store.exists` is the
    /// discriminator: a genuinely-empty SAVED document is real content and must NOT be treated
    /// as a placeholder (it would trigger a pointless fetch that could overwrite it).
    private func isEmptyPlaceholder(docId: String) async -> Bool {
        guard let live = await sessions[docId]?.currentBytes, live.isEmpty else { return false }
        return (try? store.exists(docId: docId)) != true
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
    public func applyAdvertisements(_ ads: [DocAdvertisement], connectionId: UUID, deviceId: String?) {
        guard let deviceId else { return }
        // Track this connection as live for its device, so a LATER close of a DIFFERENT (stale)
        // connection for the same device can't wipe its advertisements (`removeConnection` below).
        deviceConnections[deviceId, default: []].insert(connectionId)
        // A batch is that device's COMPLETE current set (`advertiseLocalDocs` gathers every
        // syncEnabled local doc), so REPLACE its previous contribution rather than accumulating.
        // Accumulating would keep listing a document the device has since deleted or marked
        // local-only, and would keep offering that device as a fetch source for it — a stale
        // holder that sorts first is asked first and burns the full device timeout.
        dropDeviceFromHolders(deviceId)
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

    /// M2c-1: a connection closed. Its device's documents disappear from the index only when
    /// this was the device's LAST live connection — a reconnect (a fresh connection for the same
    /// device) races the old socket's close, and pruning by deviceId alone would let that stale
    /// close wipe the live connection's advertisements until it happened to re-advertise.
    public func removeConnection(connectionId: UUID, deviceId: String) {
        guard var live = deviceConnections[deviceId] else { return }
        live.remove(connectionId)
        if live.isEmpty {
            deviceConnections.removeValue(forKey: deviceId)
            dropDeviceFromHolders(deviceId)
        } else {
            deviceConnections[deviceId] = live
        }
    }

    /// Remove `deviceId` from every holder set, dropping any entry whose last holder just left.
    /// Pure index surgery — does NOT touch `deviceConnections` (the caller owns that bookkeeping).
    private func dropDeviceFromHolders(_ deviceId: String) {
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
    ///
    /// M2c-1 review F9 — the walk is bounded by `config.fetchTotalTimeout`. Each individual
    /// attempt is already bounded (the broker's `strokeOpTimeout`), but the holders are tried
    /// SEQUENTIALLY, so N stale holders otherwise cost N x that timeout on ONE subscribe or agent
    /// tool call. The budget is checked BEFORE starting each attempt: an attempt already in flight
    /// is never abandoned (cancelling it would leave the device's reply unclaimed for a request the
    /// broker still has in flight), so the honest worst case is the budget plus one attempt. The
    /// deadline is computed per CALL — never stored on the entry — so a doc whose fetch timed out
    /// once is fully retryable later.
    private func fetchFromHolders(docId: String) async throws -> Data {
        guard let contentProvider, let entry = liveIndex[docId], !entry.holders.isEmpty else {
            throw DocumentStoreError.notFound
        }
        if let existing = inFlightFetches[docId] { return try await existing.value }

        let holders = entry.holders.sorted()
        let deadline = ContinuousClock.now.advanced(by: config.fetchTotalTimeout)
        let task = Task<Data, Error> {
            var lastError: Error = DocumentStoreError.notFound
            for holder in holders {
                // Spend no more of the caller's time once the budget is gone. The guard is
                // `now < deadline`, so a zero/negative budget refuses even the first attempt.
                guard ContinuousClock.now < deadline else {
                    lastError = ContentFetchError.budgetExhausted
                    break
                }
                do {
                    let bytes = try await contentProvider(docId, holder)
                    // Never persist an empty payload. A holder that returns 0 bytes (a truncated
                    // or corrupt local file) would otherwise be saved and reported hasContent:true
                    // FOREVER — permanently shadowing every real holder's copy, with no eviction.
                    // Treat it as a failure and try the next holder instead.
                    guard !bytes.isEmpty else { lastError = DocumentStoreError.notFound; continue }
                    return bytes
                } catch { lastError = error }
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
