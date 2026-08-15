import Testing
@testable import InfSketchServerKit

/// The block that puts the terminal's scan-to-join information on the page.
///
/// Pure, so all of it is testable with synthetic addresses — the real `LocalAddresses.candidates()`
/// answers whatever the machine running the suite happens to have.
@Suite struct ConnectPanelTests {

    private let wifi = LocalAddress(interface: "en0", ip: "192.168.1.42")
    private let vpn = LocalAddress(interface: "utun4", ip: "10.8.0.3")

    /// The startup tab is localhost, which is no candidate — so the best guess shows, and `ranked`
    /// has already decided which that is.
    @Test(arguments: ["localhost:8080", "127.0.0.1:8080", "not-a-host", nil])
    func anUnknownHostFallsToTheBestGuess(host: String?) {
        #expect(ConnectPanel.selectedIndex(candidates: [wifi, vpn], host: host) == 0)
    }

    /// A page that LOADED over an address has proved that address reaches this server — the same
    /// reasoning `/join` rests on. This is what makes the terminal's `o` key need no state.
    @Test func theHostHeaderSelectsItsOwnAddress() {
        #expect(ConnectPanel.selectedIndex(candidates: [wifi, vpn], host: "10.8.0.3:8080") == 1)
    }

    @Test func theHostMatchesWithoutAPort() {
        #expect(ConnectPanel.selectedIndex(candidates: [wifi, vpn], host: "10.8.0.3") == 1)
    }

    /// Candidates are IPv4, so a bracketed IPv6 literal can never match — and must not be split on
    /// the colons inside it.
    @Test func aBracketedIPv6HostIsNotMisSplit() {
        #expect(ConnectPanel.hostPart(of: "[::1]:8080") == "[::1]")
        #expect(ConnectPanel.selectedIndex(candidates: [wifi], host: "[::1]:8080") == 0)
    }

    @Test func withNoCandidatesThereIsNothingToSelect() {
        #expect(ConnectPanel.selectedIndex(candidates: [], host: "localhost:8080") == nil)
    }

