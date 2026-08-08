import Testing
@testable import InfSketchServerKit

/// The overview page's sortable table: the markup the click handler binds to, and
/// that the page embeds the REAL sort source rather than a copy of it.
@Suite struct WebOverviewSortTests {
    let html = WebUI.indexHTML(connectSection: "")

    @Test func everySortableColumnIsMarkedUp() {
        // The handler binds to `th[data-sort]` and the comparator switches on the
        // same names — a rename on one side alone silently unsorts a column.
        for column in ["name", "sizeBytes", "seq", "subscribers"] {
            #expect(html.contains("data-sort=\"\(column)\""), "missing header for \(column)")
        }
        // The thumbnail column has nothing to sort by and must stay inert.
        #expect(html.contains("<th></th>"))
    }

    @Test func theHeadersAreReachableWithoutAMouse() {
        #expect(html.contains("tabindex=\"0\""))
        #expect(html.contains("aria-sort"))
    }

    @Test func thePageEmbedsTheRealSortSource() {
        // The script parses whether or not this interpolation survives, so pin
        // the embed itself (same reasoning as the viewer page's viewportJS).
        #expect(html.contains(WebUI.tableSortJS))
    }
}

#if canImport(JavaScriptCore)
import JavaScriptCore

extension WebOverviewSortTests {
    /// The whole overview script, parsed (never executed) by a real JS engine —
    /// the syntax gate a script inside a Swift string literal otherwise lacks.
    @Test func theOverviewScriptParses() throws {
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

/// Drives the REAL sort source (`WebUI.tableSortJS`) in a JSContext — the code the
/// browser runs, never a Swift re-derivation of it. The four fixture documents are
/// deliberately awkward: mixed case, a size that sorts differently as text than as
/// a number, a tie on both size and subscriber count, and one offline document
/// whose seq and subscriber count are absent.
@Suite struct TableSortJSTests {
    private func makeSorter() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, ex in Issue.record("JS threw: \(ex?.toString() ?? "?")") }
        ctx.evaluateScript(WebUI.tableSortJS)
        ctx.evaluateScript("""
        var DOCS = [
          { name: "beta",  sizeBytes: 100, seq: 3,    subscriberCount: 1 },
          { name: "Alpha", sizeBytes: 9,   seq: null, subscriberCount: null },
          { name: "gamma", sizeBytes: 50,  seq: 12,   subscriberCount: 2 },
          { name: "delta", sizeBytes: 50,  seq: 7,    subscriberCount: 1 }
        ];
        var s = makeTableSort();
        function click(col, shift) { s.toggle(col, !!shift); }
        function order() { return s.apply(DOCS).map(function (d) { return d.name; }).join(","); }
        """)
        return ctx
    }

    private func eval(_ ctx: JSContext, _ js: String) -> String {
        ctx.evaluateScript(js)?.toString() ?? "<nil>"
    }

    private func order(_ ctx: JSContext) -> String { eval(ctx, "order()") }

    @Test func aPlainClickCyclesAscendingThenDescendingThenOff() {
        let ctx = makeSorter()
        ctx.evaluateScript("click('name')")
        #expect(order(ctx) == "Alpha,beta,delta,gamma")
        #expect(eval(ctx, "s.ariaSort('name')") == "ascending")
        #expect(eval(ctx, "s.indicator('name')") == "▲")   // no rank: it is the only key

        ctx.evaluateScript("click('name')")
        #expect(order(ctx) == "gamma,delta,beta,Alpha")
        #expect(eval(ctx, "s.ariaSort('name')") == "descending")

        ctx.evaluateScript("click('name')")
        #expect(order(ctx) == "beta,Alpha,gamma,delta", "a cleared column returns the server's order")
        #expect(eval(ctx, "s.ariaSort('name')") == "none")
        #expect(eval(ctx, "s.indicator('name')") == "")
    }

