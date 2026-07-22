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

    /// Darwin's `JSONSerialization` PARSES the grammar-valid number `-1e999`
    /// as -infinity (negative overflow does not throw, unlike `+1e999`), so a
    /// document can make it INTO memory carrying a value that cannot be
    /// serialized back out. Mutations must surface that as
    /// `invalidDocumentJSON` — never trap the server process (a precondition
    /// here was remotely reachable via crafted document bytes).
    @Test func nonReserializableNumberThrowsInvalidDocumentOnMutation() {
        let fixture = Data(#"""
        {
          "darkColorScheme": false,
          "zoomScale": -1e999,
          "placedTextsData": [
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
        #expect(throws: DocJSON.DocJSONError.invalidDocumentJSON) {
            _ = try DocJSON.addText(to: fixture, id: UUID(), text: "New", x: 1, y: 2, pinned: false)
        }
        #expect(throws: DocJSON.DocJSONError.invalidDocumentJSON) {
            _ = try DocJSON.editText(in: fixture,
                                     textId: "AAAAAAAA-0000-0000-0000-000000000001",
                                     newText: "X", x: nil, y: nil)
        }
        #expect(throws: DocJSON.DocJSONError.invalidDocumentJSON) {
            _ = try DocJSON.removeText(from: fixture, textId: "AAAAAAAA-0000-0000-0000-000000000001")
        }
    }

    // MARK: - removeImage (agent-remove-image)

    @Test func removeImageDropsPlacedAndOrphanedPasted() throws {
        let doc = Data(#"""
        {
          "placedImagesData": [
            {"id": "P1", "pastedImageDataId": "B1", "rect": [[0, 0], [10, 10]]}
          ],
          "pastedImagesData": [
            {"id": "B1", "data": "AAAA"}
          ]
        }
        """#.utf8)
        let out = try DocJSON.removeImage(from: doc, imageId: "P1")
        let d = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        #expect((d["placedImagesData"] as! [Any]).isEmpty)
        #expect((d["pastedImagesData"] as! [Any]).isEmpty)   // orphan pruned
    }

    @Test func removeImageKeepsSharedBlobWhenAnotherPlacedReferencesIt() throws {
        let doc = Data(#"""
        {
          "placedImagesData": [
            {"id": "P1", "pastedImageDataId": "B1", "rect": [[0, 0], [10, 10]]},
            {"id": "P2", "pastedImageDataId": "B1", "rect": [[20, 20], [10, 10]]}
          ],
          "pastedImagesData": [
            {"id": "B1", "data": "AAAA"}
          ]
        }
        """#.utf8)
        let out = try DocJSON.removeImage(from: doc, imageId: "P1")
        let d = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let placed = d["placedImagesData"] as! [[String: Any]]
        #expect(placed.count == 1 && placed[0]["id"] as? String == "P2")
        #expect((d["pastedImagesData"] as! [Any]).count == 1)   // B1 still referenced by P2 -> kept
    }

    @Test func removeImageUnknownIdThrowsImageNotFound() throws {
        let doc = Data(#"""
        {
          "placedImagesData": [
            {"id": "P1", "pastedImageDataId": "B1", "rect": [[0, 0], [10, 10]]}
          ],
          "pastedImagesData": [
            {"id": "B1", "data": "AAAA"}
          ]
        }
        """#.utf8)
        #expect(throws: DocJSON.DocJSONError.imageNotFound) {
            _ = try DocJSON.removeImage(from: doc, imageId: "NOPE")
        }
    }

    /// Other document content (a placed text) survives untouched, and a STRAY
    /// non-dictionary element in BOTH `placedImagesData` and
    /// `pastedImagesData` is preserved — proof that removal casts each array
    /// element individually rather than casting the whole array at once (the
    /// same trap `removeText`'s stray-element regression test pins).
    @Test func removeImagePreservesOtherContentAndStrayElements() throws {
        let doc = Data(#"""
        {
          "placedTextsData": [
            {
              "id": "T1",
              "text": ["Hello", {}],
              "rect": [[10, 20], [1, 1]],
              "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
              "opacity": 1, "pinned": false, "wordWrapEnabled": false,
              "colorSchemeIsDark": false
            }
          ],
          "placedImagesData": [
            "stray-placed-element",
            {"id": "P1", "pastedImageDataId": "B1", "rect": [[0, 0], [10, 10]]}
          ],
          "pastedImagesData": [
            "stray-pasted-element",
            {"id": "B1", "data": "AAAA"}
          ]
        }
        """#.utf8)
        let out = try DocJSON.removeImage(from: doc, imageId: "P1")
        let d = try JSONSerialization.jsonObject(with: out) as! [String: Any]

        // Other content untouched:
        #expect((d["placedTextsData"] as! [Any]).count == 1)

        // The real entry is gone, the stray element survives:
        let placed = d["placedImagesData"] as! [Any]
        #expect(placed.count == 1)
        #expect((placed[0] as? String) == "stray-placed-element")

        // B1 was P1's only referencer, so it's pruned -- but the stray
        // pasted-blob element is preserved (per-element casting, not a
        // whole-array cast that would have emptied the array instead).
        let pasted = d["pastedImagesData"] as! [Any]
        #expect(pasted.count == 1)
        #expect((pasted[0] as? String) == "stray-pasted-element")
    }

    // A doc with one text (pinned:false) and one image (pinned:false) for set_pinned.
    static let pinFixture: Data = Data(#"""
    {
      "darkColorScheme": false,
      "placedTextsData": [
        {
          "id": "TTTTTTTT-0000-0000-0000-000000000001",
          "text": ["Hi", {}],
          "rect": [[10, 20], [1, 1]],
          "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
          "opacity": 1, "pinned": false
        }
      ],
      "placedImagesData": [
        {
          "id": "IIIIIIII-0000-0000-0000-000000000001",
          "pastedImageDataId": "PPPPPPPP-0000-0000-0000-000000000001",
          "rect": [[0, 0], [100, 100]],
          "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
          "opacity": 1, "pinned": false
        }
      ],
      "strokeAnchors": {}
    }
    """#.utf8)

    private static let textId = "TTTTTTTT-0000-0000-0000-000000000001"
    private static let imageId = "IIIIIIII-0000-0000-0000-000000000001"

    private func pinnedFlags(_ bytes: Data) throws -> (text: Bool, image: Bool) {
        let obj = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let t = (obj["placedTextsData"] as! [[String: Any]])[0]["pinned"] as! Bool
        let i = (obj["placedImagesData"] as! [[String: Any]])[0]["pinned"] as! Bool
        return (t, i)
    }

    @Test func setPinnedFlipsTextOnly() throws {
        let out = try DocJSON.setPinned(from: Self.pinFixture, ids: [Self.textId], pinned: true)
        let flags = try pinnedFlags(out)
        #expect(flags.text == true)
        #expect(flags.image == false)   // untouched
    }

    @Test func setPinnedFlipsImageOnly() throws {
        let out = try DocJSON.setPinned(from: Self.pinFixture, ids: [Self.imageId], pinned: true)
        let flags = try pinnedFlags(out)
        #expect(flags.text == false)    // untouched
        #expect(flags.image == true)
    }

    @Test func setPinnedFlipsMixedTextAndImage() throws {
        let out = try DocJSON.setPinned(from: Self.pinFixture, ids: [Self.textId, Self.imageId], pinned: true)
        let flags = try pinnedFlags(out)
        #expect(flags.text == true)
        #expect(flags.image == true)
    }

    @Test func setPinnedCanUnpin() throws {
        let pinned = try DocJSON.setPinned(from: Self.pinFixture, ids: [Self.textId, Self.imageId], pinned: true)
        let out = try DocJSON.setPinned(from: pinned, ids: [Self.textId, Self.imageId], pinned: false)
        let flags = try pinnedFlags(out)
        #expect(flags.text == false)
        #expect(flags.image == false)
    }

    @Test func setPinnedUnknownIdThrowsAndMutatesNothing() throws {
        #expect(throws: DocJSON.DocJSONError.elementNotFound) {
            // one valid id + one unknown -> atomic failure, nothing changes
            _ = try DocJSON.setPinned(from: Self.pinFixture, ids: [Self.textId, "nope"], pinned: true)
        }
        // Atomicity: the VALID id (the text) must NOT have been pinned by the
        // failed call — the source fixture still reads pinned:false for both.
        let flags = try pinnedFlags(Self.pinFixture)
        #expect(flags.text == false)
        #expect(flags.image == false)
    }

    @Test func setPinnedToCurrentValueIsAValidNoopReencode() throws {
        // Idempotence: setting pinned to its existing value (false -> false) is a
        // valid re-encode, never a throw; the flags stay put.
        let out = try DocJSON.setPinned(from: Self.pinFixture, ids: [Self.textId, Self.imageId], pinned: false)
        let flags = try pinnedFlags(out)
        #expect(flags.text == false)
        #expect(flags.image == false)
    }

    @Test func setPinnedChangesOnlyThePinnedField() throws {
        let out = try DocJSON.setPinned(from: Self.pinFixture, ids: [Self.imageId], pinned: true)
        let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let img = (obj["placedImagesData"] as! [[String: Any]])[0]
        #expect(img["id"] as? String == Self.imageId)
        #expect(img["pastedImageDataId"] as? String == "PPPPPPPP-0000-0000-0000-000000000001")
        #expect((img["opacity"] as? NSNumber)?.doubleValue == 1)
        #expect(img["pinned"] as? Bool == true)
        // Geometry fields survive too — only `pinned` changed.
        let rect = img["rect"] as! [[NSNumber]]
        #expect(rect[0].map(\.doubleValue) == [0, 0])
        #expect(rect[1].map(\.doubleValue) == [100, 100])
        let transform = img["transform"] as! [String: NSNumber]
        #expect(transform["a"]?.doubleValue == 1)
        #expect(transform["d"]?.doubleValue == 1)
    }

    @Test func setPinnedPreservesStrayNonDictionaryElements() throws {
        // A stray non-dictionary element in placedTextsData must survive untouched.
        let stray = Data(#"""
        {
          "placedTextsData": [
            "STRAY",
            {
              "id": "TTTTTTTT-0000-0000-0000-000000000001",
              "text": ["Hi", {}], "rect": [[1, 1], [1, 1]],
              "transform": {"a":1,"b":0,"c":0,"d":1,"tx":0,"ty":0},
              "opacity": 1, "pinned": false
            }
          ]
        }
        """#.utf8)
        let out = try DocJSON.setPinned(from: stray, ids: [Self.textId], pinned: true)
        let elements = (try JSONSerialization.jsonObject(with: out) as! [String: Any])["placedTextsData"] as! [Any]
        #expect(elements.count == 2)
        #expect(elements[0] as? String == "STRAY")
        #expect((elements[1] as! [String: Any])["pinned"] as? Bool == true)
    }

}
