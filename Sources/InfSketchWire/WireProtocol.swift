import Foundation

public enum WireProtocol {
    public static let version = 1
}

/// A bulk byte field on a wire message: inline for small payloads (v0 shape),
/// or a descriptor announcing a chunked binary transfer for large ones.
/// Session-layer code only ever sees `.inline` — the WS adapter reassembles
/// transfers before messages reach SessionManager.
public enum BulkPayload: Equatable, Sendable {
    case inline(Data)
    case transfer(TransferDescriptor)

    public var inlineData: Data? {
        if case .inline(let data) = self { return data }
        return nil
    }
}

public struct OpPayload: Equatable, Sendable {
    public var type: String
    public var bulk: BulkPayload

    public init(type: String, data: Data) {
        self.type = type
        self.bulk = .inline(data)
    }
    public init(type: String, bulk: BulkPayload) {
        self.type = type
        self.bulk = bulk
    }
}

extension OpPayload: Codable {
    private enum CodingKeys: String, CodingKey { case type, data, transfer }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        if let descriptor = try c.decodeIfPresent(TransferDescriptor.self, forKey: .transfer) {
            bulk = .transfer(descriptor)
        } else {
            bulk = .inline(try c.decode(Data.self, forKey: .data))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch bulk {
        case .inline(let data): try c.encode(data, forKey: .data)
        case .transfer(let descriptor): try c.encode(descriptor, forKey: .transfer)
        }
    }
}

public struct StatusPayload: Codable, Equatable, Sendable {
    public var docId: String
    public var kind: String
    public var seq: Int?
    public var subscriberCount: Int?
    public init(docId: String, kind: String, seq: Int?, subscriberCount: Int?) {
        self.docId = docId
        self.kind = kind
        self.seq = seq
        self.subscriberCount = subscriberCount
    }
}

/// One row of the server's document listing (the WS twin of the REST
/// /api/docs summary; DocSummary stays server-side for the HTTP route).
public struct DocListEntry: Codable, Equatable, Sendable {
    public var id: String
    public var sizeBytes: Int
    public var modifiedAt: Date
    public var seq: Int?
    public var subscriberCount: Int?
    public init(id: String, sizeBytes: Int, modifiedAt: Date, seq: Int?, subscriberCount: Int?) {
        self.id = id
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.seq = seq
        self.subscriberCount = subscriberCount
    }
}

public enum ClientMessage: Equatable, Sendable {
    case hello(protocolVersion: Int, capabilities: [String])
    case subscribe(docId: String, fromSeq: Int?, createIfMissing: Bool)
    case unsubscribe(docId: String)
    case op(docId: String, opId: String, payload: OpPayload)
    case subscribeStatus
    case unsubscribeStatus
    case listDocs
    case transferEnd(transferId: UInt32)
    case transferAbort(transferId: UInt32, reason: String)
    case watchDoc(docId: String)
    case unwatchDoc(docId: String)
    case frame(docId: String, payload: BulkPayload)
    case createDocReply(requestId: UInt32, docId: String, payload: BulkPayload?, failureReason: String?)
}

