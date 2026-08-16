# InfinitySketch MCP tools

54 tools, served over streamable HTTP at `/mcp`.

<!-- Generated from MCPAdapter.toolDefinitions. Do not edit by hand: run
     INFSKETCH_REGENERATE_DOCS=1 swift test --filter ToolReferenceTests -->

Every tool declares `additionalProperties: false`, so an argument a tool does not list
below is rejected by name rather than ignored. Reads work with no device connected;
authoring strokes, styling text and rendering need at least one device, because only
PencilKit can produce or rasterize stroke data.

Read [`infsketch://guide`](../Sources/InfSketchServerKit/MCP/AgentGuide.swift) first —
it carries the rules that span tools. This page is the per-tool detail.

## Documents

A `docId` is a filename stem. Writes are compare-and-swap guarded by bytes; a stale write is rejected with `docChangedDuringOp` rather than clobbering.

| Tool | Summary |
|---|---|
| [`list_docs`](#list_docs) | Every document on the server: `{id, sizeBytes, modifiedAt, hasContent, open}`, newest-modified first. |
| [`list_open_docs`](#list_open_docs) | What is OPEN right now, and on what. |
| [`create_doc`](#create_doc) | Creates a new document containing the InfinitySketch app's empty default content, authored by a connected InfinitySketch device. |
| [`fetch_doc`](#fetch_doc) | Ensures a document's content is available on the server, pulling it from a device that holds it if the server has only its metadata (a "content on another device" doc — see the… |
| [`replace_doc`](#replace_doc) | Replaces a document's raw bytes wholesale, creating it if it doesn't yet exist. |
| [`delete_doc`](#delete_doc) | Delete a document from the server. |
| [`merge_docs`](#merge_docs) | Merges document `source` INTO document `target` by element identity (strokes by their composite key, texts/images by id): every element of both docs survives, shared elements… |
| [`set_paper`](#set_paper) | Sets a document's paper appearance: `light` (the paper colour in light mode), `dark` (the paper colour in dark mode), and/or `transparent` (a transparent background).… |
| [`undo_last_edit`](#undo_last_edit) | Take back YOUR OWN last write to a document — the one you just made and wish you had not. |

## Strokes

Geometry is canvas space in both directions. `stampWidth` is a stroke's own ink size, which a transform does not scale — see `canvasInkBounds` for the true on-screen extent.

| Tool | Summary |
|---|---|
| [`draw_strokes`](#draw_strokes) | Draws one or more freehand strokes into a document, authored by a connected InfinitySketch device. |
| [`draw_dots`](#draw_dots) | Draw solid round dots — junction dots on a schematic, plotted data points, bullets, the centre of a pivot. |
| [`fill_region`](#fill_region) | Fill a closed path with a solid area — one call instead of the hundreds of closely spaced strokes you would otherwise compute yourself. |
| [`list_strokes`](#list_strokes) | Lists every stroke currently in a document — each with its id (usable with delete_strokes), geometry, and bbox/pathBounds — authored by a connected InfinitySketch device. bbox is… |
| [`get_strokes`](#get_strokes) | Reads strokes in full fidelity: every point with its size, opacity, force, azimuth, altitude, timeOffset and secondaryScale, plus the stroke's width, colour, inkType, transform,… |
| [`reshape_strokes`](#reshape_strokes) | Replaces strokes' geometry in place, keeping their identity (id), ink, z-order and width-edit history. |
| [`restyle_strokes`](#restyle_strokes) | Changes strokes' colour, width and/or ink in place; identity and geometry survive. |
| [`transform_strokes`](#transform_strokes) | Moves, scales and/or rotates strokes in place. |
| [`restore_stroke_widths`](#restore_stroke_widths) | Takes the SCALE back off the ink of strokes that were scaled, leaving them exactly where they are on the canvas. |
| [`delete_strokes`](#delete_strokes) | Deletes one or more strokes from a document by their composite stroke keys (as returned by list_strokes), authored by a connected InfinitySketch device. |

## Text

Plain text is written server-side; styled text and every listing need a connected device, because a laid-out size is UIKit-only.

| Tool | Summary |
|---|---|
| [`add_text`](#add_text) | Appends a placed-text entry to a document: a new id, the document's current colour scheme, and an identity transform/opacity. (canvasX, canvasY) is the text box's top-left corner. |
| [`edit_text`](#edit_text) | Mutates an existing placed text by id: replace its string and/or move it, or restyle it with color/fontSize/bold/italic/family (whole-field) or a `spans` array (parts of it… |
| [`remove_text`](#remove_text) | Removes a placed text entry from a document by id. |
| [`list_texts`](#list_texts) | Lists a document's placed texts, one per text, as {id, text, bounds:[x,y,w,h] (canvas space), pinned, opacity} — authored by a connected InfinitySketch device. |
| [`list_fonts`](#list_fonts) | The font families installed on the connected device, sorted. |

## Images

`add_image` takes a path on the machine the server runs on. There is no base64 argument — transcribing one by hand is what corrupted the image that removed it.

| Tool | Summary |
|---|---|
| [`add_image`](#add_image) | Place an image into a document. `path` names an image FILE ON THE MACHINE THIS SERVER RUNS ON — it must be absolute (a leading ~ is expanded), and the server reads it itself, so… |
| [`list_images`](#list_images) | Lists a document's placed images, one per image, as {id, bounds:[x,y,w,h] (canvas space), pinned, opacity} — authored by a connected InfinitySketch device. |
| [`remove_image`](#remove_image) | Remove a placed image from a document by its id (as returned by add_image or reported by get_selection). unknownDoc if the document doesn't exist; imageNotFound if no placed image… |

## Grids

`visible` (drawn) and `enabled` (snapped-to) are independent. `snap` is a MULTIPLIER of `spacing`, not a distance.

| Tool | Summary |
|---|---|
| [`list_grids`](#list_grids) | Lists a document's grids, one per grid, as {id, type, spacing, snap, rotation, offset, pivot, color, thickness, visible, enabled, families} — authored by a connected… |
| [`add_grid`](#add_grid) | Adds a new grid to a document, authored by a connected InfinitySketch device. |
| [`update_grid`](#update_grid) | Modifies an existing grid's supplied fields only (present-only), authored by a connected InfinitySketch device. |
| [`remove_grid`](#remove_grid) | Removes a grid from a document by its id, authored by a connected InfinitySketch device. |
| [`reorder_grids`](#reorder_grids) | Sets the draw order (z-order) of a document's grids, authored by a connected InfinitySketch device. `orderedIds` must be a full permutation of the document's current grid ids (as… |
| [`set_grid_origin`](#set_grid_origin) | Sets a grid's pivot to an EXACT canvas coordinate — the programmatic equivalent of the app's tap-to-pick-origin gesture — so the lattice passes through (canvasX, canvasY): the… |
| [`snap_points`](#snap_points) | Where could these points snap to? Returns CANDIDATES — it never moves anything, and it never decides for you. |

## Elements

Strokes, texts and images addressed by id, whatever their kind. Resolve a tag to ids with `find_elements`, then act with the id-taking tools.

| Tool | Summary |
|---|---|
| [`tag_elements`](#tag_elements) | Give elements durable TAGS, so you can find your own work again later — the strokes that make up a roof, the series of markers on a plot, the text that titles a chart. |
| [`find_elements`](#find_elements) | Resolve TAGS to element ids, so you can act on them with any tool that takes ids. |
| [`list_tags`](#list_tags) | Every tag in a document, with how many live things carry it, split by family. |
| [`transform_elements`](#transform_elements) | Move, scale or rotate named strokes, texts AND images together — on ANY document, open or not. |
| [`reorder_elements`](#reorder_elements) | Sets the z-order (draw order) of named strokes/texts/images within ONE document — bring-to-front or send-to-back, authored by a connected InfinitySketch device. |
| [`set_pinned`](#set_pinned) | Sets the `pinned` (background) flag on the named placed texts and/or images of a document. `ids` may mix text ids and image ids (as returned by… |
| [`copy_elements`](#copy_elements) | Copies named strokes/texts/images from document `source` INTO document `target`, as FRESH clones (fresh ids) — unlike merge_docs, elements are never deduped by identity, so… |

## Selection

These act on the LIVE rect-select session on a connected device, not on document bytes, and land as one undo step each.

| Tool | Summary |
|---|---|
| [`select_all`](#select_all) | Select every stroke, placed text, and placed image in the document on a connected device's live rect-select, replacing any existing selection — the agent equivalent of the user's… |
| [`select_elements`](#select_elements) | Select specific elements by id on a connected device's live rect-select, replacing any existing selection. |
| [`clear_selection`](#clear_selection) | Clear the user's live rect-select selection on a connected device, returning it to idle — the agent equivalent of tapping outside the selection or hitting Escape. |
| [`get_selection`](#get_selection) | Read the user's CURRENT live rect-select selection on a connected device. |
| [`set_reference_point`](#set_reference_point) | Place the reference point the user's live selection pivots/rotates/scales around, at the given CANVAS coordinates — the same point a manual rect-select drag drops. |
| [`transform_selection`](#transform_selection) | Transform the user's live selection exactly as a manual rect-select transform would (one undoable step). `ops` is a list of 1 to 16 operations, composed left-to-right into one… |
| [`preview_selection`](#preview_selection) | Preview a proposed transform of the user's live selection WITHOUT committing anything — the agent's scratchpad for a selection edit, the same role render_sketch's ephemeral… |
| [`duplicate_selection`](#duplicate_selection) | Duplicate the user's live selection on a connected device. |
| [`draw_selection`](#draw_selection) | Draw strokes into the user's LIVE rect-select selection AND select them, in one step. `strokes` takes the same shape as draw_strokes. |
| [`restyle_selection`](#restyle_selection) | Restyle the strokes in the user's LIVE rect-select selection — `color` (#RRGGBB/#RRGGBBAA), `width` (target peak stroke width), and/or `inkType` (pen/pencil/marker/monoline). |
| [`delete_selection`](#delete_selection) | Delete everything in the user's LIVE rect-select selection, exactly as the toolbar's Delete does — one undo step, canvas refreshed immediately. noSelectionActive if nothing is… |

## Reading the canvas

Read-only. `render_sketch` also renders ephemeral candidate strokes that are never written anywhere — synthesize, render, refine, then commit.

| Tool | Summary |
|---|---|
| [`render_sketch`](#render_sketch) | Renders a region of a document, specific strokes, and/or ephemeral candidate strokes that are not written to the document — use it to preview a stroke before committing it with… |
| [`get_tool`](#get_tool) | Report the tool picker's CURRENT tool on the connected device — `isInkingTool`, and when true `inkType`, `toolWidth`, `stampWidth` and `color` (#RRGGBBAA). |


---

## Documents — reference

### `list_docs`

Every document on the server: `{id, sizeBytes, modifiedAt, hasContent, open}`, newest-modified first. START HERE when you do not already have a docId — every other tool takes one, and this is the tool that tells you what they are.

`open` means a device has it on screen right now, so your writes land live on the user's canvas; use list_open_docs when you want the device and capability detail as well. `hasContent: false` means the bytes live on a device rather than here — every content tool fetches those for you automatically, or call fetch_doc to pull one explicitly. An empty list means the server holds no documents at all.

REPLY: an ARRAY of `{id, sizeBytes, modifiedAt, hasContent, open}`, newest first.

Takes no arguments.

### `list_open_docs`

What is OPEN right now, and on what. Read-only, no device round trip, no docId needed. Returns `{devices: {count, capabilities}, openDocs: [{docId, seq, subscribers}]}`.

CALL THIS INSTEAD OF GUESSING A docId FROM CONVERSATION. A document's `docId` is its filename stem, so the name a human says ("grok2 test") can differ from the live id ("Untitled 16 1 1") — and every tool aimed at the spoken name fails against a device that is working perfectly. A rename moves the id with the file, so what remains is an id quoted from earlier in the conversation, a document whose sync is off, and one skipped as a same-stem duplicate. `openDocs` is the truth: those are the ids the selection tools, and every write to an open document, will accept.

An empty `openDocs` with `devices.count == 0` means no device is connected at all (open the app with the mirror enabled, and check it points at THIS server's port). An empty `openDocs` with a non-zero count means a device is connected but has no document open — ask the user to open one; no amount of retrying will help. `capabilities` is the union of what the connected devices can do, which is what every `noDeviceAvailable` is ultimately about.

Takes no arguments.

### `create_doc`

Creates a new document containing the InfinitySketch app's empty default content, authored by a connected InfinitySketch device. REQUIRES such a device to be connected to the server — fails with noDeviceAvailable if none is, deviceTimeout if it doesn't respond in time, and docExists if a document with this id already exists.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to create. |

### `fetch_doc`

Ensures a document's content is available on the server, pulling it from a device that holds it if the server has only its metadata (a "content on another device" doc — see the hasContent hint in the resource list). Read-only: it promotes the document to server content but authors nothing. Call it before other tools if you want to control when the (possibly multi-second) transfer happens; otherwise the content tools fetch on demand themselves. Errors: contentUnavailable (the holding device isn't online), unknownDoc.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to fetch. |

### `replace_doc`

Replaces a document's raw bytes wholesale, creating it if it doesn't yet exist. The bytes are opaque to the server — the agent owns their validity, the same trust any other writer on the network has. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `bytes` | string | yes | Base64-encoded .infsketch document bytes. |
| `docId` | string | yes | The document id to write. |

### `delete_doc`

Delete a document from the server. The document is moved to the server's .trash directory rather than destroyed, so a mistaken delete is recoverable by hand. Server-side, no device needed. unknownDoc if the document doesn't exist. Note the server keeps NO record of the deletion: a device that still holds the document may re-advertise or re-push it, which brings it back. A device with the document currently open keeps its copy and stops syncing it.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to delete. |

### `merge_docs`

Merges document `source` INTO document `target` by element identity (strokes by their composite key, texts/images by id): every element of both docs survives, shared elements dedupe, and a same-key clash is broken by `prefer` (default "target"). `target` becomes the union; `source` is left untouched. With `into`, the union is written to a new document and both inputs are left untouched (docExists if `into` is taken). REQUIRES a connected device with the mergeDocs capability — fails with noDeviceAvailable if none is connected, sourceNotFound / targetNotFound if either document is absent, and deviceFailed: <reason> if the device rejects the merge. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `source` | string | yes | The document to merge FROM (left unchanged). |
| `target` | string | yes | The document to merge INTO (becomes the union). |
| `into` | string | no | Optional: write the union to a NEW document with this id, leaving both source and target untouched. docExists if the name is already taken. |
| `prefer` | string — `source`, `target` | no | Which side wins a same-key clash. Default target. |

### `set_paper`

Sets a document's paper appearance: `light` (the paper colour in light mode), `dark` (the paper colour in dark mode), and/or `transparent` (a transparent background). `light`/`dark` are #RRGGBB or #RRGGBBAA hex. At least one field is required. Light and dark are set independently (no automatic light<->dark derivation). Server-side, no device needed; applies live to an open document with no banner. unknownDoc if the document doesn't exist; invalidSpec on a bad hex colour; invalidArguments if no field is given. Unlike the colorAppearance door elsewhere on this surface, `light` and `dark` here are each the LITERAL value for that appearance — nothing is converted between them. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `dark` | string | no | Dark-mode paper colour, #RRGGBB or #RRGGBBAA. |
| `light` | string | no | Light-mode paper colour, #RRGGBB or #RRGGBBAA. |
| `transparent` | boolean | no | Whether the background is transparent. |

### `undo_last_edit`

Take back YOUR OWN last write to a document — the one you just made and wish you had not. Reaches edits made whether or not the document is open, which the user's own Undo cannot.

Only YOUR writes are recorded, never the user's own drawing, so this can never reverse their work. One undo = one tool call, the same unit the app registers, and `steps` walks further back one call at a time.

If the document changed after your write, it is MERGED rather than refused: your change is reversed and everything that happened since is kept. That path needs a connected device; an unchanged document does not. There is no redo — but an undo is itself a write, so undoing it again does the obvious thing. History is bounded and in memory, so a much older edit answers `nothingToUndo`.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to undo an edit in. |
| `steps` | integer | no | How many of your own edits to take back, newest first. Default 1. |

---

## Strokes — reference

### `draw_strokes`

Draws one or more freehand strokes into a document, authored by a connected InfinitySketch device. Each stroke is a list of (x, y) points in canvas coordinates — the same space as add_text's x/y — plus optional width, color, inkType, and smooth fields. Points are a POLYLINE by default (smooth: false, the default): straight segments and sharp corners, which is almost certainly what you mean. Set smooth: true to have them treated as spline knots and smoothly interpolated instead — useful for a curve given as a few sparse points; PencilKit splines THROUGH its control points, so a sparse polyline misread as knots renders as a rounded blob, not the shape you asked for. (reshape_strokes defaults smooth the OPPOSITE way — verbatim by default.) Other defaults for any stroke that omits them: inkType "pen", width 4, and a colour that FOLLOWS THE PAPER — white on a dark document, black on a light one (never a hardcoded #000000, which renders invisible on dark paper). An explicit color is always honoured exactly as given, and is LIGHT-CANONICAL — pass colorAppearance: "dark" when you picked colours for how they look on the dark canvas; the device converts them before storing, and the reply's storedColors array (one entry per created stroke, present only when the dark door was used) reports what was actually stored. The result names the seq the write was assigned, and the id of each stroke it created, in the order supplied — use those, not a bounding-box guess, to revise exactly what you just drew with get_strokes/transform_strokes/restyle_strokes/reshape_strokes/delete_strokes. REQUIRES a connected device — fails with noDeviceAvailable if none is connected, deviceTimeout if it doesn't respond in time, opInProgress if another stroke operation on this document is already in flight, and deviceFailed: <reason> if the device rejects the strokes (e.g. malformed points). Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `strokes` | array | yes | One or more strokes to draw. Passed through to the device verbatim; the item properties below are the exact field names the device decodes. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |

Each item of `strokes`:

| Field | Type | Required | Description |
|---|---|---|---|
| `canvasPoints` | array | yes | The stroke's polyline; at least 2 points. Each point is either an [x, y] pair or a rich point object. |
| `color` | string | no | Stroke colour as #RRGGBB or #RRGGBBAA hex. OMIT IT to inherit the colour of the tool the user currently has selected in the picker (see get_tool); falls back to a paper-contrasting default when no inking tool is selected. Light-canonical (the light-appearance value); see colorAppearance. |
| `inkType` | string — `pen`, `pencil`, `marker`, `monoline`, `fountainPen`, `watercolor`, `crayon` | no | The ink to draw with. OMIT IT to inherit the ink the user currently has selected (see get_tool); pen when no inking tool is selected. THEY DIFFER IN CHARACTER, not only in name, and you cannot see that from a listing: `pen` is opaque and even — reach for it for solid fills, flat colour, and anything you layer; `marker` is wide and TRANSLUCENT, so colours build where strokes overlap and whatever is underneath shows through (painting a solid area in marker leaves the paper visible between passes); `pencil` is textured and goes finest, with a minimum width of 1.2 against 2.5 for the others; `fountainPen`, `watercolor` and `crayon` are expressive — try them and look. Below an ink's minimum a stroke is effectively INVISIBLE, so widths under it are raised and the reply says so. `monoline` is accepted and READS BACK AS `pen`. Nothing went wrong: PencilKit records it as pen when the document is saved, and the two are pixel-identical for strokes you author — monoline means "hold the width constant whatever the pressure", which yours already do. |
| `smooth` | boolean | no | How to read `points`. DEFAULT false: they are a POLYLINE — straight segments, sharp corners, which is almost certainly what you mean. Set true to have them treated as spline knots and smoothly interpolated (useful for a curve given as a few sparse points) — PKStrokePath splines THROUGH its control points, so a sparse polyline misread as knots renders as a rounded teardrop, not the shape you asked for. Note reshape_strokes defaults the OTHER way. A polyline too corner-dense to fit the 4000-point canonical budget fails loudly — send fewer points, or split the shape into several strokes. smooth: true is NOT the escape from that: it skips the budget (the verbatim path has no point cap of its own, only the message-size limit) precisely BECAUSE it does no corner work at all, so every sharp corner then comes out rounded. |
| `stampWidth` | number | no | Peak STAMP width — the stroke's own ink size, which a transform does NOT scale (canvasInkBounds shows its true on-screen extent). OMIT IT to inherit the width of the tool the user currently has selected (see get_tool). |

### `draw_dots`

Draw solid round dots — junction dots on a schematic, plotted data points, bullets, the centre of a pivot. Each dot is ONE stroke you can select, name, move, restyle or delete as a single thing.

`diameter` is what you would measure on the canvas, ink included, and defaults to 8. It is honoured exactly for any dot bigger than the ink can draw as a line; a smaller one is raised to that minimum and the reply says which.

Do NOT fake a dot with a short wide stroke: round caps at each end of a segment make a STADIUM (length + width) × width, which is visibly oval at the sizes a dot is used at. Each dot's `color` is light-canonical; pass colorAppearance: "dark" if you picked it for the dark canvas — the reply's storedColors array (one entry per created dot, present only when the dark door was used) reports what was actually stored. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `dots` | array | yes | The dots to draw. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |

Each item of `dots`:

| Field | Type | Required | Description |
|---|---|---|---|
| `canvasX` | number | yes | Centre x, canvas coordinates. |
| `canvasY` | number | yes | Centre y, canvas coordinates. |
| `color` | string | no | #RRGGBB or #RRGGBBAA. Omit to inherit the user's pen. Light-canonical (the light-appearance value); see colorAppearance. |
| `diameter` | number | no | Outer diameter on the canvas, ink included. Default 8. |
| `inkType` | string | no | Default pen, which is opaque and even. marker is TRANSLUCENT, so a dot drawn with it shows a darker core where the centre and the rim overlap. |
| `tags` | array | no | Durable tags, so find_elements can reach this again later. |

### `fill_region`

Fill a closed path with a solid area — one call instead of the hundreds of closely spaced strokes you would otherwise compute yourself. The strokes are generated on the device and are ORDINARY strokes: the user can erase part of the fill, select inside it, restyle it, and it ink-adapts on a dark/light flip, exactly like anything they drew.

`canvasPoints` is the boundary in canvas coordinates, closed by repeating the first point (an unclosed path is closed for you). Concave shapes fill correctly, and a path that returns through itself leaves a hole rather than blocking it out.

`inkType` defaults to **pen** on purpose: marker is TRANSLUCENT and builds up where passes overlap, so a fill made from it shows the paper through. `spacingRatio` is the scanline spacing as a fraction of the stroke width — it defaults to 0.4, which overlaps by more than mere coverage so the fill stays even when the canvas is zoomed out or exported small; below 1 the passes overlap and it reads solid (default 0.8), above 1 you get visible hatching, and `angleDeg` turns the hatch.

A SOLID fill is ONE stroke: the passes are joined into a serpentine, so you can select, name, restyle or move the filled area as a single thing. It also traces its own boundary, centred, at the same `stampWidth` — that border is what you see at the edge. Pass `border: false` when part of your outline is construction rather than a real edge (a silhouette closed along a base line does not want that line drawn) — but note it is ALL OR NOTHING: with it off, EVERY edge shows the scalloping the round pass-ends leave, not just the construction one. Measured: a plain rectangle drawn with border:false has visibly wavy sides. If only one edge is construction, keep the border and cover that edge, or draw the edges you want yourself with draw_strokes.

TWO HONEST LIMITS. The document still carries every stroke, so a large fill is genuinely large — the reply tells you how many were made, and past 4 000 passes the call fails and names the spacing that would fit rather than handing back a half-filled shape. And a fill does not RESHAPE: move, scale, rotate and restyle all take the fill and its border together, because they are one stroke, but changing the boundary to a different SHAPE does not re-fill it. You hold the outline, so give the fill a `name` and reshape it by deleting it and filling the new outline under that same name. `color` is light-canonical; pass colorAppearance: "dark" if you picked it for the dark canvas — the reply's storedColors array (one entry per pass/border stroke, present only when the dark door was used) reports what was actually stored. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `canvasPoints` | array | yes | The boundary, in canvas coordinates; at least 3 points. |
| `docId` | string | yes | The document id to modify. |
| `angleDeg` | number | no | Direction of the passes; 0 is horizontal. |
| `border` | boolean | no | Trace the boundary, centred on it, at stampWidth. Default true — it covers the scalloped edge the round pass-ends leave. Set FALSE when part of your boundary is CONSTRUCTION rather than a real edge: a mountain silhouette closed along a base line does not want that base line drawn across the picture. |
| `color` | string | no | #RRGGBB or #RRGGBBAA. Omit to inherit the user's pen. Light-canonical (the light-appearance value); see colorAppearance. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |
| `inkType` | string — `pen`, `pencil`, `marker`, `monoline`, `fountainPen`, `watercolor`, `crayon` | no | Defaults to pen, which is opaque and even. monoline is accepted and reads back as pen. |
| `spacingRatio` | number | no | Spacing as a fraction of the width. < 1 solid (default 0.8), > 1 hatched. |
| `stampWidth` | number | no | Width of each pass. Also sets the spacing, via spacingRatio. |
| `tags` | array | no | Durable tags for the filled area, so you can find it again with find_elements after this call's ids are gone — which is how you reshape a fill: delete it and fill the new outline under the same tag. A hatched fill gets them too: it is several strokes, and a tag is a set. |

### `list_strokes`

Lists every stroke currently in a document — each with its id (usable with delete_strokes), geometry, and bbox/pathBounds — authored by a connected InfinitySketch device. bbox is the INK box (renderBounds: cap + antialias bleed, so it reads WIDER than what you placed — e.g. pins placed 80 pt apart show a bbox around 86); pathBounds is the box of the stroke's points — what you actually placed. Use pathBounds to verify geometry you positioned.

`width` is the stroke's own STAMP width and does NOT include any transform it carries, while its coordinates DO — so a stroke that was scaled up reports tripled bounds and an unchanged width, and two strokes both reporting `width: 4` can render three times apart. That matters for exactly one intent: matching a new stroke to an existing one. Call get_strokes for that stroke — it reports the `transform`, and stamp width times its scale is what you see. (This is deliberate: `width` is the same quantity restyle_strokes SETS, so reading one and writing it back is consistent.)

This tool does not report grids — render_sketch's metadata does, including each grid's id (what snap_points' gridIds and transform_strokes' snapTo refer to). REQUIRES a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. Returns the device's listing verbatim as text; this call never writes to the document. A stroke drawn by hand with an ink outside pen/pencil/marker (fountain pen, watercolour, crayon…) lists under that ink's name but cannot be re-drawn with draw_strokes, whose inkType enum covers only the four names above.

REPLY: an ARRAY of `{id, canvasInkBounds, canvasPathBounds, color, inkType, stampWidth, pointCount, tags}`. `canvasInkBounds` is the INK's extent (cap and antialias included) and `canvasPathBounds` is the control points' box — use the latter to verify placement, the former for true on-screen size. `color` is the stored LIGHT-CANONICAL hex; on a dark document what you SEE is its conversion, not this value.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to list strokes from. |

### `get_strokes`

Reads strokes in full fidelity: every point with its size, opacity, force, azimuth, altitude, timeOffset and secondaryScale, plus the stroke's width, colour, inkType, transform, bbox and pathBounds. Point x/y are CANVAS coordinates — the stroke's transform is ALREADY applied to them, so they are the coordinates you see in render_sketch and the ones transform_strokes moves in; the returned transform array is informational, never something you apply yourself. bbox is the INK box (it includes cap and antialias bleed, so it reads wider than what you placed); pathBounds is the box of the stroke's points — use pathBounds to verify geometry you positioned. width is the stroke's peak stamp width — the quantity restyle_strokes' width sets — and is NOT scaled by the transform, so a scaled stroke renders proportionally wider than its width says (bbox and render_sketch show its true extent). Field names are symmetric with draw_strokes/reshape_strokes, so a fetch → alter → put-back needs no translation and loses nothing: handing the points straight back to reshape_strokes (whose smooth defaults to true — verbatim) changes nothing at all. Nothing is capped or decimated by the server — use list_strokes' pointCount to price a fetch first, and maxPoints if you want a guard of your own; a request over that guard fails with pointBudgetExceeded(<actual>), naming the real total. Note: a stroke asked for in `monoline` lists back as `pen` — PencilKit records it that way and the two are identical on the page. This tool does not report grids — render_sketch's metadata does, including each grid's id (what snap_points' gridIds and transform_strokes' snapTo refer to). Read-only.

REPLY: an ARRAY of `{id, canvasPoints, canvasPathBounds, localToCanvasTransform, color, inkType, stampWidth, pointCount}`. NOTE there is no `canvasInkBounds` here — only list_strokes reports it. `color` is the stored LIGHT-CANONICAL hex; on a dark document what you SEE is its conversion, not this value.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to read strokes from. |
| `ids` | array | yes | Composite stroke ids, as returned by list_strokes or draw_strokes. |
| `maxPoints` | integer | no | YOUR OWN budget guard, not a server limit: fails with pointBudgetExceeded(<actual>) if the request's total point count exceeds this. Omit for no limit. |

### `reshape_strokes`

Replaces strokes' geometry in place, keeping their identity (id), ink, z-order and width-edit history. Points are CANVAS coordinates — the same space get_strokes returns and render_sketch shows — so you straighten a stroke by naming the canvas coordinates you can SEE, and it lands exactly there: the stroke's transform is preserved and accounted for on your behalf (never re-applied on top of your points). Handing back the exact points get_strokes gave you changes nothing. Points are used VERBATIM by default (smooth: true — the OPPOSITE of draw_strokes' default), because a reshape may be handing back a stroke a HUMAN drew, and re-sampling it would flatten their curve. Pass smooth: false to read them as a polyline with sharp corners instead. Attributes you OMIT on a point are resampled from the ORIGINAL stroke along the new path — so straightening a wobbly line with plain [x, y] pairs keeps its pressure taper. Supply attributes explicitly to override that. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `strokes` | array | yes | One or more strokes to reshape by id. |

Each item of `strokes`:

| Field | Type | Required | Description |
|---|---|---|---|
| `canvasPoints` | array | yes | The new polyline; at least 2 points. Each point is either an [x, y] pair or a rich point object. |
| `id` | string | yes | The id of the stroke to reshape. |
| `smooth` | boolean | no | DEFAULT true here (the OPPOSITE of draw_strokes): the points are used verbatim, because a reshape may be round-tripping a stroke a HUMAN drew and canonicalizing it would sharpen turns they drew round (and break the exact get_strokes round-trip). Pass false to read them as a polyline with sharp corners — that path canonicalizes, and fails loudly if the polyline is too corner-dense for the 4000-point budget. Dropping back to the verbatim default is not an equivalent escape from that failure: verbatim has no point budget only because it does no corner work, so the corners render rounded. |

### `restyle_strokes`

Changes strokes' colour, width and/or ink in place; identity and geometry survive. At least one of color, width, or inkType must be supplied — omitting all three is rejected. width is the TARGET PEAK stroke width — the same quantity get_strokes/list_strokes report, not a tool-slider value — and is CLAMPED to what the target ink can express (pen tops out around peak 6; marker cannot render below roughly 7.5), so a thin pen stroke necessarily gets thicker when restyled to marker. THE REPLY SAYS SO when it happens, naming what you asked for and what it became, so you do not have to call list_strokes to find out; get_strokes reports the actual resulting peak either way. An ink-only restyle (no width) preserves the stroke's apparent thickness. A colour-only restyle changes nothing else. One user-visible cost, worth knowing before you restyle a stroke the user has never width-edited: the app can afterwards restore that stroke's original width only APPROXIMATELY, because the tool-slider value the user drew with is not recorded anywhere and cannot be recovered from the stroke (a colour-only restyle, and any stroke the user HAS width-edited, are unaffected). Note: `monoline` reads back as `pen` — PencilKit's archive format does not preserve it. `color` is LIGHT-CANONICAL — pass colorAppearance: "dark" if you picked it for the dark canvas; the device converts it before storing, and the reply's storedColor reports what was actually stored. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `ids` | array | yes | Composite stroke ids, as returned by list_strokes or draw_strokes. |
| `color` | string | no | #RRGGBB or #RRGGBBAA. Light-canonical (the light-appearance value); see colorAppearance. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |
| `inkType` | string — `pen`, `pencil`, `marker`, `monoline`, `fountainPen`, `watercolor`, `crayon` | no | Note: `monoline` reads back as `pen` — PencilKit records it that way, and the two are identical on the page. |
| `stampWidth` | number | no | Target PEAK STAMP width (> 0) — the stroke's own ink size, the same quantity get_strokes/list_strokes report, not a tool-slider value. Clamped to what the target ink can express (pen tops out around peak 6; marker cannot go below roughly 7.5) — get_strokes reports the actual resulting peak. |

### `transform_strokes`

Moves, scales and/or rotates strokes in place. The strokes keep their identity (ids), their points and their z-order — only their placement changes. canvasTranslate and canvasAnchor are CANVAS coordinates: the same space get_strokes' points, list_strokes' bbox and render_sketch are quoted in. Scale and rotate act about canvasAnchor, which defaults to the centre of the ids' union bounding box. TO SNAP, pass snapToGrid: true, or snapTo, or both — EITHER ONE alone means "snap" (naming a target IS asking to snap), and the whole SET is then shifted rigidly (never additionally scaled or rotated) so the anchor lands on a lattice point. WITHOUT snapTo, that lattice is the nearest line across ALL of the document's ENABLED grids — so the FINEST enabled grid wins, and that grid is usually INVISIBLE (see render_sketch's metadata for every grid's visible/enabled flags and lattice); this stays the default because it's the app's own pen behaviour, but it is easy to land a schematic between the lines a human can see. Use snap_points first to see what's actually near your anchor, then pass snapTo to name the grid (and optionally which of its line families — one family constrains a single direction, e.g. a wire's y-coordinate while its x-coordinate stays put) you actually mean; with no enabled grid (and no snapTo), snapToGrid is a no-op. A snap alone, with no translate/ scale/rotate, is a legal request. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `ids` | array | yes | Composite stroke ids, as returned by list_strokes or draw_strokes. |
| `canvasAnchor` | array | no | [x, y]. Defaults to the centre of the ids' union bounding box. |
| `canvasTranslate` | array | no | [dx, dy] in canvas points. |
| `rotate` | number | no | Degrees about the anchor; positive = clockwise on screen. |
| `scale` | array | no | [sx, sy] about the anchor; non-zero. |
| `snapTo` | object | no | Which grid to snap to — AND, on its own, a request TO snap: snapToGrid need not also be set (passing snapTo without it snaps to this target; it is not ignored). WITHOUT snapTo, snapToGrid takes the nearest line across ALL enabled grids — so the FINEST grid wins, and that grid is usually INVISIBLE, which will pull your drawing between the lines a human sees. Name a grid (ids from render_sketch's metadata, or snap_points' candidate parents), and optionally only some of its families, to snap to what you mean. |
| `snapToGrid` | boolean | no | Land the anchor on the nearest lattice point, shifting the whole set by that one delta. Without snapTo the lattice is ALL of the document's ENABLED grids (the finest, usually invisible, one wins); no enabled grid = no-op. NOT required when you pass snapTo — a snapTo alone already snaps. |

### `restore_stroke_widths`

Takes the SCALE back off the ink of strokes that were scaled, leaving them exactly where they are on the canvas. Scaling a stroke (here or by the user dragging a selection) scales its INK THICKNESS along with its geometry, because the scale lives on the stroke's transform and PencilKit scales stamp size with it — so a shape scaled up by 3 is drawn with lines 3x fatter. This restores the drawn thickness while every point stays put; it is the same operation as the app's "Restore original stroke widths" menu item. Nothing else changes: ids, points, z-order, colour and ink all survive, and the stroke's width-edit history is left alone. AFTERWARDS the strokes' localToCanvasTransform (get_strokes) has changed — its scale is now 1, or it is identity for a stroke that was scaled unevenly — so re-read rather than reusing a cached one; canvasPoints and canvasPathBounds are unaffected. A stroke that carries no scale is LEFT ALONE and counted in the reply, not an error, and when that is true of every id given, NOTHING IS WRITTEN AT ALL (the reply says "no change" and quotes no seq). stampWidth is not touched — to change the drawn thickness itself, use restyle_strokes. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `ids` | array | yes | Composite stroke ids, as returned by list_strokes or draw_strokes. Ids that carry no scale are accepted and reported back as unchanged. |

### `delete_strokes`

Deletes one or more strokes from a document by their composite stroke keys (as returned by list_strokes), authored by a connected InfinitySketch device. REQUIRES a connected device — fails with noDeviceAvailable if none is connected, deviceTimeout if it doesn't respond in time, opInProgress if another stroke operation on this document is already in flight, and deviceFailed: <reason> if a key doesn't match any stroke. The result names the seq the write was assigned. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `ids` | array | yes | The composite stroke ids to delete, as returned by list_strokes. |

---

## Text — reference

### `add_text`

Appends a placed-text entry to a document: a new id, the document's current colour scheme, and an identity transform/opacity. (canvasX, canvasY) is the text box's top-left corner. Give color/fontSize/bold/italic/family to style the WHOLE label, or a `spans` array to style parts of it independently (e.g. a subscript). A whole-field style is the base each span overrides. Styling needs a connected device; plain text does not. Returns the new text's id so you can edit it. Colours: #RRGGBB(AA), light-canonical (see colorAppearance to author for the dark canvas). Font families come from list_fonts — call it before setting a `family`. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `canvasX` | number | yes | Canvas-space x of the text box's top-left corner. |
| `canvasY` | number | yes | Canvas-space y of the text box's top-left corner. |
| `docId` | string | yes | The document id to modify. |
| `text` | string | yes | The text to place. Omit if using `spans`. |
| `bold` | boolean | no |  |
| `color` | string | no | #RRGGBB or #RRGGBBAA. Default: the document's automatic text colour. Light-canonical (the light-appearance value); see colorAppearance. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |
| `family` | string | no | A font family name from list_fonts. An unknown family fails with unknownFont. |
| `fontSize` | number | no | Point size, 1–512. |
| `italic` | boolean | no |  |
| `pinned` | boolean | no | Excludes the text from selection transforms. Defaults to false. |
| `spans` | array | no | Style parts of the text independently instead of a single `text` string. Each span is {text, color?, fontSize?, bold?, italic?, family?}; any whole-field color/fontSize/bold/italic/ family above is the base a span's own value overrides. Supply `text` OR `spans`, not both. Requires a connected device. |
| `tags` | array | no | Durable tags for this text, so find_elements can reach it later. |

Each item of `spans`:

| Field | Type | Required | Description |
|---|---|---|---|
| `text` | string | yes | This span's text. |
| `bold` | boolean | no |  |
| `color` | string | no | #RRGGBB or #RRGGBBAA. Default: the document's automatic text colour. Light-canonical (the light-appearance value); see colorAppearance. |
| `family` | string | no | A font family name from list_fonts. An unknown family fails with unknownFont. |
| `fontSize` | number | no | Point size, 1–512. |
| `italic` | boolean | no |  |

### `edit_text`

Mutates an existing placed text by id: replace its string and/or move it, or restyle it with color/fontSize/bold/italic/family (whole-field) or a `spans` array (parts of it independently — a whole-field style is the base each span overrides). WARNING: replacing the text via PLAIN `text` (no style/spans) resets that entry's rich formatting to plain defaults — the attributed run's bold/italic/font/colour attributes are UIKit-archived data no server-side code can synthesize, so a new plain text run always replaces the old ones wholesale. A STYLED edit (any of color/fontSize/bold/italic/family/spans present) restyles the EXISTING characters (or replaces them with `text`/`spans` if given) and needs a connected device — plain edits do not. Position-only edits (canvasX and/or canvasY with no text/style) do not touch formatting. Colours: #RRGGBB(AA), light-canonical (see colorAppearance to author for the dark canvas). Font families come from list_fonts. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `textId` | string | yes | The id of the text entry to edit. |
| `bold` | boolean | no |  |
| `canvasX` | number | no | New canvas-space x of the text box's top-left corner. |
| `canvasY` | number | no | New canvas-space y of the text box's top-left corner. |
| `color` | string | no | #RRGGBB or #RRGGBBAA. Default: the document's automatic text colour. Light-canonical (the light-appearance value); see colorAppearance. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |
| `family` | string | no | A font family name from list_fonts. An unknown family fails with unknownFont. |
| `fontSize` | number | no | Point size, 1–512. |
| `italic` | boolean | no |  |
| `spans` | array | no | Replace the text with independently-styled parts instead of a single `text` string. Same shape as add_text's `spans`. Requires a connected device. |
| `text` | string | no | Replacement text. Plain (no style/spans), this resets formatting to plain defaults — see the tool description. Styled (with color/fontSize/bold/italic/family/spans), it replaces the characters with the new style instead. |

Each item of `spans`:

| Field | Type | Required | Description |
|---|---|---|---|
| `text` | string | yes | This span's text. |
| `bold` | boolean | no |  |
| `color` | string | no | #RRGGBB or #RRGGBBAA. Default: the document's automatic text colour. Light-canonical (the light-appearance value); see colorAppearance. |
| `family` | string | no | A font family name from list_fonts. An unknown family fails with unknownFont. |
| `fontSize` | number | no | Point size, 1–512. |
| `italic` | boolean | no |  |

### `remove_text`

Removes a placed text entry from a document by id. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `textId` | string | yes | The id of the text entry to remove. |

### `list_texts`

Lists a document's placed texts, one per text, as {id, text, bounds:[x,y,w,h] (canvas space), pinned, opacity} — authored by a connected InfinitySketch device. REQUIRES a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. Returns the device's listing verbatim as text; this call never writes to the document. unknownDoc if the document doesn't exist.

REPLY: an ARRAY of `{id, text, canvasBounds, pinned, opacity, tags}`. The box is `canvasBounds`, NOT `bounds`.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to list placed texts from. |

### `list_fonts`

The font families installed on the connected device, sorted. Call this before setting a `family` on add_text/edit_text — an unknown family is rejected with unknownFont. REQUIRES a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. Read-only: it never writes to the document, so there is no seq assigned and nothing to retry.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to query. |

---

## Images — reference

### `add_image`

Place an image into a document. `path` names an image FILE ON THE MACHINE THIS SERVER RUNS ON — it must be absolute (a leading ~ is expanded), and the server reads it itself, so no image data passes through your context. Write a generated image to a file and pass its path; do not try to inline it. (canvasX, canvasY) is the placement's TOP-LEFT corner. Optional canvasWidth/canvasHeight (canvas points) resize it — OMIT BOTH FOR THE IMAGE'S NATURAL PIXEL SIZE, which for a photo is thousands of points across; give one to preserve aspect ratio, both for exact. Optional `opacity` (0..1, default 1). Requires a connected device (the image is decoded there) — noDeviceAvailable otherwise. The reply names the new image's id, the canvasBounds it actually occupies, and the source's pixel size, so you can size it correctly in one follow-up rather than by rendering and guessing. Errors name the file: imagePathNotAbsolute, imageFileNotFound, imageFileUnreadable, imageFileEmpty, imageTooLarge, imageCorrupt (a truncated or damaged PNG/JPEG/GIF — this is checked because no image DECODER catches it: a truncated PNG decodes to the right size and renders blank). unknownDoc if the document doesn't exist.

| Argument | Type | Required | Description |
|---|---|---|---|
| `canvasX` | number | yes | Canvas-space x of the placement's top-left corner. |
| `canvasY` | number | yes | Canvas-space y of the placement's top-left corner. |
| `docId` | string | yes | The document id to modify. |
| `path` | string | yes | Absolute path to a PNG/JPEG/GIF (or anything else the device can decode) on the server's own filesystem. A leading ~ is expanded; a relative path is refused rather than resolved against a working directory you cannot see. |
| `canvasHeight` | number | no | Canvas-point height. Omit both for the image's natural pixel size; give one to preserve aspect ratio. |
| `canvasWidth` | number | no | Canvas-point width. Omit both for the image's natural pixel size; give one to preserve aspect ratio. |
| `opacity` | number | no | 0..1. Defaults to 1. |
| `tags` | array | no | Durable tags for this image, so find_elements can reach it later. |

### `list_images`

Lists a document's placed images, one per image, as {id, bounds:[x,y,w,h] (canvas space), pinned, opacity} — authored by a connected InfinitySketch device. REQUIRES a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. Returns the device's listing verbatim as text; this call never writes to the document. unknownDoc if the document doesn't exist.

REPLY: an ARRAY of `{id, canvasBounds, pinned, opacity, tags}`. The box is `canvasBounds`, NOT `bounds`. An empty array means the document has no images.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to list placed images from. |

### `remove_image`

Remove a placed image from a document by its id (as returned by add_image or reported by get_selection). unknownDoc if the document doesn't exist; imageNotFound if no placed image has that id. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `imageId` | string | yes | The id of the placed image to remove. |

---

## Grids — reference

### `list_grids`

Lists a document's grids, one per grid, as {id, type, spacing, snap, rotation, offset, pivot, color, thickness, visible, enabled, families} — authored by a connected InfinitySketch device. `type` is one of "grid"/"horizontal"/"vertical"/"isometric"; `color` is "#RRGGBBAA" hex. `visible` (drawn) and `enabled` (snapped-to) are independent — check both. `families` are the derived line families (from GridGeometry), the same vocabulary render_sketch reports, so a grid's id here is what snap_points' gridIds and transform_strokes' snapTo refer to. REQUIRES a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. Returns the device's listing verbatim as text; this call never writes to the document. unknownDoc if the document doesn't exist.

REPLY: an ARRAY of `{id, type, spacing, snap, rotation, offset, color, thickness, visible, enabled, families, tags}` in DRAW order, where each family is `{id, label, normal, lineAngleDeg, phase, drawSpacing, snapSpacing}` and `tags` is the grid's durable tags (empty unless you set them with add_grid/update_grid).

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to list grids from. |

### `add_grid`

Adds a new grid to a document, authored by a connected InfinitySketch device. Every field is optional and defaults to the app's own new-grid defaults (spacing 20, snap 1, type "grid", color a translucent blue, thickness 1, rotation 0, offset [0, 0]) EXCEPT `visible` and `enabled`, which default to true — a grid an agent adds is usable immediately, unlike the app's own hidden-by-default "Add Grid" affordance which the user then configures. `snap` is a MULTIPLIER of `spacing`, not a distance — real snap distance is spacing × snap. Returns the new grid's id. Requires a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. unknownDoc if the document doesn't exist; invalidSpec if `color` isn't valid hex or `type` isn't one of the four recognized strings. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `color` | string | no | "#RRGGBBAA" or "#RRGGBB" hex. Defaults to a translucent blue. Literal: drawn identically in light and dark (grid colours never convert). |
| `enabled` | boolean | no | Whether strokes snap to the grid. Defaults to true. |
| `offset` | array | no | The lattice phase [x, y]. Defaults to [0, 0]. |
| `rotation` | number | no | Rotation in degrees. Defaults to 0. |
| `snap` | number | no | A MULTIPLIER of spacing, not a distance — real snap distance is spacing × snap. Defaults to 1. |
| `spacing` | number | no | Line spacing in canvas points. Defaults to 20. |
| `tags` | array | no | Durable tags for this grid, so you can find it again in a later session — and group it with the strokes you draw against it. REPLACES the grid's tags; [] clears them. Grids do NOT appear in find_elements; read them back from list_grids. list_tags reports how many grids carry each tag. |
| `thickness` | number | no | Line thickness. Defaults to 1. |
| `type` | string — `grid`, `horizontal`, `vertical`, `isometric` | no | The grid's lattice type. Defaults to "grid". |
| `visible` | boolean | no | Whether the grid is drawn. Defaults to true. |

### `update_grid`

Modifies an existing grid's supplied fields only (present-only), authored by a connected InfinitySketch device. Same field vocabulary as add_grid. If the grid has a pivot (set via set_grid_origin or the app's tap-to-pick-origin) and `type`/`spacing`/`rotation` changes, the offset is automatically re-reduced so the lattice keeps passing through that pivot. Requires a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. gridNotFound if no grid has that id; unknownDoc if the document doesn't exist; invalidSpec if `color`/ `type` aren't recognized. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `id` | string | yes | The id of the grid to modify, as returned by add_grid/list_grids. |
| `color` | string | no | "#RRGGBBAA" or "#RRGGBB" hex. Literal: drawn identically in light and dark (grid colours never convert). |
| `enabled` | boolean | no | Whether strokes snap to the grid. |
| `offset` | array | no | The lattice phase [x, y]. |
| `rotation` | number | no | Rotation in degrees. |
| `snap` | number | no | A MULTIPLIER of spacing, not a distance — real snap distance is spacing × snap. |
| `spacing` | number | no | Line spacing in canvas points. |
| `tags` | array | no | Durable tags for this grid, so you can find it again in a later session — and group it with the strokes you draw against it. REPLACES the grid's tags; [] clears them. Grids do NOT appear in find_elements; read them back from list_grids. list_tags reports how many grids carry each tag. |
| `thickness` | number | no | Line thickness. |
| `type` | string — `grid`, `horizontal`, `vertical`, `isometric` | no | The grid's lattice type. |
| `visible` | boolean | no | Whether the grid is drawn. |

### `remove_grid`

Removes a grid from a document by its id, authored by a connected InfinitySketch device. The grid array may legitimately reach zero, as in the app. gridNotFound if no grid has that id; unknownDoc if the document doesn't exist. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `id` | string | yes | The id of the grid to remove, as returned by add_grid/list_grids. |

### `reorder_grids`

Sets the draw order (z-order) of a document's grids, authored by a connected InfinitySketch device. `orderedIds` must be a full permutation of the document's current grid ids (as returned by list_grids) — the grids draw, and list_grids reports them, in this sequence. Requires a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. unknownDoc if the document doesn't exist; gridNotFound/ invalidSpec if orderedIds isn't a valid permutation of the document's grid ids. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `orderedIds` | array | yes | The grid ids (as returned by list_grids/add_grid), in the desired draw order — a full permutation of the document's current grid ids. |

### `set_grid_origin`

Sets a grid's pivot to an EXACT canvas coordinate — the programmatic equivalent of the app's tap-to-pick-origin gesture — so the lattice passes through (canvasX, canvasY): the offset is recomputed so the grid stays anchored there. No snap — use snap_points first if you want a lattice point. Authored by a connected InfinitySketch device. gridNotFound if no grid has that id; unknownDoc if the document doesn't exist. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `canvasX` | number | yes | Canvas-space x the lattice should pass through. |
| `canvasY` | number | yes | Canvas-space y the lattice should pass through. |
| `docId` | string | yes | The document id to modify. |
| `id` | string | yes | The id of the grid to set the origin of, as returned by add_grid/list_grids. |

### `snap_points`

Where could these points snap to? Returns CANDIDATES — it never moves anything, and it never decides for you. Each candidate is either a LINE (one grid family: it constrains ONE direction, so a horizontal wire can snap its y-coordinate and keep its x-coordinate) or an INTERSECTION of two non-parallel families, which MAY come from two DIFFERENT grids — the 20pt grid's vertical crossing the 5pt grid's horizontal is a real point. Every candidate names its parent grid(s): gridId, familyId, label, lineAngleDeg, spacing, snapSpacing, visible, enabled, thickness, color — use gridId/familyId with transform_strokes' snapTo once you've picked one.

THE LIST IS ORDERED BY DISTANCE, AND DISTANCE IS NOT A RECOMMENDATION. Measured on the factory document, for a point near (103, 92) the top THREE candidates are the invisible, DISABLED 1pt grid's — at distance 0.2 ("snap to where you already are") — and the candidate an agent actually wants, the VISIBLE 20×20 intersection at (100, 100), is LAST, at distance 8.43. Grabbing candidates[0] lands a schematic between the lines a human can see — that is exactly what happened to a real agent. For LAYOUT, prefer candidates whose parents are `visible`; the finest enabled grid is usually invisible.

maxCandidates (default 64) is a SAFETY VALVE, not a working parameter: truncation drops the FARTHEST candidates, which are usually the coarse VISIBLE ones you want — lowering it can silently delete the answer you need. REQUIRES a connected device — fails with noDeviceAvailable if none is connected and deviceTimeout if it doesn't respond in time. Read-only: no write, no seq bump.

REPLY: an ARRAY, one entry per point you asked about, each `{canvasPoint, candidates}` where a candidate is `{canvasPosition, distance, kind, parents}` — `kind` is the sort of snap (a grid line, or an intersection of two families) and `parents` names the grid(s) and families it came from.

| Argument | Type | Required | Description |
|---|---|---|---|
| `canvasPoints` | array | yes | Canvas-space [x, y] points to find snap candidates for. |
| `docId` | string | yes | The document id to query. |
| `gridIds` | array | no | Consider only these grids (ids from render_sketch's metadata). Default: all of them, including invisible and disabled ones. |
| `maxCandidates` | integer | no | Per point; default 64. The cap drops the FARTHEST candidates. |

---

## Elements — reference

### `tag_elements`

Give elements durable TAGS, so you can find your own work again later — the strokes that make up a roof, the series of markers on a plot, the text that titles a chart. Tags live in the DOCUMENT, so they outlast this task, this session and this agent, which the ids returned by draw_strokes do not.

THE POINT: with a tag you can update your own work in place (find_elements -> the tools that take ids) instead of deleting and redrawing, which is what destroys the user's own annotations and hand-adjusted spacing.

Many-to-many: an element carries any number of tags and a tag covers any number of elements, so overlapping sets are fine — the strokes of "sky" can also be "background". `mode` is add (default), remove, or replace; `replace` with an empty `tags` clears. Tags are 1-128 characters, at most 32 per element; use whatever reads well ("roof", "fft.axis.h", "Achse H"). Clones inherit their tags, so a duplicated roof tile is still part of the roof. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `ids` | array | yes | Element ids (stroke id, text id or image id). Any number. |
| `mode` | string — `add`, `remove`, `replace` | no | add (default) / remove / replace. replace with an empty tags clears. |
| `tags` | array | no | The tags to add, remove, or replace with. |

### `find_elements`

Resolve TAGS to element ids, so you can act on them with any tool that takes ids. Read-only and cheap: no document payload comes back, just `{tag: [ids]}` for the tags that resolve.

Ids come back in DOCUMENT order — strokes in drawing order, then texts, then images — so a tagged series is returned in a stable, meaningful sequence.

A tag whose elements no longer exist is simply ABSENT from the reply rather than a dangling id, so an empty answer means "those elements are gone", not "the lookup failed". Tags are set with tag_elements, or at creation time by draw_strokes / add_text / add_image / fill_region / draw_dots. Use list_tags to see what a document already has.

REPLY: an OBJECT mapping each tag you asked for to an ARRAY of element ids, e.g. `{"roof": ["id1", "id2"]}`. A tag with no live elements is ABSENT from the object rather than present-and-empty, so check for the key before indexing it.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to query. |
| `tags` | array | yes | The tags to resolve. |

### `list_tags`

Every tag in a document, with how many live things carry it, split by family. Read-only.

This is how you pick up work you did earlier: the ids you were handed are gone, and guessing a tag is indistinguishable from the tag having been deleted. Start here, then find_elements to turn a tag into ids.

READ THE `grids` COUNT. Grids carry tags too, but find_elements returns ELEMENT ids only and never a grid — so a tag with `grids` above zero has a lattice in it that resolving the tag will not hand you. Read it back from list_grids, and change it with update_grid.

REPLY: an OBJECT mapping each tag to `{"elements": N, "grids": M}` — live elements and grids carrying it, e.g. `{"roof": {"elements": 7, "grids": 0}, "elevation": {"elements": 12, "grids": 1}}`. `{}` means nothing is tagged yet.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to query. |

### `transform_elements`

Move, scale or rotate named strokes, texts AND images together — on ANY document, open or not. This is how you reposition a placed image: transform_strokes takes strokes only, and edit_text can move a text but not turn or resize it, so before this an image could be named, pinned, reordered, copied and deleted but never nudged without the document being open and a live selection running.

Ops are named, never a raw matrix, and mean exactly what they mean on transform_strokes: `scale` then `rotate`, both about `anchor`, then `translate`. `anchor` defaults to the centre of the whole set's bounding box across all three kinds. Identity survives — a stroke keeps its id and its width-edit history, texts and images keep theirs; this is a MOVE, not a copy.

ATOMIC: every id must resolve or nothing moves, so a set can never end up sheared half-way. Use transform_strokes when you want grid snapping (`snapToGrid` / `snapTo`), which is stroke-lattice specific and stays there. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `canvasAnchor` | array | no | [x, y]. Defaults to the centre of the whole set's bounding box. |
| `canvasTranslate` | array | no | [dx, dy] in canvas points. |
| `imageIds` | array | no | Placed-image ids, as returned by list_images. |
| `rotate` | number | no | Degrees about the anchor; positive = clockwise on screen. |
| `scale` | array | no | [sx, sy] about the anchor; non-zero. |
| `strokeIds` | array | no | Stroke ids, as returned by list_strokes or draw_strokes. |
| `textIds` | array | no | Placed-text ids, as returned by list_texts. |

### `reorder_elements`

Sets the z-order (draw order) of named strokes/texts/images within ONE document — bring-to-front or send-to-back, authored by a connected InfinitySketch device. At least one of `strokeIds`/`textIds`/`imageIds` is required. `mode` selects the direction: "front" moves the named elements to the top of the draw order, "back" to the bottom — each WITHIN its own element type's stacking, mirroring the app's Bring-to-Front/Send-to-Back tool. The cross-type order is FIXED (images below strokes below texts), so a stroke brought to front is still drawn below every text; use this only to reorder among same-type elements. For images, pinned (background) images always draw behind unpinned ones regardless of this order — change that band with set_pinned. REQUIRES a connected device with the reorderElements capability — fails with noDeviceAvailable if none is connected, deviceTimeout if it doesn't respond in time, unknownDoc if the document doesn't exist, and deviceFailed: <reason> (e.g. elementNotFound) for an unknown id. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `mode` | string — `front`, `back` | yes | "front" moves the named elements to the top of the draw order, "back" to the bottom — within each element type. |
| `imageIds` | array | no | Placed-image ids to reorder, from list_images. |
| `strokeIds` | array | no | Stroke ids to reorder, from list_strokes/get_strokes. |
| `textIds` | array | no | Placed-text ids to reorder, from list_texts. |

### `set_pinned`

Sets the `pinned` (background) flag on the named placed texts and/or images of a document. `ids` may mix text ids and image ids (as returned by list_texts/list_images/add_text/add_image). A pinned element draws beneath unpinned content and is skipped by rect-select. Server-side, no device needed. Atomic: if any id isn't a text or image in the document it fails with elementNotFound and nothing changes. unknownDoc if the document doesn't exist. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to modify. |
| `ids` | array | yes | Ids of the placed texts/images to (un)pin — a non-empty list. |
| `pinned` | boolean | yes | true to pin, false to unpin. |

### `copy_elements`

Copies named strokes/texts/images from document `source` INTO document `target`, as FRESH clones (fresh ids) — unlike merge_docs, elements are never deduped by identity, so copying the same source element twice yields two distinct clones. `source` is left untouched; `target` gains the copies. At least one of `strokeIds`/ `textIds`/`imageIds` is required. REQUIRES a connected device with the copyElements capability — fails with noDeviceAvailable if none is connected, sourceNotFound / targetNotFound if either document is absent, and deviceFailed: elementNotFound if an id isn't found in `source`. Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes.

REPLY: the clones' NEW ids, as `createdStrokeIds`, `createdTextIds` and `createdImageIds` — deliberately not `strokeIds`/`textIds`/`imageIds`, which are this tool's ARGUMENTS and name the elements in the SOURCE.

| Argument | Type | Required | Description |
|---|---|---|---|
| `source` | string | yes | The document to copy FROM (left unchanged). |
| `target` | string | yes | The document to copy INTO (gains the clones). |
| `imageIds` | array | no | Placed-image ids to clone, from list_images. |
| `strokeIds` | array | no | Stroke ids to clone, from list_strokes/get_strokes. |
| `textIds` | array | no | Placed-text ids to clone, from list_texts. |

---

## Selection — reference

### `select_all`

Select every stroke, placed text, and placed image in the document on a connected device's live rect-select, replacing any existing selection — the agent equivalent of the user's Select All. REQUIRES a connected `controlSelection` device.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |

### `select_elements`

Select specific elements by id on a connected device's live rect-select, replacing any existing selection. Pass `strokeIds` (stroke ids, from `list_strokes`/`get_strokes`), `textIds`, and/or `imageIds` (text/image ids, from `get_selection` or the document summary) — at least one id across the three arrays is required (enforced device-side). By default the selection rectangle is resized to hug the chosen elements; pass `keepRect: true` to leave the user's own marquee exactly where they dragged it. REQUIRES a connected `controlSelection` device.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |
| `imageIds` | array | no | Placed-image ids to select. |
| `keepRect` | boolean | no | Keep the existing selection rectangle instead of resizing it to the chosen elements. Defaults to false. |
| `strokeIds` | array | no | Stroke ids to select. |
| `textIds` | array | no | Placed-text ids to select. |

### `clear_selection`

Clear the user's live rect-select selection on a connected device, returning it to idle — the agent equivalent of tapping outside the selection or hitting Escape. REQUIRES a connected `controlSelection` device.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |

### `get_selection`

Read the user's CURRENT live rect-select selection on a connected device. REQUIRES a connected device with the document open.

THE REPLY'S KEYS, because guessing them wastes a round trip and fails SILENTLY (absent JSON keys read as nothing, not as an error):

- `elements` — what is selected. NOT "strokes": each entry is   `{kind: "stroke"|"text"|"image", id, canvasBounds, pinned}`, so one list covers   all three kinds.
- `canvasBounds` — the union of the selected elements. NOT "bounds".
- `canvasRect` — the MARQUEE itself, which is a different thing: it is where the   user dragged, and it can be non-empty while `elements` is empty. NOT "rect".
- `canvasReferencePoint` — the pivot the user placed, absent if they have not.
- `active` — something is selected. `sessionActive` — select mode is ON. These   DIFFER: a user in select mode who has not swiped yet, or whose swipe was   perfectly straight (a zero-height marquee selects nothing), gives   `sessionActive: true` with `active: false`.
- `uncommittedCopy` — a duplicate or paste that will be DELETED if you clear the   selection rather than committing it.
- `signature` — opaque; pass back as transform_selection's `expect`.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |

### `set_reference_point`

Place the reference point the user's live selection pivots/rotates/scales around, at the given CANVAS coordinates — the same point a manual rect-select drag drops. This does NOT snap to the grid; call `snap_points` first and pass one of its candidates if you want a lattice point. REQUIRES a connected `controlSelection` device with an active selection.

| Argument | Type | Required | Description |
|---|---|---|---|
| `canvasX` | number | yes | Canvas-space x. Not snapped. |
| `canvasY` | number | yes | Canvas-space y. Not snapped. |
| `docId` | string | yes | The document id. |

### `transform_selection`

Transform the user's live selection exactly as a manual rect-select transform would (one undoable step). `ops` is a list of 1 to 16 operations, composed left-to-right into one undo step (single fixed reference point): rotate {op:"rotate",degrees} (+ = clockwise, relative), scale {op:"scale",factor} (uniform), translate {op:"translate",dx,dy} (canvas points, no reference point), flipHorizontal / flipVertical. rotate/scale/flip pivot on the reference point the USER placed — if none is set the op fails (noReferencePoint); placing it yourself is not supported yet. Pass `expect` = a prior get_selection's `signature` to be rejected if the user changed the selection since (selectionChanged). REQUIRES a connected device with an active selection.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |
| `ops` | array | yes | 1 to 16 operations, composed left-to-right into one undo step. |
| `expect` | string | no | signature from get_selection. |

Each item of `ops`:

| Field | Type | Required | Description |
|---|---|---|---|
| `op` | string — `rotate`, `scale`, `translate`, `flipHorizontal`, `flipVertical` | yes | Which operation this entry is. |
| `degrees` | number | no | rotate: degrees about the reference point; positive = clockwise. |
| `dx` | number | no | translate: canvas points along x. |
| `dy` | number | no | translate: canvas points along y. |
| `factor` | number | no | scale: uniform factor about the reference point. |

### `preview_selection`

Preview a proposed transform of the user's live selection WITHOUT committing anything — the agent's scratchpad for a selection edit, the same role render_sketch's ephemeral strokes play for stroke authoring: synthesize → render → refine → only then commit via transform_selection. `ops` is 1 to 16 operations, composed left-to-right into one undo step (single fixed reference point), the same shape as transform_selection: rotate {op:"rotate",degrees} (+ = clockwise, relative), scale {op:"scale",factor} (uniform), translate {op:"translate",dx,dy}, flipHorizontal / flipVertical — pivoting on the reference point the USER placed (noReferencePoint if none is set). Returns a PNG plus metadata: canvas-space bounds for each transformed selected element (and, with includePoints, each stroke's transformed points), the overall selection bounds/referencePoint, and — per grid — the same line families render_sketch reports, so you can align the proposed transform before committing it. `include`: "withContext" (default) renders the grid and the rest of the document's content behind the moved selection; "selectionOnly" renders just the transformed selection, transparent background, no grid pixels (grid metadata is still reported). `rect` bounds the render like render_sketch's; omit for auto-fit. Nothing here is ever written to the document or the live selection. REQUIRES a connected `controlSelection` device with an active selection.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |
| `ops` | array | yes | 1 to 16 operations, composed left-to-right into one undo step (single fixed reference point), same shape as transform_selection's ops. |
| `canvasRect` | array | no | [x, y, w, h] in canvas coordinates. Omit for auto-fit. |
| `duplicate` | boolean | no | Preview a stamp: render the originals plus a transformed copy together (requires ops). |
| `include` | string — `withContext`, `selectionOnly` | no | "withContext" (default): the grid plus the rest of the document's content behind the moved selection. "selectionOnly": just the transformed selection, transparent background, no grid pixels (grid metadata is still reported). |
| `includePoints` | boolean | no | Include each transformed stroke's canvas-space points alongside its bounds. Defaults to false. |

### `duplicate_selection`

Duplicate the user's live selection on a connected device. With no `ops`: a provisional copy in place — like the toolbar's duplicate, it commits on a later edit and is deleted on a later deselect. With `ops` (1 to 16, same shape as transform_selection's, composed left-to-right around the single reference point): clone + transform as one "stamp" undo step. Returns the new elements' keys/ids. Pass `expect` = a prior get_selection's `signature` to be rejected if the user changed the selection since (selectionChanged). REQUIRES a connected `controlSelection` device with an active selection.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |
| `expect` | string | no | signature from get_selection. |
| `ops` | array | no | 1 to 16 operations, composed left-to-right into one undo step (single fixed reference point), same shape as transform_selection's ops. Omit for a provisional in-place copy. |

### `draw_selection`

Draw strokes into the user's LIVE rect-select selection AND select them, in one step. `strokes` takes the same shape as draw_strokes. Composing draw_strokes + select_elements does the same thing but leaves a window where the stroke exists unselected; this is atomic. By default the user's selection rectangle is KEPT (you are drawing INTO it) — pass `keepRect: false` to shrink it to the new strokes. Stroke colours are light-canonical, same as draw_strokes — pass colorAppearance: "dark" if you picked them for the dark canvas. Requires an ACTIVE selection: noSelectionActive otherwise, userBusy mid-gesture. REQUIRES a connected `controlSelection` device.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |
| `strokes` | array | yes | Strokes to draw; same item shape as draw_strokes. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |
| `keepRect` | boolean | no | Keep the user's selection rectangle. Defaults to true. |

### `restyle_selection`

Restyle the strokes in the user's LIVE rect-select selection — `color` (#RRGGBB/#RRGGBBAA), `width` (target peak stroke width), and/or `inkType` (pen/pencil/marker/monoline). At least one is required; an omitted field is left alone. Unlike restyle_strokes (which edits document bytes and cannot refresh the canvas while a selection is open) this drives the app's own reink path, so the change appears immediately and lands as one undo step. `color` is light-canonical — pass colorAppearance: "dark" if you picked it for the dark canvas. noSelectionActive if nothing is selected; userBusy mid-gesture. REQUIRES a connected `controlSelection` device.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |
| `color` | string | no | #RRGGBB or #RRGGBBAA. Light-canonical (the light-appearance value); see colorAppearance. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |
| `inkType` | string — `pen`, `pencil`, `marker`, `monoline`, `fountainPen`, `watercolor`, `crayon` | no | pen, pencil, marker, or monoline. |
| `stampWidth` | number | no | Target peak STAMP width — the stroke's own ink size. |

### `delete_selection`

Delete everything in the user's LIVE rect-select selection, exactly as the toolbar's Delete does — one undo step, canvas refreshed immediately. noSelectionActive if nothing is selected; userBusy mid-gesture. REQUIRES a connected `controlSelection` device.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id. |

---

## Reading the canvas — reference

### `render_sketch`

Renders a region of a document, specific strokes, and/or ephemeral candidate strokes that are not written to the document — use it to preview a stroke before committing it with draw_strokes, optionally composited over the document's real content to judge fit and alignment. Authored by a connected InfinitySketch device. Pass `appearance: "light"|"dark"` to render as though the device were showing that appearance, regardless of what it is actually showing — the default is the document's own (the last opener's device); two connected devices can be viewing in different modes, so render both to check your work in each. Returns a PNG plus metadata: the covered rect, the scale actually used, the appearance actually rendered, the canvas contentSize, and — per grid — its id, thickness, and each drawn/snap line family's id, lineAngleDeg and label. These grid and family ids are what snap_points' gridIds and transform_strokes' snapTo refer to. Ephemeral `strokes`' `color` hexes are light-canonical like everywhere else on this surface — pass colorAppearance: "dark" if you picked them for the dark canvas. READ lineAngleDeg for a family's line direction, never infer it from `normal` — normal is PERPENDICULAR to the lines it describes ([1, 0] means VERTICAL lines, not horizontal). Only visible grids appear in the rendered image, but visible and enabled are independent — a grid can be snapped to without being drawable, or drawn without being snapped to; both flags are reported for every grid, so check `enabled` for whether a grid you can't see is still pulling strokes onto it. To ZOOM IN, shrink the rect: the scale rises to fill the pixel budget, up to 16x. (A 60x50pt rect comes back 960x800, not 120x100.) The scale actually used is always reported in the metadata. An empty document (nothing to auto-fit, no explicit rect) now renders at the document's saved viewport instead of failing — only an explicit include: "none" with no ephemeral strokes still fails with deviceFailed: emptyRender (there is deliberately nothing to show). REQUIRES a connected device — fails with noDeviceAvailable if none is connected, deviceTimeout if it doesn't respond in time, and deviceFailed: <reason> for a bad spec (e.g. an unknown strokeKey). Read-only: it never writes to the document, so there is no seq assigned and nothing to retry.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | The document id to render. |
| `appearance` | string — `light`, `dark` | no | Which appearance to render. Default: the document's own (the last opener's device). Two connected devices can be viewing in different modes — render both to check your work in each. |
| `axes` | boolean | no | Overlay light tick marks and coordinate labels along the edges. Defaults to false (a render meant for visual judgement stays clean). |
| `background` | string — `transparent`, `paper`, `paper+grid` | no | "transparent", "paper" (the document's background colour for the current appearance), or "paper+grid" (default — the grid is what agents align to). |
| `canvasRect` | array | no | [x, y, w, h] in canvas coordinates. Omit for auto-fit: the tight bounding box of everything rendered, expanded by padding. |
| `colorAppearance` | string — `light`, `dark` | no | The appearance this call's colour hexes were authored in. Default "light" — the canonical space every colour on this surface speaks. Pass "dark" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form. |
| `include` | string — `document`, `strokes`, `none` | no | What document content to render, alongside any ephemeral strokes below. "document" (default): every stroke, placed image, and placed text. "strokes": only the strokes named by strokeIds — no images or texts. "none": nothing from the document. |
| `maxPixels` | number | no | Pixel budget. Defaults to 1000000, hard ceiling 4000000. An over-large request is downscaled, not rejected, and the metadata reports the scale actually used. |
| `padding` | number | no | Auto-fit margin in canvas points. Defaults to 10% of the fitted box's larger side, minimum 20. |
| `scale` | number | no | Pixels per canvas point, at most 16. THIS is the knob for how big the image comes back — and the image is returned to you inline, so its size is a cost you pay on every call. Omit it and the renderer picks a scale that fits `maxPixels`. |
| `strokeIds` | array | no | With include: "strokes", the stroke ids (as returned by list_strokes) to show. |
| `strokes` | array | no | EPHEMERAL candidate strokes to render — the exact stroke shape draw_strokes takes. Synthesized through the same code a commit would use, so the preview has the same geometry and style draw_strokes would commit, but nothing here is ever written to the document. |

Each item of `strokes`:

| Field | Type | Required | Description |
|---|---|---|---|
| `canvasPoints` | array | yes | The stroke's polyline; at least 2 points. Each point is either an [x, y] pair or a rich point object. |
| `color` | string | no | Stroke colour as #RRGGBB or #RRGGBBAA hex. OMIT IT to inherit the colour of the tool the user currently has selected in the picker (see get_tool); falls back to a paper-contrasting default when no inking tool is selected. Light-canonical (the light-appearance value); see colorAppearance. |
| `inkType` | string — `pen`, `pencil`, `marker`, `monoline`, `fountainPen`, `watercolor`, `crayon` | no | The ink to draw with. OMIT IT to inherit the ink the user currently has selected (see get_tool); pen when no inking tool is selected. THEY DIFFER IN CHARACTER, not only in name, and you cannot see that from a listing: `pen` is opaque and even — reach for it for solid fills, flat colour, and anything you layer; `marker` is wide and TRANSLUCENT, so colours build where strokes overlap and whatever is underneath shows through (painting a solid area in marker leaves the paper visible between passes); `pencil` is textured and goes finest, with a minimum width of 1.2 against 2.5 for the others; `fountainPen`, `watercolor` and `crayon` are expressive — try them and look. Below an ink's minimum a stroke is effectively INVISIBLE, so widths under it are raised and the reply says so. `monoline` is accepted and READS BACK AS `pen`. Nothing went wrong: PencilKit records it as pen when the document is saved, and the two are pixel-identical for strokes you author — monoline means "hold the width constant whatever the pressure", which yours already do. |
| `smooth` | boolean | no | How to read `points`. DEFAULT false: they are a POLYLINE — straight segments, sharp corners, which is almost certainly what you mean. Set true to have them treated as spline knots and smoothly interpolated (useful for a curve given as a few sparse points) — PKStrokePath splines THROUGH its control points, so a sparse polyline misread as knots renders as a rounded teardrop, not the shape you asked for. Note reshape_strokes defaults the OTHER way. A polyline too corner-dense to fit the 4000-point canonical budget fails loudly — send fewer points, or split the shape into several strokes. smooth: true is NOT the escape from that: it skips the budget (the verbatim path has no point cap of its own, only the message-size limit) precisely BECAUSE it does no corner work at all, so every sharp corner then comes out rounded. |
| `stampWidth` | number | no | Peak STAMP width — the stroke's own ink size, which a transform does NOT scale (canvasInkBounds shows its true on-screen extent). OMIT IT to inherit the width of the tool the user currently has selected (see get_tool). |

### `get_tool`

Report the tool picker's CURRENT tool on the connected device — `isInkingTool`, and when true `inkType`, `toolWidth`, `stampWidth` and `color` (#RRGGBBAA). READ THIS BEFORE DRAWING and pass the values explicitly to draw_strokes / draw_selection / render_sketch, so strokes you author match the pen the user is holding unless they asked for something else. The values are never applied implicitly: you hold them, so a preview and its commit are the same numbers even if the user switches tools in between. `isInkingTool` is false for the eraser, lasso, or Bring to Front — nothing sensible to inherit, so use your own values. `color` is reported LIGHT-CANONICAL, whatever appearance the device is currently showing — copy it into draw_strokes/restyle_strokes verbatim, no colorAppearance needed.

TWO WIDTHS, and they are DIFFERENT NUMBERS. `stampWidth` is what the pen actually lays down — the same quantity list_strokes / get_strokes report and draw_* / restyle_* accept, under the SAME NAME, so copying it straight across is correct by construction. `toolWidth` is the picker DIAL, a third quantity, reported because it is the unit stroke anchors record; do NOT pass it to draw_*. They coincide only for marker: monoline lays down `dial + 2`, and pen and pencil follow a non-linear curve, so a dial of 2 on monoline draws a 4. Omitting stampWidth entirely inherits it for you. Needs no selection. REQUIRES a connected `controlSelection` device.

| Argument | Type | Required | Description |
|---|---|---|---|
| `docId` | string | yes | Any open document id on the device. |

