import Foundation

/// One top-level BOOLEAN of a document, read and set at the byte level — the app turns
/// `syncEnabled` off in a CLOSED file when the server says its document was deleted.
///
/// Byte-level for `DocumentIdentity`'s reasons: every other byte stays what it was, the key order
/// is untouched (the thumbnail stays the first key), keys this build does not know survive, and a
/// file in a newer format — which the app refuses to decode — can still be taken off sync.
public enum DocumentFlag {

    /// The top-level boolean `key` of `bytes`; nil when absent, not a boolean, or `bytes` is not a
    /// JSON object.
    public static func value(of key: String, in bytes: Data) -> Bool? {
        guard let range = DocumentIdentity.valueRange(ofTopLevelKey: key, in: bytes) else { return nil }
        return literal(bytes[range])
    }

    /// `bytes` with the top-level boolean `key` set to `value`: the existing value replaced, or —
    /// for a document without the key — a member INSERTED before the first top-level key that
    /// sorts after it (where the app's `.sortedKeys` encoder puts it), else before the closing
    /// brace. The SAME bytes come back when the document already says `value`, when the key holds
    /// something that is not a boolean, and for anything malformed.
    public static func setting(_ key: String, to value: Bool, in bytes: Data) -> Data {
        let encoded = Data((value ? "true" : "false").utf8)
        if let range = DocumentIdentity.valueRange(ofTopLevelKey: key, in: bytes) {
            guard let current = literal(bytes[range]), current != value else { return bytes }
            var out = Data(bytes[bytes.startIndex..<range.lowerBound])
            out.append(encoded)
            out.append(bytes[range.upperBound...])
            return out
        }
        guard let (members, closingBrace) = DocumentIdentity.topLevelMembers(in: bytes),
              let encodedKey = try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed])
        else { return bytes }
        var member = encodedKey
        member.append(UInt8(ascii: ":"))
        member.append(encoded)
        var out = Data()
        if let next = members.first(where: { $0.key > key }) {
            out.append(bytes[bytes.startIndex..<next.keyStart])
            out.append(member)
            out.append(UInt8(ascii: ","))
            out.append(bytes[next.keyStart...])
        } else {
            out.append(bytes[bytes.startIndex..<closingBrace])
            if !members.isEmpty { out.append(UInt8(ascii: ",")) }
            out.append(member)
            out.append(bytes[closingBrace...])
        }
        return out
    }

    private static func literal(_ raw: Data) -> Bool? {
        if raw.elementsEqual("true".utf8) { return true }
        if raw.elementsEqual("false".utf8) { return false }
        return nil
    }
}
