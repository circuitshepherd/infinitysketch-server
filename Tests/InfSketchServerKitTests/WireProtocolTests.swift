import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct WireProtocolTests {
    /// Pins the version so a wire ADDITION cannot ship without it. Both decoders throw on an
    /// unknown `type` rather than ignoring it, so an older peer does not degrade — it passes the
    /// `hello` gate and then dies on the first message it has never heard of. `ping`/`pong` took
    /// this from 1 to 2; `deleteDoc`/`docDeleted` took it from 2 to 3; `WriteExpectation.matchHash`
    /// took it from 3 to 4; the `strippedDoc` op payload took it from 4 to 5;
    /// `strokeOpReply.payloadKind` took it from 5 to 6; `strokeOpRequest.payloadKind` (M4,
    /// request stripping) took it from 6 to 7; `framePx` on `watchDoc`/`watchers` (frame
    /// resolution) took it from 7 to 8; the next addition takes it to 9.
    ///
    /// An addition is not only a new MESSAGE: `matchHash` is a new CASE inside an existing
    /// message's payload, and an older peer would throw on its unknown `kind` exactly the same
    /// way. Anything that changes what a peer must understand counts.
    ///
    /// This test earning its keep is not hypothetical: the delete work added both messages and
    /// left the version at 2, and this is what caught it.
    @Test func theVersionIsBumpedForEveryWireAddition() {
        #expect(WireProtocol.version == 8)
    }

    @Test func clientMessagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .hello(protocolVersion: 1, capabilities: ["render"], deviceId: nil),
            .subscribe(docId: "a", fromSeq: 7, createIfMissing: false),
            .subscribe(docId: "a", fromSeq: nil, createIfMissing: false),
            .unsubscribe(docId: "a"),
            .op(docId: "a", opId: "c1-1", payload: OpPayload(type: "fullDoc", data: Data([1, 2, 3]))),
            .subscribeStatus,
            .unsubscribeStatus,
        ]
        for m in messages {
            let decoded = try ClientMessage(jsonText: try m.jsonText())
            #expect(decoded == m)
        }
    }

    @Test func serverMessagesRoundTrip() throws {
        let messages: [ServerMessage] = [
            .helloAck(protocolVersion: 1),
            .subscribed(docId: "a", seq: 0, snapshot: .inline(Data([9]))),
            .event(docId: "a", seq: 1, kind: "op", opId: "c1-1",
                   payload: OpPayload(type: "fullDoc", data: Data([1]))),
            .reject(docId: "a", opId: "c1-1", reason: "unsupportedPayloadType", seq: 3),
            .resyncRequired(docId: "a", seq: 12),
            .statusEvent(payload: StatusPayload(docId: "a", kind: "docUpdated", seq: 4, subscriberCount: 2)),
            .error(reason: "malformedMessage"),
            .subscribeFailed(docId: "Doc-1", reason: "unknownDoc"),
        ]
        for m in messages {
            let decoded = try ServerMessage(jsonText: try m.jsonText())
            #expect(decoded == m)
        }
    }

    @Test func typeFieldIsFlatDiscriminator() throws {
        let json = try ClientMessage.subscribe(docId: "doc1", fromSeq: nil, createIfMissing: false).jsonText()
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["type"] as? String == "subscribe")
        #expect(obj["docId"] as? String == "doc1")
    }

    @Test func unknownTypeThrows() {
        #expect(throws: (any Error).self) {
            _ = try ClientMessage(jsonText: #"{"type":"launchMissiles"}"#)
        }
    }
}

@Suite struct TransferWireProtocolTests {
    private func roundTripServer(_ m: ServerMessage) throws -> ServerMessage {
        try ServerMessage(jsonText: m.jsonText())
    }
    private func roundTripClient(_ m: ClientMessage) throws -> ClientMessage {
        try ClientMessage(jsonText: m.jsonText())
    }

