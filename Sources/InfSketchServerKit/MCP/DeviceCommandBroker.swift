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
        case deviceFailed(String)
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
    }

    private struct PendingRequest {
        let docId: String
        let connectionId: UUID
        let continuation: CheckedContinuation<StrokeOpReply, Error>
        var timeoutTask: Task<Void, Never>?
        /// The document bytes this request CARRIED. A device may answer with the blobs left out —
        /// it was just sent them, so it knows we have them — and this is what they are spliced back
        /// from. Empty for requests that send no document.
        let sentBytes: Data
    }

    private let createTimeout: Duration
    private let strokeOpTimeout: Duration

    /// Ordered oldest → newest; the last capability-matching element is the
    /// most-recently-registered connection, which request methods prefer.
    private var connections: [Connection] = []
    /// The document bytes most recently SENT to each connection, per docId — the base a
    /// stripped REQUEST is cut against (M4, spec 2026-08-03-request-blob-stripping-design.md).
    /// Agent ops come in bursts against one document, and each request is itself the shared
    /// document the next one needs; the first op pays full price, every later one ships the
    /// delta. Updated at SEND time, optimistically: drift from a failed round trip is caught by
    /// the digest checks and costs one whole resend (`cannotReconstructRequest` below). Ordered
    /// oldest → newest per connection for LRU eviction under `ledgerBudgetPerConnection`.
    private var lastSentDocs: [UUID: [(docId: String, bytes: Data)]] = [:]
    private let ledgerBudgetPerConnection = 32 * 1024 * 1024   // the retainedBases budget
    private var pending: [UInt32: PendingRequest] = [:]
    /// docIds with a request currently in flight — the "requestInFlight"
    /// guard. Shared across request kinds by construction (keyed only by
    /// docId, not kind).
    private var docIdsInFlight: Set<String> = []
    private var nextRequestId: UInt32 = 1

    public init(createTimeout: Duration = .seconds(10), strokeOpTimeout: Duration = .seconds(20)) {
        self.createTimeout = createTimeout
        self.strokeOpTimeout = strokeOpTimeout
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
                                      capabilities: capabilities, send: send))
    }

    /// How many devices are connected, and the union of what they can do. Read only to make
    /// `noDeviceAvailable` say WHY (spec 2026-07-27-actionable-tool-errors-design.md): "no device
    /// is connected" and "a device is connected but none offers `controlSelection`" are different
    /// problems with different fixes, and the bare reason string tells them apart for nobody.
    public func connectionSummary() -> (count: Int, capabilities: Set<String>) {
        (connections.count, connections.reduce(into: Set<String>()) { $0.formUnion($1.capabilities) })
    }

    /// WSAdapter calls on connection close. Fails that connection's pending
    /// requests immediately with .deviceTimeout.
    public func unregister(connectionId: UUID) {
        connections.removeAll { $0.id == connectionId }
        lastSentDocs[connectionId] = nil
        let affected = pending.filter { $0.value.connectionId == connectionId }.map(\.key)
        for requestId in affected {
            guard let entry = completePending(requestId) else { continue }
            entry.continuation.resume(throwing: DeviceCommandError.deviceTimeout)
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
    public func requestStrokeOp(
        docId: String, docBytes: Data, spec: Data, capability: String = "authorStrokes"
    ) async throws -> StrokeOpReply {
        do {
            return try await sendStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                          capability: capability, allowStripping: true)
        } catch DeviceCommandError.deviceFailed(let reason)
            where reason.hasPrefix(BlobOmissionWire.cannotReconstructRequestReason) {
            // The device lost its copy (relaunch, eviction) or the ledger drifted past it — a
            // CACHE problem, not an op problem, so it must not surface as a tool error. Forget
            // what we thought it held and retry the SAME op once, whole. A second failure is a
            // genuine device failure and surfaces normally.
            forgetSentDoc(docId: docId)
            return try await sendStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                          capability: capability, allowStripping: false)
        }
    }

    private func sendStrokeOp(
        docId: String, docBytes: Data, spec: Data, capability: String, allowStripping: Bool
    ) async throws -> StrokeOpReply {
        try await performRequest(docId: docId, capability: capability, timeout: strokeOpTimeout,
                                 sentBytes: docBytes) { broker, connection, requestId in
            // The strip decision needs the CHOSEN connection, so it lives here — the closure
            // runs isolated on the broker, which is what lets it read and update the ledger
            // synchronously. `sentBytes` above stays the WHOLE document regardless — it is what
            // the device's stripped REPLY is spliced back from (M2), and the device replies
            // against the whole content it reconstructs, never against what rode the wire.
            let payload = broker.requestPayload(for: connection, docId: docId,
                                                docBytes: docBytes,
                                                allowStripping: allowStripping)
            connection.send(.strokeOpRequest(requestId: requestId, docId: docId,
                                             payload: .inline(payload.bytes), spec: spec,
                                             payloadKind: payload.kind))
        }
    }

    /// Decide what a request's payload IS for this connection, and keep the ledger current.
    /// Nonisolated-unsafe free of suspension: called synchronously on the actor from inside
    /// `performRequest`'s send closure.
    private func requestPayload(for connection: Connection, docId: String, docBytes: Data,
                                allowStripping: Bool) -> (bytes: Data, kind: String?) {
        // Empty docBytes (provideContent) is never stripped and never ledgered — an empty entry
        // would poison the next strip. The capability gate mirrors the broadcast direction:
        // a peer that has not said `blobOmission` gets whole documents forever.
        guard !docBytes.isEmpty else { return (docBytes, nil) }
        defer { rememberSentDoc(connectionId: connection.id, docId: docId, bytes: docBytes) }
        guard allowStripping,
              connection.capabilities.contains("blobOmission"),
              let base = lastSentDocs[connection.id]?.first(where: { $0.docId == docId })?.bytes
        else { return (docBytes, nil) }
        let stripped = StrippedDocument.strip(
            document: docBytes, against: base,
            basedOn: Data(SHA256.hash(data: base)),
            originalSHA256: Data(SHA256.hash(data: docBytes)))
        // Only pay for the alternative payload when something was actually left out — a document
        // with no shared blobs strips to one literal part, the same bytes in a wrapper (M1's rule).
        let omittedSomething = stripped.parts.contains {
            if case .blob = $0 { return true } else { return false }
        }
        guard omittedSomething else { return (docBytes, nil) }
        return (stripped.encoded(), BlobOmissionWire.strippedDocKind)
    }

    private func rememberSentDoc(connectionId: UUID, docId: String, bytes: Data) {
        var entries = lastSentDocs[connectionId] ?? []
        entries.removeAll { $0.docId == docId }
        entries.append((docId, bytes))
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
        if payloadKind == "strippedDoc" {
            guard let stripped = try? StrippedDocument(encoded: resolved),
                  stripped.basedOn == Data(SHA256.hash(data: entry.sentBytes)),
                  let rebuilt = try? stripped.restore(using: entry.sentBytes),
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
    /// `requestProvideContent`: capability-filtered most-recent connection
    /// selection — narrowed to ONE named device when `deviceId` is non-nil
    /// (M2c-1: only a device that HAS a document can serve its content;
    /// passing nil keeps the original "any capable device" behaviour) — the
    /// shared per-docId in-flight guard, atomic actor-turn continuation
    /// registration (no awaits before the send + timeout-task wiring), and a
    /// per-kind timeout. `send` fires synchronously inside the continuation
    /// closure — never suspends — so the reply-routing side can never race
    /// this registration into existence.
    private func performRequest(
        docId: String, capability: String, timeout: Duration, deviceId: String? = nil,
        sentBytes: Data = Data(),
        send: @escaping (isolated DeviceCommandBroker, Connection, UInt32) -> Void
    ) async throws -> StrokeOpReply {
        guard let connection = connections.last(where: {
            $0.capabilities.contains(capability) && (deviceId == nil || $0.deviceId == deviceId)
        }) else {
            throw DeviceCommandError.noDeviceAvailable
        }
        guard !docIdsInFlight.contains(docId) else {
            throw DeviceCommandError.requestInFlight
        }
        docIdsInFlight.insert(docId)

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
                sentBytes: sentBytes)

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
        docIdsInFlight.remove(entry.docId)
        entry.timeoutTask?.cancel()
        return entry
    }
}
