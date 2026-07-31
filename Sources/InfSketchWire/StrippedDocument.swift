import Foundation

/// Which of a pasted image's two byte fields a reference stands for.
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
                fields[field] = Data(escaped(base64).utf8)
            }
            if !fields.isEmpty { found[id] = fields }
        }
        return found
    }

    /// The one substitution `JSONEncoder` applies to a base64 string.
    static func escaped(_ base64: String) -> String {
        base64.replacingOccurrences(of: "/", with: "\\/")
    }
}

extension StrippedDocument {

    /// Cut `document` at every blob run that `base` also has.
    ///
    /// Pure, and it computes no digests — both are supplied, because this module may not depend on
    /// a hash implementation. `minimumRunBytes` keeps a thumbnail of a few hundred bytes from
    /// earning two part boundaries and a UUID to save less than it costs.
    public static func strip(document: Data, against base: Data,
                             basedOn: Data, originalSHA256: Data,
                             minimumRunBytes: Int = 4096) -> StrippedDocument {
        var candidates: [(run: Data, id: UUID, field: BlobField)] = []
        for (id, fields) in DocumentBlobs.escapedRuns(in: base) {
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
    public func restore(using holder: Data) throws -> Data {
        let available = DocumentBlobs.escapedRuns(in: holder)
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
