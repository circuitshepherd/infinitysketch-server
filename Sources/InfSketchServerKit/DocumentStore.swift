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

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    public func delete(docId: String) throws {
        let url = try fileURL(for: docId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentStoreError.notFound
        }
        try FileManager.default.removeItem(at: url)
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
