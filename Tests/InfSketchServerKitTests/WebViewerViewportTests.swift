#if canImport(JavaScriptCore)
import JavaScriptCore
import Testing
@testable import InfSketchServerKit

/// Drives the REAL viewport source (`WebUI.viewportJS`) in a JSContext — the math the
/// browser runs, never a Swift re-derivation of it. dpr is pinned to 2 (a Retina
/// display), so 1:1 means scale 0.5 and the max zoom (8 device px per frame px) is 4.
/// Every test starts from a 1000x800 box holding a 1024x1024 frame: fit = 800/1024
/// = 0.78125, letterboxed left/right (tx 100), flush top/bottom (ty 0).
@Suite struct WebViewerViewportTests {
    /// The default frame reports NO canvas rect, which is the stale-thumbnail path and
    /// the weaker frame-pixel rule — so every test below that does not pass one is
    /// pinning that fallback.
    private func makeVP(dpr: Double = 2.0, rect: Any = NSNull()) -> JSValue {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, ex in Issue.record("JS threw: \(ex?.toString() ?? "?")") }
        ctx.evaluateScript(WebUI.viewportJS)
        ctx.evaluateScript("var vp = makeViewport(function () { return \(dpr); });")
        let vp = ctx.objectForKeyedSubscript("vp")!
        vp.invokeMethod("setBox", withArguments: [1000, 800])
        vp.invokeMethod("setFrame", withArguments: [1024, 1024, rect])
        return vp
    }

    /// Where a canvas point currently lands in the box, given the rect the frame covers.
    /// Two distinct points holding still across a frame change pins scale AND translation.
    private func cssX(_ vp: JSValue, canvas: Double, rectX: Double, rectW: Double,
                      imgW: Double = 1024) -> Double {
        let s = state(vp)
        return (canvas - rectX) * (imgW / rectW) * s.scale + s.tx
    }

    private func state(_ vp: JSValue) -> (scale: Double, tx: Double, ty: Double, atFit: Bool) {
        let s = vp.forProperty("state")!
        return (s.forProperty("scale")!.toDouble(), s.forProperty("tx")!.toDouble(),
                s.forProperty("ty")!.toDouble(), s.forProperty("atFit")!.toBool())
    }

    @Test func fitCentresTheLetterboxedSquare() {
        let s = state(makeVP())
        #expect(abs(s.scale - 800.0 / 1024.0) < 1e-12)
        #expect(abs(s.tx - 100) < 1e-9)   // (1000 - 800) / 2
        #expect(abs(s.ty - 0) < 1e-9)
        #expect(s.atFit)
    }

    @Test func zoomKeepsTheCursorPointFixed() {
        let vp = makeVP()
        let s0 = state(vp)
        let framePx = (500.0 - s0.tx) / s0.scale   // the frame pixel under cursor x=500
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 1.5])
        let s1 = state(vp)
        #expect(abs(framePx * s1.scale + s1.tx - 500) < 1e-9)
    }

    /// zoomAbout must derive its translation from the CLAMPED scale. The buggy version
    /// (translation from the requested factor) makes the image creep sideways on every
    /// scroll tick taken against the zoom limit — this test pins tx/ty exactly still.
    @Test func zoomAgainstTheLimitDoesNotCreep() {
        let vp = makeVP()
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 100])   // clamps to 4
        let sA = state(vp)
        #expect(abs(sA.scale - 4.0) < 1e-12)
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 2])     // already at max
        let sB = state(vp)
        #expect(sB.tx == sA.tx && sB.ty == sA.ty && sB.scale == sA.scale)
    }

    /// 1:1 (0.5 here) is MORE zoomed out than fit (0.78) — the common case. The minimum
    /// clamp is min(fit, 1/dpr) precisely so this button works; clamped at fitScale it
    /// would be inert and this test fails.
    @Test func oneToOneIsReachableBelowFit() {
        let vp = makeVP()
        vp.invokeMethod("oneToOne", withArguments: [])
        #expect(abs(state(vp).scale - 0.5) < 1e-12)
    }

    @Test func aSmallerImageIsCentredNotCornered() {
        let vp = makeVP()
        vp.invokeMethod("oneToOne", withArguments: [])   // 512 CSS px in a 1000x800 box
        let s = state(vp)
        #expect(abs(s.tx - 244) < 1e-9)   // (1000 - 512) / 2
        #expect(abs(s.ty - 144) < 1e-9)   // (800 - 512) / 2
    }

    /// A new frame with a different pixel size keeps the same document region on
    /// screen. Factor 1.27 is chosen deliberately: it is inside the narrow window
    /// where the image overflows the box (so the no-dead-space clamp does not
    /// re-centre and mask a wrong tx) AND scale/k = scale*4 stays under the max
    /// clamp of 4 (so the preserved region is not legitimately clamped away).
    /// scale ends at 0.78125 * 1.27 = 0.99219; 1024 * that = 1016 > 1000.
    @Test func aNewFrameSizeKeepsTheDocumentRegion() {
        let vp = makeVP()
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 1.27])
        let s0 = state(vp)
        let frameFrac = ((500.0 - s0.tx) / s0.scale) / 1024.0   // doc-relative point at x=500
        vp.invokeMethod("setFrame", withArguments: [256, 256, NSNull()])
        let s1 = state(vp)
        #expect(abs(frameFrac * 256.0 * s1.scale + s1.tx - 500) < 1e-9)
    }

    @Test func resizeStaysAtFitOnlyIfTheUserWasAtFit() {
        let vp = makeVP()
        vp.invokeMethod("setBox", withArguments: [600, 600])
        #expect(abs(state(vp).scale - 600.0 / 1024.0) < 1e-12)   // was at fit: re-fitted
        vp.invokeMethod("zoomAbout", withArguments: [300, 300, 2.0])
        let zoomed = state(vp).scale
        vp.invokeMethod("setBox", withArguments: [1000, 800])
        #expect(state(vp).scale == zoomed)                        // zoomed: scale held
    }

    @Test func panIsClampedToNoDeadSpace() {
        let vp = makeVP()
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 3.0])   // image 2400 CSS px
        vp.invokeMethod("panBy", withArguments: [100000, 100000])
        let s = state(vp)
        #expect(s.tx == 0 && s.ty == 0)                            // top-left limit
        vp.invokeMethod("panBy", withArguments: [-100000, -100000])
        let s2 = state(vp)
        #expect(abs(s2.tx - (1000 - 1024 * s.scale)) < 1e-9)       // bottom-right limit
        #expect(abs(s2.ty - (800 - 1024 * s.scale)) < 1e-9)
    }

    /// When the fitted scale exceeds the 8-device-px cap (a 256 px thumbnail in a
    /// big box), the cap yields to fit: the first zoom-in tick must NOT snap the
    /// view down to the cap. fit = min(1200/256, 1200/256) = 4.6875 > 4.
    @Test func aFitAboveTheZoomCapDoesNotSnapDownOnZoomIn() {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, ex in Issue.record("JS threw: \(ex?.toString() ?? "?")") }
        ctx.evaluateScript(WebUI.viewportJS)
        ctx.evaluateScript("var vp = makeViewport(function () { return 2.0; });")
        let vp = ctx.objectForKeyedSubscript("vp")!
        vp.invokeMethod("setBox", withArguments: [1200, 1200])
        vp.invokeMethod("setFrame", withArguments: [256, 256, NSNull()])
        let fitted = vp.forProperty("state")!.forProperty("scale")!.toDouble()
        #expect(abs(fitted - 4.6875) < 1e-12)
        vp.invokeMethod("zoomAbout", withArguments: [600, 600, 1.5])
        #expect(vp.forProperty("state")!.forProperty("scale")!.toDouble() >= fitted - 1e-12)
    }

    // MARK: - Holding a canvas region while the document's bounds move underneath

    /// The bug this feature exists for. The frame keeps its 1024 px size while the
    /// document's content grows, so the OLD rule saw nothing to do and the picture slid
    /// out from under a zoomed viewer. Two distinct canvas points must stay put, which
    /// pins the translation and the rescale together.
    ///
    /// Numbers chosen so neither clamp can mask a wrong answer: after the zoom the image
    /// is 1016 CSS px against a 1000x800 box (overflowing, so no dead-space re-centring),
    /// and the resulting scale 1.389 is under the 4 cap.
    @Test func aContentRectChangeHoldsTheCanvasRegionWhileZoomed() {
        let vp = makeVP(rect: [0, 0, 500, 500])
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 1.27])
        let before = (a: cssX(vp, canvas: 120, rectX: 0, rectW: 500),
                      b: cssX(vp, canvas: 300, rectX: 0, rectW: 500))

        // A stroke lands up and to the left: the same 1024 pixels now cover more canvas.
        vp.invokeMethod("setFrame", withArguments: [1024, 1024, [-100, -100, 700, 700]])

        #expect(abs(cssX(vp, canvas: 120, rectX: -100, rectW: 700) - before.a) < 1e-9)
        #expect(abs(cssX(vp, canvas: 300, rectX: -100, rectW: 700) - before.b) < 1e-9)
        #expect(!state(vp).atFit)
    }

    /// The other half of the ask: at fit the view SHOULD follow the content.
    @Test func aContentRectChangeRefitsWhileAtFit() {
        let vp = makeVP(rect: [0, 0, 500, 500])
        #expect(state(vp).atFit)
        vp.invokeMethod("setFrame", withArguments: [512, 512, [-100, -100, 700, 700]])
        let s = state(vp)
        #expect(s.atFit)
        #expect(abs(s.scale - 800.0 / 512.0) < 1e-12)   // re-fitted to the new pixel size
        #expect(abs(s.tx - (1000 - 800) / 2) < 1e-9)
    }

    /// A frame that reports no rect cannot be compensated for, so the weaker
    /// frame-pixel rule takes over rather than the viewer inventing a mapping. This is
    /// the live-frame -> stale-thumbnail transition.
    @Test func aFrameWithNoRectFallsBackToTheFrameSizeRule() {
        let vp = makeVP(rect: [0, 0, 500, 500])
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 1.27])
        let s0 = state(vp)
        let frameFrac = ((500.0 - s0.tx) / s0.scale) / 1024.0
        vp.invokeMethod("setFrame", withArguments: [256, 256, NSNull()])
        let s1 = state(vp)
        #expect(abs(frameFrac * 256.0 * s1.scale + s1.tx - 500) < 1e-9)
    }

    /// Content growing far enough asks for a scale past the 8-device-px cap, and the
    /// region genuinely cannot be held. Anchoring on the BOX CENTRE is what makes the
    /// degradation "same middle, wrong zoom" instead of the view sliding sideways —
    /// the reason this is not the algebraic tx += (newX - oldX) * s_c.
    @Test func theBoxCentreSurvivesTheZoomClamp() {
        let vp = makeVP(rect: [0, 0, 500, 500])
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 3.0 / (800.0 / 1024.0)])
        #expect(abs(state(vp).scale - 3.0) < 1e-9)
        let anchor = 250.0   // canvas point under the box centre, by symmetry

        vp.invokeMethod("setFrame", withArguments: [1024, 1024, [0, 0, 2000, 2000]])

        let s = state(vp)
        #expect(abs(s.scale - 4.0) < 1e-12)   // 6.144 / 0.512 = 12, clamped to 8 / dpr
        #expect(abs(cssX(vp, canvas: anchor, rectX: 0, rectW: 2000) - 500) < 1e-9)
    }

    /// A malformed rect must read as ABSENT, not as a rect: dividing by a zero width
    /// would put NaN into scale and blank the viewer for the rest of the session.
    @Test func aDegenerateRectIsTreatedAsAbsent() {
        let vp = makeVP(rect: [0, 0, 500, 500])
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 1.27])
        let before = state(vp)
        vp.invokeMethod("setFrame", withArguments: [1024, 1024, [0, 0, 0, 500]])
        let s = state(vp)
        #expect(s.scale.isFinite && s.tx.isFinite && s.ty.isFinite)
        #expect(abs(s.scale - before.scale) < 1e-12)   // same pixel size, fallback k = 1
    }

    /// Re-sending the SAME frame must not disturb a zoomed view — the page refetches on
    /// every nudge, and a no-op that re-clamped would creep the picture once a second.
    @Test func anUnchangedFrameMovesNothing() {
        let vp = makeVP(rect: [0, 0, 500, 500])
        vp.invokeMethod("zoomAbout", withArguments: [500, 400, 1.27])
        vp.invokeMethod("panBy", withArguments: [-30, -20])
        let before = state(vp)
        vp.invokeMethod("setFrame", withArguments: [1024, 1024, [0, 0, 500, 500]])
        let s = state(vp)
        #expect(s.scale == before.scale && s.tx == before.tx && s.ty == before.ty)
    }
}
#endif
