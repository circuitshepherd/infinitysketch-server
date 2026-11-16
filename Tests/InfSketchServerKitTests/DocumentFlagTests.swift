import Foundation
import Testing
@testable import InfSketchWire

/// `DocumentFlag` sets one top-level boolean of a document at the byte level — the app turns
/// `syncEnabled` off in a CLOSED file when the server says the document was deleted.
@Suite struct DocumentFlagTests {

    @Test func itReplacesOnlyTheTopLevelValueAndLeavesEveryOtherByte() {
        let doc = Data(#"{"aaa001_thumbnailData":"x\"y","nested":{"syncEnabled":true},"syncEnabled":true ,"z":[1,{"a":"}"}]}"#.utf8)
        let out = DocumentFlag.setting("syncEnabled", to: false, in: doc)
        #expect(String(decoding: out, as: UTF8.self)
                == #"{"aaa001_thumbnailData":"x\"y","nested":{"syncEnabled":true},"syncEnabled":false ,"z":[1,{"a":"}"}]}"#)
        #expect(DocumentFlag.value(of: "syncEnabled", in: out) == false)
    }

    /// A document that already says so comes back as the SAME bytes: the caller reads "nothing to
    /// write" off that.
    @Test func aDocumentThatAlreadyCarriesTheValueIsUnchanged() {
        let doc = Data(#"{"a":1,"syncEnabled":false,"z":2}"#.utf8)
        #expect(DocumentFlag.setting("syncEnabled", to: false, in: doc) == doc)
    }

    /// A file written before the key existed has none. It is inserted where the app's sorted
    /// encoder would have written it, so the thumbnail stays the first key.
    @Test func anAbsentKeyIsInsertedAtTheSortedPosition() throws {
        let doc = Data(#"{"aaa001_thumbnailData":"x","drawingData":"AA==","textDefaultStyle":{},"zoom":1}"#.utf8)
        #expect(DocumentFlag.value(of: "syncEnabled", in: doc) == nil)
        let out = DocumentFlag.setting("syncEnabled", to: false, in: doc)
        #expect(String(decoding: out, as: UTF8.self)
                == #"{"aaa001_thumbnailData":"x","drawingData":"AA==","syncEnabled":false,"textDefaultStyle":{},"zoom":1}"#)
        #expect(try JSONSerialization.jsonObject(with: out) is [String: Any])
    }

    @Test func anAbsentKeyThatSortsLastGoesBeforeTheClosingBrace() throws {
        let doc = Data(#"{"a":1,"b":[2]}"#.utf8)
        #expect(String(decoding: DocumentFlag.setting("syncEnabled", to: true, in: doc), as: UTF8.self)
                == #"{"a":1,"b":[2],"syncEnabled":true}"#)
        #expect(String(decoding: DocumentFlag.setting("syncEnabled", to: false, in: Data("{}".utf8)), as: UTF8.self)
                == #"{"syncEnabled":false}"#)
    }

    /// Bytes that are not a JSON object, and a key whose value is not a boolean (a form this code
    /// does not know), are left exactly as they are.
    @Test func malformedBytesAndANonBooleanValueAreLeftAlone() {
        for garbage in ["", "[]", "{", #"{"syncEnabled":"#, #"{"syncEnabled":"yes"}"#, #"{"syncEnabled":1}"#] {
            let bytes = Data(garbage.utf8)
            #expect(DocumentFlag.setting("syncEnabled", to: false, in: bytes) == bytes, "\(garbage)")
        }
    }

    /// Works on a slice (non-zero start index), which is what a `Data` cut from a larger buffer is.
    @Test func itWorksOnASlice() {
        let whole = Data(#"XX{"syncEnabled":true,"b":1}"#.utf8)
        let slice = whole.dropFirst(2)
        #expect(DocumentFlag.value(of: "syncEnabled", in: slice) == true)
        #expect(String(decoding: DocumentFlag.setting("syncEnabled", to: false, in: slice), as: UTF8.self)
                == #"{"syncEnabled":false,"b":1}"#)
    }
}
