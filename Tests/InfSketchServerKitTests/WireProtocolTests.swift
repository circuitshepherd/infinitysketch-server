import Foundation
import Testing
@testable import InfSketchServerKit

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
            .subscribed(docId: "a", seq: 0, snapshot: Data([9])),
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
