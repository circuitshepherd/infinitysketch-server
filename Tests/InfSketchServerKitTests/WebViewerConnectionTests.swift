#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import Testing
@testable import InfSketchServerKit

/// Runs the viewer page's REAL script in a JSContext against a stub DOM, a scripted WebSocket
/// and a scripted `fetch`, and drives the connection and frame-fetch paths review findings 24
/// and 25 were about: nothing on the page may assume the socket either works or closes
/// cleanly, and no browser is driven to check it. The stubs are deliberately dumb — every
/// socket, fetch, image and timer is recorded, and the test decides when each one answers.
@Suite struct WebViewerConnectionTests {
    /// The stub world. Elements are proxies that accept any method call, so the page's
    /// layout and input code runs without a line of it being stubbed by name.
    static let harness = #"""
    var timers = [];
    function setTimeout(f, ms) { timers.push({ f: f, ms: ms }); return timers.length; }
    function clearTimeout(id) { if (id && timers[id - 1]) timers[id - 1].f = null; }
    function setInterval() { return 0; }
    // Runs every pending timer whose delay is `ms` (once each; a timer it schedules waits).
    function fireTimers(ms) {
      const due = timers.filter((t) => t.f && t.ms === ms);
      for (const t of due) { const f = t.f; t.f = null; f(); }
    }

    var sockets = [];
    function WebSocket(url) { this.sent = []; this.readyState = 0; sockets.push(this); }
    WebSocket.OPEN = 1;
    WebSocket.prototype.send = function (d) { this.sent.push(JSON.parse(d)); };
    WebSocket.prototype.close = function () { this.closedByPage = true; this.readyState = 3; };
    function openSocket(s) { s.readyState = 1; s.onopen(); }
    function serverSays(s, m) { s.onmessage({ data: JSON.stringify(m) }); }
    function sentTypes(s) { return s.sent.map((m) => m.type).join(","); }

    var fetches = [];
    function fetch(url, opts) {
      return new Promise((resolve, reject) => fetches.push({ url: url, resolve: resolve, reject: reject }));
    }
    function answerFetch(i) {
      fetches[i].resolve({ ok: true, headers: { get() { return null; } },
                           blob() { return Promise.resolve({ n: i }); } });
    }

    var images = [];
    function Image() { images.push(this); this.naturalWidth = 100; this.naturalHeight = 100; }
    var URL = { createObjectURL(b) { return "blob:" + b.n; }, revokeObjectURL() {} };
    function ResizeObserver() { this.observe = function () {}; }