    @Test func shiftClickSortsBySubscribersThenName() {
        // The example from the request. Subscribers descending ties beta and delta;
        // the appended name key is what breaks the tie, so flipping it must flip
        // exactly those two and leave the rest alone.
        let ctx = makeSorter()
        ctx.evaluateScript("click('subscribers'); click('subscribers'); click('name', true)")
        #expect(order(ctx) == "gamma,beta,delta,Alpha")
        #expect(eval(ctx, "s.indicator('subscribers')") == "▼1")
        #expect(eval(ctx, "s.indicator('name')") == "▲2")

        ctx.evaluateScript("click('name', true)")
        #expect(order(ctx) == "gamma,delta,beta,Alpha")
        #expect(eval(ctx, "s.indicator('name')") == "▼2")
    }

    @Test func aShiftClickCyclesItsOwnColumnOffWithoutDisturbingTheRest() {
        let ctx = makeSorter()
        ctx.evaluateScript("click('subscribers'); click('name', true); click('name', true); click('name', true)")
        #expect(eval(ctx, "JSON.stringify(s.keys)") == #"[{"column":"subscribers","dir":1}]"#)
    }

    @Test func aPlainClickDropsTheOtherColumns() {
        let ctx = makeSorter()
        ctx.evaluateScript("click('subscribers'); click('name', true); click('sizeBytes')")
        #expect(eval(ctx, "JSON.stringify(s.keys)") == #"[{"column":"sizeBytes","dir":1}]"#)
    }

    @Test func aPlainClickOnAColumnAlreadyInTheSortCyclesIt() {
        // It is the same rule as any other click: the column advances asc -> desc,
        // and dropping the others is all the plain button adds.
        let ctx = makeSorter()
        ctx.evaluateScript("click('subscribers'); click('name', true); click('name')")
        #expect(eval(ctx, "JSON.stringify(s.keys)") == #"[{"column":"name","dir":-1}]"#)
    }

    @Test func missingValuesSortLastInBothDirections() {
        // Alpha is offline: no seq, no subscriber count. "–" is not a small number,
        // it is not a number at all, so it never leads a descending sort.
        let ctx = makeSorter()
        ctx.evaluateScript("click('seq')")
        #expect(order(ctx) == "beta,delta,gamma,Alpha")
        ctx.evaluateScript("click('seq')")
        #expect(order(ctx) == "gamma,delta,beta,Alpha")
    }

    @Test func sizeSortsAsANumberNotAsText() {
        // Lexicographically 100 < 50 < 9 — the answer this must not give.
        let ctx = makeSorter()
        ctx.evaluateScript("click('sizeBytes')")
        #expect(order(ctx) == "Alpha,gamma,delta,beta")
    }

    @Test func equalRowsKeepTheOrderTheServerSent() {
        // gamma and delta are both 50 bytes and appear in that order in DOCS.
        let ctx = makeSorter()
        ctx.evaluateScript("click('sizeBytes')")
        #expect(order(ctx).contains("gamma,delta"))
    }

    @Test func namesSortCaseInsensitivelyAndNumerically() {
        let ctx = makeSorter()
        #expect(eval(ctx, """
        (function () {
          var t = makeTableSort();
          t.toggle("name", false);
          return t.apply([{ name: "Doc 10" }, { name: "Doc 9" }, { name: "doc 2" }])
                  .map(function (d) { return d.name; }).join(",");
        })()
        """) == "doc 2,Doc 9,Doc 10")
    }

    @Test func anUnknownColumnIsIgnored() {
        // The handler reads a data attribute; a typo there must not push a key
        // whose accessor does not exist and throw on every later comparison.
        let ctx = makeSorter()
        ctx.evaluateScript("click('nope')")
        #expect(eval(ctx, "s.keys.length") == "0")
        #expect(order(ctx) == "beta,Alpha,gamma,delta")
    }

    @Test func theReportedKeysCannotBeMutatedFromOutside() {
        let ctx = makeSorter()
        ctx.evaluateScript("click('name'); var k = s.keys; k[0].dir = -1;")
        #expect(order(ctx) == "Alpha,beta,delta,gamma")
    }
}
#endif
