import Foundation
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
    public init(
        gracePeriod: Duration = .seconds(60),
        outboundBufferLimit: Int = 256,
        inlineLimit: Int = 256 * 1024,
        chunkSize: Int = 512 * 1024,
        mcpSessionIdleTimeout: Duration = .seconds(3600),
        mcpSessionCleanupInterval: Duration = .seconds(60),
        createDocTimeout: Duration = .seconds(10),
        strokeOpTimeout: Duration = .seconds(20),
        fetchTotalTimeout: Duration = .seconds(30)
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
        guard payload.type == "fullDoc" else {
            return .rejected(.reject(docId: docId, opId: opId, reason: "unsupportedPayloadType", seq: seq))
        }
        // The adapter reassembles transfers before ops reach the session.
        guard case .inline(let newBytes) = payload.bulk else {
            return .rejected(.reject(docId: docId, opId: opId, reason: "unresolvedTransfer", seq: seq))
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

    private func broadcast(_ message: ServerMessage) {
        for (token, continuation) in subscribers {
            switch continuation.yield(message) {
            case .dropped, .terminated:
                // Bounded-buffer overflow (or consumer gone): disconnect; the
                // client recovers by re-subscribing (fresh snapshot in v0).
                subscribers.removeValue(forKey: token)?.finish()
            default:
                break
            }
        }
    }
}
