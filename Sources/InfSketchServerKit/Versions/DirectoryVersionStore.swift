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
        try record(docId: docId, bytes: bytes, hash: hash, sparing: [])
    }

    private func record(docId: String, bytes: Data, hash: String, sparing: Set<String>) throws {
        guard VersionDigest.hex(of: bytes) == hash else { throw VersionStoreError.hashMismatch }
        let dir = try docDir(docId)
        let prepared = prepare(dir: dir, bytes: bytes, hash: hash)
        lock.lock(); defer { lock.unlock() }
        // "No index yet" (a fresh document) and "an index exists but will not decode" must NOT be
        // treated alike: `?? VersionIndex()` on the second one silently drops every device's holds.
        // The protection this needs is NOT "skip the sweep on this one call" (a later call would
        // simply sweep against the fresh, holds-less index instead) — it is `sweep`'s own
        // quarantine check below, which holds for as long as the quarantined file sits in `dir`.
        var index: VersionIndex
        switch readIndexDistinguishingCorruption(dir) {
        case .absent:
            index = VersionIndex()
        case .corrupt:
            quarantineCorruptIndex(dir)
            index = VersionIndex()
        case .ok(let existing):
            index = existing
        }
        try writeOrRepairVersion(dir: dir, bytes: bytes, hash: hash, docId: docId, prepared: prepared)
        makeCurrent(&index, hash)
        try writeIndex(index, dir)
        sweep(dir: dir, index: index, sparing: sparing)
    }

    public func recordWrite(docId: String, bytes: Data, digest: Data, pusher: String?,
                            deliveredTo: Set<String>, now: Date) throws {
        guard digest.count == 32 else { throw VersionStoreError.malformedDigest }
        let hash = VersionHash.hex(digest)
        let dir = try docDir(docId)
        let prepared = prepare(dir: dir, bytes: bytes, hash: hash)
        lock.lock(); defer { lock.unlock() }
        var index: VersionIndex
        switch readIndexDistinguishingCorruption(dir) {
        case .absent: index = VersionIndex()
        case .corrupt:
            quarantineCorruptIndex(dir)
            index = VersionIndex()
        case .ok(let existing): index = existing
        }
        try writeOrRepairVersion(dir: dir, bytes: bytes, hash: hash, docId: docId, prepared: prepared)
        makeCurrent(&index, hash)
        // The version file was written just above, so every hold here names a KEPT version.
        if let pusher {
            var holds = index.devices[pusher] ?? DeviceHolds(lastSeen: now)
            holds.pushed = hash
            holds.lastSeen = now
            index.devices[pusher] = holds
        }
        for device in deliveredTo {
            var holds = index.devices[device] ?? DeviceHolds(lastSeen: now)
            holds.delivered = hash
            holds.lastSeen = now
            index.devices[device] = holds
        }
        try writeIndex(index, dir)
        sweep(dir: dir, index: index)
    }

    private func makeCurrent(_ index: inout VersionIndex, _ hash: String) {
        index.current = hash
        index.recent.removeAll { $0 == hash }
        index.recent.append(hash)
        if index.recent.count > Self.recentCount { index.recent.removeFirst(index.recent.count - Self.recentCount) }
    }

    /// The cutting (`StoredVersion.make` parses the whole document) done OUTSIDE the lock, which is
    /// store-wide: every document's writes wait on it. Skipped when the version file already exists
    /// — the common re-record — since then the locked path only has to confirm it; if that finds
    /// the file damaged it cuts the version itself. Checking existence without the lock is only an
    /// optimisation: either answer leads to a correct locked path.
    private func prepare(dir: URL, bytes: Data, hash: String) -> (version: StoredVersion, blobs: [String: Data])? {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(hash).path) { return nil }
        return StoredVersion.make(from: bytes, digest: VersionHash.digest(hex: hash) ?? Data())
    }

    public func ensureCurrent(docId: String, bytes: Data, hash: String, sparing: Set<String>) throws {
        let dir = try docDir(docId)
        lock.lock()
        let index = readIndex(dir)
        // Not just "does the file exist" — a `current` entry whose file exists but is damaged
        // (a blob gone missing, a partial write) must still be repaired, the same as any other
        // `record` would repair it; `loadLocked` is the one place that already knows how to tell.
        let alreadyCurrentAndHealthy = index?.current == hash && loadLocked(dir: dir, hash: hash, docId: docId) != nil
        lock.unlock()
        if !alreadyCurrentAndHealthy { try record(docId: docId, bytes: bytes, hash: hash, sparing: sparing) }
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
    public func setHold(docId: String, deviceId: String, slot: HoldSlot, hash: String?, now: Date,
                        sparing: Set<String>) -> Bool {
        guard let dir = try? docDir(docId) else { return false }
        lock.lock(); defer { lock.unlock() }
        var index: VersionIndex
        switch readIndexDistinguishingCorruption(dir) {
        case .absent:
            // A document the store has never seen: nothing to hold, and no directory is created for
            // it (a note written for a document the server deleted must not bring a folder back).
            return false
        case .corrupt:
            // The document DOES exist — its index just cannot be read. `setHold` may be the very
            // first call to see this (before any further `record`), so it quarantines and logs
            // exactly as `record` does, rather than silently answering as if nothing were held.
            quarantineCorruptIndex(dir)
            index = VersionIndex()
        case .ok(let existing):
            index = existing
        }
        let known = hash.map { VersionHash.isWellFormed($0)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) } ?? true
        var holds = index.devices[deviceId] ?? DeviceHolds(lastSeen: now)
        // An unknown version holds nothing — and the slot is still cleared: the device has moved on
        // from what it held there (for `base`, its note names something else now).
        holds[slot] = known ? hash : nil
        holds.lastSeen = now
        index.devices[deviceId] = holds
        guard (try? writeIndex(index, dir)) != nil else { return false }
        sweep(dir: dir, index: index, sparing: sparing)
        return known && hash != nil
    }

    public func holds(docId: String) -> [String: DeviceHolds] {
        guard let dir = try? docDir(docId) else { return [:] }
        lock.lock(); defer { lock.unlock() }
        switch readIndexDistinguishingCorruption(dir) {
        case .absent: return [:]
        case .corrupt:
            // A pure read still surfaces (and quarantines) a corruption nobody has reported yet,
            // for the same reason `setHold` does — silence here is indistinguishable from "nothing
            // is held".
            quarantineCorruptIndex(dir)
            return [:]
        case .ok(let index): return index.devices
        }
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
    /// missing (disk error, a stray delete), the version file itself damaged by a crash mid-write,
    /// or a manifest that still PARSES but has been tampered into naming the wrong shas.
    ///
    /// Ref-counting on repair: COUNT the correct (new) manifest's shas FIRST, then RELEASE whatever
    /// the prior manifest named, if it parsed — in that order, never the reverse. A blob referenced
    /// by both (the ordinary case: most of a version is untouched) is counted twice for a moment and
    /// then released once, never zero — releasing first would let a shared, still-needed blob hit
    /// zero and be deleted before the new manifest re-claims it. A prior manifest that did NOT parse
    /// (absent file, or bytes too damaged to read at all) names nothing to release, so its shas are
    /// simply counted as new — which OVER-counts by one if they were already counted at the write
    /// that (before being damaged) first produced this same version: that is a known, accepted
    /// residue of not being able to read what a corrupt file used to say, and the next process
    /// restart's `rebuildBlobReferences` scan corrects it back to exactly one count per referencing
    /// file, since it recomputes every count from what is actually on disk rather than accumulating.
    private func writeOrRepairVersion(dir: URL, bytes: Data, hash: String, docId: String,
                                      prepared: (version: StoredVersion, blobs: [String: Data])? = nil) throws {
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
        let (version, blobs) = prepared
            ?? StoredVersion.make(from: bytes, digest: VersionHash.digest(hex: hash) ?? Data())
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
        for sha in Set(version.manifest.values) { blobRefs[sha, default: 0] += 1 }
        if let prior = priorManifest {
            for sha in Set(prior.values) { releaseBlob(sha) }
        }
    }

    /// `nil` for BOTH "no index file" and "an index file that will not decode" — the ordinary read,
    /// used everywhere a caller only needs a good index or none. `record` needs the two told apart
    /// (see `readIndexDistinguishingCorruption`) and is the one caller that does not go through this.
    func readIndex(_ dir: URL) -> VersionIndex? {
        switch readIndexDistinguishingCorruption(dir) {
        case .absent, .corrupt: return nil
        case .ok(let index): return index
        }
    }

    enum IndexRead {
        case absent
        case corrupt
        case ok(VersionIndex)
    }

    /// Absent (a fresh document — a fresh index is the right, harmless answer) and corrupt (an
    /// index that EXISTS but cannot be decoded — silently substituting a fresh one here would throw
    /// away every device's holds) must not collapse into the same case; `record` is the one caller
    /// that acts on the difference.
    func readIndexDistinguishingCorruption(_ dir: URL) -> IndexRead {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.holdsFileName)) else { return .absent }
        let decoder = JSONDecoder()
        // `.deferredToDate` round-trips a `Date` exactly, sub-second precision included — measured:
        // `.secondsSince1970` (a Double near 1.8e9, most of its mantissa spent on the whole-second
        // part) lost sub-second precision on about half of random values, while `.deferredToDate`
        // (`timeIntervalSinceReferenceDate`, a smaller-magnitude Double, roughly 2001-epoch) did not
        // on any. `.iso8601`'s default formatter has no fractional-second option at all and would
        // truncate to the second on every write.
        decoder.dateDecodingStrategy = .deferredToDate
        guard let index = try? decoder.decode(VersionIndex.self, from: data) else { return .corrupt }
        return .ok(index)
    }

    /// `holds.json` exists but did not decode. Preserve the bytes under a new name and log it,
    /// rather than let the document proceed as if it had never had any holds at all — a decode
    /// failure must not be indistinguishable from "no device has ever reported in".
    private func quarantineCorruptIndex(_ dir: URL) {
        let file = dir.appendingPathComponent(Self.holdsFileName)
        let stamp = Int(Date().timeIntervalSince1970 * 1_000_000)
        let quarantined = dir.appendingPathComponent("\(Self.holdsFileName).corrupt-\(stamp)")
        if (try? FileManager.default.moveItem(at: file, to: quarantined)) != nil {
            ServerLog.error("'\(dir.lastPathComponent)': holds.json did not decode — preserved as " +
                             "\(quarantined.lastPathComponent) rather than treated as empty")
        } else {
            ServerLog.error("'\(dir.lastPathComponent)': holds.json did not decode and could not be " +
                             "moved aside")
        }
    }

    func writeIndex(_ index: VersionIndex, _ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: dir.appendingPathComponent(Self.holdsFileName), options: .atomic)
    }

    /// What the retention policy keeps: the CURRENT version, the last `recentCount` recorded, and
    /// every hash any device's holds still name — the union, computed fresh from `index` every time.
    func kept(_ index: VersionIndex) -> Set<String> {
        var keep = Set(index.recent)
        if let current = index.current { keep.insert(current) }
        for holds in index.devices.values { keep.formUnion(holds.hashes) }
        return keep
    }

    /// Delete every version file of `dir` the policy does not keep, and every blob no kept version
    /// references any more. After writes only — never on a timer.
    ///
    /// While ANY quarantined `holds.json.corrupt-*` file sits in `dir`, this does NOTHING — checked
    /// fresh on EVERY call, not only the one that discovered the corruption. The fresh index written
    /// right after quarantining has no memory of whatever the unreadable file was naming as held, so
    /// without this check the very next write (or `setHold`) would sweep against that empty memory
    /// and delete versions only the lost holds were keeping alive — exactly the failure the
    /// quarantine exists to prevent, and it must keep preventing it however many further writes
    /// follow. Lifting this is an explicit action (the quarantine file being removed — an operator,
    /// or a future "forget device"), never a matter of more time or more writes.
    ///
    /// A version file whose manifest does not even PARSE is still deleted here when retention is
    /// otherwise running (it cannot be kept — nothing names garbage as current, recent or held), but
    /// its blob references cannot be released: this sweep has no way to know what it referenced.
    /// Those blobs become ORPHANS — freed instead by the next process start's
    /// `rebuildBlobReferences` scan, which finds them referenced by nothing and deletes them then.
    ///
    /// `sparing` — versions THIS call must not delete although the policy no longer keeps them: a
    /// subscribe's own hold move spares the versions that same subscribe named as its base, so the
    /// move can never take away the version the device is about to merge against (a later write may
    /// still sweep it, once nothing holds it).
    func sweep(dir: URL, index: VersionIndex, sparing: Set<String> = []) {
        guard !hasQuarantinedIndex(dir) else { return }
        let keep = kept(index).union(sparing)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where VersionHash.isWellFormed(name) && !keep.contains(name) {
            let file = dir.appendingPathComponent(name)
            if let raw = try? Data(contentsOf: file), let manifest = try? StoredVersion.manifest(ofEncoded: raw) {
                for sha in Set(manifest.values) { releaseBlob(sha) }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Whether `dir` currently holds a quarantined index. Checked fresh from disk every time,
    /// never cached, so removing the file — the explicit act that lifts the protection — takes
    /// effect starting with the very next write, with nothing else to reset or forget.
    private func hasQuarantinedIndex(_ dir: URL) -> Bool {
        let prefix = "\(Self.holdsFileName).corrupt-"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .contains { $0.hasPrefix(prefix) }
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
        // Orphans: a blob written just before a crash whose version file never made it to disk, or
        // one a `sweep` deleted the referencing (unparseable) version file of without being able to
        // release (see `sweep`'s doc comment). Nothing can ever reference it again, so free the
        // space at the next start. Only a well-formed name is even a candidate — anything else in
        // `.blobs/` was never one of ours to begin with and is left alone.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: blobsDir.path)) ?? []
        where VersionHash.isWellFormed(name) && blobRefs[name] == nil {
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
        }
    }
}
