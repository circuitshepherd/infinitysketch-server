import Foundation
import InfSketchWire

/// The v0 overview page, embedded so the binary is self-contained.
///
/// Both scripts interpolate `WireProtocol.version` into their `hello` rather than hardcoding a
/// literal. These pages ship inside the same binary that serves them, so they are never
/// legitimately stale — but a hardcoded number silently rots on the next wire addition, and the
/// symptom (the server answering `unsupportedVersion` to its own web UI) points nowhere near
/// the cause.
public enum WebUI {
    /// `connectSection` is `ConnectPanel.html(…)`, built per request: it depends on this machine's
    /// current addresses and on the `Host` header the browser used.
    public static func indexHTML(connectSection: String) -> String {
        #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>infsketch-server</title>
    <style>
      :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
      body { margin: 2rem auto; max-width: 720px; padding: 0 1rem; }
      h1 { font-size: 1.3rem; }
      #status { color: gray; font-size: 0.85rem; }
      table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
      td, th { padding: 0.5rem 0.75rem; border-bottom: 1px solid rgba(128,128,128,0.3); text-align: left; }
      img.thumb { width: 48px; height: 48px; object-fit: contain; background: rgba(128,128,128,0.15); border-radius: 4px; }
      .live { color: #2a9d2a; font-weight: 600; }
    </style>
    </head>
    <body>
    <h1>infsketch-server</h1>
    <div id="status">connecting…</div>
    \#(connectSection)
    <table>
      <thead><tr><th></th><th>Document</th><th>Size</th><th>Seq</th><th>Subscribers</th></tr></thead>
      <tbody id="docs"></tbody>
    </table>
    <script>
    const statusEl = document.getElementById("status");
    const docsEl = document.getElementById("docs");
    let refreshTimer = null;

    function esc(s) {
      return String(s).replace(/[&<>"']/g, c => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
      }[c]));
    }

    async function refresh() {
      const docs = await (await fetch("/api/docs")).json();
      docsEl.innerHTML = "";
      for (const d of docs) {
        const row = document.createElement("tr");
        const live = d.subscriberCount != null;
        row.innerHTML =
          `<td><img class="thumb" src="/api/docs/${encodeURIComponent(d.id)}/frame?v=${d.seq ?? "s"}"` +
          ` onerror="this.style.visibility='hidden'"></td>` +
          `<td><a href="/doc/${encodeURIComponent(d.id)}">${esc(d.name)}</a></td><td>${d.sizeBytes} B</td>` +
          `<td>${d.seq ?? "–"}</td>` +
          `<td class="${live ? "live" : ""}">${d.subscriberCount ?? "–"}</td>`;
        docsEl.appendChild(row);
      }
    }

    function scheduleRefresh() {              // debounce bursts of status events
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(refresh, 300);
    }

    function connect() {
      const ws = new WebSocket(`ws://${location.host}/ws`);
      ws.onopen = () => {
        statusEl.textContent = "live";
        ws.send(JSON.stringify({ type: "hello", protocolVersion: \#(WireProtocol.version), capabilities: [] }));
        ws.send(JSON.stringify({ type: "subscribeStatus" }));
      };
      ws.onmessage = (e) => {
        const m = JSON.parse(e.data);
        // The server drops a connection that will not prove it is reading.
        if (m.type === "ping") return ws.send(JSON.stringify({ type: "pong" }));
        if (m.type === "statusEvent") scheduleRefresh();
      };
      ws.onclose = () => {
        statusEl.textContent = "disconnected — retrying…";
        setTimeout(connect, 2000);
      };
    }

    refresh();
    connect();
    </script>
    </body>
    </html>
    """#
    }

    /// The per-document live view. docId is embedded JSON-encoded (safe for
    /// any filename) and HTML-escaped for the title.
    public static func docHTML(docId: String) -> String {
        let jsonId = String(decoding: (try? JSONEncoder().encode(docId)) ?? Data("\"?\"".utf8), as: UTF8.self)
        let htmlId = docId
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return #"""
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\#(htmlId) — infsketch</title>
        <style>
          :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
          body { margin: 1rem auto; max-width: 1100px; padding: 0 1rem; }
          header { display: flex; align-items: baseline; gap: 1rem; }
          h1 { font-size: 1.2rem; margin: 0; }
          #badge { font-size: 0.85rem; color: gray; }
          #badge.live { color: #2a9d2a; font-weight: 600; }
          img#frame { width: 100%; margin-top: 1rem; border-radius: 8px;
                      background: rgba(128,128,128,0.1); }
        </style>
        </head>
        <body>
        <header>
          <a href="/">← overview</a>
          <h1>\#(htmlId)</h1>
          <span id="badge">connecting…</span>
        </header>
        <img id="frame" src="">
        <script>
        const docId = \#(jsonId);
        const badge = document.getElementById("badge");
        const img = document.getElementById("frame");
        let lastSeq = null;
        let lastFrameAt = 0;

        function refetch(tag) {
          img.src = `/api/docs/${encodeURIComponent(docId)}/frame?v=${tag}`;
        }

        function updateBadge() {
          const fresh = Date.now() - lastFrameAt < 4000;
          badge.textContent = fresh ? "live"
            : (lastSeq === null ? "stale (no live client)" : `as of seq ${lastSeq}`);
          badge.className = fresh ? "live" : "";
        }
        setInterval(updateBadge, 1000);

        function connect() {
          const ws = new WebSocket(`ws://${location.host}/ws`);
          ws.onopen = () => {
            ws.send(JSON.stringify({ type: "hello", protocolVersion: \#(WireProtocol.version), capabilities: [] }));
            ws.send(JSON.stringify({ type: "watchDoc", docId: docId }));
          };
          ws.onmessage = (e) => {
            const m = JSON.parse(e.data);
            // The server drops a connection that will not prove it is reading.
            if (m.type === "ping") return ws.send(JSON.stringify({ type: "pong" }));
            if (m.type === "frameAvailable" && m.docId === docId) {
              lastSeq = m.seq;
              lastFrameAt = Date.now();
              refetch(`${m.seq}-${lastFrameAt}`);
              updateBadge();
            }
          };
          ws.onclose = () => {
            badge.textContent = "disconnected — retrying…";
            badge.className = "";
            setTimeout(connect, 2000);
          };
        }

        refetch("initial");
        connect();
        </script>
        </body>
        </html>
        """#
    }
}
