import Foundation

/// The `infsketch://guide` resource: the cross-cutting things an agent needs to know that do not
/// belong to any one tool.
///
/// **WHY THIS EXISTS.** Everything learned the hard way about this surface was being written into
/// the repository's `CLAUDE.md` — which is read by agents working on the CODEBASE and never by an
/// agent driving the MCP API. The knowledge was in the wrong place for the people who need it.
/// Per-tool traps belong in that tool's own description and are there; this covers what spans
/// tools, or what you need before you have picked one.
///
/// Every claim below was MEASURED against a live device while doing real work — building a chart,
/// laying out a floor plan, drawing two finished pictures — not inferred from the source. Where a
/// number appears, it came from an experiment.
///
/// Keep it SHORT. It is read in full, every time, by something with a budget. New entries earn
/// their place by having cost someone an hour; a fact that fits in one tool's description belongs
/// there instead.
enum AgentGuide {
    static let markdown = """
    # InfinitySketch: what to know before you draw

    You are editing a real document that a person may have open in front of you. Everything here \
    was measured while doing actual work, not inferred.

    ## Start here

    - **`list_docs`** — what exists. `open: true` means a device has it on screen, so your writes \
      land live on the user's canvas while they watch.
    - **`render_sketch`** — look at it. Your most useful tool by a distance: propose, render, \
      check, adjust. Its metadata carries the paper colour, every grid, and the viewport.
    - **`undo_last_edit`** — take back your own last write, on any document. Only your writes are \
      recorded, never the user's, so it can never reverse their work.

    ## Where to put things

    The canvas is 40 000 × 40 000 points and the user is looking at a small window of it, usually \
    nowhere near the origin. **Drawing at (100, 100) because it seems reasonable puts your work \
    tens of thousands of points off-screen.**

    `render_sketch`'s metadata reports `viewport.visibleRect` — the canvas rect the user can \
    actually see, with the toolbar and tool picker already subtracted. Compose inside it. It is \
    absent when nobody has the document open, which is the honest answer rather than a guess.

    Sizing matters as much as position: a phone shows roughly 440 × 810 points. A layout built for \
    an imagined 800-point width arrives cropped, and you will not find that out from any reply.

    ## Coordinates

    Every coordinate on this API is CANVAS space, both directions. `get_strokes` returns points \
    with the stroke's transform ALREADY applied; `reshape_strokes` inverts it for you. The \
    `transform` array on a response is informational — never something you apply yourself.

    **The one exception is `width`**, which is the stroke's own stamp size and does NOT include \
    its transform. This is deliberate: it is the same quantity `restyle_strokes` sets, so reading \
    a width and writing it back is a no-op rather than something that multiplies the stroke by its \
    own scale each time.

    It also could not be otherwise. Three strokes all reporting `width: 4`: one scaled 3× (renders \
    thick), one horizontal stretched 6× sideways (renders unchanged — the stretch runs along its \
    length), and one VERTICAL under that same stretch (renders six times fatter). Rendered \
    thickness depends on a stroke's direction at every point. **Use `bbox` for true on-screen \
    extent; `width` only compares meaningfully between strokes with the same transform.**

    ## Points, and the one asymmetry that will bite you

    `draw_strokes` reads your points as a POLYLINE: corners come out sharp, which is what a point \
    list usually means. `reshape_strokes` reads the same list VERBATIM, as spline knots, because a \
    reshape may be handing back a curve a human drew and re-sampling would flatten it.

    So the identical array means different things in the two tools. Send a rectangle to `reshape` \
    the way you sent it to `draw` and it comes back a rounded blob. Pass `smooth: false` to \
    reshape as a polyline. The reply tells you when corners were rounded — read it.

    ## Ink

    The inks differ in character, not just name, and you cannot see that from a listing:

    - **`monoline`** — opaque, uniform. The one for solid fills, flat colour, anything layered.
    - **`marker`** — wide and TRANSLUCENT. Colours build where strokes overlap and whatever is \
      underneath shows through. Painting a solid area with it leaves the paper visible.
    - **`pen`** — tapers with force; the everyday line.
    - **`pencil`** — textured, goes finest (minimum width 1.2 against 2.5 for the rest).

    Below its ink's minimum a stroke is effectively invisible, so widths under it are raised and \
    the reply says so. There is no fill primitive: solid regions are built from closely spaced \
    strokes, which works but costs a lot of them.

    ## Working alongside a person

    - **Name what you may need again.** `tag_elements`, or `name` at creation. Names live in the \
      document, so they outlast this task and this session — `find_elements` resolves them later. \
      Without one you cannot find your own axis again and will redraw the chart, taking the \
      user's annotations with it.
    - **Edit in place; never rebuild.** `reshape_strokes`, `restyle_strokes`, `transform_elements` \
      keep an element's identity and its history. Deleting and redrawing loses both.
    - **Snap candidates are ranked by DISTANCE, not by suitability.** `snap_points` returns every \
      plausible answer including from invisible and disabled grids. On the factory document the \
      three nearest candidates to a point all belong to an invisible 1 pt grid — "snap to where \
      you already are" — while the visible 20 pt intersection you actually want sorts LAST. \
      Reading `candidates[0]` puts your work between the drawn lines.
    - **The user can undo you** — one step per tool call — so an id you obtained earlier may be \
      gone. Re-read rather than caching.
    - **Errors carry the answer.** `unknownDoc` lists the documents that exist; \
      `noSelectionActive` names what IS open. Read the whole message before retrying.
    """
}
