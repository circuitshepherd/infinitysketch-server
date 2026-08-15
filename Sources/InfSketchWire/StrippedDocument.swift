import Foundation

/// Which of a pasted image's two byte fields a reference stands for.
/// The two tokens both peers must agree on, held ONCE in the shared wire package so the seam
/// cannot drift: the payload-kind naming a `StrippedDocument`, and the failure reason a device
/// answers when it cannot rebuild a stripped REQUEST (the broker matches it by prefix and retries
/// the op whole). Each existed as two independent string literals — composed in the app, matched
/// on the server — and drift there does not fail an op, it WEDGES the document: every subsequent
/// request strips, is refused with an unrecognized reason, and errors until the connection dies
/// (review finding, 2026-08-03; the reshape_strokes seam class, one layer up from the envelope).
public enum BlobOmissionWire {
    public static let strippedDocKind = "strippedDoc"
    public static let cannotReconstructRequestReason = "cannotReconstructRequest"
}

public enum BlobField: String, Sendable, Equatable {
    case data, thumbnailData
}

/// One piece of a document: bytes carried verbatim, or a blob the receiver already has.
public enum DocumentPart: Sendable, Equatable {
    case literal(Data)
    case blob(id: UUID, field: BlobField)
}

public enum StrippedDocumentError: Error, Equatable {
    case truncated
    case unknownVersion(UInt8)
    case unknownPartKind(UInt8)
    case unknownField(UInt8)
    case missingBlob(id: UUID, field: BlobField)
}

/// A document with its already-known image blobs cut out, plus the two digests that make rebuilding
/// it verifiable: which document the omissions were taken from, and what the rebuild must produce.
///
/// **Encoded as a compact binary, never JSON.** The literal parts are raw document bytes — about a
/// third of a large sketch is `drawingData` — and base64-ing them into a JSON envelope would inflate
/// exactly the bytes this exists to save, by a third. `Transfer.swift` chunks an opaque `Data`, so
/// nothing below this layer notices the difference.
///
/// **No hashing happens here.** `InfSketchWire` is linked by the app and stays at zero
/// dependencies; it carries digests and never computes one, the same split `WriteExpectation`
/// established when `swift-crypto` went on `InfSketchServerKit` alone.
public struct StrippedDocument: Sendable, Equatable {
    public var parts: [DocumentPart]
    /// SHA-256 of the document the omissions were taken from. The receiver checks its own copy
    /// against this before trying, so a mismatch is named rather than discovered as garbage.
    public var basedOn: Data
    /// SHA-256 of the original. The receiver MUST check its rebuild against this.
    public var originalSHA256: Data

    public init(parts: [DocumentPart], basedOn: Data, originalSHA256: Data) {
        self.parts = parts
        self.basedOn = basedOn
        self.originalSHA256 = originalSHA256
    }

    private static let formatVersion: UInt8 = 1

    public func encoded() -> Data {
        var out = Data([Self.formatVersion])
        out.append(basedOn)
        out.append(originalSHA256)
        out.append(Self.uint32(UInt32(parts.count)))
        for part in parts {
            switch part {
            case .literal(let bytes):
                out.append(0)
                out.append(Self.uint32(UInt32(bytes.count)))
                out.append(bytes)
            case .blob(let id, let field):
                out.append(1)
                withUnsafeBytes(of: id.uuid) { out.append(contentsOf: $0) }
                out.append(field == .data ? 0 : 1)
            }
        }
        return out
    }

    public init(encoded: Data) throws {
        var reader = Reader(encoded)
        let version = try reader.byte()
        guard version == Self.formatVersion else {
            throw StrippedDocumentError.unknownVersion(version)
        }
        basedOn = try reader.take(32)
        originalSHA256 = try reader.take(32)
        let count = try reader.uint32()
        var parts: [DocumentPart] = []
        for _ in 0..<count {
            switch try reader.byte() {
            case 0:
                let length = Int(try reader.uint32())
                parts.append(.literal(try reader.take(length)))
            case 1:
                let raw = try reader.take(16)
                let uuid = raw.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
                switch try reader.byte() {
                case 0: parts.append(.blob(id: uuid, field: .data))
                case 1: parts.append(.blob(id: uuid, field: .thumbnailData))
                case let other: throw StrippedDocumentError.unknownField(other)
                }
            case let other:
                throw StrippedDocumentError.unknownPartKind(other)
            }
        }
        self.parts = parts
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw StrippedDocumentError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= bytes.count else {
                throw StrippedDocumentError.truncated
            }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
        mutating func uint32() throws -> UInt32 {
            let b = [UInt8](try take(4))
            return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        }
    }
}

