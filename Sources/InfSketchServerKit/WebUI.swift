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
    /// The overview table's sort core — a standalone constant for the same reason
    /// `viewportJS` is one: the suite drives the REAL source in a JSContext rather
    /// than a Swift re-derivation of it. Pure: no DOM, no globals.
    public static let tableSortJS = #"""
    // What the page opens at: the documents someone is actually looking at first,
    // then alphabetical. It is deliberately NOT persisted anywhere — a reload is
    // the way back to it, so nothing here may reach localStorage or a cookie.
    const DEFAULT_SORT = [{ column: "subscribers", dir: -1 }, { column: "name", dir: 1 }];

    // Sort state for the document table: an ORDERED list of keys, most significant
    // first, so "subscribers, then name" is expressible. One rule covers both
    // buttons — a click CYCLES a column asc -> desc -> off — and `additive`
    // (shift) is the only difference: without it the other columns are dropped
    // first, so a plain click always means "sort by just this one".
    //
    // `initial` omitted means DEFAULT_SORT; pass [] for an unsorted table.
    function makeTableSort(initial) {
      const COLUMNS = {
        name: (d) => d.name,
        sizeBytes: (d) => d.sizeBytes,
        seq: (d) => d.seq,
        subscribers: (d) => d.subscriberCount,
      };
      // COPIED, never aliased: `toggle` mutates these objects in place, so a shared
      // DEFAULT_SORT entry would carry one page's click into the next sorter built.
      let keys = (initial === undefined ? DEFAULT_SORT : initial)   // [{ column, dir }],
        .filter((k) => k && k.column in COLUMNS)                    // dir: 1 asc, -1 desc
        .map((k) => ({ column: k.column, dir: k.dir === -1 ? -1 : 1 }));

      function toggle(column, additive) {
        if (!(column in COLUMNS)) return;
        const existing = keys.find(k => k.column === column);
        // The survivor is the same object `existing` names, so the cycle below
        // still sees the direction this column was already at.
        if (!additive) keys = keys.filter(k => k.column === column);
        if (!existing) keys.push({ column, dir: 1 });
        else if (existing.dir === 1) existing.dir = -1;
        else keys = keys.filter(k => k.column !== column);
      }

      // A missing value (an offline document has no seq and no subscriber count)
      // sorts LAST in BOTH directions: a block of "–" at the top of a descending
      // sort is noise, and it is not a small number — it is not a number at all.
      function compareOne(a, b, key) {
        const x = COLUMNS[key.column](a), y = COLUMNS[key.column](b);
        const xGone = x === null || x === undefined, yGone = y === null || y === undefined;
        if (xGone || yGone) return xGone && yGone ? 0 : (xGone ? 1 : -1);
        if (typeof x === "string" || typeof y === "string") {
          // numeric: "Doc 10" after "Doc 9"; base: case is not a sort key.
          return key.dir * String(x).localeCompare(String(y), undefined,
            { numeric: true, sensitivity: "base" });
        }
        return key.dir * (x < y ? -1 : x > y ? 1 : 0);
      }

      return {
        get keys() { return keys.map(k => ({ column: k.column, dir: k.dir })); },
        toggle,
        // Array#sort is stable (ES2019), so rows equal on every key keep the
        // order the server sent and cannot shuffle between refreshes.
        apply(docs) {
          if (keys.length === 0) return docs.slice();
          return docs.slice().sort((a, b) => {
            for (const k of keys) { const c = compareOne(a, b, k); if (c !== 0) return c; }
            return 0;
          });
        },
        // "" unsorted, else an arrow — plus the 1-based rank once a second key
        // exists, which is the only thing that makes a multi-column sort legible.
        indicator(column) {
          const i = keys.findIndex(k => k.column === column);
          if (i < 0) return "";
          return (keys[i].dir === 1 ? "▲" : "▼") + (keys.length > 1 ? (i + 1) : "");
        },
        ariaSort(column) {
          const k = keys.find(k => k.column === column);
          return k ? (k.dir === 1 ? "ascending" : "descending") : "none";
        },
      };
    }
    """#

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
    \#(WebStyle.tokens)
      body { margin: 0 auto; max-width: 880px; padding: 2rem 1rem 3rem; }
      header.page { display: flex; align-items: baseline; gap: 0.75rem; margin-bottom: 1.5rem; }
      h1 { font-size: 1.35rem; margin: 0; }

      /* The table sits on its own surface so it reads as one object against --bg. */
      .card { background: var(--surface); border: 1px solid var(--line);
              border-radius: var(--radius); overflow: hidden; }
      table { border-collapse: collapse; width: 100%; }
      th, td { padding: 0.6rem 0.9rem; border-bottom: 1px solid var(--line);
               text-align: left; }
      thead th { font-size: 0.7rem; font-weight: 600; text-transform: uppercase;
                 letter-spacing: 0.06em; color: var(--fg-dim); }
      tbody tr:last-child td { border-bottom: none; }
      tbody tr:hover { background: var(--bg); }
      /* Right-aligned and tabular so the columns actually line up digit by digit —
         which is most of what makes a dense table read as designed. */
      .num { text-align: right; font-variant-numeric: tabular-nums; }
      td.name a { font-weight: 500; text-decoration: none; }
      td.name a:hover { text-decoration: underline; }
      img.thumb { width: 48px; height: 48px; object-fit: contain; display: block;
                  background: var(--bg); border: 1px solid var(--line); border-radius: 6px; }
      td.thumb { width: 48px; padding-right: 0; }
      #empty { padding: 2rem 0.9rem; color: var(--fg-dim); font-size: 0.9rem; }
      /* Sortable headers (from main) on the shared tokens: the hover matches the row
         hover, and the mark takes the same dim colour as the header text. */
      th[data-sort] { cursor: pointer; user-select: none; -webkit-user-select: none; }
      th[data-sort]:hover { background: var(--bg); }
      /* A FIXED slot, because the mark's content changes with the sort ("" -> ▲ -> ▼2)
         and the table is auto-layout: a header that grows or shrinks under a click
         re-measures its whole column, so every column shifts as you sort. The width
         holds the widest mark (arrow + rank) — measured at 14.7px against this 15.7px
         slot — so the reserve is identical on a sorted and an unsorted header, and a
         font that draws the arrow wider spills into the cell padding rather than
         moving anything. */
      .sortmark { display: inline-block; width: 1.75em; margin-left: 0.35rem;
                  font-size: 0.8em; color: var(--fg-dim);
                  text-align: left; white-space: nowrap; }
      /* On a right-aligned column the mark goes on the INNER side (it is first in the
         markup there): the label then ends flush with the digits below it whatever the
         sort is doing, and the reserved slot sits in the cell's empty middle. */
      th.num .sortmark { margin-left: 0; margin-right: 0.35rem; text-align: right; }
    </style>
    </head>
    <body>
    <header class="page">
      <h1>infsketch-server</h1>
      <span id="status" class="badge">connecting…</span>
    </header>
    \#(connectSection)
    <div class="card">
      <table>
        <thead><tr>
          <th></th>
          <th data-sort="name" tabindex="0" title="Click to sort. Shift-click to add a column, so the sort can be e.g. subscribers then name. A third click clears the column.">Document<span class="sortmark"></span></th>
          <th class="num" data-sort="sizeBytes" tabindex="0" title="Click to sort. Shift-click to add a column."><span class="sortmark"></span>Size</th>
          <th class="num" data-sort="seq" tabindex="0" title="Click to sort. Shift-click to add a column."><span class="sortmark"></span>Seq</th>
          <th class="num" data-sort="subscribers" tabindex="0" title="Click to sort. Shift-click to add a column."><span class="sortmark"></span>Subscribers</th>
        </tr></thead>
        <tbody id="docs"></tbody>
      </table>
      <div id="empty" hidden>No documents yet — open a sketch on a connected device.</div>
    </div>
    <script>
    \#(tableSortJS)

    const statusEl = document.getElementById("status");
    const docsEl = document.getElementById("docs");
    let refreshTimer = null;
    // No argument = DEFAULT_SORT (subscribers descending, then name). The sort is held
    // in this variable and nowhere else, so a reload always comes back to the default.
    const sorter = makeTableSort();
    // The last payload, kept so a header click re-sorts what is on screen without
    // re-fetching — and so a status-event refresh cannot drop the user's sort.
    let docs = [];

    function esc(s) {
      return String(s).replace(/[&<>"']/g, c => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
      }[c]));
    }

    // A raw byte count is unreadable past about five digits, and this column exists to be
    // compared down its length.
    function fmtBytes(n) {
      if (typeof n !== "number") return "–";
      if (n < 1024) return `${n} B`;
      if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
      return `${(n / 1048576).toFixed(1)} MB`;
    }

    // `docs` is the module-level array the sort reads — deliberately NOT shadowed by a local
    // here, which is what the pre-sort version of this function did.
    function render() {
      docsEl.innerHTML = "";
      document.getElementById("empty").hidden = docs.length > 0;
      for (const d of sorter.apply(docs)) {
        const row = document.createElement("tr");
        const live = d.subscriberCount != null;
        row.innerHTML =
          `<td class="thumb"><img class="thumb" src="/api/docs/${encodeURIComponent(d.id)}/frame?v=${d.seq ?? "s"}"` +
          ` onerror="this.style.visibility='hidden'"></td>` +
          `<td class="name"><a href="/doc/${encodeURIComponent(d.id)}">${esc(d.name)}</a></td>` +
          `<td class="num">${fmtBytes(d.sizeBytes)}</td>` +
          `<td class="num">${d.seq ?? "–"}</td>` +
          `<td class="num badge${live ? " live" : ""}">${d.subscriberCount ?? "–"}</td>`;
        docsEl.appendChild(row);
      }
      for (const th of document.querySelectorAll("th[data-sort]")) {
        th.setAttribute("aria-sort", sorter.ariaSort(th.dataset.sort));
        th.querySelector(".sortmark").textContent = sorter.indicator(th.dataset.sort);
      }
    }

    for (const th of document.querySelectorAll("th[data-sort]")) {
      const sortBy = (e) => { sorter.toggle(th.dataset.sort, e.shiftKey); render(); };
      th.addEventListener("click", sortBy);
      th.addEventListener("keydown", (e) => {
        if (e.key !== "Enter" && e.key !== " ") return;
        e.preventDefault();   // else Space scrolls the page
        sortBy(e);
      });
    }

    async function refresh() {
      docs = await (await fetch("/api/docs")).json();
      render();
    }

    function scheduleRefresh() {              // debounce bursts of status events
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(refresh, 300);
    }

    function connect() {
      const ws = new WebSocket(`ws://${location.host}/ws`);
      ws.onopen = () => {
        statusEl.textContent = "live";
        statusEl.className = "badge live";
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
        statusEl.className = "badge";
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

    /// The pan/zoom viewport core — a standalone constant so the test suite can
    /// evaluate the REAL source in a JSContext rather than a Swift re-derivation.
    /// Pure: no DOM, no globals; dpr is injected so tests can pin it.
    public static let viewportJS = #"""
    // A frame pixel (px, py) lands at (px * scale + tx, py * scale + ty).
    function makeViewport(dpr) {
      const MAX_DEVICE_PX = 8;   // never magnify a frame pixel beyond 8 device px
      let scale = 1, tx = 0, ty = 0;
      let boxW = 0, boxH = 0, imgW = 0, imgH = 0;
      let atFit = true;
      // The canvas region the WHOLE square frame covers, [x, y, w, h], or null when
      // the server did not report one (the stale-thumbnail path cannot know it). This
      // is what makes a pinned view possible at all: the frame is an auto-fit render
      // of the document's bounds, so its pixels change meaning whenever those bounds
      // move, while scale/tx/ty sit still.
      let rect = null;
      const validRect = (r) => (Array.isArray(r) && r.length === 4
        && r.every((v) => typeof v === "number" && isFinite(v))
        && r[2] > 0 && r[3] > 0) ? r : null;

      const fitScale = () => (imgW && imgH && boxW && boxH)
        ? Math.min(boxW / imgW, boxH / imgH) : 1;
      // The minimum is min(fit, 1:1): in the common case 1:1 is MORE zoomed out
      // than fit, and clamping at fitScale would make the 1:1 button do nothing.
      // the cap yields to fit: a small frame in a big box must still fit without
      // the next zoom-in tick snapping down
      const clampScale = (s) => Math.min(Math.max(MAX_DEVICE_PX / dpr(), fitScale()),
        Math.max(Math.min(fitScale(), 1 / dpr()), s));

      // No dead space: an axis where the image is smaller than the box is
      // centred; otherwise the image edge may not come inside the box edge.
      function clampTranslation() {
        const w = imgW * scale, h = imgH * scale;
        tx = (w <= boxW) ? (boxW - w) / 2 : Math.min(0, Math.max(boxW - w, tx));
        ty = (h <= boxH) ? (boxH - h) / 2 : Math.min(0, Math.max(boxH - h, ty));
      }

      // Derives from the CLAMPED target, never the requested one — otherwise the
      // image creeps sideways on every scroll tick taken against the zoom limit.
      function setScaleAbout(cx, cy, target) {
        const s = clampScale(target);
        const r = s / scale;
        tx = cx - (cx - tx) * r;
        ty = cy - (cy - ty) * r;
        scale = s;
        atFit = false;
        clampTranslation();
      }

      // Canvas point under a CSS point in the box, using the CURRENT geometry.
      // Only meaningful with a rect; callers check.
      function canvasAt(cx, cy) {
        const ppc = imgW / rect[2];               // frame px per canvas point
        return [rect[0] + (cx - tx) / (scale * ppc),
                rect[1] + (cy - ty) / (scale * ppc)];
      }

      return {
        get state() { return { scale, tx, ty, atFit, imgW, imgH, boxW, boxH, rect }; },
        panBy(dx, dy) { tx += dx; ty += dy; atFit = false; clampTranslation(); },
        zoomAbout(cx, cy, factor) { setScaleAbout(cx, cy, scale * factor); },
        fit() {
          scale = fitScale();
          tx = (boxW - imgW * scale) / 2;
          ty = (boxH - imgH * scale) / 2;
          atFit = true;
        },
        oneToOne() { setScaleAbout(boxW / 2, boxH / 2, 1 / dpr()); },
        setBox(w, h) {
          boxW = w; boxH = h;
          if (atFit) this.fit(); else clampTranslation();
        },
        // A new frame. At fit the view follows the content, by design; otherwise the
        // CANVAS region on screen is held still, whatever the frame did underneath.
        //
        // With both rects known the invariant is CSS pixels per canvas point. The
        // anchor is the canvas point under the BOX CENTRE rather than an algebraic
        // tx' = tx + (newX - oldX) * s_c, and the difference shows only when the scale
        // clamp bites (content growing far enough pushes past the 8/dpr ceiling):
        // centre-anchored degrades to the same middle at a slightly wrong zoom instead
        // of sliding sideways. Same idea as oneToOne.
        //
        // Without a rect on either side — the stale-thumbnail path never reports one —
        // this falls back to the older, weaker rule: hold the same FRAME-pixel region,
        // which is exactly right there because that path does not re-render. Both frame
        // sources are square (1024 live, 256 stored thumbnail), licensing the single k.
        setFrame(w, h, newRect) {
          const prev = rect;
          const next = validRect(newRect);
          if (!imgW || !imgH) { imgW = w; imgH = h; rect = next; this.fit(); return; }
          const moved = !prev || !next || prev[0] !== next[0] || prev[1] !== next[1]
            || prev[2] !== next[2] || prev[3] !== next[3];
          if (w === imgW && h === imgH && !moved) { rect = next; return; }
          if (atFit) { imgW = w; imgH = h; rect = next; this.fit(); return; }

          if (prev && next) {
            const ppcOld = imgW / prev[2];
            const anchor = canvasAt(boxW / 2, boxH / 2);
            const sc = scale * ppcOld;            // CSS px per canvas point — the invariant
            imgW = w; imgH = h; rect = next;
            const ppcNew = imgW / rect[2];
            scale = clampScale(sc / ppcNew);
            tx = boxW / 2 - (anchor[0] - rect[0]) * ppcNew * scale;
            ty = boxH / 2 - (anchor[1] - rect[1]) * ppcNew * scale;
          } else {
            const k = w / imgW;
            imgW = w; imgH = h; rect = next;
            scale = clampScale(scale / k);
          }
          clampTranslation();
        },
      };
    }
    """#

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
        \#(WebStyle.tokens)
          html, body { height: 100%; }
          body { margin: 0; display: flex; flex-direction: column; overflow: hidden; }

          /* One bar, not a header row plus a toolbar row: two rows of chrome over a
             viewer is most of what made the page look unfinished. */
          #bar { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap;
                 box-sizing: border-box; padding: 0.6rem 0.9rem;
                 border-bottom: 1px solid var(--line); background: var(--surface); }
          #bar .back { text-decoration: none; font-size: 1.1rem; line-height: 1;
                       padding: 0.15rem 0.35rem; border-radius: 6px; }
          #bar .back:hover { background: var(--bg); }
          #bar h1 { font-size: 1.05rem; margin: 0; white-space: nowrap;
                    overflow: hidden; text-overflow: ellipsis; }
          #bar .spacer { flex: 1 1 auto; }
          #controls { display: flex; gap: 0.4rem; flex-wrap: wrap; }

          /* Immersive mode: the bar leaves the flow, so #stage (already flex: 1) fills
             the window. Nothing about the browser's OWN fullscreen is involved. */
          body.immersive #bar { position: absolute; z-index: 2; top: 0; left: 0; right: 0;
                                background: var(--bar); border-bottom: none;
                                backdrop-filter: blur(12px);
                                -webkit-backdrop-filter: blur(12px);
                                transition: opacity 0.25s ease; }
          body.immersive.idle #bar { opacity: 0; pointer-events: none; }

          /* touch-action: none is load-bearing: the stage owns every gesture inside
             it (native pan/pinch suppressed HERE ONLY; the page keeps browser zoom). */
          #stage { flex: 1; overflow: hidden; position: relative;
                   touch-action: none; user-select: none; -webkit-user-select: none;
                   -webkit-touch-callout: none; cursor: grab;
                   background: var(--stage); }
          #stage.dragging { cursor: grabbing; }
          img#frame { position: absolute; left: 0; top: 0; transform-origin: 0 0;
                      image-rendering: -webkit-optimize-contrast; }
        </style>
        </head>
        <body>
        <div id="bar">
          <a class="back" href="/" title="Back to the overview">&larr;</a>
          <h1>\#(htmlId)</h1>
          <span id="badge" class="badge">connecting…</span>
          <span class="spacer"></span>
          <div id="controls">
            <button class="btn" id="fit" title="Fit the whole sketch (0)">Fit</button>
            <button class="btn" id="one" title="One frame pixel per device pixel (1)">1:1</button>
            <button class="btn" id="pause" title="Stop live re-rendering">Pause</button>
            <button class="btn" id="wheelmode" title="What a plain wheel does"></button>
            <button class="btn" id="respx" title="Requested live-frame resolution — the device renders at least this many pixels (it requests; a paused or absent device changes nothing)"></button>
            <button class="btn" id="full" title="Immersive mode — overlay the header (f, Escape to exit)">&#10530;</button>
          </div>
        </div>
        <div id="stage">
          <img id="frame" draggable="false" alt="">
        </div>
        <script>
        "use strict";
        const docId = \#(jsonId);
        const badge = document.getElementById("badge");
        const img = document.getElementById("frame");
        const stage = document.getElementById("stage");

        \#(viewportJS)

        const vp = makeViewport(() => window.devicePixelRatio || 1);
        window.__viewport = vp;   // deliberately exposed: how the browser checks drive the math

        const fitBtn = document.getElementById("fit");

        function render() {
          img.style.transform =
            `translate(${vp.state.tx}px, ${vp.state.ty}px) scale(${vp.state.scale})`;
          // Read live on every render rather than tracked as a second flag: the button
          // says what the viewport IS, so it cannot fall out of step with it. The title
          // carries what the highlight MEANS — that lit is the one state in which the
          // view follows the sketch — which the border alone cannot say.
          const following = vp.state.atFit;
          fitBtn.classList.toggle("on", following);
          fitBtn.title = following
            ? "Following the sketch: the view re-fits as the drawing grows. Zoom or pan to pin it. (0)"
            : "View pinned — it stays put as the drawing changes. Press to fit the whole sketch and follow it again. (0)";
        }

        new ResizeObserver(() => {
          vp.setBox(stage.clientWidth, stage.clientHeight);
          render();
        }).observe(stage);

        // ---- controls ----
        const pauseBtn = document.getElementById("pause");
        const wheelBtn = document.getElementById("wheelmode");
        let paused = false;
        let wheelMode = "zoom";
        try { if (localStorage.getItem("infsketch.wheelMode") === "pan") wheelMode = "pan"; } catch (e) {}

        let framePx = null;   // null = auto (the device's own default)
        try {
          const v = parseInt(localStorage.getItem("infsketch.framePx"), 10);
          if (v === 1024 || v === 2048) framePx = v;
        } catch (e) {}

        function watchMessage() {
          const m = { type: "watchDoc", docId: docId };
          if (framePx) m.framePx = framePx;
          return JSON.stringify(m);
        }

        fitBtn.onclick = () => { vp.fit(); render(); };
        document.getElementById("one").onclick = () => { vp.oneToOne(); render(); };
        function toggleFitOne() {
          if (vp.state.atFit) vp.oneToOne(); else vp.fit();
          render();
        }

        pauseBtn.onclick = () => {
          paused = !paused;
          pauseBtn.textContent = paused ? "Resume" : "Pause";
          // unwatchDoc, not a frozen picture: with zero watchers the device's
          // FrameScheduler goes inert, so pausing genuinely stops the rendering.
          if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(paused ? JSON.stringify({ type: "unwatchDoc", docId: docId })
                           : watchMessage());
          }
          if (!paused) refetch(`resume-${Date.now()}`);
          updateBadge();
        };

        function showWheelMode() {
          wheelBtn.textContent = wheelMode === "zoom" ? "Wheel: zoom" : "Wheel: pan";
        }
        wheelBtn.onclick = () => {
          wheelMode = wheelMode === "zoom" ? "pan" : "zoom";
          try { localStorage.setItem("infsketch.wheelMode", wheelMode); } catch (e) {}
          showWheelMode();
        };
        showWheelMode();

        const resBtn = document.getElementById("respx");
        function showRes() {
          resBtn.textContent = framePx ? `Res: ${framePx}` : "Res: auto";
        }
        resBtn.onclick = () => {
          framePx = framePx === null ? 1024 : (framePx === 1024 ? 2048 : null);
          try {
            if (framePx) localStorage.setItem("infsketch.framePx", String(framePx));
            else localStorage.removeItem("infsketch.framePx");
          } catch (e) {}
          showRes();
          // Re-watch so the new request reaches the device; a paused page applies it on resume.
          if (!paused && ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: "unwatchDoc", docId: docId }));
            ws.send(watchMessage());
          }
        };
        showRes();

        // ---- immersive mode ----
        // The page's OWN chrome, deliberately independent of the browser's fullscreen
        // control: no requestFullscreen anywhere, so F11 composes with this instead of
        // fighting it. The bar leaves the flow and the ResizeObserver above re-fits.
        const fullBtn = document.getElementById("full");
        const bar = document.getElementById("bar");
        let immersive = false;
        let idleTimer = null;
        let pointerOverBar = false;

        function goIdle() {
          // Never fade out from under a hand that is reaching for the controls.
          if (immersive && !pointerOverBar) document.body.classList.add("idle");
        }
        function wake() {
          document.body.classList.remove("idle");
          clearTimeout(idleTimer);
          if (immersive) idleTimer = setTimeout(goIdle, 2200);
        }
        bar.addEventListener("pointerenter", () => { pointerOverBar = true; wake(); });
        bar.addEventListener("pointerleave", () => { pointerOverBar = false; wake(); });

        function setImmersive(on) {
          immersive = on;
          document.body.classList.toggle("immersive", on);
          fullBtn.classList.toggle("on", on);
          fullBtn.title = on ? "Leave immersive mode (f or Escape)"
                             : "Immersive mode — overlay the header (f, Escape to exit)";
          try {
            if (on) localStorage.setItem("infsketch.immersive", "1");
            else localStorage.removeItem("infsketch.immersive");
          } catch (e) {}
          wake();   // entering always starts un-faded: never a chromeless mystery
        }
        fullBtn.onclick = () => setImmersive(!immersive);
        try { if (localStorage.getItem("infsketch.immersive") === "1") setImmersive(true); } catch (e) {}

        // Any sign of life re-arms the timer. Passive: these only observe — the stage's
        // own wheel/pointer handlers still own the gesture.
        // `mousemove` is listed BESIDE `pointermove` on purpose. Real mouse input fires both,
        // but the compatibility event is all some environments emit (measured: this page's own
        // browser-driven check woke the bar on pointermove and not on mousemove), and a bar that
        // will not come back is a page with no controls at all.
        for (const ev of ["pointermove", "mousemove", "pointerdown", "keydown", "wheel"]) {
          document.addEventListener(ev, wake, { passive: true });
        }

        // ---- input ----
        stage.addEventListener("wheel", (e) => {
          e.preventDefault();   // or ctrl+wheel zooms the whole page
          const rect = stage.getBoundingClientRect();
          const lineScale = e.deltaMode === 1 ? 16 : 1;   // Firefox reports lines
          const dx = e.deltaX * lineScale, dy = e.deltaY * lineScale;
          if (e.ctrlKey || wheelMode === "zoom") {
            // ctrlKey is how a trackpad pinch arrives, in every browser
            const k = e.ctrlKey ? 0.01 : 0.002;
            vp.zoomAbout(e.clientX - rect.left, e.clientY - rect.top, Math.exp(-dy * k));
          } else if (e.shiftKey && dx === 0) {
            vp.panBy(-dy, 0);
          } else {
            vp.panBy(-dx, -dy);
          }
          render();
        }, { passive: false });

        const pointers = new Map();
        let lastMid = null, lastDist = 0;
        let lastTapAt = 0, lastTapX = 0, lastTapY = 0;

        stage.addEventListener("pointerdown", (e) => {
          // Capture keeps a drag alive outside the stage; synthetic test events
          // have no active pointer to capture, which must not kill the handler.
          try { stage.setPointerCapture(e.pointerId); } catch (err) {}
          pointers.set(e.pointerId, { x: e.clientX, y: e.clientY,
                                      startX: e.clientX, startY: e.clientY });
          if (pointers.size === 2) {
            const [a, b] = [...pointers.values()];
            lastMid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
            lastDist = Math.hypot(a.x - b.x, a.y - b.y);
          }
          stage.classList.add("dragging");
        });

        stage.addEventListener("pointermove", (e) => {
          const p = pointers.get(e.pointerId);
          if (!p) return;
          const rect = stage.getBoundingClientRect();
          if (pointers.size === 1) {
            vp.panBy(e.clientX - p.x, e.clientY - p.y);
            render();
          }
          p.x = e.clientX; p.y = e.clientY;
          if (pointers.size === 2 && lastMid) {
            const [a, b] = [...pointers.values()];
            const m = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
            const d = Math.hypot(a.x - b.x, a.y - b.y);
            vp.panBy(m.x - lastMid.x, m.y - lastMid.y);
            if (lastDist > 0 && d > 0) {
              vp.zoomAbout(m.x - rect.left, m.y - rect.top, d / lastDist);
            }
            lastMid = m; lastDist = d;
            render();
          }
        });

        function endPointer(e) {
          const p = pointers.get(e.pointerId);
          if (!p) return;
          pointers.delete(e.pointerId);
          if (pointers.size < 2) { lastMid = null; lastDist = 0; }
          if (pointers.size === 0) stage.classList.remove("dragging");
          // Double-click and double-tap share one manual path — native dblclick
          // would double-fire on browsers that synthesize it after taps.
          const wasTap = Math.hypot(e.clientX - p.startX, e.clientY - p.startY) < 10;
          if (wasTap && pointers.size === 0) {
            const now = Date.now();
            if (now - lastTapAt < 350
                && Math.abs(e.clientX - lastTapX) < 30
                && Math.abs(e.clientY - lastTapY) < 30) {
              lastTapAt = 0;
              toggleFitOne();
            } else {
              lastTapAt = now; lastTapX = e.clientX; lastTapY = e.clientY;
            }
          }
        }
        stage.addEventListener("pointerup", endPointer);
        stage.addEventListener("pointercancel", endPointer);
        stage.addEventListener("dblclick", (e) => e.preventDefault());
        stage.addEventListener("dragstart", (e) => e.preventDefault());

        window.addEventListener("keydown", (e) => {
          if (e.ctrlKey || e.metaKey || e.altKey) return;
          const PAN = 60;
          const cx = stage.clientWidth / 2, cy = stage.clientHeight / 2;
          switch (e.key) {
            // Both return rather than break: neither touches the viewport, and Escape
            // must fall through untouched when there is no immersive mode to leave.
            case "f": case "F": setImmersive(!immersive); e.preventDefault(); return;
            case "Escape":
              if (!immersive) return;
              setImmersive(false); e.preventDefault(); return;
            case "0": vp.fit(); break;
            case "1": vp.oneToOne(); break;
            case "+": case "=": vp.zoomAbout(cx, cy, 1.25); break;
            case "-": case "_": vp.zoomAbout(cx, cy, 0.8); break;
            case "ArrowLeft":  vp.panBy(PAN, 0); break;
            case "ArrowRight": vp.panBy(-PAN, 0); break;
            case "ArrowUp":    vp.panBy(0, PAN); break;
            case "ArrowDown":  vp.panBy(0, -PAN); break;
            default: return;
          }
          e.preventDefault();
          render();
        });

        // ---- frames ----
        let lastSeq = null;
        let lastFrameAt = 0;
        let loadGen = 0;
        let disconnected = false;

        // fetch, not `new Image()`: the frame's canvas rect arrives as a response
        // HEADER, which an <img> load cannot read. Still decoded into a detached Image
        // and swapped only on load — assigning img.src directly blanks the element for
        // the whole download, once a second, and a zoomed inspection must never
        // flicker. On any failure keep the last good frame.
        let objectUrl = null;
        function refetch(tag) {
          const gen = ++loadGen;
          fetch(`/api/docs/${encodeURIComponent(docId)}/frame?v=${tag}`, { cache: "no-store" })
            .then((res) => {
              if (!res.ok) throw new Error(`frame ${res.status}`);
              // Absent header = unknown rect, which the viewport handles as its own
              // case. Parse defensively: a malformed value must read as absent, never
              // as a rect full of NaN.
              const raw = res.headers.get("X-Frame-Canvas-Rect");
              const rect = raw ? raw.split(",").map(Number) : null;
              return res.blob().then((blob) => ({ blob, rect }));
            })
            .then(({ blob, rect }) => {
              if (gen !== loadGen) return;   // superseded by a newer frame
              const url = URL.createObjectURL(blob);
              const probe = new Image();
              probe.onload = () => {
                if (gen !== loadGen) return URL.revokeObjectURL(url);
                img.src = url;
                if (objectUrl) URL.revokeObjectURL(objectUrl);
                objectUrl = url;
                vp.setFrame(probe.naturalWidth, probe.naturalHeight, rect);
                render();
              };
              probe.onerror = () => URL.revokeObjectURL(url);
              probe.src = url;
            })
            .catch(() => {});
        }

        function updateBadge() {
          // Every write keeps the "badge" base class — dropping it loses the type styling.
          if (paused) { badge.textContent = "paused"; badge.className = "badge"; return; }
          if (disconnected) {
            badge.textContent = "disconnected — retrying…";
            badge.className = "badge";
            return;
          }
          const fresh = Date.now() - lastFrameAt < 4000;
          badge.textContent = fresh ? "live"
            : (lastSeq === null ? "stale (no live client)" : `as of seq ${lastSeq}`);
          badge.className = fresh ? "badge live" : "badge";
        }
        setInterval(updateBadge, 1000);

        let ws = null;
        function connect() {
          ws = new WebSocket(`ws://${location.host}/ws`);
          ws.onopen = () => {
            disconnected = false;
            ws.send(JSON.stringify({ type: "hello", protocolVersion: \#(WireProtocol.version), capabilities: [] }));
            if (!paused) ws.send(watchMessage());
            updateBadge();
          };
          ws.onmessage = (e) => {
            const m = JSON.parse(e.data);
            // The server drops a connection that will not prove it is reading.
            if (m.type === "ping") return ws.send(JSON.stringify({ type: "pong" }));
            if (m.type === "frameAvailable" && m.docId === docId && !paused) {
              lastSeq = m.seq;
              lastFrameAt = Date.now();
              refetch(`${m.seq}-${lastFrameAt}`);
              updateBadge();
            }
          };
          ws.onclose = () => {
            disconnected = true;
            updateBadge();
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
