import Foundation

public enum SnapshotBundleWire {
    /// `ServerMessage.subscribed.snapshotKind` when the snapshot payload is a `SnapshotBundle`.
    public static let kind = "snapshotWithBase"
}

/// A subscribe snapshot and the BASE version the device asked for, in the one bulk payload a
/// message may carry (`TransferSender` chunks exactly one field).
///
/// The base is cut against the snapshot — the one document the server knows the device will hold
/// byte-for-byte the moment it reads this — so an image unchanged between the two crosses the wire
/// once, and an image only the base has travels inline.
///
/// `ISSB` | UInt8 version 1 | UInt32 snapshot length | snapshot | UInt8 hash length | hash (UTF-8)
/// | UInt8 stripped | UInt32 base length | base.  Binary, never JSON, for `StrippedDocument`'s reason.
public struct SnapshotBundle: Sendable, Equatable {
    public var snapshot: Data
    public var baseHash: String
    public var base: Data
    public var baseIsStripped: Bool

    public init(snapshot: Data, baseHash: String, base: Data, baseIsStripped: Bool) {
        self.snapshot = snapshot
        self.baseHash = baseHash
        self.base = base
        self.baseIsStripped = baseIsStripped
    }

    public static func make(snapshot: Data, base: Data, baseHash: String,
                            snapshotDigest: Data, baseDigest: Data) -> SnapshotBundle {
        let stripped = StrippedDocument.strip(document: base, against: snapshot,
                                              basedOn: snapshotDigest, originalSHA256: baseDigest)
        let omitted = stripped.parts.contains { if case .blob = $0 { return true } else { return false } }
        return omitted
            ? SnapshotBundle(snapshot: snapshot, baseHash: baseHash, base: stripped.encoded(), baseIsStripped: true)
            : SnapshotBundle(snapshot: snapshot, baseHash: baseHash, base: base, baseIsStripped: false)
    }

    /// The base's bytes. UNVERIFIED — the caller checks them against `baseHash`, which is what keeps
    /// a bug here to "no base" rather than a wrong one.
    public func resolvedBase() throws -> Data {
        guard baseIsStripped else { return base }
        return try StrippedDocument(encoded: base).restore(using: snapshot)
    }

    private static let magic = Data("ISSB".utf8)

    public func encoded() -> Data {
        var out = Self.magic
        out.append(1)
        out.append(Self.uint32(snapshot.count)); out.append(snapshot)
        let hash = Data(baseHash.utf8)
        out.append(UInt8(truncatingIfNeeded: hash.count)); out.append(hash)
        out.append(baseIsStripped ? 1 : 0)
        out.append(Self.uint32(base.count)); out.append(base)
        return out
    }

    public init(encoded: Data) throws {
        let bytes = [UInt8](encoded)
        var offset = 0
        func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, offset + n <= bytes.count else { throw StrippedDocumentError.truncated }
            defer { offset += n }
            return Array(bytes[offset..<(offset + n)])
        }
        func uint32() throws -> Int {
            let b = try take(4)
            return Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        }
        guard try Data(take(4)) == Self.magic else { throw StrippedDocumentError.truncated }
        let version = try take(1)[0]
        guard version == 1 else { throw StrippedDocumentError.unknownVersion(version) }
        snapshot = Data(try take(try uint32()))
        let hashLength = Int(try take(1)[0])
        baseHash = String(decoding: try take(hashLength), as: UTF8.self)
        baseIsStripped = try take(1)[0] == 1
        base = Data(try take(try uint32()))
    }

    private static func uint32(_ value: Int) -> Data {
        let v = UInt32(value)
        return Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}
