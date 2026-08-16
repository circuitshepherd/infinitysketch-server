import Foundation
import Testing
@testable import InfSketchServerKit

/// `ImageContainer` — the structural check `add_image` runs on the bytes it reads from `path`,
/// before relaying them to the device (spec `2026-08-11-agent-add-image-path-design.md`).
///
/// It exists because NO decoder-level check catches the failure that was reported: a truncated PNG
/// makes `UIImage(data:)` return an image of the right size (the size comes from the IHDR header,
/// which survives truncation), `CGImageSourceGetStatus` report `complete`, and a forced decode
/// still yield a `CGImage` — measured in `scripts/probe-corrupt-image-decode`. The image then
/// renders as zero pixels, and `list_images` reports plausible bounds for it forever.
///
/// The fixtures are real encoder output (16×16, one flat fill plus a rectangle), embedded as
/// base64 so this suite runs on Linux and Windows too — the CRC values in the PNG therefore come
/// from a real encoder rather than from this repo's own arithmetic, which is the whole point of
/// checking them.
struct ImageContainerTests {

    // MARK: - Fixtures

    static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAAB" +
        "AAAAGgAAAAAAAqACAAQAAAABAAAAEKADAAQAAAABAAAAEAAAAAAXnVPIAAAAQElEQVQ4EWMUXv36PwMFgIkCvWCtowYwMAx8" +
        "GLDAovFNgCiMiUGLbHiNIQYTGHgvDLwL4IGIL6BgAYaNHngvAAAPigd7VhWPyAAAAABJRU5ErkJggg=="

    static let jpegBase64 =
        "/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAEKAD" +
        "AAQAAAABAAAAEAAAAAD/wAARCAAQABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA" +
        "AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6" +
        "Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXG" +
        "x8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA" +
        "AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5" +
        "OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPE" +
        "xcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgI" +
        "CAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ" +
        "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/90ABAAB/9oADAMBAAIRAxEAPwDUor6r+G3xy8J+DvBeneHNTtL6W5tPO3tD" +
        "HE0Z8yV5BgtKp6MM8da+cPE+pwa14l1bWbVWSG/u57hA4AYLLIzgMASM4POCfrX9B8B+IXEGaZ5mOWZnkk8Lh6EpKlWlUUlX" +
        "Sm4qSjyR5eaKU7c0rJ28z/PTiLhrLcJl+GxWEx6rVKiTnTUbOm3FNpvmd7P3dlsf/9k="

    static let gifBase64 =
        "R0lGODdhEAAQAKIAAAAAABOr6//7AP///wAAAAAAAAAAAAAAACH5BAkAAAQALAAAAAAQABAAAAMYGLrc/jDKSau9UugtIt/e" +
        "10Hi+JRYqjIJADs="

    static func fixture(_ base64: String) throws -> Data {
        try #require(Data(base64Encoded: base64))
    }

    static func broken(_ verdict: ImageContainer.Verdict) -> String? {
        if case .broken(let why) = verdict { return why }
        return nil
    }

    // MARK: - PNG

    @Test func aRealPngLooksIntact() throws {
        #expect(ImageContainer.inspect(try Self.fixture(Self.pngBase64)) == .looksIntact)
    }

