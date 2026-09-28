import Foundation
import InfSketchWire
import Crypto

/// Bridges MCP tools that `await` bytes solicited live from a connected
/// InfinitySketch device — `create_doc` (Task 3) and the agent
/// stroke-authoring tool (Task 4, `requestStrokeOp`) — to the WS layer
/// (which sends a `*Request` message down to a connected device and later
/// routes back its `*Reply`).
///
/// One broker per server process. `WSAdapter` registers/unregisters a
/// connection's send closure + capability set + `deviceId` at hello/close; MCP tool
/// handlers call `requestCreation` / `requestStrokeOp`; `WSAdapter` routes an
/// inbound `createDocReply` / `strokeOpReply` to `handleReply` (kind-agnostic
/// — it resolves purely by `requestId`).
///
/// M2c-1 adds a second addressing mode alongside "any device with capability X":
/// `requestProvideContent` targets ONE named `deviceId`, because only a device that
/// actually holds a document can hand over its content. All holders are equal — the
/// caller picks one and falls back to the next if it fails.
///
/// Every completion path — a reply, a timeout, or the owning connection
/// closing — removes the pending entry, releases the per-docId "request in
/// progress" guard (shared across both request kinds: a pending create for
/// docId "D" blocks a stroke op on "D" and vice versa), and cancels the
/// timeout `Task`. This is centralized in `completePending(_:)` on purpose:
/// the NotificationDebouncer review found this exact class of leak (an entry
/// *reset* instead of *deleted*), so every exit here goes through one
/// deletion path rather than duplicating cleanup at each call site.
public actor DeviceCommandBroker {
    public enum DeviceCommandError: Error, Equatable {
        case noDeviceAvailable
        case requestInFlight
        case deviceTimeout
        /// The device's connection closed while the request was outstanding. Distinct from
        /// `deviceTimeout` because the causes and the cures differ: a device that went away is
        /// not slow, and a socket the device dropped (an oversized frame, the app backgrounded)
        /// used to be reported as a timeout that nobody could explain.
        case deviceDisconnected
        /// A live-state op (the user's selection) and no capable connected device has the
        /// document open. Distinct from `noDeviceAvailable`: a device is there, the document is
        /// not open on it, and sending the op to it anyway could only answer "nothing selected".
        case documentNotOpen
        case deviceFailed(String)
    }

    /// Which devices a request may go to, relative to the ones that have its document OPEN.
    ///
    /// The broker used to pick by capability alone — the device that most recently spoke — so
    /// with an iPad holding a selection and a Mac connected later, `transform_selection` went to
    /// the Mac and failed `noSelectionActive`, an omitted colour came from the Mac's pen and
    /// `render_sketch` lost the iPad's viewport (review finding 20).
    enum Routing: Equatable {
        /// Any capable device: the op names no open document (creating one, fetching from a
        /// named holder).
        case any
        /// A device with the document open when there is one, else any capable device. For ops
        /// on bytes whose answer is better from the device the user is looking at — the pen an
        /// omitted colour inherits, the viewport a render reports — but valid from any.
        case preferOpen
        /// Only a device with the document open: the op acts on LIVE state that exists only
        /// there.
        case requireOpen

        static func `for`(capability: String) -> Routing {
            switch capability {
            case "controlSelection": return .requireOpen
            case "createDoc", "provideContent": return .any
            default: return .preferOpen
            }
        }
    }

    /// The connections subscribed to a document — `SessionManager.subscribedConnections`, set by
    /// `InfSketchServer`. Unset (a broker in a unit test), every request routes as `.any`.
    public typealias SubscriberLookup = @Sendable (String) async -> Set<UUID>
    private var subscriberLookup: SubscriberLookup?

    public func setSubscriberLookup(_ lookup: @escaping SubscriberLookup) {
        subscriberLookup = lookup
    }

    /// How long past its timeout a request stays valid on the device. The device judges the
    /// deadline in THIS machine's clock (`ServerClock`, sampled at hello and on every ping), so
    /// the allowance no longer has to cover clock skew — only the latency of those samples, which
    /// the device's estimate can overshoot by at most one one-way trip. The failure the deadline
    /// exists for is MINUTES late (a suspended iPad waking up); 2 s keeps an op the agent was
    /// told timed out from landing much after that answer.
    static let deadlineSkewAllowance: Duration = .seconds(2)

    /// `notAfter` for a request sent now with `timeout`: Unix milliseconds.
    static func deadline(after timeout: Duration, now: Date = Date()) -> Int {
        let seconds = Double((timeout + deadlineSkewAllowance).components.seconds)
            + Double((timeout + deadlineSkewAllowance).components.attoseconds) / 1e18
        return Int((now.timeIntervalSince1970 + seconds) * 1000)
    }

    /// `requestStrokeOp`'s result: the reply's bytes (doc bytes for
    /// draw/delete, listing JSON for list, a PNG for render) plus an optional
    /// metadata JSON. `meta` carries render metadata AND the selection ops'
    /// descriptor JSON (get_selection / transform_selection / select_*), which
    /// reply with `meta` and NO bytes — a success WSAdapter must not misread as
    /// a failure (see WSAdapterTests.strokeOpReplyWithMetaAndNoBytesIsSuccess).
    public struct StrokeOpReply: Equatable, Sendable {
        public let bytes: Data
        public let meta: Data?

        public init(bytes: Data, meta: Data?) {
            self.bytes = bytes
            self.meta = meta
        }
    }

    /// A connection registered by `WSAdapter` at hello, tagged with the
    /// capability set it advertised. A connection is only ever selected for
    /// a request kind whose required capability it advertised.
    private struct Connection {
        let id: UUID
        /// M2c-1: which device this connection belongs to (from `hello`). Used to address a
        /// SPECIFIC holder for a content fetch — every other request kind picks by capability.
        let deviceId: String?
        let capabilities: Set<String>
        let send: @Sendable (ServerMessage) -> Void
        /// When the peer last sent anything (fed by `noteActivity`); registration counts.
        var lastActivity: ContinuousClock.Instant
    }

    private struct PendingRequest {
        let docId: String
        let connectionId: UUID
        let continuation: CheckedContinuation<StrokeOpReply, Error>
        var timeoutTask: Task<Void, Never>?
        /// The document this request CARRIED. A device may answer with the blobs left out — it was
        /// just sent them, so it knows we have them — and this is what they are spliced back from.
        /// Empty bytes for requests that send no document.
        let sentDoc: SentDocument
        /// Whether this request took `docIdsInFlight` and must release it.
        let holdsDocumentLock: Bool
    }

    /// A document a connection was sent, beside the two derivations of it that BOTH directions of
    /// an agent op need — its digest, and its blob runs.
    ///
    /// A reference type on purpose, so one take is shared by everything that asks: the request that
    /// strips against these bytes, the reply that splices back into them, and the NEXT request,
    /// whose base is this same document (agent ops come in bursts against one document, which is
    /// the whole premise of the ledger). Taking the runs means a whole-document parse — ~62 ms on a
    /// 6.7 MB document, see `BlobRunIndex` — and it was being taken afresh at each of those points.
    ///
    /// Both are lazy: a device that never strips and a document with no images must not pay for
    /// derivations nothing reads.
    private final class SentDocument {
        let docId: String
        let bytes: Data
        private var takenHash: Data?
        private var takenRuns: BlobRunIndex?

        init(docId: String, bytes: Data) {
            self.docId = docId
            self.bytes = bytes
        }

        var hash: Data {
            if let takenHash { return takenHash }
            let value = Data(SHA256.hash(data: bytes))
            takenHash = value
            return value
        }

        var runs: BlobRunIndex {
            if let takenRuns { return takenRuns }
            let value = BlobRunIndex(of: bytes)
            takenRuns = value
            return value
        }
    }

    private let createTimeout: Duration
    private let strokeOpTimeout: Duration

    /// Ordered oldest → newest by registration. Requests go to the capable connection that most
    /// recently SPOKE, registration order breaking ties — see `pickConnection`.
    private var connections: [Connection] = []
    /// The document bytes most recently SENT to each connection, per docId — the base a
    /// stripped REQUEST is cut against (M4, spec 2026-08-03-request-blob-stripping-design.md).
    /// Agent ops come in bursts against one document, and each request is itself the shared
    /// document the next one needs; the first op pays full price, every later one ships the
    /// delta. Updated at SEND time, optimistically: drift from a failed round trip is caught by
    /// the digest checks and costs one whole resend (`cannotReconstructRequest` below). Ordered
    /// oldest → newest per connection for LRU eviction under `ledgerBudgetPerConnection`.
    private var lastSentDocs: [UUID: [SentDocument]] = [:]
    private let ledgerBudgetPerConnection = 32 * 1024 * 1024   // the retainedBases budget
    private var pending: [UInt32: PendingRequest] = [:]
    /// docIds with a request currently in flight — the "requestInFlight"
    /// guard. Shared across request kinds by construction (keyed only by
    /// docId, not kind).
    private var docIdsInFlight: Set<String> = []
    private var nextRequestId: UInt32 = 1

    /// How long a connection may be silent before it counts as possibly ASLEEP when choosing a
    /// device for an op that any device can serve. A live peer answers the keepalive at least this
    /// often (`SessionConfig.keepaliveIdleInterval`), so a quieter one is probably a suspended iPad.
    private let quietAfter: Duration

    public init(createTimeout: Duration = .seconds(10), strokeOpTimeout: Duration = .seconds(20),
                quietAfter: Duration = .seconds(30)) {
        self.createTimeout = createTimeout
        self.strokeOpTimeout = strokeOpTimeout
        self.quietAfter = quietAfter
    }

    /// WSAdapter calls at hello with the connection's full hello capability
    /// set. Most-recently-registered, capability-matching connection is
    /// preferred for new requests of a given kind.
    public func register(
        connectionId: UUID, deviceId: String? = nil, capabilities: Set<String>,
        send: @escaping @Sendable (ServerMessage) -> Void
    ) {
        connections.removeAll { $0.id == connectionId }
        connections.append(Connection(id: connectionId, deviceId: deviceId,
                                      capabilities: capabilities, send: send,
                                      lastActivity: ContinuousClock.now))
    }

    /// The peer on this connection sent something. `WSAdapter` reports it (throttled), so a
    /// device that went to sleep stops looking like the best one to ask.
    public func noteActivity(connectionId: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        connections[index].lastActivity = ContinuousClock.now
    }

    /// The capable connection that most recently SPOKE; among equals, the most recently
    /// registered.
    ///
    /// "Most recently connected" alone chose an iPad that connected after a Mac and then went to
    /// sleep: every agent call waited out the full timeout on the sleeping one while the Mac sat
    /// idle and able (measured: `render_sketch` failed `deviceTimeout` after 20.3 s; review
    /// finding 21). A live device answers the keepalive at least every ~30 s, so it stays ahead
    /// of one that has gone quiet.
    ///
    /// `within`, when given, narrows the candidates to those connections (the ones with the
    /// document open).
    private func pickConnection(capability: String, deviceId: String?,
                                excluding: Set<UUID> = [], within: Set<UUID>? = nil) -> Connection? {
        connections.enumerated()
            .filter { $0.element.capabilities.contains(capability)
                && (deviceId == nil || $0.element.deviceId == deviceId)
                && !excluding.contains($0.element.id)
                && (within == nil || within!.contains($0.element.id)) }
            .max { ($0.element.lastActivity, $0.offset) < ($1.element.lastActivity, $1.offset) }?
            .element
    }

    /// Ops that act on LIVE state on the device (a user's selection) and so must never be sent
    /// twice: a device that was merely slow may still apply the first.
    private static let neverRetriedCapabilities: Set<String> = ["controlSelection"]

    /// How many devices are connected, and the union of what they can do. Read only to make
    /// `noDeviceAvailable` say WHY (spec 2026-07-27-actionable-tool-errors-design.md): "no device
    /// is connected" and "a device is connected but none offers `controlSelection`" are different
    /// problems with different fixes, and the bare reason string tells them apart for nobody.
    public func connectionSummary() -> (count: Int, capabilities: Set<String>) {
        (connections.count, connections.reduce(into: Set<String>()) { $0.formUnion($1.capabilities) })
    }

    /// WSAdapter calls on connection close. Fails that connection's pending
    /// requests immediately with .deviceDisconnected.
    public func unregister(connectionId: UUID) {
        connections.removeAll { $0.id == connectionId }
        lastSentDocs[connectionId] = nil
        let affected = pending.filter { $0.value.connectionId == connectionId }.map(\.key)
        for requestId in affected {
            guard let entry = completePending(requestId) else { continue }
            entry.continuation.resume(throwing: DeviceCommandError.deviceDisconnected)
        }
    }

    /// MCP `create_doc` entry point. Throws DeviceCommandError.
    public func requestCreation(docId: String) async throws -> Data {
        try await performRequest(docId: docId, capability: "createDoc", timeout: createTimeout) {
            _, connection, requestId in
            connection.send(.createDocRequest(requestId: requestId, docId: docId))
        }.bytes
    }

    /// Agent stroke-authoring entry point (Task 4). Throws DeviceCommandError.
    /// The reply's `meta` (when present) carries metadata alongside or instead of
    /// bytes: render/preview metadata JSON, the selection ops' descriptor JSON
    /// (get_selection / transform_selection / select_*, which reply with `meta` and
    /// NO bytes), or the created-id lists some authoring ops report (draw_strokes'
    /// keys, copy_elements' created ids, add_text/add_image's id). Ops that only
    /// mutate the doc bytes (delete/reorder/set_*) resolve with `meta == nil`.
    ///
    /// `capability` defaults to "authorStrokes" (every stroke-op tool). The
    /// styled `add_text`/`edit_text`/`list_fonts` text-authoring tools (Task
    /// 4, styled_text branch) pass "authorText" instead — a device that only
    /// advertises stroke authoring must not be selected for a text-styling
    /// request, and vice versa. Both ride the same `strokeOpRequest`/
    /// `strokeOpReply` wire messages and the same per-docId in-flight guard;
    /// only the capability used to pick a connection differs.
    ///
    /// `takesDocumentLock: false` is the watcher-frame relay's: it renders, writes nothing, and
    /// fires after every accepted write to a watched closed document — holding the agents' lock
    /// there made the agent's NEXT call on that document fail `opInProgress`, and the other way
    /// round failed the relay (review finding 22). Every agent write is compare-and-swap guarded,
    /// so a render running beside one needs no lock.
    ///
    /// `specParts` are op-spec fields too big to sit IN the spec. The spec rides inline in the
    /// message's JSON text frame — `TransferSender` chunks only `bulkBytes`, which is `payload` —
    /// so a whole document base64'd into a spec produced a single frame of ~3.56x the document
    /// size, past the 1 MiB a `URLSessionWebSocketTask` will receive. Handing them here instead
    /// puts them in the payload, through the chunker, and the device splices them back into the
    /// spec before any op handler sees it (`OpSpecBundle`).
    public func requestStrokeOp(
        docId: String, docBytes: Data, spec: Data, capability: String = "authorStrokes",
        specParts: [OpSpecBundleWire.Field: Data] = [:], takesDocumentLock: Bool = true
    ) async throws -> StrokeOpReply {
        do {
            return try await sendStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                          capability: capability, specParts: specParts,
                                          allowStripping: true, takesDocumentLock: takesDocumentLock)
        } catch DeviceCommandError.deviceFailed(let reason)
            where reason.hasPrefix(BlobOmissionWire.cannotReconstructRequestReason) {
            // The device lost its copy (relaunch, eviction) or the ledger drifted past it — a
            // CACHE problem, not an op problem, so it must not surface as a tool error. Forget
            // what we thought it held and retry the SAME op once, whole. A second failure is a
            // genuine device failure and surfaces normally.
            forgetSentDoc(docId: docId)
            return try await sendStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                          capability: capability, specParts: specParts,
                                          allowStripping: false, takesDocumentLock: takesDocumentLock)
        }
    }

    private func sendStrokeOp(
        docId: String, docBytes: Data, spec: Data, capability: String,
        specParts: [OpSpecBundleWire.Field: Data], allowStripping: Bool, takesDocumentLock: Bool
    ) async throws -> StrokeOpReply {
        // A live-selection op acts on the device's OWN open document and never reads the request's
        // bytes (the app's bridge takes only the spec), so it carries none: uploading a large
        // document would only spend the op's deadline before the device could even look at it.
        let isLiveStateOp = Routing.for(capability: capability) == .requireOpen
        let docBytes = isLiveStateOp ? Data() : docBytes
        let readOnlySelectionRead = isLiveStateOp && Self.opName(of: spec) == "getSelection"
        return try await performRequest(docId: docId, capability: capability, timeout: strokeOpTimeout,
                                        sentBytes: docBytes, takesDocumentLock: takesDocumentLock,
                                        nothingSelected: { outcome in
                                            Self.saysNothingSelected(outcome,
                                                                     readOnly: readOnlySelectionRead)
                                        }) { broker, connection, requestId in
            // The strip decision needs the CHOSEN connection, so it lives here — the closure
            // runs isolated on the broker, which is what lets it read and update the ledger
            // synchronously. `sentBytes` above stays the WHOLE document regardless — it is what
            // the device's stripped REPLY is spliced back from (M2), and the device replies
            // against the whole content it reconstructs, never against what rode the wire.
            var payload = broker.requestPayload(for: connection, requestId: requestId,
                                                docId: docId, docBytes: docBytes,
                                                allowStripping: allowStripping)
            // A strict WRAPPER around whatever the document payload already was, so the blob
            // omission above is unchanged and simply travels inside — the device unwraps this,
            // then resolves `primary` by its own kind exactly as before.
            // The spec itself goes the same way once it is too big to sit inline: the text frame
            // is never chunked, and a spec of a few thousand full-attribute points (a large
            // `reshape_strokes`) passed the 1 MiB the app's socket receives — which drops the
            // connection instead of refusing the message.
            var parts = specParts
            var inlineSpec = spec
            if spec.count > OpSpecBundleWire.inlineSpecLimit {
                parts[.spec] = spec
                inlineSpec = Data("{}".utf8)
            }
            if !parts.isEmpty {
                let bundle = OpSpecBundle(primary: payload.bytes, primaryKind: payload.kind,
                                          parts: parts)
                payload = (bundle.encoded(), OpSpecBundleWire.kind)
            }
            connection.send(.strokeOpRequest(requestId: requestId, docId: docId,
                                             payload: .inline(payload.bytes), spec: inlineSpec,
                                             payloadKind: payload.kind,
                                             notAfter: Self.deadline(after: broker.strokeOpTimeout)))
        }
    }

    /// The spec's `op`, when it has one.
    static func opName(of spec: Data) -> String? {
        struct Peek: Decodable { let op: String? }
        return (try? JSONDecoder().decode(Peek.self, from: spec))?.op
    }

    /// Whether a device's answer to a live-selection op means "nothing is selected HERE" — which,
    /// with the document open on several devices, says nothing about the others.
    ///
    /// A refusal `noSelectionActive` always qualifies: every selection op that answers it checks
    /// for a selection before changing anything, so asking the next device is safe. A SUCCESS
    /// qualifies only for the read-only `getSelection` (`active: false`) — `select_all` on an
    /// empty document answers the same way, and asking the next device would select there too.
    static func saysNothingSelected(_ outcome: Result<StrokeOpReply, Error>, readOnly: Bool) -> Bool {
        switch outcome {
        case .failure(DeviceCommandError.deviceFailed(let reason)):
            return reason.hasPrefix("noSelectionActive")
        case .failure:
            return false
        case .success(let reply):
            guard readOnly, let meta = reply.meta,
                  let object = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
                  let active = object["active"] as? Bool else { return false }
            return !active
        }
    }

    /// Decide what a request's payload IS for this connection, and keep the ledger current.
    /// Nonisolated-unsafe free of suspension: called synchronously on the actor from inside
    /// `performRequest`'s send closure.
    private func requestPayload(for connection: Connection, requestId: UInt32,
                                docId: String, docBytes: Data,
                                allowStripping: Bool) -> (bytes: Data, kind: String?) {
        // Empty docBytes (provideContent) is never stripped and never ledgered — an empty entry
        // would poison the next strip. The capability gate mirrors the broadcast direction:
        // a peer that has not said `blobOmission` gets whole documents forever.
        guard !docBytes.isEmpty else { return (docBytes, nil) }
        // The memo the pending entry already holds for exactly these bytes, so the strip here, the
        // reply's rebuild and the NEXT request's base share one take of the digest and the blob
        // runs. That entry is created in this same actor turn, immediately above the send that
        // calls this, so the lookup always hits — and the fallback keeps a miss a matter of SPEED
        // rather than of correctness, because the BYTES come from the caller either way. Deriving
        // the document from the lookup instead would make a miss send the device an EMPTY one.
        let sent = pending[requestId]?.sentDoc ?? SentDocument(docId: docId, bytes: docBytes)
        defer { rememberSentDoc(connectionId: connection.id, document: sent) }
        guard allowStripping,
              connection.capabilities.contains("blobOmission"),
              let base = lastSentDocs[connection.id]?.first(where: { $0.docId == sent.docId })
        else { return (sent.bytes, nil) }
        let stripped = StrippedDocument.strip(
            document: sent.bytes, againstRuns: base.runs,
            basedOn: base.hash,
            originalSHA256: sent.hash)
        // Only pay for the alternative payload when something was actually left out — a document
        // with no shared blobs strips to one literal part, the same bytes in a wrapper (M1's rule).
        let omittedSomething = stripped.parts.contains {
            if case .blob = $0 { return true } else { return false }
        }
        guard omittedSomething else { return (sent.bytes, nil) }
        return (stripped.encoded(), BlobOmissionWire.strippedDocKind)
    }

    private func rememberSentDoc(connectionId: UUID, document: SentDocument) {
        var entries = lastSentDocs[connectionId] ?? []
        entries.removeAll { $0.docId == document.docId }
        entries.append(document)
        var total = entries.reduce(0) { $0 + $1.bytes.count }
        while total > ledgerBudgetPerConnection, !entries.isEmpty {
            total -= entries.removeFirst().bytes.count
        }
        lastSentDocs[connectionId] = entries
    }

    private func forgetSentDoc(docId: String) {
        for key in lastSentDocs.keys {
            lastSentDocs[key]?.removeAll { $0.docId == docId }
        }
    }

    /// M2c-1: ask ONE NAMED device to hand over a document's current bytes. Unlike every other
    /// request kind — which picks any capability-matching connection — this addresses a specific
    /// holder, because only a device that HAS the document can serve it. Rides the existing
    /// strokeOpRequest/strokeOpReply envelope (op `provideContent`); `docBytes` is deliberately
    /// EMPTY, since the device is the one supplying content, not transforming it.
    /// Throws `.noDeviceAvailable` when that device isn't connected (or lacks the capability),
    /// which is the caller's signal to try the next holder.
    public func requestProvideContent(docId: String, deviceId: String) async throws -> Data {
        let spec = try JSONEncoder().encode(["op": "provideContent", "docId": docId])
        return try await performRequest(
            docId: docId, capability: "provideContent", timeout: strokeOpTimeout,
            deviceId: deviceId
        ) { _, connection, requestId in
            connection.send(.strokeOpRequest(
                requestId: requestId, docId: docId, payload: .inline(Data()), spec: spec))
        }.bytes
    }

    /// WSAdapter routes createDocReply/strokeOpReply here — kind-agnostic,
    /// resolved purely by requestId. Unknown/expired requestId → log + drop.
    /// `meta` is non-nil only for replies that carry metadata (render/preview,
    /// selection descriptors, or an authoring op's created ids — see requestStrokeOp);
    /// createDocReply routing always passes the default `nil`.
    public func handleReply(requestId: UInt32, bytes: Data?, meta: Data? = nil,
                            failureReason: String?, payloadKind: String? = nil) {
        guard let entry = completePending(requestId) else {
            ServerLog.verbose("[DeviceCommandBroker] dropping reply for unknown/expired requestId \(requestId)")
            return
        }
        if let failureReason {
            entry.continuation.resume(throwing: DeviceCommandError.deviceFailed(failureReason))
            return
        }

        // The device may leave out the image blobs we sent it — it knows we have them, because we
        // are the ones who sent them. Rebuilt HERE, so every caller downstream receives a whole
        // document exactly as before and none of them learns that anything was omitted.
        //
        // Verified rather than trusted, for the same reason `DocumentSession.submit` verifies: these
        // bytes go on to be stored under a compare-and-swap. A rebuild that does not match the
        // device's own hash of its result is a failure, never a document.
        var resolved = bytes ?? Data()
        if payloadKind == BlobOmissionWire.strippedDocKind {
            guard let stripped = try? StrippedDocument(encoded: resolved),
                  stripped.basedOn == entry.sentDoc.hash,
                  let rebuilt = try? stripped.restore(usingRuns: entry.sentDoc.runs),
                  Data(SHA256.hash(data: rebuilt)) == stripped.originalSHA256
            else {
                entry.continuation.resume(
                    throwing: DeviceCommandError.deviceFailed("cannotReconstruct"))
                return
            }
            DocumentSession.report("\(entry.docId): rebuilt an agent reply, "
                                   + "\(rebuilt.count) B from a \(bytes?.count ?? 0) B payload")
            resolved = rebuilt
        }
        entry.continuation.resume(returning: StrokeOpReply(bytes: resolved, meta: meta))
    }

    /// Shared request path for `requestCreation`, `requestStrokeOp` and
    /// `requestProvideContent`: capability-filtered most-recently-active connection
    /// selection (`pickConnection`), one failover on timeout for pure ops — narrowed to ONE named device when `deviceId` is non-nil
    /// (M2c-1: only a device that HAS a document can serve its content;
    /// passing nil keeps the original "any capable device" behaviour) — the
    /// shared per-docId in-flight guard, atomic actor-turn continuation
    /// registration (no awaits before the send + timeout-task wiring), and a
    /// per-kind timeout. `send` fires synchronously inside the continuation
    /// closure — never suspends — so the reply-routing side can never race
    /// this registration into existence.
    private func performRequest(
        docId: String, capability: String, timeout: Duration, deviceId: String? = nil,
        sentBytes: Data = Data(), takesDocumentLock: Bool = true,
        nothingSelected: ((Result<StrokeOpReply, Error>) -> Bool)? = nil,
        send: @escaping (isolated DeviceCommandBroker, Connection, UInt32) -> Void
    ) async throws -> StrokeOpReply {
        let routing = deviceId == nil ? Routing.for(capability: capability) : .any
        var open: Set<UUID>?
        if routing != .any, let subscriberLookup {
            open = await subscriberLookup(docId)
        }
        let now = ContinuousClock.now
        // A device with the document open first; for `.preferOpen`, any capable one after that.
        func pick(excluding: Set<UUID>) -> Connection? {
            if let open, let preferred = pickConnection(capability: capability, deviceId: deviceId,
                                                        excluding: excluding, within: open) {
                // An op any device can serve does not wait on an open device that has gone quiet
                // (a suspended iPad) while another capable device is demonstrably awake: the pen
                // and viewport it would inherit are worth less than a `deviceTimeout`.
                if routing == .preferOpen, now - preferred.lastActivity > quietAfter,
                   let awake = pickConnection(capability: capability, deviceId: deviceId,
                                              excluding: excluding),
                   now - awake.lastActivity <= quietAfter {
                    return awake
                }
                return preferred
            }
            if routing == .requireOpen, open != nil { return nil }
            return pickConnection(capability: capability, deviceId: deviceId, excluding: excluding)
        }
        guard let first = pick(excluding: []) else {
            // "Nothing can do this at all" and "something could, but not with this document
            // open" have different cures, so they are different errors.
            if pickConnection(capability: capability, deviceId: deviceId) != nil {
                throw DeviceCommandError.documentNotOpen
            }
            throw DeviceCommandError.noDeviceAvailable
        }
        if routing == .requireOpen, let nothingSelected {
            // Live state: the document may be open on several devices, and the selection is on
            // (at most) one. The device asked first answering "nothing selected" says nothing about
            // the others, so ask each open device in turn; only when every one says so is that
            // the answer (the FIRST device's, the most recently active). Never a retry after a
            // timeout — a slow device may still apply the op (`neverRetriedCapabilities`).
            var tried: Set<UUID> = []
            var firstAnswer: Result<StrokeOpReply, Error>?
            var connection = first
            while true {
                tried.insert(connection.id)
                let outcome: Result<StrokeOpReply, Error>
                do {
                    outcome = .success(try await performRequest(
                        on: connection, docId: docId, timeout: timeout, sentBytes: sentBytes,
                        takesDocumentLock: takesDocumentLock, send: send))
                } catch {
                    outcome = .failure(error)
                }
                guard nothingSelected(outcome) else { return try outcome.get() }
                if firstAnswer == nil { firstAnswer = outcome }
                guard let next = pick(excluding: tried) else { return try firstAnswer!.get() }
                ServerLog.verbose("[DeviceCommandBroker] \(capability) on '\(docId)': nothing selected on one open device; asking another")
                connection = next
            }
        }
        do {
            return try await performRequest(
                on: first, docId: docId, timeout: timeout, sentBytes: sentBytes,
                takesDocumentLock: takesDocumentLock, send: send)
        } catch let error as DeviceCommandError
            where (error == .deviceTimeout || error == .deviceDisconnected)
                && deviceId == nil && !Self.neverRetriedCapabilities.contains(capability) {
            // One more try on ANOTHER capable device, for ops that only turn bytes into bytes: a
            // device that answers late (or went away) costs nothing but a discarded reply. A
            // request addressed to one named device (a holder fetch) has no other device to ask.
            guard let next = pick(excluding: [first.id]) else {
                throw error
            }
            ServerLog.verbose("[DeviceCommandBroker] \(capability) on '\(docId)' failed (\(error)); retrying once on another device")
            return try await performRequest(
                on: next, docId: docId, timeout: timeout, sentBytes: sentBytes,
                takesDocumentLock: takesDocumentLock, send: send)
        }
    }

    private func performRequest(
        on connection: Connection, docId: String, timeout: Duration,
        sentBytes: Data, takesDocumentLock: Bool,
        send: @escaping (isolated DeviceCommandBroker, Connection, UInt32) -> Void
    ) async throws -> StrokeOpReply {
        if takesDocumentLock {
            guard !docIdsInFlight.contains(docId) else {
                throw DeviceCommandError.requestInFlight
            }
            docIdsInFlight.insert(docId)
        }

        let requestId = nextRequestId
        nextRequestId &+= 1

        // Whichever completion path fires (reply / timeout / unregister)
        // releases docIdsInFlight via completePending — nothing further to
        // clean up here regardless of how this throws or returns.
        return try await withCheckedThrowingContinuation { continuation in
            // Register BEFORE sending (the MirrorTransport-subscribe
            // idiom): the reply-routing side must always find an entry
            // to resume, never race it into existence.
            pending[requestId] = PendingRequest(
                docId: docId, connectionId: connection.id, continuation: continuation,
                sentDoc: SentDocument(docId: docId, bytes: sentBytes),
                holdsDocumentLock: takesDocumentLock)

            send(self, connection, requestId)

            let timeoutDuration = timeout
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeoutDuration)
                guard !Task.isCancelled else { return }
                await self?.timeoutFired(requestId: requestId)
            }
            pending[requestId]?.timeoutTask = timeoutTask
        }
    }

    private func timeoutFired(requestId: UInt32) {
        guard let entry = completePending(requestId) else { return }
        entry.continuation.resume(throwing: DeviceCommandError.deviceTimeout)
    }

    /// The single deletion path for a pending request: removes the dict
    /// entry, releases the per-docId in-flight guard, and cancels the
    /// timeout task. Every completion path (reply, timeout, unregister)
    /// routes through here so none of the three can be forgotten.
    @discardableResult
    private func completePending(_ requestId: UInt32) -> PendingRequest? {
        guard let entry = pending.removeValue(forKey: requestId) else { return nil }
        if entry.holdsDocumentLock { docIdsInFlight.remove(entry.docId) }
        entry.timeoutTask?.cancel()
        return entry
    }
}
