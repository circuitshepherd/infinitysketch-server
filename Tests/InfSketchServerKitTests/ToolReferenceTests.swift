import Foundation
import Testing
@testable import InfSketchServerKit
import MCP

/// `docs/mcp-tools.md` is GENERATED from `MCPAdapter.toolDefinitions`, and these tests are the
/// generator.
///
/// The gap this closes: a human asking "what can this server do" had two options, both bad —
/// read a 6000-line Swift file, or stand up an MCP client and call `tools/list`. The README
/// pointed at `infsketch://guide`, which is deliberately short and agent-facing, and
/// `docs/protocol.md` gave the MCP surface six lines.
///
/// A hand-written tools table was rejected for the obvious reason: 54 tools maintained by hand
/// drift within a week, and a reference that disagrees with the schema is worse than none —
/// `ToolDescriptionVocabularyTests` exists because exactly that happened to six tool
/// DESCRIPTIONS after the coordinate-space rename. Generating from `toolDefinitions` means the
/// page cannot describe a tool the server does not serve, and `additionalProperties: false`
/// makes the schema the whole argument contract, so there is nothing left for prose to get wrong.
///
/// Runs on every platform: it reads `toolDefinitions` directly rather than through a client, so
/// like `ToolDescriptionVocabularyTests` it survives where `MCPAdapterTests` is compiled out
/// (`MCP_SSE_CLIENT`). That is what makes `swift test` — and therefore `scripts/linux-build` and
/// GitLab CI — the drift gate, with no new script to wire in.
///
///     INFSKETCH_REGENERATE_DOCS=1 swift test --filter ToolReferenceTests
enum ToolReference {

    // MARK: - Grouping

    /// Section order, and the tools in each section.
    ///
    /// Hand-curated because `Tool` carries no category and the alternatives are worse: alphabetical
    /// puts `set_paper` between `select_elements` and `set_grid_origin`, and grouping by name
    /// prefix splits `draw_strokes`, `get_strokes` and `list_strokes` across three sections.
    ///
    /// `everyToolBelongsToExactlyOneGroup` is what makes hand-curation safe — a tool added and not
    /// listed here fails the suite rather than vanishing from the reference.
    struct Group {
        let title: String
        let blurb: String
        let tools: [String]
    }

    static let groups: [Group] = [
        Group(title: "Documents",
              blurb: "A `docId` is a filename stem. Writes are compare-and-swap guarded by bytes; "
                   + "a stale write is rejected with `docChangedDuringOp` rather than clobbering.",
              tools: ["list_docs", "list_open_docs", "create_doc", "fetch_doc", "replace_doc",
                      "delete_doc", "merge_docs", "set_paper", "undo_last_edit"]),
        Group(title: "Strokes",
              blurb: "Geometry is canvas space in both directions. `stampWidth` is a stroke's own "
                   + "ink size, which a transform does not scale — see `canvasInkBounds` for the "
                   + "true on-screen extent.",
              tools: ["draw_strokes", "draw_dots", "fill_region", "list_strokes", "get_strokes",
                      "reshape_strokes", "restyle_strokes", "transform_strokes",
                      "restore_stroke_widths", "delete_strokes"]),
        Group(title: "Text",
              blurb: "Plain text is written server-side; styled text and every listing need a "
                   + "connected device, because a laid-out size is UIKit-only.",
              tools: ["add_text", "edit_text", "remove_text", "list_texts", "list_fonts"]),
        Group(title: "Images",
              blurb: "`add_image` takes a path on the machine the server runs on. There is no "
                   + "base64 argument — transcribing one by hand is what corrupted the image that "
                   + "removed it.",
              tools: ["add_image", "list_images", "remove_image"]),
        Group(title: "Grids",
              blurb: "`visible` (drawn) and `enabled` (snapped-to) are independent. `snap` is a "
                   + "MULTIPLIER of `spacing`, not a distance.",
              tools: ["list_grids", "add_grid", "update_grid", "remove_grid", "reorder_grids",
                      "set_grid_origin", "snap_points"]),
        Group(title: "Elements",
              blurb: "Strokes, texts and images addressed by id, whatever their kind. Resolve a "
                   + "tag to ids with `find_elements`, then act with the id-taking tools.",
              tools: ["tag_elements", "find_elements", "list_tags", "transform_elements",
                      "reorder_elements", "set_pinned", "copy_elements"]),
        Group(title: "Selection",
              blurb: "These act on the LIVE rect-select session on a connected device, not on "
                   + "document bytes, and land as one undo step each.",
              tools: ["select_all", "select_elements", "clear_selection", "get_selection",
                      "set_reference_point", "transform_selection", "preview_selection",
                      "duplicate_selection", "draw_selection", "restyle_selection",
                      "delete_selection"]),
        Group(title: "Reading the canvas",
              blurb: "Read-only. `render_sketch` also renders ephemeral candidate strokes that are "
                   + "never written anywhere — synthesize, render, refine, then commit.",
              tools: ["render_sketch", "get_tool"]),
    ]

