import Foundation
import InfSketchWire

/// Bridges the MCP `create_doc` tool (which `await`s the resulting bytes)
/// to the WS layer (which sends `.createDocRequest` down to a connected
/// device and later routes back its `.createDocReply`).
///
/// One broker per server process. `WSAdapter` registers/unregisters a
/// connection's send closure at hello/close; the MCP tool handler calls
/// `requestCreation`; `WSAdapter` routes an inbound `createDocReply` to
/// `handleReply`.
///
/// Every completion path — a reply, a timeout, or the owning connection
/// closing — removes the pending entry, releases the per-docId
/// "creation in progress" guard, and cancels the timeout `Task`. This is
/// centralized in `completePending(_:)` on purpose: the NotificationDebouncer
/// review found this exact class of leak (an entry *reset* instead of
/// *deleted*), so every exit here goes through one deletion path rather than
/// duplicating cleanup at each call site.
public actor CreateDocBroker {
    public enum CreateDocError: Error, Equatable {
        case noDeviceAvailable
        case creationInProgress
        case deviceTimeout
        case deviceFailed(String)
    }

    /// A createDoc-capable connection registered by `WSAdapter` at hello.
    private struct Connection {
        let id: UUID
        let send: @Sendable (ServerMessage) -> Void
    }

    private struct PendingRequest {
        let docId: String
        let connectionId: UUID
        let continuation: CheckedContinuation<Data, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let timeout: Duration

    /// Ordered oldest → newest; the last element is the most-recently
    /// registered connection, which `requestCreation` prefers.
    private var connections: [Connection] = []
    private var pending: [UInt32: PendingRequest] = [:]
    /// docIds with a request currently in flight — the "creationInProgress" guard.
    private var docIdsInFlight: Set<String> = []
    private var nextRequestId: UInt32 = 1

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    /// WSAdapter calls at hello when capabilities contains "createDoc".
    /// Most-recently-registered connection is preferred for new requests.
    public func register(connectionId: UUID, send: @escaping @Sendable (ServerMessage) -> Void) {
        connections.removeAll { $0.id == connectionId }
        connections.append(Connection(id: connectionId, send: send))
    }

    /// WSAdapter calls on connection close. Fails that connection's pending
    /// requests immediately with .deviceTimeout.
    public func unregister(connectionId: UUID) {
        connections.removeAll { $0.id == connectionId }
        let affected = pending.filter { $0.value.connectionId == connectionId }.map(\.key)
        for requestId in affected {
            guard let entry = completePending(requestId) else { continue }
            entry.continuation.resume(throwing: CreateDocError.deviceTimeout)
        }
    }

    /// MCP tool entry point. Throws CreateDocError.
    public func requestCreation(docId: String) async throws -> Data {
        guard let connection = connections.last else {
            throw CreateDocError.noDeviceAvailable
        }
        guard !docIdsInFlight.contains(docId) else {
            throw CreateDocError.creationInProgress
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

            connection.send(.createDocRequest(requestId: requestId, docId: docId))

            let timeoutDuration = timeout
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeoutDuration)
                guard !Task.isCancelled else { return }
                await self?.timeoutFired(requestId: requestId)
            }
            pending[requestId]?.timeoutTask = timeoutTask
        }
    }

    /// WSAdapter routes createDocReply here. Unknown/expired requestId → log + drop.
    public func handleReply(requestId: UInt32, bytes: Data?, failureReason: String?) {
        guard let entry = completePending(requestId) else {
            print("[CreateDocBroker] dropping createDocReply for unknown/expired requestId \(requestId)")
            return
        }
        if let failureReason {
            entry.continuation.resume(throwing: CreateDocError.deviceFailed(failureReason))
        } else {
            entry.continuation.resume(returning: bytes ?? Data())
        }
    }

    private func timeoutFired(requestId: UInt32) {
        guard let entry = completePending(requestId) else { return }
        entry.continuation.resume(throwing: CreateDocError.deviceTimeout)
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
