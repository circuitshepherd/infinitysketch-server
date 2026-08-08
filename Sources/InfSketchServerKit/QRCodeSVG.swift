import Foundation
import QRCodeGenerator

/// A QR code as inline SVG, for the web page.
///
/// The terminal renderer beside this one (`TerminalQRCode`) documents the two traps that decide
/// whether a code scans at all, and both apply here: the four-module quiet zone is part of the
/// symbol, and the colours must be stated rather than inherited — the overview page carries
/// `color-scheme: light dark`, and an inverted code is one most scanners refuse.
///
/// Inline rather than an image endpoint: the page must work with no internet and no extra route,
/// and the generator already produces markup.
public enum QRCodeSVG {

    public static func inlineSVG(for text: String) throws -> String {
        let qr = try QRCode.encode(text: text, ecl: .medium)
        // `width` is deliberately nil: the generator interpolates it as `width=200`, unquoted,
        // which is malformed HTML. CSS sizes the element instead.
        let svg = qr.toSVGString(
            border: TerminalQRCode.quietZone, width: nil,
            foreground: "#000000", background: "#FFFFFF")
        // The generator emits an XML prolog and a DOCTYPE. Inline SVG in an HTML document must
        // begin at `<svg`; a browser meeting the prolog mid-document does not render the code.
        guard let start = svg.range(of: "<svg") else { return svg }
        return String(svg[start.lowerBound...])
    }
}
