import Foundation
import FlyingFox

/// Bridges one WebSocket connection to the SessionManager.
/// FlyingFox calls makeMessages once per connection.
public struct WSAdapter: WSMessageHandler, Sendable {
    private let manager: SessionManager

    public init(manager: SessionManager) {
        self.manager = manager
    }

    public func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        let (output, outputCont) = AsyncStream<WSMessage>.makeStream()
        let connection = Connection(manager: manager, output: outputCont)
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
    private var helloed = false
    private var closed = false
    private var docSubscriptions: [String: (token: UUID, pump: Task<Void, Never>)] = [:]
    private var statusSubscription: (token: UUID, pump: Task<Void, Never>)?

    init(manager: SessionManager, output: AsyncStream<WSMessage>.Continuation) {
        self.manager = manager
        self.output = output
    }

    func handle(_ frame: WSMessage) async {
        guard !closed else { return }
        guard case .text(let text) = frame else {
            return send(.error(reason: "expectedTextFrame"))
        }
        guard let message = try? ClientMessage(jsonText: text) else {
            return send(.error(reason: "malformedMessage"))
        }
        switch message {
        case .hello(let version, _):
            guard version == WireProtocol.version else {
                send(.error(reason: "unsupportedVersion"))
                await close()
                return
            }
            helloed = true
            send(.helloAck(protocolVersion: WireProtocol.version))

        case _ where !helloed:
            send(.error(reason: "helloRequired"))

        case .subscribe(let docId, _):
            // v0: fromSeq ignored — always a full snapshot.
            guard docSubscriptions[docId] == nil else {
                return send(.error(reason: "alreadySubscribed"))
            }
            do {
                let result = try await manager.subscribe(docId: docId)
                send(result.snapshot)
                docSubscriptions[docId] = (result.token, pump(result.events, docId: docId, token: result.token))
            } catch {
                send(.error(reason: "unknownDoc"))
            }

        case .unsubscribe(let docId):
            if let sub = docSubscriptions.removeValue(forKey: docId) {
                sub.pump.cancel()
                await manager.unsubscribe(docId: docId, token: sub.token)
            }

        case .op(let docId, let opId, let payload):
            guard docSubscriptions[docId] != nil else {
                return send(.error(reason: "notSubscribed"))
            }
            if let reject = await manager.submit(docId: docId, opId: opId, payload: payload) {
                send(reject)
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

    /// Forwards session events out as JSON text frames. When the stream
    /// finishes server-side (e.g. buffer-overflow disconnect), releases the
    /// subscription so SessionManager's count stays accurate.
    private func pump(
        _ events: AsyncStream<ServerMessage>, docId: String?, token: UUID
    ) -> Task<Void, Never> {
        Task { [manager, output] in
            for await event in events {
                guard let json = try? event.jsonText() else { continue }
                output.yield(.text(json))
            }
            guard !Task.isCancelled else { return }
            if let docId {
                await manager.unsubscribe(docId: docId, token: token)
            } else {
                await manager.unsubscribeStatus(token)
            }
        }
    }

    private func send(_ message: ServerMessage) {
        guard let json = try? message.jsonText() else { return }
        output.yield(.text(json))
    }
}
