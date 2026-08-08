import Testing
import QRCodeGenerator
@testable import InfSketchServerKit

/// The same two structural traps `TerminalQRCodeTests` pins, in the other renderer — plus one that
/// belongs to HTML: the generator emits an XML prolog and a DOCTYPE, and inline SVG inside an HTML
/// document must begin at `<svg`.
@Suite struct QRCodeSVGTests {

    @Test func theMarkupBeginsAtTheSvgElement() throws {
        let svg = try QRCodeSVG.inlineSVG(for: "http://192.168.1.42:18551/join")
        #expect(svg.hasPrefix("<svg"))
        #expect(!svg.contains("<?xml"))
        #expect(!svg.contains("DOCTYPE"))
    }

    /// Explicit black on explicit white, in a page that carries `color-scheme: light dark`. Most
    /// scanners refuse an inverted code, and a code that inherits the page's colours inverts.
    @Test func theCodeIsBlackOnAnExplicitWhitePlate() throws {
        let svg = try QRCodeSVG.inlineSVG(for: "hello")
        #expect(svg.contains("fill=\"#FFFFFF\""), "no explicit white background")
        #expect(svg.contains("fill=\"#000000\""), "no explicit black modules")
    }

    /// The quiet zone is four modules on every side and it is part of the symbol: the viewBox is
    /// the module count PLUS twice the quiet zone.
    @Test func theViewBoxCarriesTheQuietZone() throws {
        let text = "http://192.168.1.42:18551/join"
        let expected = try QRCode.encode(text: text, ecl: .medium).size + 2 * TerminalQRCode.quietZone
        let svg = try QRCodeSVG.inlineSVG(for: text)
        #expect(svg.contains("viewBox=\"0 0 \(expected) \(expected)\""))
    }

    /// The generator writes `width=200` with NO QUOTES, which is malformed HTML — so no width
    /// attribute is asked for at all and the size comes from CSS.
    /// Checked on the OPENING TAG only: the background `<rect>` legitimately carries
    /// `width="100%"`, so a search of the whole document would pass whatever the generator did.
    @Test func noUnquotedWidthAttributeIsEmitted() throws {
        let svg = try QRCodeSVG.inlineSVG(for: "hello")
        let openingTag = svg.prefix { $0 != ">" }
        #expect(!openingTag.contains("width"),
                "an unquoted width attribute leaked into the <svg> tag: \(openingTag)")
    }
}
