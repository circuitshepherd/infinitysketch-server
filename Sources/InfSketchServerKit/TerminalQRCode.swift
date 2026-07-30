import Foundation
import QRCodeGenerator

/// A QR code drawn with text, for a terminal.
///
/// Two details decide whether a rendered code scans at all, and both are easy to leave out because
/// the result still LOOKS like a QR code:
///
/// - **The quiet zone.** Four clear modules on every side. It reads as padding; it is part of the
///   symbol, and without it most scanners never lock on.
/// - **Explicit colours.** Relying on the terminal's own palette inverts the code on a dark theme,
///   and most scanners refuse an inverted code. Both the light and the dark module carry an explicit
///   ANSI colour here, so the code looks the same whatever the theme.
///
/// Drawn with half blocks, so ONE character cell carries TWO module rows — otherwise a terminal's
/// line height stretches the symbol into a rectangle and the aspect ratio fights the scanner.
enum TerminalQRCode {
    /// Four modules, per the QR specification. Not decoration.
    static let quietZone = 4

    static let light = "\u{1B}[38;5;15m"   // explicit white foreground
    static let dark = "\u{1B}[48;5;0m"     // explicit black background
    static let reset = "\u{1B}[0m"

    static func render(_ text: String) throws -> String {
        let qr = try QRCode.encode(text: text, ecl: .medium)
        let padded = qr.size + 2 * quietZone

        // `true` = dark module. Everything outside the symbol is quiet zone, which is light.
        func isDark(_ x: Int, _ y: Int) -> Bool {
            let mx = x - quietZone, my = y - quietZone
            guard mx >= 0, my >= 0, mx < qr.size, my < qr.size else { return false }
            return qr.getModule(x: mx, y: my)
        }

        var out = ""
        for row in stride(from: 0, to: padded, by: 2) {
            out += light + dark
            for x in 0..<padded {
                let upper = isDark(x, row)
                // An odd module count leaves the last row's lower half outside the symbol: light.
                let lower = row + 1 < padded ? isDark(x, row + 1) : false
                switch (upper, lower) {
                case (false, false): out += "\u{2588}"   // full block: light over light
                case (false, true): out += "\u{2580}"    // upper half light, lower dark
                case (true, false): out += "\u{2584}"    // lower half light, upper dark
                case (true, true): out += " "            // both dark — the background shows through
                }
            }
            out += reset + "\n"
        }
        return out
    }
}
