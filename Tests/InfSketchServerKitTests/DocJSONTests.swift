import Foundation
import Testing
@testable import InfSketchServerKit

@Suite struct DocJSONTests {
    static let fixture: Data = Data(#"""
    {
      "darkColorScheme": true,
      "contentSizeWidth": 40000,
      "contentSizeHeight": 40000,
      "placedTextsData": [
        {
          "id": "AAAAAAAA-0000-0000-0000-000000000001",
          "text": ["Hello", {}],
          "rect": [[10, 20], [1, 1]],
          "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
          "opacity": 1, "pinned": false, "wordWrapEnabled": false,
          "colorSchemeIsDark": true
        },
        {
          "id": "AAAAAAAA-0000-0000-0000-000000000002",
          "text": ["Styled", {"NSColor": "ZHVtbXk=", "NSFont": "ZHVtbXk="}],
          "rect": [[300, 400], [366, 43]],
          "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": -5, "ty": 6},
          "opacity": 0.8, "pinned": true, "wordWrapEnabled": true,
          "maxWidth": 360, "layout": {"usesFontLeading": true},
          "colorSchemeIsDark": true
        }
      ],
      "strokeAnchors": {}
    }
    """#.utf8)

    @Test func summaryExtractsTextsAndConfig() throws {
        let s = try DocJSON.summary(from: Self.fixture)
        #expect(s.darkColorScheme == true)
        #expect(s.texts.count == 2)
        #expect(s.texts[0] == DocJSON.TextSummary(
            id: "AAAAAAAA-0000-0000-0000-000000000001",
            text: "Hello", x: 10, y: 20, pinned: false))
        #expect(s.texts[1].text == "Styled")
        #expect(s.texts[1].pinned == true)
    }

    @Test func addTextAppendsCanonicalEntryWithDocScheme() throws {
        let id = UUID()
        let out = try DocJSON.addText(to: Self.fixture, id: id, text: "New", x: 1, y: 2, pinned: false)
        let s = try DocJSON.summary(from: out)
        #expect(s.texts.count == 3)
        let added = try #require(s.texts.first(where: { $0.id == id.uuidString }))
        #expect(added.text == "New")
        // Entry inherits the doc's colour scheme:
        let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let texts = obj["placedTextsData"] as! [[String: Any]]
        let entry = texts.first(where: { ($0["id"] as? String) == id.uuidString })!
        #expect(entry["colorSchemeIsDark"] as? Bool == true)
        #expect((entry["text"] as? [Any])?.count == 2)
    }

    @Test func editTextMutatesStringAndPosition() throws {
        let out = try DocJSON.editText(in: Self.fixture,
                                       textId: "AAAAAAAA-0000-0000-0000-000000000002",
                                       newText: "Replaced", x: 7, y: nil)
        let s = try DocJSON.summary(from: out)
        let edited = try #require(s.texts.first(where: { $0.id.hasSuffix("0002") }))
        #expect(edited.text == "Replaced")
        #expect(edited.x == 7)
        #expect(edited.y == 400)   // untouched axis preserved
        // Replacing the string resets runs to [string, {}] (formatting reset, documented):
        let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let texts = obj["placedTextsData"] as! [[String: Any]]
        let entry = texts.first(where: { ($0["id"] as? String)?.hasSuffix("0002") == true })!
        let runs = entry["text"] as! [Any]
        #expect(runs.count == 2)
        #expect((runs[1] as? [String: Any])?.isEmpty == true)
    }

    @Test func editPositionOnlyPreservesRuns() throws {
        let out = try DocJSON.editText(in: Self.fixture,
                                       textId: "AAAAAAAA-0000-0000-0000-000000000002",
                                       newText: nil, x: nil, y: 999)
        let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let texts = obj["placedTextsData"] as! [[String: Any]]
        let entry = texts.first(where: { ($0["id"] as? String)?.hasSuffix("0002") == true })!
        let runs = entry["text"] as! [Any]
        #expect((runs[1] as? [String: Any])?["NSColor"] != nil)   // formatting kept
    }

    @Test func removeTextDeletesById() throws {
        let out = try DocJSON.removeText(from: Self.fixture, textId: "AAAAAAAA-0000-0000-0000-000000000001")
        #expect(try DocJSON.summary(from: out).texts.count == 1)
    }

    @Test func unknownIdThrows() {
        #expect(throws: DocJSON.DocJSONError.textNotFound) {
            _ = try DocJSON.removeText(from: Self.fixture, textId: "nope")
        }
    }

    @Test func garbageThrowsInvalidDocument() {
        #expect(throws: DocJSON.DocJSONError.invalidDocumentJSON) {
            _ = try DocJSON.summary(from: Data("not json".utf8))
        }
    }

}
