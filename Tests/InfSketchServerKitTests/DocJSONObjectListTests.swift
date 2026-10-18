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

    /// Review I2 (2026-10-15): an agent could not delete an arrow from a CLOSED document — the
    /// only door was select_elements + delete_selection, which needs it open on a device.
    @Test func removeArrowRemovesOnlyThatArrowFromTheList() throws {
        var obj = try Self.object(Self.fixture)
        let arrowId = "DDDDDDDD-0000-0000-0000-000000000001"
        var list = obj["placedObjects"] as! [Any]
        list.insert(["kind": "arrow", "layer": "front", "id": arrowId,
                     "points": [["x": 0, "y": 0], ["x": 50, "y": 0]], "width": 2, "pinned": false] as [String: Any], at: 1)
        obj["placedObjects"] = list
        obj["formatVersion"] = 6
        let withArrow = try JSONSerialization.data(withJSONObject: obj)
        let out = try DocJSON.removeArrow(from: withArrow, arrowId: arrowId)
        #expect(try Self.ids(out) == [Self.t1, Self.i1, Self.t2])
        #expect(throws: DocJSON.DocJSONError.arrowNotFound) { try DocJSON.removeArrow(from: withArrow, arrowId: Self.t1) }
        #expect(throws: DocJSON.DocJSONError.arrowNotFound) { try DocJSON.removeArrow(from: Self.fixture, arrowId: arrowId) }
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

    // Document format 6: an arrow element is another kind in the list. Every per-kind edit keeps
    // it in its slot, and set_pinned reaches it.
    static let a1 = "DDDDDDDD-0000-0000-0000-000000000001"
    static var withArrow: Data {
        var obj = try! object(fixture)
        var list = obj["placedObjects"] as! [Any]
        list.insert(["kind": "arrow", "layer": "front", "id": a1, "pinned": false, "width": 3,
                     "startHead": "flatEnd", "endHead": "filledTriangle",
                     "points": [["x": 0, "y": 0], ["x": 50, "y": 0]],
                     "color": ["red": 0, "green": 0, "blue": 0, "alpha": 1]] as [String: Any], at: 1)
        obj["placedObjects"] = list
        obj["formatVersion"] = 6
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test func anArrowKeepsItsSlotThroughTextAndImageEdits() throws {
        let added = try DocJSON.addText(to: Self.withArrow, id: UUID(), text: "New", x: 1, y: 2, pinned: false)
        #expect(try Self.ids(added).prefix(4) == [Self.t1, Self.a1, Self.i1, Self.t2])
        let removed = try DocJSON.removeText(from: Self.withArrow, textId: Self.t1)
        #expect(try Self.ids(removed) == [Self.a1, Self.i1, Self.t2])
        let noImage = try DocJSON.removeImage(from: Self.withArrow, imageId: Self.i1)
        #expect(try Self.ids(noImage) == [Self.t1, Self.a1, Self.t2])
        #expect(try DocJSON.summary(from: Self.withArrow).texts.map(\.id) == [Self.t1, Self.t2])
    }

    @Test func setPinnedReachesAnArrow() throws {
        let out = try DocJSON.setPinned(from: Self.withArrow, ids: [Self.a1], pinned: true)
        let objects = try Self.object(out)["placedObjects"] as! [[String: Any]]
        #expect(objects.map { $0["pinned"] as? Bool } == [false, true, false, false])
        #expect(try Self.ids(out) == [Self.t1, Self.a1, Self.i1, Self.t2])
    }
}
