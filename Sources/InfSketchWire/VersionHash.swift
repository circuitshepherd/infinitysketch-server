import Foundation

/// A document VERSION's name: the lowercase hex of the SHA-256 of the whole document bytes — the
/// digest the app's `.matchHash` compare-and-swap token already carries, spelled as text so it can
/// be a JSON field, a file name on the server and a key in the device's note.
///
/// Formatting only. This module computes no hash (it stays dependency-free, the rule
/// `WriteExpectation` and `StrippedDocument` follow); callers hash with what they have.
public enum VersionHash {
    public static func hex(_ digest: Data) -> String {
        var out = ""
        out.reserveCapacity(digest.count * 2)
        let alphabet = Array("0123456789abcdef")
        for byte in digest {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0F)])
        }
        return out
    }

    /// The 32-byte digest a well-formed version id spells, or nil.
    public static func digest(hex: String) -> Data? {
        guard isWellFormed(hex) else { return nil }
        var out = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Exactly 64 LOWERCASE hex digits. A version id becomes a file name on the server, so this is
    /// the check that keeps a device-supplied value from ever naming a path.
    public static func isWellFormed(_ hex: String) -> Bool {
        hex.utf8.count == 64 && hex.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