    // MARK: - Emitting

    struct Argument: Equatable {
        let name: String
        let type: String
        let required: Bool
        let description: String
    }

    /// A property's declared type, with enum cases inline where the schema names them.
    static func typeLabel(for schema: Value) -> String {
        guard case .object(let fields) = schema else { return "—" }
        let base: String
        if case .string(let t)? = fields["type"] { base = t } else { base = "—" }
        guard case .array(let cases)? = fields["enum"] else { return base }
        let names = cases.compactMap(\.stringValue).map { "`\($0)`" }
        return names.isEmpty ? base : "\(base) — \(names.joined(separator: ", "))"
    }

    /// The properties of one object schema, required first then optional, alphabetically within
    /// each — `properties` is a dictionary, so SOME total order has to be imposed or the page
    /// churns between runs.
    static func arguments(fromSchema schema: Value) -> [Argument] {
        guard case .object(let fields) = schema,
              case .object(let properties)? = fields["properties"] else { return [] }
        var required: Set<String> = []
        if case .array(let names)? = fields["required"] {
            required = Set(names.compactMap(\.stringValue))
        }
        return properties.keys.sorted()
            .map { name -> Argument in
                var text = ""
                if case .object(let p) = properties[name]!,
                   case .string(let d)? = p["description"] { text = d }
                return Argument(name: name, type: typeLabel(for: properties[name]!),
                                required: required.contains(name), description: text)
            }
            .sorted { ($0.required ? 0 : 1, $0.name) < ($1.required ? 0 : 1, $1.name) }
    }

    static func arguments(of tool: Tool) -> [Argument] { arguments(fromSchema: tool.inputSchema) }

    /// The per-item fields of an array argument, one level deep — empty for anything else.
    ///
    /// These are decoded on the DEVICE rather than by a server handler, which is why
    /// `scripts/audit-tool-arguments` deliberately ignores them. A human reference cannot: the
    /// first generated page rendered `draw_dots.dots` as "array — The dots to draw" and put
    /// `canvasX`/`canvasY`/`diameter`/`color`/`inkType` NOWHERE, so a reader had everything except
    /// how to build the call. It is not a corner: the payload of `draw_strokes`, `add_text` and
    /// `render_sketch` lives in an item schema too — `theToolsWithItemSchemasRenderTheirFields`
    /// pins the exact set. One level covers all of them, and going deeper would start duplicating
    /// prose the parent description already carries.
    static func itemFields(of schema: Value) -> [Argument] {
        guard case .object(let fields) = schema,
              case .string("array")? = fields["type"],
              let items = fields["items"] else { return [] }
        return arguments(fromSchema: items)
    }

