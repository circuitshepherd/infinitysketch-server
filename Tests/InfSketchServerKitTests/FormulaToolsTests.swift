import Foundation
import Testing
@testable import InfSketchServerKit
import MCP

/// Formula objects (format 7) on the agent surface: `add_formula` / `edit_formula` /
/// `list_formulas` go to a device that says `formulas`; `remove_formula` and `set_pinned` edit a
/// closed document's JSON on the server; and every tool that can hand a device a formula's id
/// joins `formulas` onto its capability, so an older app is never asked about one.
///
/// This first suite needs no MCP client, so it runs on Linux too (`scripts/linux-build`); the
/// suite below it drives the tools through a real client and a fake device, which needs the SDK's
/// SSE client transport (Apple platforms only, `MCP_SSE_CLIENT`).
@Suite struct FormulaDocJSONTests {
    static let text = "AAAAAAAA-0000-0000-0000-000000000001"
    static let arrow = "DDDDDDDD-0000-0000-0000-000000000001"
    static let formula = "EEEEEEEE-0000-0000-0000-000000000001"
    static let image = "BBBBBBBB-0000-0000-0000-000000000001"

    /// A format-7 document: a text, a formula, an arrow and an image in one object list, plus a
    /// key this server knows nothing about and a stored thumbnail.
    static let document: Data = Data(#"""
    {
      "aaa001_thumbnailData": "c3RhbGU=",
      "formatVersion": 7,
      "darkColorScheme": false,
      "someFutureKey": {"kept": true},
      "placedObjects": [
        {"kind": "text", "layer": "front", "id": "AAAAAAAA-0000-0000-0000-000000000001",
         "text": ["Label", {}], "rect": [[10, 20], [1, 1]],
         "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0},
         "opacity": 1, "pinned": false, "wordWrapEnabled": false, "colorSchemeIsDark": false},
        {"kind": "formula", "id": "EEEEEEEE-0000-0000-0000-000000000001",
         "latex": "x^2", "origin": [40, 50], "fontSize": 30},
        {"kind": "arrow", "layer": "front", "id": "DDDDDDDD-0000-0000-0000-000000000001", "pinned": false,
         "nodes": [{"x": 0, "y": 0}, {"x": 50, "y": 0}]},
        {"kind": "image", "layer": "back", "id": "BBBBBBBB-0000-0000-0000-000000000001",
         "pastedImageDataId": "CCCCCCCC-0000-0000-0000-000000000001", "rect": [[0, 0], [10, 10]],
         "transform": {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0}, "opacity": 1, "pinned": false}
      ],
      "pastedImagesData": [{"id": "CCCCCCCC-0000-0000-0000-000000000001", "data": "", "thumbnailData": ""}]
    }
    """#.utf8)

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    static func objects(_ data: Data) throws -> [[String: Any]] {
        try #require(try object(data)["placedObjects"] as? [[String: Any]])
    }

    /// The server-side removal: the formula leaves its slot, every other object keeps its own,
    /// an unknown key stays, and the stored preview goes (the server cannot render the new bytes).
    @Test func removeFormulaWorksOnAClosedDocument() throws {
        let out = try DocJSON.removeFormula(from: Self.document, formulaId: Self.formula)
        #expect(try Self.objects(out).map { $0["id"] as? String } == [Self.text, Self.arrow, Self.image])
        let doc = try Self.object(out)
        #expect((doc["someFutureKey"] as? [String: Any])?["kept"] as? Bool == true)
        #expect(doc["aaa001_thumbnailData"] == nil, "a stale preview is worse than none")
        #expect((doc["formatVersion"] as? NSNumber)?.intValue == 7)
        #expect(doc["placedFormulasData"] == nil, "a formula lives only in the object list")
    }

    @Test func removeFormulaOfAnUnknownIdFails() throws {
        #expect(throws: DocJSON.DocJSONError.formulaNotFound) {
            _ = try DocJSON.removeFormula(from: Self.document, formulaId: "FFFFFFFF-0000-0000-0000-000000000009")
        }
        // An arrow's id is not a formula's.
        #expect(throws: DocJSON.DocJSONError.formulaNotFound) {
            _ = try DocJSON.removeFormula(from: Self.document, formulaId: Self.arrow)
        }
        // A document from before the object list has no formulas at all.
        let legacy = Data(#"{"formatVersion": 4, "placedTextsData": [], "placedImagesData": []}"#.utf8)
        #expect(throws: DocJSON.DocJSONError.formulaNotFound) {
            _ = try DocJSON.removeFormula(from: legacy, formulaId: Self.formula)
        }
        // A newer document is refused, as by every edit.
        let newer = Data(String(decoding: Self.document, as: UTF8.self)
            .replacingOccurrences(of: "\"formatVersion\": 7", with: "\"formatVersion\": 8").utf8)
        #expect(throws: DocJSON.DocJSONError.documentFormatNewer(file: 8)) {
            _ = try DocJSON.removeFormula(from: newer, formulaId: Self.formula)
        }
    }

    @Test func setPinnedAcceptsAFormulaId() throws {
        let out = try DocJSON.setPinned(from: Self.document, ids: [Self.formula, Self.text], pinned: true)
        let objects = try Self.objects(out)
        #expect(objects.map { $0["id"] as? String } == [Self.text, Self.formula, Self.arrow, Self.image])
        #expect(objects.map { $0["pinned"] as? Bool } == [true, true, false, false])
        #expect(objects[1]["latex"] as? String == "x^2", "only the flag changes")
    }

    /// A formula has no per-kind array from before the object list: it is never read from one
    /// and never written into one.
    @Test func aFormulaHasNoLegacyKey() throws {
        #expect(DocJSON.ElementKind.formula.legacyKey == nil)
        #expect(DocJSON.ElementKind.text.legacyKey == "placedTextsData")
        #expect(DocJSON.ElementKind.image.legacyKey == "placedImagesData")
        let legacy = try Self.object(Data(#"{"placedTextsData": [], "placedFormulasData": [{"id": "x"}]}"#.utf8))
        #expect(DocJSON.elements(.formula, of: legacy).isEmpty)
    }

    @Test func formulaIdsAreReadFromTheDocument() throws {
        #expect(DocJSON.elementIds(.formula, in: Self.document) == [Self.formula])
        #expect(DocJSON.elementIds(.arrow, in: Self.document) == [Self.arrow])
        #expect(DocJSON.elementIds(.formula, in: Data("not json".utf8)).isEmpty)
    }

    @Test func theFormatVersionStaysSeven() throws {
        #expect(DocJSON.knownFormatVersion == 7)
        let out = try DocJSON.removeFormula(from: Self.document, formulaId: Self.formula)
        #expect((try Self.object(out)["formatVersion"] as? NSNumber)?.intValue == 7)
    }

    // MARK: - The pure rules the handlers use

    /// The capability rule for a tool that takes MIXED ids: `formulas` joins only when one of
    /// them is a formula's in THIS document; with only other ids the string is the old one.
    @Test func mixedIdsJoinFormulasOnlyForAFormulasId() {
        #expect(MCPAdapter.idsNameAFormula([Self.formula], in: Self.document))
        #expect(MCPAdapter.idsNameAFormula([Self.text, Self.formula], in: Self.document))
        #expect(!MCPAdapter.idsNameAFormula([Self.text, Self.arrow, Self.image, "seed:1.0"], in: Self.document))
        #expect(MCPAdapter.joiningFormulas("tagElements", if: true) == "tagElements+formulas")
        #expect(MCPAdapter.joiningFormulas("tagElements", if: false) == "tagElements")
    }

    @Test func aSourceIsRefusedOnTheServerOnlyWhenBlankOrTooLong() {
        #expect(MCPAdapter.formulaSourceRefusal("  \n\t") == "emptyFormula")
        #expect(MCPAdapter.formulaSourceRefusal(String(repeating: "x", count: 4001)) == "formulaTooLong")
        #expect(MCPAdapter.formulaSourceRefusal(String(repeating: "x", count: 4000)) == nil)
        // UTF-16 units, the device's measure: 2000 emoji are 4000 units, one more is too long.
        #expect(MCPAdapter.formulaSourceRefusal(String(repeating: "😀", count: 2000)) == nil)
        #expect(MCPAdapter.formulaSourceRefusal(String(repeating: "😀", count: 2001)) == "formulaTooLong")
        // A source that does not typeset is the device's to store and report, never refused here.
        #expect(MCPAdapter.formulaSourceRefusal(#"\frac{1"#) == nil)
    }

    /// `restore_stroke_widths`' reply names what it was given. A formula id is a UUID like an
    /// arrow's, so the noun asks the document which ids are formulas.
    @Test func restoreWidthsDoesNotCallAFormulaAnArrow() {
        let formulas: Set<String> = [Self.formula]
        #expect(MCPAdapter.restoreTargetsNoun([Self.formula], formulaIds: formulas) == "formula")
        #expect(MCPAdapter.restoreTargetsNoun(["seed:1.0", Self.formula], formulaIds: formulas)
                == "elements (1 stroke and 1 formula)")
        #expect(MCPAdapter.restoreTargetsNoun([Self.arrow, Self.formula], formulaIds: formulas)
                == "elements (1 arrow and 1 formula)")
        #expect(MCPAdapter.restoreTargetsNoun(["seed:1.0", Self.arrow, Self.formula], formulaIds: formulas)
                == "elements (1 stroke, 1 arrow and 1 formula)")
        // Without formulas the nouns are what they were.
        #expect(MCPAdapter.restoreTargetsNoun(["seed:1.0", Self.arrow], formulaIds: []) == "elements (1 stroke and 1 arrow)")
        #expect(MCPAdapter.restoreTargetsNoun([Self.arrow, Self.arrow], formulaIds: []) == "arrows")
        #expect(MCPAdapter.restoreTargetsNoun(["seed:1.0"], formulaIds: []) == "stroke")
    }

    // MARK: - What an agent is told

    static func description(_ tool: String) throws -> String {
        try #require(MCPAdapter.toolDefinitions.first { $0.name == tool }?.description, "no tool \(tool)")
    }

    /// The things an agent cannot find out by trying: no `$` markers, a formula in a sentence is a
    /// text, where `canvasX`/`canvasY` are, that a source that does not typeset is stored and how to fix it.
    @Test func theToolTextsSayWhatAnAgentNeeds() throws {
        let add = try Self.description("add_formula")
        for needed in ["ONE LaTeX formula per object", "WITHOUT `$` markers", "`inlineMath: true`",
                       "LEFT END OF THE BASELINE", "point size", "`canvasX`", "`fontSize`", "canvasBounds",
                       "canvasBaseline", "invalidFontSize", "light-canonical", "STORED",
                       "`message`", "edit_formula", "emptyFormula", "formulaTooLong", "4000 UTF-16 code units", "`formulas` capability"] {
            #expect(add.contains(needed), "add_formula does not say \(needed)")
        }
        let edit = try Self.description("edit_formula")
        for needed in ["WITHOUT `$`", "LEFT END", "formulaNotFound", "`unchanged: true`", "grows along its baseline"] {
            #expect(edit.contains(needed), "edit_formula does not say \(needed)")
        }
        #expect(try Self.description("remove_formula").contains("needs no connected device"))
        #expect(try Self.description("list_formulas").contains("`inlineMath`"))
        for tool in ["set_layer", "set_pinned", "snap_points", "get_selection", "reorder_elements",
                     "copy_elements", "transform_elements", "select_elements", "reset_element_transforms"] {
            #expect(try Self.description(tool).lowercased().contains("formula"), "\(tool) does not name formulas")
        }
        // The id-taking tools advertise `formulaIds`, and render_sketch relays it (an allow-list).
        for tool in ["reorder_elements", "copy_elements", "transform_elements", "select_elements",
                     "reset_element_transforms", "render_sketch"] {
            let t = try #require(MCPAdapter.toolDefinitions.first { $0.name == tool })
            #expect(MCPAdapter.declaredArguments(of: t).contains("formulaIds"), "\(tool)")
        }
    }

    @Test func theGuideNamesFormulas() {
        let guide = AgentGuide.markdown
        for needed in ["## Formulas", "add_formula", "WITHOUT `$` markers", "`inlineMath: true`",
                       "LEFT END OF ITS", "edit_formula", "list_formulas", "remove_formula", "formulaIds",
                       "`formulas` capability"] {
            #expect(guide.contains(needed), "the guide does not say \(needed)")
        }
    }
}

#if MCP_SSE_CLIENT

import InfSketchWire

extension MCPAdapterTests {
/// The four tools and the capability joins, through a real MCP client against a running server,
/// with fake devices that announce exactly the capabilities a test needs. Nested in the
/// serialized `MCPAdapterTests` so its clients never run beside that suite's: the SDK client's
/// SSE stream goes deaf under several concurrent clients in one process (see that suite).
@Suite(.serialized) struct FormulaToolsTests {
    typealias D = FormulaDocJSONTests

    private func startServer() async throws -> (InfSketchServer, UInt16, Task<Void, any Error>) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("formula-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "d", bytes: D.document)
        try store.save(docId: "other", bytes: Fixtures.docBytes)
        let server = InfSketchServer(port: 0, docsDirectory: dir, config: SessionConfig())
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        return (server, port, task)
    }

    private func connectedClient(port: UInt16) async throws -> Client {
        let transport = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!,
                                            sseInitializationTimeout: 0.5)
        let client = Client(name: "formula-tools-test-client", version: "0.0.1")
        _ = try await client.connect(transport: transport)
        return client
    }

    private func text(_ content: [Tool.Content]) -> String {
        content.compactMap { if case .text(let t, _, _) = $0 { return t } else { return nil } }.joined()
    }

    private func raw(_ client: Client, _ docId: String) async throws -> Data {
        let contents = try await client.readResource(uri: "infsketch://doc/\(docId)/raw")
        return Data(base64Encoded: try #require(contents.first?.blob)) ?? Data()
    }

    private func spec(_ device: FakeStrokeOpDevice) async throws -> [String: Any] {
        let last = try #require(await device.receivedRequests.last)
        return try #require(try JSONSerialization.jsonObject(with: last.spec) as? [String: Any])
    }

    static let reply = Data(#"{"aaa001_thumbnailData":"","placedObjects":["after"]}"#.utf8)
    static let meta = Data(#"{"canvasBaseline":[40,71],"canvasBounds":[40,50,30,28],"id":"EEEEEEEE-0000-0000-0000-000000000002","typeset":true}"#.utf8)

    @Test func addFormulaGoesToADeviceWithTheFormulasCapability() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        // An app that does not know formulas is never asked.
        let old = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Self.reply),
                                               capabilities: ["authorText", "arrows"])
        let (refused, refusedError) = try await client.callTool(name: "add_formula", arguments: [
            "docId": "d", "latex": "x^2", "canvasX": 40, "canvasY": 71])
        #expect(refusedError == true)
        #expect(text(refused).hasPrefix("noDeviceAvailable") && text(refused).contains("`formulas`"), "\(text(refused))")
        #expect(await old.receivedRequests.isEmpty)
        await old.close()

        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytesWithMeta(bytes: Self.reply, meta: Self.meta),
                                                  capabilities: ["formulas"])
        defer { Task { await device.close() } }
        let (content, isError) = try await client.callTool(name: "add_formula", arguments: [
            "docId": "d", "latex": #"\frac{a}{b}"#, "canvasX": 40, "canvasY": 71, "fontSize": 30, "color": "#FF0000",
            "colorAppearance": "dark", "layer": "back", "tags": .array(["eq"])])
        #expect(isError != true, "\(text(content))")
        let s = try await spec(device)
        #expect(s["op"] as? String == "addFormula")
        #expect(Set(s.keys) == ["op", "latex", "canvasX", "canvasY", "fontSize", "color", "colorAppearance", "layer", "tags"])
        #expect(s["latex"] as? String == #"\frac{a}{b}"#)
        #expect(s["canvasX"] as? Double == 40 && s["canvasY"] as? Double == 71 && s["fontSize"] as? Double == 30)
        #expect(s["tags"] as? [String] == ["eq"])
        #expect(await device.receivedRequests.last?.docBytes == D.document)
        // The reply is the device's measurement with the seq, and the document is the device's bytes.
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [String: Any])
        #expect(reply["id"] as? String == "EEEEEEEE-0000-0000-0000-000000000002")
        #expect(reply["typeset"] as? Bool == true)
        #expect(reply["canvasBounds"] as? [Double] == [40, 50, 30, 28])
        #expect(reply["canvasBaseline"] as? [Double] == [40, 71])
        #expect(reply["seq"] as? Int != nil)
        #expect(try await raw(client, "d") == Self.reply)

        // Only the arguments given travel.
        _ = try await client.callTool(name: "add_formula", arguments: ["docId": "d", "latex": "y", "canvasX": 0, "canvasY": 0])
        #expect(Set(try await spec(device).keys) == ["op", "latex", "canvasX", "canvasY"])
        await server.stop()
    }

    @Test func editAndListGoToADevice() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }

        let editor = try await FakeStrokeOpDevice(port: port, autoReply: .bytesWithMeta(bytes: Self.reply, meta: Self.meta),
                                                  capabilities: ["formulas"])
        let (content, isError) = try await client.callTool(name: "edit_formula", arguments: [
            "docId": "d", "id": .string(D.formula), "latex": "y^3", "fontSize": 40, "color": "#00FF00",
            "colorAppearance": "light"])
        #expect(isError != true, "\(text(content))")
        let s = try await spec(editor)
        #expect(s["op"] as? String == "editFormula")
        #expect(Set(s.keys) == ["op", "id", "latex", "fontSize", "color", "colorAppearance"])
        #expect(s["id"] as? String == D.formula)
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [String: Any])
        #expect(reply["typeset"] as? Bool == true && reply["seq"] as? Int != nil)
        #expect(try await raw(client, "d") == Self.reply)
        await editor.close()

        let listing = Data(#"[{"id":"EEEEEEEE-0000-0000-0000-000000000001","latex":"x^2","typeset":true}]"#.utf8)
        let lister = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(listing), capabilities: ["formulas"])
        defer { Task { await lister.close() } }
        let (listed, listError) = try await client.callTool(name: "list_formulas", arguments: ["docId": "d"])
        #expect(listError != true)
        #expect(text(listed) == String(decoding: listing, as: UTF8.self), "the listing is passed through verbatim")
        let ls = try await spec(lister)
        #expect(ls["op"] as? String == "listFormulas" && Set(ls.keys) == ["op"])
        #expect(try await raw(client, "d") == Self.reply, "a listing writes nothing")
        await server.stop()
    }

    /// The device answers an edit that changes nothing with the request's own bytes: the server
    /// then writes nothing and says so, rather than bumping `seq` for every subscriber.
    @Test func aNoOpEditWritesNothing() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytesWithMeta(bytes: D.document, meta: Self.meta),
                                                  capabilities: ["formulas"])
        defer { Task { await device.close() } }
        let (content, isError) = try await client.callTool(name: "edit_formula", arguments: [
            "docId": "d", "id": .string(D.formula), "latex": "x^2"])
        #expect(isError != true)
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [String: Any])
        #expect(reply["unchanged"] as? Bool == true)
        #expect(reply["seq"] == nil, "nothing was written, so there is no seq to quote")
        #expect(try await raw(client, "d") == D.document)
        await server.stop()
    }

    @Test func emptyAndTooLongAreRefusedBeforeTheDevice() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytes(Self.reply), capabilities: ["formulas"])
        defer { Task { await device.close() } }

        let long = String(repeating: "x", count: 4001)
        let calls: [(String, [String: Value], String)] = [
            ("add_formula", ["latex": "  ", "canvasX": 0, "canvasY": 0], "emptyFormula"),
            ("add_formula", ["latex": .string(long), "canvasX": 0, "canvasY": 0], "formulaTooLong"),
            ("edit_formula", ["id": .string(D.formula), "latex": "\n"], "emptyFormula"),
            ("edit_formula", ["id": .string(D.formula), "latex": .string(long)], "formulaTooLong"),
        ]
        for (tool, args, reason) in calls {
            var a = args; a["docId"] = "d"
            let (content, isError) = try await client.callTool(name: tool, arguments: a)
            #expect(isError == true, "\(tool)")
            #expect(text(content).hasPrefix(reason), "\(tool): \(text(content))")
        }
        #expect(await device.receivedRequests.isEmpty, "the device is never asked")
        #expect(try await raw(client, "d") == D.document)
        await server.stop()
    }

    /// No device at all: the server edits the document's JSON itself.
    @Test func removeFormulaWorksOnAClosedDocument() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (content, isError) = try await client.callTool(name: "remove_formula", arguments: [
            "docId": "d", "id": .string(D.formula)])
        #expect(isError != true, "\(text(content))")
        #expect(text(content).contains(D.formula) && text(content).contains("seq"))
        let after = try await raw(client, "d")
        #expect(try D.objects(after).map { $0["id"] as? String } == [D.text, D.arrow, D.image])
        #expect(try D.object(after)["aaa001_thumbnailData"] == nil)
        await server.stop()
    }

    @Test func removeFormulaOfAnUnknownIdFails() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        for id in ["nope", D.arrow] {
            let (content, isError) = try await client.callTool(name: "remove_formula", arguments: [
                "docId": "d", "id": .string(id)])
            #expect(isError == true)
            #expect(text(content).hasPrefix("formulaNotFound"), "\(text(content))")
        }
        #expect(try await raw(client, "d") == D.document)
        await server.stop()
    }

    @Test func setPinnedAcceptsAFormulaId() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let (content, isError) = try await client.callTool(name: "set_pinned", arguments: [
            "docId": "d", "ids": .array([.string(D.formula)]), "pinned": true])
        #expect(isError != true, "\(text(content))")
        let objects = try D.objects(try await raw(client, "d"))
        #expect(objects.first { $0["id"] as? String == D.formula }?["pinned"] as? Bool == true)
        await server.stop()
    }

    /// The shared shape of every join test: with only the device an older app would be, a call
    /// without a formula id reaches it (the capability is EXACTLY the old one) and a call with
    /// one is refused naming every part it needs; a device that adds `formulas` gets it.
    private func expectJoin(tool: String, base: Set<String>, needs: String,
                            plain: [String: Value], withFormula: [String: Value],
                            relayedKey: String? = nil, subscribe: Bool = false,
                            port: UInt16, client: Client) async throws {
        // The device hands the document back as it was, so every call sees the formula in it.
        let reply: FakeStrokeOpDevice.AutoReply = .bytesWithMeta(bytes: D.document, meta: Data("{}".utf8))
        let old = try await FakeStrokeOpDevice(port: port, autoReply: reply, capabilities: base,
                                               subscribeTo: subscribe ? "d" : nil)
        let (plainContent, plainError) = try await client.callTool(name: tool, arguments: plain)
        #expect(plainError != true, "\(tool) without a formula id reaches the older app: \(text(plainContent))")
        #expect(await old.receivedRequests.count == 1, "\(tool)")
        let (refused, refusedError) = try await client.callTool(name: tool, arguments: withFormula)
        #expect(refusedError == true, "\(tool) with a formula id is not handed to the older app")
        #expect(text(refused).hasPrefix("noDeviceAvailable") && text(refused).contains("this call needs \(needs)"),
                "\(tool): \(text(refused))")
        #expect(await old.receivedRequests.count == 1, "\(tool)")
        await old.close()

        let newer = try await FakeStrokeOpDevice(port: port, autoReply: reply, capabilities: base.union(["formulas"]),
                                                 subscribeTo: subscribe ? "d" : nil)
        let (accepted, acceptedError) = try await client.callTool(name: tool, arguments: withFormula)
        #expect(acceptedError != true, "\(tool): \(text(accepted))")
        if let relayedKey {
            #expect(try await spec(newer)[relayedKey] != nil, "\(tool) relays \(relayedKey)")
        }
        await newer.close()
    }

    @Test func setLayerJoinsFormulasWhenAnIdIsAFormulas() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await expectJoin(
            tool: "set_layer", base: ["reorderElements", "objectLayerWrites"],
            needs: "`formulas` + `objectLayerWrites` + `reorderElements`",
            plain: ["docId": "d", "ids": .array([.string(D.arrow)]), "layer": "back"],
            withFormula: ["docId": "d", "ids": .array([.string(D.arrow), .string(D.formula)]), "layer": "back"],
            port: port, client: client)
        await server.stop()
    }

    @Test func reorderTakesFormulaIds() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        try await expectJoin(
            tool: "reorder_elements", base: ["reorderElements", "arrows", "objectLayerWrites"],
            needs: "`formulas` + `objectLayerWrites` + `reorderElements`",
            plain: ["docId": "d", "arrowIds": .array([.string(D.arrow)]), "mode": "front"],
            withFormula: ["docId": "d", "formulaIds": .array([.string(D.formula)]), "mode": "front"],
            relayedKey: "formulaIds", port: port, client: client)
        await server.stop()
    }

    @Test func tagAndSelectAndCopyAndTransformJoinFormulas() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let f: Value = .array([.string(D.formula)])
        try await expectJoin(
            tool: "tag_elements", base: ["tagElements"], needs: "`formulas` + `tagElements`",
            plain: ["docId": "d", "ids": .array([.string(D.text), "seed:1.0"]), "tags": .array(["eq"])],
            withFormula: ["docId": "d", "ids": .array([.string(D.text), .string(D.formula)]), "tags": .array(["eq"])],
            port: port, client: client)
        try await expectJoin(
            tool: "select_elements", base: ["controlSelection"], needs: "`controlSelection` + `formulas`",
            plain: ["docId": "d", "textIds": .array([.string(D.text)])],
            withFormula: ["docId": "d", "formulaIds": f],
            relayedKey: "formulaIds", subscribe: true, port: port, client: client)
        try await expectJoin(
            tool: "copy_elements", base: ["copyElements"], needs: "`copyElements` + `formulas`",
            plain: ["source": "d", "target": "other", "textIds": .array([.string(D.text)])],
            withFormula: ["source": "d", "target": "other", "formulaIds": f],
            relayedKey: "formulaIds", port: port, client: client)
        try await expectJoin(
            tool: "transform_elements", base: ["transformElements"], needs: "`formulas` + `transformElements`",
            plain: ["docId": "d", "textIds": .array([.string(D.text)]), "canvasTranslate": .array([1, 2])],
            withFormula: ["docId": "d", "formulaIds": f, "canvasTranslate": .array([1, 2])],
            relayedKey: "formulaIds", port: port, client: client)
        try await expectJoin(
            tool: "reset_element_transforms", base: ["transformElements"], needs: "`formulas` + `transformElements`",
            plain: ["docId": "d", "textIds": .array([.string(D.text)])],
            withFormula: ["docId": "d", "formulaIds": f],
            relayedKey: "formulaIds", port: port, client: client)
        try await expectJoin(
            tool: "render_sketch", base: ["authorStrokes"], needs: "`authorStrokes` + `formulas`",
            plain: ["docId": "d"],
            withFormula: ["docId": "d", "include": "formulas", "formulaIds": f],
            relayedKey: "formulaIds", port: port, client: client)
        await server.stop()
    }

    /// The wire names, as SETS (controller ruling S2-R11): what the server sends for each op, and
    /// that the old spellings are refused BY NAME before any device is asked (no aliasing). The
    /// app pins its decoder and replies the same way (`AgentFormulaToolsTests.
    /// theRepliesNameTheirFieldsLikeTheTextTools`), so a one-sided rename fails a test.
    @Test func theWireNamesAreTheTextTools() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytesWithMeta(bytes: Self.reply, meta: Self.meta),
                                                  capabilities: ["formulas"])
        defer { Task { await device.close() } }
        let (content, _) = try await client.callTool(name: "add_formula", arguments: [
            "docId": "d", "latex": "a", "canvasX": 1, "canvasY": 2, "fontSize": 30, "color": "#FF0000",
            "colorAppearance": "light", "layer": "front", "tags": .array(["eq"])])
        #expect(Set(try await spec(device).keys)
                == ["op", "latex", "canvasX", "canvasY", "fontSize", "color", "colorAppearance", "layer", "tags"])
        // The device's measurement reaches the agent under its own names, with the seq.
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(text(content).utf8)) as? [String: Any])
        #expect(Set(reply.keys) == ["id", "typeset", "canvasBounds", "canvasBaseline", "seq"])
        _ = try await client.callTool(name: "edit_formula", arguments: [
            "docId": "d", "id": .string(D.formula), "latex": "b", "fontSize": 40, "color": "#00FF00",
            "colorAppearance": "dark"])
        #expect(Set(try await spec(device).keys) == ["op", "id", "latex", "fontSize", "color", "colorAppearance"])
        let asked = await device.receivedRequests.count

        let old: [(String, [String: Value], String)] = [
            ("add_formula", ["latex": "a", "x": 1, "y": 2], "x"),
            ("add_formula", ["latex": "a", "canvasX": 1, "canvasY": 2, "size": 30], "size"),
            ("edit_formula", ["id": .string(D.formula), "size": 30], "size"),
        ]
        for (tool, args, key) in old {
            var a = args; a["docId"] = "d"
            let (refused, isError) = try await client.callTool(name: tool, arguments: a)
            #expect(isError == true, "\(tool) with \(key)")
            #expect(text(refused).contains(key) && text(refused).hasPrefix("invalidArgument"), "\(tool): \(text(refused))")
        }
        #expect(await device.receivedRequests.count == asked, "an old spelling never reaches the device")
        await server.stop()
    }

    /// The tool's reply asks the document which ids are formulas (`restoreTargetsNoun`).
    @Test func restoreWidthsDoesNotCallAFormulaAnArrow() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let client = try await connectedClient(port: port)
        defer { Task { await client.disconnect() } }
        let device = try await FakeStrokeOpDevice(port: port, autoReply: .bytesWithMeta(
            bytes: Self.reply, meta: Data(#"{"restoredIds":[],"unchangedIds":[]}"#.utf8)))
        defer { Task { await device.close() } }
        let (content, _) = try await client.callTool(name: "restore_stroke_widths", arguments: [
            "docId": "d", "ids": .array([.string(D.arrow), .string(D.formula)])])
        #expect(text(content).contains("elements (1 arrow and 1 formula)"), "\(text(content))")
        await server.stop()
    }
}
}

#endif  // MCP_SSE_CLIENT
