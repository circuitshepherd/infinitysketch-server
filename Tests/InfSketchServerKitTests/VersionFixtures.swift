import Foundation
@testable import InfSketchServerKit

/// Documents in the app's on-disk shape — sorted keys, thumbnail first, pasted images as base64
/// with `/` escaped the way `JSONEncoder` escapes it (see `DocumentBlobs`) — built by hand so the
/// tests run on Linux, where there is no app encoder.
enum VersionFixtures {
    static func image(seed: UInt8, count: Int = 12_000) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    static func document(marker: String, images: [(id: UUID, bytes: Data)] = [],
                         documentId: String = "doc") -> Data {
        let entries = images.map { image -> String in
            let escaped = image.bytes.base64EncodedString().replacingOccurrences(of: "/", with: "\\/")
            return #"{"data":"\#(escaped)","id":"\#(image.id.uuidString)"}"#
        }.joined(separator: ",")
        return Data(#"{"aaa001_thumbnailData":"","documentId":"\#(documentId)","marker":"\#(marker)","pastedImagesData":[\#(entries)]}"#.utf8)
    }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
