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

    /// `host` is the `Host` header verbatim — host and port as the device reached them.
    static func html(host: String) -> String {
        let safe = escaped(host)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Join this InfinitySketch server</title>
        <style>
          body { font: -apple-system-body, system-ui, sans-serif; margin: 0 auto; max-width: 30rem;
                 padding: 2rem 1.5rem; line-height: 1.5; color: #111; background: #fff; }
          code { font-size: 1.05rem; }
          a.join { display: block; margin: 2rem 0; padding: 1rem; text-align: center;
                   background: #007aff; color: #fff; border-radius: 0.75rem;
                   text-decoration: none; font-weight: 600; }
          p.small { color: #666; font-size: 0.9rem; }
          @media (prefers-color-scheme: dark) {
            body { color: #eee; background: #111; }
            p.small { color: #999; }
          }
        </style></head>
        <body>
          <h1>Sync with this server</h1>
          <p>This will point InfinitySketch at <code>\(safe)</code> and turn syncing on.</p>
          <a class="join" href="\(scheme)://join?address=\(safe)">Open InfinitySketch</a>
          <p class="small">Nothing happening? InfinitySketch isn't installed on this device, or it is
          an older version that doesn't know how to join a server yet.</p>
        </body></html>
        """
    }

    /// The host reaches both an `href` and the page's text, and it arrives from the network.
    private static func escaped(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
