import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct WireProtocolTests {
    @Test func clientMessagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .hello(protocolVersion: 1, capabilities: ["render"]),
            .subscribe(docId: "a", fromSeq: 7),
            .subscribe(docId: "a", fromSeq: nil),
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
        let json = try ClientMessage.subscribe(docId: "doc1", fromSeq: nil).jsonText()
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
