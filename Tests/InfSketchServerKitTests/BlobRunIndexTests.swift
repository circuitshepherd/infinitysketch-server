import Testing
import Foundation
@testable import InfSketchWire

/// The blob runs of a document, computed ONCE and handed to several strips and restores.
///
/// Finding them is the expensive half of blob omission — a whole-document `JSONSerialization`
/// parse plus an escape pass over every blob's base64 — and a caller that holds a document across
/// more than one of those (the server's `DocumentSession`, the broker's per-connection ledger)
/// otherwise pays for the identical answer twice. These tests pin the property that makes reuse
/// legitimate: an index is a pure function of the bytes, so passing one in must be
/// indistinguishable from taking it fresh.
@Suite struct BlobRunIndexTests {

    private func document(blobId: UUID, payload: String, tail: String = "tail") -> Data {
        Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }

    private var payload: String { String(repeating: "ab\\/cd", count: 2000) }

    @Test func anIndexPassedInStripsExactlyLikeOneTakenFresh() {
        let id = UUID()
        let base = document(blobId: id, payload: payload)
        let updated = document(blobId: id, payload: payload, tail: "edited")

        let fresh = StrippedDocument.strip(document: updated, against: base,
                                           basedOn: Data(repeating: 1, count: 32),
                                           originalSHA256: Data(repeating: 2, count: 32))
        let reused = StrippedDocument.strip(document: updated, againstRuns: BlobRunIndex(of: base),
                                            basedOn: Data(repeating: 1, count: 32),
                                            originalSHA256: Data(repeating: 2, count: 32))

        #expect(fresh == reused)
        #expect(fresh.parts.contains { if case .blob = $0 { return true } else { return false } },
                "the fixture must actually omit something, or this compares two no-ops")
    }

    @Test func anIndexPassedInRestoresExactlyLikeOneTakenFresh() throws {
        let id = UUID()
        let base = document(blobId: id, payload: payload)
        let updated = document(blobId: id, payload: payload, tail: "edited")
        let stripped = StrippedDocument.strip(document: updated, against: base,
                                              basedOn: Data(repeating: 1, count: 32),
                                              originalSHA256: Data(repeating: 2, count: 32))

        #expect(try stripped.restore(using: base) == updated)
        #expect(try stripped.restore(usingRuns: BlobRunIndex(of: base)) == updated)
    }

    /// An index of the WRONG document is missing the run, so the rebuild fails by name rather
    /// than splicing something plausible. That is what keeps a stale cache a resend and never a
    /// wrong document.
    @Test func anIndexOfADifferentDocumentFailsRatherThanSplicingSomethingElse() {
        let id = UUID()
        let base = document(blobId: id, payload: payload)
        let stripped = StrippedDocument.strip(document: base, against: base,
                                              basedOn: Data(repeating: 1, count: 32),
                                              originalSHA256: Data(repeating: 2, count: 32))

        #expect(throws: StrippedDocumentError.self) {
            try stripped.restore(usingRuns: BlobRunIndex(of: Data("{}".utf8)))
        }
    }

    @Test func anIndexNamesEveryBlobFieldTheDocumentCarries() {
        let id = UUID()
        let index = BlobRunIndex(of: document(blobId: id, payload: payload))
        #expect(index.runs[id]?[.data] != nil)
        #expect(BlobRunIndex(of: Data("{}".utf8)).isEmpty)
    }
}

/// The escape itself. `JSONEncoder` writes base64's `/` as `\/`, so the run in the file is the
/// base64 with that one substitution — and producing it is 37.5 ms of the ~62 ms one index costs
/// on a 6.7 MB document, because `String.replacingOccurrences` re-forms a multi-megabyte String
/// whose only consumer is `Data(_.utf8)`. The byte form must agree with it exactly.
@Suite struct BlobEscapeTests {

    @Test func theByteFormAgreesWithTheStringForm() {
        for raw in ["", "/", "//", "ab/cd/ef", "abc", "///a///",
                    String(repeating: "a/b", count: 5000),
                    String(repeating: "/", count: 4096)] {
            #expect(DocumentBlobs.escapedBytes(raw) == Data(DocumentBlobs.escaped(raw).utf8),
                    "disagreed on a \(raw.count)-character input")
        }
    }

    @Test func theEscapeTouchesNothingButTheSlash() {
        #expect(DocumentBlobs.escapedBytes("ab/cd/ef") == Data("ab\\/cd\\/ef".utf8))
        #expect(DocumentBlobs.escapedBytes("A+z0=") == Data("A+z0=".utf8))
    }
}
