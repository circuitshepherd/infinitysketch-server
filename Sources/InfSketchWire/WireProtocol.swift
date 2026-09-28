import Foundation

public enum WireProtocol {
    /// 2: `ServerMessage.ping` / `ClientMessage.pong` (WS backpressure + keepalive). The bump is
    /// mandatory, not cosmetic — both decoders THROW on an unknown `type` rather than ignoring
    /// it, so a v1 peer does not degrade gracefully: it completes the hello handshake, then dies
    /// on the first `ping` the server sends. Without the bump the `hello` gate lets exactly the
    /// two reachable stale peers through — an older installed app binary, which would then flap
    /// on reconnect backoff forever with no diagnosable reason, and a browser tab opened before a
    /// server rebuild that reconnects with its old in-memory script. With it they get a clean
    /// `unsupportedVersion`. Any future wire ADDITION needs the same treatment.
    ///
    /// 3: `ClientMessage.deleteDoc` / `ServerMessage.docDeleted` (document delete). Same reasoning
    /// as the v2 bump, and the failure it prevents is concrete: a stale v2 app stays connected
    /// happily until the moment some other device deletes a document it is subscribed to, at which
    /// point the `docDeleted` push it cannot decode kills the connection — a disconnect with no
    /// diagnosable cause, arriving arbitrarily long after the upgrade.
    ///
    /// 10: op-spec envelopes gained colorAppearance and the render spec gained appearance.
    // v11: op-spec bulk fields moved out of `spec` and into the chunked payload (`OpSpecBundle`).
    // The message SHAPE is unchanged, so nothing here would reject an older peer — but an older
    // app would read an `opBundle` payload as a document and hand an op garbage, so the exact
    // equality gate is what forces app and server to deploy together.
    // v12: `helloAck` names the server INSTANCE (`serverId`, persistent per documents directory), so a
    // device can tell one server from another at the same address; an op on a document the
    // connection is not subscribed to is answered with a `reject` carrying its opId (it was a
    // docId-less `error` that no push waiter ever heard, so a push sent into a refetch's
    // unsubscribe→subscribe window waited forever); `alreadySubscribed` became a `subscribeFailed`;
    // an oversized op-spec rides the chunked payload as an `OpSpecBundle` `spec` part; and a
    // device's `frame` may say which seq it rendered; a `strokeOpRequest` carries a `notAfter`
    // deadline a device honours for live-state ops; and three things nothing ever used went away —
    // `subscribe.fromSeq` (always nil, always ignored), `resyncRequired` and `transferAbort` (never
    // sent by anyone).
    public static let version = 12
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