    /// Collapse a description onto one line and neutralise the table delimiter.
    ///
    /// Both halves are load-bearing: a raw newline ENDS a Markdown table, and a `|` inside a cell
    /// opens a phantom column — either one silently mangles the rest of the table rather than
    /// failing.
    static func cell(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    static func section(for tool: Tool) -> String {
        var out = "### `\(tool.name)`\n\n"
        out += (tool.description ?? "_No description._") + "\n"
        let args = arguments(of: tool)
        guard !args.isEmpty else { return out + "\nTakes no arguments.\n" }
        out += "\n| Argument | Type | Required | Description |\n|---|---|---|---|\n"
        for a in args {
            out += "| `\(a.name)` | \(cell(a.type)) | \(a.required ? "yes" : "no") "
                 + "| \(cell(a.description)) |\n"
        }
        guard case .object(let schema) = tool.inputSchema,
              case .object(let properties)? = schema["properties"] else { return out }
        for a in args {
            let nested = itemFields(of: properties[a.name] ?? .null)
            guard !nested.isEmpty else { continue }
            out += "\nEach item of `\(a.name)`:\n\n"
                 + "| Field | Type | Required | Description |\n|---|---|---|---|\n"
            for f in nested {
                out += "| `\(f.name)` | \(cell(f.type)) | \(f.required ? "yes" : "no") "
                     + "| \(cell(f.description)) |\n"
            }
        }
        return out
    }

    /// The whole page. Pure: takes the tools, returns the bytes, touches nothing.
    static func markdown(tools: [Tool], groups: [Group]) -> String {
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        var out = """
            # InfinitySketch MCP tools

            \(tools.count) tools, served over streamable HTTP at `/mcp`.

            <!-- Generated from MCPAdapter.toolDefinitions. Do not edit by hand: run
                 INFSKETCH_REGENERATE_DOCS=1 swift test --filter ToolReferenceTests -->

            Every tool declares `additionalProperties: false`, so an argument a tool does not list
            below is rejected by name rather than ignored. Reads work with no device connected;
            authoring strokes, styling text and rendering need at least one device, because only
            PencilKit can produce or rasterize stroke data.

            Read [`infsketch://guide`](../Sources/InfSketchServerKit/MCP/AgentGuide.swift) first —
            it carries the rules that span tools. This page is the per-tool detail.


            """
        for group in groups {
            out += "## \(group.title)\n\n\(group.blurb)\n\n| Tool | Summary |\n|---|---|\n"
            for name in group.tools {
                let text = byName[name]?.description.map(summary) ?? ""
                out += "| [`\(name)`](#\(name)) | \(cell(text)) |\n"
            }
            out += "\n"
        }
        out += "\n"
        for group in groups {
            out += "---\n\n## \(group.title) — reference\n\n"
            for name in group.tools {
                guard let tool = byName[name] else { continue }
                out += section(for: tool) + "\n"
            }
        }
        return out
    }

    /// The summary-table cell: first sentence, capped.
    ///
    /// The cap is not cosmetic. `transform_selection` and `preview_selection` pack the whole `ops`
    /// grammar into their opening sentence, which came out around 600 characters — one row taller
    /// than the rest of the table put together, in the one column whose entire job is skimming.
    /// The full text is directly below in the tool's own section, so nothing is lost by cutting.
    static func summary(_ text: String) -> String {
        let sentence = firstSentence(text)
        guard sentence.count > 180 else { return sentence }
        let head = sentence.prefix(180)
        let cut = head.lastIndex(of: " ").map { head[head.startIndex..<$0] } ?? head
        return cut + "…"
    }

    /// First sentence. Abbreviations in these descriptions are the reason this looks for ". " and
    /// a following capital rather than splitting on every period.
    static func firstSentence(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = ""
        let chars = Array(flat)
        var i = 0
        while i < chars.count {
            out.append(chars[i])
            if chars[i] == ".", i + 2 < chars.count, chars[i + 1] == " ",
               chars[i + 2].isUppercase { return out }
            i += 1
        }
        return out
    }

    // MARK: - Where the page lives

    static var pageURL: URL {
        URL(fileURLWithPath: #filePath)          // …/server/Tests/InfSketchServerKitTests/<this>
            .deletingLastPathComponent()          // …/server/Tests/InfSketchServerKitTests
            .deletingLastPathComponent()          // …/server/Tests
            .deletingLastPathComponent()          // …/server
            .appendingPathComponent("docs/mcp-tools.md")
    }
}

struct ToolReferenceTests {

    // MARK: - The emitter, pinned against fixtures

    /// Formatting is verified here, against three hand-built tools, rather than by eyeballing the
    /// 60 KB page: a diff of the real page tells you THAT something changed, never whether the
    /// change was right.
    @Test func theEmitterRendersAToolSection() throws {
        let tool = Tool(
            name: "paint_fence",
            description: "Paint a fence. Slats are painted left to right.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                    "colour": .object(["type": "string",
                                       "enum": .array(["red", "white"].map(Value.string)),
                                       "description": "Paint colour."]),
                    "slats": .object(["type": "integer",
                                      "description": "How many slats.\nDefaults to all of them."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ]))

        let out = ToolReference.section(for: MCPAdapter.strict(tool))

        #expect(out.contains("### `paint_fence`"))
        #expect(out.contains("Paint a fence. Slats are painted left to right."))
        // Required first, then optional alphabetically — colour before slats.
        let rows = out.split(separator: "\n").filter { $0.hasPrefix("| `") }
        #expect(rows.count == 3)
        #expect(rows[0].hasPrefix("| `docId` | string | yes |"))
        #expect(rows[1].hasPrefix("| `colour` | string — `red`, `white` | no |"))
        #expect(rows[2].hasPrefix("| `slats` | integer | no |"))
        // The embedded newline must not have ended the table.
        #expect(rows[2].contains("How many slats. Defaults to all of them."))
    }

