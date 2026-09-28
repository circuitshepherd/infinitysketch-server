import Foundation
import InfSketchWire

/// The one-time move of a pre-identity documents folder — `<name>.infsketch` — to documents keyed
/// by `documentId` (spec §4, "Migration"). Runs at store init, before anything reads the folder;
/// writes `.identity-v1` when done, so it runs once. An EMPTY folder gets the marker at once, which
/// is what keeps a store created fresh (every test, a new server) from ever migrating the ids it
/// later saves.
///
/// **It runs once on real users' folders, so its one rule is: never lose or overwrite a document.**
///  - Crash-safe by ordering: a minted id is written into the OLD file first, then
///    `<id>.infsketch`, then the label, and only then is the old file removed — so a run killed
///    anywhere finds the same id again next time and finishes the same document.
///  - An existing `<id>.infsketch` is taken for this document's finished target ONLY when its bytes
///    are exactly this file's AND no label names it as some other file. Anything else there is
///    another document, and this one gets a fresh id instead — an existing file is never written.
///  - The old file is removed only after the target has been read back byte-identical and the label
///    is on disk, and never when the two names reach the same file (a case-insensitive disk).
///  - A file the migration cannot give an id to (not a JSON object, a `documentId` that is not a
///    string) is LEFT WHERE IT IS: it stays a document under its old name.
///  - The marker is written only when every file left behind was left for a PERMANENT reason (it
///    cannot carry an id). A write or read that failed (a full disk, a file that would not read)
///    leaves the marker unwritten, so the next start tries that document again — with the marker
///    written it would stay under its old name for good.
///  - Only top-level, non-hidden `<stem>.infsketch` files are considered: the trash, `.server-id`,
///    the labels file and atomic-write leftovers are not documents and are not touched.
enum IdentityMigration {
    static let markerName = ".identity-v1"
    static let fileExtension = DirectoryDocumentStore.fileExtension

    private struct Candidate {
        let stem: String
        let url: URL
        var bytes: Data
        let modified: Date
        let id: String?
        /// Already in the id layout: named by the id it carries (letter case aside — on a
        /// case-insensitive disk `x-id.infsketch` IS the file `X-ID.infsketch`).
        var isIdNamed: Bool { id.map { $0.lowercased() == stem.lowercased() } ?? false }
    }

