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
    public init(
        gracePeriod: Duration = .seconds(60),
        outboundBufferLimit: Int = 256,
        inlineLimit: Int = 256 * 1024,
        chunkSize: Int = 512 * 1024
    ) {
        self.gracePeriod = gracePeriod
        self.outboundBufferLimit = outboundBufferLimit
        self.inlineLimit = inlineLimit
        self.chunkSize = chunkSize
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

/// Per-document hub: current bytes, seq counter, subscriber fan-out.
/// Grace-period teardown lives in SessionManager, not here.
actor DocumentSession {
    let docId: String
    private let store: any DocumentStore
    private let bufferLimit: Int
    private var bytes: Data
    private(set) var seq = 0
    private var subscribers: [UUID: AsyncStream<ServerMessage>.Continuation] = [:]

    init(docId: String, store: any DocumentStore, bufferLimit: Int) throws {
        self.docId = docId
        self.store = store
        self.bufferLimit = bufferLimit
        self.bytes = try store.load(docId: docId)
    }

    var subscriberCount: Int { subscribers.count }

    func subscribe() -> SubscribeResult {
        let token = UUID()
        let (stream, continuation) = AsyncStream<ServerMessage>.makeStream(
            bufferingPolicy: .bufferingOldest(bufferLimit))
        subscribers[token] = continuation
        return SubscribeResult(
            snapshot: .subscribed(docId: docId, seq: seq, snapshot: .inline(bytes)),
            events: stream,
            token: token)
    }

    func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)?.finish()
    }

    /// Returns nil when accepted (the broadcast echo is the submitter's ack),
    /// or a .reject to deliver to the submitter only.
    func submit(opId: String, payload: OpPayload) -> ServerMessage? {
        guard payload.type == "fullDoc" else {
            return .reject(docId: docId, opId: opId, reason: "unsupportedPayloadType", seq: seq)
        }
        // The adapter reassembles transfers before ops reach the session.
        guard case .inline(let newBytes) = payload.bulk else {
            return .reject(docId: docId, opId: opId, reason: "unresolvedTransfer", seq: seq)
        }
        do {
            try store.save(docId: docId, bytes: newBytes)
        } catch {
            FileHandle.standardError.write(Data("store.save failed for '\(docId)': \(error)\n".utf8))
            return .reject(docId: docId, opId: opId, reason: "storeFailure", seq: seq)
        }
        bytes = newBytes
        seq += 1
        broadcast(.event(docId: docId, seq: seq, kind: "op", opId: opId, payload: payload))
        return nil
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
