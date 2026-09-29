import Foundation
import Testing
import InfSketchWire

@Suite struct WireIdentityTests {
    @Test func subscribeCarriesTheName() throws {
        let message = ClientMessage.subscribe(docId: "ID-1", createIfMissing: true, name: "Chart")
        #expect(try ClientMessage(jsonText: message.jsonText()) == message)
    }

    @Test func subscribeWithoutANameStillDecodes() throws {
        let text = #"{"type":"subscribe","docId":"ID-1","createIfMissing":true}"#
        #expect(try ClientMessage(jsonText: text) == .subscribe(docId: "ID-1", createIfMissing: true, name: nil))
    }

    @Test func renameRoundTripsBothWays() throws {
        let rename = ClientMessage.renameDoc(docId: "ID-1", name: "Plan B")
        #expect(try ClientMessage(jsonText: rename.jsonText()) == rename)
        let renamed = ServerMessage.docRenamed(docId: "ID-1", name: "Plan B")
        #expect(try ServerMessage(jsonText: renamed.jsonText()) == renamed)
    }

    @Test func listingAndAdvertisementCarryNames() throws {
        let entry = DocListEntry(id: "ID-1", name: "Chart", sizeBytes: 1, modifiedAt: Date(timeIntervalSince1970: 0),
                                 seq: nil, subscriberCount: nil)
        let decoded = try JSONDecoder().decode(DocListEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.name == "Chart")
        let ad = DocAdvertisement(docId: "ID-1", name: "Chart", modifiedAt: Date(timeIntervalSince1970: 0),
                                  sizeBytes: 1, thumbnail: nil)
        #expect(try JSONDecoder().decode(DocAdvertisement.self, from: JSONEncoder().encode(ad)).name == "Chart")
    }

    /// A peer that sends no name (the demo client, an older test) is labelled by the id.
    @Test func aMissingNameFallsBackToTheId() throws {
        let entry = try JSONDecoder().decode(DocListEntry.self, from: Data(
            #"{"id":"ID-1","sizeBytes":1,"modifiedAt":0}"#.utf8))
        #expect(entry.name == "ID-1")
        let ad = try JSONDecoder().decode(DocAdvertisement.self, from: Data(
            #"{"docId":"ID-1","modifiedAt":0,"sizeBytes":1}"#.utf8))
        #expect(ad.name == "ID-1")
    }
}
