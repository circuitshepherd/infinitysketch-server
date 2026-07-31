import Testing
import Foundation
@testable import InfSketchWire

@Suite struct StrippedDocumentCodecTests {

    /// Binary, not JSON: the literal parts are raw document bytes, and base64-ing them into a JSON
    /// envelope would inflate exactly what this feature saves by a third.
    @Test func aStrippedDocumentSurvivesItsOwnEncoding() throws {
        let id = UUID()
        let original = StrippedDocument(
            parts: [.literal(Data([0x7B, 0x22, 0x61])),
                    .blob(id: id, field: .data),
                    .literal(Data([0x22, 0x7D])),
                    .blob(id: id, field: .thumbnailData)],
            basedOn: Data(repeating: 0xAB, count: 32),
            originalSHA256: Data(repeating: 0xCD, count: 32))

        #expect(try StrippedDocument(encoded: original.encoded()) == original)
    }

    /// Truncation is an error, not a partial read that silently loses a part.
    @Test func aTruncatedEncodingIsRejected() {
        let encoded = StrippedDocument(parts: [.literal(Data([1, 2, 3]))],
                                       basedOn: Data(repeating: 0, count: 32),
                                       originalSHA256: Data(repeating: 0, count: 32)).encoded()
        #expect(throws: StrippedDocumentError.self) {
            try StrippedDocument(encoded: encoded.dropLast(2))
        }
    }

    /// The literal bytes travel verbatim — no base64, no escaping, no inflation.
    @Test func literalBytesAreNotInflated() {
        let payload = Data(repeating: 0x41, count: 100_000)
        let encoded = StrippedDocument(parts: [.literal(payload)],
                                       basedOn: Data(repeating: 0, count: 32),
                                       originalSHA256: Data(repeating: 0, count: 32)).encoded()
        #expect(encoded.count < payload.count + 128, "overhead is a header, not a re-encoding")
    }
}

@Suite struct StrippedDocumentSpliceTests {

    /// Shaped like the real encoder's output: `.sortedKeys`, and base64 whose `/` is written `\/`.
    private func document(blobId: UUID, payload: String, tail: String = "tail") -> Data {
        Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }

    private var payload: String { String(repeating: "ab\\/cd", count: 2000) }

    /// THE property everything rests on: rebuilding produces the original bytes exactly.
    @Test func restoringReproducesTheOriginalByteForByte() throws {
        let id = UUID()
        let base = document(blobId: id, payload: payload)
        let updated = document(blobId: id, payload: payload, tail: "edited")

        let stripped = StrippedDocument.strip(document: updated, against: base,
                                              basedOn: Data(repeating: 1, count: 32),
                                              originalSHA256: Data(repeating: 2, count: 32))

        #expect(try stripped.restore(using: base) == updated)
    }

    /// …and it genuinely removed something, so the test above cannot pass on a no-op.
    @Test func theBlobIsGenuinelyOmitted() {
        let base = document(blobId: UUID(), payload: payload)
        let stripped = StrippedDocument.strip(document: base, against: base,
                                              basedOn: Data(repeating: 1, count: 32),
                                              originalSHA256: Data(repeating: 2, count: 32))

        #expect(stripped.parts.contains { if case .blob = $0 { return true } else { return false } })
        #expect(stripped.encoded().count < base.count / 2)
    }

    /// Provably inert where it should be: nothing shared means one literal part carrying the lot.
    @Test func aDocumentWithNothingInCommonStripsToOneLiteral() {
        let doc = document(blobId: UUID(), payload: payload)
        let stripped = StrippedDocument.strip(document: doc, against: Data(),
                                              basedOn: Data(repeating: 1, count: 32),
                                              originalSHA256: Data(repeating: 2, count: 32))

        #expect(stripped.parts.count == 1)
        if case .literal(let bytes) = stripped.parts[0] {
            #expect(bytes == doc)
        } else {
            Issue.record("expected a single literal part")
        }
    }