    /// `write` is every file write the migration makes (the old file, the target, the marker) —
    /// injectable so a test can make one fail the way a full disk does.
    static func run(in directory: URL, labels: DocumentLabels,
                    write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        let fm = FileManager.default
        // Set when a document was left behind for a reason that may pass (see the type's comment).
        var retryNeeded = false
        let marker = directory.appendingPathComponent(markerName)
        guard !fm.fileExists(atPath: marker.path) else { return }

        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates: [Candidate] = names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard url.pathExtension == fileExtension, !name.hasPrefix(".") else { return nil }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                ServerLog.error("identity migration: left \(name) in place (not a file)")
                return nil
            }
            guard let bytes = try? Data(contentsOf: url) else {
                ServerLog.error("identity migration: left \(name) in place (could not be read), will retry")
                retryNeeded = true
                return nil
            }
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            return Candidate(stem: url.deletingPathExtension().lastPathComponent, url: url, bytes: bytes,
                             modified: modified, id: DocumentIdentity.documentId(of: bytes))
        }
        // Already-id-named files (a half-finished earlier run, or a document saved in the id layout)
        // wait until every old-named file has claimed its id; one nobody claims is its own document.
        let idNamed = candidates.filter(\.isIdNamed)
        // Oldest first: when two files carry one id (a Files-style copy), the older keeps it.
        let oldNamed = candidates.filter { !$0.isIdNamed }
            .sorted { ($0.modified, $0.stem) < ($1.modified, $1.stem) }

        var labelled = labels.all()
        var claimed = Set(labelled.keys.map { $0.lowercased() })
        for var candidate in oldNamed {
            var id = candidate.id
            if let existing = id, isUsableFileStem(existing),
               let target = existingFile(named: existing, in: directory) {
                // Something is already stored under this id. It is this very document only when
                // it holds exactly these bytes and no label says it belongs to another file.
                let targetLabel = labelled[target.deletingPathExtension().lastPathComponent]
                let sameDocument = (try? Data(contentsOf: target)) == candidate.bytes
                    && (targetLabel == nil || targetLabel == candidate.stem)
                    && !isSameFile(target, candidate.url)
                if !sameDocument { id = nil }
            } else if let existing = id, claimed.contains(existing.lowercased()) {
                id = nil
            }
            if id == nil || !isUsableFileStem(id!) {
                // Minted and written into the OLD file first, so a run killed from here on finds
                // this same id again. Bytes that cannot carry one are left where they are.
                let fresh = DocumentIdentity.newId()
                let rewritten = DocumentIdentity.settingDocumentId(in: candidate.bytes, to: fresh)
                guard DocumentIdentity.documentId(of: rewritten) == fresh else {
                    ServerLog.error("identity migration: left \(candidate.url.lastPathComponent) in place (cannot carry a documentId)")
                    continue
                }
                do { try write(rewritten, candidate.url) } catch {
                    ServerLog.error("identity migration: left \(candidate.url.lastPathComponent) in place, will retry: \(error)")
                    retryNeeded = true
                    continue
                }
                candidate.bytes = rewritten
                id = fresh
            }
            guard let id else { continue }
            let target: URL
            if let existing = existingFile(named: id, in: directory) {
                target = existing   // checked above: this document's own finished target
            } else {
                target = directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
                do { try write(candidate.bytes, target) } catch {
                    ServerLog.error("identity migration: left \(candidate.url.lastPathComponent) in place, will retry: \(error)")
                    retryNeeded = true
                    continue
                }
            }
            // The old file goes only once its content is verifiably stored under the id.
            guard (try? Data(contentsOf: target)) == candidate.bytes else {
                ServerLog.error("identity migration: left \(candidate.url.lastPathComponent) in place (\(target.lastPathComponent) does not read back), will retry")
                retryNeeded = true
                continue
            }
            let storedId = target.deletingPathExtension().lastPathComponent
            labelled[storedId] = candidate.stem
            claimed.insert(storedId.lowercased())
            // Without the label on disk the old file is the only record of the name: stop, and let
            // the next start retry (no marker written).
            do { try labels.replaceAll(labelled) } catch {
                ServerLog.error("identity migration: could not write the document names, will retry: \(error)")
                return
            }
            guard !isSameFile(target, candidate.url) else { continue }
            try? fm.removeItem(at: candidate.url)
        }
        for file in idNamed where fm.fileExists(atPath: file.url.path) && labelled[file.stem] == nil {
            labelled[file.stem] = file.stem
        }
        do { try labels.replaceAll(labelled) } catch {
            ServerLog.error("identity migration: could not write the document names, will retry: \(error)")
            return
        }
        guard !retryNeeded else { return }
        do { try write(Data(), marker) } catch {
            ServerLog.error("identity migration: could not write \(markerName), will run again: \(error)")
        }
    }

    /// The file stored under `id`, in whatever letter case the disk has it — exact spelling first.
    private static func existingFile(named id: String, in directory: URL) -> URL? {
        let exact = directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let wanted = "\(id).\(fileExtension)"
        if names.contains(wanted) { return exact }
        if let match = names.filter({ $0.lowercased() == wanted.lowercased() }).min() {
            return directory.appendingPathComponent(match)
        }
        // A disk that normalises names differently from how they enumerate still answers here.
        return FileManager.default.fileExists(atPath: exact.path) ? exact : nil
    }

    /// Whether two paths reach one file. Compared by file number where the platform reports one,
    /// else by the name folded the way a case-insensitive disk folds it — erring towards "same",
    /// which only ever keeps a file that could have been removed.
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        if let aa = try? fm.attributesOfItem(atPath: a.path), let bb = try? fm.attributesOfItem(atPath: b.path),
           let an = aa[.systemFileNumber] as? NSNumber, let bn = bb[.systemFileNumber] as? NSNumber,
           let ad = aa[.systemNumber] as? NSNumber, let bd = bb[.systemNumber] as? NSNumber,
           an.uint64Value != 0 {
            return an == bn && ad == bd
        }
        func folded(_ url: URL) -> String {
            url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        }
        return folded(a) == folded(b)
    }

    private static func isUsableFileStem(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 200, !id.hasPrefix("."), !id.contains("..") else { return false }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        return id.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }
}
