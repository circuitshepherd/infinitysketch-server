import Foundation
import Crypto
import InfSketchWire

public struct SessionConfig: Sendable {
    public var gracePeriod: Duration
    public var outboundBufferLimit: Int
    /// Bulk payloads at or below this raw byte count travel inline (v0 shape);
    /// larger ones become chunked binary transfers.
    public var inlineLimit: Int
    /// Payload bytes per binary chunk message. Header + payload stays under
    /// URLSessionWebSocketTask's 1 MiB default receive cap.
    public var chunkSize: Int
    /// MCP sessions idle longer than this are reaped (the SDK's own client
    /// never sends `DELETE /mcp`, so idle reaping is the ORDINARY teardown
    /// path for MCP sessions, not a safety net — see MCPAdapter).
    public var mcpSessionIdleTimeout: Duration
    /// How often the MCP adapter sweeps for idle sessions.
    public var mcpSessionCleanupInterval: Duration
    /// How long `DeviceCommandBroker.requestCreation` waits for a device's
    /// `createDocReply` before failing with `.deviceTimeout`.
    public var createDocTimeout: Duration
    /// How long `DeviceCommandBroker.requestStrokeOp` waits for a device's
    /// `strokeOpReply` before failing with `.deviceTimeout`.
    public var strokeOpTimeout: Duration
    /// Total budget for ONE `SessionManager.fetchFromHolders` call, across all
    /// holders (M2c-1 review F9). Each individual attempt is already bounded by
    /// `strokeOpTimeout`, but holders are tried SEQUENTIALLY — so without a total
    /// budget a document advertised by N stale devices costs N x `strokeOpTimeout`
    /// on a single subscribe or agent tool call. Once the budget is spent no
    /// FURTHER holder is tried (an attempt already in flight still runs to its own
    /// timeout, so the true worst case is this budget plus one `strokeOpTimeout`).
    ///
    /// The default admits exactly two 20 s attempts (they start at 0 s and 20 s; a
    /// third would start at 40 s > 30 s and is refused), for a 50 s worst case. Two
    /// ceilings make a LARGER default a poor trade: it should stay under
    /// `gracePeriod`, so a fetch cannot outlive a session teardown it raced (see
    /// `subscribe`'s store-aware re-check, which no longer merely ASSUMES that), and
    /// under the ~60 s timeout typical MCP clients apply, since a client that gives
    /// up orphans the fetch.
    public var fetchTotalTimeout: Duration
    /// Bytes a connection may be sent since the peer last proved it is reading, before the
    /// server asks it to prove that again with a `ping`. Crossing this is NOT a disconnect —
    /// see `ConnectionHealth`, which explains why asking is load-bearing.
    ///
    /// 64 MB is roughly ten large documents in flight: one broadcast event carries a WHOLE
    /// document (the bundled Example B is ~2 MB, Example 1 ~5.8 MB), and a healthy client on a
    /// LAN drains one in milliseconds. Far above any legitimate burst, far below a memory
    /// problem.
    public var outboundByteBudget: Int
    /// Time with no proof of life before an unprompted `ping`. This is what reaps a half-open
    /// socket — a device that slept or lost WiFi without a FIN, whose subscriptions would
    /// otherwise hold its document session open forever.
    public var keepaliveIdleInterval: Duration
    /// How long a peer has to answer a `ping` before the connection is dropped.
    public var keepalivePingGrace: Duration
    /// How often the per-connection timer calls `ConnectionHealth.tick`. It only has to be fine
    /// enough to observe `keepalivePingGrace` with reasonable precision — the deadlines
    /// themselves are computed from timestamps, not from tick counts.
    public var keepaliveTickInterval: Duration
    /// Bytes per second a peer is assumed to be able to drain, used to extend a BUDGET ping's
    /// deadline by the time it takes the peer to reach the ping through the backlog queued ahead
    /// of it (see `ConnectionHealth`). It is not a measurement and not a rate limit — it is a
    /// floor that keeps the deadline from expiring before the question is even deliverable.
    ///
    /// 1 MB/s means a full 64 MB budget buys 64 s instead of the flat 10 s grace. A peer slower
    /// than this floor genuinely cannot keep up with a system whose broadcast events carry whole
    /// multi-MB documents (Example 1 is ~5.8 MB — six seconds for ONE event at this rate), so
    /// treating it as stalled is the correct verdict; the point of the floor is only that the
    /// deadline must at least cover DELIVERING the question.
    public var assumedMinimumDrainRate: Int
    public init(
        gracePeriod: Duration = .seconds(60),
        outboundBufferLimit: Int = 256,
        inlineLimit: Int = 256 * 1024,
        chunkSize: Int = 512 * 1024,
        mcpSessionIdleTimeout: Duration = .seconds(3600),
        mcpSessionCleanupInterval: Duration = .seconds(60),
        createDocTimeout: Duration = .seconds(10),
        strokeOpTimeout: Duration = .seconds(20),
        fetchTotalTimeout: Duration = .seconds(30),
        outboundByteBudget: Int = 64 * 1024 * 1024,
        keepaliveIdleInterval: Duration = .seconds(30),
        keepalivePingGrace: Duration = .seconds(10),
        keepaliveTickInterval: Duration = .seconds(5),
        assumedMinimumDrainRate: Int = 1024 * 1024
    ) {
        self.gracePeriod = gracePeriod
        self.outboundBufferLimit = outboundBufferLimit
        self.inlineLimit = inlineLimit
        self.chunkSize = chunkSize
        self.mcpSessionIdleTimeout = mcpSessionIdleTimeout
        self.mcpSessionCleanupInterval = mcpSessionCleanupInterval
        self.createDocTimeout = createDocTimeout
        self.strokeOpTimeout = strokeOpTimeout
        self.fetchTotalTimeout = fetchTotalTimeout
        self.outboundByteBudget = outboundByteBudget
        self.keepaliveIdleInterval = keepaliveIdleInterval
        self.keepalivePingGrace = keepalivePingGrace
        self.keepaliveTickInterval = keepaliveTickInterval
        self.assumedMinimumDrainRate = assumedMinimumDrainRate
    }
}

