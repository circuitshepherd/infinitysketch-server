import Testing
import Foundation
import Crypto
@testable import InfSketchServerKit
@testable import InfSketchWire

/// What does ONE push of a large-image document cost on the `DocumentSession` actor?
///
/// Written to answer "sync feels laggy with two devices and an agent on a document with a big
/// image". Every step below runs SERIALIZED on one actor per document, so their sum is the floor
/// on how often that document can accept a write — and the app pushes on a leading edge, so at
/// Sync Interval = Immediate the pushes arrive as fast as they can be served. This is the number
/// the interval setting cannot change, which is why turning it down did not help.
///
/// It mirrors `submit` step for step, INCLUDING which values it now shares rather than recomputes:
/// one `BlobRunIndex` serving both the rebuild and the broadcast strip, and the two digests handed
/// to `broadcastDocument` instead of being taken again. Measured on this Mac, release:
///
///                    debug   release
///   before           198 ms   172 ms   two whole-document parses, four SHA-256s, String escapes
///   after             78 ms    70 ms   one parse, two SHA-256s, memchr escapes
///
/// Prints rather than asserts: these are timings of Foundation's JSON and CryptoKit on whatever
/// machine runs the suite, and a threshold on that is a flake generator.
///
/// **RUN IT BOTH WAYS.** `scripts/worktree-server` builds the dev server with a plain
/// `swift build`, and the app links `InfSketchWire` as a local package, so Debug is what actually
/// runs while anyone is developing. The gap was not the story before this work — 198 vs 172 ms,
/// because the cost sat inside Foundation either way — but it decided the escape: the candidate
/// that measured 5× faster in release measured 33× SLOWER in debug (see the comparison at the end,
/// and `DocumentBlobs.escapedBytes`).
struct BlobOmissionCostMeasurement {

