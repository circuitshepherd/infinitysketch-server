import Foundation

public struct StoredDocInfo: Sendable, Equatable {
    public let docId: String
    public let name: String
    public let sizeBytes: Int
    public let modifiedAt: Date
    /// Whether `name` is a recorded label (false: no label, `name` is the id). Carried so a listing
    /// never asks the store per document again (`SessionManager.listedName`).
    public let labelled: Bool

    /// `labelled` defaults to "the name is not the id", right for every store that keeps no labels.
    public init(docId: String, name: String, sizeBytes: Int, modifiedAt: Date, labelled: Bool? = nil) {
        self.docId = docId
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.labelled = labelled ?? (name != docId)
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
    /// The spelling a stored document goes by when `docId` names it in any letter case, or nil
    /// when nothing is stored under it. What `SessionManager` canonicalises docIds to, so one
    /// document is one session however a caller spells it.
    func storedDocId(matching docId: String) -> String?
    /// Whether a document is stored under EXACTLY this spelling. A fast check for the common case
    /// (a caller passing an id it was given), cheaper than `list()` or `storedDocId(matching:)`.
    func storesExactly(docId: String) -> Bool
    /// A server-instance id that survives restarts, or nil when this store cannot keep one (the
    /// server then makes a random id per process). See `SessionManager.serverId`.
    func persistentServerId() -> String?
    /// The name a person sees for `docId` — a LABEL, not an identity: two documents may carry the
    /// same one. Nil when none is recorded (callers show the id).
    func name(of docId: String) -> String?
    /// Records `name` as `docId`'s label.
    func setName(_ name: String, for docId: String) throws
    /// Records `name` as the label of the document stored under EXACTLY `storedId` (a spelling the
    /// caller took from `list()`), with no lookup of the stored spelling.
    func setName(_ name: String, forStoredId storedId: String) throws
    /// Forgets `docId`'s label (a document deleted without stored bytes — `delete` drops the label
    /// of a stored one itself).
    func removeName(for docId: String)
}

extension DocumentStore {
    /// For stores with no case folding of their own (the test stores): a document exists under
    /// exactly the spelling asked for, or not at all.
    public func storedDocId(matching docId: String) -> String? {
        (try? exists(docId: docId)) == true ? docId : nil
    }

    public func storesExactly(docId: String) -> Bool { storedDocId(matching: docId) == docId }

    /// Stores with nowhere durable to keep it: a random id per server process.
    public func persistentServerId() -> String? { nil }

    /// Stores that keep no labels: every document is shown by its id.
    public func name(of docId: String) -> String? { nil }
    public func setName(_ name: String, for docId: String) throws {}
    public func setName(_ name: String, forStoredId storedId: String) throws {
        try setName(name, for: storedId)
    }
    public func removeName(for docId: String) {}
}

public struct DirectoryDocumentStore: DocumentStore {
    public static let fileExtension = "infsketch"
    private let directory: URL
    /// How long a deleted document stays recoverable in `.trash` before pruning removes it.
    /// 30 days, matching the iOS "Recently Deleted" window the app's own delete lands in — both
    /// sides of a delete answer "how long do I have to change my mind?" the same way. Injected so
    /// tests can pin the boundary instead of waiting a month.
    private let trashRetention: TimeInterval
    /// documentId → name (`.names.json`). A class instance, so this struct stays a value.
    private let labels: DocumentLabels
    /// How many times this store enumerated its directory (`list()`, `storedDocId(matching:)`) —
    /// what `ListingCostTests` counts, so a per-document lookup that lists the folder again (an
    /// O(N²) listing on the session actor) fails a test instead of a large library.
    let directoryListings = ListingCounter()

    public init(directory: URL, trashRetention: TimeInterval = 30 * 24 * 60 * 60) {
        self.directory = directory
        self.trashRetention = trashRetention
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        labels = DocumentLabels(directory: directory)
        // First, before anything reads the folder: a pre-identity (name-keyed) folder becomes
        // id-keyed, once. An empty folder just gets the marker.
        IdentityMigration.run(in: directory, labels: labels)
        // Sweep once here as well as after each delete, so a server that runs for weeks without
        // deleting anything still clears out what expired while it was up.
        pruneTrash()
        sweepAtomicWriteLeftovers()
    }

    /// A process killed during `save` leaves the `.atomic` write's temporary file behind —
    /// `<name>.sb-<hash>-<random>` beside the document on Darwin — and nothing ever removed one.
    /// At startup nothing of ours is writing, so any such file is an abandoned half-write. It can
    /// never surface as a document (`list()` filters on the extension); this only reclaims space.
    /// The file holding this documents directory's server id. A dot-file, and without the
    /// document extension, so `list()` can never report it as a document.
    public static let serverIdFileName = ".server-id"

    /// Read once per server start (`SessionManager.init`). Created on first use; a file that
    /// cannot be read or written degrades to nil — a random id for this run — rather than failing
    /// the server over bookkeeping.
    public func persistentServerId() -> String? {
        let url = directory.appendingPathComponent(Self.serverIdFileName)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        let id = UUID().uuidString
        do {
            try Data((id + "\n").utf8).write(to: url, options: .atomic)
            return id
        } catch {
            ServerLog.error("could not persist the server id at \(url.path): \(error)")
            return nil
        }
    }

