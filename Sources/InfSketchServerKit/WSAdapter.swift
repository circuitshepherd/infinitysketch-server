import Foundation
import FlyingFox

/// Bridges one WebSocket connection to the SessionManager.
/// FlyingFox calls makeMessages once per connection.
public struct WSAdapter: WSMessageHandler, Sendable {
    private let manager: SessionManager
    private let config: SessionConfig

    public init(manager: SessionManager, config: SessionConfig = SessionConfig()) {
        self.manager = manager
        self.config = config
    }

    public func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        // KNOWN GAP: this output stream is unbounded, and FlyingFox itself
        // drains it eagerly into another unbounded buffer before the socket
        // writer — so the session-level bounded-buffer disconnect (DocumentSession)
        // never engages for a slow *socket*. A stalled client therefore buffers
        // events in memory until keepalive/reaping (future plan) drops it.
        let (output, outputCont) = AsyncStream<WSMessage>.makeStream()
        let connection = Connection(manager: manager, output: outputCont, config: config)
        Task {
            for await frame in client {
                await connection.handle(frame)
            }
            await connection.close()
        }
        return output
    }
}

/// Per-connection state machine: hello gate, doc subscriptions, status subscription.
actor Connection {
    private let manager: SessionManager
    private let output: AsyncStream<WSMessage>.Continuation
    private var sender: TransferSender<ServerMessage>
    private var reassembler = TransferReassembler<ClientMessage>()
    private var helloed = false
    private var closed = false
    private var docSubscriptions: [String: (token: UUID, pump: Task<Void, Never>)] = [:]
    private var statusSubscription: (token: UUID, pump: Task<Void, Never>)?

    init(manager: SessionManager, output: AsyncStream<WSMessage>.Continuation, config: SessionConfig) {
        self.manager = manager
        self.output = output
        self.sender = TransferSender(inlineLimit: config.inlineLimit, chunkSize: config.chunkSize)
    }

    func handle(_ frame: WSMessage) async {
        guard !closed else { return }
        let wire: WireFrame
        switch frame {
        case .close:
            await close()
            return
        case .text(let text):
            wire = .text(text)
        case .data(let data):
            wire = .binary(data)
        }
        let message: ClientMessage?
        // TODO(hardening): frames reach the reassembler before the hello gate —
        // when auth lands, gate or bound pre-hello transfer bytes.
        do {
            message = try reassembler.consume(wire)
        } catch let error as TransferWireError {
            // Transfer state is positional — once violated the stream can't
            // be trusted. Connection-fatal per the chunked-transfer spec.
            FileHandle.standardError.write(Data("transfer violation on connection: \(error)\n".utf8))
            emit(.error(reason: "transferViolation"))
            await close()
            return
        } catch {
            emit(.error(reason: "malformedMessage"))
            return
        }
        guard let message else { return }   // chunk consumed / transfer opened / aborted
        await dispatch(message)
    }

    private func dispatch(_ message: ClientMessage) async {
        switch message {
        case .hello(let version, _):
            guard version == WireProtocol.version else {
                emit(.error(reason: "unsupportedVersion"))
                await close()
                return
            }
            helloed = true
            emit(.helloAck(protocolVersion: WireProtocol.version))

        case _ where !helloed:
            emit(.error(reason: "helloRequired"))

        case .subscribe(let docId, _):
            // v0: fromSeq ignored — always a full snapshot.
            guard docSubscriptions[docId] == nil else {
                return emit(.error(reason: "alreadySubscribed"))
            }
            do {
                let result = try await manager.subscribe(docId: docId)
                emit(result.snapshot)
                docSubscriptions[docId] = (result.token, pump(result.events, docId: docId, token: result.token))
            } catch {
                emit(.error(reason: "unknownDoc"))
            }

        case .unsubscribe(let docId):
            if let sub = docSubscriptions.removeValue(forKey: docId) {
                sub.pump.cancel()
                await manager.unsubscribe(docId: docId, token: sub.token)
            }

        case .op(let docId, let opId, let payload):
            guard docSubscriptions[docId] != nil else {
                return emit(.error(reason: "notSubscribed"))
            }
            if let reject = await manager.submit(docId: docId, opId: opId, payload: payload) {
                emit(reject)
            }

        case .subscribeStatus:
            guard statusSubscription == nil else { return }
            let (events, token) = await manager.subscribeStatus()
            statusSubscription = (token, pump(events, docId: nil, token: token))

        case .unsubscribeStatus:
            if let sub = statusSubscription {
                statusSubscription = nil
                sub.pump.cancel()
                await manager.unsubscribeStatus(sub.token)
            }

        case .transferEnd, .transferAbort:
            // Unreachable: the reassembler consumes these or throws.
            emit(.error(reason: "transferViolation"))
            await close()
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        for (docId, sub) in docSubscriptions {
            sub.pump.cancel()
            await manager.unsubscribe(docId: docId, token: sub.token)
        }
        docSubscriptions.removeAll()
        if let sub = statusSubscription {
            statusSubscription = nil
            sub.pump.cancel()
            await manager.unsubscribeStatus(sub.token)
        }
        output.finish()
    }

    /// Called by a pump on natural (server-initiated) stream completion:
    /// clears connection-local bookkeeping and releases the manager-side
    /// subscription so a later client re-subscribe works.
    private func releaseDocSubscription(docId: String, token: UUID) async {
        if let sub = docSubscriptions[docId], sub.token == token {
            docSubscriptions.removeValue(forKey: docId)
        }
        await manager.unsubscribe(docId: docId, token: token)
    }

    private func releaseStatusSubscription(token: UUID) async {
        if let sub = statusSubscription, sub.token == token {
            statusSubscription = nil
        }
        await manager.unsubscribeStatus(token)
    }

    /// Forwards session events out through emit(_:). When the stream
    /// finishes server-side (e.g. buffer-overflow disconnect), releases the
    /// subscription so SessionManager's count stays accurate.
    private func pump(
        _ events: AsyncStream<ServerMessage>, docId: String?, token: UUID
    ) -> Task<Void, Never> {
        Task {
            // This unstructured Task inherits Connection's actor isolation,
            // so emit is a same-actor synchronous call — no await. If a
            // future Swift changed that inheritance, this would fail to
            // compile (cross-actor isolated calls require await) instead of
            // silently losing the serialized-output guarantee.
            for await event in events {
                self.emit(event)
            }
            guard !Task.isCancelled else { return }
            if let docId {
                await self.releaseDocSubscription(docId: docId, token: token)
            } else {
                await self.releaseStatusSubscription(token: token)
            }
        }
    }

    /// Single serialized exit point for every outgoing message. Expands
    /// oversized bulk payloads into descriptor + chunks + end; actor
    /// isolation (and no suspension inside) keeps each expansion's frames
    /// contiguous on the socket — the one-in-flight-per-direction rule
    /// holds by construction.
    private func emit(_ message: ServerMessage) {
        guard let frames = try? sender.frames(for: message) else { return }
        for frame in frames {
            switch frame {
            case .text(let json): output.yield(.text(json))
            case .binary(let data): output.yield(.data(data))
            }
        }
    }
}
