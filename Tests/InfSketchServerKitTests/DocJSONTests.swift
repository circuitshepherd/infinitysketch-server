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

    // MARK: - Review fixes (post-056cde8)

    /// A `placedTextsData` array containing a stray non-dictionary element
    /// alongside a well-formed entry. Regression fixture for the whole-array
    /// `as? [[String: Any]]` cast that turned ONE bad element into "no texts
    /// at all" on read and destroyed every existing text on `addText`.
    static let strayElementFixture: Data = Data(#"""
    {
      "darkColorScheme": false,
      "placedTextsData": [
        "stray-non-dict-element",
        {
          "id": "AAAAAAAA-0000-0000-0000-000000000001",
          "text": ["Hello", {}],
          "rect": [[10, 20], [1, 1]],
          "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
          "opacity": 1, "pinned": false, "wordWrapEnabled": false,
          "colorSchemeIsDark": false
        }
      ],
      "strokeAnchors": {}
    }
    """#.utf8)

    @Test func strayElementIsSkippedBySummaryAndPreservedByAddText() throws {
        // summary skips the stray element but still reports the valid entry:
        let s = try DocJSON.summary(from: Self.strayElementFixture)
        #expect(s.texts.count == 1)
        #expect(s.texts[0].text == "Hello")

        // addText preserves BOTH the stray element and the existing entry:
        let id = UUID()
        let out = try DocJSON.addText(to: Self.strayElementFixture, id: id, text: "New", x: 1, y: 2, pinned: false)
        let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let elements = obj["placedTextsData"] as! [Any]
        #expect(elements.count == 3)
        #expect(elements.contains { ($0 as? String) == "stray-non-dict-element" })
        #expect(elements.contains { (($0 as? [String: Any])?["id"] as? String) == "AAAAAAAA-0000-0000-0000-000000000001" })
        #expect(elements.contains { (($0 as? [String: Any])?["id"] as? String) == id.uuidString })
    }

    @Test func strayElementIsPreservedByEditAndRemove() throws {
        // editText locates the real entry despite the stray sibling and keeps it:
        let edited = try DocJSON.editText(in: Self.strayElementFixture,
                                          textId: "AAAAAAAA-0000-0000-0000-000000000001",
                                          newText: nil, x: nil, y: 99)
        let editedObj = try JSONSerialization.jsonObject(with: edited) as! [String: Any]
        let editedElements = editedObj["placedTextsData"] as! [Any]
        #expect(editedElements.count == 2)
        #expect(editedElements.contains { ($0 as? String) == "stray-non-dict-element" })
        let editedSummary = try DocJSON.summary(from: edited)
        #expect(editedSummary.texts[0].y == 99)

        // removeText removes only the matching entry; the stray element survives:
        let removed = try DocJSON.removeText(from: Self.strayElementFixture,
                                             textId: "AAAAAAAA-0000-0000-0000-000000000001")
        let removedObj = try JSONSerialization.jsonObject(with: removed) as! [String: Any]
        let removedElements = removedObj["placedTextsData"] as! [Any]
        #expect(removedElements.count == 1)
        #expect((removedElements[0] as? String) == "stray-non-dict-element")
    }

    /// AttributedString's Codable form is an ALTERNATING sequence of
    /// (run string, attributes dict) pairs — one pair per attribute run. A text
    /// with mixed formatting therefore has multiple string elements; summary
    /// must concatenate them all, not truncate to the first run.
    @Test func multiRunTextConcatenatesAllRuns() throws {
        let fixture = Data(#"""
        {
          "darkColorScheme": false,
          "placedTextsData": [
            {
              "id": "AAAAAAAA-0000-0000-0000-000000000003",
              "text": ["Hello ", {"NSFont": "ZHVtbXk="}, "world", {}],
              "rect": [[1, 2], [1, 1]],
              "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
              "opacity": 1, "pinned": false, "wordWrapEnabled": false,
              "colorSchemeIsDark": false
            }
          ],
          "strokeAnchors": {}
        }
        """#.utf8)
        let s = try DocJSON.summary(from: fixture)
        #expect(s.texts.count == 1)
        #expect(s.texts[0].text == "Hello world")
    }

}
