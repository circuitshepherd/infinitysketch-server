import Foundation
import Testing
@testable import InfSketchServerKit
import MCP

/// The 2026-07-28 coordinate-space rename moved `x`/`y`/`width`/`height` to `canvasX`/`canvasY`/
/// `canvasWidth`/`canvasHeight` in every schema — but left several tool DESCRIPTIONS still telling
/// the caller to pass the old spelling. `add_image` said "`x`,`y` are the TOP-LEFT corner" and
/// "optional `width`/`height`" while declaring the `canvas*` names.
///
/// That is not cosmetic. Every tool is `additionalProperties: false` with `enforceKnownArguments`,
/// so an agent that believes the prose has its first call rejected by name. It is exactly what
/// happened, and `noToolRequiresAnArgumentItDoesNotDeclare` structurally cannot see it: that test
/// compares *required* against *declared*, and a stale English sentence is neither.
///
/// The rule is deliberately narrow enough to need no tuning: a bare `x`/`y` word, or a BACKTICKED
/// `width`/`height`, in a tool that declares the `canvas*` spelling. Unbackticked "width" is left
/// alone because it has honest prose uses — "inherit the width of the tool the user has selected"
/// is about a quantity, not an argument.
///
/// Runs on every platform: it reads `MCPAdapter.toolDefinitions` directly rather than through a
/// client, so unlike `MCPAdapterTests` it is not compiled out where the SDK has no SSE transport.
struct ToolDescriptionVocabularyTests {

    /// A standalone `x` or `y` — `(x, y)`, "x and/or y", "`x`" — but not `canvasX`, `16x16`,
    /// `maxPixels` or the hyphenated `x-coordinate`.
    ///
    /// The hyphen matters: two descriptions use `x` and `y` honestly, about the axes rather than
    /// about arguments ("a horizontal wire can snap its y and keep its x"). Rather than carry an
    /// allowlist — which the next maintainer would only grow — those were rewritten to
    /// `y-coordinate`/`x-coordinate`, which reads better and leaves this gate with no exemptions.
    static func containsBareToken(_ token: Character, in text: String) -> Bool {
        let chars = Array(text)
        for (i, c) in chars.enumerated() where c == token {
            let before = i > 0 ? chars[i - 1] : " "
            let after = i + 1 < chars.count ? chars[i + 1] : " "
            let adjacent = { (c: Character) in c.isLetter || c.isNumber || c == "-" }
            if !adjacent(before) && !adjacent(after) { return true }
        }
        return false
    }

    static func toolsDeclaringCanvasNames() -> [Tool] {
        MCPAdapter.toolDefinitions.filter { tool in
            MCPAdapter.declaredArguments(of: tool).contains { $0.hasPrefix("canvas") }
        }
    }

    @Test func noDescriptionTellsTheCallerToPassTheOldCoordinateNames() throws {
        let candidates = Self.toolsDeclaringCanvasNames()
        #expect(!candidates.isEmpty, "no tool declares a canvas* argument — the filter is wrong")

        var offences: [String] = []
        for tool in candidates {
            let description = tool.description ?? ""
            for token: Character in ["x", "y"] where Self.containsBareToken(token, in: description) {
                offences.append("\(tool.name): bare `\(token)` in its description")
            }
            for word in ["width", "height"] where description.contains("`\(word)`") {
                offences.append("\(tool.name): backticked `\(word)` in its description")
            }
        }

        #expect(offences.isEmpty, """
            These tools declare canvas* arguments but their descriptions name the pre-rename \
            spelling, so a caller that believes the prose is refused by enforceKnownArguments:
            \(offences.joined(separator: "\n"))
            """)
    }

    /// A colour argument whose description does not name its space re-opens the trap the
    /// 2026-08-12 colour-space spec closed.
    @Test func everyColourTakingToolNamesTheColourSpace() throws {
        let colourTools = MCPAdapter.toolDefinitions.filter {
            MCPAdapter.declaredArguments(of: $0).contains("colorAppearance")
        }
        #expect(!colourTools.isEmpty)
        for tool in colourTools {
            let description = tool.description ?? ""
            #expect(description.localizedCaseInsensitiveContains("light-canonical")
                 || description.localizedCaseInsensitiveContains("colorAppearance"),
                    "\(tool.name) takes colours but its description never names their space")
        }
    }

    /// The detector itself, in both directions — a gate that cannot fire is worse than no gate.
    @Test func theBareTokenDetectorDistinguishesPoseFromParameters() {
        #expect(Self.containsBareToken("x", in: "(x, y) is the top-left corner"))
        #expect(Self.containsBareToken("x", in: "pass `x` and `y`"))
        #expect(Self.containsBareToken("y", in: "x and/or y with no text"))
        #expect(!Self.containsBareToken("x", in: "canvasX is the left edge"))
        #expect(!Self.containsBareToken("x", in: "a 16x16 image at maxPixels"))
        #expect(!Self.containsBareToken("y", in: "the array is ordered by distance only"))
    }
}
