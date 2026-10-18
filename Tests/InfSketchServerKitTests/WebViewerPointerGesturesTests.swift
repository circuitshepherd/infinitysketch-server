#if canImport(JavaScriptCore)
import JavaScriptCore
import Testing
@testable import InfSketchServerKit

/// Drives the REAL pointer source (`WebUI.pointerGesturesJS`) in a JSContext.
@Suite struct WebViewerPointerGesturesTests {
    private func makeGestures() -> JSValue {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, ex in Issue.record("JS threw: \(ex?.toString() ?? "?")") }
        ctx.evaluateScript(WebUI.pointerGesturesJS)
        ctx.evaluateScript("var g = makePointerGestures();")
        return ctx.objectForKeyedSubscript("g")!
    }

    private func down(_ g: JSValue, _ id: Int, _ x: Double, _ y: Double) {
        g.invokeMethod("down", withArguments: [id, x, y])
    }

    private func move(_ g: JSValue, _ id: Int, _ x: Double, _ y: Double)
        -> (dx: Double, dy: Double, ratio: Double?)? {
        let r = g.invokeMethod("move", withArguments: [id, x, y])!
        if r.isNull || r.isUndefined { return nil }
        let zoom = r.forProperty("zoom")!
        return (r.forProperty("dx")!.toDouble(), r.forProperty("dy")!.toDouble(),
                zoom.isNull ? nil : zoom.forProperty("ratio")!.toDouble())
    }

    @Test func oneFingerPansByItsOwnMovement() throws {
        let g = makeGestures()
        down(g, 1, 100, 100)
        let m = try #require(move(g, 1, 110, 95))
        #expect(m.dx == 10 && m.dy == -5 && m.ratio == nil)
    }

    @Test func twoFingersPanByTheMidpointAndZoomByTheSpread() throws {
        let g = makeGestures()
        down(g, 1, 100, 100)
        down(g, 2, 200, 100)
        let m = try #require(move(g, 2, 300, 100))
        #expect(m.dx == 50 && m.dy == 0)
        #expect(m.ratio == 2)
    }

    /// Two fingers down, a third touches, the two move while it rests, the third lifts: the next
    /// move must pan and zoom by THAT move only. The reference used to be taken only on a press,
    /// so it still held the positions from before the third finger came down.
    @Test func liftingAThirdFingerReseedsThePinch() throws {
        let g = makeGestures()
        down(g, 1, 100, 100)
        down(g, 2, 200, 100)
        down(g, 3, 150, 300)
        #expect(move(g, 1, 400, 400) == nil)   // three pointers: no gesture
        #expect(move(g, 2, 600, 400) == nil)
        g.invokeMethod("up", withArguments: [3])
        let m = try #require(move(g, 2, 601, 400))
        #expect(m.dx == 0.5 && m.dy == 0)
        #expect(abs((m.ratio ?? 0) - 201.0 / 200.0) < 1e-12)
    }

    @Test func liftingOneOfTwoLeavesAOneFingerPanFromWhereItIs() throws {
        let g = makeGestures()
        down(g, 1, 100, 100)
        down(g, 2, 200, 100)
        _ = move(g, 2, 250, 100)
        g.invokeMethod("up", withArguments: [2])
        let m = try #require(move(g, 1, 103, 100))
        #expect(m.dx == 3 && m.ratio == nil)
    }

    @Test func upReturnsTheStartPointForTheTapTest() {
        let g = makeGestures()
        down(g, 7, 40, 50)
        _ = move(g, 7, 45, 52)
        let p = g.invokeMethod("up", withArguments: [7])!
        #expect(p.forProperty("startX")!.toDouble() == 40)
        #expect(g.forProperty("size")!.toInt32() == 0)
        #expect(g.invokeMethod("up", withArguments: [7])!.isNull)
    }
}
#endif
