import Foundation

/// The "connect a device" block at the top of the overview page: a scannable code for every address
/// this machine can be reached at, the addresses themselves, and the MCP url an agent needs.
///
/// The terminal prints the same three things, and keeps doing so — but a terminal scrolls, and a
/// server started from a script has no terminal the user is looking at. The page is also where a
/// real QR image and selectable text are possible.
///
/// Pure and self-contained (its own style and script travel with the markup), so it is testable
/// without a server and cannot half-arrive on a page that forgot to include its CSS.
public enum ConnectPanel {

    /// Which candidate's code is shown large.
    ///
    /// The `Host` header decides when it names one of them: a page that LOADED over an address has
    /// proved that address reaches this server — the same reasoning `/join` rests on. The startup
    /// tab is `localhost`, matches nothing, and falls to index 0, which `LocalAddresses.ranked` has
    /// already made the best guess.
    public static func selectedIndex(candidates: [LocalAddress], host: String?) -> Int? {
        guard !candidates.isEmpty else { return nil }
        if let host, let index = candidates.firstIndex(where: { $0.ip == hostPart(of: host) }) {
            return index
        }
        return 0
    }

    /// The host without its port.
    ///
    /// A bracketed IPv6 literal carries colons INSIDE it, so its port is whatever follows the
    /// closing bracket — splitting on the last colon would cut into the address itself. Such a host
    /// can never match anyway (candidates are IPv4), but returning something that is not a host is
    /// the kind of thing the next reader builds on.
    static func hostPart(of host: String) -> String {
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return String(host[host.startIndex...close])
        }
        guard let colon = host.lastIndex(of: ":") else { return host }
        return String(host[host.startIndex..<colon])
    }

    public static func html(candidates: [LocalAddress], port: UInt16, host: String?) -> String {
        guard let selected = selectedIndex(candidates: candidates, host: host) else {
            return section(body: noAddressBody(port: port), script: "")
        }

        var blocks = ""
        var chips = ""
        for (index, candidate) in candidates.enumerated() {
            let joinURL = AddressPicker.joinURL(ip: candidate.ip, port: port)
            let mcpURL = AddressPicker.mcpURL(ip: candidate.ip, port: port)
            // A url is far inside the format's capacity, so this cannot fail in practice; an empty
            // code still leaves the address itself readable, which is the thing that must not be
            // lost.
            let qr = (try? QRCodeSVG.inlineSVG(for: joinURL)) ?? ""
            blocks += """
            <div class="address" data-index="\(index)"\(index == selected ? "" : " hidden")>
              <div class="qr">\(qr)</div>
              <div class="meta">
                <div class="ip">\(HTML.escape(candidate.ip)):\(port)</div>
                <div class="iface">\(HTML.escape(candidate.interface))</div>
                <p>Scan with the camera on your iPhone or iPad. The app asks before it joins.</p>
                <p class="agent">AI agent (MCP)<br>
                  <code id="mcp-\(index)">\(HTML.escape(mcpURL))</code>
                  <button class="copy" data-target="mcp-\(index)">copy</button><br>
                  <code class="cmd" id="cmd-\(index)">\(HTML.escape(AddressPicker.claudeRegisterCommand(mcpURL: mcpURL)))</code>
                  <button class="copy" data-target="cmd-\(index)">copy</button></p>
              </div>
            </div>

            """
            chips += """
            <button class="chip\(index == selected ? " selected" : "")" data-index="\(index)">\
            \(HTML.escape(candidate.interface)) · \(HTML.escape(candidate.ip))</button>

            """
        }

        // OUTSIDE the per-address blocks, which the chips hide and show: loopback is the same url
        // whichever network address is selected, and an agent on this machine should be given it
        // rather than a LAN address that changes with the network. Matches what the terminal
        // prints — including the registration command, and the example note ONCE, here rather
        // than per address.
        let loopback = AddressPicker(candidates: candidates, port: port).loopbackMCPURL
        let local = """
        <p class="agent">AI agent (MCP) on THIS machine<br>
          <code id="mcp-local">\(HTML.escape(loopback))</code>
          <button class="copy" data-target="mcp-local">copy</button><br>
          <code class="cmd" id="cmd-local">\(HTML.escape(AddressPicker.claudeRegisterCommand(mcpURL: loopback)))</code>
          <button class="copy" data-target="cmd-local">copy</button></p>
        <p class="hint">\(HTML.escape(AddressPicker.claudeExampleNote))</p>

        """

        // One address is one address: nothing to switch to.
        let switcher = candidates.count > 1 ? """
        <p class="hint">Not reachable from your phone? Try:</p>
        <div class="chips">\(chips)</div>
        """ : ""

        return section(body: blocks + local + switcher, script: behaviour)
    }

    private static func noAddressBody(port: UInt16) -> String {
        // The terminal's own fallback wording, and the one url that still works here: an agent on
        // THIS machine needs no network address. The command too, matching the terminal — but no
        // copy button: this body ships without the behaviour script, and a dead button is worse
        // than none.
        let loopback = AddressPicker.mcpURL(ip: "127.0.0.1", port: port)
        return """
        <p>No reachable network address found — scan to join is unavailable on this machine.</p>
        <p class="agent">AI agent (MCP), on this machine<br>
          <code>\(HTML.escape(loopback))</code><br>
          <code class="cmd">\(HTML.escape(AddressPicker.claudeRegisterCommand(mcpURL: loopback)))</code></p>
        <p class="hint">\(HTML.escape(AddressPicker.claudeExampleNote))</p>
        """
    }

    private static func section(body: String, script: String) -> String {
        """
        <section id="connect">
        <style>
          /* Every var() carries a fallback ON PURPOSE. This panel's contract is that its style
             travels with its markup, so it must still render standalone, without WebStyle.tokens
             on the page — "degrades gracefully" rather than "identical alone".
             WebStyleTests.theConnectPanelStillRendersStandalone pins that none here is
             fallback-less. */
          #connect { border: 1px solid var(--line, rgba(128,128,128,0.3));
                     border-radius: var(--radius, 10px);
                     background: var(--surface, transparent);
                     padding: 1rem 1.25rem; margin-bottom: 1.5rem; }
          #connect h2 { font-size: 0.7rem; margin: 0 0 0.75rem; text-transform: uppercase;
                        letter-spacing: 0.06em; color: var(--fg-dim, gray); font-weight: 600; }
          #connect .address { display: flex; gap: 1.25rem; align-items: flex-start;
                              flex-wrap: wrap; }
          /* `display: flex` above OUTRANKS the browser's own `[hidden] { display: none }`, so
             without this every address is visible at once and the chips appear to do nothing. */
          #connect .address[hidden] { display: none; }
          /* The plate stays white in dark mode: an inverted code is one most scanners refuse. */
          #connect .qr { background: #fff; padding: 0.35rem; border-radius: 6px; line-height: 0;
                         flex: 0 0 auto; }
          #connect .qr svg { width: 180px; height: 180px; display: block; }
          /* Beside the code, wrapping under it only on a genuinely narrow window. Without a
             `flex` here the block's own minimum width pushed it below the code every time. */
          #connect .meta { flex: 1 1 16rem; min-width: 0; }
          #connect .ip { font-size: 1.25rem; font-weight: 600;
                         font-variant-numeric: tabular-nums; }
          #connect .iface { color: var(--fg-dim, gray); font-size: 0.85rem; margin-bottom: 0.5rem; }
          #connect .agent { font-size: 0.85rem; color: var(--fg-dim, gray); margin: 0.75rem 0 0; }
          #connect code { font-family: var(--font-mono, ui-monospace, Menlo, monospace);
                          font-size: 0.9rem; }
          /* The registration command is ~90 characters; without this it widens the panel on a
             narrow window instead of wrapping. */
          #connect .cmd { overflow-wrap: anywhere; }
          #connect .hint { font-size: 0.85rem; color: var(--fg-dim, gray); margin: 1rem 0 0.35rem; }
          #connect .chips { display: flex; gap: 0.5rem; flex-wrap: wrap; }
          #connect .chip { font: inherit; font-size: 0.8rem; padding: 0.25rem 0.6rem;
                           border-radius: 999px;
                           border: 1px solid var(--line, rgba(128,128,128,0.4));
                           background: transparent; color: inherit; cursor: pointer; }
          #connect .chip.selected { border-color: var(--live, #2a9d2a);
                                    color: var(--live, #2a9d2a); font-weight: 600; }
          #connect .copy { font: inherit; font-size: 0.75rem; margin-left: 0.4rem;
                           cursor: pointer; }
        </style>
        <h2>Connect a device</h2>
        \(body)
        \(script)
        </section>
        """
    }

    /// Chip switching and the copy button. Everything it needs is already in the page.
    private static let behaviour = """
    <script>
    (function () {
      const section = document.getElementById("connect");
      section.querySelectorAll(".chip").forEach(chip => {
        chip.addEventListener("click", () => {
          const index = chip.dataset.index;
          section.querySelectorAll(".chip").forEach(c => c.classList.toggle("selected", c === chip));
          section.querySelectorAll(".address").forEach(a => { a.hidden = a.dataset.index !== index; });
        });
      });
      section.querySelectorAll(".copy").forEach(button => {
        button.addEventListener("click", async () => {
          const code = document.getElementById(button.dataset.target);
          // navigator.clipboard is undefined outside a secure context, and plain http:// to a LAN
          // address is exactly that. Selecting the text leaves the keyboard shortcut working,
          // rather than a button that does nothing.
          try {
            await navigator.clipboard.writeText(code.textContent);
            button.textContent = "copied";
            setTimeout(() => { button.textContent = "copy"; }, 1500);
          } catch (e) {
            const range = document.createRange();
            range.selectNodeContents(code);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            button.textContent = "press ⌘C";
          }
        });
      });
    })();
    </script>
    """
}
