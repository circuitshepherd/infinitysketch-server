import Testing
import Foundation
import QRCodeGenerator
@testable import InfSketchServerKit

/// A rendered code either scans or it does not, and the ways it fails are structural: a missing
/// quiet zone, or colours left to the terminal's theme. Both are pinned here, because both leave
/// something on screen that still looks exactly like a QR code.
@Suite struct TerminalQRCodeTests {

    /// The quiet zone is four modules on every side, and it is not decoration: without it most
    /// scanners never lock on. Two module rows per text row, so the row count is half the padded
    /// module count, rounded up.
    @Test func theBlockCarriesAFourModuleQuietZone() throws {
        let url = "http://192.168.1.42:18551/join"
        let qr = try QRCode.encode(text: url, ecl: .medium)
        let lines = try TerminalQRCode.render(url)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let padded = qr.size + 2 * TerminalQRCode.quietZone
        #expect(lines.count == (padded + 1) / 2)
    }

    /// Both colours are stated explicitly. Letting the terminal's palette decide inverts the code on
    /// a dark theme, and most scanners refuse an inverted code.
    @Test func bothColoursAreExplicitAndResetAfterwards() throws {
        let rendered = try TerminalQRCode.render("hello")
        #expect(rendered.contains(TerminalQRCode.light), "no explicit light colour")
        #expect(rendered.contains(TerminalQRCode.dark), "no explicit dark colour")
        #expect(rendered.hasSuffix(TerminalQRCode.reset + "\n"),
                "the colours must be reset, or the rest of the shell keeps them")
    }

    /// Every row is the same width, so the symbol is a rectangle rather than a staircase.
    @Test func everyRowIsTheSameWidth() throws {
        let widths = Set(try TerminalQRCode.render("http://10.0.0.5:8080/join")
            .split(separator: "\n")
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "",
                                           options: .regularExpression).count })
        #expect(widths.count == 1)
    }
}

#if canImport(CoreImage)
import CoreImage

extension TerminalQRCodeTests {
    /// Render the same grid to a bitmap and DECODE it. This is the difference between "it looks like
    /// a QR code" and "it is a QR code that says what we meant" — the tests above pin the shape,
    /// this one pins the content. CoreImage is Apple-only, so on Linux the suite is one test lighter.
    @Test func theCodeDecodesBackToTheURL() throws {
        let url = "http://192.168.1.42:18551/join"
        let qr = try QRCode.encode(text: url, ecl: .medium)
        let scale = 8, quiet = TerminalQRCode.quietZone
        let side = (qr.size + 2 * quiet) * scale

        var pixels = [UInt8](repeating: 255, count: side * side)   // white, including the quiet zone
        for y in 0..<qr.size {
            for x in 0..<qr.size where qr.getModule(x: x, y: y) {
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        pixels[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0
                    }
                }
            }
        }
        let ctx = try #require(CGContext(data: &pixels, width: side, height: side,
                                         bitsPerComponent: 8, bytesPerRow: side,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let cg = try #require(ctx.makeImage())
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let decoded = (detector.features(in: CIImage(cgImage: cg)).first as? CIQRCodeFeature)?.messageString
        #expect(decoded == url)
    }
}
#endif
