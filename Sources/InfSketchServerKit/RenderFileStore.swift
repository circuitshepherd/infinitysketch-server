import Foundation

/// Where `render_sketch(writeToFile: true)` puts its PNGs.
///
/// WHY THE SERVER NAMES THE FILE. The obvious shape for this feature is an `outputPath` argument,
/// and it was rejected for one reason: nobody could clean up after it. An agent has no reason to
/// remember a file it wrote an hour ago, and a long session leaves dozens behind. A store can only
/// prune what it owns, so it owns the naming.
///
/// WHY A BYTE BUDGET RATHER THAN A RETENTION WINDOW. A render is scratch, not user data — nobody
/// comes back for last week's preview the way they come back for a deleted document, so the trash's
/// 30-day retention is the wrong shape. The telemetry file's cap is the right one: bound the bytes,
/// keep the RECENT past, and let age take care of itself.
public struct RenderFileStore: Sendable {
    /// A dot-directory beside the documents. `DirectoryDocumentStore.list()` enumerates
    /// non-recursively and filters on the `.infsketch` extension, so renders can never surface as
    /// documents — the same containment `.trash` relies on.
    public static let directoryName = ".renders"

    private let directory: URL
    private let byteBudget: Int

    /// - Parameter byteBudget: total bytes of PNG kept in the directory. 64 MB, matching the
    ///   telemetry file's cap — big enough to hold a working session's renders, small enough that a
    ///   forgotten server cannot fill a disk.
    public init(directory: URL, byteBudget: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.byteBudget = byteBudget
    }

    /// Writes `png` and returns its ABSOLUTE path — the agent hands that string to some other
    /// program, which knows nothing about the server's working directory. (`add_image` refuses a
    /// relative path for the same reason rather than resolving one against a directory the caller
    /// cannot see.)
    @discardableResult
    public func write(docId: String, png: Data, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory
            .appendingPathComponent(Self.basename(docId: docId, now: now))
            .appendingPathExtension("png")
        try png.write(to: url, options: .atomic)
        prune(keeping: url)
        return url.standardizedFileURL
    }

    /// `<docId>_<UTC stamp>_<token>`.
    ///
    /// The token is what the pre-merge backup names carry, and for the same reason: a stamp alone is
    /// not unique, and two renders inside one millisecond would silently overwrite each other.
    static func basename(docId: String, now: Date) -> String {
        "\(sanitized(docId))_\(stamp(for: now))_\(token())"
    }

    /// The docId reaching this store has already been through the document store's own rules, but
    /// this is a second place that builds a path out of it — so it does not get to be the door that
    /// lets `..` or a separator back in. Anything outside the allowed set becomes `-`.
    static func sanitized(_ docId: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = String(docId.map { allowed.contains($0) ? $0 : "-" })
        return mapped.isEmpty ? "render" : mapped
    }

    private static func token() -> String {
        String(format: "%04x", UInt16.random(in: .min ... .max))
    }

    // MARK: - Pruning

    /// Evict oldest-first until the directory is inside its budget.
    ///
    /// `keeping` is never evicted, even when it alone exceeds the whole budget: the caller asked for
    /// that render and a silently-absent file is worse than an over-budget directory. Same rule the
    /// mirror's `retainedBases` LRU follows — never evict the thing just written.
    ///
    /// Best-effort throughout, like the trash sweep: a failure leaves the file in place, which is
    /// the harmless direction for a scratch directory.
    private func prune(keeping: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return }

        let entries = urls
            .filter { $0.pathExtension == "png" }
            .map { url in
                (url: url,
                 size: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0,
                 date: Self.date(fromBasename: url.deletingPathExtension().lastPathComponent))
            }

        var total = entries.reduce(0) { $0 + $1.size }
        guard total > byteBudget else { return }

        // Oldest first. A name with no parseable stamp is not ours — it still counts toward the
        // budget (it occupies real disk) but is never deleted, the same safe direction the trash
        // sweep takes for a file it cannot date.
        let evictable = entries
            .filter { $0.date != nil && $0.url.standardizedFileURL != keeping.standardizedFileURL }
            .sorted { $0.date! < $1.date! }

        for entry in evictable {
            guard total > byteBudget else { break }
            guard (try? fm.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.size
        }
    }

    // MARK: - Stamps

    private static let stampFormat = "yyyy-MM-dd_HH-mm-ss-SSS"

    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = stampFormat
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    static func stamp(for date: Date) -> String {
        stampFormatter().string(from: date)
    }

    /// Reads the write time back out of `<docId>_<stamp>_<token>`.
    ///
    /// Parsed from the RIGHT, because a docId may itself contain `_` while the stamp is always
    /// exactly two `_`-separated components (`yyyy-MM-dd` and `HH-mm-ss-SSS`) and the token none.
    ///
    /// The name rather than the mtime, so ordering is exact rather than dependent on filesystem
    /// timestamp resolution — several renders can land inside one tick. (The trash reads its stamp
    /// from the name for a different reason: `moveItem` preserves mtimes, so a trashed file's mtime
    /// is when the document was last edited. Here the file really is created at write time; this is
    /// determinism, not correctness.)
    static func date(fromBasename basename: String) -> Date? {
        let parts = basename.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return stampFormatter().date(from: "\(parts[parts.count - 3])_\(parts[parts.count - 2])")
    }
}