/// If `events` finishes server-side (e.g. buffer-overflow disconnect), the
/// consumer MUST call SessionManager.unsubscribe(docId:token:) — otherwise
/// the subscriber count leaks and the session never tears down. (The WS
/// adapter's pump does this.)
public struct SubscribeResult: Sendable {
    public let snapshot: ServerMessage
    public let events: AsyncStream<ServerMessage>
    public let token: UUID
}

/// A watcher receives ONLY frameAvailable notifications — no snapshot, no op
/// events. Browsers watch; apps subscribe.
public struct WatchResult: Sendable {
    public let events: AsyncStream<ServerMessage>
    public let token: UUID
}

/// Outcome of a document write. `accepted` carries the seq this write was
/// assigned, threaded back from the ONE place that knows it atomically —
/// `DocumentSession.submit`, the same actor turn that increments the
/// counter. Callers must use THIS seq for acks, never a separate read-back
/// after the write returns: both actors are reentrant, so a racing
/// concurrent write to the same doc can land in the gap between the write
/// and a follow-up `seq`/`liveInfo()` read, making the read-back report the
/// LATER write's seq (Task 7 review, Important #1 — empirically reproduced).
/// `rejected` carries the `.reject` ServerMessage to deliver to the
/// submitter only.
public enum SubmitOutcome: Equatable, Sendable {
    case accepted(seq: Int)
    case rejected(ServerMessage)

    /// The `.reject` message when rejected, nil when accepted — for callers
    /// (the WS adapter) that only need to forward a rejection.
    public var rejectMessage: ServerMessage? {
        if case .rejected(let message) = self { return message }
        return nil
    }
}