    public var transferDescriptor: TransferDescriptor? {
        if case .transfer(let descriptor) = self { return descriptor }
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
    /// SHA-256 of the content the writer expects to find. Same guarantee as `matchBytes`, but
    /// 32 bytes instead of a second copy of the document — which is what makes it usable by the
    /// APP's ordinary settle-push, where `matchBytes` would double every upload
    /// (spec 2026-07-27-app-push-write-expectation-design.md).
    ///
    /// The digest is opaque here: this module carries it and never computes one, which is how
    /// InfSketchWire keeps its zero dependencies.
    case matchHash(Data)
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
        case "hash":
            self = .matchHash(try c.decode(Data.self, forKey: .bytes))
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
        case .matchHash(let digest):
            try c.encode("hash", forKey: .kind)
            try c.encode(digest, forKey: .bytes)
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

/// One document a device advertises: metadata + thumbnail, NO content — so a doc is
/// discoverable and previewable on other devices without its bytes ever being uploaded.
/// The thumbnail travels WITH the advertisement so the preview needs no follow-up round trip.
///
/// M2c-1: the server holds these ONLY in an in-memory live index, keyed by docId with the set
/// of devices that advertised it — nothing is persisted (the server's durable state is content
/// documents alone), and an entry is pruned when its last advertising device disconnects.
/// All advertisers are equal: any of them may later be asked to hand over the content.
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
    case subscribe(docId: String, createIfMissing: Bool)
    case unsubscribe(docId: String)
    /// Remove the document from the server's store outright.
    ///
    /// Unlike `.op`, this is not a document edit and carries no `WriteExpectation`: the user asked
    /// for the document to be gone, so a write that landed a moment earlier does not make the
    /// request stale. The server keeps NO record of the deletion — a device that still holds a copy
    /// and later re-pushes it will simply re-create it, which is accepted behaviour.
    case deleteDoc(docId: String)
    case op(docId: String, opId: String, payload: OpPayload, expectation: WriteExpectation? = nil)
    case subscribeStatus
    case unsubscribeStatus
    case listDocs
    /// Answers a `ServerMessage.ping`. Carries nothing: a connection has at most one ping
    /// outstanding, and ANY inbound message clears it — this exists only so a client with
    /// nothing else to say can still prove it is reading.
    case pong
    case transferEnd(transferId: UInt32)
    case watchDoc(docId: String, framePx: Int?)
    case unwatchDoc(docId: String)
    /// `canvasRect` is `[x, y, width, height]`: the canvas region the WHOLE square
    /// frame covers, paper padding included — not the content bounds. It is what
    /// lets a browser hold a canvas region still while the document's own bounds
    /// move underneath it; without it the frame's pixels silently change meaning.
    /// `nil` when the document draws nothing, so nothing is covered.
    /// `seq` is the seq of the document bytes the frame was rendered FROM, when the device knows
    /// it; the server then stamps the frame with it instead of the seq current on arrival, which a
    /// render that finished after a write would otherwise claim. The app does NOT send it today —
    /// it renders its own frames from its live document, which holds no server seq — so every
    /// device frame is stamped with the seq current on arrival. The frames that need the exact seq
    /// are the RELAYED renders (a watched document nobody has open), and those carry it on the
    /// server side (`SessionManager.submitFrame(atSeq:)`), not on this message.
    case frame(docId: String, payload: BulkPayload, canvasRect: [Double]?, seq: Int? = nil)
    case createDocReply(requestId: UInt32, docId: String, payload: BulkPayload?, failureReason: String?)
    /// `meta` (additive) rides small JSON inline — never chunked — alongside
    /// the (possibly chunked) PNG `payload`; see the `render` op (Task 4).
    /// Base64-ing the PNG into a JSON envelope instead would inflate it ~33%
    /// over the wire for no benefit, so the two travel as separate fields.
    /// `payloadKind` names what `payload` IS: nil (or absent, from an older peer) means a whole
    /// document — or a PNG, for a render — and `"strippedDoc"` means a `StrippedDocument` the
    /// receiver must rebuild against the bytes it sent with the request. Explicit rather than
    /// sniffed: `OpPayload` already carries a `type` for exactly this, and the one thing that must
    /// never happen is a receiver guessing wrong about what it is storing.
    case strokeOpReply(requestId: UInt32, docId: String, payload: BulkPayload?, meta: Data?,
                       failureReason: String?, payloadKind: String? = nil)
    case advertiseDocs(payload: BulkPayload)
}

extension ClientMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, capabilities, deviceId, docId, createIfMissing, opId, payload, transferId, reason, data, transfer, requestId, failureReason, meta, expectation, payloadKind, framePx, canvasRect, seq
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
                createIfMissing: try c.decodeIfPresent(Bool.self, forKey: .createIfMissing) ?? false)
        case "unsubscribe":
            self = .unsubscribe(docId: try c.decode(String.self, forKey: .docId))
        case "deleteDoc":
            self = .deleteDoc(docId: try c.decode(String.self, forKey: .docId))
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
        case "pong":
            self = .pong
        case "transferEnd":
            self = .transferEnd(transferId: try c.decode(UInt32.self, forKey: .transferId))
        case "watchDoc":
            self = .watchDoc(docId: try c.decode(String.self, forKey: .docId),
                             framePx: try c.decodeIfPresent(Int.self, forKey: .framePx))
        case "unwatchDoc":
            self = .unwatchDoc(docId: try c.decode(String.self, forKey: .docId))
        case "frame":
            let payload: BulkPayload
            if let descriptor = try c.decodeIfPresent(TransferDescriptor.self, forKey: .transfer) {
                payload = .transfer(descriptor)
            } else {
                payload = .inline(try c.decode(Data.self, forKey: .data))
            }
            self = .frame(docId: try c.decode(String.self, forKey: .docId), payload: payload,
                          canvasRect: try c.decodeIfPresent([Double].self, forKey: .canvasRect),
                          seq: try c.decodeIfPresent(Int.self, forKey: .seq))
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
                failureReason: try c.decodeIfPresent(String.self, forKey: .failureReason),
                payloadKind: try c.decodeIfPresent(String.self, forKey: .payloadKind))
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
        case .subscribe(let docId, let createIfMissing):
            try c.encode("subscribe", forKey: .type)
            try c.encode(docId, forKey: .docId)
            if createIfMissing { try c.encode(true, forKey: .createIfMissing) }
        case .unsubscribe(let docId):
            try c.encode("unsubscribe", forKey: .type)
            try c.encode(docId, forKey: .docId)
        case .deleteDoc(let docId):
            try c.encode("deleteDoc", forKey: .type)
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
        case .pong:
            try c.encode("pong", forKey: .type)
        case .transferEnd(let transferId):
            try c.encode("transferEnd", forKey: .type)
            try c.encode(transferId, forKey: .transferId)
        case .watchDoc(let docId, let framePx):
            try c.encode("watchDoc", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encodeIfPresent(framePx, forKey: .framePx)
        case .unwatchDoc(let docId):
            try c.encode("unwatchDoc", forKey: .type)
            try c.encode(docId, forKey: .docId)
        case .frame(let docId, let payload, let canvasRect, let seq):
            try c.encode("frame", forKey: .type)
            try c.encode(docId, forKey: .docId)
            switch payload {
            case .inline(let data): try c.encode(data, forKey: .data)
            case .transfer(let descriptor): try c.encode(descriptor, forKey: .transfer)
            }
            try c.encodeIfPresent(canvasRect, forKey: .canvasRect)
            try c.encodeIfPresent(seq, forKey: .seq)
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
        case .strokeOpReply(let requestId, let docId, let payload, let meta, let failureReason,
                            let payloadKind):
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
            try c.encodeIfPresent(payloadKind, forKey: .payloadKind)
        }
    }
}