    @Test func subscribedWithDescriptorRoundTrips() throws {
        let d = TransferDescriptor(transferId: 7, totalBytes: 1000, chunkSize: 256)
        let m = ServerMessage.subscribed(docId: "a", seq: 41, snapshot: .transfer(d))
        #expect(try roundTripServer(m) == m)
    }
    @Test func eventWithDescriptorRoundTrips() throws {
        let d = TransferDescriptor(transferId: 8, totalBytes: 10, chunkSize: 4)
        let m = ServerMessage.event(docId: "a", seq: 2, kind: "op", opId: "o1",
                                    payload: OpPayload(type: "fullDoc", bulk: .transfer(d)))
        #expect(try roundTripServer(m) == m)
    }
    @Test func opWithDescriptorRoundTrips() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 5, chunkSize: 2)
        let m = ClientMessage.op(docId: "a", opId: "c1",
                                 payload: OpPayload(type: "fullDoc", bulk: .transfer(d)))
        #expect(try roundTripClient(m) == m)
    }
    @Test func transferControlMessagesRoundTrip() throws {
        #expect(try roundTripServer(.transferEnd(transferId: 3)) == .transferEnd(transferId: 3))
        #expect(try roundTripServer(.transferAbort(transferId: 3, reason: "storeFailure"))
            == .transferAbort(transferId: 3, reason: "storeFailure"))
        #expect(try roundTripClient(.transferEnd(transferId: 9)) == .transferEnd(transferId: 9))
        #expect(try roundTripClient(.transferAbort(transferId: 9, reason: "cancelled"))
            == .transferAbort(transferId: 9, reason: "cancelled"))
    }
    @Test func framePxRoundTripsAndAbsenceDecodesNil() throws {
        #expect(try roundTripClient(.watchDoc(docId: "d", framePx: 2048))
                == .watchDoc(docId: "d", framePx: 2048))
        #expect(try roundTripServer(.watchers(docId: "d", count: 2, framePx: 1024))
                == .watchers(docId: "d", count: 2, framePx: 1024))
        // A v7 peer's message carries no framePx key — it must decode as nil…
        let legacy = Data(#"{"type":"watchDoc","docId":"d"}"#.utf8)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: legacy)
                == .watchDoc(docId: "d", framePx: nil))
        // …and an absent request must ENCODE no key (byte-shape unchanged).
        let encoded = try JSONEncoder().encode(ClientMessage.watchDoc(docId: "d", framePx: nil))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("framePx"))
    }

    @Test func inlineEncodingStaysV0Compatible() throws {
        // Below-threshold traffic must be byte-compatible with v0: same keys, base64 data.
        let subscribed = try ServerMessage.subscribed(docId: "a", seq: 0, snapshot: .inline(Data([9]))).jsonText()
        #expect(subscribed.contains(#""snapshot":"CQ==""#))
        #expect(!subscribed.contains("transfer"))
        let op = try ClientMessage.op(docId: "a", opId: "c1",
                                      payload: OpPayload(type: "fullDoc", data: Data([1, 2, 3]))).jsonText()
        #expect(op.contains(#""data":"AQID""#))
        #expect(!op.contains("transfer"))
    }
}

@Suite struct CreateIfMissingWireTests {
    @Test func subscribeWithFlagRoundTrips() throws {
        let m = ClientMessage.subscribe(docId: "d", fromSeq: nil, createIfMissing: true)
        #expect(try ClientMessage(jsonText: m.jsonText()) == m)
        #expect(try m.jsonText().contains("createIfMissing"))
    }
    @Test func subscribeWithoutFlagStaysV0Compatible() throws {
        let m = ClientMessage.subscribe(docId: "d", fromSeq: 3, createIfMissing: false)
        #expect(!(try m.jsonText().contains("createIfMissing")))
        // Old-client JSON without the key decodes as false.
        let old = #"{"type":"subscribe","docId":"d","fromSeq":3}"#
        #expect(try ClientMessage(jsonText: old) == m)
    }
}

