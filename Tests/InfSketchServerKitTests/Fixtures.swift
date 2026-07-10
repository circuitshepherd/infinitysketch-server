import Foundation

enum Fixtures {
    /// A valid 1x1 PNG.
    static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    static var thumbnailPNG: Data {
        Data(base64Encoded: onePixelPNGBase64)!
    }

    /// Minimal stand-in for an .infsketch document: JSON with the thumbnail
    /// as its first key (the real format's contract).
    static var docBytes: Data {
        Data(#"{"aaa001_thumbnailData":"\#(onePixelPNGBase64)","strokes":[]}"#.utf8)
    }
}
