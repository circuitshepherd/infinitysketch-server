import Testing
@testable import InfSketchServerKit

/// Scanning helpers shared by the web-page suites.
///
/// **Comments are stripped first, and that is load-bearing in both directions.** A `/* … */`
/// explaining `var(--fg)` is not a usage, and a `//` note mentioning an API by name is not a call —
/// without stripping, the prose written to explain a rule is what breaks the test enforcing it.
/// Both happened while writing these suites.
enum WebPageScan {

    /// `html` with CSS block comments and JS line comments removed.
    static func stripComments(_ html: String) -> String {
        var out = ""
        let chars = Array(html)
        var i = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                continue
            }
            // A "//" inside a string literal (a URL's scheme) must survive, so only a comment
            // that starts a line — after nothing but whitespace — is stripped.
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/",
               Self.onlyWhitespaceSinceLineStart(chars, before: i) {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func onlyWhitespaceSinceLineStart(_ chars: [Character], before index: Int) -> Bool {
        var k = index - 1
        while k >= 0, chars[k] != "\n" {
            if !chars[k].isWhitespace { return false }
            k -= 1
        }
        return true
    }

    /// Every `var(…)` argument list, with parentheses balanced so an `rgba(…)` fallback does not
    /// terminate the match early. Comments are stripped first.
    static func varCalls(in css: String) -> [String] {
        var found: [String] = []
        let chars = Array(stripComments(css))
        let needle = Array("var(")
        var i = 0
        while i + needle.count <= chars.count {
            guard Array(chars[i..<(i + needle.count)]) == needle else { i += 1; continue }
            var depth = 1
            var j = i + needle.count
            var body = ""
            while j < chars.count, depth > 0 {
                if chars[j] == "(" { depth += 1 }
                if chars[j] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(chars[j])
                j += 1
            }
            found.append(body)
            i = j
        }
        return found
    }

    /// The custom property a `var()` body names, e.g. `--fg` from `--fg, gray`.
    static func propertyName(of body: String) -> String {
        String(body.split(separator: ",", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the body carries a fallback after a TOP-LEVEL comma — a comma inside `rgba(…)`
    /// does not count.
    static func hasFallback(_ body: String) -> Bool {
        var depth = 0
        for c in body {
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if c == ",", depth == 0 { return true }
        }
        return false
    }

    /// The custom properties a CSS string DEFINES (`--name:` at a declaration position).
    static func definedProperties(in css: String) -> Set<String> {
        var names: Set<String> = []
        for line in stripComments(css).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--"), let colon = trimmed.firstIndex(of: ":") else { continue }
            names.insert(String(trimmed[trimmed.startIndex..<colon]))
        }
        return names
    }
}

/// The shared-style contract across every server web page.
///
/// The load-bearing test here is `noPageUsesAnUndefinedCustomProperty`. An undefined custom
/// property is **not a CSS error** — `var(--typo)` with no fallback resolves to nothing and the
/// declaration is dropped, so a misspelled token reaches a browser with nothing failing anywhere:
/// no build error, no console warning, just a colour that quietly is not there. Nor can the
/// existing HTML-marker tests see it. This suite is the only gate on that class of mistake.
@Suite struct WebStyleTests {

    // MARK: - the pages under test

    static let connectSection = ConnectPanel.html(
        candidates: [LocalAddress(interface: "en0", ip: "192.168.1.42")],
        port: 8080,
        host: "192.168.1.42:8080")

    /// Every surface that is supposed to carry the shared look, by name for failure messages.
    static let pages: [(name: String, html: String)] = [
        ("overview", WebUI.indexHTML(connectSection: connectSection)),
        ("viewer", WebUI.docHTML(docId: "Doc & Co")),
        ("join", JoinPage.html(host: "192.168.1.42:8080")),
    ]

    /// The properties `WebStyle.tokens` actually defines.
    static let definedTokens = WebPageScan.definedProperties(in: WebStyle.tokens)

    // MARK: - tests

    @Test func theTokensDefineTheExpectedVocabulary() {
        // A rename here is a real decision; every page reads these names.
        for name in ["--font", "--font-mono", "--bg", "--surface", "--stage", "--fg", "--fg-dim",
                     "--line", "--accent", "--live", "--bar", "--radius"] {
            #expect(Self.definedTokens.contains(name), "tokens no longer define \(name)")
        }
    }

    @Test func everyPageEmbedsTheTokens() {
        for page in Self.pages {
            #expect(page.html.contains(WebStyle.tokens), "\(page.name) does not embed WebStyle.tokens")
        }
    }

    @Test func noPageUsesAnUndefinedCustomProperty() {
        for page in Self.pages {
            for body in WebPageScan.varCalls(in: page.html) {
                let name = WebPageScan.propertyName(of: body)
                #expect(Self.definedTokens.contains(name),
                        "\(page.name) reads \(name), which WebStyle.tokens does not define")
            }
        }
    }

    @Test func everyColourIsDefinedOutsideTheDarkMediaQuery() throws {
        // A colour whose ONLY definition sits inside `@media (prefers-color-scheme: dark)` is
        // absent in light mode, where `var()` then silently yields its fallback or nothing.
        let marker = "@media (prefers-color-scheme: dark)"
        let split = try #require(WebStyle.tokens.range(of: marker))
        let light = String(WebStyle.tokens[WebStyle.tokens.startIndex..<split.lowerBound])
        let lightNames = WebPageScan.definedProperties(in: light)
        for name in Self.definedTokens {
            #expect(lightNames.contains(name),
                    "\(name) is defined only in the dark block — it is absent in light mode")
        }
    }

    @Test func theConnectPanelStillRendersStandalone() {
        // Its header comment promises the style travels with the markup. Sharing tokens weakens
        // that to "degrades gracefully", which holds only while every var() has a fallback.
        for body in WebPageScan.varCalls(in: Self.connectSection) {
            #expect(WebPageScan.hasFallback(body),
                    "#connect reads var(\(body)) with no fallback — the panel no longer renders alone")
        }
    }

    @Test func theConnectPanelKeepsItsTwoTraps() {
        // Both are documented in ConnectPanel and both fail silently if lost: `display: flex`
        // outranks the browser's own `[hidden] { display: none }`, and an inverted QR code in
        // dark mode is one most scanners refuse.
        #expect(Self.connectSection.contains("#connect .address[hidden]"))
        #expect(Self.connectSection.contains("#connect .qr { background: #fff"))
    }
}