@Suite struct RenderDelegationWireTests {
    @Test func watchMessagesRoundTrip() throws {
        let w = ClientMessage.watchDoc(docId: "d", framePx: nil)
        #expect(try ClientMessage(jsonText: w.jsonText()) == w)
        let u = ClientMessage.unwatchDoc(docId: "d")
        #expect(try ClientMessage(jsonText: u.jsonText()) == u)
    }
    @Test func frameMessageRoundTripsInline() throws {
        let f = ClientMessage.frame(docId: "d", payload: .inline(Data([1, 2, 3])))
        #expect(try ClientMessage(jsonText: f.jsonText()) == f)
    }
    @Test func frameMessageRoundTripsAsDescriptor() throws {
        let d = TransferDescriptor(transferId: 3, totalBytes: 100, chunkSize: 8)
        let f = ClientMessage.frame(docId: "d", payload: .transfer(d))
        #expect(try ClientMessage(jsonText: f.jsonText()) == f)
    }
    @Test func frameChunksThroughSenderAndReassembler() throws {
        let png = Data((0..<100).map { UInt8($0 % 256) })
        var sender = TransferSender<ClientMessage>(inlineLimit: 16, chunkSize: 8)
        var reassembler = TransferReassembler<ClientMessage>()
        var results: [ClientMessage] = []
        for frame in try sender.frames(for: .frame(docId: "d", payload: .inline(png))) {
            if let m = try reassembler.consume(frame) { results.append(m) }
        }
        #expect(results == [.frame(docId: "d", payload: .inline(png))])
    }
    @Test func serverFrameMessagesRoundTrip() throws {
        let fa = ServerMessage.frameAvailable(docId: "d", seq: 7)
        #expect(try ServerMessage(jsonText: fa.jsonText()) == fa)
        let w = ServerMessage.watchers(docId: "d", count: 2, framePx: nil)
        #expect(try ServerMessage(jsonText: w.jsonText()) == w)
    }
}

@Suite struct DocListWireTests {
    @Test func listDocsRoundTrips() throws {
        #expect(try ClientMessage(jsonText: ClientMessage.listDocs.jsonText()) == .listDocs)
    }
    @Test func docListRoundTrips() throws {
        let entry = DocListEntry(id: "a", sizeBytes: 10,
                                 modifiedAt: Date(timeIntervalSince1970: 1_000_000),
                                 seq: 3, subscriberCount: 1)
        let bare = DocListEntry(id: "b", sizeBytes: 0,
                                modifiedAt: Date(timeIntervalSince1970: 2_000_000),
                                seq: nil, subscriberCount: nil)
        let m = ServerMessage.docList(docs: [entry, bare])
        #expect(try ServerMessage(jsonText: m.jsonText()) == m)
    }
}

@Suite struct CreateDocWireTests {
    @Test func createDocRequestRoundTrips() throws {
        let msg = ServerMessage.createDocRequest(requestId: 7, docId: "AgentDoc")
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ServerMessage.self, from: data) == msg)
    }

    @Test func createDocReplySuccessRoundTrips() throws {
        let msg = ClientMessage.createDocReply(
            requestId: 7, docId: "AgentDoc",
            payload: .inline(Data("doc-bytes".utf8)), failureReason: nil)
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == msg)
    }

    @Test func createDocReplyFailureRoundTrips() throws {
        let msg = ClientMessage.createDocReply(
            requestId: 8, docId: "AgentDoc", payload: nil, failureReason: "templateMissing")
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == msg)
    }

    @Test func createDocReplyTransferFormRoundTrips() throws {
        let msg = ClientMessage.createDocReply(
            requestId: 9, docId: "AgentDoc",
            payload: .transfer(TransferDescriptor(transferId: 3, totalBytes: 1_000_000, chunkSize: 65536)),
            failureReason: nil)
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == msg)
    }

    @Test func createDocReplyChunksThroughSenderAndReassembler() throws {
        let bytes = Data((0..<100).map { UInt8($0 % 256) })
        var sender = TransferSender<ClientMessage>(inlineLimit: 16, chunkSize: 8)
        var reassembler = TransferReassembler<ClientMessage>()
        var results: [ClientMessage] = []
        let original = ClientMessage.createDocReply(
            requestId: 9, docId: "AgentDoc", payload: .inline(bytes), failureReason: nil)
        for frame in try sender.frames(for: original) {
            if let m = try reassembler.consume(frame) { results.append(m) }
        }
        #expect(results == [original])
    }
}

