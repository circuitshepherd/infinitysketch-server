import Foundation
import Testing
@testable import InfSketchWire

@Suite struct VersionHashTests {
    @Test func hexRoundTripsA32ByteDigest() throws {
        let digest = Data((0..<32).map { UInt8($0 * 7 & 0xFF) })
        let hex = VersionHash.hex(digest)
        #expect(hex.count == 64)
        #expect(hex == hex.lowercased())
        #expect(VersionHash.digest(hex: hex) == digest)
        #expect(VersionHash.isWellFormed(hex))
    }

    /// A version id arrives from a device and becomes a FILE NAME on the server: anything that is
    /// not exactly 64 lowercase hex characters must be refused, never used as a path.
    @Test(arguments: ["", "abc", String(repeating: "g", count: 64), "../" + String(repeating: "a", count: 61),
                      String(repeating: "A", count: 64)])
    func malformedHexIsRefused(_ text: String) {
        #expect(VersionHash.isWellFormed(text) == false)
    }

    @Test func anIndexCanBeBuiltFromBlobsHeldElsewhere() {
        let id = UUID()
        let run = Data("abc\\/def".utf8)
        let index = BlobRunIndex(runs: [id: [.data: run]])
        #expect(index.runs[id]?[.data] == run)
        #expect(index.isEmpty == false)
    }
}
