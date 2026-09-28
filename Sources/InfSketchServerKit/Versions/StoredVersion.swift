import Foundation
import InfSketchWire

/// One kept version on disk: the document with every image run of at least 4 KiB cut out, and a
/// manifest naming the blob file each cut run is.
///
/// `ISV1` | UInt32 big-endian manifest length | manifest JSON | `StrippedDocument.encoded()`
///
/// The cutting is `StrippedDocument`'s, reused rather than re-invented: the rebuild splices the
/// ORIGINAL bytes back, so a stored version is byte-identical by construction, and the caller still
/// verifies it against the version hash.
struct StoredVersion: Equatable {
    /// `"<UUID>/<field>"` → SHA-256 hex of the escaped run bytes (the blob's file name).
    var manifest: [String: String]
    var stripped: StrippedDocument

    static let magic = Data("ISV1".utf8)

    static func key(id: UUID, field: BlobField) -> String { "\(id.uuidString)/\(field.rawValue)" }

    static func make(from bytes: Data, digest: Data) -> (version: StoredVersion, blobs: [String: Data]) {
        let runs = BlobRunIndex(of: bytes)
        let stripped = StrippedDocument.strip(document: bytes, againstRuns: runs,
                                              basedOn: Data(repeating: 0, count: 32),
                                              originalSHA256: digest)
        var manifest: [String: String] = [:]
        var blobs: [String: Data] = [:]
        for part in stripped.parts {
            guard case .blob(let id, let field) = part, let run = runs.runs[id]?[field] else { continue }
            let sha = VersionDigest.hex(of: run)
            manifest[key(id: id, field: field)] = sha
            blobs[sha] = run
        }
        return (StoredVersion(manifest: manifest, stripped: stripped), blobs)
    }

    func encoded() -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        var out = Self.magic
        let length = UInt32(json.count)
        out.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF),
                                UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        out.append(json)
        out.append(stripped.encoded())
        return out
    }

    init(manifest: [String: String], stripped: StrippedDocument) {
        self.manifest = manifest
        self.stripped = stripped
    }

    init(encoded: Data) throws {
        let (manifest, rest) = try Self.split(encoded)
        self.manifest = manifest
        self.stripped = try StrippedDocument(encoded: rest)
    }

    /// The manifest alone — what the reference counting at startup reads.
    static func manifest(ofEncoded encoded: Data) throws -> [String: String] {
        try split(encoded).manifest
    }

    private static func split(_ encoded: Data) throws -> (manifest: [String: String], rest: Data) {
        let bytes = [UInt8](encoded)
        guard bytes.count >= 8, Data(bytes[0..<4]) == magic else { throw StrippedDocumentError.truncated }
        let length = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
        guard 8 + length <= bytes.count else { throw StrippedDocumentError.truncated }
        let json = Data(bytes[8..<(8 + length)])
        guard let manifest = try JSONSerialization.jsonObject(with: json) as? [String: String] else {
            throw StrippedDocumentError.truncated
        }
        return (manifest, Data(bytes[(8 + length)...]))
    }

    /// Rebuild the document, reading each blob through `blob`. Throws `missingBlob` when one is
    /// gone; the CALLER verifies the result against the version hash.
    func rebuild(blob: (String) -> Data?) throws -> Data {
        var runs: [UUID: [BlobField: Data]] = [:]
        for (key, sha) in manifest {
            let pieces = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let id = UUID(uuidString: pieces[0]),
                  let field = BlobField(rawValue: pieces[1]) else { continue }
            guard let run = blob(sha) else { throw StrippedDocumentError.missingBlob(id: id, field: field) }
            runs[id, default: [:]][field] = run
        }
        return try stripped.restore(usingRuns: BlobRunIndex(runs: runs))
    }
}
