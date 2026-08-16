import Foundation
import Testing
@testable import InfSketchServerKit

/// `add_image`'s `path` argument — the file read that replaced base64 `bytes`
/// (spec `2026-08-11-agent-add-image-path-design.md`).
///
/// The tool used to take the image as base64 in the call. That made the bytes travel disk → the
/// calling agent's context → back to the server, and an agent reported a 19 KB PNG becoming 25 000
/// characters it had to transcribe by hand — which is what corrupted it. The server runs next to
/// the file, so it reads the file.
///
/// These run everywhere: `readImageFile` is a static on `MCPAdapter` that touches no transport, so
/// unlike `MCPAdapterTests` this is not compiled out where the SDK lacks an SSE client.
struct AddImagePathTests {

    static func withTempDir<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("addimage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    static func refusal(_ read: MCPAdapter.ImageFileRead) -> String? {
        if case .refusal(let reason) = read { return reason }
        return nil
    }

    static func write(_ data: Data, _ name: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    @Test func aRealImageFileIsReadAndReturnedWhole() throws {
        let png = try ImageContainerTests.fixture(ImageContainerTests.pngBase64)
        try Self.withTempDir { dir in
            let path = try Self.write(png, "logo.png", in: dir)
            guard case .bytes(let data) = MCPAdapter.readImageFile(at: path) else {
                Issue.record("a valid PNG was refused"); return
            }
            #expect(data == png, "the bytes must reach the device unchanged")
        }
    }

    /// The bug as reported, at the seam that now catches it: a truncated file is refused with a
    /// reason naming the file, instead of being placed as an image with plausible bounds and no
    /// pixels.
    @Test func aTruncatedImageFileIsRefusedByNameRatherThanPlaced() throws {
        let png = try ImageContainerTests.fixture(ImageContainerTests.pngBase64)
        try Self.withTempDir { dir in
            let path = try Self.write(png.prefix(png.count / 2), "cut.png", in: dir)
            let reason = try #require(Self.refusal(MCPAdapter.readImageFile(at: path)))
            #expect(reason.hasPrefix("imageCorrupt: "), "\(reason)")
            #expect(reason.contains("cut.png"), "the error must name the file: \(reason)")
        }
    }

    @Test func aMissingFileIsNamed() throws {
        try Self.withTempDir { dir in
            let path = dir.appendingPathComponent("nope.png").path
            let reason = try #require(Self.refusal(MCPAdapter.readImageFile(at: path)))
            #expect(reason.hasPrefix("imageFileNotFound: "), "\(reason)")
            #expect(reason.contains("nope.png"), "\(reason)")
        }
    }

    @Test func aDirectoryIsRefusedRatherThanRead() throws {
        try Self.withTempDir { dir in
            let reason = try #require(Self.refusal(MCPAdapter.readImageFile(at: dir.path)))
            #expect(reason.hasPrefix("imageFileUnreadable: "), "\(reason)")
        }
    }

    @Test func anEmptyFileIsRefused() throws {
        try Self.withTempDir { dir in
            let path = try Self.write(Data(), "empty.png", in: dir)
            let reason = try #require(Self.refusal(MCPAdapter.readImageFile(at: path)))
            #expect(reason.hasPrefix("imageFileEmpty: "), "\(reason)")
        }
    }

    /// A relative path is REFUSED, not resolved against the server's working directory — the
    /// caller cannot see that directory, so resolving it would produce a wrong answer that looks
    /// like a right one.
    @Test func aRelativePathIsRefusedNotResolvedAgainstTheServersCwd() throws {
        for path in ["logo.png", "./logo.png", "../images/logo.png", "images/logo.png"] {
            let reason = try #require(Self.refusal(MCPAdapter.readImageFile(at: path)),
                                      "\(path) should have been refused as relative")
            #expect(reason.hasPrefix("imagePathNotAbsolute: "), "\(reason)")
            #expect(reason.contains(path), "the error must quote what was passed: \(reason)")
        }
    }

    /// A leading `~` is expanded, so an agent may write the path the way a person would. It should
    /// reach the not-found branch, never the not-absolute one.
    @Test func aTildePathIsExpandedRatherThanRefusedAsRelative() throws {
        let reason = try #require(
            Self.refusal(MCPAdapter.readImageFile(at: "~/definitely-not-here-\(UUID().uuidString).png")))
        #expect(reason.hasPrefix("imageFileNotFound: "), "\(reason)")
        #expect(!reason.contains("~"), "the tilde should have been expanded away: \(reason)")
    }

    /// The server runs on Windows too, where absolute means a drive letter or a UNC path.
    @Test func windowsAbsolutePathsCountAsAbsolute() {
        #expect(MCPAdapter.isAbsolutePath("C:\\Users\\jowo\\logo.png"))
        #expect(MCPAdapter.isAbsolutePath("C:/Users/jowo/logo.png"))
        #expect(MCPAdapter.isAbsolutePath("\\\\server\\share\\logo.png"))
        #expect(MCPAdapter.isAbsolutePath("/Users/jowo/logo.png"))
        #expect(!MCPAdapter.isAbsolutePath("logo.png"))
        #expect(!MCPAdapter.isAbsolutePath("C:logo.png"))
    }

    /// A container the validator does not recognise still reaches the device, which decodes far
    /// more than PNG/JPEG/GIF. The read must not become a format allowlist.
    @Test func anUnrecognisedFormatIsStillRead() throws {
        try Self.withTempDir { dir in
            let heicish = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
            let path = try Self.write(heicish, "photo.heic", in: dir)
            guard case .bytes(let data) = MCPAdapter.readImageFile(at: path) else {
                Issue.record("an unrecognised container was refused by the server"); return
            }
            #expect(data == heicish)
        }
    }

    /// Refused by name rather than loaded into memory to find out how big it is. Written sparse so
    /// the test costs no real disk.
    @Test func aFileOverTheCapIsRefusedByName() throws {
        try Self.withTempDir { dir in
            let url = dir.appendingPathComponent("huge.png")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(MCPAdapter.maxImageFileBytes + 1))
            try handle.close()

            let reason = try #require(Self.refusal(MCPAdapter.readImageFile(at: url.path)))
            #expect(reason.hasPrefix("imageTooLarge: "), "\(reason)")
            #expect(reason.contains("64 MB"), "the error should name the limit: \(reason)")
        }
    }
}