public enum ServerMessage: Equatable, Sendable {
    /// `serverId` names the server INSTANCE — stable for as long as its documents directory is
    /// (persisted beside the documents), different for a different server at the same address. It
    /// is what a device keys "what this server and I last agreed on" by: a lineage agreed with one
    /// server is not a lineage with another.
    /// `serverTimeMs` (v12) is this server's clock at the moment the ack was sent, Unix ms. A
    /// device compares a request's `notAfter` against the SERVER's clock, estimated from this (and
    /// refreshed by every `ping`), never against its own: a device clock off by more than the
    /// deadline's skew allowance otherwise refused every live-state op, or applied stale ones.
    /// nil from a server that does not send it (the device then falls back to its own clock).
    case helloAck(protocolVersion: Int, serverId: String, serverTimeMs: Int? = nil)
    case subscribed(docId: String, seq: Int, snapshot: BulkPayload)
    case event(docId: String, seq: Int, kind: String, opId: String, payload: OpPayload)
    case reject(docId: String, opId: String, reason: String, seq: Int)
    case statusEvent(payload: StatusPayload)
    case error(reason: String)
    /// Asks the peer to prove it is still reading. Sent when a connection has been emitted more
    /// than `SessionConfig.outboundByteBudget` since its last inbound message, or when it has
    /// been silent for `SessionConfig.keepaliveIdleInterval`. See `ConnectionHealth`.
    /// `serverTimeMs` (v12): the server's clock when the ping was sent, Unix ms — a fresh sample
    /// for the device's estimate of the server clock (see `helloAck`). Optional, so a ping from a
    /// server that omits it is still a ping.
    case ping(serverTimeMs: Int? = nil)
    case docList(docs: [DocListEntry])
    case transferEnd(transferId: UInt32)
    case frameAvailable(docId: String, seq: Int)
    case watchers(docId: String, count: Int, framePx: Int?)
    case createDocRequest(requestId: UInt32, docId: String)
    /// `payloadKind` names what the request's `payload` IS — byte-for-byte the `strokeOpReply`
    /// pattern: nil means a whole document; "strippedDoc" means the binary `StrippedDocument`,
    /// stripped against the bytes this connection was last sent for this doc (M4). The version
    /// gate makes an absent kind from an older peer unreachable, but nil stays the whole-document
    /// meaning regardless.
    ///
    /// `notAfter` (v12) is a deadline in Unix milliseconds: the request's timeout on the server,
    /// plus an allowance for clock skew. A device that sees it only after that moment — it was
    /// suspended with the request queued in its socket — must not apply a LIVE-state op (a
    /// transform of the user's selection): the agent has long been told `deviceTimeout` and may
    /// have retried. Ops that only turn bytes into bytes may ignore it; their late reply is
    /// dropped on the server. nil = no deadline.
    case strokeOpRequest(requestId: UInt32, docId: String, payload: BulkPayload, spec: Data,
                         payloadKind: String? = nil, notAfter: Int? = nil)
    case subscribeFailed(docId: String, reason: String)
    /// The document was deleted on the server (by another device). Pushed to every live
    /// subscriber so a device holding the document can keep its copy as a LOCAL-ONLY document
    /// rather than silently re-uploading it moments later.
    case docDeleted(docId: String)
}

