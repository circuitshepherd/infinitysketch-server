import Foundation
import MCP
import InfSketchWire

// MARK: - MCPAdapter (Task 6, mcp_endpoint branch)
//
// Replaces the Task 1 spike's hello-world MCP server (`makeSpikeMCPServer`,
// one global `MCP.Server` + one `StatefulHTTPServerTransport`) with the real
// resource surface, and — per the spike's single-session caveat — a proper
// per-session registry.
//
// [SPIKE-PIN-1]/[SPIKE-PIN-2] (see task-1-report.md): `StatefulHTTPServerTransport`
// only supports one `initialize` per instance, and a single `MCP.Server`
// actor can only usefully back one live transport (its `connection` is
// last-transport-wins). So this adapter owns a `[sessionID: (Server,
// Transport)]` map, keyed by the `Mcp-Session-Id` header, creating a fresh
// pair per `initialize` — the same pattern as the SDK's own
// `MCPConformance/Server/HTTPApp.swift` reference (adapted here for
// FlyingFox via `MCPMount.swift`, which is now a thin, stateless
// FlyingFox<->MCP.HTTPRequest/Response converter that forwards every
// request into `handle(_:)` below).
//
// [SPIKE-PIN-2] session identity inside a handler: `Server.currentHandlerContext?
// .httpContext?.header(HTTPHeaderName.sessionID)` (a task-local the SDK sets
// per-dispatch). `makeServer()` is deliberately parameterless and reusable —
// the one handler that needs to know its session (`resources/subscribe`)
// reads this per-request instead of a captured value.
//
// [SPIKE-PIN-3] addressing one session for a push is "call `.notify` on
// THAT session's own `Server`" — there is no broadcast primitive. That's why
// the notify path below looks up `sessions[sessionID]?.server` and calls
// `.notify` on it directly.
public actor MCPAdapter {
    private struct Session {
        let server: MCP.Server
        let transport: StatefulHTTPServerTransport
        /// Monotonic last-request time, for idle reaping. The SDK's own
        /// client NEVER sends `DELETE /mcp` (verified in 0.12.1 — its
        /// `disconnect()` only invalidates the local URLSession), so idle
        /// reaping is the ORDINARY teardown path for MCP sessions, not a
        /// safety net. Without it every connect/disconnect cycle leaks a
        /// `Server` + receive-loop Task + transport, and each write to a doc
        /// the dead session subscribed grows the transport's unbounded
        /// storedEvents/SSE buffers forever.
        var lastAccessedAt: ContinuousClock.Instant
    }

    private struct CooldownKey: Hashable {
        let session: String
        let docId: String
    }

    private let manager: SessionManager
    private let idleTimeout: Duration
    private let cleanupInterval: Duration
    /// The shared device-command broker (one per `InfSketchServer` process,
    /// the same instance `WSAdapter` registers capability-tagged connections
    /// with); `callCreateDoc` awaits `broker.requestCreation` on it.
    private let broker: DeviceCommandBroker
    private var debouncer = NotificationDebouncer()
    private var sessions: [String: Session] = [:]
    /// Per-(session, doc) cooldown timers. The adapter owns every one of
    /// these Tasks; a late fire after the pair has unsubscribed is harmless
    /// (the debouncer's own membership check makes `cooldownEnded` a no-op),
    /// but `endSession` cancels them proactively anyway to avoid needless work.
    private var cooldownTasks: [CooldownKey: Task<Void, Never>] = [:]
    private var pumpTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var statusToken: UUID?
    /// Set (permanently) by `shutdown()`. Checked by the pump after it
    /// acquires its status subscription, closing the narrow race where
    /// `shutdown()` runs while the pump is still suspended in
    /// `subscribeStatus()` — without this the subscription (and the pump's
    /// for-await) would survive shutdown.
    private var isShutdown = false

    /// Test hook: the ids of the currently registered MCP sessions.
    var activeSessionIDs: [String] { Array(sessions.keys) }

    /// Test hook: the debouncer's live docId → sessions map (value copy).
    var debouncerSubscriptions: [String: Set<String>] { debouncer.subscriptions }

    public init(
        manager: SessionManager,
        idleTimeout: Duration = .seconds(3600),
        cleanupInterval: Duration = .seconds(60),
        broker: DeviceCommandBroker
    ) {
        self.manager = manager
        self.idleTimeout = idleTimeout
        self.cleanupInterval = cleanupInterval
        self.broker = broker
    }

    /// Starts the notification pump and the idle-session cleanup loop on
    /// first use. (An actor can't spawn a `Task` capturing `self` from
    /// inside its own `init` — Swift 6 treats that as escaping a
    /// not-yet-fully-initialized `self` — so this is called lazily, from
    /// `handle(_:)`, instead. This is still eager enough for correctness:
    /// no session can exist before at least one HTTP request has gone
    /// through `handle(_:)`, so both loops are always running by the time
    /// there's anyone to notify or reap.)
    private func ensureBackgroundTasksStarted() {
        guard pumpTask == nil, !isShutdown else { return }
        pumpTask = Task { [weak self] in
            await self?.runNotificationPump()
        }
        cleanupTask = Task { [weak self] in
            await self?.runCleanupLoop()
        }
    }

    /// Tears down the notification pump, the idle-cleanup loop, every live
    /// session's `Server` receive loop, and every outstanding cooldown
    /// timer. The adapter's session registry gave the spike's
    /// previously-unowned receive-loop Task a natural owner (see
    /// task-1-report.md, Concern 3) — this is where that owner discharges
    /// its duty. Called from `InfSketchServer.stop()`.
    public func shutdown() async {
        isShutdown = true
        pumpTask?.cancel()
        pumpTask = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        if let statusToken {
            await manager.unsubscribeStatus(statusToken)
        }
        statusToken = nil
        for task in cooldownTasks.values {
            task.cancel()
        }
        cooldownTasks.removeAll()
        for session in sessions.values {
            await session.server.stop()
        }
        sessions.removeAll()
    }

    // MARK: - Per-session MCP.Server factory

    /// Builds a fresh `MCP.Server` with every resource handler registered.
    /// Stateless and reusable: the handlers that need session identity read
    /// it per-request (see [SPIKE-PIN-2] above) rather than through a
    /// captured parameter, so this factory itself takes none.
    public func makeServer() async -> MCP.Server {
        let server = MCP.Server(
            name: "infsketch",
            version: ServerInfo.version,
            capabilities: .init(
                resources: .init(subscribe: true, listChanged: nil),
                tools: .init(listChanged: nil))
        )

        await server.withMethodHandler(ListResources.self) { [weak self] _ in
            guard let self else { throw MCPError.internalError("MCPAdapter deallocated") }
            return try await self.handleListResources()
        }
        await server.withMethodHandler(ReadResource.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("MCPAdapter deallocated") }
            return try await self.handleReadResource(uri: params.uri)
        }
        await server.withMethodHandler(ResourceSubscribe.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("MCPAdapter deallocated") }
            return try await self.handleSubscribe(uri: params.uri)
        }
        await server.withMethodHandler(ResourceUnsubscribe.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("MCPAdapter deallocated") }
            return try await self.handleUnsubscribe(uri: params.uri)
        }
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { throw MCPError.internalError("MCPAdapter deallocated") }
            return try await self.handleListTools()
        }
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else { throw MCPError.internalError("MCPAdapter deallocated") }
            return try await self.handleCallTool(name: params.name, arguments: params.arguments)
        }

        return server
    }

    // MARK: - HTTP entry point (called by MCPMount)

    /// Routes one bridged MCP HTTP request, mirroring the SDK's own
    /// `MCPConformance/Server/HTTPApp.swift` reference multi-session pattern
    /// ([SPIKE-PIN-1]): a request carrying a known `Mcp-Session-Id` forwards
    /// to that session's transport (and, on a successful DELETE, ends the
    /// session); an unrecognized session id 404s; anything else must be a
    /// bare `initialize` POST (pre-checked, like the reference, BEFORE any
    /// session is allocated), which creates a fresh session — rolled back
    /// if the transport's validation pipeline still rejects it.
    public func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        ensureBackgroundTasksStarted()
        let headerSessionID = request.header(HTTPHeaderName.sessionID)

        if let headerSessionID {
            guard var session = sessions[headerSessionID] else {
                return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
            }
            session.lastAccessedAt = .now
            sessions[headerSessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                await endSession(headerSessionID)
            }
            return response
        }

        // No session header: only a bare `initialize` POST may proceed.
        // Pre-check the body BEFORE allocating anything (the SDK reference
        // does the same via JSONRPCMessageKind.isInitializeRequest — that
        // type is package-scoped, so this is a minimal local equivalent),
        // so junk POSTs can't churn Server actors + receive-loop Tasks.
        guard request.method.uppercased() == "POST",
              Self.isInitializeRequest(request.body)
        else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
        }

        let newSessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: newSessionID))
        let server = await makeServer()
        try? await server.start(transport: transport)
        sessions[newSessionID] = Session(server: server, transport: transport, lastAccessedAt: .now)

        let response = await transport.handleRequest(request)
        if case .error = response {
            // The transport's validation pipeline rejected the initialize
            // (bad Accept header etc.): the session never really lived.
            sessions.removeValue(forKey: newSessionID)
            await server.stop()
        }
        return response
    }

    /// True iff `body` is a JSON-RPC `initialize` *request* (has an id).
    /// Linux-safe local stand-in for the SDK's package-scoped
    /// `JSONRPCMessageKind.isInitializeRequest`.
    private static func isInitializeRequest(_ body: Data?) -> Bool {
        guard let body,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              json["method"] as? String == "initialize",
              let id = json["id"], !(id is NSNull)
        else { return false }
        return true
    }

    /// Ends a session: stops its `Server`'s receive loop, disconnects the
    /// transport, and forgets every debouncer subscription/cooldown for it.
    private func endSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.server.stop()
        debouncer.unsubscribeAll(session: sessionID)
        for key in cooldownTasks.keys where key.session == sessionID {
            cooldownTasks.removeValue(forKey: key)?.cancel()
        }
    }

    // MARK: - Resource handlers

    private func handleListResources() async throws -> ListResources.Result {
        var resources = ResourceURI.templateResources
        for entry in try await manager.listDocuments() {
            resources.append(
                Resource(
                    name: entry.id,
                    uri: ResourceURI.docSummary(docId: entry.id).uriString,
                    mimeType: "application/json"))
        }
        return ListResources.Result(resources: resources)
    }

    private func handleReadResource(uri: String) async throws -> ReadResource.Result {
        guard let parsed = ResourceURI(uri) else {
            throw MCPError.invalidParams("Unrecognized resource uri: \(uri)")
        }

        switch parsed {
        case .docsList:
            let entries = try await manager.listDocuments()
            return ReadResource.Result(contents: [
                .text(try Self.jsonString(entries), uri: uri, mimeType: "application/json")
            ])

        case .docSummary(let docId):
            guard let bytes = await manager.currentBytes(docId: docId) else {
                throw MCPError.invalidParams("Unknown document: \(docId)")
            }
            let summary: DocJSON.DocSummary
            do {
                summary = try DocJSON.summary(from: bytes)
            } catch {
                throw MCPError.internalError("Could not parse document \(docId): \(error)")
            }
            let seq = await manager.liveInfo()[docId]?.seq ?? -1
            let envelope = DocSummaryEnvelope(seq: seq, summary: summary)
            return ReadResource.Result(contents: [
                .text(try Self.jsonString(envelope), uri: uri, mimeType: "application/json")
            ])

        case .docRaw(let docId):
            guard let bytes = await manager.currentBytes(docId: docId) else {
                throw MCPError.invalidParams("Unknown document: \(docId)")
            }
            return ReadResource.Result(contents: [
                .binary(bytes, uri: uri, mimeType: "application/octet-stream")
            ])

        case .docFrame(let docId):
            if let frame = await manager.latestFrame(docId: docId) {
                return ReadResource.Result(contents: [
                    .binary(frame.png, uri: uri, mimeType: "image/png")
                ])
            }
            guard let bytes = await manager.currentBytes(docId: docId),
                  let thumbnail = ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: bytes)
            else {
                throw MCPError.invalidParams("No frame or thumbnail available for document: \(docId)")
            }
            return ReadResource.Result(contents: [
                .binary(thumbnail, uri: uri, mimeType: "image/png")
            ])
        }
    }

    /// [SPIKE-PIN-2]: validates the uri is a known doc, then registers the
    /// CALLING session (read off the task-local HTTP context — this handler
    /// runs inside the session's own `Server`, dispatched with that
    /// session's originating request attached) with the debouncer.
    private func handleSubscribe(uri: String) async throws -> ResourceSubscribe.Result {
        guard case .docSummary(let docId) = ResourceURI(uri) else {
            throw MCPError.invalidParams("Can only subscribe to a document resource, got: \(uri)")
        }
        guard await manager.currentBytes(docId: docId) != nil else {
            throw MCPError.invalidParams("Unknown document: \(docId)")
        }
        guard let sessionID = Server.currentHandlerContext?.httpContext?.header(HTTPHeaderName.sessionID) else {
            throw MCPError.internalError("Missing session id on subscribe request")
        }
        debouncer.subscribe(session: sessionID, docId: docId)
        return Empty()
    }

    /// The mirror of `handleSubscribe`. With idle reaping being the only
    /// other client-reachable stop (the SDK client never sends DELETE),
    /// this is how a client stops `resources/updated` for one doc without
    /// ending its whole session. No known-doc validation — unsubscribing a
    /// doc you never subscribed (or that no longer exists) is a benign no-op.
    private func handleUnsubscribe(uri: String) async throws -> ResourceUnsubscribe.Result {
        guard case .docSummary(let docId) = ResourceURI(uri) else {
            throw MCPError.invalidParams("Can only unsubscribe from a document resource, got: \(uri)")
        }
        guard let sessionID = Server.currentHandlerContext?.httpContext?.header(HTTPHeaderName.sessionID) else {
            throw MCPError.internalError("Missing session id on unsubscribe request")
        }
        debouncer.unsubscribe(session: sessionID, docId: docId)
        cooldownTasks.removeValue(forKey: CooldownKey(session: sessionID, docId: docId))?.cancel()
        return Empty()
    }

    // MARK: - Tool handlers (Task 7)
    //
    // Every tool composes full document bytes and writes through
    // `SessionManager.submitOpeningSession` (opId prefixed "mcp-") — the exact
    // same seq-assignment/store-write/broadcast path any other writer uses,
    // so agent edits surface through the app's remote-change banner and the
    // web frames like any foreign write. Per the spec's error-handling
    // section, tool failures are MCP TOOL-RESULT errors (`isError: true`
    // carrying the server reason as the text content) — never thrown
    // `MCPError`s — so a client/agent can see and react to the reason
    // ("unknownDoc", "textNotFound", "invalidDocumentJSON", or a submit
    // rejection reason). The only thrown case left in `handleCallTool` is an
    // unrecognized tool NAME, which is a protocol-level misuse, not a
    // reachable domain failure.
    //
    // MANDATORY (Task 3 review, finding N2): argument extraction below reads
    // `Value.int`/`.double` only, via `Double(_:)`'s STRICT initializer —
    // never `Double(someString)`. A client sending x/y as a JSON string is
    // rejected as `invalidArgument: x`, not parsed — `Double("40000")` would
    // silently succeed and, for `Double("NaN")`, would arm `DocJSON.addText`/
    // `.editText`'s finite-value preconditions remotely. The SDK's own
    // `Value` decoder already rejects non-finite/overflow numeric literals at
    // the JSON layer (verified in Task 3's review), so any `Double`/`Int`
    // case reaching here is guaranteed finite.

    /// Task 2 (write CAS): appended verbatim to the description of every
    /// tool whose write now carries an `expectedBytes` compare-and-swap
    /// (add/edit/remove_text, replace_doc, draw/delete_strokes) — NOT
    /// create_doc (nothing to compare — its docExists guard is the race's
    /// only meaningful shape) or list_strokes (never writes).
    private static let casRejectionSentence =
        "Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry."

    /// A stroke point in EITHER form: the bare `[x, y]` pair (synthesis
    /// defaults for everything else) or the rich object carrying any subset
    /// of PencilKit's per-point attributes. `get_strokes` always RETURNS the
    /// rich form, so a fetch → alter → put-back is lossless; in a
    /// `reshape_strokes`, attributes the agent omits are resampled from the
    /// ORIGINAL stroke along the new path. Shared verbatim by
    /// `draw_strokes`, `render_sketch`'s ephemeral strokes, and
    /// `reshape_strokes` — ONE definition, so drift between the three call
    /// sites is structurally impossible; pinned by
    /// pointSchemaIsSharedAcrossDrawRenderAndReshapeTools.
    private static let pointSchema: Value = .object([
        "oneOf": .array([
            .object([
                "type": "array",
                "description": "A bare [x, y] canvas-coordinate pair.",
                "items": .object(["type": "number"]),
                "minItems": 2,
                "maxItems": 2,
            ]),
            .object([
                "type": "object",
                "description": "A rich point: x and y are required, every attribute is optional.",
                "properties": .object([
                    "x": .object(["type": "number"]),
                    "y": .object(["type": "number"]),
                    "size": .object([
                        "type": "array",
                        "description": "[width, height] of the point's stamp, both > 0.",
                        "items": .object(["type": "number"]),
                        "minItems": 2,
                        "maxItems": 2,
                    ]),
                    "opacity": .object(["type": "number"]),
                    "force": .object(["type": "number"]),
                    "azimuth": .object(["type": "number"]),
                    "altitude": .object(["type": "number"]),
                    "timeOffset": .object(["type": "number"]),
                    "secondaryScale": .object(["type": "number"]),
                ]),
                "required": .array(["x", "y"].map(Value.string)),
            ]),
        ]),
    ])

    /// The canonical per-stroke item schema — points/width/color/inkType —
    /// shared verbatim by `draw_strokes`'s `strokes` array and, since Task 5,
    /// `render_sketch`'s EPHEMERAL `strokes` array: both decode app-side into
    /// the same `StrokeAuthoring.StrokeSpec` shape (a draw commits it; a
    /// render synthesizes it through the identical code and never writes
    /// it). One schema, one place a drifted field name could be introduced,
    /// pinned by drawStrokesSpecEnvelopeMatchesCanonicalShape AND
    /// renderSketchSpecEnvelopeMatchesCanonicalShape.
    private static let strokeItemSchema: Value = .object([
        "type": "object",
        "properties": .object([
            "points": .object([
                "type": "array",
                "description": """
                    The stroke's polyline; at least 2 points. Each point is \
                    either an [x, y] pair or a rich point object.
                    """,
                "items": pointSchema,
            ]),
            "width": .object([
                "type": "number",
                "description": "Stroke width. Defaults to 4.",
            ]),
            "color": .object([
                "type": "string",
                "description": "Stroke colour as #RRGGBB or #RRGGBBAA hex. Defaults to #000000.",
            ]),
            "inkType": .object([
                "type": "string",
                "enum": .array(["pen", "pencil", "marker", "monoline"].map(Value.string)),
                "description": """
                    The ink to draw with. Defaults to pen. Note: monoline \
                    persists as pen — PencilKit's archive format does not \
                    preserve it, so a monoline stroke lists back as pen.
                    """,
            ]),
        ]),
        "required": .array(["points"].map(Value.string)),
    ])

    private static let tools: [Tool] = [
        Tool(
            name: "add_text",
            description: """
                Appends a minimal-attribute placed-text entry to a document: a new id, \
                plain unformatted text (the app backfills body-style font/colour on load), \
                the document's current colour scheme, and an identity transform/opacity. \
                (x, y) is the text box's top-left corner, in canvas coordinates. \
                \(casRejectionSentence)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "text": .object(["type": "string", "description": "The text to place."]),
                    "x": .object(["type": "number", "description": "Canvas-space x of the text box's top-left corner."]),
                    "y": .object(["type": "number", "description": "Canvas-space y of the text box's top-left corner."]),
                    "pinned": .object([
                        "type": "boolean",
                        "description": "Excludes the text from selection transforms. Defaults to false.",
                    ]),
                ]),
                "required": .array(["docId", "text", "x", "y"].map(Value.string)),
            ])
        ),
        Tool(
            name: "edit_text",
            description: """
                Mutates an existing placed text by id: replace its string and/or move it. \
                WARNING: replacing the text resets that entry's rich formatting to plain \
                defaults — the attributed run's bold/italic/font/colour attributes are \
                UIKit-archived data no server-side code can synthesize, so a new text run \
                always replaces the old ones wholesale. Position-only edits (x and/or y with \
                no text) do not touch formatting. \(casRejectionSentence)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "textId": .object(["type": "string", "description": "The id of the text entry to edit."]),
                    "text": .object([
                        "type": "string",
                        "description": "Replacement text. Resets formatting to plain defaults — see the tool description.",
                    ]),
                    "x": .object(["type": "number", "description": "New canvas-space x of the text box's top-left corner."]),
                    "y": .object(["type": "number", "description": "New canvas-space y of the text box's top-left corner."]),
                ]),
                "required": .array(["docId", "textId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "remove_text",
            description: "Removes a placed text entry from a document by id. \(casRejectionSentence)",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "textId": .object(["type": "string", "description": "The id of the text entry to remove."]),
                ]),
                "required": .array(["docId", "textId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "replace_doc",
            description: """
                Replaces a document's raw bytes wholesale, creating it if it doesn't yet \
                exist. The bytes are opaque to the server — the agent owns their validity, \
                the same trust any other writer on the network has. \(casRejectionSentence)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to write."]),
                    "bytes": .object(["type": "string", "description": "Base64-encoded .infsketch document bytes."]),
                ]),
                "required": .array(["docId", "bytes"].map(Value.string)),
            ])
        ),
        Tool(
            name: "create_doc",
            description: """
                Creates a new document containing the InfinitySketch app's empty default \
                content, authored by a connected InfinitySketch device. REQUIRES such a \
                device to be connected to the server — fails with noDeviceAvailable if none \
                is, deviceTimeout if it doesn't respond in time, and docExists if a document \
                with this id already exists.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to create."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "draw_strokes",
            description: """
                Draws one or more freehand strokes into a document, authored by a connected \
                InfinitySketch device. Each stroke is a polyline of (x, y) points in canvas \
                coordinates — the same space as add_text's x/y — plus optional width, color, \
                and inkType fields. Defaults for any stroke that omits them: inkType "pen", \
                width 4, color "#000000". REQUIRES a connected device — fails with \
                noDeviceAvailable if none is connected, deviceTimeout if it doesn't respond in \
                time, opInProgress if another stroke operation on this document is already in \
                flight, and deviceFailed: <reason> if the device rejects the strokes (e.g. \
                malformed points). The result names the seq the write was assigned. \
                \(casRejectionSentence)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "strokes": .object([
                        "type": "array",
                        "description": """
                            One or more strokes to draw. Passed through to the device \
                            verbatim; the item properties below are the exact field names \
                            the device decodes.
                            """,
                        // The item properties are the CANONICAL stroke-spec field names —
                        // points / width / color / inkType — that the app-side decoder
                        // (StrokeAuthoring.StrokeSpec, Task 5) reads. That decoder is a
                        // plain Decodable, which silently DROPS unknown keys, so this
                        // schema is the only place a calling agent learns the exact
                        // names; a drifted name (e.g. "tool") would not error — the field
                        // would just fall back to its default. Pinned server-side by
                        // drawStrokesSpecEnvelopeMatchesCanonicalShape; change both repos
                        // in lockstep or not at all. Shared verbatim with render_sketch's
                        // ephemeral `strokes` array via strokeItemSchema.
                        "items": strokeItemSchema,
                    ]),
                ]),
                "required": .array(["docId", "strokes"].map(Value.string)),
            ])
        ),
        Tool(
            name: "delete_strokes",
            description: """
                Deletes one or more strokes from a document by their composite stroke keys \
                (as returned by list_strokes), authored by a connected InfinitySketch device. \
                REQUIRES a connected device — fails with noDeviceAvailable if none is \
                connected, deviceTimeout if it doesn't respond in time, opInProgress if \
                another stroke operation on this document is already in flight, and \
                deviceFailed: <reason> if a key doesn't match any stroke. The result names the \
                seq the write was assigned. \(casRejectionSentence)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "keys": .object([
                        "type": "array",
                        "description": "The composite stroke keys to delete, as returned by list_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                ]),
                "required": .array(["docId", "keys"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_strokes",
            description: """
                Lists every stroke currently in a document — each with its composite key \
                (usable with delete_strokes) and geometry — authored by a connected \
                InfinitySketch device. REQUIRES a connected device — fails with \
                noDeviceAvailable if none is connected and deviceTimeout if it doesn't \
                respond in time. Returns the device's listing verbatim as text; this call \
                never writes to the document. A stroke drawn by hand with an ink outside \
                pen/pencil/marker (fountain pen, watercolour, crayon…) lists under that \
                ink's name but cannot be re-drawn with draw_strokes, whose inkType enum \
                covers only the four names above.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to list strokes from."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "render_sketch",
            description: """
                Renders a region of a document, specific strokes, and/or ephemeral \
                candidate strokes that are not written to the document — use it to \
                preview a stroke before committing it with draw_strokes, optionally \
                composited over the document's real content to judge fit and alignment. \
                Authored by a connected InfinitySketch device. Returns a PNG plus \
                metadata: the covered rect, the scale actually used, the current \
                appearance, the canvas contentSize, and per-grid line families for both \
                drawing and snapping. Align new strokes to the lattices of enabled \
                grids; only visible grids actually appear in the rendered image — \
                visible and enabled are independent, so a grid can be snapped to \
                without being drawable, or drawn without being snapped to. REQUIRES a \
                connected device — fails with noDeviceAvailable if none is connected, \
                deviceTimeout if it doesn't respond in time, and deviceFailed: <reason> \
                for a bad spec (e.g. an unknown strokeKey, or nothing to render). \
                Read-only: it never writes to the document, so there is no seq assigned \
                and nothing to retry.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to render."]),
                    "include": .object([
                        "type": "string",
                        "enum": .array(["document", "strokes", "none"].map(Value.string)),
                        "description": """
                            What document content to render, alongside any ephemeral \
                            strokes below. "document" (default): every stroke, placed \
                            image, and placed text. "strokes": only the strokes named \
                            by strokeKeys — no images or texts. "none": nothing from \
                            the document.
                            """,
                    ]),
                    "strokeKeys": .object([
                        "type": "array",
                        "description": """
                            With include: "strokes", the composite stroke keys (as \
                            returned by list_strokes) to show.
                            """,
                        "items": .object(["type": "string"]),
                    ]),
                    "strokes": .object([
                        "type": "array",
                        "description": """
                            EPHEMERAL candidate strokes to render — the exact stroke \
                            shape draw_strokes takes. Synthesized through the same code \
                            a commit would use, so the preview is byte-identical to \
                            what draw_strokes would produce, but nothing here is ever \
                            written to the document.
                            """,
                        // Shared verbatim with draw_strokes's `strokes` schema — see the
                        // comment on strokeItemSchema above.
                        "items": strokeItemSchema,
                    ]),
                    "rect": .object([
                        "type": "array",
                        "description": """
                            [x, y, w, h] in canvas coordinates. Omit for auto-fit: the \
                            tight bounding box of everything rendered, expanded by padding.
                            """,
                        "items": .object(["type": "number"]),
                        "minItems": 4,
                        "maxItems": 4,
                    ]),
                    "padding": .object([
                        "type": "number",
                        "description": """
                            Auto-fit margin in canvas points. Defaults to 10% of the \
                            fitted box's larger side, minimum 20.
                            """,
                    ]),
                    "background": .object([
                        "type": "string",
                        "enum": .array(["transparent", "paper", "paper+grid"].map(Value.string)),
                        "description": """
                            "transparent", "paper" (the document's background colour \
                            for the current appearance), or "paper+grid" (default — \
                            the grid is what agents align to).
                            """,
                    ]),
                    "axes": .object([
                        "type": "boolean",
                        "description": """
                            Overlay light tick marks and coordinate labels along the \
                            edges. Defaults to false (a render meant for visual \
                            judgement stays clean).
                            """,
                    ]),
                    "maxPixels": .object([
                        "type": "number",
                        "description": """
                            Pixel budget. Defaults to 1000000, hard ceiling 4000000. An \
                            over-large request is downscaled, not rejected, and the \
                            metadata reports the scale actually used.
                            """,
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "get_strokes",
            description: """
                Reads strokes in full fidelity: every point with its size, opacity, \
                force, azimuth, altitude, timeOffset and secondaryScale, plus the \
                stroke's width, colour, inkType and transform. Field names are \
                symmetric with draw_strokes/reshape_strokes, so a fetch → alter → \
                put-back needs no translation and loses nothing. Nothing is capped or \
                decimated by the server — use list_strokes' pointCount to price a \
                fetch first, and maxPoints if you want a guard of your own; a request \
                over that guard fails with pointBudgetExceeded(<actual>), naming the \
                real total. Note: monoline persists as pen — PencilKit's archive \
                format does not preserve it, so a monoline stroke lists back as pen. \
                Read-only.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to read strokes from."]),
                    "keys": .object([
                        "type": "array",
                        "description": "Composite stroke keys, as returned by list_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                    "maxPoints": .object([
                        "type": "integer",
                        "description": """
                            YOUR OWN budget guard, not a server limit: fails with \
                            pointBudgetExceeded(<actual>) if the request's total point \
                            count exceeds this. Omit for no limit.
                            """,
                    ]),
                ]),
                "required": .array(["docId", "keys"].map(Value.string)),
            ])
        ),
        Tool(
            name: "transform_strokes",
            description: """
                Moves, scales and/or rotates strokes in place. The strokes keep their \
                identity (keys), their points and their z-order — only their placement \
                changes. Scale and rotate act about anchor, which defaults to the \
                centre of the keys' union bounding box. With snapToGrid, the whole SET \
                is shifted rigidly (never additionally scaled or rotated) so the anchor \
                lands on the lattice of the document's ENABLED grids — including \
                invisible guide grids (visible and enabled are independent; see \
                render_sketch's metadata for every grid's lattice); with no enabled \
                grid, snapToGrid is a no-op. snapToGrid alone, with no translate/scale/ \
                rotate, is a legal request. \(casRejectionSentence)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "keys": .object([
                        "type": "array",
                        "description": "Composite stroke keys, as returned by list_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                    "translate": .object([
                        "type": "array",
                        "description": "[dx, dy] in canvas points.",
                        "items": .object(["type": "number"]),
                        "minItems": 2, "maxItems": 2,
                    ]),
                    "scale": .object([
                        "type": "array",
                        "description": "[sx, sy] about the anchor; non-zero.",
                        "items": .object(["type": "number"]),
                        "minItems": 2, "maxItems": 2,
                    ]),
                    "rotate": .object([
                        "type": "number",
                        "description": "Degrees about the anchor; positive = clockwise on screen.",
                    ]),
                    "anchor": .object([
                        "type": "array",
                        "description": "[x, y]. Defaults to the centre of the keys' union bounding box.",
                        "items": .object(["type": "number"]),
                        "minItems": 2, "maxItems": 2,
                    ]),
                    "snapToGrid": .object([
                        "type": "boolean",
                        "description": """
                            Land the anchor on the nearest lattice point of the document's \
                            ENABLED grids, shifting the whole set by that one delta. \
                            No enabled grid = no-op.
                            """,
                    ]),
                ]),
                "required": .array(["docId", "keys"].map(Value.string)),
            ])
        ),
        Tool(
            name: "restyle_strokes",
            description: """
                Changes strokes' colour, width and/or ink in place; identity and \
                geometry survive. width is the TARGET PEAK stroke width — the same \
                quantity get_strokes/list_strokes report, not a tool-slider value — \
                and is CLAMPED to what the target ink can express (pen tops out around \
                peak 6; marker cannot render below roughly 7.5), so a thin pen stroke \
                necessarily gets thicker when restyled to marker; get_strokes reports \
                the actual resulting peak. An ink-only restyle (no width) preserves the \
                stroke's apparent thickness. A colour-only restyle changes nothing \
                else. Note: monoline persists as pen — PencilKit's archive format does \
                not preserve it. \(casRejectionSentence)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "keys": .object([
                        "type": "array",
                        "description": "Composite stroke keys, as returned by list_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                    "color": .object([
                        "type": "string",
                        "description": "#RRGGBB or #RRGGBBAA.",
                    ]),
                    "width": .object([
                        "type": "number",
                        "description": """
                            Target PEAK stroke width (> 0) — the same quantity \
                            get_strokes/list_strokes report, not a tool-slider value. \
                            Clamped to what the target ink can express (pen tops out \
                            around peak 6; marker cannot go below roughly 7.5) — \
                            get_strokes reports the actual resulting peak.
                            """,
                    ]),
                    "inkType": .object([
                        "type": "string",
                        "enum": .array(["pen", "pencil", "marker", "monoline"].map(Value.string)),
                        "description": """
                            Note: monoline persists as pen — PencilKit's archive format \
                            does not preserve it.
                            """,
                    ]),
                ]),
                "required": .array(["docId", "keys"].map(Value.string)),
            ])
        ),
        Tool(
            name: "reshape_strokes",
            description: """
                Replaces strokes' geometry in place, keeping their identity (key), \
                ink, z-order and width-edit history. Attributes you OMIT on a point \
                are resampled from the ORIGINAL stroke along the new path — so \
                straightening a wobbly line with plain [x, y] pairs keeps its pressure \
                taper. Supply attributes explicitly to override that. \(casRejectionSentence)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "strokes": .object([
                        "type": "array",
                        "description": "One or more strokes to reshape by key.",
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "key": .object([
                                    "type": "string",
                                    "description": "The composite key of the stroke to reshape.",
                                ]),
                                "points": .object([
                                    "type": "array",
                                    "description": """
                                        The new polyline; at least 2 points. Each point is \
                                        either an [x, y] pair or a rich point object.
                                        """,
                                    "items": pointSchema,
                                ]),
                            ]),
                            "required": .array(["key", "points"].map(Value.string)),
                        ]),
                    ]),
                ]),
                "required": .array(["docId", "strokes"].map(Value.string)),
            ])
        ),
    ]

    private func handleListTools() async throws -> ListTools.Result {
        ListTools.Result(tools: Self.tools)
    }

    private func handleCallTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        switch name {
        case "add_text": return await callAddText(arguments)
        case "edit_text": return await callEditText(arguments)
        case "remove_text": return await callRemoveText(arguments)
        case "replace_doc": return await callReplaceDoc(arguments)
        case "create_doc": return await callCreateDoc(arguments)
        case "draw_strokes": return await callDrawStrokes(arguments)
        case "delete_strokes": return await callDeleteStrokes(arguments)
        case "list_strokes": return await callListStrokes(arguments)
        case "render_sketch": return await callRenderSketch(arguments)
        case "get_strokes": return await callGetStrokes(arguments)
        case "transform_strokes": return await callTransformStrokes(arguments)
        case "restyle_strokes": return await callRestyleStrokes(arguments)
        case "reshape_strokes": return await callReshapeStrokes(arguments)
        default:
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
    }

    private func callAddText(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let text = try Self.stringArg(arguments, "text")
            let x = try Self.doubleArg(arguments, "x")
            let y = try Self.doubleArg(arguments, "y")
            let pinned = try Self.boolArg(arguments, "pinned", default: false)

            guard let bytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let newId = UUID()
            let out: Data
            do {
                out = try DocJSON.addText(to: bytes, id: newId, text: text, x: x, y: y, pinned: pinned)
            } catch let error as DocJSON.DocJSONError {
                return Self.errorResult(Self.reason(for: error))
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out, expectedBytes: bytes
            ) { seq in
                "added \(newId.uuidString) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callEditText(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let textId = try Self.stringArg(arguments, "textId")
            let newText = try Self.optionalStringArg(arguments, "text")
            let x = try Self.optionalDoubleArg(arguments, "x")
            let y = try Self.optionalDoubleArg(arguments, "y")

            guard let bytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let out: Data
            do {
                out = try DocJSON.editText(in: bytes, textId: textId, newText: newText, x: x, y: y)
            } catch let error as DocJSON.DocJSONError {
                return Self.errorResult(Self.reason(for: error))
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out, expectedBytes: bytes
            ) { seq in
                "edited \(textId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callRemoveText(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let textId = try Self.stringArg(arguments, "textId")

            guard let bytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let out: Data
            do {
                out = try DocJSON.removeText(from: bytes, textId: textId)
            } catch let error as DocJSON.DocJSONError {
                return Self.errorResult(Self.reason(for: error))
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out, expectedBytes: bytes
            ) { seq in
                "removed \(textId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Unlike the other three text tools, this never reads/parses the
    /// current bytes to compute the replacement — the bytes are opaque by
    /// design (spec: "the agent owns their validity"). It still gets a CAS
    /// (Task 2, write CAS): read the doc's current bytes first and pass them
    /// as the expectation when it exists; `nil` when it doesn't, which also
    /// selects the create path via `createIfMissing: true` (unchanged). A
    /// blind overwrite of a doc that changed under the agent's feet is
    /// exactly the loss this plan exists to prevent — on rejection, the
    /// agent can re-read and re-decide instead of clobbering someone else's
    /// edit. `createIfMissing: true` is harmless in the existing-doc branch
    /// too (it only matters when no session and no stored doc exist), so one
    /// call covers both branches.
    private func callReplaceDoc(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let bytes = try Self.base64DataArg(arguments, "bytes")
            let currentBytes = await manager.currentBytes(docId: docId)
            return await submitAndRespond(
                docId: docId, createIfMissing: true, fullDoc: bytes, expectedBytes: currentBytes
            ) { seq in
                "replaced \(docId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Unlike the other four tools, the bytes to write don't come from the
    /// agent or from mutating the current document — they're solicited live
    /// from a connected InfinitySketch device via `broker.requestCreation`
    /// (`DeviceCommandBroker`, routed over the WS `createDocRequest`/
    /// `createDocReply` pair). `docExists` is checked BEFORE ever contacting
    /// a device, so an existing docId never reaches (or wakes) the device.
    private func callCreateDoc(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")

            if await manager.currentBytes(docId: docId) != nil {
                return Self.errorResult("docExists")
            }

            let bytes: Data
            do {
                bytes = try await broker.requestCreation(docId: docId)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                switch error {
                case .noDeviceAvailable: return Self.errorResult("noDeviceAvailable")
                // Published string stays "creationInProgress" (pinned by
                // MCPAdapterTests.createDocInFlightErrorPublishesCreationInProgress)
                // even though the case itself is now the kind-agnostic
                // `.requestInFlight`.
                case .requestInFlight: return Self.errorResult("creationInProgress")
                case .deviceTimeout: return Self.errorResult("deviceTimeout")
                case .deviceFailed(let why): return Self.errorResult("deviceFailed: \(why)")
                }
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // expectedBytes: nil — nothing to compare against (the doc did not
            // exist when `docExists` was checked above), so this write is
            // deliberately unconditional. Stated explicitly, not defaulted,
            // per the review's M1.
            return await submitAndRespond(
                docId: docId, createIfMissing: true, fullDoc: bytes, expectedBytes: nil
            ) { seq in
                "created \(docId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    // MARK: - Stroke-op tools (Task 4, agent stroke-authoring)
    //
    // Unlike `add_text`/`edit_text`/`remove_text` (which mutate the document
    // JSON locally via `DocJSON`), stroke construction/deletion/listing
    // happens on a connected InfinitySketch device: the server's job is only
    // to compose a minimal op-spec envelope (`{"op": "draw"|"delete"|"list",
    // …}`, built by JSON-encoding the SDK's own `Value` arguments — `Value`
    // is `Codable`, so `JSONEncoder().encode(Value.object(...))` produces the
    // exact wire bytes), relay it plus the document's current bytes through
    // `broker.requestStrokeOp`, and (for draw/delete) write back whatever
    // full-document bytes the device returns through the same
    // `submitAndRespond` tail every other write tool uses. Validation here is
    // deliberately MINIMAL — non-empty docId, a non-empty `strokes` array for
    // draw, a non-empty string `keys` array for delete — deep validation
    // (stroke shape, colours, unknown keys, …) is the device's job, surfaced
    // verbatim as `deviceFailed: <reason>`. `list_strokes` never writes: its
    // result is the device's listing bytes decoded as UTF-8 text, passed
    // straight through.

    private func callDrawStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let strokes = try Self.nonEmptyValueArrayArg(arguments, "strokes")

            guard let docBytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(
                    Value.object(["op": .string("draw"), "strokes": .array(strokes)]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // expectedBytes is docBytes — the exact bytes relayed to the
            // device — never a fresh re-read here, which would re-open the
            // very window this guard exists to close (Task 2, write CAS).
            // `.meta` is render-only (nil here) — draw/delete ignore it.
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "drew \(strokes.count) stroke(s) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callDeleteStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let keys = try Self.nonEmptyStringArrayArg(arguments, "keys")

            guard let docBytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(
                    Value.object(["op": .string("delete"), "keys": .array(keys.map(Value.string))]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // expectedBytes is docBytes — the exact bytes relayed to the
            // device — never a fresh re-read here (Task 2, write CAS).
            // `.meta` is render-only (nil here) — delete ignores it.
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "deleted \(keys.count) stroke(s) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Never writes: the device's listing bytes are decoded as UTF-8 and
    /// passed straight through as the tool result's text content — opaque to
    /// this server, same trust posture as `replace_doc`'s bytes.
    private func callListStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("list")]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // `.meta` is render-only (nil here) — list ignores it.
            return CallTool.Result(content: [
                .text(text: String(data: out.bytes, encoding: .utf8) ?? "", annotations: nil, _meta: nil)
            ])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Task 5 (agent render/preview). Like the three stroke-op tools above,
    /// this composes a minimal op-spec envelope and relays it (plus the
    /// document's current bytes) through `broker.requestStrokeOp` — but
    /// UNLIKE every other tool in this file, it is READ-ONLY: no
    /// `submitAndRespond`, no `submitOpeningSession`, no `expectedBytes`. A
    /// render never writes, so the write-CAS does not apply (Global
    /// Constraints: "A test must prove the document is byte-identical
    /// afterwards"). Every parameter beyond `docId` is OPTIONAL and is
    /// relayed present-only — an argument the caller omitted is omitted from
    /// the envelope too, never sent as an explicit null (see
    /// renderSketchWithOnlyDocIdOmitsEveryOptionalField); deep validation
    /// (stroke shape, unknown strokeKeys, degenerate rect, pixel budget) is
    /// the device's job, surfaced verbatim as `deviceFailed: <reason>`.
    private func callRenderSketch(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var specFields: [String: Value] = ["op": .string("render")]
            for key in Self.renderSpecParameterNames {
                if let value = arguments?[key] {
                    specFields[key] = value
                }
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(specFields))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // `out.meta` is the device's RenderMetadata JSON — present on
            // every genuine render reply. A missing/undecodable one degrades
            // to an empty text block rather than throwing, so a malformed
            // device reply still surfaces the image content.
            let metadataText = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return CallTool.Result(content: [
                .image(data: out.bytes.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
                .text(text: metadataText, annotations: nil, _meta: nil),
            ])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// The Global-Constraints parameter names `render_sketch` relays
    /// verbatim into the op-spec envelope alongside `"op": "render"` — every
    /// one of them optional; see `callRenderSketch`.
    private static let renderSpecParameterNames = [
        "include", "strokeKeys", "strokes", "rect", "padding", "background", "axes", "maxPixels",
    ]

    // MARK: - Stroke-editing tools (spec 2026-07-14):
    // get/transform/restyle/reshape_strokes
    //
    // Same shape as the Task 4 stroke-op tools above: compose a minimal
    // op-spec envelope containing ONLY the fields the caller actually
    // supplied (so the envelope's exact key set is deterministic and
    // pinned by strokeEditingSpecEnvelopesMatchTheCanonicalShape), relay it
    // plus the document's current bytes through `broker.requestStrokeOp`,
    // and — for the three writes — tail into `submitAndRespond` with
    // `expectedBytes: docBytes`, THE EXACT BYTES RELAYED TO THE DEVICE,
    // never a fresh re-read (Task 2, write CAS: a re-read would re-open the
    // very race the guard exists to close). `get_strokes` never writes: no
    // `submitAndRespond`, no seq bump, the device's listing bytes decoded as
    // UTF-8 and passed straight through, exactly like `list_strokes`.

    /// Read-only, like `list_strokes`/`render_sketch`: the device's listing
    /// bytes are decoded as UTF-8 and passed straight through. No
    /// `submitAndRespond`, so no seq bump and no CAS — a read never writes.
    private func callGetStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let keys = try Self.nonEmptyStringArrayArg(arguments, "keys")

            guard let docBytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("get"),
                "keys": .array(keys.map(Value.string)),
            ]
            if let maxPoints = arguments?["maxPoints"]?.intValue {
                envelope["maxPoints"] = .int(maxPoints)
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return CallTool.Result(content: [
                .text(text: String(decoding: out.bytes, as: UTF8.self), annotations: nil, _meta: nil)
            ])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callTransformStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let keys = try Self.nonEmptyStringArrayArg(arguments, "keys")

            guard let docBytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("transform"),
                "keys": .array(keys.map(Value.string)),
            ]
            // Only the keys the caller actually supplied — deep validation
            // (finite values, non-zero scale, at-least-one-op) is the
            // device's job, surfaced verbatim as `deviceFailed: <reason>`.
            for name in ["translate", "scale", "rotate", "anchor", "snapToGrid"] {
                if let value = arguments?[name] {
                    envelope[name] = value
                }
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // expectedBytes is docBytes — the exact bytes relayed to the
            // device, never a fresh re-read here, which would re-open the
            // very window this guard exists to close (Task 2, write CAS).
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "transformed \(keys.count) stroke(s) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callRestyleStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let keys = try Self.nonEmptyStringArrayArg(arguments, "keys")

            guard let docBytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("restyle"),
                "keys": .array(keys.map(Value.string)),
            ]
            for name in ["color", "width", "inkType"] {
                if let value = arguments?[name] {
                    envelope[name] = value
                }
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // expectedBytes is docBytes — the exact bytes relayed to the
            // device (Task 2, write CAS) — never a fresh re-read.
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "restyled \(keys.count) stroke(s) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callReshapeStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let items = try Self.nonEmptyValueArrayArg(arguments, "strokes")

            guard let docBytes = await manager.currentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(
                    Value.object(["op": .string("reshape"), "strokes": .array(items)]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // expectedBytes is docBytes — the exact bytes relayed to the
            // device (Task 2, write CAS) — never a fresh re-read.
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "reshaped \(items.count) stroke(s) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Maps `DeviceCommandBroker.DeviceCommandError` to the published
    /// tool-error string for every device-relayed stroke-op tool
    /// (draw/delete/list_strokes; render_sketch since Task 5;
    /// get/transform/restyle/reshape_strokes since the stroke-editing spec,
    /// 2026-07-14). UNLIKE `create_doc` (whose `.requestInFlight` publishes
    /// the pinned "creationInProgress" string — see `callCreateDoc` above),
    /// these publish "opInProgress" per the Task 4 spec's error-string
    /// mapping; every one of these tools shares the same per-docId in-flight
    /// guard (the broker's `docIdsInFlight` is keyed by docId alone, not by
    /// op kind), so any two can collide on the same doc.
    private static func strokeOpErrorResult(_ error: DeviceCommandBroker.DeviceCommandError) -> CallTool.Result {
        switch error {
        case .noDeviceAvailable: return Self.errorResult("noDeviceAvailable")
        case .requestInFlight: return Self.errorResult("opInProgress")
        case .deviceTimeout: return Self.errorResult("deviceTimeout")
        case .deviceFailed(let why): return Self.errorResult("deviceFailed: \(why)")
        }
    }

    /// Shared submit tail for every write tool (add/edit/remove_text,
    /// replace_doc, create_doc, draw/delete_strokes): opens a session on demand,
    /// writes the composed full-document bytes, and shapes the MCP result —
    /// success names the assigned seq (carried back by the write itself in
    /// `SubmitOutcome.accepted` — NEVER read back via a separate
    /// `liveInfo()` hop, which a racing concurrent write to the same doc
    /// could have bumped past this write's own seq before the read ran),
    /// `.rejected` becomes a tool error carrying the server's reason
    /// verbatim — this is also how a stale `expectedBytes` (Task 2, write
    /// CAS) surfaces: `docChangedDuringOp` flows through unchanged, no
    /// separate mapping needed.
    ///
    /// `expectedBytes` MUST be the exact bytes the caller already
    /// read/relayed for this write — never a fresh re-read taken here, which
    /// would just re-open the very race window this guard exists to close.
    /// `nil` means unconditional (`create_doc`, and the missing-doc branch of
    /// `replace_doc`).
    ///
    /// DELIBERATELY NOT DEFAULTED (Task 2 review, M1): a write tool added
    /// tomorrow that simply forgets the parameter would otherwise compile,
    /// ship, and write unconditionally — silently reopening this plan's data
    /// loss. Required means the compiler, not a test, is the guard; every
    /// call site must state its expectation, `nil` included.
    private func submitAndRespond(
        docId: String, createIfMissing: Bool, fullDoc bytes: Data,
        expectedBytes: Data?, successText: (Int) -> String
    ) async -> CallTool.Result {
        let opId = "mcp-\(UUID().uuidString)"
        let payload = OpPayload(type: "fullDoc", data: bytes)
        switch await manager.submitOpeningSession(
            docId: docId, createIfMissing: createIfMissing, opId: opId, payload: payload,
            expectedBytes: expectedBytes
        ) {
        case .accepted(let seq):
            return CallTool.Result(content: [.text(text: successText(seq), annotations: nil, _meta: nil)])
        case .rejected(let message):
            guard case .reject(_, _, let reason, _) = message else {
                return Self.errorResult("unexpectedServerResponse")
            }
            return Self.errorResult(reason)
        }
    }

    private static func reason(for error: DocJSON.DocJSONError) -> String {
        switch error {
        case .invalidDocumentJSON: return "invalidDocumentJSON"
        case .textNotFound: return "textNotFound"
        }
    }

    private static func errorResult(_ reason: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: reason, annotations: nil, _meta: nil)], isError: true)
    }

    // MARK: - Tool argument extraction
    //
    // Every accessor reads a `Value` case directly (or, for numbers, via
    // `Double(_:)`'s default STRICT mode, which only converts `.double`/
    // `.int` — see the MANDATORY note above the tools section). None of
    // these ever call a `String`-parsing initializer on an argument.

    private enum ArgumentError: Error {
        case missing(String)
        case invalidType(String)

        var reason: String {
            switch self {
            case .missing(let key): return "missingArgument: \(key)"
            case .invalidType(let key): return "invalidArgument: \(key)"
            }
        }
    }

    private static func stringArg(_ arguments: [String: Value]?, _ key: String) throws -> String {
        guard let value = arguments?[key] else { throw ArgumentError.missing(key) }
        guard case .string(let s) = value else { throw ArgumentError.invalidType(key) }
        return s
    }

    private static func optionalStringArg(_ arguments: [String: Value]?, _ key: String) throws -> String? {
        guard let value = arguments?[key], !value.isNull else { return nil }
        guard case .string(let s) = value else { throw ArgumentError.invalidType(key) }
        return s
    }

    private static func doubleArg(_ arguments: [String: Value]?, _ key: String) throws -> Double {
        guard let value = arguments?[key] else { throw ArgumentError.missing(key) }
        guard let d = Double(value) else { throw ArgumentError.invalidType(key) }
        return d
    }

    private static func optionalDoubleArg(_ arguments: [String: Value]?, _ key: String) throws -> Double? {
        guard let value = arguments?[key], !value.isNull else { return nil }
        guard let d = Double(value) else { throw ArgumentError.invalidType(key) }
        return d
    }

    private static func boolArg(_ arguments: [String: Value]?, _ key: String, default def: Bool) throws -> Bool {
        guard let value = arguments?[key], !value.isNull else { return def }
        guard let b = Bool(value) else { throw ArgumentError.invalidType(key) }
        return b
    }

    private static func base64DataArg(_ arguments: [String: Value]?, _ key: String) throws -> Data {
        let string = try stringArg(arguments, key)
        guard let data = Data(base64Encoded: string) else { throw ArgumentError.invalidType(key) }
        return data
    }

    /// A `stringArg` that additionally rejects the empty string — the
    /// stroke-op tools' minimal `docId` validation (Task 4).
    private static func nonEmptyStringArg(_ arguments: [String: Value]?, _ key: String) throws -> String {
        let s = try stringArg(arguments, key)
        guard !s.isEmpty else { throw ArgumentError.invalidType(key) }
        return s
    }

    /// A non-empty JSON array argument, returned as raw `Value`s so the
    /// caller can re-embed it verbatim into an op-spec envelope (the
    /// stroke-op tools never inspect element shape — see the MARK above).
    private static func nonEmptyValueArrayArg(_ arguments: [String: Value]?, _ key: String) throws -> [Value] {
        guard let value = arguments?[key] else { throw ArgumentError.missing(key) }
        guard case .array(let items) = value, !items.isEmpty else { throw ArgumentError.invalidType(key) }
        return items
    }

    /// A non-empty JSON array argument whose elements must all be strings
    /// (`delete_strokes`'s `keys`).
    private static func nonEmptyStringArrayArg(_ arguments: [String: Value]?, _ key: String) throws -> [String] {
        let items = try nonEmptyValueArrayArg(arguments, key)
        var strings: [String] = []
        strings.reserveCapacity(items.count)
        for item in items {
            guard case .string(let s) = item else { throw ArgumentError.invalidType(key) }
            strings.append(s)
        }
        return strings
    }

    // MARK: - Idle-session reaping

    /// Periodic sweep reaping sessions idle past `idleTimeout`, adapted
    /// from the SDK reference's `HTTPApp.sessionCleanupLoop`. This is the
    /// ORDINARY teardown path (see `Session.lastAccessedAt`): the SDK
    /// client never sends DELETE, so without this every connect/disconnect
    /// cycle would leak the session permanently.
    private func runCleanupLoop() async {
        while !Task.isCancelled && !isShutdown {
            try? await Task.sleep(for: cleanupInterval)
            if Task.isCancelled || isShutdown { break }
            let now = ContinuousClock.now
            let expired = sessions.filter { now - $0.value.lastAccessedAt > idleTimeout }.map(\.key)
            for sessionID in expired {
                await endSession(sessionID)
            }
        }
    }

    // MARK: - Notification pump

    /// One Task, for the adapter's whole lifetime, consuming
    /// `manager.subscribeStatus()`. Every `docUpdated` status event is fed
    /// to the (pure) debouncer; a `.notify` command pushes immediately and
    /// arms a per-(session, doc) cooldown.
    private func runNotificationPump() async {
        let (events, token) = await manager.subscribeStatus()
        statusToken = token
        // shutdown() may have run while we were suspended in
        // subscribeStatus() above (before statusToken was assigned) — its
        // `if let statusToken` then saw nil and could not unsubscribe. Do
        // it ourselves so the subscription never outlives shutdown.
        if isShutdown {
            statusToken = nil
            await manager.unsubscribeStatus(token)
            return
        }
        for await message in events {
            guard case .statusEvent(let payload) = message, payload.kind == "docUpdated" else { continue }
            await apply(debouncer.docUpdated(docId: payload.docId), docId: payload.docId)
        }
    }

    private func apply(_ command: NotificationDebouncer.Command, docId: String) async {
        guard case .notify(let sessionIDs) = command else { return }
        for sessionID in sessionIDs {
            await pushUpdate(sessionID: sessionID, docId: docId)
            scheduleCooldown(session: sessionID, docId: docId)
        }
    }

    private func pushUpdate(sessionID: String, docId: String) async {
        guard let server = sessions[sessionID]?.server else { return }
        let uri = ResourceURI.docSummary(docId: docId).uriString
        try? await server.notify(ResourceUpdatedNotification.message(.init(uri: uri)))
    }

    private func scheduleCooldown(session: String, docId: String) {
        let key = CooldownKey(session: session, docId: docId)
        cooldownTasks[key]?.cancel()
        cooldownTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: NotificationDebouncer.minInterval)
            guard !Task.isCancelled else { return }
            await self?.cooldownEnded(session: session, docId: docId)
        }
    }

    private func cooldownEnded(session: String, docId: String) async {
        cooldownTasks.removeValue(forKey: CooldownKey(session: session, docId: docId))
        await apply(debouncer.cooldownEnded(session: session, docId: docId), docId: docId)
    }

    // MARK: - Helpers

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

/// `resources/read` payload for `infsketch://doc/<id>` — the live seq (or
/// `-1` when the doc has no live session) alongside the pure `DocJSON`
/// summary.
private struct DocSummaryEnvelope: Encodable {
    var seq: Int
    var summary: DocJSON.DocSummary
}

/// A fixed-value `SessionIDGenerator`: the adapter picks the session id
/// itself (so it can register the (Server, Transport) pair under that exact
/// key before the transport ever sees a request), then hands the transport
/// this generator so it assigns the same id.
private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}

/// The `infsketch://` resource URI scheme: a doc list, plus per-doc summary
/// / raw bytes / frame PNG. Deliberately plain string splitting (no
/// `URLComponents`) — doc ids never contain "/" (`DirectoryDocumentStore`
/// enforces this), and this keeps the parser Linux-safe with no Foundation
/// URL-parsing surface.
enum ResourceURI: Equatable {
    case docsList
    case docSummary(docId: String)
    case docRaw(docId: String)
    case docFrame(docId: String)

    private static let scheme = "infsketch://"

    init?(_ uri: String) {
        guard uri.hasPrefix(Self.scheme) else { return nil }
        let parts = uri.dropFirst(Self.scheme.count)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        switch parts {
        case ["docs"]:
            self = .docsList
        case let p where p.count == 2 && p[0] == "doc":
            self = .docSummary(docId: p[1])
        case let p where p.count == 3 && p[0] == "doc" && p[2] == "raw":
            self = .docRaw(docId: p[1])
        case let p where p.count == 3 && p[0] == "doc" && p[2] == "frame":
            self = .docFrame(docId: p[1])
        default:
            return nil
        }
    }

    var uriString: String {
        switch self {
        case .docsList: return "\(Self.scheme)docs"
        case .docSummary(let docId): return "\(Self.scheme)doc/\(docId)"
        case .docRaw(let docId): return "\(Self.scheme)doc/\(docId)/raw"
        case .docFrame(let docId): return "\(Self.scheme)doc/\(docId)/frame"
        }
    }

    /// The four URI-template resources advertised by `resources/list` — the
    /// doc list plus one informational entry per per-doc resource kind (no
    /// concrete `{docId}` substitution). Concrete per-doc entries are
    /// appended separately, one per `manager.listDocuments()` result.
    static var templateResources: [Resource] {
        [
            Resource(
                name: "docs", uri: "\(scheme)docs",
                description: "All documents on the server", mimeType: "application/json"),
            Resource(
                name: "doc-summary", uri: "\(scheme)doc/{docId}",
                description: "Placed texts, colour scheme, and canvas size for one document",
                mimeType: "application/json"),
            Resource(
                name: "doc-raw", uri: "\(scheme)doc/{docId}/raw",
                description: "Raw .infsketch document bytes", mimeType: "application/octet-stream"),
            Resource(
                name: "doc-frame", uri: "\(scheme)doc/{docId}/frame",
                description: "Latest rendered frame, or the stored thumbnail if none is live",
                mimeType: "image/png"),
        ]
    }
}
