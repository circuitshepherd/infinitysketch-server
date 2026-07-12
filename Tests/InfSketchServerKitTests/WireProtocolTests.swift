import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct WireProtocolTests {
    @Test func clientMessagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .hello(protocolVersion: 1, capabilities: ["render"]),
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
        let w = ClientMessage.watchDoc(docId: "d")
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
        let w = ServerMessage.watchers(docId: "d", count: 2)
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
