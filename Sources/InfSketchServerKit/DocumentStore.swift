import Foundation

public struct StoredDocInfo: Sendable, Equatable {
    public let docId: String
    public let name: String
    public let sizeBytes: Int
    public let modifiedAt: Date

    public init(docId: String, name: String, sizeBytes: Int, modifiedAt: Date) {
        self.docId = docId
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public enum DocumentStoreError: Error, Equatable {
    case invalidDocId
    case notFound
}

public protocol DocumentStore: Sendable {
    func list() throws -> [StoredDocInfo]
    func load(docId: String) throws -> Data
    func save(docId: String, bytes: Data) throws
    /// Durable existence check — the source of truth for `WriteExpectation
    /// .absent` (Task 2): a `DocumentSession`'s in-memory `bytes` can't tell
    /// a fresh `createIfMissing` empty doc from a genuinely-empty saved one,
    /// and `seq` resets on session recycle, so neither can stand in for this.
    func exists(docId: String) throws -> Bool
    /// Remove the document. Throws `.notFound` if it is not there — deleting is a deliberate user
    /// action, so a caller asking to delete something absent is told, not silently succeeded.
    ///
    /// Nothing is retained afterwards: no tombstone, no record that the id ever existed. A device
    /// that still holds a copy may re-create it on its next push, which is accepted.
    func delete(docId: String) throws
}

public struct DirectoryDocumentStore: DocumentStore {
    public static let fileExtension = "infsketch"
    private let directory: URL
    /// How long a deleted document stays recoverable in `.trash` before pruning removes it.
    /// 30 days, matching the iOS "Recently Deleted" window the app's own delete lands in — both
    /// sides of a delete answer "how long do I have to change my mind?" the same way. Injected so
    /// tests can pin the boundary instead of waiting a month.
    private let trashRetention: TimeInterval

    public init(directory: URL, trashRetention: TimeInterval = 30 * 24 * 60 * 60) {
        self.directory = directory
        self.trashRetention = trashRetention
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Sweep once here as well as after each delete, so a server that runs for weeks without
        // deleting anything still clears out what expired while it was up.
        pruneTrash()
    }

    public func list() throws -> [StoredDocInfo] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        return urls
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url in
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                let id = url.deletingPathExtension().lastPathComponent
                return StoredDocInfo(
                    docId: id,
                    name: id,
                    sizeBytes: values.fileSize ?? 0,
                    modifiedAt: values.contentModificationDate ?? .distantPast)
            }
    }

    public func load(docId: String) throws -> Data {
        let url = try resolvedFileURL(for: docId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentStoreError.notFound
        }
        return try Data(contentsOf: url)
    }

    public func save(docId: String, bytes: Data) throws {
        try bytes.write(to: try resolvedFileURL(for: docId), options: .atomic)
    }

