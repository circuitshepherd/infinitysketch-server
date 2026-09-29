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

    @Test func aSubscribeNamesItsBase() throws {
        let hash = String(repeating: "b", count: 64)
        let message = ClientMessage.subscribe(docId: "ID", createIfMissing: true, name: "N",
                                              baseHash: hash, fileHash: hash, wantBase: true)
        #expect(try ClientMessage(jsonText: message.jsonText()) == message)
        let saved = ClientMessage.baseSaved(docId: "ID", versionHash: hash)
        #expect(try ClientMessage(jsonText: saved.jsonText()) == saved)
    }

    /// The chunk swap must carry the new fields: a dropped `snapshotKind` would hand the device a
    /// bundle it then stores as a document — the loss only a message big enough to chunk shows.
    @Test func aChunkedSubscribedKeepsItsBaseFields() throws {
        let message = ServerMessage.subscribed(docId: "ID", seq: 3, snapshot: .inline(Data(repeating: 7, count: 200_000)),
                                               baseHash: String(repeating: "c", count: 64),
                                               snapshotKind: SnapshotBundleWire.kind)
        var sender = TransferSender<ServerMessage>(inlineLimit: 1024, chunkSize: 4096)
        var reassembler = TransferReassembler<ServerMessage>()
        var out: ServerMessage?
        for frame in try sender.frames(for: message) {
            let wire: WireFrame
            switch frame { case .text(let t): wire = .text(t); case .binary(let d): wire = .binary(d) }
            if let m = try reassembler.consume(wire) { out = m }
        }
        #expect(out == message)
    }
}
