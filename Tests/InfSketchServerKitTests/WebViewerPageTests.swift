import Testing
import InfSketchWire
@testable import InfSketchServerKit

/// The doc page's load-bearing structure: the control ids the browser-driven checks
/// target, the CSS that makes the stage own its gestures, and the exposed viewport.
/// A rename fails here instead of silently in a browser.
@Suite struct WebViewerPageTests {
    let html = WebUI.docHTML(docId: "Doc & Co")

    @Test func theStageOwnsItsGestures() {
        // touch-action: none is the mechanism the whole touch story rests on —
        // without it the browser starts its own gesture and preventDefault is ignored.
        #expect(html.contains("touch-action: none"))
        #expect(html.contains("user-select: none"))
        #expect(html.contains("-webkit-touch-callout: none"))
    }

    @Test func theControlsExist() {
        for marker in ["id=\"stage\"", "id=\"frame\"", "id=\"badge\"", "id=\"fit\"",
                       "id=\"one\"", "id=\"pause\"", "id=\"wheelmode\""] {
            #expect(html.contains(marker), "missing \(marker)")
        }
    }

    @Test func theViewportIsExposedForTheBrowserChecks() {
        #expect(html.contains("window.__viewport"))
    }

    @Test func pauseReallyUnwatches() {
        // Pause must stop the DEVICE rendering (unwatchDoc -> FrameScheduler inert),
        // not merely freeze the picture — and the badge must say so.
        #expect(html.contains("unwatchDoc"))
        #expect(html.contains("\"paused\""))
    }

    @Test func framesLoadDetachedAndSwapOnLoad() {
        // Assigning img.src directly blanks the element for the whole download,
        // once a second — the flicker the old page had.
        #expect(html.contains("new Image()"))
    }

    @Test func theHelloStillInterpolatesTheWireVersion() {
        #expect(html.contains("protocolVersion: \(WireProtocol.version)"))
    }

    @Test func wheelModePersists() {
        #expect(html.contains("infsketch.wheelMode"))
    }

    @Test func theResolutionPickerExistsAndPersists() {
        #expect(html.contains("id=\"respx\""))
        #expect(html.contains("infsketch.framePx"))
    }

    @Test func immersiveModeIsThePagesOwnChromeNotTheBrowsers() {
        // Josef: "don't touch the browsers fullscreen control, this should work independent."
        // The Fullscreen API must not appear at all, so F11 composes with this rather than
        // competing with it. Scanned with comments stripped — the prose explaining the rule
        // names the API, and unstripped it defeated this very assertion.
        let code = WebPageScan.stripComments(html)
        #expect(!code.contains("requestFullscreen"))
        #expect(!code.contains("fullscreenElement"))
        #expect(html.contains("id=\"full\""))
        // The bar leaves the flow, which is what lets #stage fill the window.
        #expect(html.contains("body.immersive #bar"))
        #expect(html.contains("position: absolute"))
    }

    @Test func immersiveChromeAutoFadesAndPersists() {
        #expect(html.contains("body.immersive.idle #bar"))
        #expect(html.contains("pointer-events: none"))
        #expect(html.contains("infsketch.immersive"))
        // The controls must not fade out from under a hand reaching for them.
        #expect(html.contains("pointerOverBar"))
    }

    @Test func theImmersiveKeysAreHandled() {
        #expect(html.contains("case \"f\":"))
        #expect(html.contains("case \"Escape\":"))
        // Escape falls through untouched when there is no immersive mode to leave.
        #expect(html.contains("if (!immersive) return;"))
    }

    @Test func theBadgeKeepsItsBaseClassOnEveryWrite() {
        // The badge carries a shared `.badge` class now; a bare className = "live" would drop it
        // and lose the type styling, which no visual assertion here would notice.
        #expect(!html.contains("badge.className = \"\""))
        #expect(!html.contains("badge.className = fresh ? \"live\" : \"\""))
        #expect(html.contains("badge.className = \"badge\""))
        #expect(html.contains("badge.className = fresh ? \"badge live\" : \"badge\""))
    }

    @Test func thePageEmbedsTheRealViewportSource() {
        // Deleting the \#(viewportJS) interpolation leaves the parse test green
        // (it parses, never executes) — this pins the embed itself.
        #expect(html.contains(WebUI.viewportJS))
    }
}

#if canImport(JavaScriptCore)
import JavaScriptCore

extension WebViewerPageTests {
    /// The page's whole script, parsed (never executed) by a real JS engine — the
    /// syntax gate a script inside a Swift string literal otherwise lacks.
    @Test func theDocPageScriptParses() throws {
        let start = try #require(html.range(of: "<script>"))
        let end = try #require(html.range(of: "</script>"))
        let script = String(html[start.upperBound..<end.lowerBound])
        let ctx = JSContext()!
        var caught: String? = nil
        ctx.exceptionHandler = { _, ex in caught = ex?.toString() }
        ctx.evaluateScript("(function () {\n\(script)\n})")
        #expect(caught == nil, "script does not parse: \(caught ?? "")")
    }
}
#endif
