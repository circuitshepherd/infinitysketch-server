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
        // One mark span per sortable header: `render` writes into every one it finds
        // by `th.querySelector(".sortmark")`, so a header missing its span throws
        // there and takes the whole table down. (The span leads on right-aligned
        // headers and trails on the others — either way there is exactly one.)
        #expect(html.components(separatedBy: "class=\"sortmark\"").count
            == html.components(separatedBy: "data-sort=").count)
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

    @Test func thePageOpensAtTheDefaultSort() {
        // Argument-less: whatever DEFAULT_SORT is, that is what the page starts at.
        // Passing [] here would open unsorted with every JS test still green.
        #expect(html.contains("makeTableSort();"))
    }

    @Test func theSortIsNotPersistedAcrossAReload() {
        // "A reload restores the default" is a property of storing the sort NOWHERE
        // but the page's own variable — there is nothing else to assert against.
        // The dot is what makes these USES rather than the word in a comment; the
        // viewer page persists its own preferences this way, this one must not.
        for store in ["localStorage.", "sessionStorage.", "document.cookie", "indexedDB."] {
            #expect(!html.contains(store), "the sort must not survive a reload via \(store)")
        }
    }

    @Test func theSortMarkSitsInAFixedWidthSlot() throws {
        // The mark grows and shrinks with the sort ("" -> ▲ -> ▼2) and the table is
        // auto-layout, so without a fixed box a click re-measures the column under it
        // and the whole table shifts. Pin the two declarations that make it fixed.
        let start = try #require(html.range(of: ".sortmark {"))
        let end = try #require(html.range(of: "}", range: start.upperBound..<html.endIndex))
        let rule = String(html[start.lowerBound..<end.upperBound])
        #expect(rule.contains("display: inline-block"), "not a box: \(rule)")
        #expect(rule.contains("width: "), "no reserved width: \(rule)")
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
        // [] — the click-cycle tests drive every state from a known unsorted start,
        // so they keep testing the cycle and not whatever the default happens to be.
        var s = makeTableSort([]);
        function click(col, shift) { s.toggle(col, !!shift); }
        function names(t) { return t.apply(DOCS).map(function (d) { return d.name; }).join(","); }
        function order() { return names(s); }
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

    @Test func theDefaultIsSubscribersDescendingThenName() {
        // The table opens on who is being looked at, then alphabetical: gamma has 2
        // subscribers, beta and delta tie at 1 and are broken by name, and offline
        // Alpha has none at all, which sorts last in both directions.
        let ctx = makeSorter()
        #expect(eval(ctx, "JSON.stringify(makeTableSort().keys)")
            == #"[{"column":"subscribers","dir":-1},{"column":"name","dir":1}]"#)
        #expect(eval(ctx, "names(makeTableSort())") == "gamma,beta,delta,Alpha")
    }

    @Test func aFreshSorterCannotInheritAnEarlierOnesClicks() {
        // `toggle` mutates its key objects in place, so a DEFAULT_SORT handed out by
        // reference would let one page's click rewrite the default for the next.
        let ctx = makeSorter()
        ctx.evaluateScript("var a = makeTableSort(); a.toggle('name'); a.toggle('subscribers', true);")
        #expect(eval(ctx, "JSON.stringify(makeTableSort().keys)")
            == #"[{"column":"subscribers","dir":-1},{"column":"name","dir":1}]"#)
    }

    @Test func namesSortCaseInsensitivelyAndNumerically() {
        let ctx = makeSorter()
        #expect(eval(ctx, """
        (function () {
          var t = makeTableSort([]);
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
