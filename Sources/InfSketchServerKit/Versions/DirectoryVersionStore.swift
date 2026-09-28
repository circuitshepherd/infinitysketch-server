import Foundation
import InfSketchWire

/// `.versions/<docId>/<hash>` (a `StoredVersion`), `.versions/<docId>/holds.json` (a `VersionIndex`)
/// and `.blobs/<sha256>` (one escaped image run), all beside the documents.
///
/// One lock for the whole store. Every call is short file work, and the callers — one
/// `DocumentSession` actor per document plus the manager — run concurrently, so the lock is what
/// keeps a sweep from deleting a blob another document's record has just referenced.
public final class DirectoryVersionStore: VersionStore, @unchecked Sendable {
    public static let recentCount = 8
    public static let versionsDirectoryName = ".versions"
    public static let blobsDirectoryName = ".blobs"
    public static let holdsFileName = "holds.json"

    struct VersionIndex: Codable, Equatable {
        var current: String?
        /// Newest last, at most `recentCount`.
        var recent: [String] = []
        var devices: [String: DeviceHolds] = [:]
    }

    private let root: URL
    private let lock = NSLock()
    /// blob sha → how many kept version files reference it. Rebuilt from the manifests at init.
    private var blobRefs: [String: Int] = [:]

    public init(directory: URL) {
        root = directory
        lock.lock(); defer { lock.unlock() }
        rebuildBlobReferences()
    }

    private var versionsDir: URL { root.appendingPathComponent(Self.versionsDirectoryName, isDirectory: true) }
    private var blobsDir: URL { root.appendingPathComponent(Self.blobsDirectoryName, isDirectory: true) }

    private func docDir(_ docId: String) throws -> URL {
        guard !docId.isEmpty, !docId.contains("/"), !docId.contains("\\"), !docId.contains(".."),
              !docId.hasPrefix(".") else { throw VersionStoreError.invalidDocId }
        return versionsDir.appendingPathComponent(docId, isDirectory: true)
    }

    // MARK: - protocol

    public func record(docId: String, bytes: Data, hash: String) throws {
        guard VersionDigest.hex(of: bytes) == hash else { throw VersionStoreError.hashMismatch }
        lock.lock(); defer { lock.unlock() }
        let dir = try docDir(docId)
        var index = readIndex(dir) ?? VersionIndex()
        try writeVersionIfAbsent(dir: dir, bytes: bytes, hash: hash)
        index.current = hash
        index.recent.removeAll { $0 == hash }
        index.recent.append(hash)
        if index.recent.count > Self.recentCount { index.recent.removeFirst(index.recent.count - Self.recentCount) }
        try writeIndex(index, dir)
        sweep(dir: dir, index: index)
    }

    public func ensureCurrent(docId: String, bytes: Data, hash: String) throws {
        let dir = try docDir(docId)
        lock.lock()
        let index = readIndex(dir)
        let already = index?.current == hash && FileManager.default.fileExists(atPath: dir.appendingPathComponent(hash).path)
        lock.unlock()
        if !already { try record(docId: docId, bytes: bytes, hash: hash) }
    }

    public func contains(docId: String, hash: String) -> Bool {
        guard VersionHash.isWellFormed(hash), let dir = try? docDir(docId) else { return false }
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(hash).path)
    }

    public func load(docId: String, hash: String) -> Data? {
        guard VersionHash.isWellFormed(hash), let dir = try? docDir(docId) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let raw = try? Data(contentsOf: dir.appendingPathComponent(hash)) else { return nil }
        do {
            let version = try StoredVersion(encoded: raw)
            let rebuilt = try version.rebuild { sha in
                try? Data(contentsOf: self.blobsDir.appendingPathComponent(sha))
            }
            guard VersionDigest.hex(of: rebuilt) == hash else {
                ServerLog.error("version \(hash) of '\(docId)' rebuilt to other bytes — unusable")
                return nil
            }
            return rebuilt
        } catch {
            ServerLog.error("version \(hash) of '\(docId)' cannot be rebuilt (\(error)) — unusable")
            return nil
        }
    }

    // Task 1.3 fills in these four.
    @discardableResult
    public func setHold(docId: String, deviceId: String, slot: HoldSlot, hash: String?, now: Date) -> Bool { false }
    public func holds(docId: String) -> [String: DeviceHolds] { [:] }
    public func removeAll(docId: String) {}
    public func keptHashes(docId: String) -> Set<String> {
        guard let dir = try? docDir(docId) else { return [] }
        lock.lock(); defer { lock.unlock() }
        return readIndex(dir).map(kept) ?? []
    }

    #if DEBUG
    func blobReferenceCount(_ sha: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return blobRefs[sha] ?? 0
    }
    #endif

    // MARK: - internals (all called with the lock held)

    private func writeVersionIfAbsent(dir: URL, bytes: Data, hash: String) throws {
        let file = dir.appendingPathComponent(hash)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        let (version, blobs) = StoredVersion.make(from: bytes, digest: VersionHash.digest(hex: hash) ?? Data())
        // Blobs FIRST: a version file that exists must be rebuildable.
        for (sha, run) in blobs {
            let blobFile = blobsDir.appendingPathComponent(sha)
            if !FileManager.default.fileExists(atPath: blobFile.path) {
                try run.write(to: blobFile, options: .atomic)
            }
        }
        try version.encoded().write(to: file, options: .atomic)
        for sha in Set(version.manifest.values) { blobRefs[sha, default: 0] += 1 }
    }

    func readIndex(_ dir: URL) -> VersionIndex? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.holdsFileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VersionIndex.self, from: data)
    }

    func writeIndex(_ index: VersionIndex, _ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: dir.appendingPathComponent(Self.holdsFileName), options: .atomic)
    }

    /// What the retention policy keeps. Task 1.3 narrows this; until then everything recorded stays.
    func kept(_ index: VersionIndex) -> Set<String> {
        var keep = Set(index.recent)
        if let current = index.current { keep.insert(current) }
        for holds in index.devices.values { keep.formUnion(holds.hashes) }
        return keep
    }

    /// Delete every version file of `dir` the policy does not keep, and every blob no kept version
    /// references any more. After writes only — never on a timer.
    func sweep(dir: URL, index: VersionIndex) {
        let keep = kept(index)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where VersionHash.isWellFormed(name) && !keep.contains(name) {
            let file = dir.appendingPathComponent(name)
            if let raw = try? Data(contentsOf: file), let manifest = try? StoredVersion.manifest(ofEncoded: raw) {
                for sha in Set(manifest.values) { releaseBlob(sha) }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    func releaseBlob(_ sha: String) {
        let remaining = (blobRefs[sha] ?? 1) - 1
        if remaining > 0 {
            blobRefs[sha] = remaining
        } else {
            blobRefs.removeValue(forKey: sha)
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(sha))
        }
    }

    private func rebuildBlobReferences() {
        blobRefs = [:]
        let docs = (try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path)) ?? []
        for doc in docs {
            let dir = versionsDir.appendingPathComponent(doc, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where VersionHash.isWellFormed(name) {
                guard let raw = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let manifest = try? StoredVersion.manifest(ofEncoded: raw) else { continue }
                for sha in Set(manifest.values) { blobRefs[sha, default: 0] += 1 }
            }
        }
    }
}
