import Foundation
import Testing
@testable import InfSketchWire

/// `DocumentIdentity` edits one top-level value at the byte level (round 5, item 6).
@Suite struct DocumentIdentityTests {

    @Test func itReplacesOnlyTheTopLevelIdAndLeavesEveryOtherByte() {
        let doc = Data(#"{"aaa001_thumbnailData":"x\"y","nested":{"documentId":"INNER"},"documentId":"OLD" ,"z":[1,{"a":"}"}]}"#.utf8)
        #expect(DocumentIdentity.documentId(of: doc) == "OLD")
        let out = DocumentIdentity.replacingDocumentId(in: doc, with: "NEW")
        #expect(String(decoding: out, as: UTF8.self)
                == #"{"aaa001_thumbnailData":"x\"y","nested":{"documentId":"INNER"},"documentId":"NEW" ,"z":[1,{"a":"}"}]}"#)
    }

    @Test func aLegacyOrMalformedDocumentIsLeftAlone() {
        let legacy = Data(#"{"aaa001_thumbnailData":"","nested":{"documentId":"INNER"}}"#.utf8)
        #expect(DocumentIdentity.documentId(of: legacy) == nil)
        #expect(DocumentIdentity.replacingDocumentId(in: legacy, with: "NEW") == legacy)
        for garbage in ["", "[]", "{", #"{"documentId":"#, #"{"documentId":7}"#] {
            let bytes = Data(garbage.utf8)
            #expect(DocumentIdentity.replacingDocumentId(in: bytes, with: "NEW") == bytes)
        }
    }

    /// Works on a slice (non-zero start index), which is what a `Data` cut from a larger buffer is.
    @Test func itWorksOnASlice() {
        let whole = Data(#"XX{"documentId":"A","b":1}"#.utf8)
        let slice = whole.dropFirst(2)
        #expect(DocumentIdentity.documentId(of: slice) == "A")
        #expect(String(decoding: DocumentIdentity.replacingDocumentId(in: slice, with: "B"), as: UTF8.self)
                == #"{"documentId":"B","b":1}"#)
    }

    /// A legacy document (no id) gets one at the position the app's sorted encoder would have
    /// written it — right after the thumbnail and the keys that sort before it — so the thumbnail
    /// stays FIRST (the extension stops after one key) and the app's streaming id reader stops early.
    @Test func settingAnIdInsertsItAtTheSortedPosition() throws {
        let legacy = Data(#"{"aaa001_thumbnailData":"x","darkColorScheme":true,"drawingData":"AA==","z":1}"#.utf8)
        let out = DocumentIdentity.settingDocumentId(in: legacy, to: "NEW")
        #expect(String(decoding: out, as: UTF8.self)
                == #"{"aaa001_thumbnailData":"x","darkColorScheme":true,"documentId":"NEW","drawingData":"AA==","z":1}"#)
        #expect(DocumentIdentity.documentId(of: out) == "NEW")
        #expect(try JSONSerialization.jsonObject(with: out) is [String: Any])
    }

    @Test func settingAnIdWhenEveryKeySortsBeforeItAppendsIt() {
        let doc = Data(#"{"aaa001_thumbnailData":"x","b":1}"#.utf8)
        #expect(String(decoding: DocumentIdentity.settingDocumentId(in: doc, to: "N"), as: UTF8.self)
                == #"{"aaa001_thumbnailData":"x","b":1,"documentId":"N"}"#)
        #expect(String(decoding: DocumentIdentity.settingDocumentId(in: Data("{}".utf8), to: "N"), as: UTF8.self)
                == #"{"documentId":"N"}"#)
    }

    @Test func settingAnIdReplacesAnExistingOne() {
        let doc = Data(#"{"aaa001_thumbnailData":"x","documentId":"OLD"}"#.utf8)
        #expect(DocumentIdentity.documentId(of: DocumentIdentity.settingDocumentId(in: doc, to: "NEW")) == "NEW")
    }

    @Test func settingAnIdLeavesMalformedBytesAlone() {
        for garbage in ["", "[]", "{", #"{"a":"#] {
            let bytes = Data(garbage.utf8)
            #expect(DocumentIdentity.settingDocumentId(in: bytes, to: "N") == bytes)
        }
    }
}