    /// A document shaped like the real thing: one big base64 image blob plus a smaller
    /// "drawing" run that changes on every edit.
    private func document(imageBytes: Int, drawingBytes: Int, marker: String) -> Data {
        var image = Data(count: imageBytes)
        image.withUnsafeMutableBytes { raw in
            var seed: UInt64 = 0x2545F4914F6CDD1D
            for i in 0..<raw.count {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                raw[i] = UInt8(truncatingIfNeeded: seed)
            }
        }
        let drawing = Data((0..<drawingBytes).map { UInt8(65 + $0 % 26) })
        let doc: [String: Any] = [
            "aaa001_thumbnailData": drawing.base64EncodedString(),
            "drawingData": drawing.base64EncodedString(),
            "marker": marker,
            "pastedImagesData": [[
                "id": "6E1B0A1C-0000-4000-8000-000000000001",
                "data": image.base64EncodedString(),
                "thumbnailData": drawing.base64EncodedString(),
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    }

    /// Candidate B, kept so the comparison below still has the shape that LOST to run against —
    /// the one a future "simplification" would most naturally reach for.
    static func escapePerByte(_ base64: String) -> Data {
        let raw = Data(base64.utf8)
        return raw.withUnsafeBytes { source -> Data in
            var slashes = 0
            for i in 0..<source.count where source[i] == 0x2F { slashes += 1 }
            guard slashes > 0 else { return raw }
            return Data([UInt8](unsafeUninitializedCapacity: source.count + slashes) { out, count in
                var i = 0
                for j in 0..<source.count {
                    let byte = source[j]
                    if byte == 0x2F { out[i] = 0x5C; i += 1 }
                    out[i] = byte
                    i += 1
                }
                count = i
            })
        }
    }

    private func time(_ label: String, _ body: () -> Void) -> Double {
        let t0 = Date()
        body()
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "  %-44@ %8.1f ms", label as NSString, ms))
        return ms
    }

    @Test func measureWhatOneSubmitCostsOnTheSessionActor() {
        let previous = document(imageBytes: 4 * 1024 * 1024, drawingBytes: 300 * 1024, marker: "a")
        let current = document(imageBytes: 4 * 1024 * 1024, drawingBytes: 300 * 1024, marker: "b")
        print("\n=== one submit, \(current.count / 1024) KB document ===")

        let previousHash = Data(SHA256.hash(data: previous))
        let currentHash = Data(SHA256.hash(data: current))
        let payload = StrippedDocument.strip(document: current, against: previous,
                                             basedOn: previousHash,
                                             originalSHA256: currentHash).encoded()
        print("  the app's push payload is \(payload.count / 1024) KB\n")

        var total = 0.0
        total += time("SHA256 of the session's current bytes") { _ = Data(SHA256.hash(data: previous)) }
        total += time("StrippedDocument(encoded:) of the payload") { _ = try! StrippedDocument(encoded: payload) }

        // THE take that used to happen twice: once inside `restore(using:)` and once inside the
        // broadcast's `strip(against:)`, over the identical session bytes.
        var index = BlobRunIndex(of: Data())
        total += time("BlobRunIndex of the session's bytes (once)") { index = BlobRunIndex(of: previous) }

        let stripped = try! StrippedDocument(encoded: payload)
        total += time("restore(usingRuns:) — splice only") { _ = try! stripped.restore(usingRuns: index) }
        total += time("SHA256 verifying the rebuild") { _ = Data(SHA256.hash(data: current)) }
        total += time("broadcast strip(againstRuns:) — search + cut") {
            _ = StrippedDocument.strip(document: current, againstRuns: index,
                                       basedOn: previousHash, originalSHA256: currentHash)
        }
        let candidate = StrippedDocument.strip(document: current, againstRuns: index,
                                               basedOn: previousHash, originalSHA256: currentHash)
        total += time("encoded() of the broadcast payload") { _ = candidate.encoded() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DirectoryDocumentStore(directory: dir)
        total += time("store.save (atomic write of the document)") {
            try! store.save(docId: "Doc", bytes: current)
        }

        print(String(format: "\n  TOTAL on the session actor, per submit: %.1f ms", total))

        // Where the one remaining index take goes. The escape is no longer in it (see
        // `DocumentBlobs.escapedBytes`, which records why the obvious rewrites were slower); what
        // is left is the whole-document JSON parse, and the needle search `strip` does on top.
        print("\n  inside ONE BlobRunIndex, and the search on top of it:")
        var root: [String: Any] = [:]
        _ = time("JSONSerialization.jsonObject") {
            root = (try! JSONSerialization.jsonObject(with: current)) as! [String: Any]
        }
        let blob = (root["pastedImagesData"] as! [Any])[0] as! [String: Any]
        let base64 = blob["data"] as! String
        _ = time("escapedBytes (was replacingOccurrences)") { _ = DocumentBlobs.escapedBytes(base64) }
        let needle = DocumentBlobs.escapedBytes(base64)
        _ = time("Data.range(of: the blob run)") { _ = current.range(of: needle) }

        // Candidates for the escape, timed in WHATEVER configuration this suite is running in.
        // Run it both ways: `scripts/worktree-server` builds the dev server with a plain
        // `swift build`, and the app links InfSketchWire as a local package, so a Debug app build
        // compiles this code Debug too. A shape that wins in release and collapses in debug is
        // worse than one that is merely fine in both.
        print("\n  escape candidates (this build configuration):")
        _ = time("A: replacingOccurrences + Data(_.utf8)") {
            _ = Data(base64.replacingOccurrences(of: "/", with: "\\/").utf8)
        }
        _ = time("B: raw pointer, per-byte loop") { _ = Self.escapePerByte(base64) }
        _ = time("C: memchr + bulk appends (shipped)") { _ = DocumentBlobs.escapedBytes(base64) }
        #expect(Self.escapePerByte(base64) == DocumentBlobs.escapedBytes(base64),
                "the candidates must produce the same bytes, or this compares two different jobs")
        print("=== end ===\n")
    }
}