/// The escaped blob runs of ONE encoded document — the expensive half of blob omission, computed
/// once and reusable.
///
/// **Why this is a type rather than a call.** Finding the runs means a whole-document
/// `JSONSerialization` parse plus an escape pass over every blob's base64: measured at ~62 ms on a
/// 6.7 MB document, and one server `submit` used to compute it TWICE over the identical bytes —
/// once inside `restore(using: bytes)` and again inside the broadcast's `strip(…, against:
/// previous)`, where `previous` IS those same bytes. A caller that holds a document (the server's
/// `DocumentSession`, the broker's per-connection ledger) keeps one of these beside it instead.
///
/// **It is only ever valid for the bytes it was taken from**, which is why there is no
/// `Data`-plus-index overload anywhere: the index is the whole parameter, so a caller cannot hand
/// over a mismatched pair. A stale one — a cache whose owner forgot to invalidate — is missing the
/// run and `restore` throws `missingBlob`, which every call site already treats as "ask for the
/// whole document". A bug here costs a resend, never a wrong document.
public struct BlobRunIndex: Sendable, Equatable {
    public let runs: [UUID: [BlobField: Data]]

    public init(of document: Data) {
        runs = DocumentBlobs.escapedRuns(in: document)
    }

    public var isEmpty: Bool { runs.isEmpty }
}

/// Finding a pasted image's bytes inside an encoded document, without decoding the document.
///
/// **A blob's base64 does not appear in the file, and that is the trap this type exists to step
/// over.** `JSONEncoder` escapes `/` as `\/`, and `/` is the only character of base64's alphabet
/// (`A–Za–z0–9+/=`) that Foundation escapes — so the form on disk is the base64 with that one
/// substitution. Searching for the unescaped string finds NOTHING, which reads as "the blob is not
/// in this document" and makes the whole idea look unworkable. Measured on a real document, each
/// escaped run occurs exactly once, so locating it by search is unambiguous.
public enum DocumentBlobs {

    /// The escaped runs for every pasted image in `bytes`, keyed by id and field.
    ///
    /// Parsing here is READ-ONLY and deliberate. Nothing in this file re-encodes, because the
    /// output of the whole subsystem has to be the original bytes — the compare-and-swap, the sync
    /// lineage and the merge base all compare bytes, not meaning.
    public static func escapedRuns(in bytes: Data) -> [UUID: [BlobField: Data]] {
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let blobs = root["pastedImagesData"] as? [Any] else { return [:] }
        var found: [UUID: [BlobField: Data]] = [:]
        for entry in blobs {
            guard let blob = entry as? [String: Any],
                  let rawId = blob["id"] as? String,
                  let id = UUID(uuidString: rawId) else { continue }
            var fields: [BlobField: Data] = [:]
            for field in [BlobField.data, BlobField.thumbnailData] {
                guard let base64 = blob[field.rawValue] as? String, !base64.isEmpty else { continue }
                fields[field] = escapedBytes(base64)
            }
            if !fields.isEmpty { found[id] = fields }
        }
        return found
    }

    /// The one substitution `JSONEncoder` applies to a base64 string.
    ///
    /// Kept as the DEFINITION of the rule — readable, and what the byte form below is checked
    /// against — but no longer on the hot path.
    static func escaped(_ base64: String) -> String {
        base64.replacingOccurrences(of: "/", with: "\\/")
    }

    /// The same substitution, as the bytes it produces.
    ///
    /// Base64 is ASCII, so a byte pass over the UTF-8 is exactly equivalent to the String form
    /// above — and much cheaper, because the base64 of a photograph is several megabytes and
    /// `replacingOccurrences` re-forms all of it as an intermediate String whose only consumer is
    /// `Data(_.utf8)`. `BlobEscapeTests` pins the two against each other.
    ///
    /// **Every part of the shape here was measured, and the obvious spellings LOST** (5.5 MB of
    /// base64, release, `BlobOmissionCostMeasurement`):
    ///
    ///   - `replacingOccurrences` + `Data(_.utf8)`      37.0 ms   ← what this replaced
    ///   - `String.withUTF8` + a byte loop              91.8 ms   ← the obvious rewrite, 2.5× WORSE
    ///   - `Data(_.utf8)` + `for b in data`             38.4 ms   ← no better than the original
    ///   - `Data(_.utf8)` + `withUnsafeBytes`            6.9 ms   ← this
    ///
    /// The bridge itself is free (`Data(base64.utf8)` is 0.3 ms). What costs is per-element
    /// iteration: `String.withUTF8` converts a CoreFoundation-bridged String into native storage,
    /// and `Data`'s own `Iterator` is slow enough to eat the entire saving. Only a raw-pointer pass
    /// avoids both — so do not "simplify" this into a `for byte in` loop.
    ///
    /// Counted first and filled into one exactly-sized buffer: appending would grow and copy a
    /// multi-megabyte array several times.
    static func escapedBytes(_ base64: String) -> Data {
        let raw = Data(base64.utf8)
        return raw.withUnsafeBytes { source -> Data in
            let slash = UInt8(ascii: "/")
            var slashes = 0
            for i in 0..<source.count where source[i] == slash { slashes += 1 }
            guard slashes > 0 else { return raw }
            return Data([UInt8](unsafeUninitializedCapacity: source.count + slashes) { out, count in
                var i = 0
                for j in 0..<source.count {
                    let byte = source[j]
                    if byte == slash {
                        out[i] = UInt8(ascii: "\\")
                        i += 1
                    }
                    out[i] = byte
                    i += 1
                }
                count = i
            })
        }
    }
}