    private func sweepAtomicWriteLeftovers() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.contains(".\(Self.fileExtension).sb-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public func list() throws -> [StoredDocInfo] {
        let fm = FileManager.default
        directoryListings.increment()
        let urls = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let labelled = labels.all()
        return urls
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url in
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                let id = url.deletingPathExtension().lastPathComponent
                let label = labelled[id]
                return StoredDocInfo(
                    docId: id,
                    name: label ?? id,
                    sizeBytes: values.fileSize ?? 0,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    labelled: label != nil)
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
        try bytes.write(to: try canonicalFileURL(for: docId), options: .atomic)
    }

    public func exists(docId: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try resolvedFileURL(for: docId).path)
    }

    /// Exact key first, then the labels' own keys folded — both in memory. The folder is listed
    /// only when two labelled ids differ just by case, where the stored spelling decides.
    public func name(of docId: String) -> String? {
        let all = labels.all()
        if let exact = all[docId] { return exact }
        let wanted = docId.lowercased()
        let folded = all.keys.filter { $0.lowercased() == wanted }
        switch folded.count {
        case 0: return nil
        case 1: return all[folded[0]]
        default: return all[storedDocId(matching: docId) ?? folded.min()!]
        }
    }

    /// An id already labelled under this exact spelling needs no listing (every rename of a
    /// labelled document); otherwise the stored spelling is looked up.
    public func setName(_ name: String, for docId: String) throws {
        if labels.name(of: docId) != nil { return try labels.set(name, for: docId) }
        try labels.set(name, for: storedDocId(matching: docId) ?? docId)
    }

    public func setName(_ name: String, forStoredId storedId: String) throws {
        try labels.set(name, for: storedId)
    }

    public func removeName(for docId: String) {
        let wanted = docId.lowercased()
        for key in labels.all().keys where key.lowercased() == wanted { labels.remove(key) }
    }

