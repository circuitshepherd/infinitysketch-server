import Foundation

/// Names shared by both repositories, so the two sides of the seam cannot drift.
///
/// **A drift here does not fail an op — it hands a handler bytes that are not what it thinks they
/// are**, which is why these live once, in the wire package, exactly like `BlobOmissionWire`.
public enum OpSpecBundleWire {
    /// `strokeOpRequest.payloadKind` when the payload is an `OpSpecBundle` rather than a document.
    public static let kind = "opBundle"
    /// The op-spec fields that are carried as bundle parts instead of base64 inside the spec.
    /// One list, read by the server when it builds a request and by the device when it rebuilds
    /// the spec — so a field added to one side and not the other is a compile-time edit here.
    public enum Field: String, Sendable, CaseIterable {
        /// `revertMerge` (undo_last_edit's contended path) — two whole documents.
        case base, theirs
        /// `mergeDocs` — the source document.
        case sourceBytes
        /// `copyElements` — the source document.
        case source
        /// `addImage` — the image file.
        case imageBytes
    }
}

public enum OpSpecBundleError: Error, Equatable {
    case truncated
    case unknownVersion(UInt8)
    case unknownField(String)
}

/// A request payload carrying the document AND the op-spec's bulk fields, so all of it rides the
/// chunked transfer.
///
/// **The bug this exists to prevent.** `TransferSender` chunks exactly one field — `bulkBytes`,
/// which for `strokeOpRequest` is `payload`. The `spec` beside it is never chunked, so four tools
/// that put whole documents in the spec (`revertMerge`, `mergeDocs`, `copyElements`, `addImage`)
/// emitted one text frame of up to 3.56x the document size. `URLSessionWebSocketTask` refuses any
/// message over 1 MiB and drops the connection rather than complaining, so `undo_last_edit` on any
/// document over ~288 KiB failed with `deviceTimeout` and no diagnosable cause at either end.
///
/// **`primary` is kept opaque and its own kind travels with it**, so this is a strict WRAPPER: the
/// blob-omission stripping that already applies to the document (M4) is unchanged and still
/// happens, nested inside. The device unwraps this, then resolves `primary` exactly as before.
///
/// The parts are spliced back into the spec as base64 on the device, restoring byte-for-byte the
/// spec every op handler already decodes — so no op handler, and no merge or authoring code,
/// learns that anything travelled differently.
public struct OpSpecBundle: Sendable, Equatable {
    /// The document payload, as `requestPayload` would have sent it on its own.
    public var primary: Data
    /// `nil` for a whole document, `BlobOmissionWire.strippedDocKind` for a stripped one.
    public var primaryKind: String?
    /// Spec fields lifted out of the spec, by name.
    public var parts: [OpSpecBundleWire.Field: Data]

    public init(primary: Data, primaryKind: String?, parts: [OpSpecBundleWire.Field: Data]) {
        self.primary = primary
        self.primaryKind = primaryKind
        self.parts = parts
    }

    private static let formatVersion: UInt8 = 1

    public func encoded() -> Data {
        var out = Data([Self.formatVersion])
        let kindBytes = Data((primaryKind ?? "").utf8)
        out.append(Self.uint32(UInt32(kindBytes.count)))
        out.append(kindBytes)
        out.append(Self.uint32(UInt32(primary.count)))
        out.append(primary)
        // Sorted, so the same bundle always encodes to the same bytes — a dictionary's order is
        // not stable, and every byte on this wire is somewhere compared for equality.
        let ordered = parts.sorted { $0.key.rawValue < $1.key.rawValue }
        out.append(Self.uint32(UInt32(ordered.count)))
        for (field, bytes) in ordered {
            let name = Data(field.rawValue.utf8)
            out.append(Self.uint32(UInt32(name.count)))
            out.append(name)
            out.append(Self.uint32(UInt32(bytes.count)))
            out.append(bytes)
        }
        return out
    }

    public init(encoded: Data) throws {
        var reader = Reader(encoded)
        let version = try reader.byte()
        guard version == Self.formatVersion else {
            throw OpSpecBundleError.unknownVersion(version)
        }
        let kindLength = Int(try reader.uint32())
        let kindRaw = String(decoding: try reader.take(kindLength), as: UTF8.self)
        primaryKind = kindRaw.isEmpty ? nil : kindRaw
        primary = try reader.take(Int(try reader.uint32()))
        let count = try reader.uint32()
        var parts: [OpSpecBundleWire.Field: Data] = [:]
        for _ in 0..<count {
            let nameLength = Int(try reader.uint32())
            let name = String(decoding: try reader.take(nameLength), as: UTF8.self)
            guard let field = OpSpecBundleWire.Field(rawValue: name) else {
                throw OpSpecBundleError.unknownField(name)
            }
            parts[field] = try reader.take(Int(try reader.uint32()))
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
            guard offset < bytes.count else { throw OpSpecBundleError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= bytes.count else {
                throw OpSpecBundleError.truncated
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

extension OpSpecBundle {
    /// Splice the parts back into `spec` as base64 strings, restoring exactly the spec the server
    /// would have sent before this indirection existed.
    ///
    /// Done as a JSON object edit rather than a decode into a typed spec, because the spec's shape
    /// differs per op and this layer must stay ignorant of all of them.
    public func specRestoringParts(into spec: Data) throws -> Data {
        guard !parts.isEmpty else { return spec }
        guard var object = try JSONSerialization.jsonObject(with: spec) as? [String: Any] else {
            return spec
        }
        for (field, bytes) in parts {
            object[field.rawValue] = bytes.base64EncodedString()
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
