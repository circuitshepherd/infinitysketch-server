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

    /// The same docIds `DocumentStore.fileURL` accepts (no separator, no `..`) — a document and its
    /// versions must be reachable by the same id — PLUS an explicit refusal of the bare "." that
    /// `DocumentStore`'s own character check lets through undetected (it never names anything real
    /// there, but here it would collide every document's version directory into one).
    private func docDir(_ docId: String) throws -> URL {
        guard !docId.isEmpty, docId != ".",
              !docId.contains("/"), !docId.contains("\\"), !docId.contains("..")
        else { throw VersionStoreError.invalidDocId }
        return versionsDir.appendingPathComponent(docId, isDirectory: true)
    }

    // MARK: - protocol

    public func record(docId: String, bytes: Data, hash: String) throws {
        guard VersionDigest.hex(of: bytes) == hash else { throw VersionStoreError.hashMismatch }
        lock.lock(); defer { lock.unlock() }
        let dir = try docDir(docId)
        var index = readIndex(dir) ?? VersionIndex()
        try writeOrRepairVersion(dir: dir, bytes: bytes, hash: hash, docId: docId)
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
        return loadLocked(dir: dir, hash: hash, docId: docId)
    }

    /// The body of `load`, callable while the lock is already held (from `record`'s self-repair) —
    /// `NSLock` is not reentrant, so `load` itself cannot be called re-entrantly here.
    private func loadLocked(dir: URL, hash: String, docId: String) -> Data? {
        guard let raw = try? Data(contentsOf: dir.appendingPathComponent(hash)) else { return nil }
        do {
            let version = try StoredVersion(encoded: raw)
            // A manifest is data on disk, not something the write path controls at read time —
            // never trust one of its values enough to hand it to the filesystem as a path component.
            for sha in version.manifest.values where !VersionHash.isWellFormed(sha) {
                ServerLog.error("version \(hash) of '\(docId)' names a malformed blob reference — unusable")
                return nil
            }
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

    @discardableResult
    public func setHold(docId: String, deviceId: String, slot: HoldSlot, hash: String?, now: Date) -> Bool {
        guard let dir = try? docDir(docId) else { return false }
        lock.lock(); defer { lock.unlock() }
        // A document the store has never seen: nothing to hold, and no directory is created for it
        // (a note written for a document the server deleted must not bring a folder back).
        guard var index = readIndex(dir) else { return false }
        let known = hash.map { VersionHash.isWellFormed($0)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) } ?? true
        var holds = index.devices[deviceId] ?? DeviceHolds(lastSeen: now)
        // An unknown version holds nothing — and the slot is still cleared: the device has moved on
        // from what it held there (for `base`, its note names something else now).
        holds[slot] = known ? hash : nil
        holds.lastSeen = now
        index.devices[deviceId] = holds
        guard (try? writeIndex(index, dir)) != nil else { return false }
        sweep(dir: dir, index: index)
        return known && hash != nil
    }

    public func holds(docId: String) -> [String: DeviceHolds] {
        guard let dir = try? docDir(docId) else { return [:] }
        lock.lock(); defer { lock.unlock() }
        return readIndex(dir)?.devices ?? [:]
    }

    public func removeAll(docId: String) {
        guard let dir = try? docDir(docId) else { return }
        lock.lock(); defer { lock.unlock() }
        // The index goes FIRST: a kill part-way then leaves version files no index names (removed at
        // the next start, Task 4.3), never an index naming files that are gone.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.holdsFileName))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where VersionHash.isWellFormed(name) {
            if let raw = try? Data(contentsOf: dir.appendingPathComponent(name)),
               let manifest = try? StoredVersion.manifest(ofEncoded: raw) {
                for sha in Set(manifest.values) { releaseBlob(sha) }
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

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

    /// Write `hash`'s version file and blobs if absent, or REPAIR them from `bytes` (already
    /// verified against `hash` by `record`) when the file exists but does not hold up: a blob gone
    /// missing (disk error, a stray delete) or the version file itself damaged by a crash mid-write.
    ///
    /// A manifest that parsed BEFORE this call was already counted into `blobRefs` — at the write
    /// that first produced it, or at the last startup scan — and rewriting it changes none of its
    /// shas, since the manifest is a pure function of `bytes`; only a manifest that did NOT parse
    /// before (absent file, or bytes too damaged to read at all) is counted here for the first time.
    private func writeOrRepairVersion(dir: URL, bytes: Data, hash: String, docId: String) throws {
        let file = dir.appendingPathComponent(hash)
        let existedBefore = FileManager.default.fileExists(atPath: file.path)
        let priorManifest = existedBefore
            ? (try? Data(contentsOf: file)).flatMap { try? StoredVersion.manifest(ofEncoded: $0) }
            : nil
        if existedBefore, priorManifest != nil, loadLocked(dir: dir, hash: hash, docId: docId) != nil {
            return  // present, parses, and rebuilds to exactly `hash` — nothing to repair
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        let (version, blobs) = StoredVersion.make(from: bytes, digest: VersionHash.digest(hex: hash) ?? Data())
        // Blobs FIRST: a version file that exists must be rebuildable. A brand-new version reuses an
        // already-correct, content-addressed blob as is; a REPAIR overwrites unconditionally, since
        // a damaged blob file under this same name is exactly what might need fixing.
        for (sha, run) in blobs {
            let blobFile = blobsDir.appendingPathComponent(sha)
            if existedBefore || !FileManager.default.fileExists(atPath: blobFile.path) {
                try run.write(to: blobFile, options: .atomic)
            }
        }
        try version.encoded().write(to: file, options: .atomic)
        if priorManifest == nil {
            for sha in Set(version.manifest.values) { blobRefs[sha, default: 0] += 1 }
        }
    }

    func readIndex(_ dir: URL) -> VersionIndex? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.holdsFileName)) else { return nil }
        let decoder = JSONDecoder()
        // `.secondsSince1970` round-trips a Date exactly, sub-second precision included — an ISO8601
        // string (the default formatter has no fractional-second option) truncates to the second,
        // silently rewriting `lastSeen` on every read.
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(VersionIndex.self, from: data)
    }

    func writeIndex(_ index: VersionIndex, _ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
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

    /// Never used as a path component before it is CHECKED — a manifest is data on disk, and a
    /// malformed "sha" in it (a stray `..`, or `""`, which `appendingPathComponent` treats as the
    /// directory itself) must be inert rather than a deletion of something it does not name.
    func releaseBlob(_ sha: String) {
        guard VersionHash.isWellFormed(sha) else { return }
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
                for sha in Set(manifest.values) where VersionHash.isWellFormed(sha) {
                    blobRefs[sha, default: 0] += 1
                }
            }
        }
        // Orphans: a blob written just before a crash whose version file never made it to disk (or
        // one abandoned by a version that became unparseable before it could be released properly).
        // Nothing can ever reference it again, so free the space at the next start.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: blobsDir.path)) ?? []
        where blobRefs[name] == nil {
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
        }
    }
}