    /// `fileExists` alone is not enough: on a case-insensitive filesystem (APFS, NTFS) it finds
    /// `Chart.infsketch` for `chart`, and the spelling is what a session is keyed by. The directory's
    /// NAMES are compared instead — no attributes, no labels, unlike `list()`.
    public func storesExactly(docId: String) -> Bool {
        guard let url = try? fileURL(for: docId),
              FileManager.default.fileExists(atPath: url.path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return names.contains(url.lastPathComponent)
    }

    public func storedDocId(matching docId: String) -> String? {
        directoryListings.increment()
        // Names only — no attributes, no labels — unlike `list()`.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let suffix = ".\(Self.fileExtension)"
        let stored = names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }
        if stored.contains(docId) { return docId }
        let wanted = docId.lowercased()
        // `.min()`: two files differing only in case can exist on a case-sensitive filesystem, and
        // the same one must win every time (the rule `resolvedFileURL` follows).
        return stored.filter { $0.lowercased() == wanted }.min()
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
        // Resolved like `load` and `exists`: on a case-sensitive filesystem the exact spelling
        // missed a document every other call found, and the trashed copy must carry the name the
        // document was stored under, not the caller's spelling of it.
        _ = try fileURL(for: docId)   // validates
        let stem = storedDocId(matching: docId) ?? docId
        let url = try fileURL(for: stem)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentStoreError.notFound
        }
        let trashDir = directory.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let stamp = Self.trashStamp()
            let named = "\(Self.trashedStem(docId: stem, name: labels.name(of: stem)))__\(stamp)"
            do {
                try FileManager.default.moveItem(
                    at: url, to: trashDir.appendingPathComponent(named).appendingPathExtension(Self.fileExtension))
            } catch {
                // The readable name is the only part a file system can refuse (a length or
                // character rule we did not foresee): retry with the bare id before the outright
                // removal below — which destroys the document — is ever reached.
                try FileManager.default.moveItem(
                    at: url, to: trashDir.appendingPathComponent("\(stem)__\(stamp)").appendingPathExtension(Self.fileExtension))
            }
        } catch {
            try FileManager.default.removeItem(at: url)
        }
        labels.remove(stem)
        // Tidying, after the part the user actually asked for. Never allowed to fail the delete.
        pruneTrash()
    }

    /// The trashed file's name before its stamp: `<docId> (<name>)`, or the bare docId when the
    /// document has no label or is labelled by its own id. The label is dropped with the document,
    /// and a docId (a UUID) says nothing to a person looking for what they deleted — so the name
    /// travels in the file name, readable in any file browser. Characters no file system accepts
    /// become `_`, and a long name is cut to `trashNameByteLimit` bytes.
    /// The readable name's budget in UTF-8 BYTES. File-name limits are bytes (255 on ext4 and
    /// APFS), and a Character can be many of them: 100 emoji are 400 bytes, and a too-long name
    /// makes the move fail. 150 leaves room for a legacy id, ` ()`, the stamp and the extension.
    static let trashNameByteLimit = 150

    static func trashedStem(docId: String, name: String?) -> String {
        guard let name else { return docId }
        // Control characters (Cc) only — not `CharacterSet.controlCharacters`, which also holds the
        // format characters (Cf) such as the zero-width joiner inside every family emoji.
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var readable = String(String.UnicodeScalarView(name.unicodeScalars.map {
            forbidden.contains($0) || $0.properties.generalCategory == .control ? "_" : $0
        })).trimmingCharacters(in: .whitespaces)
        while readable.hasPrefix(".") { readable.removeFirst() }
        if readable.utf8.count > trashNameByteLimit {
            // Cut on a Character boundary: whole grapheme clusters only, never half an emoji.
            var cut = ""
            for character in readable {
                guard cut.utf8.count + String(character).utf8.count <= trashNameByteLimit else { break }
                cut.append(character)
            }
            readable = cut.trimmingCharacters(in: .whitespaces)
        }
        guard !readable.isEmpty, readable != docId else { return docId }
        return "\(docId) (\(readable))"
    }

    /// What a trashed file's basename says: the document's id, its name when the file carries one,
    /// and when it was deleted. Read from the RIGHT like `trashDate`: the stamp after the last
    /// `__`, then `<docId> (<name>)` split at the FIRST ` (` — a minted id (a UUID) never contains
    /// one, a name may. A LEGACY id (a pre-identity file name the migration left in place, e.g. one
    /// that could not carry an id) can: such an entry splits inside its id, and the name read back
    /// is wrong. Only the file name is affected — the document inside is whole.
    /// A file trashed before names were kept parses with `name` nil.
    static func trashedDocument(fromTrashedBasename basename: String)
        -> (docId: String, name: String?, deletedAt: Date)? {
        guard let separator = basename.range(of: "__", options: .backwards),
              let deletedAt = trashDate(fromTrashedBasename: basename) else { return nil }
        let head = String(basename[..<separator.lowerBound])
        if head.hasSuffix(")"), let open = head.range(of: " (") {
            let name = String(head[open.upperBound..<head.index(before: head.endIndex)])
            return (String(head[..<open.lowerBound]), name, deletedAt)
        }
        return (head, nil, deletedAt)
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
    /// A docId is now the document's `documentId` (a UUID the app mints), not the name a person
    /// sees — that is a label (`DocumentLabels`). Case folding stays: an agent may type a UUID in
    /// lower case, and a folder written before the identity migration may still hold a document
    /// the migration left under its old name.
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

    /// Where a SAVE must land: the spelling the document is ALREADY stored under.
    ///
    /// `resolvedFileURL`'s fast path above is correct for READING — on a case-insensitive
    /// filesystem `RAINFALL.infsketch` opens `Rainfall.infsketch` — but writing through the
    /// caller's spelling RENAMES the document, because an atomic write replaces the destination BY
    /// NAME. Measured on Windows/NTFS: saving `Rainfall` and then `RAINFALL` left ONE document
    /// called `RAINFALL`, where macOS and Linux both leave it called `Rainfall`.
    ///
    /// That is not cosmetic, which is why it is worth an enumeration. A docId IS this server's
    /// document identity — the document's `documentId`, which the file is named by, and what the
    /// mirror, the holder index and every agent tool key off — so a silent re-spelling leaves a
    /// device keyed on one spelling and a server holding another disagreeing about which document
    /// they are syncing, on one platform only.
    ///
    /// The cost is deliberately kept OFF the read path: a save writes the whole document, beside
    /// which one directory listing is noise, while `exists` — which runs on every byte-CAS — keeps
    /// its single `fileExists`.
    private func canonicalFileURL(for docId: String) throws -> URL {
        let stored = ((try? list()) ?? []).map(\.docId)
        // Already the stored spelling, or a document that does not exist yet: either way the
        // caller's own docId is the right name to write.
        guard !stored.contains(docId) else { return try fileURL(for: docId) }
        let wanted = docId.lowercased()
        // `.min()` for the same reason `resolvedFileURL` uses it: two files differing only by case
        // can exist on a case-sensitive filesystem, and the same one must win every time.
        guard let match = stored.filter({ $0.lowercased() == wanted }).min() else {
            return try fileURL(for: docId)
        }
        return try fileURL(for: match)
    }
}

public enum ThumbnailExtractor {
    private struct ThumbnailHeader: Decodable {
        let aaa001_thumbnailData: Data?
    }

    /// Reads the thumbnail PNG from .infsketch document bytes.
    /// Returns nil for documents without a thumbnail — absent or EMPTY, which is how the app and
    /// the server's own edits store "none" — or non-JSON bytes, so a caller falls through to its
    /// next source rather than serving a zero-byte image.
    public static func thumbnailPNG(fromDocumentBytes bytes: Data) -> Data? {
        guard let png = (try? JSONDecoder().decode(ThumbnailHeader.self, from: bytes))?.aaa001_thumbnailData,
              !png.isEmpty else { return nil }
        return png
    }
}


/// A thread-safe count (`DirectoryDocumentStore.directoryListings`).
final class ListingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
