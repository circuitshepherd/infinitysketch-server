import Foundation
import Crypto
import InfSketchWire

/// Which of a device's holds a version is kept by.
///
/// `base` is the version the device's NOTE names — moved only by the device's own `baseSaved`
/// report (spec decision 2: a device releases a version only by reporting a newer one).
/// `pushed` and `delivered` are TRANSIT holds the server keeps on its own: the last version this
/// device pushed and the server accepted, and the last version sent to it (a subscribe snapshot or
/// a broadcast). Each is replaced only by a newer push/delivery to the same device. They exist so
/// the version a device is about to write into its note — or the version its file IS, after a
/// close push — is still here when the device asks for it, however long it was away.
public enum HoldSlot: String, Codable, Sendable, CaseIterable {
    case base, pushed, delivered
}

public struct DeviceHolds: Codable, Equatable, Sendable {
    public var base: String?
    public var pushed: String?
    public var delivered: String?
    public var lastSeen: Date

    public init(base: String? = nil, pushed: String? = nil, delivered: String? = nil, lastSeen: Date) {
        self.base = base
        self.pushed = pushed
        self.delivered = delivered
        self.lastSeen = lastSeen
    }

    subscript(slot: HoldSlot) -> String? {
        get {
            switch slot {
            case .base: return base
            case .pushed: return pushed
            case .delivered: return delivered
            }
        }
        set {
            switch slot {
            case .base: base = newValue
            case .pushed: pushed = newValue
            case .delivered: delivered = newValue
            }
        }
    }

    var hashes: [String] { [base, pushed, delivered].compactMap { $0 } }
}

public enum VersionStoreError: Error, Equatable {
    case invalidDocId
    case hashMismatch
}

/// The server's kept document versions (spec §1). One per server, beside the documents.
public protocol VersionStore: Sendable {
    /// Keep `bytes` as version `hash` of `docId` and make it the CURRENT version; it also becomes
    /// the newest of the recent versions. Throws when `hash` is not the SHA-256 of `bytes`.
    func record(docId: String, bytes: Data, hash: String) throws
    /// Keep `bytes` as the current version of a document that predates the store (or whose
    /// session just opened). A no-op when it already is the current version.
    func ensureCurrent(docId: String, bytes: Data, hash: String) throws
    func contains(docId: String, hash: String) -> Bool
    /// The version's bytes, rebuilt from its blobs and VERIFIED against `hash`; nil when it is not
    /// kept or cannot be rebuilt exactly (a missing blob is logged and makes the version unusable).
    func load(docId: String, hash: String) -> Data?
    /// Move one of a device's holds. `hash == nil` releases that slot. Returns false — and holds
    /// NOTHING in that slot — when the document has no versions at all or `hash` is not kept.
    @discardableResult
    func setHold(docId: String, deviceId: String, slot: HoldSlot, hash: String?, now: Date) -> Bool
    func holds(docId: String) -> [String: DeviceHolds]
    /// Forget every version and hold of a deleted document.
    func removeAll(docId: String)
    /// Every version hash currently kept for `docId`.
    func keptHashes(docId: String) -> Set<String>
}

public enum VersionDigest {
    public static func hex(of bytes: Data) -> String {
        VersionHash.hex(Data(SHA256.hash(data: bytes)))
    }
}
