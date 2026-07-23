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

/// A compare-and-swap expectation a client attaches to a write `op`. Every
/// write to an EXISTING document already goes through an expected-bytes CAS
/// (`matchBytes`, the shape `expectedBytes` already uses); the two *creation*
/// paths (`create_doc`, `replace_doc`'s create branch) have no such guard yet
/// — `absent` is what lets a create op assert "this document must not already
/// exist" instead of silently overwriting one that raced into existence
/// between read and write. `none` is today's unconditional-write behavior.
public enum WriteExpectation: Equatable, Sendable {
    case none
    case matchBytes(Data)
    case absent
}

extension WriteExpectation: Codable {
    private enum CodingKeys: String, CodingKey { case kind, bytes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "none":
            self = .none
        case "absent":
            self = .absent
        case "match":
            self = .matchBytes(try c.decode(Data.self, forKey: .bytes))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown WriteExpectation kind: \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode("none", forKey: .kind)
        case .absent:
            try c.encode("absent", forKey: .kind)
        case .matchBytes(let bytes):
            try c.encode("match", forKey: .kind)
            try c.encode(bytes, forKey: .bytes)
        }
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
    /// M2b: false = the server holds only metadata + thumbnail for this doc; its content
    /// lives on a connected device (M2c-1: any of its holders). Defaults to TRUE when absent —
    /// every pre-M2b entry had content.
    public var hasContent: Bool

    public init(id: String, sizeBytes: Int, modifiedAt: Date, seq: Int?, subscriberCount: Int?,
                hasContent: Bool = true) {
        self.id = id
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.seq = seq
        self.subscriberCount = subscriberCount
        self.hasContent = hasContent
    }

    private enum CodingKeys: String, CodingKey {
        case id, sizeBytes, modifiedAt, seq, subscriberCount, hasContent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sizeBytes = try c.decode(Int.self, forKey: .sizeBytes)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        subscriberCount = try c.decodeIfPresent(Int.self, forKey: .subscriberCount)
        hasContent = try c.decodeIfPresent(Bool.self, forKey: .hasContent) ?? true
    }
}

/// One document a device advertises: metadata + thumbnail, NO content. The server persists
/// these as `metadata/` sidecars so a doc is discoverable + previewable everywhere without
/// its bytes ever being uploaded (M2b). The thumbnail travels WITH the advertisement so a
/// preview survives the origin device going offline.
public struct DocAdvertisement: Codable, Equatable, Sendable {
    public var docId: String
    public var modifiedAt: Date
    public var sizeBytes: Int
    public var thumbnail: Data?
    public init(docId: String, modifiedAt: Date, sizeBytes: Int, thumbnail: Data?) {
        self.docId = docId
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.thumbnail = thumbnail
    }
}

public enum ClientMessage: Equatable, Sendable {
    case hello(protocolVersion: Int, capabilities: [String], deviceId: String?)
    case subscribe(docId: String, fromSeq: Int?, createIfMissing: Bool)
    case unsubscribe(docId: String)
    case op(docId: String, opId: String, payload: OpPayload, expectation: WriteExpectation? = nil)
    case subscribeStatus
    case unsubscribeStatus
    case listDocs
    case transferEnd(transferId: UInt32)
    case transferAbort(transferId: UInt32, reason: String)
    case watchDoc(docId: String)
    case unwatchDoc(docId: String)
    case frame(docId: String, payload: BulkPayload)
    case createDocReply(requestId: UInt32, docId: String, payload: BulkPayload?, failureReason: String?)
    /// `meta` (additive) rides small JSON inline — never chunked — alongside
    /// the (possibly chunked) PNG `payload`; see the `render` op (Task 4).
    /// Base64-ing the PNG into a JSON envelope instead would inflate it ~33%
    /// over the wire for no benefit, so the two travel as separate fields.
    case strokeOpReply(requestId: UInt32, docId: String, payload: BulkPayload?, meta: Data?, failureReason: String?)
    case advertiseDocs(payload: BulkPayload)
}