    /// A blob the holder does not have is NAMED, never guessed at.
    @Test func restoringWithoutTheBlobFails() {
        let base = document(blobId: UUID(), payload: payload)
        let stripped = StrippedDocument.strip(document: base, against: base,
                                              basedOn: Data(repeating: 1, count: 32),
                                              originalSHA256: Data(repeating: 2, count: 32))

        #expect(throws: StrippedDocumentError.self) { try stripped.restore(using: Data("{}".utf8)) }
    }

    /// A tiny blob is not worth two part boundaries and a UUID.
    @Test func aTinyBlobIsLeftInline() {
        let base = document(blobId: UUID(), payload: "AAAA")
        let stripped = StrippedDocument.strip(document: base, against: base,
                                              basedOn: Data(repeating: 1, count: 32),
                                              originalSHA256: Data(repeating: 2, count: 32))
        #expect(stripped.parts.count == 1)
    }

    /// The escaping rule itself, pinned: what lands in the document is the base64 with `/` written
    /// `\/`. Searching for the raw base64 finds nothing, which is what makes this look impossible.
    @Test func aBlobsRunInTheDocumentIsEscapedBase64() {
        let raw = "ab/cd/ef"
        #expect(DocumentBlobs.escaped(raw) == "ab\\/cd\\/ef")

        let id = UUID()
        let doc = document(blobId: id, payload: DocumentBlobs.escaped(String(repeating: "a/", count: 3000)))
        let runs = DocumentBlobs.escapedRuns(in: doc)
        let run = try? #require(runs[id]?[.data])
        #expect(run.map { doc.range(of: $0) != nil } == true, "the escaped run must be findable")
    }
}

@Suite struct StrippedDocumentRealDocumentTests {

    /// A document written by the APP's own `JSONEncoder`, carrying a real escaped base64 run — the
    /// one thing a fixture I hand-escaped myself cannot prove, since it could agree with a strip
    /// that is wrong in exactly the same way.
    ///
    /// CHECKED IN rather than read out of the app repo next door. That is what the first version
    /// did, and it failed in the container CI actually runs in, where only this package is mounted;
    /// with a silent skip it would instead have PASSED there, covering nothing.
    @Test func aRealDocumentRoundTripsExactly() throws {
        let url = try #require(Bundle.module.url(forResource: "RealDocument",
                                                 withExtension: "infsketch"))
        let doc = try Data(contentsOf: url)

        let stripped = StrippedDocument.strip(document: doc, against: doc,
                                              basedOn: Data(repeating: 1, count: 32),
                                              originalSHA256: Data(repeating: 2, count: 32))

        #expect(try stripped.restore(using: doc) == doc, "the rebuild is not byte-identical")
        #expect(stripped.encoded().count < doc.count, "nothing was omitted from a document with blobs")
        let saved = 100.0 - Double(stripped.encoded().count) / Double(doc.count) * 100.0
        print("real document: \(doc.count) B -> \(stripped.encoded().count) B "
              + "(\(String(format: "%.1f", saved))% smaller)")
    }

    /// The escaping rule, against that same real run: `JSONEncoder` writes `/` as `\/`, so a search
    /// for the RAW base64 finds nothing at all. That is what makes this look unworkable.
    @Test func theRealRunIsEscapedAndTheRawFormIsAbsent() throws {
        let url = try #require(Bundle.module.url(forResource: "RealDocument",
                                                 withExtension: "infsketch"))
        let doc = try Data(contentsOf: url)
        let runs = DocumentBlobs.escapedRuns(in: doc)
        let id = try #require(runs.keys.first)
        let escaped = try #require(runs[id]?[.data])

        #expect(doc.range(of: escaped) != nil, "the escaped run must be findable")
        let rawBase64 = String(decoding: escaped, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(doc.range(of: Data(rawBase64.utf8)) == nil,
                "the UNescaped base64 must be absent — searching for it is the trap")
    }
}