extension ClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, capabilities, docId, fromSeq, createIfMissing, opId, payload, transferId, reason, data, transfer, requestId, failureReason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                capabilities: try c.decodeIfPresent([String].self, forKey: .capabilities) ?? [])
        case "subscribe":
            self = .subscribe(
                docId: try c.decode(String.self, forKey: .docId),
                fromSeq: try c.decodeIfPresent(Int.self, forKey: .fromSeq),
                createIfMissing: try c.decodeIfPresent(Bool.self, forKey: .createIfMissing) ?? false)
        case "unsubscribe":
            self = .unsubscribe(docId: try c.decode(String.self, forKey: .docId))
        case "op":
            self = .op(
                docId: try c.decode(String.self, forKey: .docId),
                opId: try c.decode(String.self, forKey: .opId),
                payload: try c.decode(OpPayload.self, forKey: .payload))
        case "subscribeStatus":
            self = .subscribeStatus
        case "unsubscribeStatus":
            self = .unsubscribeStatus
        case "listDocs":
            self = .listDocs
        case "transferEnd":
            self = .transferEnd(transferId: try c.decode(UInt32.self, forKey: .transferId))
        case "transferAbort":
            self = .transferAbort(
                transferId: try c.decode(UInt32.self, forKey: .transferId),
                reason: try c.decode(String.self, forKey: .reason))
        case "watchDoc":
            self = .watchDoc(docId: try c.decode(String.self, forKey: .docId))
        case "unwatchDoc":
            self = .unwatchDoc(docId: try c.decode(String.self, forKey: .docId))
        case "frame":
            let payload: BulkPayload
            if let descriptor = try c.decodeIfPresent(TransferDescriptor.self, forKey: .transfer) {
                payload = .transfer(descriptor)
            } else {
                payload = .inline(try c.decode(Data.self, forKey: .data))
            }
            self = .frame(docId: try c.decode(String.self, forKey: .docId), payload: payload)
        case "createDocReply":
            let payload: BulkPayload?
            if let descriptor = try c.decodeIfPresent(TransferDescriptor.self, forKey: .transfer) {
                payload = .transfer(descriptor)
            } else if let data = try c.decodeIfPresent(Data.self, forKey: .data) {
                payload = .inline(data)
            } else {
                payload = nil
            }
            self = .createDocReply(
                requestId: try c.decode(UInt32.self, forKey: .requestId),
                docId: try c.decode(String.self, forKey: .docId),
                payload: payload,
                failureReason: try c.decodeIfPresent(String.self, forKey: .failureReason))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown client message type: \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let v, let caps):
            try c.encode("hello", forKey: .type)
            try c.encode(v, forKey: .protocolVersion)
            try c.encode(caps, forKey: .capabilities)
        case .subscribe(let docId, let fromSeq, let createIfMissing):
            try c.encode("subscribe", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encodeIfPresent(fromSeq, forKey: .fromSeq)
            if createIfMissing { try c.encode(true, forKey: .createIfMissing) }
        case .unsubscribe(let docId):
            try c.encode("unsubscribe", forKey: .type)
            try c.encode(docId, forKey: .docId)
        case .op(let docId, let opId, let payload):
            try c.encode("op", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(opId, forKey: .opId)
            try c.encode(payload, forKey: .payload)
        case .subscribeStatus:
            try c.encode("subscribeStatus", forKey: .type)
        case .unsubscribeStatus:
            try c.encode("unsubscribeStatus", forKey: .type)
        case .listDocs:
            try c.encode("listDocs", forKey: .type)
        case .transferEnd(let transferId):
            try c.encode("transferEnd", forKey: .type)
            try c.encode(transferId, forKey: .transferId)
        case .transferAbort(let transferId, let reason):
            try c.encode("transferAbort", forKey: .type)
            try c.encode(transferId, forKey: .transferId)
            try c.encode(reason, forKey: .reason)
        case .watchDoc(let docId):
            try c.encode("watchDoc", forKey: .type)
            try c.encode(docId, forKey: .docId)
        case .unwatchDoc(let docId):
            try c.encode("unwatchDoc", forKey: .type)
            try c.encode(docId, forKey: .docId)
        case .frame(let docId, let payload):
            try c.encode("frame", forKey: .type)
            try c.encode(docId, forKey: .docId)
            switch payload {
            case .inline(let data): try c.encode(data, forKey: .data)
            case .transfer(let descriptor): try c.encode(descriptor, forKey: .transfer)
            }
        case .createDocReply(let requestId, let docId, let payload, let failureReason):
            try c.encode("createDocReply", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(docId, forKey: .docId)
            switch payload {
            case .inline(let data): try c.encode(data, forKey: .data)
            case .transfer(let descriptor): try c.encode(descriptor, forKey: .transfer)
            case nil: break
            }
            try c.encodeIfPresent(failureReason, forKey: .failureReason)
        }
    }
}

public enum ServerMessage: Equatable, Sendable {
    case helloAck(protocolVersion: Int)
    case subscribed(docId: String, seq: Int, snapshot: BulkPayload)
    case event(docId: String, seq: Int, kind: String, opId: String, payload: OpPayload)
    case reject(docId: String, opId: String, reason: String, seq: Int)
    case resyncRequired(docId: String, seq: Int)
    case statusEvent(payload: StatusPayload)
    case error(reason: String)
    case docList(docs: [DocListEntry])
    case transferEnd(transferId: UInt32)
    case transferAbort(transferId: UInt32, reason: String)
    case frameAvailable(docId: String, seq: Int)
    case watchers(docId: String, count: Int)
    case createDocRequest(requestId: UInt32, docId: String)
}

