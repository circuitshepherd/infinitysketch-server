/// The v0 overview page, embedded so the binary is self-contained.
public enum WebUI {
    public static let indexHTML = #"""
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
    <table>
      <thead><tr><th></th><th>Document</th><th>Size</th><th>Seq</th><th>Subscribers</th></tr></thead>
      <tbody id="docs"></tbody>
    </table>
    <script>
    const statusEl = document.getElementById("status");
    const docsEl = document.getElementById("docs");
    let refreshTimer = null;

    async function refresh() {
      const docs = await (await fetch("/api/docs")).json();
      docsEl.innerHTML = "";
      for (const d of docs) {
        const row = document.createElement("tr");
        const live = d.subscriberCount != null;
        row.innerHTML =
          `<td><img class="thumb" src="/api/docs/${encodeURIComponent(d.id)}/frame?v=${d.seq ?? "s"}"` +
          ` onerror="this.style.visibility='hidden'"></td>` +
          `<td>${d.name}</td><td>${d.sizeBytes} B</td>` +
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
        ws.send(JSON.stringify({ type: "hello", protocolVersion: 1, capabilities: [] }));
        ws.send(JSON.stringify({ type: "subscribeStatus" }));
      };
      ws.onmessage = (e) => {
        const m = JSON.parse(e.data);
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