/// Per-document hub: current bytes, seq counter, subscriber fan-out.
/// Grace-period teardown lives in SessionManager, not here.
actor DocumentSession {
    let docId: String
    private let store: any DocumentStore
    private let bufferLimit: Int
    private var bytes: Data
    private(set) var seq = 0
    private var subscribers: [UUID: AsyncStream<ServerMessage>.Continuation] = [:]
    private var watchers: [UUID: AsyncStream<ServerMessage>.Continuation] = [:]
    /// One-slot live-frame cache; dies with the session (the HTTP route then
    /// falls back to the stored thumbnail, marked stale).
    private(set) var latestFrame: (png: Data, seq: Int, receivedAt: Date)?

    /// Designated: session over already-known bytes (createIfMissing path uses
    /// empty bytes; nothing is persisted until the first op's store.save).
    init(docId: String, store: any DocumentStore, bufferLimit: Int, bytes: Data) {
        self.docId = docId
        self.store = store
        self.bufferLimit = bufferLimit
        self.bytes = bytes
    }

    /// Loads the document from the store (the pre-existing path).
    init(docId: String, store: any DocumentStore, bufferLimit: Int) throws {
        self.init(docId: docId, store: store, bufferLimit: bufferLimit,
                  bytes: try store.load(docId: docId))
    }

    var subscriberCount: Int { subscribers.count }

    /// The document's current in-memory bytes — always in sync with the
    /// store's on-disk copy, since `submit` writes through before updating
    /// this. Read-only accessor for callers (e.g. MCP tools) that just need
    /// the live content without subscribing.
    var currentBytes: Data { bytes }

    /// Promote content fetched from a holder into an EMPTY `createIfMissing` placeholder (M2c-1
    /// review F4), persisting it and adopting it in ONE actor turn. Returns this session's
    /// authoritative bytes afterwards — the adopted content, or whatever already won.
    ///
    /// Why the session and not just the store — TWO reasons, both load-bearing:
    ///
    /// 1. `submit`'s `.matchBytes` CAS compares against THESE bytes, so a reader handed fetched
    ///    content while this session still held empty would have every read-then-write-back
    ///    rejected `docChangedDuringOp`, non-convergently. Adoption keeps session, store and
    ///    readers on one value.
    /// 2. The STORE WRITE MUST HAPPEN HERE, not on the manager. `SessionManager`'s own
    ///    fetch-promotion write is safe only under "no session ⇒ no concurrent writer" (every
    ///    write reaches the store through a `DocumentSession`, and opening one needs the manager
    ///    actor). A placeholder breaks that premise: it is a LIVE session, so the manager's
    ///    `store.save` could race this session's `submit` writing the app's create-push —
    ///    `.atomic` writes rename after writing the whole file, so with a multi-MB document the
    ///    loser's rename can land last and leave store and session DISAGREEING, silently
    ///    discarding an already-`accepted` write until the session recycles. Doing it inside this
    ///    actor serializes it against `submit` by construction.
    ///
    /// Conditional, so a real write that landed while the caller was suspended wins and is never
    /// rolled back; a failed `store.save` adopts NOTHING (the doc stays a placeholder, so a later
    /// read retries the fetch rather than serving in-memory-only content the store never got).
    /// `seq` is deliberately NOT bumped and nothing is broadcast: this is not a document edit, it
    /// is the session learning what it should have been holding all along. Subscribers converge
    /// through the ordinary path — see `SessionManager.currentBytesOrFetch` for what the app's
    /// create-push does once this content is durable, and for the two narrow consequences.
    func adoptIfEmpty(bytes newBytes: Data) -> Data {
        guard bytes.isEmpty else { return bytes }          // a real write landed; it persisted itself
        if let durable = try? store.load(docId: docId), !durable.isEmpty {
            bytes = durable                                 // a store-only promotion beat us
            return durable
        }
        guard (try? store.save(docId: docId, bytes: newBytes)) != nil else { return bytes }
        bytes = newBytes
        return newBytes
    }

    func subscribe() -> SubscribeResult {
        let token = UUID()
        let (stream, continuation) = AsyncStream<ServerMessage>.makeStream(
            bufferingPolicy: .bufferingOldest(bufferLimit))
        subscribers[token] = continuation
        // A reconnecting app must learn it is already watched: deliver the
        // current watcher count as this subscription's first event.
        if !watchers.isEmpty {
            continuation.yield(.watchers(docId: docId, count: watchers.count))
        }
        return SubscribeResult(
            snapshot: .subscribed(docId: docId, seq: seq, snapshot: .inline(bytes)),
            events: stream,
            token: token)
    }

    func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)?.finish()
    }

    var watcherCount: Int { watchers.count }

    func watch() -> WatchResult {
        let token = UUID()
        let (stream, continuation) = AsyncStream<ServerMessage>.makeStream(
            bufferingPolicy: .bufferingOldest(bufferLimit))
        watchers[token] = continuation
        notifyWatcherCount()
        return WatchResult(events: stream, token: token)
    }

    func unwatch(_ token: UUID) {
        guard watchers.removeValue(forKey: token) != nil else { return }
        notifyWatcherCount()
    }

    /// Cache the frame and nudge every watcher. Ephemeral: no seq, no store,
    /// no subscriber echo.
    func submitFrame(bytes: Data) {
        latestFrame = (png: bytes, seq: seq, receivedAt: Date())
        let message = ServerMessage.frameAvailable(docId: docId, seq: seq)
        for (token, continuation) in watchers {
            switch continuation.yield(message) {
            case .dropped, .terminated:
                // Frame nudges are refetch hints — a stalled watcher is dropped;
                // the page reconnects like the overview does.
                watchers.removeValue(forKey: token)?.finish()
                notifyWatcherCount()
            default:
                break
            }
        }
    }

    /// Tell subscribers (the app) the current viewer count.
    private func notifyWatcherCount() {
        broadcast(.watchers(docId: docId, count: watchers.count))
    }

    /// Returns `.accepted(seq:)` carrying the newly assigned seq (the
    /// broadcast echo remains the subscriber-facing ack; the returned seq is
    /// the submitter-facing one — see `SubmitOutcome`), or `.rejected` with
    /// a .reject to deliver to the submitter only.
    func submit(opId: String, payload: OpPayload, expectation: WriteExpectation = .none) -> SubmitOutcome {
        // The adapter reassembles transfers before ops reach the session.
        guard case .inline(let inline) = payload.bulk else {
            return .rejected(.reject(docId: docId, opId: opId, reason: "unresolvedTransfer", seq: seq))
        }

        // A whole document, or one rebuilt from the blobs THIS SESSION already holds. The rebuild
        // happens here, before anything else in `submit` — so the compare-and-swap below, the
        // store, the broadcast and every agent relay carry on seeing a complete document and none
        // of them learns that anything was omitted.
        //
        // It is VERIFIED, not trusted: the sender says which document its omissions came from and
        // what the rebuild must hash to, and both are checked. That is what keeps a bug here to the
        // cost of a whole-document resend — these bytes become the stored document, the sync
        // lineage and the merge base, so a wrong rebuild must be unable to reach them.
        let newBytes: Data
        switch payload.type {
        case "fullDoc":
            newBytes = inline
        case "strippedDoc":
            guard let stripped = try? StrippedDocument(encoded: inline),
                  stripped.basedOn == Data(SHA256.hash(data: bytes)),
                  let rebuilt = try? stripped.restore(using: bytes),
                  Data(SHA256.hash(data: rebuilt)) == stripped.originalSHA256
            else {
                return .rejected(.reject(docId: docId, opId: opId,
                                         reason: "cannotReconstruct", seq: seq))
            }
            newBytes = rebuilt
        default:
            return .rejected(.reject(docId: docId, opId: opId, reason: "unsupportedPayloadType", seq: seq))
        }
        // Compare-and-swap guard for callers that read-then-compute-then-write
        // (MCP tools spanning a device round-trip): the token MUST be the
        // document's bytes, never `seq`. `seq` is scoped to this
        // DocumentSession's in-memory lifetime (`private(set) var seq = 0`
        // above), and a grace-period teardown/reopen resets it to 0 while the
        // CONTENT carries on from the store. That desync cuts both ways:
        //   - false REJECT: recycle over identical content, seq 1 -> 0, a
        //     seq CAS refuses a write that was perfectly safe; and worse,
        //   - false ACCEPT: caller reads seq 0 from a fresh session -> the
        //     user pushes (seq 1, content changes) -> teardown -> reopen at
        //     seq 0 over the USER'S NEW content -> a stale expectedSeq 0
        //     matches, and the guard waves through the very clobber it
        //     exists to stop. (Out of reach today only because gracePeriod
        //     60s > strokeOpTimeout 20s — a config coincidence, not a
        //     structural guarantee. Do not rely on it.)
        // Byte equality is exact and recycle-proof. This guard runs in the
        // same actor turn as the write below, so nothing can interleave
        // between the compare and the store.save — and it must stay ABOVE
        // that save: below it, a rejected write would already have hit disk.
        //
        // `.absent` is the creation-side twin: "this document must not
        // already exist". The STORE is the durable truth for that check —
        // never `bytes` (a `createIfMissing` session starts `bytes = Data()`,
        // indistinguishable in-memory from a genuinely-empty saved doc) and
        // never `seq` (resets to 0 on recycle). Same actor turn, directly
        // above `store.save`, single writer per docId -> atomic: a second
        // `.absent` submit racing the first sees the first's write only
        // after this turn completes, so it correctly loses.
        switch expectation {
        case .none:
            break
        case .matchBytes(let expected):
            if bytes != expected {
                return .rejected(.reject(docId: docId, opId: opId, reason: "docChangedDuringOp", seq: seq))
            }
        case .matchHash(let expected):
            // The same guarantee as `.matchBytes` — this session's current content is what the
            // writer read — with a digest standing in for the bytes, so the APP can afford to
            // carry it on every settle-push (spec 2026-07-27-app-push-write-expectation-design).
            // Same actor turn, same position above `store.save`, same rejection reason.
            if Data(SHA256.hash(data: bytes)) != expected {
                return .rejected(.reject(docId: docId, opId: opId, reason: "docChangedDuringOp", seq: seq))
            }
        case .absent:
            let alreadyExists = (try? store.exists(docId: docId)) ?? false
            if alreadyExists {
                return .rejected(.reject(docId: docId, opId: opId, reason: "docExists", seq: seq))
            }
        }
        do {
            try store.save(docId: docId, bytes: newBytes)
        } catch {
            FileHandle.standardError.write(Data("store.save failed for '\(docId)': \(error)\n".utf8))
            return .rejected(.reject(docId: docId, opId: opId, reason: "storeFailure", seq: seq))
        }
        bytes = newBytes
        seq += 1
        broadcast(.event(docId: docId, seq: seq, kind: "op", opId: opId, payload: payload))
        return .accepted(seq: seq)
    }

    /// Tell every live subscriber the document was deleted on the server, then close their streams.
    ///
    /// Their copy is not touched — a subscriber holding the document keeps it and turns it into a
    /// LOCAL-ONLY document. Without this push a device with the doc open would keep mirroring and
    /// re-create it on the server within seconds, which looks like the delete silently failing.
    func announceDeleted() {
        broadcast(.docDeleted(docId: docId))
        for (_, continuation) in subscribers { continuation.finish() }
        subscribers.removeAll()
    }

    private func broadcast(_ message: ServerMessage) {
        for (token, continuation) in subscribers {
            switch continuation.yield(message) {
            case .dropped, .terminated:
                // Bounded-buffer overflow (or consumer gone): disconnect; the
                // client recovers by re-subscribing (fresh snapshot in v0).
                //
                // NOT the primary guard against a slow SOCKET, despite appearances.
                // `WSAdapter.Connection.pump` drains this stream as fast as events arrive and
                // re-yields into the connection's unbounded `output`, so this bound does not
                // engage for a slow reader — `ConnectionHealth` handles that case. What this
                // still covers is a `pump` task that is itself suspended or descheduled, which
                // nothing else notices.
                subscribers.removeValue(forKey: token)?.finish()
            default:
                break
            }
        }
    }
}
