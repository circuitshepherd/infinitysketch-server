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
    // Sort state for the document table: an ORDERED list of keys, most significant
    // first, so "subscribers, then name" is expressible. One rule covers both
    // buttons — a click CYCLES a column asc -> desc -> off — and `additive`
    // (shift) is the only difference: without it the other columns are dropped
    // first, so a plain click always means "sort by just this one".
    function makeTableSort() {
      const COLUMNS = {
        name: (d) => d.name,
        sizeBytes: (d) => d.sizeBytes,
        seq: (d) => d.seq,
        subscribers: (d) => d.subscriberCount,
      };
      let keys = [];   // [{ column, dir }], dir: 1 ascending, -1 descending

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
      :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
      body { margin: 2rem auto; max-width: 720px; padding: 0 1rem; }
      h1 { font-size: 1.3rem; }
      #status { color: gray; font-size: 0.85rem; }
      table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
      td, th { padding: 0.5rem 0.75rem; border-bottom: 1px solid rgba(128,128,128,0.3); text-align: left; }
      img.thumb { width: 48px; height: 48px; object-fit: contain; background: rgba(128,128,128,0.15); border-radius: 4px; }
      .live { color: #2a9d2a; font-weight: 600; }
      th[data-sort] { cursor: pointer; user-select: none; -webkit-user-select: none; }
      th[data-sort]:hover { background: rgba(128,128,128,0.12); }
      .sortmark { font-size: 0.8em; color: gray; margin-left: 0.35rem; }
    </style>
    </head>
    <body>
    <h1>infsketch-server</h1>
    <div id="status">connecting…</div>
    \#(connectSection)
    <table>
      <thead><tr>
        <th></th>
        <th data-sort="name" tabindex="0" title="Click to sort. Shift-click to add a column, so the sort can be e.g. subscribers then name. A third click clears the column.">Document<span class="sortmark"></span></th>
        <th data-sort="sizeBytes" tabindex="0" title="Click to sort. Shift-click to add a column.">Size<span class="sortmark"></span></th>
        <th data-sort="seq" tabindex="0" title="Click to sort. Shift-click to add a column.">Seq<span class="sortmark"></span></th>
        <th data-sort="subscribers" tabindex="0" title="Click to sort. Shift-click to add a column.">Subscribers<span class="sortmark"></span></th>
      </tr></thead>
      <tbody id="docs"></tbody>
    </table>
    <script>
    \#(tableSortJS)

    const statusEl = document.getElementById("status");
    const docsEl = document.getElementById("docs");
    let refreshTimer = null;
    const sorter = makeTableSort();
    // The last payload, kept so a header click re-sorts what is on screen without
    // re-fetching — and so a status-event refresh cannot drop the user's sort.
    let docs = [];

    function esc(s) {
      return String(s).replace(/[&<>"']/g, c => ({
        "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
      }[c]));
    }

    function render() {
      docsEl.innerHTML = "";
      for (const d of sorter.apply(docs)) {
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

      return {
        get state() { return { scale, tx, ty, atFit, imgW, imgH, boxW, boxH }; },
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
        // A frame with a NEW pixel size keeps the same document region on screen:
        // the content scales about the shared origin, so tx/ty do not move. Both
        // frame sources are square (1024 live, 256 stored thumbnail), which is
        // what licenses the single k.
        setImageSize(w, h) {
          if (!imgW || !imgH) { imgW = w; imgH = h; this.fit(); return; }
          if (w === imgW && h === imgH) return;
          const k = w / imgW;
          imgW = w; imgH = h;
          if (atFit) { this.fit(); return; }
          scale = clampScale(scale / k);
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
          :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
          html, body { height: 100%; }
          body { margin: 0; display: flex; flex-direction: column; }
          header { display: flex; align-items: baseline; gap: 1rem;
                   width: 100%; max-width: 1100px; margin: 0 auto;
                   box-sizing: border-box; padding: 0.75rem 1rem 0.25rem; }
          h1 { font-size: 1.2rem; margin: 0; }
          #badge { font-size: 0.85rem; color: gray; }
          #badge.live { color: #2a9d2a; font-weight: 600; }
          #toolbar { display: flex; gap: 0.5rem; padding: 0.25rem 1rem 0.5rem; }
          #toolbar button { font: inherit; font-size: 0.85rem; padding: 0.2rem 0.7rem;
                            border: 1px solid rgba(128,128,128,0.5); border-radius: 6px;
                            background: transparent; color: inherit; cursor: pointer; }
          /* touch-action: none is load-bearing: the stage owns every gesture inside
             it (native pan/pinch suppressed HERE ONLY; the page keeps browser zoom). */
          #stage { flex: 1; overflow: hidden; position: relative;
                   touch-action: none; user-select: none; -webkit-user-select: none;
                   -webkit-touch-callout: none; cursor: grab;
                   background: rgba(128,128,128,0.1); }
          #stage.dragging { cursor: grabbing; }
          img#frame { position: absolute; left: 0; top: 0; transform-origin: 0 0; }
        </style>
        </head>
        <body>
        <header>
          <a href="/">← overview</a>
          <h1>\#(htmlId)</h1>
          <span id="badge">connecting…</span>
        </header>
        <div id="toolbar">
          <button id="fit" title="Fit the whole sketch (0)">Fit</button>
          <button id="one" title="One frame pixel per device pixel (1)">1:1</button>
          <button id="pause" title="Stop live re-rendering">Pause</button>
          <button id="wheelmode" title="What a plain wheel does"></button>
          <button id="respx" title="Requested live-frame resolution — the device renders at least this many pixels (it requests; a paused or absent device changes nothing)"></button>
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

        function render() {
          img.style.transform =
            `translate(${vp.state.tx}px, ${vp.state.ty}px) scale(${vp.state.scale})`;
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

        document.getElementById("fit").onclick = () => { vp.fit(); render(); };
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

        // Load into a detached Image and swap on load: assigning img.src directly
        // blanks the element for the whole download, once a second. On error keep
        // the last good frame. A zoomed inspection must never flicker.
        function refetch(tag) {
          const gen = ++loadGen;
          const probe = new Image();
          probe.onload = () => {
            if (gen !== loadGen) return;   // superseded by a newer frame
            img.src = probe.src;
            vp.setImageSize(probe.naturalWidth, probe.naturalHeight);
            render();
          };
          probe.src = `/api/docs/${encodeURIComponent(docId)}/frame?v=${tag}`;
        }

        function updateBadge() {
          if (paused) { badge.textContent = "paused"; badge.className = ""; return; }
          if (disconnected) {
            badge.textContent = "disconnected — retrying…";
            badge.className = "";
            return;
          }
          const fresh = Date.now() - lastFrameAt < 4000;
          badge.textContent = fresh ? "live"
            : (lastSeq === null ? "stale (no live client)" : `as of seq ${lastSeq}`);
          badge.className = fresh ? "live" : "";
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