extension ServerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, docId, seq, snapshot, kind, opId, payload, reason, transfer, transferId, count, docs, requestId, data, spec, payloadKind, framePx, serverId, notAfter, serverTimeMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "helloAck":
            self = .helloAck(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                             serverId: try c.decode(String.self, forKey: .serverId),
                             serverTimeMs: try c.decodeIfPresent(Int.self, forKey: .serverTimeMs))
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
        case "statusEvent":
            self = .statusEvent(payload: try c.decode(StatusPayload.self, forKey: .payload))
        case "error":
            self = .error(reason: try c.decode(String.self, forKey: .reason))
        case "ping":
            self = .ping(serverTimeMs: try c.decodeIfPresent(Int.self, forKey: .serverTimeMs))
        case "docList":
            self = .docList(docs: try c.decode([DocListEntry].self, forKey: .docs))
        case "transferEnd":
            self = .transferEnd(transferId: try c.decode(UInt32.self, forKey: .transferId))
        case "frameAvailable":
            self = .frameAvailable(
                docId: try c.decode(String.self, forKey: .docId),
                seq: try c.decode(Int.self, forKey: .seq))
        case "watchers":
            self = .watchers(
                docId: try c.decode(String.self, forKey: .docId),
                count: try c.decode(Int.self, forKey: .count),
                framePx: try c.decodeIfPresent(Int.self, forKey: .framePx))
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
            let requestId = try c.decode(UInt32.self, forKey: .requestId)
            let docId = try c.decode(String.self, forKey: .docId)
            let spec = try c.decode(Data.self, forKey: .spec)
            let payloadKind = try c.decodeIfPresent(String.self, forKey: .payloadKind)
            self = .strokeOpRequest(requestId: requestId, docId: docId, payload: payload,
                                    spec: spec, payloadKind: payloadKind,
                                    notAfter: try c.decodeIfPresent(Int.self, forKey: .notAfter))
        case "docDeleted":
            self = .docDeleted(docId: try c.decode(String.self, forKey: .docId))
        case "subscribeFailed":
            self = .subscribeFailed(
                docId: try c.decode(String.self, forKey: .docId),
                reason: try c.decode(String.self, forKey: .reason))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown server message type: \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .helloAck(let v, let serverId, let serverTimeMs):
            try c.encode("helloAck", forKey: .type)
            try c.encode(v, forKey: .protocolVersion)
            try c.encode(serverId, forKey: .serverId)
            try c.encodeIfPresent(serverTimeMs, forKey: .serverTimeMs)
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
        case .statusEvent(let payload):
            try c.encode("statusEvent", forKey: .type)
            try c.encode(payload, forKey: .payload)
        case .error(let reason):
            try c.encode("error", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .ping(let serverTimeMs):
            try c.encode("ping", forKey: .type)
            try c.encodeIfPresent(serverTimeMs, forKey: .serverTimeMs)
        case .docList(let docs):
            try c.encode("docList", forKey: .type)
            try c.encode(docs, forKey: .docs)
        case .transferEnd(let transferId):
            try c.encode("transferEnd", forKey: .type)
            try c.encode(transferId, forKey: .transferId)
        case .frameAvailable(let docId, let seq):
            try c.encode("frameAvailable", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(seq, forKey: .seq)
        case .watchers(let docId, let count, let framePx):
            try c.encode("watchers", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(count, forKey: .count)
            try c.encodeIfPresent(framePx, forKey: .framePx)
        case .createDocRequest(let requestId, let docId):
            try c.encode("createDocRequest", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(docId, forKey: .docId)
        case .strokeOpRequest(let requestId, let docId, let payload, let spec, let payloadKind,
                              let notAfter):
            try c.encode("strokeOpRequest", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(docId, forKey: .docId)
            switch payload {
            case .inline(let data): try c.encode(data, forKey: .data)
            case .transfer(let descriptor): try c.encode(descriptor, forKey: .transfer)
            }
            try c.encode(spec, forKey: .spec)
            try c.encodeIfPresent(payloadKind, forKey: .payloadKind)
            try c.encodeIfPresent(notAfter, forKey: .notAfter)
        case .docDeleted(let docId):
            try c.encode("docDeleted", forKey: .type)
            try c.encode(docId, forKey: .docId)
        case .subscribeFailed(let docId, let reason):
            try c.encode("subscribeFailed", forKey: .type)
            try c.encode(docId, forKey: .docId)
            try c.encode(reason, forKey: .reason)
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

// The chunk swap. Each message that can carry bulk bytes names WHERE they sit exactly once — in
// `bulk` (read) and `mapBulk` (rewrite) — and the four `TransferCarrying` requirements are derived
// from those two. They used to be four hand-written switches per direction, each re-listing every
// field of every case: a field forgotten in one of them was lost only for a message big enough to
// chunk (above 64 KiB, `TransferDefaults.inlineLimit`), which no small test reaches. `mapBulk` rebuilds a case with EVERY label
// spelled out (no default arguments relied on), and `WireProtocolTests` round-trips every bulk
// message with every field set through the swap.

extension ClientMessage: TransferCarrying {
    /// The message's bulk field, when it has one.
    public var bulk: BulkPayload? {
        switch self {
        case .op(_, _, let payload, _): return payload.bulk
        case .frame(_, let payload, _, _): return payload
        case .advertiseDocs(let payload): return payload
        case .createDocReply(_, _, let payload, _): return payload
        case .strokeOpReply(_, _, let payload, _, _, _): return payload
        default: return nil
        }
    }

    /// The same message with its bulk field rewritten and every other field kept. A message with
    /// no bulk field (or an absent optional one) is returned unchanged.
    public func mapBulk(_ transform: (BulkPayload) -> BulkPayload) -> ClientMessage {
        switch self {
        case .op(let docId, let opId, let payload, let expectation):
            return .op(docId: docId, opId: opId,
                       payload: OpPayload(type: payload.type, bulk: transform(payload.bulk)),
                       expectation: expectation)
        case .frame(let docId, let payload, let canvasRect, let seq):
            return .frame(docId: docId, payload: transform(payload), canvasRect: canvasRect, seq: seq)
        case .advertiseDocs(let payload):
            return .advertiseDocs(payload: transform(payload))
        case .createDocReply(let requestId, let docId, let payload?, let failureReason):
            return .createDocReply(requestId: requestId, docId: docId, payload: transform(payload),
                                   failureReason: failureReason)
        case .strokeOpReply(let requestId, let docId, let payload?, let meta, let failureReason,
                            let payloadKind):
            return .strokeOpReply(requestId: requestId, docId: docId, payload: transform(payload),
                                  meta: meta, failureReason: failureReason, payloadKind: payloadKind)
        default:
            return self
        }
    }

    public var bulkBytes: Data? { bulk?.inlineData }
    public func replacingBulk(with descriptor: TransferDescriptor) -> ClientMessage {
        mapBulk { _ in .transfer(descriptor) }
    }
    public var openingDescriptor: TransferDescriptor? { bulk?.transferDescriptor }
    public func resolvingBulk(with bytes: Data) -> ClientMessage {
        mapBulk { _ in .inline(bytes) }
    }
    public var transferControl: TransferControl? {
        if case .transferEnd(let id) = self { return .end(id) }
        return nil
    }
    public static func makeTransferEnd(transferId: UInt32) -> ClientMessage {
        .transferEnd(transferId: transferId)
    }
}

extension ServerMessage: TransferCarrying {
    /// The message's bulk field, when it has one.
    public var bulk: BulkPayload? {
        switch self {
        case .subscribed(_, _, let snapshot): return snapshot
        case .event(_, _, _, _, let payload): return payload.bulk
        case .strokeOpRequest(_, _, let payload, _, _, _): return payload
        default: return nil
        }
    }

    /// The same message with its bulk field rewritten and every other field kept.
    public func mapBulk(_ transform: (BulkPayload) -> BulkPayload) -> ServerMessage {
        switch self {
        case .subscribed(let docId, let seq, let snapshot):
            return .subscribed(docId: docId, seq: seq, snapshot: transform(snapshot))
        case .event(let docId, let seq, let kind, let opId, let payload):
            return .event(docId: docId, seq: seq, kind: kind, opId: opId,
                          payload: OpPayload(type: payload.type, bulk: transform(payload.bulk)))
        case .strokeOpRequest(let requestId, let docId, let payload, let spec, let payloadKind,
                              let notAfter):
            return .strokeOpRequest(requestId: requestId, docId: docId, payload: transform(payload),
                                    spec: spec, payloadKind: payloadKind, notAfter: notAfter)
        default:
            return self
        }
    }

    public var bulkBytes: Data? { bulk?.inlineData }
    public func replacingBulk(with descriptor: TransferDescriptor) -> ServerMessage {
        mapBulk { _ in .transfer(descriptor) }
    }
    public var openingDescriptor: TransferDescriptor? { bulk?.transferDescriptor }
    public func resolvingBulk(with bytes: Data) -> ServerMessage {
        mapBulk { _ in .inline(bytes) }
    }
    public var transferControl: TransferControl? {
        if case .transferEnd(let id) = self { return .end(id) }
        return nil
    }
    public static func makeTransferEnd(transferId: UInt32) -> ServerMessage {
        .transferEnd(transferId: transferId)
    }
}