    function el() {
      const o = { style: {}, dataset: {}, textContent: "", className: "", title: "",
                  clientWidth: 800, clientHeight: 600,
                  classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
                  getBoundingClientRect() { return { left: 0, top: 0, width: 800, height: 600 }; } };
      return new Proxy(o, { get(t, k) { return k in t ? t[k] : function () {}; } });
    }
    var elements = {};
    var document = { hidden: false, body: el(), documentElement: el(),
                     getElementById(id) { return elements[id] || (elements[id] = el()); },
                     addEventListener() {}, querySelectorAll() { return []; },
                     createElement() { return el(); } };
    var window = { devicePixelRatio: 1, addEventListener() {} };
    var reloads = 0;
    var location = { host: "h", reload() { reloads += 1; } };
    var localStorage = { getItem() { return null; }, setItem() {}, removeItem() {} };
    var stored = {};
    var sessionStorage = { getItem(k) { return k in stored ? stored[k] : null; },
                           setItem(k, v) { stored[k] = String(v); } };
    """#

    /// A context with the harness loaded and the page's script run, as a browser would at load.
    private func loadPage(docId: String = "Doc") throws -> JSContext {
        try load(WebUI.docHTML(docId: docId))
    }

    private func load(_ html: String) throws -> JSContext {
        let start = try #require(html.range(of: "<script>"))
        let end = try #require(html.range(of: "</script>"))
        let script = String(html[start.upperBound..<end.lowerBound])
        let ctx = try #require(JSContext())
        ctx.exceptionHandler = { _, ex in Issue.record("JS: \(ex?.toString() ?? "?")") }
        ctx.evaluateScript(Self.harness)
        ctx.evaluateScript(script)
        return ctx
    }

    private func js(_ ctx: JSContext, _ source: String) -> String {
        ctx.evaluateScript(source)?.toString() ?? "undefined"
    }

    private func badge(_ ctx: JSContext) -> String {
        js(ctx, "updateBadge(); elements.badge.textContent")
    }

    /// One fetch in flight however many nudges arrive, then ONE trailing fetch for all of
    /// them — and nothing more once that one lands with no nudge behind it.
    @Test func framesAreFetchedOneAtATimeWithOneTrailingFetch() throws {
        let ctx = try loadPage()
        #expect(js(ctx, "fetches.length") == "1")                 // the load's own fetch
        js(ctx, "openSocket(sockets[0]); serverSays(sockets[0], { type: 'helloAck', protocolVersion: 12, serverId: 's' })")
        for seq in 1...3 {
            js(ctx, "serverSays(sockets[0], { type: 'frameAvailable', docId: 'Doc', seq: \(seq) })")
        }
        #expect(js(ctx, "fetches.length") == "1", "a nudge started a second concurrent fetch")

        js(ctx, "answerFetch(0)")
        js(ctx, "images[0].onload()")
        #expect(js(ctx, "elements.frame.src") == "blob:0")
        #expect(js(ctx, "fetches.length") == "2", "the nudges during the fetch were not served")

        js(ctx, "answerFetch(1)")
        js(ctx, "images[1].onload()")
        #expect(js(ctx, "elements.frame.src") == "blob:1")
        #expect(js(ctx, "fetches.length") == "2")
    }

    /// A failed fetch releases the loader too, or one error would stop the page for good.
    @Test func aFailedFetchDoesNotStopLaterOnes() throws {
        let ctx = try loadPage()
        js(ctx, "openSocket(sockets[0])")
        js(ctx, "fetches[0].reject(new Error('network'))")
        js(ctx, "serverSays(sockets[0], { type: 'frameAvailable', docId: 'Doc', seq: 1 })")
        #expect(js(ctx, "fetches.length") == "2")
    }

    /// After a reconnect the page fetches the current frame itself (finding 24) and says
    /// "connected" only once the server has ACCEPTED the hello, not when the socket opens.
    @Test func aReconnectRefetchesAndIsLiveOnlyAfterTheHelloAck() throws {
        let ctx = try loadPage()
        js(ctx, "answerFetch(0)")
        js(ctx, "images[0].onload()")  // a separate turn: the image is made in a microtask
        js(ctx, "openSocket(sockets[0]); serverSays(sockets[0], { type: 'helloAck', protocolVersion: 12, serverId: 's' })")
        #expect(js(ctx, "fetches.length") == "2")
        js(ctx, "answerFetch(1)")
        js(ctx, "images[1].onload()")  // a separate turn: the image is made in a microtask

        js(ctx, "sockets[0].onclose()")
        #expect(badge(ctx) == "disconnected — retrying…")
        js(ctx, "fireTimers(2000)")
        #expect(js(ctx, "sockets.length") == "2")
        js(ctx, "openSocket(sockets[1])")
        #expect(js(ctx, "sentTypes(sockets[1])") == "hello,watchDoc")
        #expect(js(ctx, "fetches.length") == "3", "the reconnect did not fetch the current frame")
        #expect(badge(ctx) == "disconnected — retrying…", "an open socket read as connected before helloAck")
        js(ctx, "serverSays(sockets[1], { type: 'helloAck', protocolVersion: 12, serverId: 's' })")
        #expect(badge(ctx) != "disconnected — retrying…")
    }

    /// A deleted or renamed document: the page says so and asks again on a slow timer
    /// instead of sitting on the old frame for good; a frame arriving clears the message.
    @Test func anUnknownDocIsShownAndRewatchedOnASlowTimer() throws {
        let ctx = try loadPage()
        js(ctx, "openSocket(sockets[0]); serverSays(sockets[0], { type: 'helloAck', protocolVersion: 12, serverId: 's' })")
        js(ctx, "serverSays(sockets[0], { type: 'error', reason: 'unknownDoc' })")
        #expect(badge(ctx) == "Document not found (deleted or renamed)")
        #expect(js(ctx, "sentTypes(sockets[0])") == "hello,watchDoc")
        js(ctx, "fireTimers(10000)")
        #expect(js(ctx, "sentTypes(sockets[0])") == "hello,watchDoc,watchDoc")
        js(ctx, "serverSays(sockets[0], { type: 'frameAvailable', docId: 'Doc', seq: 1 })")
        #expect(badge(ctx) != "Document not found (deleted or renamed)")
    }

    /// A server upgraded under the page refuses its hello forever; the page reloads to get
    /// the new server's page — once. A second refusal inside the minute shows a message
    /// instead of reloading again, so a server refusing its own page cannot loop the tab.
    @Test func aVersionRefusalReloadsAtMostOncePerMinute() throws {
        let ctx = try loadPage()
        js(ctx, "openSocket(sockets[0])")
        js(ctx, "serverSays(sockets[0], { type: 'error', reason: 'unsupportedVersion:13' })")
        #expect(js(ctx, "reloads") == "1")
        // What a reload would bring back is a fresh page in the same tab: sessionStorage stays.
        js(ctx, "serverSays(sockets[0], { type: 'error', reason: 'unsupportedVersion:13' })")
        #expect(js(ctx, "reloads") == "1", "a second refusal reloaded again")
        #expect(badge(ctx) == "server was updated — reload the page")
        js(ctx, "sockets[0].onclose()")
        #expect(badge(ctx) == "server was updated — reload the page")
    }

    @Test func withNoStorageAVersionRefusalNeverReloads() throws {
        let ctx = try loadPage()
        js(ctx, "sessionStorage.setItem = function () { throw new Error('denied'); }")
        js(ctx, "openSocket(sockets[0])")
        js(ctx, "serverSays(sockets[0], { type: 'error', reason: 'unsupportedVersion:13' })")
        #expect(js(ctx, "reloads") == "0")
    }

    /// A socket silent past the limit is abandoned and replaced AT ONCE — its handlers
    /// detached first, since a dead socket's closing handshake can take minutes and its
    /// late `onclose` would otherwise start a second reconnect.
    @Test func aSilentSocketIsReplacedAtOnce() throws {
        let ctx = try loadPage()
        js(ctx, "openSocket(sockets[0]); serverSays(sockets[0], { type: 'helloAck', protocolVersion: 12, serverId: 's' })")
        js(ctx, "closeIfSilent()")
        #expect(js(ctx, "sockets.length") == "1", "a healthy socket was dropped")

        js(ctx, "lastMessageAt = Date.now() - 61000; closeIfSilent()")
        #expect(js(ctx, "sockets[0].closedByPage") == "true")
        #expect(js(ctx, "sockets[0].onclose === null && sockets[0].onmessage === null") == "true")
        #expect(js(ctx, "sockets.length") == "2", "the reconnect waited for the dead socket")
        #expect(badge(ctx) == "disconnected — retrying…")
    }

    /// A document name that is also markup — `<!--` opens the HTML parser's script-escape
    /// state, `</script>` ends the element — must reach the script as the plain string it is,
    /// with the whole script intact (finding 25: such a name left a page on which no code ran).
    @Test func aDocumentNamedLikeMarkupKeepsTheScriptIntact() throws {
        for name in ["<!--<script>", "</script><script>alert(1)</script>", "a & b > c"] {
            let html = WebUI.docHTML(docId: name)
            let start = try #require(html.range(of: "<script>"))
            let end = try #require(html.range(of: "</script>"))
            let script = String(html[start.upperBound..<end.lowerBound])
            #expect(!script.contains("<!--"), "\(name): the script carries a comment opener")
            #expect(script.contains("connect();"), "\(name): the script was cut short")
            let ctx = try loadPage(docId: name)
            #expect(js(ctx, "docId") == name)
        }
    }

    /// The overview: a (re)connect resyncs the table (status events missed while the socket
    /// was down are gone), a failed load is retried instead of leaving the table empty, and
    /// "live" waits for the server to accept the hello.
    @Test func theOverviewResyncsOnReconnectAndRetriesAFailedLoad() throws {
        let ctx = try load(WebUI.indexHTML(connectSection: ""))
        #expect(js(ctx, "fetches.length") == "1")                 // the load's own refresh
        js(ctx, "fetches[0].reject(new Error('network'))")
        js(ctx, "fireTimers(2000)")
        #expect(js(ctx, "fetches.length") == "2", "a failed load was not retried")
        js(ctx, "fetches[1].resolve({ ok: true, json() { return Promise.resolve([{ id: 'a', name: 'a' }]); } })")

        js(ctx, "openSocket(sockets[0])")
        #expect(js(ctx, "elements.status.textContent") != "live")
        js(ctx, "serverSays(sockets[0], { type: 'helloAck', protocolVersion: 12, serverId: 's' })")
        #expect(js(ctx, "elements.status.textContent") == "live")
        js(ctx, "fireTimers(300)")
        #expect(js(ctx, "fetches.length") == "3", "a connect did not resync the table")

        js(ctx, "sockets[0].onclose()")
        js(ctx, "fireTimers(2000)")
        js(ctx, "openSocket(sockets[1])")
        js(ctx, "fireTimers(300)")
        #expect(js(ctx, "fetches.length") == "4", "a reconnect did not resync the table")
    }
}
#endif
