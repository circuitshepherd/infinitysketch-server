import Foundation

/// The one palette and control vocabulary every server web page draws from.
///
/// **Why this is a Swift string and not a `/style.css` route.** A served stylesheet is the cleaner
/// CSS, but it makes each page depend on a second request whose failure mode is *an unstyled page* —
/// exactly the "half-arrive" failure `ConnectPanel`'s own header comment exists to prevent — and it
/// would break the tests that assert on returned HTML. So the tokens travel INSIDE each page, which
/// also keeps the server's no-build-step, no-external-asset property: this is a LAN server, often
/// reached by a device with no internet at all.
///
/// `tokens` deliberately carries **no `<style>` wrapper**. Every page already has one; a caller
/// interpolates this into it and keeps its own page-specific rules local.
///
/// **Every colour is defined on bare `:root` and only REDEFINED under the dark media query.** A
/// colour whose only definition lives inside `@media (prefers-color-scheme: dark)` is absent in
/// light mode, and `var()` then silently yields its fallback — a failure with no error anywhere.
/// `WebStyleTests` pins both that rule and the absence of any `var(--…)` no token defines.
public enum WebStyle {

    /// Custom properties, base element rules, and the three component classes shared across pages.
    public static let tokens = """
      :root {
        color-scheme: light dark;
        --font: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
        --font-mono: ui-monospace, SFMono-Regular, Menlo, monospace;
        --bg: #f2f2f7;
        --surface: #ffffff;
        /* The viewer's backdrop, deliberately its OWN token rather than --bg. A frame's padding
           is PAPER-coloured, so the surround has to differ from paper at both extremes or the
           document's edge vanishes — measured: a near-black sketch on a pure-black stage had no
           visible boundary at all. */
        --stage: #e3e3e8;
        --fg: #1d1d1f;
        --fg-dim: #6e6e73;
        --line: rgba(0, 0, 0, 0.12);
        --accent: #007aff;
        --live: #2a9d2a;
        /* A plain rgba(), never color-mix(): the overlay bar must need no support caveat. */
        --bar: rgba(255, 255, 255, 0.82);
        --radius: 10px;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #000000;
          --surface: #1c1c1e;
          --stage: #2c2c2e;
          --fg: #f5f5f7;
          --fg-dim: #98989d;
          --line: rgba(255, 255, 255, 0.16);
          --accent: #0a84ff;
          --live: #30d158;
          --bar: rgba(28, 28, 30, 0.82);
        }
      }

      body {
        font-family: var(--font);
        color: var(--fg);
        background: var(--bg);
        -webkit-font-smoothing: antialiased;
      }
      a { color: var(--accent); }
      h1, h2, h3 { font-weight: 600; letter-spacing: -0.01em; }
      code, kbd { font-family: var(--font-mono); }

      /* A control that reads as a button on every page. `font: inherit` first, or the
         browser's own tiny form font wins and the label looks unstyled. */
      .btn {
        font: inherit;
        font-size: 0.85rem;
        line-height: 1;
        padding: 0.4rem 0.75rem;
        border: 1px solid var(--line);
        border-radius: 7px;
        background: var(--surface);
        color: var(--fg);
        cursor: pointer;
        -webkit-appearance: none;
        appearance: none;
      }
      .btn:hover { border-color: var(--accent); color: var(--accent); }
      .btn:active { transform: translateY(0.5px); }
      .btn.on { border-color: var(--accent); color: var(--accent); font-weight: 600; }

      .chip {
        font: inherit;
        font-size: 0.8rem;
        padding: 0.25rem 0.65rem;
        border-radius: 999px;
        border: 1px solid var(--line);
        background: transparent;
        color: var(--fg);
        cursor: pointer;
      }
      .chip.selected { border-color: var(--live); color: var(--live); font-weight: 600; }

      /* Status text. `.live` is the same green as the app toolbar's status dot. */
      .badge { font-size: 0.85rem; color: var(--fg-dim); }
      .badge.live { color: var(--live); font-weight: 600; }
      """
}
