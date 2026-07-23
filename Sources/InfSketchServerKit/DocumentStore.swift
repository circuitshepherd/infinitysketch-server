import Foundation

/// M2b: what the server knows about a document whose CONTENT it does not hold — persisted as a
/// per-document JSON sidecar under `metadata/`. Per-doc sidecars, not one shared index: an index
/// is a mutable hot spot concurrent writers can corrupt, whereas each sidecar write is atomic and
/// independent (mirroring how documents themselves are stored).
public struct DocMetadataEntry: Codable, Equatable, Sendable {
    public var name: String
    public var sizeBytes: Int
    public var modifiedAt: Date
    public var originDeviceId: String?
    public var thumbnail: Data?
    public init(name: String, sizeBytes: Int, modifiedAt: Date, originDeviceId: String?, thumbnail: Data?) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.originDeviceId = originDeviceId
        self.thumbnail = thumbnail
    }
}

public struct StoredDocInfo: Sendable, Equatable {
    public let docId: String
    public let name: String
    public let sizeBytes: Int
    public let modifiedAt: Date
    /// M2b: false = metadata-only (content lives on `originDeviceId`).
    public let hasContent: Bool
    public let originDeviceId: String?

    public init(docId: String, name: String, sizeBytes: Int, modifiedAt: Date,
                hasContent: Bool = true, originDeviceId: String? = nil) {
        self.docId = docId
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.hasContent = hasContent
        self.originDeviceId = originDeviceId
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
    /// M2b: persist/read a metadata-only entry (an advertisement). Independent of `save`/`load`,
    /// which remain content-only — `load` still throws `notFound` for a metadata-only doc.
    func saveMetadata(docId: String, _ entry: DocMetadataEntry) throws
    func loadMetadata(docId: String) throws -> DocMetadataEntry?
}

public struct DirectoryDocumentStore: DocumentStore {
    public static let fileExtension = "infsketch"
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func list() throws -> [StoredDocInfo] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        var infos: [StoredDocInfo] = urls
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url in
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                let id = url.deletingPathExtension().lastPathComponent
                return StoredDocInfo(
                    docId: id,
                    name: id,
                    sizeBytes: values.fileSize ?? 0,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    hasContent: true,
                    originDeviceId: nil)
            }

        // M2b: metadata-only entries — advertised docs whose bytes we do NOT hold. A sidecar for
        // a docId that HAS content is skipped here (content beats metadata) but deliberately left
        // on disk, so the metadata survives if the content is ever removed.
        let contentIds = Set(infos.map(\.docId))
        let sidecars = (try? fm.contentsOfDirectory(at: metadataDirectory,
                                                    includingPropertiesForKeys: nil)) ?? []
        for url in sidecars where url.pathExtension == "json" {
            let docId = url.deletingPathExtension().lastPathComponent
            guard !contentIds.contains(docId),
                  let entry = try? loadMetadata(docId: docId) else { continue }
            infos.append(StoredDocInfo(docId: docId, name: entry.name, sizeBytes: entry.sizeBytes,
                                       modifiedAt: entry.modifiedAt, hasContent: false,
                                       originDeviceId: entry.originDeviceId))
        }
        return infos
    }

    public func load(docId: String) throws -> Data {
        let url = try fileURL(for: docId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentStoreError.notFound
        }
        return try Data(contentsOf: url)
    }

    public func save(docId: String, bytes: Data) throws {
        try bytes.write(to: try fileURL(for: docId), options: .atomic)
    }

    public func exists(docId: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try fileURL(for: docId).path)
    }

    private var metadataDirectory: URL { directory.appendingPathComponent("metadata", isDirectory: true) }

    private func metadataURL(for docId: String) throws -> URL {
        // Reuse the same docId validation the content path uses (rejects "/", "\", "..").
        _ = try fileURL(for: docId)
        return metadataDirectory.appendingPathComponent(docId).appendingPathExtension("json")
    }

    public func saveMetadata(docId: String, _ entry: DocMetadataEntry) throws {
        let url = try metadataURL(for: docId)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
    }

    public func loadMetadata(docId: String) throws -> DocMetadataEntry? {
        let url = try metadataURL(for: docId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(DocMetadataEntry.self, from: data)
    }

    private func fileURL(for docId: String) throws -> URL {
        guard !docId.isEmpty,
              !docId.contains("/"), !docId.contains("\\"), !docId.contains("..")
        else { throw DocumentStoreError.invalidDocId }
        return directory.appendingPathComponent(docId).appendingPathExtension(Self.fileExtension)
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
