import Foundation
import Testing
import InfSketchWire

@Suite struct OpSpecBundleTests {

    @Test func roundTripsPrimaryAndParts() throws {
        let bundle = OpSpecBundle(
            primary: Data(repeating: 0x01, count: 4096),
            primaryKind: nil,
            parts: [.base: Data(repeating: 0x02, count: 128),
                    .theirs: Data(repeating: 0x03, count: 256)])
        let decoded = try OpSpecBundle(encoded: bundle.encoded())
        #expect(decoded == bundle)
    }

    /// The stripped-document kind travels WITH the primary, so the M4 blob omission that already
    /// applies to the document keeps working nested inside this wrapper.
    @Test func carriesThePrimarysOwnKind() throws {
        let bundle = OpSpecBundle(primary: Data([9, 9, 9]),
                                  primaryKind: BlobOmissionWire.strippedDocKind,
                                  parts: [.source: Data([1])])
        let decoded = try OpSpecBundle(encoded: bundle.encoded())
        #expect(decoded.primaryKind == BlobOmissionWire.strippedDocKind)
        #expect(decoded.primary == Data([9, 9, 9]))
    }

    @Test func emptyPartsRoundTrip() throws {
        let bundle = OpSpecBundle(primary: Data([1, 2, 3]), primaryKind: nil, parts: [:])
        #expect(try OpSpecBundle(encoded: bundle.encoded()) == bundle)
    }

    /// Byte-stable: every byte on this wire is compared for equality somewhere, and a dictionary's
    /// iteration order is not stable across processes.
    @Test func encodingIsDeterministic() throws {
        let parts: [OpSpecBundleWire.Field: Data] = [
            .base: Data([1]), .theirs: Data([2]), .source: Data([3]), .imageBytes: Data([4]),
        ]
        let first = OpSpecBundle(primary: Data([0]), primaryKind: nil, parts: parts).encoded()
        for _ in 0..<20 {
            #expect(OpSpecBundle(primary: Data([0]), primaryKind: nil, parts: parts).encoded() == first)
        }
    }

    @Test func refusesTruncatedInput() throws {
        let encoded = OpSpecBundle(primary: Data(repeating: 7, count: 64), primaryKind: nil,
                                   parts: [.base: Data(repeating: 8, count: 32)]).encoded()
        for cut in [1, 8, encoded.count - 1] {
            #expect(throws: (any Error).self) { try OpSpecBundle(encoded: encoded.prefix(cut)) }
        }
    }

    @Test func refusesAnUnknownVersion() throws {
        var encoded = OpSpecBundle(primary: Data([1]), primaryKind: nil, parts: [:]).encoded()
        encoded[0] = 99
        #expect(throws: OpSpecBundleError.unknownVersion(99)) { try OpSpecBundle(encoded: encoded) }
    }

    /// The spec that comes out is the spec every op handler already decodes — that equivalence is
    /// the whole reason no handler had to change.
    @Test func splicingRebuildsTheOriginalSpecExactly() throws {
        let base = Data(repeating: 0xAB, count: 501)
        let theirs = Data(repeating: 0xCD, count: 733)

        // What the server used to send, and what the device must end up with.
        let original = try JSONSerialization.data(withJSONObject: [
            "op": "revertMerge",
            "base": base.base64EncodedString(),
            "theirs": theirs.base64EncodedString(),
        ])
        // What it sends now: the same spec with the bulk fields lifted out.
        let lean = try JSONSerialization.data(withJSONObject: ["op": "revertMerge"])
        let bundle = OpSpecBundle(primary: Data(), primaryKind: nil,
                                  parts: [.base: base, .theirs: theirs])

        let restored = try bundle.specRestoringParts(into: lean)
        let a = try #require(try JSONSerialization.jsonObject(with: restored) as? [String: String])
        let b = try #require(try JSONSerialization.jsonObject(with: original) as? [String: String])
        #expect(a == b)
    }

    @Test func splicingLeavesASpecWithNoPartsUntouched() throws {
        let spec = try JSONSerialization.data(withJSONObject: ["op": "delete"])
        let bundle = OpSpecBundle(primary: Data(), primaryKind: nil, parts: [:])
        #expect(try bundle.specRestoringParts(into: spec) == spec)
    }
}