    @Test func aToolWithNoArgumentsSaysSo() throws {
        let tool = Tool(name: "list_everything", description: "List it all.",
                        inputSchema: .object(["type": "object", "properties": .object([:])]))
        #expect(ToolReference.section(for: tool).contains("Takes no arguments."))
    }

    /// A `|` in a description opens a phantom column and silently shifts every cell after it.
    @Test func aPipeInADescriptionIsEscaped() throws {
        let tool = Tool(
            name: "pipe_tool", description: "d",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "mode": .object(["type": "string", "description": "One of a|b|c."]),
                ]),
            ]))
        #expect(ToolReference.section(for: tool).contains(#"One of a\|b\|c."#))
    }

    /// An array argument's per-item fields get their own table. Without this the reference lists
    /// the argument and not one thing you need to put in it.
    @Test func anArrayArgumentRendersItsItemFields() throws {
        let tool = Tool(
            name: "plant_trees", description: "d",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "trees": .object([
                        "type": "array",
                        "description": "The trees to plant.",
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "species": .object(["type": "string", "description": "Which."]),
                                "canvasX": .object(["type": "number", "description": "Where."]),
                            ]),
                            "required": .array(["canvasX"].map(Value.string)),
                        ]),
                    ]),
                ]),
                "required": .array(["trees"].map(Value.string)),
            ]))

        let out = ToolReference.section(for: tool)
        #expect(out.contains("Each item of `trees`:"))
        let rows = out.split(separator: "\n").filter { $0.hasPrefix("| `") }
        #expect(rows.count == 3)                                   // trees, then its two fields
        #expect(rows[1].hasPrefix("| `canvasX` | number | yes |")) // required item field first
        #expect(rows[2].hasPrefix("| `species` | string | no |"))
    }

    /// A plain array of strings has no item table to render.
    @Test func anArrayOfScalarsRendersNoItemTable() throws {
        let tool = Tool(
            name: "tag_it", description: "d",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "ids": .object(["type": "array", "description": "Element ids.",
                                    "items": .object(["type": "string"])]),
                ]),
            ]))
        #expect(!ToolReference.section(for: tool).contains("Each item of"))
    }

    /// The tools whose call shape lives in an item schema, pinned as an exact SET.
    ///
    /// Pinned rather than merely counted because the failure is silent in both directions: drop
    /// the nesting support and the page still generates, still looks complete, and omits every
    /// field these tools actually take; add an item schema to a new tool and it would go
    /// unrendered with nothing to notice. Modeled on
    /// `everyColourTakingToolAdvertisesColorAppearance`.
    @Test func theToolsWithItemSchemasRenderTheirFields() throws {
        let expected: Set<String> = ["draw_strokes", "draw_dots", "reshape_strokes", "add_text",
                                     "edit_text", "transform_selection", "render_sketch"]
        let rendering = Set(MCPAdapter.toolDefinitions
            .filter { ToolReference.section(for: $0).contains("Each item of") }
            .map(\.name))
        #expect(rendering == expected)

        // A spot check that the fields themselves arrive, not just the heading.
        for (name, field) in ["draw_dots": "canvasX", "add_text": "text",
                              "transform_selection": "op"] {
            let tool = try #require(MCPAdapter.toolDefinitions.first { $0.name == name })
            #expect(ToolReference.section(for: tool).contains("| `\(field)` |"),
                    "\(name) omits the `\(field)` item field")
        }
    }

    @Test func theSummaryTableTakesTheFirstSentence() throws {
        #expect(ToolReference.firstSentence("Do a thing. Then another thing.") == "Do a thing.")
        // Not fooled by an abbreviation mid-sentence.
        #expect(ToolReference.firstSentence("Renders at 2.5 pt. Next.") == "Renders at 2.5 pt.")
    }

    /// A summary cell has to stay skimmable even when the tool's opening sentence does not.
    @Test func anOverlongSummaryIsCutOnAWordBoundary() throws {
        let long = String(repeating: "alpha beta ", count: 60) + "end."
        let out = ToolReference.summary(long)
        #expect(out.count <= 181)
        #expect(out.hasSuffix("…"))
        #expect(!out.contains("alph…"))            // cut between words, not inside one
        #expect(ToolReference.summary("Short enough.") == "Short enough.")
    }

    /// No summary cell may run long enough to break the table's job.
    @Test func noSummaryCellIsOverlong() throws {
        for tool in MCPAdapter.toolDefinitions {
            let cell = ToolReference.summary(tool.description ?? "")
            #expect(cell.count <= 181, "\(tool.name): summary is \(cell.count) chars")
        }
    }

    // MARK: - The gates

    /// A tool added and not grouped would silently vanish from the reference — the page would
    /// still generate, still look complete, and omit it.
    @Test func everyToolBelongsToExactlyOneGroup() throws {
        let grouped = ToolReference.groups.flatMap(\.tools)
        let served = Set(MCPAdapter.toolDefinitions.map(\.name))

        let duplicated = Dictionary(grouping: grouped, by: { $0 }).filter { $0.value.count > 1 }
        #expect(duplicated.isEmpty, "listed in more than one group: \(duplicated.keys.sorted())")

        let ungrouped = served.subtracting(grouped).sorted()
        #expect(ungrouped.isEmpty,
                "served but in no group — add them to ToolReference.groups: \(ungrouped)")

        let phantom = Set(grouped).subtracting(served).sorted()
        #expect(phantom.isEmpty, "grouped but not served — stale entries: \(phantom)")
    }

    /// The drift gate. Set `INFSKETCH_REGENERATE_DOCS=1` to rewrite the page instead of asserting.
    @Test func theCheckedInReferenceMatchesTheToolDefinitions() throws {
        let expected = ToolReference.markdown(tools: MCPAdapter.toolDefinitions,
                                              groups: ToolReference.groups)
        let url = ToolReference.pageURL

        if ProcessInfo.processInfo.environment["INFSKETCH_REGENERATE_DOCS"] != nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try expected.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        // Compare CONTENT, not line-ending convention. The page is generated with LF, but git's
        // `core.autocrlf=true` -- the default on Windows, and what GitHub's `windows-latest`
        // runners carry -- checks it out with CRLF, so a byte comparison reports EVERY tool as
        // drifted while nothing has changed. Measured on Windows 2026-08-16: 54 of 54 "stale",
        // which is the signature of this and not of real drift (genuine drift names a few tools).
        // It is a release blocker rather than a nuisance: `swift test` is a hard gate in
        // `windows.yml`, so the build job fails, the package job never runs, and no Windows
        // download is ever produced -- on a platform whose whole reason for CI is that download.
        let actual = (try? String(contentsOf: url, encoding: .utf8))
            .map { $0.replacingOccurrences(of: "\r\n", with: "\n") }
        guard let actual else {
            Issue.record("""
                \(url.lastPathComponent) is missing.
                Run: INFSKETCH_REGENERATE_DOCS=1 swift test --filter ToolReferenceTests
                """)
            return
        }
        guard actual != expected else { return }

        // Name what changed. A 60 KB diff answers "is it stale"; it does not answer "which tool".
        let stale = MCPAdapter.toolDefinitions
            .filter { !actual.contains(ToolReference.section(for: $0)) }
            .map(\.name)
            .sorted()
        let which = stale.isEmpty
            ? "no tool section differs, so the change is in the header or a group table"
            : "\(stale.count) tool(s) differ: \(stale.joined(separator: ", "))"
        Issue.record("""
            docs/mcp-tools.md is stale — \(which).
            Run: INFSKETCH_REGENERATE_DOCS=1 swift test --filter ToolReferenceTests
            """)
    }
}
