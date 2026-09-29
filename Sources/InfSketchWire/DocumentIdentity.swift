import Foundation

/// A document's IDENTITY (`documentId`, app format 4) read and rewritten at the byte level, shared
/// by the server and the app — the app mints ids for legacy files with it at launch.
///
/// **The rule (round 5, item 6): an id travels with a DOCUMENT, never with a copy of its bytes.**
/// A device adopts a merge base only when the base, the local document and the server's copy
/// carry the same `documentId` — so two different documents sharing an id defeat that check, and
/// a document whose id changes under a same-named copy turns every other device's next open into
/// a union. Server-side paths that build a document from bytes an agent handed over therefore:
///  - CREATE (`replace_doc` of a name that does not exist, `merge_docs into:`): mint a fresh id.
///    `replace_doc` bytes are routinely another document's raw read, and a `merge_docs` union
///    carries its target's id — either way the new document would share an id with an existing
///    one.
///  - REPLACE an existing document (`replace_doc` of a name that exists): carry the CURRENT
///    document's id. Replacing the content is an edit of that document; taking the id the
///    agent's bytes happen to carry would make every device holding a lineage of it refuse the
///    lineage and union the old content back in.
/// Both paths use `settingDocumentId`, so bytes with no `documentId` (a legacy document) GAIN one —
/// the store keys a document by its id, and the bytes must say the same.
///
/// **Byte-level, never decode and re-encode**: the same rule every server-side document edit
/// keeps — the document stays exactly the bytes it was except for the one value, the key order is
/// untouched (`aaa001_thumbnailData` stays first, which is what lets the thumbnail extension stop
/// after one key), and fields this server does not know survive. The thumbnail is KEPT: it
/// renders content, which an identity change does not touch.
public enum DocumentIdentity {

    /// The top-level `documentId` string of `bytes`, or nil (absent, not a string, not a JSON
    /// object).
    public static func documentId(of bytes: Data) -> String? {
        guard let range = valueRange(ofTopLevelKey: "documentId", in: bytes) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: [.fragmentsAllowed])) as? String
    }

    /// `bytes` with its top-level `documentId` value replaced by `newId`; `bytes` unchanged when
    /// the document carries no `documentId` string (legacy) or is not a JSON object.
    public static func replacingDocumentId(in bytes: Data, with newId: String) -> Data {
        guard let range = valueRange(ofTopLevelKey: "documentId", in: bytes),
              bytes[range.lowerBound] == UInt8(ascii: "\""),
              let encoded = try? JSONSerialization.data(withJSONObject: newId, options: [.fragmentsAllowed])
        else { return bytes }
        var out = Data(bytes[bytes.startIndex..<range.lowerBound])
        out.append(encoded)
        out.append(bytes[range.upperBound...])
        return out
    }

    /// `bytes` carrying `newId` as its top-level `documentId`: the existing value replaced, or — for
    /// a legacy document without one — a member INSERTED before the first top-level key that sorts
    /// after `documentId` (where the app's `.sortedKeys` encoder puts it), else before the closing
    /// brace. Byte-level for the reason above: nothing else in the document may change. Malformed
    /// bytes come back unchanged.
    public static func settingDocumentId(in bytes: Data, to newId: String) -> Data {
        if valueRange(ofTopLevelKey: "documentId", in: bytes) != nil {
            return replacingDocumentId(in: bytes, with: newId)
        }
        guard let (members, closingBrace) = topLevelMembers(in: bytes),
              let encodedId = try? JSONSerialization.data(withJSONObject: newId, options: [.fragmentsAllowed])
        else { return bytes }
        var member = Data(#""documentId":"#.utf8)
        member.append(encodedId)
        var out = Data()
        if let next = members.first(where: { $0.key > "documentId" }) {
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

    /// A fresh identity, in the app's format (`SketchDocData.newDocumentId`).
    public static func newId() -> String { UUID().uuidString }

    struct Member { let key: String; let keyStart: Data.Index }

    /// Every top-level member's key and where it starts, and the index of the closing brace; nil
    /// on anything malformed. Same walk as `valueRange`, keeping every member instead of one.
    static func topLevelMembers(in bytes: Data) -> (members: [Member], closingBrace: Data.Index)? {
        var i = bytes.startIndex
        let end = bytes.endIndex
        func skipSpace() { while i < end, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        skipSpace()
        guard i < end, bytes[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        var members: [Member] = []
        skipSpace()
        if i < end, bytes[i] == UInt8(ascii: "}") { return (members, i) }
        while true {
            skipSpace()
            guard i < end, bytes[i] == UInt8(ascii: "\""), let keyEnd = stringEnd(bytes, from: i) else { return nil }
            members.append(Member(key: String(decoding: bytes[(i + 1)..<(keyEnd - 1)], as: UTF8.self), keyStart: i))
            i = keyEnd
            skipSpace()
            guard i < end, bytes[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            skipSpace()
            guard let valueEnd = valueEnd(bytes, from: i) else { return nil }
            i = valueEnd
            skipSpace()
            guard i < end else { return nil }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { return (members, i) }
            return nil
        }
    }

    // MARK: - scanning

    /// The byte range of the VALUE of top-level `key`, found by walking the object's members and
    /// skipping every value whole — so a nested object that happens to hold the same key is never
    /// mistaken for it. nil on anything malformed.
    static func valueRange(ofTopLevelKey key: String, in bytes: Data) -> Range<Data.Index>? {
        var i = bytes.startIndex
        let end = bytes.endIndex
        func skipSpace() { while i < end, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        skipSpace()
        guard i < end, bytes[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        let wanted = Data(key.utf8)
        while true {
            skipSpace()
            guard i < end else { return nil }
            if bytes[i] == UInt8(ascii: "}") { return nil }
            guard bytes[i] == UInt8(ascii: "\""), let keyEnd = stringEnd(bytes, from: i) else { return nil }
            let rawKey = bytes[(i + 1)..<(keyEnd - 1)]   // between the quotes, escapes undecoded
            i = keyEnd
            skipSpace()
            guard i < end, bytes[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            skipSpace()
            guard let valueEnd = valueEnd(bytes, from: i) else { return nil }
            if rawKey.elementsEqual(wanted) { return i..<valueEnd }
            i = valueEnd
            skipSpace()
            guard i < end else { return nil }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            return nil   // `}` without the key, or garbage
        }
    }

    /// Index just past the closing quote of the string starting at `start`.
    private static func stringEnd(_ bytes: Data, from start: Data.Index) -> Data.Index? {
        var i = start + 1
        while i < bytes.endIndex {
            switch bytes[i] {
            case UInt8(ascii: "\\"): i += 2
            case UInt8(ascii: "\""): return i + 1
            default: i += 1
            }
        }
        return nil
    }

    /// Index just past the JSON value starting at `start`: a string, or an object/array tracked by
    /// depth (strings inside skipped whole), or a scalar running to the next delimiter.
    private static func valueEnd(_ bytes: Data, from start: Data.Index) -> Data.Index? {
        guard start < bytes.endIndex else { return nil }
        let first = bytes[start]
        if first == UInt8(ascii: "\"") { return stringEnd(bytes, from: start) }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            var depth = 0
            var i = start
            while i < bytes.endIndex {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    guard let next = stringEnd(bytes, from: i) else { return nil }
                    i = next
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        }
        var i = start
        while i < bytes.endIndex,
              ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) {
            i += 1
        }
        return i > start ? i : nil
    }
}
