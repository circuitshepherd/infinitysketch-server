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

    /// The store link sits beside the silent-failure note, which is exactly where a device that
    /// cannot open the scheme ends up. The id matches the app's own review links.
    @Test func thePageOffersTheAppStore() {
        let html = JoinPage.html(host: "h")
        #expect(html.contains("https://apps.apple.com/app/id6736661584"))
        #expect(html.localizedCaseInsensitiveContains("App Store"))
    }

    /// The join link must stay the DOMINANT action: the store is a fallback for a device that does
    /// not have the app, so it may not be presented first.
    @Test func theJoinLinkComesBeforeTheStoreLink() throws {
        let html = JoinPage.html(host: "h")
        let join = try #require(html.range(of: "infinitysketch://join"))
        let store = try #require(html.range(of: "apps.apple.com"))
        #expect(join.lowerBound < store.lowerBound)
    }

    /// The host arrives from the network and reaches both an href and the page's text.
    @Test func theHostIsEscaped() {
        let html = JoinPage.html(host: "\"><script>alert(1)</script>")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }
}
