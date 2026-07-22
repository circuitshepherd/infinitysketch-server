import Foundation
import InfSketchWire

/// Bridges MCP tools that `await` bytes solicited live from a connected
/// InfinitySketch device — `create_doc` (Task 3) and the agent
/// stroke-authoring tool (Task 4, `requestStrokeOp`) — to the WS layer
/// (which sends a `*Request` message down to a connected device and later
/// routes back its `*Reply`).
///
/// One broker per server process. `WSAdapter` registers/unregisters a
/// connection's send closure + capability set at hello/close; MCP tool
/// handlers call `requestCreation` / `requestStrokeOp`; `WSAdapter` routes an
/// inbound `createDocReply` / `strokeOpReply` to `handleReply` (kind-agnostic
/// — it resolves purely by `requestId`).
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
        let capabilities: Set<String>
        let send: @Sendable (ServerMessage) -> Void
    }

    private struct PendingRequest {
        let docId: String
        let connectionId: UUID
        let continuation: CheckedContinuation<StrokeOpReply, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let createTimeout: Duration
    private let strokeOpTimeout: Duration

    /// Ordered oldest → newest; the last capability-matching element is the
    /// most-recently-registered connection, which request methods prefer.
    private var connections: [Connection] = []
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
        connectionId: UUID, capabilities: Set<String>, send: @escaping @Sendable (ServerMessage) -> Void
    ) {
        connections.removeAll { $0.id == connectionId }
        connections.append(Connection(id: connectionId, capabilities: capabilities, send: send))
    }

    /// WSAdapter calls on connection close. Fails that connection's pending
    /// requests immediately with .deviceTimeout.
    public func unregister(connectionId: UUID) {
        connections.removeAll { $0.id == connectionId }
        let affected = pending.filter { $0.value.connectionId == connectionId }.map(\.key)
        for requestId in affected {
            guard let entry = completePending(requestId) else { continue }
            entry.continuation.resume(throwing: DeviceCommandError.deviceTimeout)
        }
    }

    /// MCP `create_doc` entry point. Throws DeviceCommandError.
    public func requestCreation(docId: String) async throws -> Data {
        try await performRequest(docId: docId, capability: "createDoc", timeout: createTimeout) {
            connection, requestId in
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
        try await performRequest(docId: docId, capability: capability, timeout: strokeOpTimeout) {
            connection, requestId in
            connection.send(
                .strokeOpRequest(requestId: requestId, docId: docId, payload: .inline(docBytes), spec: spec))
        }
    }

    /// WSAdapter routes createDocReply/strokeOpReply here — kind-agnostic,
    /// resolved purely by requestId. Unknown/expired requestId → log + drop.
    /// `meta` is non-nil only for replies that carry metadata (render/preview,
    /// selection descriptors, or an authoring op's created ids — see requestStrokeOp);
    /// createDocReply routing always passes the default `nil`.
    public func handleReply(requestId: UInt32, bytes: Data?, meta: Data? = nil, failureReason: String?) {
        guard let entry = completePending(requestId) else {
            print("[DeviceCommandBroker] dropping reply for unknown/expired requestId \(requestId)")
            return
        }
        if let failureReason {
            entry.continuation.resume(throwing: DeviceCommandError.deviceFailed(failureReason))
        } else {
            entry.continuation.resume(returning: StrokeOpReply(bytes: bytes ?? Data(), meta: meta))
        }
    }

    /// Shared request path for both `requestCreation` and `requestStrokeOp`:
    /// capability-filtered most-recent connection selection, the shared
    /// per-docId in-flight guard, atomic actor-turn continuation
    /// registration (no awaits before the send + timeout-task wiring), and a
    /// per-kind timeout. `send` fires synchronously inside the continuation
    /// closure — never suspends — so the reply-routing side can never race
    /// this registration into existence.
    private func performRequest(
        docId: String, capability: String, timeout: Duration,
        send: @escaping (Connection, UInt32) -> Void
    ) async throws -> StrokeOpReply {
        guard let connection = connections.last(where: { $0.capabilities.contains(capability) }) else {
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
                docId: docId, connectionId: connection.id, continuation: continuation)

            send(connection, requestId)

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
