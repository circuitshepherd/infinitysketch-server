import Foundation

/// Structural validation of image bytes **without decoding them** — the check `add_image` runs on
/// the file it reads from `path` before relaying it to the device
/// (spec `2026-08-11-agent-add-image-path-design.md`).
///
/// **Why this is not done with a decoder.** It was reported that `add_image` accepted a corrupt
/// PNG, returned success with an id, and left `list_images` reporting plausible bounds for an image
/// with zero pixels. Measured (`scripts/probe-corrupt-image-decode`), a PNG truncated to 60 % of
/// its length makes `UIImage(data:)` return an image, reports the correct 167×160 size (it comes
/// from the IHDR header, which survives truncation), makes `CGImageSourceGetStatus` answer
/// `complete`, and still yields a `CGImage` when the decode is forced. ImageIO rejects only input
/// it cannot find a header in. So the tool's documented `invalidSpec`-on-undecodable-bytes promise
/// could not be kept at the decoder level at all.
///
/// A container check keeps it: PNG carries a CRC32 per chunk and must terminate with `IEND`, so
/// truncation and byte corruption are both positively detectable. Needing no decoder is what lets
/// this live on the cross-platform server, run before any device round trip, and name the file.
///
/// **It refuses only what it positively recognises as broken.** `UIImage(data:)` decodes more
/// formats than the three understood here (HEIC, TIFF, …), so anything whose signature is not
/// recognised is `.unrecognised` and passes through to the device untouched. A safety check must
/// not quietly narrow what the tool accepts.
enum ImageContainer {

    enum Verdict: Equatable {
        /// A recognised container that is structurally complete.
        case looksIntact
        /// Not a container this understands. Pass it to the device, which decodes far more.
        case unrecognised
        /// A recognised container that is positively broken; the string names the failing check
        /// and goes into the tool's error verbatim.
        case broken(String)
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let gif87a = Array("GIF87a".utf8)
    private static let gif89a = Array("GIF89a".utf8)

    static func inspect(_ data: Data) -> Verdict {
        data.withUnsafeBytes { raw -> Verdict in
            let bytes = raw.bindMemory(to: UInt8.self)
            if starts(bytes, with: pngSignature) { return inspectPNG(bytes) }
            if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 { return inspectJPEG(bytes) }
            if starts(bytes, with: gif87a) || starts(bytes, with: gif89a) { return inspectGIF(bytes) }
            return .unrecognised
        }
    }

    private static func starts(_ bytes: UnsafeBufferPointer<UInt8>, with prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        for (i, b) in prefix.enumerated() where bytes[i] != b { return false }
        return true
    }

    // MARK: - PNG

    /// Walks `[length][type][data][CRC32]` chunks from just past the signature. Every chunk's CRC
    /// must match — that is what catches a flipped byte whose framing still looks right — and the
    /// walk must reach `IEND`, which is what catches truncation. Bytes after `IEND` are ignored:
    /// some tools pad, and padding is not corruption.
    private static func inspectPNG(_ bytes: UnsafeBufferPointer<UInt8>) -> Verdict {
        var offset = pngSignature.count
        while true {
            guard offset + 8 <= bytes.count else {
                return .broken("PNG data ends inside a chunk header at offset \(offset)")
            }
            let length = Int(be32(bytes, offset))
            let typeStart = offset + 4
            let type = String(decoding: (0..<4).map { bytes[typeStart + $0] }, as: UTF8.self)
            // A length is a 4-byte unsigned field but the format caps it at 2^31-1; a larger one
            // is corruption, and on a 32-bit host the addition below could overflow.
            guard length >= 0, length <= 0x7FFF_FFFF else {
                return .broken("PNG chunk \(type) at offset \(offset) declares an impossible length")
            }
            guard typeStart + 4 + length + 4 <= bytes.count else {
                return .broken(
                    "PNG data ends inside the \(type) chunk at offset \(offset) "
                    + "(it declares \(length) bytes, \(bytes.count - typeStart - 4) remain)")
            }
            let stored = be32(bytes, typeStart + 4 + length)
            let actual = crc32(bytes, from: typeStart, count: 4 + length)
            guard stored == actual else {
                return .broken("PNG chunk \(type) at offset \(offset) fails its CRC")
            }
            if type == "IEND" { return .looksIntact }
            offset = typeStart + 4 + length + 4
        }
    }

    private static func be32(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    /// The standard zlib CRC-32 (reflected polynomial 0xEDB88320) PNG chunks carry, computed over
    /// the chunk's type and data. Table built once.
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ bytes: UnsafeBufferPointer<UInt8>, from: Int, count: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for i in from..<(from + count) {
            crc = crcTable[Int((crc ^ UInt32(bytes[i])) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - JPEG

    /// JPEG has no per-segment checksum, so only truncation is detectable: the stream must carry
    /// an end-of-image marker (`FFD9`). Searched from the end, where it belongs, and accepted
    /// anywhere rather than only as the final two bytes — trailing padding is common and is not
    /// corruption.
    private static func inspectJPEG(_ bytes: UnsafeBufferPointer<UInt8>) -> Verdict {
        guard bytes.count >= 4 else { return .broken("JPEG data ends immediately after its header") }
        var i = bytes.count - 2
        while i >= 2 {
            if bytes[i] == 0xFF, bytes[i + 1] == 0xD9 { return .looksIntact }
            i -= 1
        }
        return .broken("JPEG data ends without an end-of-image marker")
    }

    // MARK: - GIF

    /// GIF likewise has no checksum; the detectable failure is a missing `0x3B` trailer. Allowed
    /// within the last few bytes rather than exactly last, for the same padding reason.
    private static func inspectGIF(_ bytes: UnsafeBufferPointer<UInt8>) -> Verdict {
        let window = 8
        guard bytes.count > gif87a.count else { return .broken("GIF data ends after its header") }
        var i = bytes.count - 1
        let stop = max(gif87a.count, bytes.count - window)
        while i >= stop {
            if bytes[i] == 0x3B { return .looksIntact }
            i -= 1
        }
        return .broken("GIF data ends without its trailer")
    }
}
