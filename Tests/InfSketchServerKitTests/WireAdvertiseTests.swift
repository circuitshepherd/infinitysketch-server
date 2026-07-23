import XCTest
@testable import InfSketchWire

final class WireAdvertiseTests: XCTestCase {
    /// `deviceId` is OPTIONAL — an older client's hello (no deviceId key) must still decode.
    func testHelloDeviceIdRoundTripsAndIsOptional() throws {
        let withId = ClientMessage.hello(protocolVersion: 1, capabilities: ["render"], deviceId: "dev-A")
        let data = try JSONEncoder().encode(withId)
        XCTAssertEqual(try JSONDecoder().decode(ClientMessage.self, from: data), withId)

        let legacy = #"{"type":"hello","protocolVersion":1,"capabilities":["render"]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ClientMessage.self, from: legacy),
                       .hello(protocolVersion: 1, capabilities: ["render"], deviceId: nil))
    }

    func testAdvertiseDocsRoundTripsInline() throws {
        let ads = [DocAdvertisement(docId: "Foo", modifiedAt: Date(timeIntervalSince1970: 100),
                                    sizeBytes: 42, thumbnail: Data([1, 2, 3]))]
        let msg = ClientMessage.advertiseDocs(payload: .inline(try JSONEncoder().encode(ads)))
        let data = try JSONEncoder().encode(msg)
        guard case .advertiseDocs(let payload) = try JSONDecoder().decode(ClientMessage.self, from: data),
              case .inline(let inline) = payload else { return XCTFail("expected inline advertiseDocs") }
        XCTAssertEqual(try JSONDecoder().decode([DocAdvertisement].self, from: inline), ads)
    }

    /// A newer server's entry decodes in an older-shaped reader: missing `hasContent`
    /// must default to TRUE (every pre-M2b doc had content).
    func testDocListEntryNewFieldsDefaultForOlderPayloads() throws {
        let legacy = #"{"id":"Foo","sizeBytes":10,"modifiedAt":0}"#.data(using: .utf8)!
        let entry = try JSONDecoder().decode(DocListEntry.self, from: legacy)
        XCTAssertTrue(entry.hasContent)
        XCTAssertNil(entry.originDeviceId)

        let full = DocListEntry(id: "Bar", sizeBytes: 1, modifiedAt: Date(timeIntervalSince1970: 0),
                                seq: nil, subscriberCount: nil, hasContent: false, originDeviceId: "dev-A")
        XCTAssertEqual(try JSONDecoder().decode(DocListEntry.self,
                                                from: try JSONEncoder().encode(full)), full)
    }
}