extension ServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, docId, seq, snapshot, kind, opId, payload, reason, transfer, transferId, count, docs, requestId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "helloAck":
            self = .helloAck(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion))
        case "subscribed":
            let snapshot: BulkPayload
            if let descriptor = try c.decodeIfPresent(TransferDescriptor.self, forKey: .transfer) {
                snapshot = .transfer(descriptor)
            } else {
                snapshot = .inline(try c.decode(Data.self, forKey: .snapshot))
            }
            self = .subscribed(
                docId: try c.decode(String.self, forKey: .docId),
                seq: try c.decode(Int.self, forKey: .seq),
                snapshot: snapshot)
        case "event":
            self = .event(
                docId: try c.decode(String.self, forKey: .docId),
                seq: try c.decode(Int.self, forKey: .seq),
                kind: try c.decode(String.self, forKey: .kind),
                opId: try c.decode(String.self, forKey: .opId),
                payload: try c.decode(OpPayload.self, forKey: .payload))
        case "reject":
            self = .reject(
                docId: try c.decode(String.self, forKey: .docId),
                opId: try c.decode(String.self, forKey: .opId),
                reason: try c.decode(String.self, forKey: .reason),
                seq: try c.decode(Int.self, forKey: .seq))
        case "resyncRequired":
            self = .resyncRequired(
                docId: try c.decode(String.self, forKey: .docId),
                seq: try c.decode(Int.self, forKey: .seq))
        case "statusEvent":
            self = .statusEvent(payload: try c.decode(StatusPayload.self, forKey: .payload))
        case "error":
            self = .error(reason: try c.decode(String.self, forKey: .reason))
        case "docList":
            self = .docList(docs: try c.decode([DocListEntry].self, forKey: .docs))
        case "transferEnd":
            self = .transferEnd(transferId: try c.decode(UInt32.self, forKey: .transferId))
        case "transferAbort":
            self = .transferAbort(
                transferId: try c.decode(UInt32.self, forKey: .transferId),
                reason: try c.decode(String.self, forKey: .reason))
        case "frameAvailable":
            self = .frameAvailable(
                docId: try c.decode(String.self, forKey: .docId),
                seq: try c.decode(Int.self, forKey: .seq))
        case "watchers":
            self = .watchers(
                docId: try c.decode(String.self, forKey: .docId),
                count: try c.decode(Int.self, forKey: .count))
        case "createDocRequest":
            self = .createDocRequest(
                requestId: try c.decode(UInt32.self, forKey: .requestId),
                docId: try c.decode(String.self, forKey: .docId))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown server message type: \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .helloAck(let v):
            try c.encode("helloAck", forKey: .type)
            try c.encode(v, forKey: .protocolVersion)
        case .subscribed(let docId, let seq, let snapshot):
            try c.encode("subscribed", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(seq, forKey: .seq)
            switch snapshot {
            case .inline(let data): try c.encode(data, forKey: .snapshot)
            case .transfer(let descriptor): try c.encode(descriptor, forKey: .transfer)
            }
        case .event(let docId, let seq, let kind, let opId, let payload):
            try c.encode("event", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(seq, forKey: .seq)
            try c.encode(kind, forKey: .kind)
            try c.encode(opId, forKey: .opId)
            try c.encode(payload, forKey: .payload)
        case .reject(let docId, let opId, let reason, let seq):
            try c.encode("reject", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(opId, forKey: .opId)
            try c.encode(reason, forKey: .reason)
            try c.encode(seq, forKey: .seq)
        case .resyncRequired(let docId, let seq):
            try c.encode("resyncRequired", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(seq, forKey: .seq)
        case .statusEvent(let payload):
            try c.encode("statusEvent", forKey: .type)
            try c.encode(payload, forKey: .payload)
        case .error(let reason):
            try c.encode("error", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .docList(let docs):
            try c.encode("docList", forKey: .type)
            try c.encode(docs, forKey: .docs)
        case .transferEnd(let transferId):
            try c.encode("transferEnd", forKey: .type)
            try c.encode(transferId, forKey: .transferId)
        case .transferAbort(let transferId, let reason):
            try c.encode("transferAbort", forKey: .type)
            try c.encode(transferId, forKey: .transferId)
            try c.encode(reason, forKey: .reason)
        case .frameAvailable(let docId, let seq):
            try c.encode("frameAvailable", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(seq, forKey: .seq)
        case .watchers(let docId, let count):
            try c.encode("watchers", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(count, forKey: .count)
        case .createDocRequest(let requestId, let docId):
            try c.encode("createDocRequest", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(docId, forKey: .docId)
        }
    }
}

public extension ClientMessage {
    init(jsonText: String) throws {
        self = try JSONDecoder().decode(ClientMessage.self, from: Data(jsonText.utf8))
    }
    func jsonText() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

public extension ServerMessage {
    init(jsonText: String) throws {
        self = try JSONDecoder().decode(ServerMessage.self, from: Data(jsonText.utf8))
    }
    func jsonText() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}

extension ClientMessage: TransferCarrying {
    public var bulkBytes: Data? {
        switch self {
        case .op(_, _, let payload): return payload.bulk.inlineData
        case .frame(_, let payload): return payload.inlineData
        case .createDocReply(_, _, let payload, _): return payload?.inlineData
        default: return nil
        }
    }
    public func replacingBulk(with descriptor: TransferDescriptor) -> ClientMessage {
        switch self {
        case .op(let docId, let opId, let payload):
            return .op(docId: docId, opId: opId,
                       payload: OpPayload(type: payload.type, bulk: .transfer(descriptor)))
        case .frame(let docId, _):
            return .frame(docId: docId, payload: .transfer(descriptor))
        case .createDocReply(let requestId, let docId, _, let failureReason):
            return .createDocReply(requestId: requestId, docId: docId,
                                    payload: .transfer(descriptor), failureReason: failureReason)
        default:
            return self
        }
    }
    public var openingDescriptor: TransferDescriptor? {
        switch self {
        case .op(_, _, let payload):
            if case .transfer(let d) = payload.bulk { return d }
            return nil
        case .frame(_, .transfer(let d)):
            return d
        case .createDocReply(_, _, let payload, _):
            if case .transfer(let d) = payload { return d }
            return nil
        default: return nil
        }
    }
    public func resolvingBulk(with bytes: Data) -> ClientMessage {
        switch self {
        case .op(let docId, let opId, let payload):
            return .op(docId: docId, opId: opId, payload: OpPayload(type: payload.type, data: bytes))
        case .frame(let docId, _):
            return .frame(docId: docId, payload: .inline(bytes))
        case .createDocReply(let requestId, let docId, _, let failureReason):
            return .createDocReply(requestId: requestId, docId: docId,
                                    payload: .inline(bytes), failureReason: failureReason)
        default:
            return self
        }
    }
    public var transferControl: TransferControl? {
        switch self {
        case .transferEnd(let id): return .end(id)
        case .transferAbort(let id, let reason): return .abort(id, reason: reason)
        default: return nil
        }
    }
    public static func makeTransferEnd(transferId: UInt32) -> ClientMessage {
        .transferEnd(transferId: transferId)
    }
}

extension ServerMessage: TransferCarrying {
    public var bulkBytes: Data? {
        switch self {
        case .subscribed(_, _, let snapshot): return snapshot.inlineData
        case .event(_, _, _, _, let payload): return payload.bulk.inlineData
        default: return nil
        }
    }
    public func replacingBulk(with descriptor: TransferDescriptor) -> ServerMessage {
        switch self {
        case .subscribed(let docId, let seq, _):
            return .subscribed(docId: docId, seq: seq, snapshot: .transfer(descriptor))
        case .event(let docId, let seq, let kind, let opId, let payload):
            return .event(docId: docId, seq: seq, kind: kind, opId: opId,
                          payload: OpPayload(type: payload.type, bulk: .transfer(descriptor)))
        default:
            return self
        }
    }
    public var openingDescriptor: TransferDescriptor? {
        switch self {
        case .subscribed(_, _, .transfer(let d)): return d
        case .event(_, _, _, _, let payload):
            if case .transfer(let d) = payload.bulk { return d }
            return nil
        default: return nil
        }
    }
    public func resolvingBulk(with bytes: Data) -> ServerMessage {
        switch self {
        case .subscribed(let docId, let seq, _):
            return .subscribed(docId: docId, seq: seq, snapshot: .inline(bytes))
        case .event(let docId, let seq, let kind, let opId, let payload):
            return .event(docId: docId, seq: seq, kind: kind, opId: opId,
                          payload: OpPayload(type: payload.type, data: bytes))
        default:
            return self
        }
    }
    public var transferControl: TransferControl? {
        switch self {
        case .transferEnd(let id): return .end(id)
        case .transferAbort(let id, let reason): return .abort(id, reason: reason)
        default: return nil
        }
    }
    public static func makeTransferEnd(transferId: UInt32) -> ServerMessage {
        .transferEnd(transferId: transferId)
    }
}
