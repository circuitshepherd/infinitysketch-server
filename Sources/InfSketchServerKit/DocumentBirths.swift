import Foundation

/// When each document was first stored here (`.created.json`: documentId → seconds since 1970).
///
/// The file system cannot say: every save is an atomic replace, so a document's file is as old as
/// its last write. An agent that keeps its sketches in dated folders needs the time a sketch was
/// CREATED, and had to take it out of the server's log (improvement note S9, 2026-11-22).
///
/// Recorded at the first save of an id that has no file yet, removed with the document. A
/// document this server held before it kept this record has no entry — an absent `createdAt` is
/// the honest answer, never a guess from a modification date.
///
/// `DocumentLabels`' shape: one small JSON file, read once, a lock for the writers.
final class DocumentBirths: @unchecked Sendable {
    static let fileName = ".created.json"
    private let url: URL
    private let lock = NSLock()
    private var cache: [String: Double]?

    init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    func all() -> [String: Date] {
        lock.lock(); defer { lock.unlock() }
        return loaded().mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Records `date` for a document that has no record yet; a later call changes nothing.
    func recordIfAbsent(_ docId: String, _ date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var births = loaded()
        guard births[docId] == nil else { return }
        births[docId] = date.timeIntervalSince1970
        persist(births)
    }

    func remove(_ docId: String) {
        lock.lock(); defer { lock.unlock() }
        var births = loaded()
        guard births.removeValue(forKey: docId) != nil else { return }
        persist(births)
    }

    private func loaded() -> [String: Double] {
        if let cache { return cache }
        // An unreadable file is treated as empty and replaced at the next record: these are
        // conveniences, and losing them must never stand in the way of a save.
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        cache = read
        return read
    }

    private func persist(_ births: [String: Double]) {
        cache = births
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { try encoder.encode(births).write(to: url, options: .atomic) } catch {
            ServerLog.error("could not write the documents' creation times at \(url.path): \(error)")
        }
    }
}