extension ClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, capabilities, deviceId, docId, fromSeq, createIfMissing, opId, payload, transferId, reason, data, transfer, requestId, failureReason, meta, expectation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                capabilities: try c.decodeIfPresent([String].self, forKey: .capabilities) ?? [],
                deviceId: try c.decodeIfPresent(String.self, forKey: .deviceId))
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
                payload: try c.decode(OpPayload.self, forKey: .payload),
                expectation: try c.decodeIfPresent(WriteExpectation.self, forKey: .expectation))
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
        case "advertiseDocs":
            let payload: BulkPayload
            if let descriptor = try c.decodeIfPresent(TransferDescriptor.self, forKey: .transfer) {
                payload = .transfer(descriptor)
            } else {
                payload = .inline(try c.decode(Data.self, forKey: .data))
            }
            self = .advertiseDocs(payload: payload)
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
        case "strokeOpReply":
            let payload: BulkPayload?
            if let descriptor = try c.decodeIfPresent(TransferDescriptor.self, forKey: .transfer) {
                payload = .transfer(descriptor)
            } else if let data = try c.decodeIfPresent(Data.self, forKey: .data) {
                payload = .inline(data)
            } else {
                payload = nil
            }
            self = .strokeOpReply(
                requestId: try c.decode(UInt32.self, forKey: .requestId),
                docId: try c.decode(String.self, forKey: .docId),
                payload: payload,
                meta: try c.decodeIfPresent(Data.self, forKey: .meta),
                failureReason: try c.decodeIfPresent(String.self, forKey: .failureReason))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown client message type: \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let v, let caps, let deviceId):
            try c.encode("hello", forKey: .type)
            try c.encode(v, forKey: .protocolVersion)
            try c.encode(caps, forKey: .capabilities)
            try c.encodeIfPresent(deviceId, forKey: .deviceId)
        case .subscribe(let docId, let fromSeq, let createIfMissing):
            try c.encode("subscribe", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encodeIfPresent(fromSeq, forKey: .fromSeq)
            if createIfMissing { try c.encode(true, forKey: .createIfMissing) }
        case .unsubscribe(let docId):
            try c.encode("unsubscribe", forKey: .type)
            try c.encode(docId, forKey: .docId)
        case .op(let docId, let opId, let payload, let expectation):
            try c.encode("op", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(opId, forKey: .opId)
            try c.encode(payload, forKey: .payload)
            try c.encodeIfPresent(expectation, forKey: .expectation)
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
        case .advertiseDocs(let payload):
            try c.encode("advertiseDocs", forKey: .type)
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
        case .strokeOpReply(let requestId, let docId, let payload, let meta, let failureReason):
            try c.encode("strokeOpReply", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(docId, forKey: .docId)
            switch payload {
            case .inline(let data): try c.encode(data, forKey: .data)
            case .transfer(let descriptor): try c.encode(descriptor, forKey: .transfer)
            case nil: break
            }
            try c.encodeIfPresent(meta, forKey: .meta)
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
    case strokeOpRequest(requestId: UInt32, docId: String, payload: BulkPayload, spec: Data)
}

extension ServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, docId, seq, snapshot, kind, opId, payload, reason, transfer, transferId, count, docs, requestId, data, spec
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
        case "strokeOpRequest":
            let payload: BulkPayload
            if let descriptor = try c.decodeIfPresent(TransferDescriptor.self, forKey: .transfer) {
                payload = .transfer(descriptor)
            } else {
                payload = .inline(try c.decode(Data.self, forKey: .data))
            }
            self = .strokeOpRequest(
                requestId: try c.decode(UInt32.self, forKey: .requestId),
                docId: try c.decode(String.self, forKey: .docId),
                payload: payload,
                spec: try c.decode(Data.self, forKey: .spec))
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
        case .strokeOpRequest(let requestId, let docId, let payload, let spec):
            try c.encode("strokeOpRequest", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(docId, forKey: .docId)
            switch payload {
            case .inline(let data): try c.encode(data, forKey: .data)
            case .transfer(let descriptor): try c.encode(descriptor, forKey: .transfer)
            }
            try c.encode(spec, forKey: .spec)
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
        case .op(_, _, let payload, _): return payload.bulk.inlineData
        case .frame(_, let payload): return payload.inlineData
        case .advertiseDocs(let payload): return payload.inlineData
        case .createDocReply(_, _, let payload, _): return payload?.inlineData
        case .strokeOpReply(_, _, let payload, _, _): return payload?.inlineData
        default: return nil
        }
    }
    public func replacingBulk(with descriptor: TransferDescriptor) -> ClientMessage {
        switch self {
        case .op(let docId, let opId, let payload, let expectation):
            return .op(docId: docId, opId: opId,
                       payload: OpPayload(type: payload.type, bulk: .transfer(descriptor)),
                       expectation: expectation)
        case .frame(let docId, _):
            return .frame(docId: docId, payload: .transfer(descriptor))
        case .advertiseDocs:
            return .advertiseDocs(payload: .transfer(descriptor))
        case .createDocReply(let requestId, let docId, _, let failureReason):
            return .createDocReply(requestId: requestId, docId: docId,
                                    payload: .transfer(descriptor), failureReason: failureReason)
        case .strokeOpReply(let requestId, let docId, _, let meta, let failureReason):
            // meta is PRESERVED through this swap, exactly like failureReason
            // — a dropped meta here would silently lose the render metadata
            // for any reply large enough to chunk.
            return .strokeOpReply(requestId: requestId, docId: docId,
                                   payload: .transfer(descriptor), meta: meta, failureReason: failureReason)
        default:
            return self
        }
    }
    public var openingDescriptor: TransferDescriptor? {
        switch self {
        case .op(_, _, let payload, _):
            if case .transfer(let d) = payload.bulk { return d }
            return nil
        case .frame(_, .transfer(let d)):
            return d
        case .advertiseDocs(.transfer(let d)):
            return d
        case .createDocReply(_, _, let payload, _):
            if case .transfer(let d) = payload { return d }
            return nil
        case .strokeOpReply(_, _, let payload, _, _):
            if case .transfer(let d) = payload { return d }
            return nil
        default: return nil
        }
    }
    public func resolvingBulk(with bytes: Data) -> ClientMessage {
        switch self {
        case .op(let docId, let opId, let payload, let expectation):
            return .op(docId: docId, opId: opId, payload: OpPayload(type: payload.type, data: bytes),
                       expectation: expectation)
        case .frame(let docId, _):
            return .frame(docId: docId, payload: .inline(bytes))
        case .advertiseDocs:
            return .advertiseDocs(payload: .inline(bytes))
        case .createDocReply(let requestId, let docId, _, let failureReason):
            return .createDocReply(requestId: requestId, docId: docId,
                                    payload: .inline(bytes), failureReason: failureReason)
        case .strokeOpReply(let requestId, let docId, _, let meta, let failureReason):
            // meta is PRESERVED through this swap too — see replacingBulk above.
            return .strokeOpReply(requestId: requestId, docId: docId,
                                   payload: .inline(bytes), meta: meta, failureReason: failureReason)
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
        case .strokeOpRequest(_, _, let payload, _): return payload.inlineData
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
        case .strokeOpRequest(let requestId, let docId, _, let spec):
            return .strokeOpRequest(requestId: requestId, docId: docId,
                                     payload: .transfer(descriptor), spec: spec)
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
        case .strokeOpRequest(_, _, .transfer(let d), _): return d
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
        case .strokeOpRequest(let requestId, let docId, _, let spec):
            return .strokeOpRequest(requestId: requestId, docId: docId,
                                     payload: .inline(bytes), spec: spec)
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
