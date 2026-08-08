import Foundation

/// The page a scanned QR code lands on.
///
/// It exists because **Apple documents nothing about which URL types the iOS Camera app will act
/// on**. A QR carrying `infinitysketch://…` directly might work — reports are anecdotes per device
/// and OS version, and Apple has never committed to the behaviour. So the code carries an ordinary
/// `http://` URL, which is the one case the whole QR ecosystem rests on, and THIS page offers the
/// custom scheme as a link that Safari opens on a user tap — how every "open in app" banner works.
///
/// **The address comes from the request's own `Host` header**, never from anything baked into the
/// link. If the device loaded this page, the address it used is by definition reachable from the
/// device — so a mis-guessed network interface cannot produce a link that half-works. It produces a
/// page that never loads, and the user switches the terminal to another address.
enum JoinPage {
    /// Declared on BOTH sides of the wire: here, and in the app's `ServerJoinLink`. They are in
    /// different repositories, so a rename on one side alone leaves both test suites green and the
    /// feature dead. Change both, or neither.
    static let scheme = "infinitysketch"

    /// The app's own store page. The id matches the review links in the app's `HelpView` and
    /// `WhatsNewView` — taken from there rather than written down fresh.
    ///
    /// It is offered beside the "nothing happening?" note, which is exactly where a device that
    /// cannot open the scheme has to end up: the app is not installed. Reaching it needs internet
    /// while this page arrived over the LAN, so the page says so rather than looking broken.
    static let appStoreURL = "https://apps.apple.com/app/id6736661584"

    /// `host` is the `Host` header verbatim — host and port as the device reached them.
    static func html(host: String) -> String {
        // The host reaches both an `href` and the page's text, and it arrives from the network.
        let safe = HTML.escape(host)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Join this InfinitySketch server</title>
        <style>
        \(WebStyle.tokens)
          body { margin: 0 auto; max-width: 30rem; padding: 2.5rem 1.5rem; line-height: 1.5; }
          h1 { font-size: 1.5rem; margin: 0 0 0.75rem; }
          code { font-size: 1.05rem; background: var(--surface); border: 1px solid var(--line);
                 border-radius: 6px; padding: 0.1rem 0.35rem; }
          a.join { display: block; margin: 2rem 0 1rem; padding: 1rem; text-align: center;
                   background: var(--accent); color: #fff; border-radius: 0.75rem;
                   text-decoration: none; font-weight: 600; }
          /* Outlined, so the primary "open the app" action stays visually dominant. */
          a.store { display: block; margin: 0 0 0.5rem; padding: 0.85rem; text-align: center;
                    border: 1px solid var(--line); border-radius: 0.75rem;
                    background: var(--surface); color: var(--accent);
                    text-decoration: none; font-weight: 600; }
          p.small { color: var(--fg-dim); font-size: 0.9rem; }
        </style></head>
        <body>
          <h1>Sync with this server</h1>
          <p>This will point InfinitySketch at <code>\(safe)</code> and turn syncing on.</p>
          <a class="join" href="\(scheme)://join?address=\(safe)">Open InfinitySketch</a>
          <p class="small">Nothing happening? InfinitySketch isn't installed on this device, or it is
          an older version that doesn't know how to join a server yet.</p>
          <a class="store" href="\(appStoreURL)">Get InfinitySketch on the App Store</a>
          <p class="small">The App Store needs an internet connection — this page came from your
          local network.</p>
        </body></html>
        """
    }
}
