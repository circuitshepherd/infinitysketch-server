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

    /// The copy button must survive a page that is NOT a secure context — plain http to a LAN
    /// address, which is exactly what this page is — where `navigator.clipboard` is undefined.
    @Test func theCopyButtonHasAFallbackPath() {
        let html = ConnectPanel.html(candidates: [wifi], port: 8080, host: nil)
        #expect(html.contains("navigator.clipboard"))
        #expect(html.contains("selectNodeContents"), "no fallback for a non-secure context")
    }
}
