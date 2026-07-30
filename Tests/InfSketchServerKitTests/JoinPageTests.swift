import Testing
@testable import InfSketchServerKit

/// The page that hands this server's address to the app.
@Suite struct JoinPageTests {

    /// The link carries the Host header VERBATIM, port included. That is the safety property of the
    /// whole design: if the device loaded this page, the address it used is reachable from the
    /// device, so a mis-guessed interface cannot produce a link that half-works.
    @Test func theLinkCarriesTheHostTheDeviceActuallyReached() {
        let html = JoinPage.html(host: "192.168.1.42:18551")
        #expect(html.contains("infinitysketch://join?address=192.168.1.42:18551"))
    }

    /// The page states the effect before the tap, because the app deliberately does not ask again —
    /// this IS the confirmation.
    @Test func thePageStatesTheEffectBeforeTheTap() {
        let html = JoinPage.html(host: "10.0.0.5:8080")
        #expect(html.contains("10.0.0.5:8080"))
        #expect(html.localizedCaseInsensitiveContains("syncing on"))
    }

    /// …and says what to do when nothing happens, which is the case a user cannot diagnose alone.
    @Test func thePageExplainsTheSilentFailure() {
        #expect(JoinPage.html(host: "h").localizedCaseInsensitiveContains("isn't installed"))
    }

    /// The host arrives from the network and reaches both an href and the page's text.
    @Test func theHostIsEscaped() {
        let html = JoinPage.html(host: "\"><script>alert(1)</script>")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }
}
