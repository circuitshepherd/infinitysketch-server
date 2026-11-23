//
//  AgentTextDefaults.swift
//  InfSketchWire
//
//  The font of a text an agent adds without naming one. In the package both sides link, so the
//  server's own text writer and the app's cannot disagree about it.
//

import Foundation

/// A text added without a `family` is set in the font the APP BUNDLES — Inter — at a fixed size,
/// so it is the same on every device (2026-11-23). Until then it had no font at all and each
/// device showed it in its own system font at its own Dynamic Type size; the Mac's system font
/// is up to 5 percent wider than an iPad's, and an agent's captions broke into other lines there.
public enum AgentTextDefaults {
    /// The bundled font's family name, as `list_fonts` reports it and `family` takes it.
    public static let family = "Inter Variable"

    /// The size of a text added without a `fontSize`, in points.
    public static let fontSize: Double = 17

    /// The document format from which every app that opens the document has the font. The server
    /// writes the font only into such a document: an older app does not have it, would show the
    /// text in a substitute and store the substitute at its next save.
    public static let firstFormatWithTheFont = 8

    /// The value of a text run's `NSFont` attribute for `family` (its regular face) at
    /// `fontSize`: the archive the app itself writes for that font. The server cannot make one —
    /// it is UIKit's — so it carries this one; the app's `BundledInterFontTests` decodes it and
    /// checks that it is the font the app's own default resolves to.
    public static let fontAttribute =
        "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGrCwwhIigyMxs0Oz9VJG51bGzbDQ4PEBESExQVFhcYGBkaGxwdGx4aIF8QIlVJRm9udE1heGltdW1Qb2ludFNpemVBZnRlclNjYWxpbmdfEBlVSUZvbnRQb2ludFNpemVGb3JTY2FsaW5nXxAQVUlGb250RGVzY3JpcHRvclZOU05hbWVWTlNTaXplViRjbGFzc1xVSUZvbnRUcmFpdHNfEA9VSUZvbnRQb2ludFNpemVfEBlVSUZvbnRUZXh0U3R5bGVGb3JTY2FsaW5nWlVJRm9udE5hbWVcVUlTeXN0ZW1Gb250IwAAAAAAAAAAgAOAAiNAMQAAAAAAAIAKEACAAIACCF1JbnRlclZhcmlhYmxl0yMSJCUmJ18QF1VJRm9udERlc2NyaXB0b3JPcHRpb25zXxAaVUlGb250RGVzY3JpcHRvckF0dHJpYnV0ZXMSgACAAIAJgATTKSoSKy4xV05TLmtleXNaTlMub2JqZWN0c6IsLYAFgAaiLxqAB4ACgAhfEBNOU0ZvbnRTaXplQXR0cmlidXRlXxATTlNGb250TmFtZUF0dHJpYnV0ZdI1Njc4WiRjbGFzc25hbWVYJGNsYXNzZXNcTlNEaWN0aW9uYXJ5ojk6XE5TRGljdGlvbmFyeVhOU09iamVjdNI1Njw9XxAQVUlGb250RGVzY3JpcHRvcqI+Ol8QEFVJRm9udERlc2NyaXB0b3LTNTZAQUJDWyRjbGFzc2hpbnRzVlVJRm9udKJBOqFEVk5TRm9udAAIABEAGgAkACkAMgA3AEkATABRAFMAXwBlAHwAoQC9ANAA1wDeAOUA8gEEASABKwE4AUEBQwFFAU4BUAFSAVQBVgFXAWUBbAGGAaMBqAGqAawBswG7AcYByQHLAc0B0AHSAdQB1gHsAgICBwISAhsCKAIrAjgCQQJGAlkCXAJvAnYCggKJAowCjgAAAAAAAAIBAAAAAAAAAEUAAAAAAAAAAAAAAAAAAAKV"
}
