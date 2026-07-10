import Foundation

public struct StoredDocInfo: Sendable, Equatable {
    public let docId: String
    public let name: String
    public let sizeBytes: Int
    public let modifiedAt: Date
}

public enum DocumentStoreError: Error, Equatable {
    case invalidDocId
    case notFound
}

public protocol DocumentStore: Sendable {
    func list() throws -> [StoredDocInfo]
    func load(docId: String) throws -> Data
    func save(docId: String, bytes: Data) throws
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