    /// Every candidate is rendered into the page; the chips only change which one is visible. No
    /// round trip, and switching cannot fetch a stale address.
    @Test func everyCandidateGetsItsOwnCodeAndAgentUrl() {
        let html = ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: nil)
        #expect(html.components(separatedBy: "<svg").count - 1 == 2)
        #expect(html.contains("http://192.168.1.42:8080/mcp"))
        #expect(html.contains("http://10.8.0.3:8080/mcp"))
        #expect(html.contains("192.168.1.42:8080"))
        #expect(html.contains("10.8.0.3:8080"))
        #expect(html.contains("en0"))
        #expect(html.contains("utun4"))
    }

    @Test func onlyTheSelectedAddressIsVisible() {
        let html = ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: "10.8.0.3:8080")
        #expect(html.contains("<div class=\"address\" data-index=\"0\" hidden>"))
        #expect(html.contains("<div class=\"address\" data-index=\"1\">"))
    }

    /// One address is one address: there is nothing to switch to, so the chips are not drawn.
    @Test func chipsAppearOnlyWhenThereIsSomethingToSwitchTo() {
        #expect(!ConnectPanel.html(candidates: [wifi], port: 8080, host: nil)
            .contains("class=\"chip"))
        #expect(ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: nil)
            .contains("class=\"chip"))
    }

    /// The terminal's own fallback, on the page: say why there is no code, and still give the one
    /// url that does work here — an agent on this machine needs no network address.
    @Test func withNoAddressesTheFallbackStillCarriesTheLoopbackAgentUrl() {
        let html = ConnectPanel.html(candidates: [], port: 8080, host: nil)
        #expect(html.contains("http://127.0.0.1:8080/mcp"))
        #expect(html.lowercased().contains("no reachable network address"))
        #expect(!html.contains("<svg"))
    }

    /// Interface names come from the operating system, but they reach the page's text, and
    /// `JoinPage` sets the precedent for escaping everything that does.
    @Test func interfaceNamesAreEscaped() {
        let odd = LocalAddress(interface: "en<0>&\"x\"", ip: "192.168.1.42")
        let html = ConnectPanel.html(candidates: [odd], port: 8080, host: nil)
        #expect(!html.contains("en<0>"))
        #expect(html.contains("en&lt;0&gt;&amp;"))
    }

    /// `display: flex` on `.address` OUTRANKS the browser's own `[hidden] { display: none }`, so
    /// without an explicit rule every address renders at once and the chips appear to do nothing —
    /// which is what shipped for one commit, invisible to every assertion above, because the markup
    /// was already correct. A test cannot render CSS; it can insist the rule is there.
    @Test func hiddenIsRestatedForTheFlexLayout() {
        let html = ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: nil)
        #expect(html.contains(".address[hidden] { display: none; }"))
    }

    /// The copy button must survive a page that is NOT a secure context — plain http to a LAN
    /// address, which is exactly what this page is — where `navigator.clipboard` is undefined.
    @Test func theCopyButtonHasAFallbackPath() {
        let html = ConnectPanel.html(candidates: [wifi], port: 8080, host: nil)
        #expect(html.contains("navigator.clipboard"))
        #expect(html.contains("selectNodeContents"), "no fallback for a non-secure context")
    }

    /// The page carries the same connect information the terminal prints, and the terminal prints
    /// BOTH agent addresses — an agent on this machine needs no network address at all.
    @Test func theLoopbackAgentUrlIsOffered() {
        let html = ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: nil)
        #expect(html.contains("http://127.0.0.1:8080/mcp"))
    }

    /// It must sit OUTSIDE the `.address` blocks the chips hide and show: loopback does not depend
    /// on which network address is selected, so hiding it with one would make it vanish for every
    /// address but the first — invisible to an assertion that only asks whether the url appears.
    @Test func theLoopbackAgentUrlIsNotInsideASwitchableAddressBlock() throws {
        let html = ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: nil)
        let loopback = try #require(html.range(of: "http://127.0.0.1:8080/mcp"))
        // Every address block is balanced, so at any point OUTSIDE them the opened and closed
        // `div`s match; anywhere INSIDE one, an open is still outstanding. (The inline QR is SVG
        // and contributes no `div`s.) Asserting only that the url appears would pass with the
        // line nested in the first block, where the chips would hide it for every other address.
        let prefix = html[html.startIndex..<loopback.lowerBound]
        let opened = prefix.components(separatedBy: "<div").count - 1
        let closed = prefix.components(separatedBy: "</div>").count - 1
        #expect(opened == closed, "loopback url sits inside \(opened - closed) unclosed div(s)")
    }

    /// One address means no chips at all — and the loopback url must still be there, since it is
    /// the only one that works when the single candidate is unreachable from the phone.
    @Test func theLoopbackAgentUrlSurvivesASingleCandidate() {
        let html = ConnectPanel.html(candidates: [wifi], port: 8080, host: nil)
        #expect(!html.contains("class=\"chips\""))
        #expect(html.contains("http://127.0.0.1:8080/mcp"))
    }

    // MARK: - the Claude Code registration command

    /// The page shows the COMMAND, not only the url — one per agent url, each embedding ITS url,
    /// rendered from the same `AddressPicker` source the terminal prints.
    @Test func theClaudeCommandIsShownForEveryAgentUrl() {
        let html = ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: nil)
        #expect(html.contains(
            AddressPicker.claudeRegisterCommand(mcpURL: "http://192.168.1.42:8080/mcp")))
        #expect(html.contains(
            AddressPicker.claudeRegisterCommand(mcpURL: "http://10.8.0.3:8080/mcp")))
        #expect(html.contains(
            AddressPicker.claudeRegisterCommand(mcpURL: "http://127.0.0.1:8080/mcp")))
    }

    /// The caveat appears ONCE, under the loopback block — not repeated per address.
    @Test func theClaudeNoteAppearsExactlyOnce() {
        let html = ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: nil)
        #expect(html.components(separatedBy: AddressPicker.claudeExampleNote).count - 1 == 1)
    }

    /// A ~90-character command must WRAP rather than widen the panel on a narrow window. A test
    /// cannot render CSS; it can insist the rule is there (the `.address[hidden]` precedent).
    @Test func theCommandCodeWraps() {
        let html = ConnectPanel.html(candidates: [wifi], port: 8080, host: nil)
        #expect(html.contains("overflow-wrap: anywhere"))
    }

    /// The no-address fallback mirrors the terminal's: loopback url AND the command. (No copy
    /// button there — that body ships without the behaviour script, and a dead button is worse
    /// than none.)
    @Test func theNoAddressFallbackCarriesTheCommandToo() {
        let html = ConnectPanel.html(candidates: [], port: 8080, host: nil)
        #expect(html.contains(
            AddressPicker.claudeRegisterCommand(mcpURL: "http://127.0.0.1:8080/mcp")))
    }

    /// Every copy button must point at an id that exists, or it silently copies nothing.
    @Test func everyCopyButtonTargetsAnExistingId() {
        let html = ConnectPanel.html(candidates: [wifi, vpn], port: 8080, host: nil)
        for target in ["mcp-0", "mcp-1", "mcp-local", "cmd-0", "cmd-1", "cmd-local"] {
            #expect(html.contains("id=\"\(target)\""), "missing element \(target)")
            #expect(html.contains("data-target=\"\(target)\""), "missing button for \(target)")
        }
    }
}