extension StrippedDocument {

    /// Cut `document` at every blob run that `base` also has.
    ///
    /// Pure, and it computes no digests — both are supplied, because this module may not depend on
    /// a hash implementation. `minimumRunBytes` keeps a thumbnail of a few hundred bytes from
    /// earning two part boundaries and a UUID to save less than it costs.
    ///
    /// `base` is used for NOTHING but its blob runs; a caller that already holds a `BlobRunIndex`
    /// for it should pass that instead and skip the parse.
    public static func strip(document: Data, against base: Data,
                             basedOn: Data, originalSHA256: Data,
                             minimumRunBytes: Int = 4096) -> StrippedDocument {
        strip(document: document, againstRuns: BlobRunIndex(of: base),
              basedOn: basedOn, originalSHA256: originalSHA256, minimumRunBytes: minimumRunBytes)
    }

    /// As above, against blob runs the caller has already taken. See `BlobRunIndex` for why that
    /// is worth a second entry point, and for why a stale index costs a resend rather than a wrong
    /// document.
    public static func strip(document: Data, againstRuns baseRuns: BlobRunIndex,
                             basedOn: Data, originalSHA256: Data,
                             minimumRunBytes: Int = 4096) -> StrippedDocument {
        var candidates: [(run: Data, id: UUID, field: BlobField)] = []
        for (id, fields) in baseRuns.runs {
            for (field, run) in fields where run.count >= minimumRunBytes {
                candidates.append((run, id, field))
            }
        }
        // Longest first. Two runs can never partially overlap in valid JSON, but cutting the larger
        // one first keeps the search space small and makes the result independent of dictionary
        // ordering — which `escapedRuns` does not promise.
        candidates.sort { $0.run.count > $1.run.count }

        var parts: [DocumentPart] = [.literal(document)]
        for candidate in candidates {
            var next: [DocumentPart] = []
            for part in parts {
                guard case .literal(let bytes) = part,
                      let range = bytes.range(of: candidate.run) else {
                    next.append(part)
                    continue
                }
                if range.lowerBound > bytes.startIndex {
                    next.append(.literal(Data(bytes[bytes.startIndex..<range.lowerBound])))
                }
                next.append(.blob(id: candidate.id, field: candidate.field))
                if range.upperBound < bytes.endIndex {
                    next.append(.literal(Data(bytes[range.upperBound..<bytes.endIndex])))
                }
            }
            parts = next
        }
        return StrippedDocument(parts: parts, basedOn: basedOn, originalSHA256: originalSHA256)
    }

    /// Rebuild, taking each referenced blob from `holder`.
    ///
    /// The CALLER must then check the result against `originalSHA256`; this cannot, without a hash
    /// function it is not allowed to have. That check is what makes a bug here cost a resend
    /// instead of a wrong document.
    ///
    /// `holder` is used for NOTHING but its blob runs; a caller that already holds a
    /// `BlobRunIndex` for it should pass that instead and skip the parse.
    public func restore(using holder: Data) throws -> Data {
        try restore(usingRuns: BlobRunIndex(of: holder))
    }

    /// As above, from blob runs the caller has already taken.
    public func restore(usingRuns holder: BlobRunIndex) throws -> Data {
        let available = holder.runs
        var out = Data()
        for part in parts {
            switch part {
            case .literal(let bytes):
                out.append(bytes)
            case .blob(let id, let field):
                guard let run = available[id]?[field] else {
                    throw StrippedDocumentError.missingBlob(id: id, field: field)
                }
                out.append(run)
            }
        }
        return out
    }
}