    public func exists(docId: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try resolvedFileURL(for: docId).path)
    }

    /// Name of the trash subdirectory. It has no `.infsketch` extension and `list()` enumerates
    /// non-recursively, so trashed documents can never appear in a listing.
    public static let trashDirectoryName = ".trash"

    /// Move the document into the trash rather than destroying it — the server-side counterpart of
    /// the app browser's Files trash, so a delete is recoverable on both sides. The document is
    /// gone from the store either way: `exists` is false and `load` throws afterwards.
    ///
    /// The trashed name carries a UTC stamp, so deleting successive documents of the same name
    /// keeps every one of them instead of the newest silently replacing the last.
    ///
    /// Falls back to an outright removal if the move fails — deleting must still work, and leaving
    /// the document in place would mean the caller's delete silently did nothing.
    public func delete(docId: String) throws {
        let url = try fileURL(for: docId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentStoreError.notFound
        }
        let trashDir = directory.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let stamped = "\(docId)__\(Self.trashStamp())"
            try FileManager.default.moveItem(
                at: url,
                to: trashDir.appendingPathComponent(stamped).appendingPathExtension(Self.fileExtension))
        } catch {
            try FileManager.default.removeItem(at: url)
        }
        // Tidying, after the part the user actually asked for. Never allowed to fail the delete.
        pruneTrash()
    }

    /// Remove trashed documents past `trashRetention`
    /// (spec 2026-07-27-server-trash-pruning-design.md). Best-effort throughout: every failure
    /// leaves the file in place, which is the safe direction for content someone may still want.
    private func pruneTrash(now: Date = Date()) {
        let trashDir = directory.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashDir.path) else { return }
        for name in names {
            // No parseable stamp -> KEEP. A hand-placed file, or a naming scheme older than this
            // code, is not something to delete on a guess.
            guard let trashedAt = Self.trashDate(fromTrashedBasename: (name as NSString).deletingPathExtension)
            else { continue }
            guard now.timeIntervalSince(trashedAt) > trashRetention else { continue }
            try? FileManager.default.removeItem(at: trashDir.appendingPathComponent(name))
        }
    }

    private static let trashStampFormat = "yyyy-MM-dd_HH-mm-ss-SSS"

    private static func trashStampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = trashStampFormat
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// Internal rather than private so tests can plant a trashed file of a chosen age.
    static func trashStamp(for date: Date = Date()) -> String {
        trashStampFormatter().string(from: date)
    }

    /// When a trashed file was deleted, read from the stamp `delete` wrote into its name.
    ///
    /// NOT the file's modification date: `moveItem` PRESERVES it, so a trashed file's mtime is
    /// when the document was last edited. A document written in spring and deleted today would
    /// look months old and be pruned on the spot.
    ///
    /// Splits on the LAST `__`, so a docId that itself contains `__` is dated from its stamp and
    /// not from part of its own name. Returns nil for anything that does not parse — the caller
    /// keeps those.
    static func trashDate(fromTrashedBasename basename: String) -> Date? {
        guard let separator = basename.range(of: "__", options: .backwards) else { return nil }
        return trashStampFormatter().date(from: String(basename[separator.upperBound...]))
    }

    private func fileURL(for docId: String) throws -> URL {
        guard !docId.isEmpty,
              !docId.contains("/"), !docId.contains("\\"), !docId.contains("..")
        else { throw DocumentStoreError.invalidDocId }
        return directory.appendingPathComponent(docId).appendingPathExtension(Self.fileExtension)
    }

    /// The file a docId names, matching an existing document's case when the exact name misses.
    ///
    /// WHY THIS EXISTS: a docId resolved straight to `<docId>.infsketch`, so lookup inherited the
    /// HOST FILESYSTEM's case rules. On macOS (APFS, case-insensitive by default) `RAINFALL` found
    /// `Rainfall`; on Linux it would not — so an agent's calls behaved differently on the
    /// development machine and on a deployment, and the same `save` created one file there and two
    /// here. This server is cross-platform on purpose, so the resolution is now the server's own
    /// and identical everywhere.
    ///
    /// Case-insensitive was chosen over exact-match because it is what macOS users already
    /// experience and what the app's own browser assumes (it dedupes documents by name stem, so
    /// "Chart" and "chart" were never really two documents).
    ///
    /// The scan only runs when the exact name MISSES, so the ordinary hit — every repeat call on a
    /// document, including the byte-CAS `exists` check on every write — still costs one
    /// `fileExists` and no directory enumeration.
    private func resolvedFileURL(for docId: String) throws -> URL {
        let exact = try fileURL(for: docId)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }

        let wanted = docId.lowercased()
        let match = ((try? list()) ?? [])
            .map(\.docId)
            .filter { $0.lowercased() == wanted }
            // Two files differing only in case can exist on a case-sensitive filesystem. Pick the
            // same one every time rather than whatever the directory happens to enumerate first.
            .min()
        guard let match else { return exact }
        return try fileURL(for: match)
    }
}

public enum ThumbnailExtractor {
    private struct ThumbnailHeader: Decodable {
        let aaa001_thumbnailData: Data?
    }

    /// Reads the thumbnail PNG from .infsketch document bytes.
    /// Returns nil for documents without a thumbnail or non-JSON bytes.
    public static func thumbnailPNG(fromDocumentBytes bytes: Data) -> Data? {
        (try? JSONDecoder().decode(ThumbnailHeader.self, from: bytes))?.aaa001_thumbnailData
    }
}
