import Foundation
import Testing
@testable import InfSketchServerKit

/// Document format 5 (object layers): texts and images are ONE list, `placedObjects`, each
/// element carrying `kind`. The server's direct JSON edits must work on that list in place and
/// never write the old per-kind keys into such a document.
@Suite struct DocJSONObjectListTests {
    static let t1 = "AAAAAAAA-0000-0000-0000-000000000001"
    static let i1 = "BBBBBBBB-0000-0000-0000-000000000001"
    static let t2 = "AAAAAAAA-0000-0000-0000-000000000002"
    static let blob = "CCCCCCCC-0000-0000-0000-000000000001"

    static let fixture: Data = Data(#"""
    {
      "formatVersion": 5,
      "darkColorScheme": false,
      "placedObjects": [
        {"kind": "text", "layer": "back", "id": "AAAAAAAA-0000-0000-0000-000000000001",
         "text": ["Behind", {}], "rect": [[10, 20], [1, 1]],
         "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
         "opacity": 1, "pinned": false, "wordWrapEnabled": false, "colorSchemeIsDark": false},
        {"kind": "image", "layer": "front", "id": "BBBBBBBB-0000-0000-0000-000000000001",
         "pastedImageDataId": "CCCCCCCC-0000-0000-0000-000000000001", "rect": [[0, 0], [10, 10]],
         "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
         "opacity": 1, "pinned": false},
        {"kind": "text", "layer": "front", "id": "AAAAAAAA-0000-0000-0000-000000000002",
         "text": ["Front", {}], "rect": [[30, 40], [1, 1]],
         "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
         "opacity": 1, "pinned": false, "wordWrapEnabled": false, "colorSchemeIsDark": false}
      ],
      "pastedImagesData": [{"id": "CCCCCCCC-0000-0000-0000-000000000001", "data": "", "thumbnailData": ""}]
    }
    """#.utf8)

    static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func ids(_ data: Data) throws -> [String] {
        (try object(data)["placedObjects"] as! [[String: Any]]).map { $0["id"] as! String }
    }

    @Test func theSummaryReadsTextsFromTheList() throws {
        let s = try DocJSON.summary(from: Self.fixture)
        #expect(s.texts.map(\.id) == [Self.t1, Self.t2])
    }

    @Test func addTextAppendsAFrontTextToTheListAndNoOldKey() throws {
        let id = UUID()
        let out = try DocJSON.addText(to: Self.fixture, id: id, text: "New", x: 1, y: 2, pinned: false)
        let obj = try Self.object(out)
        #expect(obj["placedTextsData"] == nil && obj["placedImagesData"] == nil)
        #expect(try Self.ids(out) == [Self.t1, Self.i1, Self.t2, id.uuidString])
        let entry = (obj["placedObjects"] as! [[String: Any]]).last!
        #expect(entry["kind"] as? String == "text" && entry["layer"] as? String == "front")
    }

    @Test func editAndRemoveTextKeepEveryOtherSlot() throws {
        let edited = try DocJSON.editText(in: Self.fixture, textId: Self.t1, newText: "Moved", x: 5, y: nil)
        #expect(try Self.ids(edited) == [Self.t1, Self.i1, Self.t2])
        let first = (try Self.object(edited)["placedObjects"] as! [[String: Any]])[0]
        #expect(first["layer"] as? String == "back" && (first["text"] as? [Any])?.first as? String == "Moved")
        let removed = try DocJSON.removeText(from: Self.fixture, textId: Self.t1)
        #expect(try Self.ids(removed) == [Self.i1, Self.t2])
        #expect(throws: DocJSON.DocJSONError.textNotFound) { try DocJSON.removeText(from: Self.fixture, textId: Self.i1) }
    }

    @Test func removeImageRemovesItFromTheListAndPrunesTheBlob() throws {
        let out = try DocJSON.removeImage(from: Self.fixture, imageId: Self.i1)
        #expect(try Self.ids(out) == [Self.t1, Self.t2])
        #expect((try Self.object(out)["pastedImagesData"] as? [Any])?.isEmpty == true)
    }

    @Test func setPinnedFlipsTextsAndImagesInPlace() throws {
        let out = try DocJSON.setPinned(from: Self.fixture, ids: [Self.t2, Self.i1], pinned: true)
        let objects = try Self.object(out)["placedObjects"] as! [[String: Any]]
        #expect(objects.map { $0["pinned"] as? Bool } == [false, true, true])
        #expect(try Self.ids(out) == [Self.t1, Self.i1, Self.t2])
        #expect(try Self.object(out)["placedTextsData"] == nil)
    }
}
