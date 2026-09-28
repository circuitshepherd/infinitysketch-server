import Foundation

/// `.names.json` — documentId → the name a person sees. The id is the document's identity; the
/// name is a label, and two documents may carry the same one (spec §4).
///
/// If this file is lost, every document is labelled by its id until a device advertises it again
/// (an advertisement carries the name — `SessionManager.applyAdvertisements`). The documents
/// themselves do not carry their name, so there is nothing else to rebuild it from — which is why
/// a labels file that exists but cannot be read is SET ASIDE (`.names.unreadable-<stamp>.json`)
/// before anything is written over it, rather than silently replaced by the next `set`.
final class DocumentLabels: @unchecked Sendable {
    static let fileName = ".names.json"
    private let directory: URL
    private let url: URL
    private let lock = NSLock()
    private var cache: [String: String]?

    init(directory: URL) {
        self.directory = directory
        url = directory.appendingPathComponent(Self.fileName)
    }

    func all() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return loaded()
    }

    func name(of docId: String) -> String? { all()[docId] }

    func set(_ name: String, for docId: String) throws {
        lock.lock(); defer { lock.unlock() }
        var labels = loaded()
        guard labels[docId] != name else { return }
        labels[docId] = name
        try persist(labels)
    }

    func remove(_ docId: String) {
        lock.lock(); defer { lock.unlock() }
        var labels = loaded()
        guard labels.removeValue(forKey: docId) != nil else { return }
        do { try persist(labels) } catch {
            ServerLog.error("could not write the document names at \(url.path): \(error)")
        }
    }

    func replaceAll(_ labels: [String: String]) throws {
        lock.lock(); defer { lock.unlock() }
        _ = loaded()   // an unreadable file is set aside before it is replaced
        try persist(labels)
    }

    private func loaded() -> [String: String] {
        if let cache { return cache }
        let fm = FileManager.default
        var read: [String: String] = [:]
        if fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                read = decoded
            } else {
                setAsideUnreadableFile()
            }
        }
        cache = read
        return read
    }

    /// Moves an unreadable labels file out of the way so the next write cannot destroy it. If the
    /// move fails the error is logged and the names in it are lost at the next write — the
    /// documents themselves are never touched by this.
    private func setAsideUnreadableFile() {
        let stamp = DirectoryDocumentStore.trashStamp()
        let aside = directory.appendingPathComponent(".names.unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            ServerLog.error("document names at \(url.path) could not be read; kept as \(aside.lastPathComponent)")
        } catch {
            ServerLog.error("document names at \(url.path) could not be read nor set aside: \(error)")
        }
    }

    private func persist(_ labels: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(labels).write(to: url, options: .atomic)
        cache = labels
    }
}