@Suite struct StrokeOpWireTests {
    @Test func strokeOpRequestRoundTrips() throws {
        let msg = ServerMessage.strokeOpRequest(
            requestId: 5, docId: "D",
            payload: .inline(Data("doc".utf8)), spec: Data(#"{"op":"list"}"#.utf8))
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ServerMessage.self, from: data) == msg)
    }

    @Test func strokeOpRequestTransferFormRoundTrips() throws {
        let msg = ServerMessage.strokeOpRequest(
            requestId: 6, docId: "D",
            payload: .transfer(TransferDescriptor(transferId: 9, totalBytes: 1_000_000, chunkSize: 65536)),
            spec: Data(#"{"op":"draw"}"#.utf8))
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ServerMessage.self, from: data) == msg)
    }

    @Test func strokeOpReplySuccessRoundTrips() throws {
        let msg = ClientMessage.strokeOpReply(
            requestId: 5, docId: "D", payload: .inline(Data("out".utf8)), meta: nil, failureReason: nil)
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == msg)
    }

    @Test func strokeOpReplyFailureRoundTrips() throws {
        let msg = ClientMessage.strokeOpReply(
            requestId: 7, docId: "D", payload: nil, meta: nil, failureReason: "strokeNotFound: [k1]")
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == msg)
    }

    /// Task 4 (render op): `meta` (the render's metadata JSON) rides inline
    /// alongside an inline PNG `payload` — additive field, so a reply that
    /// carries it must still round-trip byte-for-byte.
    @Test func strokeOpReplyWithMetaInlineRoundTrips() throws {
        let msg = ClientMessage.strokeOpReply(
            requestId: 5, docId: "D", payload: .inline(Data("png-bytes".utf8)),
            meta: Data(#"{"pixelSize":[512,512],"scale":2}"#.utf8), failureReason: nil)
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == msg)
    }

    /// Same as above, but with the PNG payload in its `.transfer` (chunked)
    /// form — the transfer-descriptor announce frame is where a dropped
    /// `meta` would most easily hide, since `meta` itself is never chunked.
    @Test func strokeOpReplyWithMetaTransferFormRoundTrips() throws {
        let msg = ClientMessage.strokeOpReply(
            requestId: 9, docId: "D",
            payload: .transfer(TransferDescriptor(transferId: 3, totalBytes: 1_000_000, chunkSize: 65536)),
            meta: Data(#"{"pixelSize":[2048,2048],"scale":2}"#.utf8), failureReason: nil)
        let data = try JSONEncoder().encode(msg)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == msg)
    }

    @Test func strokeOpReplyChunksThroughSenderAndReassemblerWithMetaIntact() throws {
        let bytes = Data((0..<100).map { UInt8($0 % 256) })
        var sender = TransferSender<ClientMessage>(inlineLimit: 16, chunkSize: 8)
        var reassembler = TransferReassembler<ClientMessage>()
        var results: [ClientMessage] = []
        let original = ClientMessage.strokeOpReply(
            requestId: 9, docId: "D", payload: .inline(bytes),
            meta: Data(#"{"scale":1}"#.utf8), failureReason: nil)
        for frame in try sender.frames(for: original) {
            if let m = try reassembler.consume(frame) { results.append(m) }
        }
        #expect(results == [original])
    }

    @Test func strokeOpMessagesParticipateInTransferCarrying() throws {
        // The server chunks OUTBOUND requests and the app's reassembler resolves them
        // (and symmetrically for replies) purely via these four hooks.
        let bigDoc = Data(repeating: 7, count: 600_000)
        let request = ServerMessage.strokeOpRequest(
            requestId: 1, docId: "D", payload: .inline(bigDoc), spec: Data(#"{"op":"draw"}"#.utf8))
        #expect(request.bulkBytes == bigDoc)
        let descriptor = TransferDescriptor(transferId: 2, totalBytes: bigDoc.count, chunkSize: 65536)
        let swapped = request.replacingBulk(with: descriptor)
        #expect(swapped.openingDescriptor == descriptor)
        #expect(swapped.resolvingBulk(with: bigDoc) == request)

        // meta must survive the transfer round trip untouched — a dropped
        // meta on a chunked reply would silently lose the render metadata.
        let meta = Data(#"{"pixelSize":[512,512]}"#.utf8)
        let reply = ClientMessage.strokeOpReply(
            requestId: 1, docId: "D", payload: .inline(bigDoc), meta: meta, failureReason: nil)
        #expect(reply.bulkBytes == bigDoc)
        let swappedReply = reply.replacingBulk(with: descriptor)
        #expect(swappedReply.openingDescriptor == descriptor)
        #expect(swappedReply.resolvingBulk(with: bigDoc) == reply)
    }
}

/// Liveness has to be an application-level message: FlyingFox's `WSMessage` is only
/// `.text`/`.data`/`.close`, so a handler cannot send a protocol-level ping, and an inbound
/// pong is dropped by `WSHandler` before it ever reaches the handler (`makeMessage` and
/// `makeResponseFrames` both return nil for it).
struct WirePingPongTests {
    @Test func serverPingRoundTrips() throws {
        let json = try ServerMessage.ping.jsonText()
        #expect(json.contains("\"type\":\"ping\""))
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
        guard case .ping = decoded else {
            Issue.record("expected .ping, got \(decoded)")
            return
        }
    }

    @Test func clientPongRoundTrips() throws {
        let json = try ClientMessage.pong.jsonText()
        #expect(json.contains("\"type\":\"pong\""))
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
        guard case .pong = decoded else {
            Issue.record("expected .pong, got \(decoded)")
            return
        }
    }

    /// A ping carries nothing — no correlation id, because only one is ever outstanding per
    /// connection and ANY inbound message clears it. Pinning the exact wire text keeps the
    /// hand-written web-UI and demo clients honest.
    @Test func thePingAndPongWireTextIsExactlyTheTypeTag() throws {
        #expect(try ServerMessage.ping.jsonText() == #"{"type":"ping"}"#)
        #expect(try ClientMessage.pong.jsonText() == #"{"type":"pong"}"#)
    }
}

extension WireProtocolTests {
    /// The REQUEST's `payloadKind` must survive both directions of chunking — the reply side has
    /// exactly this pin (`StrippedSubmitTests`), and the request side shipped with the
    /// implementation and the comment but no test. The nil-kind round-trip test passes trivially
    /// if either hook drops the kind (nil == nil), so this one is NON-nil by construction:
    /// dropped anywhere, a chunked stripped request is read as a whole document and every large
    /// stripped request fails `undecodableDocument` — and in production MOST stripped requests
    /// chunk, since the stripped remainder of a big document exceeds the 256 KB inline limit.
    @Test func aStrippedRequestsKindSurvivesChunkingBothWays() throws {
        let original = ServerMessage.strokeOpRequest(
            requestId: 9, docId: "D", payload: .inline(Data([1, 2, 3])),
            spec: Data("{}".utf8), payloadKind: BlobOmissionWire.strippedDocKind)
        let descriptor = TransferDescriptor(transferId: 7, totalBytes: 3, chunkSize: 3)

        let announced = original.replacingBulk(with: descriptor)
        guard case .strokeOpRequest(_, _, .transfer, _, let announcedKind) = announced else {
            Issue.record("replacingBulk changed the message shape"); return
        }
        #expect(announcedKind == BlobOmissionWire.strippedDocKind,
                "the kind must ride the transfer descriptor")

        let resolved = announced.resolvingBulk(with: Data([1, 2, 3]))
        guard case .strokeOpRequest(let rid, let docId, .inline(let bytes), _, let resolvedKind) = resolved else {
            Issue.record("resolvingBulk changed the message shape"); return
        }
        #expect(rid == 9)
        #expect(docId == "D")
        #expect(bytes == Data([1, 2, 3]))
        #expect(resolvedKind == BlobOmissionWire.strippedDocKind,
                "the kind must land back beside the reassembled bytes")
    }
}