    /// The reported failure. Every byte that remains is valid; what is missing is the end.
    @Test func aTruncatedPngIsBrokenAndSaysWhy() throws {
        let png = try Self.fixture(Self.pngBase64)
        let cut = png.prefix(Int(Double(png.count) * 0.6))
        let why = try #require(Self.broken(ImageContainer.inspect(cut)),
                               "a truncated PNG must not pass — this is the bug as reported")
        #expect(why.lowercased().contains("end"), "the reason should name the truncation: \(why)")
    }

    /// A byte flipped inside a chunk, its length untouched, so nothing about the framing looks
    /// wrong — only the chunk's own CRC disagrees. This is what a hand-transcribed payload does.
    @Test func aPngWithAFlippedByteFailsItsChunkCrc() throws {
        var png = try Self.fixture(Self.pngBase64)
        let mid = png.count / 2
        png[png.startIndex + mid] = png[png.startIndex + mid] &+ 77
        let why = try #require(Self.broken(ImageContainer.inspect(png)))
        #expect(why.uppercased().contains("CRC"), "the reason should name the CRC: \(why)")
    }

    /// Every truncation point is caught, not just a convenient one. The signature alone is
    /// deliberately excluded: 8 bytes with no chunk at all is not a PNG anyone produced.
    @Test func everyTruncationOfAPngIsCaught() throws {
        let png = try Self.fixture(Self.pngBase64)
        for cut in 9..<png.count {
            #expect(Self.broken(ImageContainer.inspect(png.prefix(cut))) != nil,
                    "a PNG cut to \(cut) of \(png.count) bytes passed")
        }
        #expect(ImageContainer.inspect(png) == .looksIntact)
    }

    /// Bytes appended after IEND are not corruption — some tools pad. Accept, because the
    /// validator refuses only what it positively recognises as broken.
    @Test func trailingBytesAfterIendAreAccepted() throws {
        var png = try Self.fixture(Self.pngBase64)
        png.append(contentsOf: [0x00, 0xFF, 0x42, 0x42])
        #expect(ImageContainer.inspect(png) == .looksIntact)
    }

    /// A declared chunk length that runs past the end of the data must be refused, not trusted
    /// into an out-of-bounds read.
    @Test func aChunkLengthPastTheEndIsRefusedNotRead() throws {
        var png = try Self.fixture(Self.pngBase64)
        // The first chunk after the 8-byte signature is IHDR; blow up its declared length.
        png[png.startIndex + 8] = 0x7F
        png[png.startIndex + 9] = 0xFF
        #expect(Self.broken(ImageContainer.inspect(png)) != nil)
    }

    // MARK: - JPEG

    @Test func aRealJpegLooksIntact() throws {
        #expect(ImageContainer.inspect(try Self.fixture(Self.jpegBase64)) == .looksIntact)
    }

    @Test func aTruncatedJpegIsBroken() throws {
        let jpeg = try Self.fixture(Self.jpegBase64)
        let cut = jpeg.prefix(Int(Double(jpeg.count) * 0.6))
        #expect(Self.broken(ImageContainer.inspect(cut)) != nil)
    }

    // MARK: - GIF

    @Test func aRealGifLooksIntact() throws {
        #expect(ImageContainer.inspect(try Self.fixture(Self.gifBase64)) == .looksIntact)
    }

    @Test func aTruncatedGifIsBroken() throws {
        let gif = try Self.fixture(Self.gifBase64)
        let cut = gif.prefix(Int(Double(gif.count) * 0.6))
        #expect(Self.broken(ImageContainer.inspect(cut)) != nil)
    }

    // MARK: - Everything else passes through

    /// `UIImage(data:)` decodes more than these three formats (HEIC, TIFF, …). A container this
    /// validator does not recognise must reach the device untouched, or a safety check quietly
    /// narrows what the tool accepts.
    @Test func anUnrecognisedContainerIsPassedThroughRatherThanRefused() {
        #expect(ImageContainer.inspect(Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]))
                == .unrecognised)
        #expect(ImageContainer.inspect(Data("II*\0 not really a tiff".utf8)) == .unrecognised)
        #expect(ImageContainer.inspect(Data()) == .unrecognised)
    }

    /// A recognised signature is what arms the check — nothing else may be refused, however odd.
    @Test func randomBytesAreNotRefused() {
        var generator = SystemRandomNumberGenerator()
        let junk = Data((0..<512).map { _ in UInt8.random(in: 0...255, using: &generator) })
        // Astronomically unlikely to begin with a PNG/JPEG/GIF signature.
        #expect(ImageContainer.inspect(junk) == .unrecognised)
    }
}
