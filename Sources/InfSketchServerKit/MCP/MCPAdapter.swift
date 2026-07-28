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
    /// What each agent tool call changed, so `undo_last_edit` can take one back. Deliberately NOT
    /// on `DocumentSession` — see the type's own doc comment for why agent scope has to hold by
    /// construction here rather than by a flag inside `submit`.
    private let history = AgentEditHistory()
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

    /// M2c-3: `entry.hasContent == false` means this doc is metadata-only — its content lives
    /// on a connected device (M2c-1's live index) — so the resource carries a `description`
    /// hint pointing the agent at `fetch_doc` to pull it explicitly. A resident doc's
    /// `description` stays nil (the ordinary, silent-auto-fetch case every other tool already
    /// handles via `currentBytesOrFetch`).
    private func handleListResources() async throws -> ListResources.Result {
        var resources = ResourceURI.templateResources
        for entry in try await manager.listDocuments() {
            resources.append(
                Resource(
                    name: entry.id,
                    uri: ResourceURI.docSummary(docId: entry.id).uriString,
                    description: entry.hasContent
                        ? nil
                        : "content is on another device — call fetch_doc(\"\(entry.id)\") to pull it",
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
            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
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
            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
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
            guard let bytes = await manager.currentBytesOrFetch(docId: docId),
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
    /// (add/edit/remove_text, replace_doc, draw/delete_strokes, and the
    /// stroke-editing writes transform/restyle/reshape_strokes) — NOT
    /// create_doc (nothing to compare — its docExists guard is the race's
    /// only meaningful shape) and NOT the read-only tools, which never write:
    /// list_strokes, get_strokes, render_sketch, snap_points, list_fonts.
    /// The two caveats every WRITE tool shares. Attached to the same set of tools, because they
    /// are the same set: anything that can be CAS-rejected can also be undone by the user.
    private static let writeToolCaveats =
        "Rejected with docChangedDuringOp if the document changed while this call was being processed — re-read the document and retry. "
        + "The USER CAN UNDO your edit at any time (one undo step per tool call), so ids you obtained earlier may no longer exist: "
        + "re-read (list_strokes / list_texts / list_images / get_selection) before acting on them rather than caching. "
        + "Subscribe to the resource infsketch://doc/<docId> if you want to be told when the document changes."

    // MARK: - Styled text (styled_text branch)
    //
    // add_text/edit_text decide plain-vs-styled FROM THE ARGUMENTS: none of
    // color/fontSize/bold/italic/family/spans present → the unchanged
    // server-side DocJSON path (byte-identical); any present → relay a
    // device op (addText/editText), gated on the "authorText" capability
    // (DeviceCommandBroker.requestStrokeOp's capability: parameter) rather
    // than "authorStrokes". list_fonts always relays listFonts, read-only.
    // These are the exact NEW envelope keys the app-side TextAuthoring
    // decodes (`AddSpec`/`EditSpec`/`SpanSpec`, `Server/TextAuthoring.swift`)
    // — a plain `Decodable` that silently drops unknown keys, so a
    // field-name drift here would never fail loudly; every agent would just
    // keep getting default-styled text. Pinned by the styled add/edit_text
    // envelope-contract tests (mirroring drawStrokesSpecEnvelopeMatchesCanonicalShape).
    private static let styleArgKeys = ["color", "fontSize", "bold", "italic", "family", "spans"]

    /// True iff any style/spans argument is present (and not an explicit
    /// JSON null) — the plain-vs-styled routing decision for
    /// `callAddText`/`callEditText`.
    ///
    /// `name` is in the list even though it is not a style: an element name lives in
    /// `elementNames`, which the server-side `DocJSON` path does not write, so a named
    /// `add_text` must take the device path or the name would be silently dropped.
    private static func hasStyleArgs(_ arguments: [String: Value]?) -> Bool {
        (styleArgKeys + ["name"]).contains { key in
            guard let value = arguments?[key] else { return false }
            return !value.isNull
        }
    }

    /// Shared style properties for add_text/edit_text (whole-field). Colours
    /// are #RRGGBB(AA). A whole-field style is the base a `spans` entry
    /// overrides.
    private static let textStyleProperties: [String: Value] = [
        "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA. Default: the document's automatic text colour."]),
        "fontSize": .object(["type": "number", "description": "Point size, 1–512."]),
        "bold": .object(["type": "boolean"]),
        "italic": .object(["type": "boolean"]),
        "family": .object(["type": "string", "description": "A font family name from list_fonts. An unknown family fails with unknownFont."]),
    ]

    /// One `spans` array entry: required `text`, plus every whole-field
    /// style property as an optional per-span override.
    private static let textSpanItemSchema: Value = .object([
        "type": "object",
        "properties": .object(
            ["text": .object(["type": "string", "description": "This span's text."])]
                .merging(textStyleProperties) { current, _ in current }
        ),
        "required": .array(["text"].map(Value.string)),
    ])

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
    ///
    /// **x and y are CANVAS coordinates in every one of those four directions.**
    /// A stroke's underlying `PKStrokePath` is stored in a local, pre-transform
    /// space, and strokes the user has rect-dragged (or `transform_strokes` has
    /// moved) carry a non-identity transform — so the app maps points OUT through
    /// that transform in `get_strokes` and BACK through its inverse in
    /// `reshape_strokes` (`StrokeEditing.canvasPoints(of:)`). The agent never sees
    /// the local space and never has to apply a matrix; the `transform` array on a
    /// `get_strokes` result is information, not homework.
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
                "description": """
                    A rich point: x and y (canvas coordinates) are required, every \
                    other attribute is optional.
                    """,
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
                "description": "Peak stroke width. OMIT IT to inherit the width of the tool the user currently has selected (see get_tool).",
            ]),
            "color": .object([
                "type": "string",
                "description": "Stroke colour as #RRGGBB or #RRGGBBAA hex. OMIT IT to inherit the colour of the tool the user currently has selected in the picker (see get_tool); falls back to a paper-contrasting default when no inking tool is selected.",
            ]),
            "inkType": .object([
                "type": "string",
                "enum": .array(["pen", "pencil", "marker", "monoline"].map(Value.string)),
                "description": """
                    The ink to draw with. OMIT IT to inherit the ink the user currently has \
                    selected (see get_tool); pen when no inking tool is selected.

                    THEY DIFFER IN CHARACTER, not only in name, and you cannot see that from a \
                    listing: `monoline` is opaque and uniform — reach for it for solid fills, \
                    flat colour, and anything you layer; `marker` is wide and TRANSLUCENT, so \
                    colours build where strokes overlap and whatever is underneath shows through \
                    (painting a solid area in marker leaves the paper visible between passes); \
                    `pen` tapers with force and is the everyday line; `pencil` is textured and \
                    goes finest, with a minimum width of 1.2 against 2.5 for the others. Below \
                    that minimum a stroke is effectively INVISIBLE, so widths under it are raised \
                    and the reply says so.

                    Note: monoline \
                    persists as pen — PencilKit's archive format does not \
                    preserve it, so a monoline stroke lists back as pen.
                    """,
            ]),
            "smooth": .object([
                "type": "boolean",
                "description": """
                    How to read `points`. DEFAULT false: they are a POLYLINE — straight \
                    segments, sharp corners, which is almost certainly what you mean. Set \
                    true to have them treated as spline knots and smoothly interpolated \
                    (useful for a curve given as a few sparse points) — PKStrokePath \
                    splines THROUGH its control points, so a sparse polyline misread as \
                    knots renders as a rounded teardrop, not the shape you asked for. \
                    Note reshape_strokes defaults the OTHER way. A polyline too \
                    corner-dense to fit the 4000-point canonical budget fails loudly — \
                    send fewer points, or split the shape into several strokes. \
                    smooth: true is NOT the escape from that: it skips the budget (the \
                    verbatim path has no point cap of its own, only the message-size \
                    limit) precisely BECAUSE it does no corner work at all, so every \
                    sharp corner then comes out rounded.
                    """,
            ]),
        ]),
        "required": .array(["points"].map(Value.string)),
    ])

    private static let tools: [Tool] = [
        Tool(
            name: "add_text",
            description: """
                Appends a placed-text entry to a document: a new id, the document's current \
                colour scheme, and an identity transform/opacity. (x, y) is the text box's \
                top-left corner, in canvas coordinates. Give color/fontSize/bold/italic/family \
                to style the WHOLE label, or a `spans` array to style parts of it independently \
                (e.g. a subscript). A whole-field style is the base each span overrides. Styling \
                needs a connected device; plain text does not. Returns the new text's id so you \
                can edit it. Colours: #RRGGBB(AA). Font families come from list_fonts — call it \
                before setting a `family`. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(
                    [
                        "docId": .object(["type": "string", "description": "The document id to modify."]),
                        "text": .object(["type": "string", "description": "The text to place. Omit if using `spans`."]),
                        "x": .object(["type": "number", "description": "Canvas-space x of the text box's top-left corner."]),
                        "y": .object(["type": "number", "description": "Canvas-space y of the text box's top-left corner."]),
                        "pinned": .object([
                            "type": "boolean",
                            "description": "Excludes the text from selection transforms. Defaults to false.",
                        ]),
                        "spans": .object([
                            "type": "array",
                            "description": """
                                Style parts of the text independently instead of a single \
                                `text` string. Each span is {text, color?, fontSize?, bold?, \
                                italic?, family?}; any whole-field color/fontSize/bold/italic/ \
                                family above is the base a span's own value overrides. Supply \
                                `text` OR `spans`, not both. Requires a connected device.
                                """,
                            "items": textSpanItemSchema,
                        ]),
                    ].merging(textStyleProperties) { current, _ in current }
                ),
                "required": .array(["docId", "text", "x", "y"].map(Value.string)),
            ])
        ),
        Tool(
            name: "edit_text",
            description: """
                Mutates an existing placed text by id: replace its string and/or move it, or \
                restyle it with color/fontSize/bold/italic/family (whole-field) or a `spans` \
                array (parts of it independently — a whole-field style is the base each span \
                overrides). WARNING: replacing the text via PLAIN `text` (no style/spans) \
                resets that entry's rich formatting to plain defaults — the attributed run's \
                bold/italic/font/colour attributes are UIKit-archived data no server-side code \
                can synthesize, so a new plain text run always replaces the old ones wholesale. \
                A STYLED edit (any of color/fontSize/bold/italic/family/spans present) restyles \
                the EXISTING characters (or replaces them with `text`/`spans` if given) and \
                needs a connected device — plain edits do not. Position-only edits (x and/or y \
                with no text/style) do not touch formatting. Colours: #RRGGBB(AA). Font \
                families come from list_fonts. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(
                    [
                        "docId": .object(["type": "string", "description": "The document id to modify."]),
                        "textId": .object(["type": "string", "description": "The id of the text entry to edit."]),
                        "text": .object([
                            "type": "string",
                            "description": """
                                Replacement text. Plain (no style/spans), this resets \
                                formatting to plain defaults — see the tool description. \
                                Styled (with color/fontSize/bold/italic/family/spans), it \
                                replaces the characters with the new style instead.
                                """,
                        ]),
                        "x": .object(["type": "number", "description": "New canvas-space x of the text box's top-left corner."]),
                        "y": .object(["type": "number", "description": "New canvas-space y of the text box's top-left corner."]),
                        "spans": .object([
                            "type": "array",
                            "description": """
                                Replace the text with independently-styled parts instead of a \
                                single `text` string. Same shape as add_text's `spans`. \
                                Requires a connected device.
                                """,
                            "items": textSpanItemSchema,
                        ]),
                    ].merging(textStyleProperties) { current, _ in current }
                ),
                "required": .array(["docId", "textId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "tag_elements",
            description: """
                Give an element a durable NAME, so you can find it again later — the stroke you \
                drew for an axis, the text that titles a chart. Names live in the DOCUMENT, so \
                they outlast this task, this session and this agent, which the ids returned by \
                draw_strokes do not.

                THE POINT: with a name you can update your own work in place (find_elements -> \
                reshape_strokes) instead of deleting and redrawing, which is what destroys the \
                user's own annotations and hand-adjusted spacing.

                A name identifies exactly ONE element, so `name` requires exactly one id. \
                Assigning a name that is already taken MOVES it — the previous holder stays on \
                the canvas, unnamed, and the reply says which it was, so you can delete it if \
                this was a replacement. To CLEAR names, pass `name: null` with any number of ids. \
                Names are 1-128 characters; use whatever reads well ("fft.axis.h", "Achse H"). \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "ids": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Element ids (stroke id, text id or image id). Exactly one when setting a name; any number when clearing.",
                    ]),
                    "name": .object([
                        "type": "string",
                        "description": "The name to assign. Omit or pass null to CLEAR the names of the given ids.",
                    ]),
                ]),
                "required": .array(["docId", "ids"].map(Value.string)),
            ])
        ),
        Tool(
            name: "find_elements",
            description: """
                Resolve element NAMES to ids, so you can act on them with any tool that takes \
                ids. Read-only, and cheap: no document payload comes back, just \
                `{name: id}` for the names that resolve.

                A name whose element no longer exists is simply ABSENT from the reply rather \
                than a dangling id — so an empty answer means "that element is gone", not "the \
                lookup failed". Names are set with tag_elements, or at creation time by \
                draw_strokes / add_text / add_image.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to query."]),
                    "names": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "The names to resolve.",
                    ]),
                ]),
                "required": .array(["docId", "names"].map(Value.string)),
            ])
        ),
        Tool(
            name: "transform_elements",
            description: """
                Move, scale or rotate named strokes, texts AND images together — on ANY document, \
                open or not. This is how you reposition a placed image: transform_strokes takes \
                strokes only, and edit_text can move a text but not turn or resize it, so before \
                this an image could be named, pinned, reordered, copied and deleted but never \
                nudged without the document being open and a live selection running.

                Ops are named, never a raw matrix, and mean exactly what they mean on \
                transform_strokes: `scale` then `rotate`, both about `anchor`, then `translate`. \
                `anchor` defaults to the centre of the whole set's bounding box across all three \
                kinds. Identity survives — a stroke keeps its id and its width-edit history, texts \
                and images keep theirs; this is a MOVE, not a copy.

                ATOMIC: every id must resolve or nothing moves, so a set can never end up sheared \
                half-way. Use transform_strokes when you want grid snapping (`snapToGrid` / \
                `snapTo`), which is stroke-lattice specific and stays there. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "strokeIds": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Stroke ids, as returned by list_strokes or draw_strokes.",
                    ]),
                    "textIds": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Placed-text ids, as returned by list_texts.",
                    ]),
                    "imageIds": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Placed-image ids, as returned by list_images.",
                    ]),
                    "translate": .object([
                        "type": "array", "items": .object(["type": "number"]),
                        "description": "[dx, dy] in canvas points.",
                    ]),
                    "scale": .object([
                        "type": "array", "items": .object(["type": "number"]),
                        "description": "[sx, sy] about the anchor; non-zero.",
                    ]),
                    "rotate": .object([
                        "type": "number",
                        "description": "Degrees about the anchor; positive = clockwise on screen.",
                    ]),
                    "anchor": .object([
                        "type": "array", "items": .object(["type": "number"]),
                        "description": "[x, y]. Defaults to the centre of the whole set's bounding box.",
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "undo_last_edit",
            description: """
                Take back YOUR OWN last write to a document — the one you just made and wish you \
                had not. Reaches edits made whether or not the document is open, which the user's \
                own Undo cannot.

                Only YOUR writes are recorded, never the user's own drawing, so this can never \
                reverse their work. One undo = one tool call, the same unit the app registers, and \
                `steps` walks further back one call at a time.

                If the document changed after your write, it is MERGED rather than refused: your \
                change is reversed and everything that happened since is kept. That path needs a \
                connected device; an unchanged document does not. There is no redo — but an undo \
                is itself a write, so undoing it again does the obvious thing. History is bounded \
                and in memory, so a much older edit answers `nothingToUndo`.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to undo an edit in."]),
                    "steps": .object([
                        "type": "integer",
                        "description": "How many of your own edits to take back, newest first. Default 1.",
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_docs",
            description: """
                Every document on the server: `{id, sizeBytes, modifiedAt, hasContent, open}`, \
                newest-modified first. START HERE when you do not already have a docId — every \
                other tool takes one, and this is the tool that tells you what they are.

                `open` means a device has it on screen right now, so your writes land live on the \
                user's canvas; use list_open_docs when you want the device and capability detail \
                as well. `hasContent: false` means the bytes live on a device rather than here — \
                every content tool fetches those for you automatically, or call fetch_doc to pull \
                one explicitly. An empty list means the server holds no documents at all.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "list_open_docs",
            description: """
                What is OPEN right now, and on what. Read-only, no device round trip, no docId \
                needed. Returns `{devices: {count, capabilities}, openDocs: [{docId, seq, \
                subscribers}]}`.

                CALL THIS INSTEAD OF GUESSING A docId FROM CONVERSATION. A document's `docId` is \
                its filename stem captured when the app opened it, so a rename mid-session leaves \
                the name a human says ("grok2 test") different from the live id ("Untitled 16 1 \
                1") until the document is reopened — and every tool aimed at the spoken name \
                fails against a device that is working perfectly. `openDocs` is the truth: those \
                are the ids the selection tools, and every write to an open document, will accept.

                An empty `openDocs` with `devices.count == 0` means no device is connected at all \
                (open the app with the mirror enabled, and check it points at THIS server's port). \
                An empty `openDocs` with a non-zero count means a device is connected but has no \
                document open — ask the user to open one; no amount of retrying will help. \
                `capabilities` is the union of what the connected devices can do, which is what \
                every `noDeviceAvailable` is ultimately about.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
            ])
        ),
        Tool(
            name: "list_fonts",
            description: """
                The font families installed on the connected device, sorted. Call this before \
                setting a `family` on add_text/edit_text — an unknown family is rejected with \
                unknownFont. REQUIRES a connected device — fails with noDeviceAvailable if none \
                is connected and deviceTimeout if it doesn't respond in time. Read-only: it \
                never writes to the document, so there is no seq assigned and nothing to retry.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(["docId": .object(["type": "string", "description": "The document id to query."])]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "remove_text",
            description: "Removes a placed text entry from a document by id. \(writeToolCaveats)",
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
            name: "add_image",
            description: """
                Place an image into a document. `bytes` is a base64-encoded PNG/JPEG/GIF; `x`,`y` are the \
                TOP-LEFT corner of the placement in canvas coordinates. Optional `width`/`height` (canvas \
                points) resize it — omit both for natural pixel size, give one to preserve aspect ratio, both \
                for exact. Optional `opacity` (0..1, default 1). Requires a connected device (the image is \
                decoded there) — noDeviceAvailable otherwise. Returns the new image's id. unknownDoc if the \
                document doesn't exist; invalidSpec if the bytes aren't a decodable image.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "bytes": .object(["type": "string", "description": "Base64-encoded PNG/JPEG/GIF image data."]),
                    "x": .object(["type": "number", "description": "Canvas-space x of the placement's top-left corner."]),
                    "y": .object(["type": "number", "description": "Canvas-space y of the placement's top-left corner."]),
                    "width": .object([
                        "type": "number",
                        "description": "Canvas-point width. Omit both width and height for natural pixel size; give one to preserve aspect ratio.",
                    ]),
                    "height": .object([
                        "type": "number",
                        "description": "Canvas-point height. Omit both width and height for natural pixel size; give one to preserve aspect ratio.",
                    ]),
                    "opacity": .object(["type": "number", "description": "0..1. Defaults to 1."]),
                ]),
                "required": .array(["docId", "bytes", "x", "y"].map(Value.string)),
            ])
        ),
        Tool(
            name: "delete_doc",
            description: """
                Delete a document from the server. The document is moved to the server's \
                .trash directory rather than destroyed, so a mistaken delete is recoverable by \
                hand. Server-side, no device needed. unknownDoc if the document doesn't exist. \
                Note the server keeps NO record of the deletion: a device that still holds the \
                document may re-advertise or re-push it, which brings it back. A device with the \
                document currently open keeps its copy and stops syncing it.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to delete."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "remove_image",
            description: """
                Remove a placed image from a document by its id (as returned by add_image or \
                reported by get_selection). unknownDoc if the document doesn't exist; \
                imageNotFound if no placed image has that id. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "imageId": .object(["type": "string", "description": "The id of the placed image to remove."]),
                ]),
                "required": .array(["docId", "imageId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "set_pinned",
            description: """
                Sets the `pinned` (background) flag on the named placed texts and/or images \
                of a document. `ids` may mix text ids and image ids (as returned by \
                list_texts/list_images/add_text/add_image). A pinned element draws beneath \
                unpinned content and is skipped by rect-select. Server-side, no device needed. \
                Atomic: if any id isn't a text or image in the document it fails with \
                elementNotFound and nothing changes. unknownDoc if the document doesn't exist. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "ids": .object([
                        "type": "array",
                        "description": "Ids of the placed texts/images to (un)pin — a non-empty list.",
                        "items": .object(["type": "string"]),
                    ]),
                    "pinned": .object(["type": "boolean", "description": "true to pin, false to unpin."]),
                ]),
                "required": .array(["docId", "ids", "pinned"].map(Value.string)),
            ])
        ),
        Tool(
            name: "set_paper",
            description: """
                Sets a document's paper appearance: `light` (the paper colour in light \
                mode), `dark` (the paper colour in dark mode), and/or `transparent` (a \
                transparent background). `light`/`dark` are #RRGGBB or #RRGGBBAA hex. At \
                least one field is required. Light and dark are set independently (no \
                automatic light<->dark derivation). Server-side, no device needed; applies \
                live to an open document with no banner. unknownDoc if the document doesn't \
                exist; invalidSpec on a bad hex colour; invalidArguments if no field is given. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "light": .object(["type": "string", "description": "Light-mode paper colour, #RRGGBB or #RRGGBBAA."]),
                    "dark": .object(["type": "string", "description": "Dark-mode paper colour, #RRGGBB or #RRGGBBAA."]),
                    "transparent": .object(["type": "boolean", "description": "Whether the background is transparent."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "replace_doc",
            description: """
                Replaces a document's raw bytes wholesale, creating it if it doesn't yet \
                exist. The bytes are opaque to the server — the agent owns their validity, \
                the same trust any other writer on the network has. \(writeToolCaveats)
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
                InfinitySketch device. Each stroke is a list of (x, y) points in canvas \
                coordinates — the same space as add_text's x/y — plus optional width, color, \
                inkType, and smooth fields. Points are a POLYLINE by default (smooth: false, \
                the default): straight segments and sharp corners, which is almost certainly \
                what you mean. Set smooth: true to have them treated as spline knots and \
                smoothly interpolated instead — useful for a curve given as a few sparse \
                points; PencilKit splines THROUGH its control points, so a sparse polyline \
                misread as knots renders as a rounded blob, not the shape you asked for. \
                (reshape_strokes defaults smooth the OPPOSITE way — verbatim by default.) \
                Other defaults for any stroke that omits them: inkType "pen", width 4, and a \
                colour that FOLLOWS THE PAPER — white on a dark document, black on a light \
                one (never a hardcoded #000000, which renders invisible on dark paper). An \
                explicit color is always honoured exactly as given. The result names the seq \
                the write was assigned, and the id of each stroke it created, in \
                the order supplied — use those, not a bounding-box guess, to revise exactly \
                what you just drew with \
                get_strokes/transform_strokes/restyle_strokes/reshape_strokes/delete_strokes. \
                REQUIRES a connected device — fails with \
                noDeviceAvailable if none is connected, deviceTimeout if it doesn't respond in \
                time, opInProgress if another stroke operation on this document is already in \
                flight, and deviceFailed: <reason> if the device rejects the strokes (e.g. \
                malformed points). \(writeToolCaveats)
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
                seq the write was assigned. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "ids": .object([
                        "type": "array",
                        "description": "The composite stroke ids to delete, as returned by list_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                ]),
                "required": .array(["docId", "ids"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_strokes",
            description: """
                Lists every stroke currently in a document — each with its id \
                (usable with delete_strokes), geometry, and bbox/pathBounds — authored by a \
                connected InfinitySketch device. bbox is the INK box (renderBounds: cap + \
                antialias bleed, so it reads WIDER than what you placed — e.g. pins placed 80 \
                pt apart show a bbox around 86); pathBounds is the box of the stroke's \
                points — what you actually placed. Use pathBounds to verify geometry you \
                positioned.

                `width` is the stroke's own STAMP width and does NOT include any transform it \
                carries, while its coordinates DO — so a stroke that was scaled up reports \
                tripled bounds and an unchanged width, and two strokes both reporting `width: 4` \
                can render three times apart. That matters for exactly one intent: matching a new \
                stroke to an existing one. Call get_strokes for that stroke — it reports the \
                `transform`, and stamp width times its scale is what you see. \
                (This is deliberate: `width` is the same quantity restyle_strokes SETS, so \
                reading one and writing it back is consistent.)

                This tool does not report grids — render_sketch's metadata does, \
                including each grid's id (what snap_points' gridIds and transform_strokes' \
                snapTo refer to). REQUIRES a connected device — fails with \
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
            name: "list_texts",
            description: """
                Lists a document's placed texts, one per text, as \
                {id, text, bounds:[x,y,w,h] (canvas space), pinned, opacity} — authored by a \
                connected InfinitySketch device. REQUIRES a connected device — fails with \
                noDeviceAvailable if none is connected and deviceTimeout if it doesn't \
                respond in time. Returns the device's listing verbatim as text; this call \
                never writes to the document. unknownDoc if the document doesn't exist.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to list placed texts from."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_images",
            description: """
                Lists a document's placed images, one per image, as \
                {id, bounds:[x,y,w,h] (canvas space), pinned, opacity} — authored by a \
                connected InfinitySketch device. REQUIRES a connected device — fails with \
                noDeviceAvailable if none is connected and deviceTimeout if it doesn't \
                respond in time. Returns the device's listing verbatim as text; this call \
                never writes to the document. unknownDoc if the document doesn't exist.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to list placed images from."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_grids",
            description: """
                Lists a document's grids, one per grid, as {id, type, spacing, snap, \
                rotation, offset, pivot, color, thickness, visible, enabled, families} — \
                authored by a connected InfinitySketch device. `type` is one of \
                "grid"/"horizontal"/"vertical"/"isometric"; `color` is "#RRGGBBAA" hex. \
                `visible` (drawn) and `enabled` (snapped-to) are independent — check both. \
                `families` are the derived line families (from GridGeometry), the same \
                vocabulary render_sketch reports, so a grid's id here is what \
                snap_points' gridIds and transform_strokes' snapTo refer to. REQUIRES a \
                connected device — fails with noDeviceAvailable if none is connected and \
                deviceTimeout if it doesn't respond in time. Returns the device's listing \
                verbatim as text; this call never writes to the document. unknownDoc if the \
                document doesn't exist.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to list grids from."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "add_grid",
            description: """
                Adds a new grid to a document, authored by a connected InfinitySketch \
                device. Every field is optional and defaults to the app's own new-grid \
                defaults (spacing 20, snap 1, type "grid", color a translucent blue, \
                thickness 1, rotation 0, offset [0, 0]) EXCEPT `visible` and `enabled`, \
                which default to true — a grid an agent adds is usable immediately, unlike \
                the app's own hidden-by-default "Add Grid" affordance which the user then \
                configures. `snap` is a MULTIPLIER of `spacing`, not a distance — real snap \
                distance is spacing × snap. Returns the new grid's id. Requires a connected \
                device — fails with noDeviceAvailable if none is connected and deviceTimeout \
                if it doesn't respond in time. unknownDoc if the document doesn't exist; \
                invalidSpec if `color` isn't valid hex or `type` isn't one of the four \
                recognized strings. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "type": .object([
                        "type": "string",
                        "enum": .array(["grid", "horizontal", "vertical", "isometric"].map(Value.string)),
                        "description": "The grid's lattice type. Defaults to \"grid\".",
                    ]),
                    "spacing": .object(["type": "number", "description": "Line spacing in canvas points. Defaults to 20."]),
                    "snap": .object([
                        "type": "number",
                        "description": "A MULTIPLIER of spacing, not a distance — real snap distance is spacing × snap. Defaults to 1.",
                    ]),
                    "rotation": .object(["type": "number", "description": "Rotation in degrees. Defaults to 0."]),
                    "color": .object(["type": "string", "description": "\"#RRGGBBAA\" or \"#RRGGBB\" hex. Defaults to a translucent blue."]),
                    "thickness": .object(["type": "number", "description": "Line thickness. Defaults to 1."]),
                    "visible": .object(["type": "boolean", "description": "Whether the grid is drawn. Defaults to true."]),
                    "enabled": .object(["type": "boolean", "description": "Whether strokes snap to the grid. Defaults to true."]),
                    "offset": .object([
                        "type": "array",
                        "description": "The lattice phase [x, y]. Defaults to [0, 0].",
                        "items": .object(["type": "number"]),
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "update_grid",
            description: """
                Modifies an existing grid's supplied fields only (present-only), authored \
                by a connected InfinitySketch device. Same field vocabulary as add_grid. If \
                the grid has a pivot (set via set_grid_origin or the app's tap-to-pick-origin) \
                and `type`/`spacing`/`rotation` changes, the offset is automatically \
                re-reduced so the lattice keeps passing through that pivot. Requires a \
                connected device — fails with noDeviceAvailable if none is connected and \
                deviceTimeout if it doesn't respond in time. gridNotFound if no grid has \
                that id; unknownDoc if the document doesn't exist; invalidSpec if `color`/ \
                `type` aren't recognized. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "id": .object(["type": "string", "description": "The id of the grid to modify, as returned by add_grid/list_grids."]),
                    "type": .object([
                        "type": "string",
                        "enum": .array(["grid", "horizontal", "vertical", "isometric"].map(Value.string)),
                        "description": "The grid's lattice type.",
                    ]),
                    "spacing": .object(["type": "number", "description": "Line spacing in canvas points."]),
                    "snap": .object([
                        "type": "number",
                        "description": "A MULTIPLIER of spacing, not a distance — real snap distance is spacing × snap.",
                    ]),
                    "rotation": .object(["type": "number", "description": "Rotation in degrees."]),
                    "color": .object(["type": "string", "description": "\"#RRGGBBAA\" or \"#RRGGBB\" hex."]),
                    "thickness": .object(["type": "number", "description": "Line thickness."]),
                    "visible": .object(["type": "boolean", "description": "Whether the grid is drawn."]),
                    "enabled": .object(["type": "boolean", "description": "Whether strokes snap to the grid."]),
                    "offset": .object([
                        "type": "array",
                        "description": "The lattice phase [x, y].",
                        "items": .object(["type": "number"]),
                    ]),
                ]),
                "required": .array(["docId", "id"].map(Value.string)),
            ])
        ),
        Tool(
            name: "remove_grid",
            description: """
                Removes a grid from a document by its id, authored by a connected \
                InfinitySketch device. The grid array may legitimately reach zero, as in the \
                app. gridNotFound if no grid has that id; unknownDoc if the document doesn't \
                exist. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "id": .object(["type": "string", "description": "The id of the grid to remove, as returned by add_grid/list_grids."]),
                ]),
                "required": .array(["docId", "id"].map(Value.string)),
            ])
        ),
        Tool(
            name: "reorder_grids",
            description: """
                Sets the draw order (z-order) of a document's grids, authored by a connected \
                InfinitySketch device. `orderedIds` must be a full permutation of the \
                document's current grid ids (as returned by list_grids) — the grids draw, and \
                list_grids reports them, in this sequence. Requires a connected device — fails \
                with noDeviceAvailable if none is connected and deviceTimeout if it doesn't \
                respond in time. unknownDoc if the document doesn't exist; gridNotFound/ \
                invalidSpec if orderedIds isn't a valid permutation of the document's grid ids. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "orderedIds": .object([
                        "type": "array",
                        "description": "The grid ids (as returned by list_grids/add_grid), in the desired draw order — a full permutation of the document's current grid ids.",
                        "items": .object(["type": "string"]),
                    ]),
                ]),
                "required": .array(["docId", "orderedIds"].map(Value.string)),
            ])
        ),
        Tool(
            name: "set_grid_origin",
            description: """
                Sets a grid's pivot to an EXACT canvas coordinate — the programmatic \
                equivalent of the app's tap-to-pick-origin gesture — so the lattice passes \
                through (x, y): the offset is recomputed so the grid stays anchored there. \
                No snap — use snap_points first if you want a lattice point. Authored by a \
                connected InfinitySketch device. gridNotFound if no grid has that id; \
                unknownDoc if the document doesn't exist. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "id": .object(["type": "string", "description": "The id of the grid to set the origin of, as returned by add_grid/list_grids."]),
                    "x": .object(["type": "number", "description": "Canvas-space x the lattice should pass through."]),
                    "y": .object(["type": "number", "description": "Canvas-space y the lattice should pass through."]),
                ]),
                "required": .array(["docId", "id", "x", "y"].map(Value.string)),
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
                appearance, the canvas contentSize, and — per grid — its id, thickness, \
                and each drawn/snap line family's id, lineAngleDeg and label. These grid \
                and family ids are what snap_points' gridIds and transform_strokes' \
                snapTo refer to. READ lineAngleDeg for a family's line direction, never \
                infer it from `normal` — normal is PERPENDICULAR to the lines it \
                describes ([1, 0] means VERTICAL lines, not horizontal). Only visible \
                grids appear in the rendered image, but visible and enabled are \
                independent — a grid can be snapped to without being drawable, or drawn \
                without being snapped to; both flags are reported for every grid, so \
                check `enabled` for whether a grid you can't see is still pulling \
                strokes onto it. To ZOOM IN, shrink the rect: the scale rises to fill \
                the pixel budget, up to 16x. (A 60x50pt rect comes back 960x800, not \
                120x100.) The scale actually used is always reported in the metadata. \
                An empty document (nothing to auto-fit, no explicit rect) now renders \
                at the document's saved viewport instead of failing — only an explicit \
                include: "none" with no ephemeral strokes still fails with \
                deviceFailed: emptyRender (there is deliberately nothing to show). \
                REQUIRES a connected device — fails with noDeviceAvailable if none is \
                connected, deviceTimeout if it doesn't respond in time, and \
                deviceFailed: <reason> for a bad spec (e.g. an unknown strokeKey). \
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
                            by strokeIds — no images or texts. "none": nothing from \
                            the document.
                            """,
                    ]),
                    "strokeIds": .object([
                        "type": "array",
                        "description": """
                            With include: "strokes", the stroke ids (as returned by \
                            list_strokes) to show.
                            """,
                        "items": .object(["type": "string"]),
                    ]),
                    "strokes": .object([
                        "type": "array",
                        "description": """
                            EPHEMERAL candidate strokes to render — the exact stroke \
                            shape draw_strokes takes. Synthesized through the same code \
                            a commit would use, so the preview has the same geometry and \
                            style draw_strokes would commit, but nothing here is ever \
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
                stroke's width, colour, inkType, transform, bbox and pathBounds. Point \
                x/y are CANVAS coordinates — the stroke's transform is ALREADY applied \
                to them, so they are the coordinates you see in render_sketch and the \
                ones transform_strokes moves in; the returned transform array is \
                informational, never something you apply yourself. bbox is the INK box \
                (it includes cap and antialias bleed, so it reads wider than what you \
                placed); pathBounds is the box of the stroke's points — use pathBounds \
                to verify geometry you positioned. width is the stroke's peak stamp \
                width — the quantity restyle_strokes' width sets — and is NOT scaled by \
                the transform, so a scaled stroke renders proportionally wider than its \
                width says (bbox and render_sketch show its true extent). Field names \
                are symmetric with draw_strokes/reshape_strokes, so a fetch → alter → \
                put-back needs no translation and loses nothing: handing the points \
                straight back to reshape_strokes (whose smooth defaults to true — \
                verbatim) changes nothing at all. Nothing is capped or \
                decimated by the server — use list_strokes' pointCount to price a \
                fetch first, and maxPoints if you want a guard of your own; a request \
                over that guard fails with pointBudgetExceeded(<actual>), naming the \
                real total. Note: monoline persists as pen — PencilKit's archive \
                format does not preserve it, so a monoline stroke lists back as pen. \
                This tool does not report grids — render_sketch's metadata does, \
                including each grid's id (what snap_points' gridIds and \
                transform_strokes' snapTo refer to). Read-only.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to read strokes from."]),
                    "ids": .object([
                        "type": "array",
                        "description": "Composite stroke ids, as returned by list_strokes or draw_strokes.",
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
                "required": .array(["docId", "ids"].map(Value.string)),
            ])
        ),
        Tool(
            name: "snap_points",
            description: """
                Where could these points snap to? Returns CANDIDATES — it never moves \
                anything, and it never decides for you. Each candidate is either a LINE \
                (one grid family: it constrains ONE direction, so a horizontal wire can \
                snap its y and keep its x) or an INTERSECTION of two non-parallel \
                families, which MAY come from two DIFFERENT grids — the 20pt grid's \
                vertical crossing the 5pt grid's horizontal is a real point. Every \
                candidate names its parent grid(s): gridId, familyId, label, \
                lineAngleDeg, spacing, snapSpacing, visible, enabled, thickness, color \
                — use gridId/familyId with transform_strokes' snapTo once you've picked \
                one.

                THE LIST IS ORDERED BY DISTANCE, AND DISTANCE IS NOT A RECOMMENDATION. \
                Measured on the factory document, for a point near (103, 92) the top \
                THREE candidates are the invisible, DISABLED 1pt grid's — at distance \
                0.2 ("snap to where you already are") — and the candidate an agent \
                actually wants, the VISIBLE 20×20 intersection at (100, 100), is LAST, \
                at distance 8.43. Grabbing candidates[0] lands a schematic between the \
                lines a human can see — that is exactly what happened to a real agent. \
                For LAYOUT, prefer candidates whose parents are `visible`; the finest \
                enabled grid is usually invisible.

                maxCandidates (default 64) is a SAFETY VALVE, not a working parameter: \
                truncation drops the FARTHEST candidates, which are usually the coarse \
                VISIBLE ones you want — lowering it can silently delete the answer you \
                need. REQUIRES a connected device — fails with noDeviceAvailable if none \
                is connected and deviceTimeout if it doesn't respond in time. Read-only: \
                no write, no seq bump.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to query."]),
                    "points": .object([
                        "type": "array",
                        "description": "Canvas-space [x, y] points to find snap candidates for.",
                        "items": .object([
                            "type": "array",
                            "items": .object(["type": "number"]),
                            "minItems": 2, "maxItems": 2,
                        ]),
                    ]),
                    "gridIds": .object([
                        "type": "array",
                        "description": """
                            Consider only these grids (ids from render_sketch's metadata). \
                            Default: all of them, including invisible and disabled ones.
                            """,
                        "items": .object(["type": "integer"]),
                    ]),
                    "maxCandidates": .object([
                        "type": "integer",
                        "description": "Per point; default 64. The cap drops the FARTHEST candidates.",
                    ]),
                ]),
                "required": .array(["docId", "points"].map(Value.string)),
            ])
        ),
        Tool(
            name: "transform_strokes",
            description: """
                Moves, scales and/or rotates strokes in place. The strokes keep their \
                identity (ids), their points and their z-order — only their placement \
                changes. translate and anchor are CANVAS coordinates: the same space \
                get_strokes' points, list_strokes' bbox and render_sketch are quoted \
                in. Scale and rotate act about anchor, which defaults to the \
                centre of the ids' union bounding box. TO SNAP, pass snapToGrid: true, \
                or snapTo, or both — EITHER ONE alone means "snap" (naming a target IS \
                asking to snap), and the whole SET is then shifted rigidly (never \
                additionally scaled or rotated) so the anchor lands on a lattice point. \
                WITHOUT snapTo, that lattice is the nearest line across ALL of the \
                document's ENABLED grids — so the FINEST enabled grid wins, and that grid \
                is usually INVISIBLE (see render_sketch's metadata for every grid's \
                visible/enabled flags and lattice); this stays the default because it's \
                the app's own pen behaviour, but it is easy to land a schematic between \
                the lines a human can see. Use snap_points first to see what's actually \
                near your anchor, then pass snapTo to name the grid (and optionally which \
                of its line families — one family constrains a single direction, e.g. a \
                wire's y while its x stays put) you actually mean; with no enabled grid \
                (and no snapTo), snapToGrid is a no-op. A snap alone, with no translate/ \
                scale/rotate, is a legal request. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "ids": .object([
                        "type": "array",
                        "description": "Composite stroke ids, as returned by list_strokes or draw_strokes.",
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
                        "description": "[x, y]. Defaults to the centre of the ids' union bounding box.",
                        "items": .object(["type": "number"]),
                        "minItems": 2, "maxItems": 2,
                    ]),
                    "snapToGrid": .object([
                        "type": "boolean",
                        "description": """
                            Land the anchor on the nearest lattice point, shifting the whole \
                            set by that one delta. Without snapTo the lattice is ALL of the \
                            document's ENABLED grids (the finest, usually invisible, one wins); \
                            no enabled grid = no-op. NOT required when you pass snapTo — a \
                            snapTo alone already snaps.
                            """,
                    ]),
                    "snapTo": .object([
                        "type": "object",
                        "description": """
                            Which grid to snap to — AND, on its own, a request TO snap: \
                            snapToGrid need not also be set (passing snapTo without it snaps \
                            to this target; it is not ignored). WITHOUT snapTo, snapToGrid \
                            takes the nearest line across ALL enabled grids — so the FINEST \
                            grid wins, and that grid is usually INVISIBLE, which will pull \
                            your drawing between the lines a human sees. Name a grid (ids from \
                            render_sketch's metadata, or snap_points' candidate parents), and \
                            optionally only some of its families, to snap to what you mean.
                            """,
                        "properties": .object([
                            "gridId": .object(["type": "integer"]),
                            "familyIds": .object([
                                "type": "array",
                                "description": """
                                    Snap only against these families of that grid (a single \
                                    family constrains one direction). Default: all of them.
                                    """,
                                "items": .object(["type": "integer"]),
                            ]),
                        ]),
                        "required": .array(["gridId"].map(Value.string)),
                    ]),
                ]),
                "required": .array(["docId", "ids"].map(Value.string)),
            ])
        ),
        Tool(
            name: "restyle_strokes",
            description: """
                Changes strokes' colour, width and/or ink in place; identity and \
                geometry survive. At least one of color, width, or inkType must be \
                supplied — omitting all three is rejected. width is the TARGET PEAK \
                stroke width — the same quantity get_strokes/list_strokes report, not a tool-slider value — \
                and is CLAMPED to what the target ink can express (pen tops out around \
                peak 6; marker cannot render below roughly 7.5), so a thin pen stroke \
                necessarily gets thicker when restyled to marker; get_strokes reports \
                the actual resulting peak. An ink-only restyle (no width) preserves the \
                stroke's apparent thickness. A colour-only restyle changes nothing \
                else. One user-visible cost, worth knowing before you restyle a stroke \
                the user has never width-edited: the app can afterwards restore that \
                stroke's original width only APPROXIMATELY, because the tool-slider \
                value the user drew with is not recorded anywhere and cannot be \
                recovered from the stroke (a colour-only restyle, and any stroke the \
                user HAS width-edited, are unaffected). Note: monoline persists as pen \
                — PencilKit's archive format does not preserve it. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "ids": .object([
                        "type": "array",
                        "description": "Composite stroke ids, as returned by list_strokes or draw_strokes.",
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
                "required": .array(["docId", "ids"].map(Value.string)),
            ])
        ),
        Tool(
            name: "reshape_strokes",
            description: """
                Replaces strokes' geometry in place, keeping their identity (id), \
                ink, z-order and width-edit history. Points are CANVAS coordinates — \
                the same space get_strokes returns and render_sketch shows — so you \
                straighten a stroke by naming the canvas coordinates you can SEE, and \
                it lands exactly there: the stroke's transform is preserved and \
                accounted for on your behalf (never re-applied on top of your points). \
                Handing back the exact points get_strokes gave you changes nothing. \
                Points are used VERBATIM by default (smooth: true — the OPPOSITE of \
                draw_strokes' default), because a reshape may be handing back a stroke \
                a HUMAN drew, and re-sampling it would flatten their curve. Pass \
                smooth: false to read them as a polyline with sharp corners instead. \
                Attributes you OMIT on a point are resampled from the ORIGINAL stroke \
                along the new path — so straightening a wobbly line with plain [x, y] \
                pairs keeps its pressure taper. Supply attributes explicitly to \
                override that. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "strokes": .object([
                        "type": "array",
                        "description": "One or more strokes to reshape by id.",
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "id": .object([
                                    "type": "string",
                                    "description": "The id of the stroke to reshape.",
                                ]),
                                "points": .object([
                                    "type": "array",
                                    "description": """
                                        The new polyline; at least 2 points. Each point is \
                                        either an [x, y] pair or a rich point object.
                                        """,
                                    "items": pointSchema,
                                ]),
                                "smooth": .object([
                                    "type": "boolean",
                                    "description": """
                                        DEFAULT true here (the OPPOSITE of draw_strokes): the \
                                        points are used verbatim, because a reshape may be \
                                        round-tripping a stroke a HUMAN drew and \
                                        canonicalizing it would sharpen turns they drew round \
                                        (and break the exact get_strokes round-trip). Pass \
                                        false to read them as a polyline with sharp corners — \
                                        that path canonicalizes, and fails loudly if the \
                                        polyline is too corner-dense for the 4000-point \
                                        budget. Dropping back to the verbatim default is not \
                                        an equivalent escape from that failure: verbatim has \
                                        no point budget only because it does no corner work, \
                                        so the corners render rounded.
                                        """,
                                ]),
                            ]),
                            "required": .array(["id", "points"].map(Value.string)),
                        ]),
                    ]),
                ]),
                "required": .array(["docId", "strokes"].map(Value.string)),
            ])
        ),
        Tool(
            name: "get_selection",
            description: """
                Read the user's CURRENT live rect-select selection on a connected device: which \
                strokes/texts/images are selected (by id), the reference point they placed, the \
                selection bounds, and an opaque `signature` to pass back as transform_selection's \
                `expect`. REQUIRES a connected device with an active selection.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "transform_selection",
            description: """
                Transform the user's live selection exactly as a manual rect-select transform would \
                (one undoable step). `ops` is a list of 1 to 16 operations, composed left-to-right \
                into one undo step (single fixed reference point): rotate \
                {op:"rotate",degrees} (+ = clockwise, relative), scale {op:"scale",factor} (uniform), \
                translate {op:"translate",dx,dy} (canvas points, no reference point), flipHorizontal / \
                flipVertical. rotate/scale/flip pivot on the reference point the USER placed — if none \
                is set the op fails (noReferencePoint); placing it yourself is not supported yet. Pass \
                `expect` = a prior get_selection's `signature` to be rejected if the user changed the \
                selection since (selectionChanged). REQUIRES a connected device with an active \
                selection.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                    "ops": .object([
                        "type": "array",
                        "description": "1 to 16 operations, composed left-to-right into one undo step.",
                        // Typed, not a bare `object`: an agent reading the schema could not tell
                        // what an op looked like, so the shapes lived only in the prose above and
                        // the natural guess was transform_strokes' flat fields, which is a
                        // different vocabulary for the same idea (2026-07-28 finding 7).
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "op": .object([
                                    "type": "string",
                                    "enum": .array(["rotate", "scale", "translate", "flipHorizontal", "flipVertical"].map(Value.string)),
                                    "description": "Which operation this entry is.",
                                ]),
                                "degrees": .object(["type": "number", "description": "rotate: degrees about the reference point; positive = clockwise."]),
                                "factor": .object(["type": "number", "description": "scale: uniform factor about the reference point."]),
                                "dx": .object(["type": "number", "description": "translate: canvas points along x."]),
                                "dy": .object(["type": "number", "description": "translate: canvas points along y."]),
                            ]),
                            "required": .array([Value.string("op")]),
                        ]),
                    ]),
                    "expect": .object(["type": "string", "description": "signature from get_selection."]),
                ]),
                "required": .array(["docId", "ops"].map(Value.string)),
            ])
        ),
        Tool(
            name: "select_all",
            description: """
                Select every stroke, placed text, and placed image in the document on a connected \
                device's live rect-select, replacing any existing selection — the agent equivalent \
                of the user's Select All. REQUIRES a connected `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "get_tool",
            description: """
                Report the tool picker's CURRENT tool on the connected device — `isInkingTool`, \
                and when true `inkType`, `width`, `toolWidth`, `peakWidth` and `color` \
                (#RRGGBBAA). READ THIS BEFORE DRAWING and pass the values explicitly to \
                draw_strokes / draw_selection / render_sketch, so strokes you author match the \
                pen the user is holding unless they asked for something else. The values are \
                never applied implicitly: you hold them, so a preview and its commit are the same \
                numbers even if the user switches tools in between. `isInkingTool` is false for \
                the eraser, lasso, or Bring to Front — nothing sensible to inherit, so use your \
                own values.

                TWO WIDTHS, and they are DIFFERENT NUMBERS. `peakWidth` is what the pen actually \
                lays down — the same quantity list_strokes / get_strokes report and \
                draw_* / restyle_* accept — and `width` is an alias of it, so copying `width` \
                straight into a draw call is correct. `toolWidth` is the picker DIAL, reported \
                for completeness (it is the unit stroke anchors record); do NOT pass it to \
                draw_*. They coincide only for marker: monoline draws `dial + 2`, and pen and \
                pencil follow a non-linear curve, so a dial of 2 on monoline draws a 4. Omitting \
                width entirely inherits `peakWidth` for you. Needs no selection. \
                REQUIRES a connected `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "Any open document id on the device."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "draw_selection",
            description: """
                Draw strokes into the user's LIVE rect-select selection AND select them, in one \
                step. `strokes` takes the same shape as draw_strokes. Composing draw_strokes + \
                select_elements does the same thing but leaves a window where the stroke exists \
                unselected; this is atomic. By default the user's selection rectangle is KEPT (you \
                are drawing INTO it) — pass `keepRect: false` to shrink it to the new strokes. \
                Requires an ACTIVE selection: noSelectionActive otherwise, userBusy mid-gesture. \
                REQUIRES a connected `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                    "strokes": .object([
                        "type": "array",
                        "description": "Strokes to draw; same item shape as draw_strokes.",
                        "items": .object(["type": "object"]),
                    ]),
                    "keepRect": .object([
                        "type": "boolean",
                        "description": "Keep the user's selection rectangle. Defaults to true.",
                    ]),
                ]),
                "required": .array(["docId", "strokes"].map(Value.string)),
            ])
        ),
        Tool(
            name: "restyle_selection",
            description: """
                Restyle the strokes in the user's LIVE rect-select selection — `color` \
                (#RRGGBB/#RRGGBBAA), `width` (target peak stroke width), and/or `inkType` \
                (pen/pencil/marker/monoline). At least one is required; an omitted field is left \
                alone. Unlike restyle_strokes (which edits document bytes and cannot refresh the \
                canvas while a selection is open) this drives the app's own reink path, so the \
                change appears immediately and lands as one undo step. noSelectionActive if \
                nothing is selected; userBusy mid-gesture. REQUIRES a connected \
                `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                    "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA."]),
                    "width": .object(["type": "number", "description": "Target peak stroke width."]),
                    "inkType": .object([
                        "type": "string",
                        "description": "pen, pencil, marker, or monoline.",
                        "enum": .array(["pen", "pencil", "marker", "monoline"].map(Value.string)),
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "delete_selection",
            description: """
                Delete everything in the user's LIVE rect-select selection, exactly as the \
                toolbar's Delete does — one undo step, canvas refreshed immediately. \
                noSelectionActive if nothing is selected; userBusy mid-gesture. REQUIRES a \
                connected `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "select_elements",
            description: """
                Select specific elements by id on a connected device's live rect-select, replacing \
                any existing selection. Pass `strokeIds` (stroke ids, from \
                `list_strokes`/`get_strokes`), `textIds`, and/or `imageIds` (text/image ids, from \
                `get_selection` or the document summary) — at least one id across the three arrays \
                is required (enforced device-side). By default the selection rectangle is resized \
                to hug the chosen elements; pass `keepRect: true` to leave the user's own marquee \
                exactly where they dragged it. REQUIRES a connected `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                    "strokeIds": .object([
                        "type": "array",
                        "description": "Stroke ids to select.",
                        "items": .object(["type": "string"]),
                    ]),
                    "textIds": .object([
                        "type": "array",
                        "description": "Placed-text ids to select.",
                        "items": .object(["type": "string"]),
                    ]),
                    "imageIds": .object([
                        "type": "array",
                        "description": "Placed-image ids to select.",
                        "items": .object(["type": "string"]),
                    ]),
                    "keepRect": .object([
                        "type": "boolean",
                        "description": "Keep the existing selection rectangle instead of resizing it to the chosen elements. Defaults to false.",
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "set_reference_point",
            description: """
                Place the reference point the user's live selection pivots/rotates/scales around, \
                at the given CANVAS coordinates — the same point a manual rect-select drag drops. \
                This does NOT snap to the grid; call `snap_points` first and pass one of its \
                candidates if you want a lattice point. REQUIRES a connected `controlSelection` \
                device with an active selection.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                    "x": .object(["type": "number", "description": "Canvas-space x. Not snapped."]),
                    "y": .object(["type": "number", "description": "Canvas-space y. Not snapped."]),
                ]),
                "required": .array(["docId", "x", "y"].map(Value.string)),
            ])
        ),
        Tool(
            name: "clear_selection",
            description: """
                Clear the user's live rect-select selection on a connected device, returning it to \
                idle — the agent equivalent of tapping outside the selection or hitting Escape. \
                REQUIRES a connected `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "preview_selection",
            description: """
                Preview a proposed transform of the user's live selection WITHOUT committing \
                anything — the agent's scratchpad for a selection edit, the same role \
                render_sketch's ephemeral strokes play for stroke authoring: synthesize → \
                render → refine → only then commit via transform_selection. `ops` is 1 to 16 \
                operations, composed left-to-right into one undo step (single fixed reference \
                point), the same shape as transform_selection: rotate \
                {op:"rotate",degrees} (+ = clockwise, relative), scale {op:"scale",factor} \
                (uniform), translate {op:"translate",dx,dy}, flipHorizontal / flipVertical — \
                pivoting on the reference point the USER placed (noReferencePoint if none is \
                set). Returns a PNG plus metadata: canvas-space bounds for each transformed \
                selected element (and, with includePoints, each stroke's transformed points), \
                the overall selection bounds/referencePoint, and — per grid — the same line \
                families render_sketch reports, so you can align the proposed transform before \
                committing it. `include`: "withContext" (default) renders the grid and the \
                rest of the document's content behind the moved selection; "selectionOnly" \
                renders just the transformed selection, transparent background, no grid pixels \
                (grid metadata is still reported). `rect` bounds the render like \
                render_sketch's; omit for auto-fit. Nothing here is ever written to the \
                document or the live selection. REQUIRES a connected `controlSelection` device \
                with an active selection.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                    "ops": .object([
                        "type": "array",
                        "description": """
                            1 to 16 operations, composed left-to-right into one undo step \
                            (single fixed reference point), same shape as transform_selection's ops.
                            """,
                        "items": .object(["type": "object"]),
                    ]),
                    "duplicate": .object([
                        "type": "boolean",
                        "description": """
                            Preview a stamp: render the originals plus a transformed copy together \
                            (requires ops).
                            """,
                    ]),
                    "include": .object([
                        "type": "string",
                        "enum": .array(["withContext", "selectionOnly"].map(Value.string)),
                        "description": """
                            "withContext" (default): the grid plus the rest of the document's \
                            content behind the moved selection. "selectionOnly": just the \
                            transformed selection, transparent background, no grid pixels (grid \
                            metadata is still reported).
                            """,
                    ]),
                    "rect": .object([
                        "type": "array",
                        "description": """
                            [x, y, w, h] in canvas coordinates. Omit for auto-fit.
                            """,
                        "items": .object(["type": "number"]),
                        "minItems": 4,
                        "maxItems": 4,
                    ]),
                    "includePoints": .object([
                        "type": "boolean",
                        "description": """
                            Include each transformed stroke's canvas-space points alongside its \
                            bounds. Defaults to false.
                            """,
                    ]),
                ]),
                "required": .array(["docId", "ops"].map(Value.string)),
            ])
        ),
        Tool(
            name: "duplicate_selection",
            description: """
                Duplicate the user's live selection on a connected device. With no `ops`: a \
                provisional copy in place — like the toolbar's duplicate, it commits on a later \
                edit and is deleted on a later deselect. With `ops` (1 to 16, same shape as \
                transform_selection's, composed left-to-right around the single reference \
                point): clone + transform as one "stamp" undo step. Returns the new elements' \
                keys/ids. Pass `expect` = a prior get_selection's `signature` to be rejected if \
                the user changed the selection since (selectionChanged). REQUIRES a connected \
                `controlSelection` device with an active selection.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id."]),
                    "ops": .object([
                        "type": "array",
                        "description": """
                            1 to 16 operations, composed left-to-right into one undo step \
                            (single fixed reference point), same shape as transform_selection's \
                            ops. Omit for a provisional in-place copy.
                            """,
                        "items": .object(["type": "object"]),
                    ]),
                    "expect": .object(["type": "string", "description": "signature from get_selection."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "merge_docs",
            description: """
                Merges document `source` INTO document `target` by element identity (strokes \
                by their composite key, texts/images by id): every element of both docs \
                survives, shared elements dedupe, and a same-key clash is broken by `prefer` \
                (default "target"). `target` becomes the union; `source` is left untouched. \
                With `into`, the union is written to a new document and both inputs are left \
                untouched (docExists if `into` is taken). \
                REQUIRES a connected device with the mergeDocs capability — fails with \
                noDeviceAvailable if none is connected, sourceNotFound / targetNotFound if \
                either document is absent, and deviceFailed: <reason> if the device rejects \
                the merge. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "source": .object(["type": "string", "description": "The document to merge FROM (left unchanged)."]),
                    "target": .object(["type": "string", "description": "The document to merge INTO (becomes the union)."]),
                    "prefer": .object([
                        "type": "string",
                        "enum": .array(["source", "target"].map(Value.string)),
                        "description": "Which side wins a same-key clash. Default target.",
                    ]),
                    "into": .object([
                        "type": "string",
                        "description": "Optional: write the union to a NEW document with this id, leaving both source and target untouched. docExists if the name is already taken.",
                    ]),
                ]),
                "required": .array(["source", "target"].map(Value.string)),
            ])
        ),
        Tool(
            name: "copy_elements",
            description: """
                Copies named strokes/texts/images from document `source` INTO document \
                `target`, as FRESH clones (fresh ids) — unlike \
                merge_docs, elements are never deduped by identity, so copying the same \
                source element twice yields two distinct clones. `source` is left \
                untouched; `target` gains the copies. At least one of `strokeIds`/ \
                `textIds`/`imageIds` is required. \
                REQUIRES a connected device with the copyElements capability — fails with \
                noDeviceAvailable if none is connected, sourceNotFound / targetNotFound if \
                either document is absent, and deviceFailed: elementNotFound if an id \
                isn't found in `source`. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "source": .object(["type": "string", "description": "The document to copy FROM (left unchanged)."]),
                    "target": .object(["type": "string", "description": "The document to copy INTO (gains the clones)."]),
                    "strokeIds": .object([
                        "type": "array",
                        "description": "Stroke ids to clone, from list_strokes/get_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                    "textIds": .object([
                        "type": "array",
                        "description": "Placed-text ids to clone, from list_texts.",
                        "items": .object(["type": "string"]),
                    ]),
                    "imageIds": .object([
                        "type": "array",
                        "description": "Placed-image ids to clone, from list_images.",
                        "items": .object(["type": "string"]),
                    ]),
                ]),
                "required": .array(["source", "target"].map(Value.string)),
            ])
        ),
        Tool(
            name: "reorder_elements",
            description: """
                Sets the z-order (draw order) of named strokes/texts/images within ONE \
                document — bring-to-front or send-to-back, authored by a connected \
                InfinitySketch device. At least one of `strokeIds`/`textIds`/`imageIds` \
                is required. `mode` selects the direction: "front" moves the named \
                elements to the top of the draw order, "back" to the bottom — each \
                WITHIN its own element type's stacking, mirroring the app's \
                Bring-to-Front/Send-to-Back tool. The cross-type order is FIXED (images \
                below strokes below texts), so a stroke brought to front is still drawn \
                below every text; use this only to reorder among same-type elements. For \
                images, pinned (background) images always draw behind unpinned ones \
                regardless of this order — change that band with set_pinned. \
                REQUIRES a connected device with the reorderElements capability — fails \
                with noDeviceAvailable if none is connected, deviceTimeout if it doesn't \
                respond in time, unknownDoc if the document doesn't exist, and \
                deviceFailed: <reason> (e.g. elementNotFound) for an unknown id. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to modify."]),
                    "strokeIds": .object([
                        "type": "array",
                        "description": "Stroke ids to reorder, from list_strokes/get_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                    "textIds": .object([
                        "type": "array",
                        "description": "Placed-text ids to reorder, from list_texts.",
                        "items": .object(["type": "string"]),
                    ]),
                    "imageIds": .object([
                        "type": "array",
                        "description": "Placed-image ids to reorder, from list_images.",
                        "items": .object(["type": "string"]),
                    ]),
                    "mode": .object([
                        "type": "string",
                        "enum": .array(["front", "back"].map(Value.string)),
                        "description": "\"front\" moves the named elements to the top of the draw order, \"back\" to the bottom — within each element type.",
                    ]),
                ]),
                "required": .array(["docId", "mode"].map(Value.string)),
            ])
        ),
        Tool(
            name: "fetch_doc",
            description: """
                Ensures a document's content is available on the server, pulling it from a device \
                that holds it if the server has only its metadata (a "content on another device" \
                doc — see the hasContent hint in the resource list). Read-only: it promotes the \
                document to server content but authors nothing. Call it before other tools if you \
                want to control when the (possibly multi-second) transfer happens; otherwise the \
                content tools fetch on demand themselves. Errors: contentUnavailable (the holding \
                device isn't online), unknownDoc.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document id to fetch."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])),
    ]

    private func handleListTools() async throws -> ListTools.Result {
        ListTools.Result(tools: Self.tools)
    }

    /// Every tool call, with one post-processing step: an error that names only a SYMPTOM gets
    /// the context that makes it actionable (`enrichedError`).
    private func handleCallTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        await enrichedError(try await dispatchCallTool(name: name, arguments: arguments),
                            arguments: arguments)
    }

    /// Turn a dead-end error into a self-correcting one.
    ///
    /// The failure this exists for: a document renamed while open keeps the mirror `docId` it was
    /// registered under (the filename stem at `beginMirroring`), so an agent aiming at the name
    /// the user now sees misses the live session and is told `noSelectionActive` — with no way to
    /// learn that `grok2 test` and `Untitled 16 1 1` are the same open document. The server knows
    /// both. Saying so costs nothing and removes the guesswork.
    ///
    /// Applied at THIS seam rather than at the ~57 `errorResult("unknownDoc")` call sites: one
    /// place to keep correct, and it also catches the device-relayed `deviceFailed:
    /// noSelectionActive` string, which no call-site edit could reach. Anything else — every
    /// other error, and every success — passes through untouched.
    private func enrichedError(_ result: CallTool.Result,
                               arguments: [String: Value]?) async -> CallTool.Result {
        guard result.isError == true,
              let first = result.content.first,
              case .text(let text, _, _) = first
        else { return result }

        if text == "unknownDoc" {
            let named = (arguments?["docId"]?.stringValue).map { " named \"\($0)\"" } ?? ""
            let ids = ((try? await manager.listDocuments()) ?? []).map(\.id).sorted()
            return Self.errorResult("unknownDoc: no document\(named). \(Self.documentsClause(ids))")
        }

        if text == "noDeviceAvailable" {
            // Two different problems wear this one word: nothing connected at all, or something
            // connected that cannot do this particular job.
            let (count, capabilities) = await broker.connectionSummary()
            let clause = count == 0
                ? "no device is connected to this server (open the app with the mirror enabled)"
                : "\(count) device(s) connected, none offering the capability this tool needs "
                  + "(offered: \(capabilities.sorted().joined(separator: ", ")))"
            return Self.errorResult("\(text) — \(clause)")
        }

        if text == "noSelectionActive" || text.hasSuffix("noSelectionActive") {
            // The rule is about what the SERVER can verify, not about who produced the reason.
            //
            // A device answers `deviceFailed: noSelectionActive` in two very different
            // situations: the document the agent named is open and nothing is selected (literal,
            // and the device is authoritative — say nothing), or the agent named a document this
            // device does not have open at all (the renamed-document case — say which one it
            // does). Only the server can tell those apart, from its own subscriber set, and
            // getting this backwards means either lying about an open document or staying silent
            // in exactly the case the message exists for. Both were live at different points
            // while writing this.
            let live = await manager.liveInfo()
                .filter { $0.value.subscriberCount > 0 }
                .keys.sorted()
            if let named = arguments?["docId"]?.stringValue, live.contains(named) {
                return result          // it IS open: `noSelectionActive` means what it says
            }
            let clause = live.isEmpty
                ? "no document is open on any connected device"
                : "open on a connected device: " + live.map { "\"\($0)\"" }.joined(separator: ", ")
            return Self.errorResult("\(text) — \(clause)")
        }

        return result
    }

    /// "Documents: a, b, c" — capped, because a store with dozens of documents should not answer
    /// a mistyped name with a wall of text.
    private static func documentsClause(_ ids: [String], limit: Int = 12) -> String {
        guard !ids.isEmpty else { return "This server holds no documents." }
        let shown = ids.prefix(limit).map { "\"\($0)\"" }.joined(separator: ", ")
        let more = ids.count > limit ? " (+\(ids.count - limit) more)" : ""
        return "Documents: \(shown)\(more)"
    }

    private func dispatchCallTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        switch name {
        case "transform_elements": return await callTransformElements(arguments)
        case "undo_last_edit": return await callUndoLastEdit(arguments)
        case "list_docs": return await callListDocs()
        case "list_open_docs": return await callListOpenDocs()
        case "tag_elements": return await callTagElements(arguments)
        case "find_elements": return await callFindElements(arguments)
        case "add_text": return await callAddText(arguments)
        case "add_image": return await callAddImage(arguments)
        case "edit_text": return await callEditText(arguments)
        case "remove_text": return await callRemoveText(arguments)
        case "delete_doc": return await callDeleteDoc(arguments)
        case "remove_image": return await callRemoveImage(arguments)
        case "set_pinned": return await callSetPinned(arguments)
        case "set_paper": return await callSetPaper(arguments)
        case "replace_doc": return await callReplaceDoc(arguments)
        case "create_doc": return await callCreateDoc(arguments)
        case "draw_strokes": return await callDrawStrokes(arguments)
        case "delete_strokes": return await callDeleteStrokes(arguments)
        case "list_strokes": return await callListStrokes(arguments)
        case "list_texts": return await callListTexts(arguments)
        case "list_images": return await callListImages(arguments)
        case "list_grids": return await callListGrids(arguments)
        case "add_grid": return await callAddGrid(arguments)
        case "update_grid": return await callUpdateGrid(arguments)
        case "remove_grid": return await callRemoveGrid(arguments)
        case "set_grid_origin": return await callSetGridOrigin(arguments)
        case "reorder_grids": return await callReorderGrids(arguments)
        case "render_sketch": return await callRenderSketch(arguments)
        case "get_strokes": return await callGetStrokes(arguments)
        case "snap_points": return await callSnapPoints(arguments)
        case "transform_strokes": return await callTransformStrokes(arguments)
        case "restyle_strokes": return await callRestyleStrokes(arguments)
        case "reshape_strokes": return await callReshapeStrokes(arguments)
        case "list_fonts": return await callListFonts(arguments)
        case "get_selection": return await callGetSelection(arguments)
        case "transform_selection": return await callTransformSelection(arguments)
        case "select_all": return await callSelectAll(arguments)
        case "get_tool": return await callGetTool(arguments)
        case "draw_selection": return await callDrawSelection(arguments)
        case "restyle_selection": return await callRestyleSelection(arguments)
        case "delete_selection": return await callDeleteSelection(arguments)
        case "select_elements": return await callSelectElements(arguments)
        case "set_reference_point": return await callSetReferencePoint(arguments)
        case "clear_selection": return await callClearSelection(arguments)
        case "preview_selection": return await callPreviewSelection(arguments)
        case "duplicate_selection": return await callDuplicateSelection(arguments)
        case "merge_docs": return await callMergeDocs(arguments)
        case "copy_elements": return await callCopyElements(arguments)
        case "reorder_elements": return await callReorderElements(arguments)
        case "fetch_doc": return await callFetchDoc(arguments)
        default:
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
    }

    /// Plain-vs-styled routing (styled_text branch): no style/spans argument
    /// → the unchanged server-side `DocJSON` path, byte-identical to before
    /// this branch existed (`callAddTextServerSide`, extracted verbatim).
    /// Any of color/fontSize/bold/italic/family/spans → relay an `addText`
    /// device op instead (`callAddTextStyled`).
    private func callAddText(_ arguments: [String: Value]?) async -> CallTool.Result {
        if Self.hasStyleArgs(arguments) {
            return await callAddTextStyled(arguments)
        }
        return await callAddTextServerSide(arguments)
    }

    /// The pre-styled_text `add_text` body, extracted verbatim — same
    /// behaviour, same tests (see plainAddTextStillUsesTheServerSidePathAndDoesNotRelay).
    private func callAddTextServerSide(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let text = try Self.stringArg(arguments, "text")
            let x = try Self.doubleArg(arguments, "x")
            let y = try Self.doubleArg(arguments, "y")
            let pinned = try Self.boolArg(arguments, "pinned", default: false)

            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
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

    /// Styled `add_text` (styled_text branch): relays an `addText` device op
    /// carrying ONLY the arguments the caller actually supplied — the exact
    /// envelope key set app-side `TextAuthoring.AddSpec` decodes — through
    /// `broker.requestStrokeOp`, gated on "authorText" (not "authorStrokes":
    /// a device that only authors strokes must not be picked for this).
    /// `expectedBytes` is the exact bytes relayed to the device (Task 2,
    /// write CAS) — never a fresh re-read. Surfaces the new text's id (from
    /// the device reply's `meta`, `{"id": …}` — `TextAuthoring.add`, app
    /// repo) in the result text so an agent can `edit_text` exactly what it
    /// just added.
    private func callAddTextStyled(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("addText")]
            for key in ["text", "x", "y", "pinned", "color", "fontSize", "bold", "italic", "family", "spans", "name"] {
                if let value = arguments?[key], !value.isNull {
                    envelope[key] = value
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
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorText")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var summary = "added styled text at seq \(seq)"
                if let meta = out.meta,
                   let decoded = try? JSONDecoder().decode([String: String].self, from: meta),
                   let id = decoded["id"] {
                    summary += "\nid: \(id)"
                }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `add_image` (Task 2): relays an `addImage` device op — `{op, imageBytes
    /// (base64, relayed verbatim), x, y, width?, height?, opacity?}`, present-only
    /// optionals — through `broker.requestStrokeOp`, gated on the "authorImage"
    /// capability (a device that only authors strokes/text must not be picked
    /// for this — same reasoning as `callAddTextStyled`'s "authorText" gate).
    /// The image itself is decoded device-side (`ImageAuthoring`, app repo);
    /// this relay never touches the bytes beyond passing the base64 string
    /// through. `expectedBytes` is the exact bytes relayed to the device (the
    /// write CAS, unchanged from every other relay tool) — never a fresh
    /// re-read. Surfaces the new image's id (from the device reply's `meta`,
    /// `{"id": …}`) in the result text, mirroring `callAddTextStyled`.
    private func callAddImage(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let bytesB64 = try Self.stringArg(arguments, "bytes")  // relay verbatim as base64
            let x = try Self.doubleArg(arguments, "x")
            let y = try Self.doubleArg(arguments, "y")
            let width = try Self.optionalDoubleArg(arguments, "width")
            let height = try Self.optionalDoubleArg(arguments, "height")
            let opacity = try Self.optionalDoubleArg(arguments, "opacity")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("addImage"), "imageBytes": .string(bytesB64),
                "x": .double(x), "y": .double(y),
            ]
            if let width { envelope["width"] = .double(width) }
            if let height { envelope["height"] = .double(height) }
            if let opacity { envelope["opacity"] = .double(opacity) }
            if let name = try Self.optionalStringArg(arguments, "name") { envelope["name"] = .string(name) }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorImage")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var summary = "added image to \(docId) at seq \(seq)"
                if let meta = out.meta,
                   let decoded = try? JSONDecoder().decode([String: String].self, from: meta),
                   let id = decoded["id"] {
                    summary += "\nid: \(id)"
                }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Plain-vs-styled routing for `edit_text`, mirroring `callAddText`.
    private func callEditText(_ arguments: [String: Value]?) async -> CallTool.Result {
        if Self.hasStyleArgs(arguments) {
            return await callEditTextStyled(arguments)
        }
        return await callEditTextServerSide(arguments)
    }

    /// The pre-styled_text `edit_text` body, extracted verbatim — same
    /// behaviour, same tests (see plainEditTextStillUsesTheServerSidePathAndDoesNotRelay).
    private func callEditTextServerSide(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let textId = try Self.stringArg(arguments, "textId")
            let newText = try Self.optionalStringArg(arguments, "text")
            let x = try Self.optionalDoubleArg(arguments, "x")
            let y = try Self.optionalDoubleArg(arguments, "y")

            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
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

    /// Styled `edit_text` (styled_text branch): relays an `editText` device
    /// op carrying ONLY the arguments the caller actually supplied, through
    /// `broker.requestStrokeOp` gated on "authorText". `expectedBytes` is
    /// the exact bytes relayed to the device (Task 2, write CAS) — never a
    /// fresh re-read.
    private func callEditTextStyled(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let textId = try Self.stringArg(arguments, "textId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("editText"), "textId": .string(textId)]
            for key in ["text", "x", "y", "color", "fontSize", "bold", "italic", "family", "spans"] {
                if let value = arguments?[key], !value.isNull {
                    envelope[key] = value
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
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorText")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "edited \(textId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `list_fonts` (styled_text branch): relays `{"op": "listFonts"}` and
    /// passes the device's reply bytes through as text — modeled on
    /// `callListStrokes`, not `callDrawStrokes`: READ-ONLY, no
    /// `submitAndRespond`, no seq bump. Gated on "authorText".
    private func callListFonts(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("listFonts")]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorText")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // `.meta` is render-only (nil here) — list_fonts ignores it.
            return CallTool.Result(content: [
                .text(text: String(decoding: out.bytes, as: UTF8.self), annotations: nil, _meta: nil)
            ])
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

            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
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

    /// Unlike every other write tool this takes no CAS: the caller asked for the document to be
    /// gone, so a write that landed a moment earlier does not make the request stale. The bytes
    /// are recoverable from the server's .trash directory either way.
    private func callDeleteDoc(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            do {
                try await manager.deleteDoc(docId: docId)
            } catch {
                return Self.errorResult("unknownDoc")
            }
            // The bytes are gone, so its undo history is meaningless — and an undo that
            // resurrected a deleted document would be a surprise, not a service. It also stops a
            // recycled name inheriting the previous document's history, which is how an undo
            // could otherwise reach content that was never in THIS document at all.
            await history.forget(docId: docId)
            return Self.textResult("deleted \(docId)")
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callRemoveImage(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let imageId = try Self.stringArg(arguments, "imageId")

            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let out: Data
            do {
                out = try DocJSON.removeImage(from: bytes, imageId: imageId)
            } catch let error as DocJSON.DocJSONError {
                return Self.errorResult(Self.reason(for: error))
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out, expectedBytes: bytes
            ) { seq in
                "removed \(imageId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Flips the `pinned` flag on the named placed texts/images — a pure
    /// server-side `DocJSON` write (no device), mirroring `callRemoveImage`:
    /// `unknownDoc` fast-fail, `DocJSON.setPinned`, then the byte-CAS write
    /// (`docChangedDuringOp`). `ids` is required non-empty; `pinned` is required.
    private func callSetPinned(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let ids = try Self.nonEmptyStringArrayArg(arguments, "ids")
            let pinned = try Self.requiredBoolArg(arguments, "pinned")

            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let out: Data
            do {
                out = try DocJSON.setPinned(from: bytes, ids: ids, pinned: pinned)
            } catch let error as DocJSON.DocJSONError {
                return Self.errorResult(Self.reason(for: error))
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out, expectedBytes: bytes
            ) { seq in
                "set pinned=\(pinned) on \(ids.count) element(s) in \(docId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Sets a document's paper colours / transparent flag — a pure server-side
    /// `DocJSON` write (no device), mirroring `callSetPinned`. At least one of
    /// `light`/`dark`/`transparent` is required (else `invalidArguments`);
    /// `unknownDoc` fast-fail; byte-CAS write (`docChangedDuringOp`); a bad hex
    /// surfaces as `invalidSpec` via `DocJSON`.
    private func callSetPaper(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let light = try Self.optionalStringArg(arguments, "light")
            let dark = try Self.optionalStringArg(arguments, "dark")
            let transparent = try Self.optionalBoolArg(arguments, "transparent")
            guard light != nil || dark != nil || transparent != nil else {
                return Self.errorResult("invalidArguments")
            }
            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let out: Data
            do {
                out = try DocJSON.setPaper(from: bytes, light: light, dark: dark, transparent: transparent)
            } catch let error as DocJSON.DocJSONError {
                return Self.errorResult(Self.reason(for: error))
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out, expectedBytes: bytes
            ) { seq in
                "set paper on \(docId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Unlike the other three text tools, this never reads/parses the
    /// current bytes to compute the replacement — the bytes are opaque by
    /// design (spec: "the agent owns their validity"). It gets a CAS on both
    /// branches (Task 2 write CAS + Task 3 expect-absent create CAS): read
    /// the doc's current bytes first and pass `.matchBytes(currentBytes)`
    /// when it exists, `.absent` when it doesn't — the latter also selects
    /// the create path via `createIfMissing: true` (unchanged) and, being
    /// enforced against the store in the same actor turn as the write
    /// (`DocumentSession.submit`), closes the same create-vs-create race
    /// `create_doc` closes. A blind overwrite of a doc that changed under the
    /// agent's feet, or a blind create over one a racing caller just created,
    /// is exactly the loss this plan exists to prevent — on rejection, the
    /// agent can re-read and re-decide instead of clobbering someone else's
    /// write. `createIfMissing: true` is harmless in the existing-doc branch
    /// too (it only matters when no session and no stored doc exist), so one
    /// call covers both branches.
    private func callReplaceDoc(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let bytes = try Self.base64DataArg(arguments, "bytes")
            // Resident-only, NOT `currentBytesOrFetch` — like `create_doc`/`merge_docs into:`,
            // this read is a create-vs-write CAS token, not a read-to-operate. `replace_doc`
            // overwrites the doc with the agent's opaque bytes, so it gains nothing from
            // fetching content-on-another-device (it would relay for seconds, promote a doc it's
            // about to overwrite, then discard the fetched bytes). Worse, auto-fetching would
            // synthesize a `.matchBytes(V0)` token the agent never actually read, defeating the
            // `.absent` create-CAS above ("never silently overwrite a different doc of the same
            // name") for a metadata-only doc. A metadata-only doc reads nil here → `.absent`.
            let currentBytes = await manager.currentBytes(docId: docId)
            return await submitAndRespond(
                docId: docId, createIfMissing: true, fullDoc: bytes,
                expectation: currentBytes.map(WriteExpectation.matchBytes) ?? .absent
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

            // expectation: .absent — the fast-fail `docExists` check above is
            // a pre-device-round-trip convenience only (never wake a device
            // for a docId that's already taken); the ATOMIC guard against a
            // racing create for the same docId is this `.absent` expectation,
            // enforced in the same actor turn as the write itself
            // (`DocumentSession.submit`, Task 2).
            return await submitAndRespond(
                docId: docId, createIfMissing: true, fullDoc: bytes, expectation: .absent
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
    // draw, a non-empty string `ids` array for delete — deep validation
    // (stroke shape, colours, unknown keys, …) is the device's job, surfaced
    // verbatim as `deviceFailed: <reason>`. `list_strokes` never writes: its
    // result is the device's listing bytes decoded as UTF-8 text, passed
    // straight through.

    private func callDrawStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let strokes = try Self.nonEmptyValueArrayArg(arguments, "strokes")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
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
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                // `out.meta` carries the created strokes' composite KEYS, in
                // the order supplied (`StrokeAuthoring.draw`'s `{"keys": […]}`,
                // app repo) — surfaced here so an agent can revise EXACTLY
                // what it just drew instead of re-finding it by bounding box
                // (the measured failure mode that once clobbered the wrong
                // stroke). A missing/undecodable meta degrades to just the
                // seq line rather than throwing.
                var summary = "drew \(strokes.count) stroke(s) at seq \(seq)"
                // A typed struct, NOT [String: [String]] — that shape cannot decode the
                // `resolvedTool` object and silently dropped the `ids:` line when the device
                // started reporting it. The device's meta and this decoder move together.
                struct DrawMeta: Decodable {
                    struct Tool: Decodable { let inkType: String; let width: Double; let color: String }
                    let keys: [String]?
                    let resolvedTool: Tool?
                    /// Parallel to `keys`; an empty entry means that stroke's name displaced
                    /// nothing. Absent entirely when no supplied name took over.
                    let displacedNames: [String]?
                    let clampedWidths: [Double]?
                }
                if let meta = out.meta,
                   let decoded = try? JSONDecoder().decode(DrawMeta.self, from: meta) {
                    if let keys = decoded.keys, !keys.isEmpty {
                        summary += "\nids: \(keys.joined(separator: ", "))"
                    }
                    // What an omitted colour/width/inkType actually inherited from the user's
                    // picker. Pass these back explicitly if you previewed first: the picker is
                    // live, so omitting the fields twice reads it twice.
                    if let tool = decoded.resolvedTool {
                        summary += "\ninherited from the user's tool: inkType \(tool.inkType), width \(tool.width), color \(tool.color)"
                    }
                    // A name that was already taken MOVES to the new stroke. The element it came
                    // from is still on the canvas, now unnamed — reported so you can delete it if
                    // this draw was meant to replace it.
                    // A width below the ink's floor renders as almost nothing, so it is raised
                    // rather than silently drawn invisible (art-session finding 12).
                    if let clamped = decoded.clampedWidths, !clamped.isEmpty {
                        summary += "\nnote: \(clamped.count) stroke(s) asked for a width "
                                 + "(\(clamped.map { String(format: "%.1f", $0) }.joined(separator: ", "))) "
                                 + "below what that ink can render, and were raised to its minimum "
                                 + "(2.5, or 1.2 for pencil). Below it a stroke is effectively invisible."
                    }
                    if let displaced = decoded.displacedNames {
                        for taken in displaced where !taken.isEmpty {
                            summary += "\nthe name moved from \(taken), which is still on the canvas and now unnamed"
                        }
                    }
                }
                return summary
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
            let ids = try Self.nonEmptyStringArrayArg(arguments, "ids")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(
                    Value.object(["op": .string("delete"), "ids": .array(ids.map(Value.string))]))
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
                "deleted \(ids.count) stroke(s) at seq \(seq)"
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

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
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

    /// Mirrors `callListStrokes` exactly, but gated on the "authorText"
    /// capability instead of the stroke tools' default "authorStrokes" — a
    /// device that only advertises stroke authoring must not be selected for
    /// this read (agent-list-elements spec, Task 2). Never writes: the
    /// device's listing bytes are decoded as UTF-8 and passed straight
    /// through as the tool result's text content.
    private func callListTexts(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("listTexts")]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorText")
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

    /// Mirrors `callListStrokes` exactly, but gated on the "authorImage"
    /// capability instead of the stroke tools' default "authorStrokes" — a
    /// device that only advertises stroke authoring must not be selected for
    /// this read (agent-list-elements spec, Task 2). Never writes: the
    /// device's listing bytes are decoded as UTF-8 and passed straight
    /// through as the tool result's text content.
    private func callListImages(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("listImages")]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorImage")
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

    // MARK: - Grid authoring (agent-grid-authoring spec, Task 3)
    //
    // `list_grids`/`add_grid`/`update_grid`/`remove_grid`/`set_grid_origin`
    // relay a `GridAuthoring` device op (app repo, Task 2), gated on the
    // "authorGrids" capability — a device that only authors strokes/text/
    // images must not be picked for these. `list_grids` mirrors
    // `callListImages`: READ-ONLY, no `submitAndRespond`. The four write
    // tools mirror `callAddImage`: present-only envelope, byte-CAS write via
    // `submitAndRespond(expectedBytes: docBytes)`.

    /// Mirrors `callListImages` exactly, but gated on the "authorGrids"
    /// capability. Never writes: the device's listing bytes are decoded as
    /// UTF-8 and passed straight through as the tool result's text content.
    private func callListGrids(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("listGrids")]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorGrids")
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

    /// Relays an `addGrid` device op carrying ONLY the arguments the caller
    /// actually supplied — mirrors `callAddImage`. `expectedBytes` is the
    /// exact bytes relayed to the device (the write CAS) — never a fresh
    /// re-read. Surfaces the new grid's id (from the device reply's `meta`,
    /// `{"id": …}`) in the result text, mirroring `callAddImage`/
    /// `callAddTextStyled`.
    private func callAddGrid(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("addGrid")]
            for key in ["type", "spacing", "snap", "rotation", "color", "thickness", "visible", "enabled", "offset"] {
                if let value = arguments?[key], !value.isNull {
                    envelope[key] = value
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
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorGrids")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var summary = "added grid to \(docId) at seq \(seq)"
                if let meta = out.meta,
                   let decoded = try? JSONDecoder().decode([String: String].self, from: meta),
                   let id = decoded["id"] {
                    summary += "\nid: \(id)"
                }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Relays an `updateGrid` device op carrying the target `id` plus ONLY
    /// the fields the caller actually supplied — mirrors `callAddGrid`'s
    /// present-only envelope construction. `expectedBytes` is the exact
    /// bytes relayed to the device (the write CAS) — never a fresh re-read.
    private func callUpdateGrid(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let id = try Self.stringArg(arguments, "id")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("updateGrid"), "id": .string(id)]
            for key in ["type", "spacing", "snap", "rotation", "color", "thickness", "visible", "enabled", "offset"] {
                if let value = arguments?[key], !value.isNull {
                    envelope[key] = value
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
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorGrids")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "updated grid \(id) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Relays a `removeGrid` device op naming the target `id` — mirrors
    /// `callRemoveImage`'s shape, but device-relayed (not server-side
    /// `DocJSON`, unlike remove_text/remove_image): a grid CRUD op needs the
    /// device's pivot/offset reduction math (`GridRotationMath`, app-only),
    /// so every grid op is device-relayed uniformly, including removal.
    private func callRemoveGrid(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let id = try Self.stringArg(arguments, "id")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("removeGrid"), "id": .string(id)]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorGrids")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "removed grid \(id) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Relays a `setGridOrigin` device op naming the target `id` plus the
    /// canvas-space `x`/`y` pivot — the programmatic equivalent of the app's
    /// tap-to-pick-origin gesture. `expectedBytes` is the exact bytes
    /// relayed to the device (the write CAS) — never a fresh re-read.
    private func callSetGridOrigin(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let id = try Self.stringArg(arguments, "id")
            let x = try Self.doubleArg(arguments, "x")
            let y = try Self.doubleArg(arguments, "y")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("setGridOrigin"), "id": .string(id), "x": .double(x), "y": .double(y),
                ]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorGrids")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "set origin of grid \(id) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Relays a `reorderGrids` device op carrying the full ordered id list
    /// verbatim — mirrors `callUpdateGrid`'s shape (same capability,
    /// same CAS write), but with a single required array argument instead of
    /// present-only optionals. Reads via `optionalStringArrayArg`
    /// (`select_elements`'s helper) rather than `nonEmptyStringArrayArg`
    /// (`delete_strokes`'s `ids`) because `orderedIds: []` is a VALID
    /// no-op on a 0-grid document — a non-empty guard here would be a
    /// server-side validation of `orderedIds`, contradicting the next
    /// sentence. The server does NOT validate that `orderedIds` is a
    /// permutation of the document's actual grid ids — that's the device's
    /// job (gridNotFound/invalidSpec, surfaced via `deviceFailed:`).
    /// `expectedBytes` is the exact bytes relayed to the device (the write
    /// CAS) — never a fresh re-read.
    private func callReorderGrids(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            guard let orderedIds = try Self.optionalStringArrayArg(arguments, "orderedIds") else {
                return Self.errorResult("missingArgument: orderedIds")
            }

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("reorderGrids"), "orderedIds": .array(orderedIds.map(Value.string)),
                ]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "authorGrids")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                "reordered \(orderedIds.count) grids in \(docId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    // MARK: - reorder_elements (agent-element-zorder, Task 2: server relay)
    //
    // Bring-to-front/send-to-back for strokes/texts/images within ONE
    // document — the element-level counterpart to reorder_grids above, but
    // gated on the "reorderElements" capability (a device that only authors
    // grids must not be picked for this) and validated server-side on
    // `mode` (unlike orderedIds above, "front"/"back" IS a closed
    // enumeration the server can and does check before ever contacting a
    // device). At least one of strokeIds/textIds/imageIds is required —
    // an op with no ids at all would be a silent no-op relayed to the
    // device for nothing.
    private func callReorderElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let strokeIds = try Self.optionalStringArrayArg(arguments, "strokeIds") ?? []
            let textIds = try Self.optionalStringArrayArg(arguments, "textIds") ?? []
            let imageIds = try Self.optionalStringArrayArg(arguments, "imageIds") ?? []
            let mode = try Self.stringArg(arguments, "mode")
            guard mode == "front" || mode == "back" else { return Self.errorResult("invalidArguments") }
            guard !(strokeIds.isEmpty && textIds.isEmpty && imageIds.isEmpty) else { return Self.errorResult("invalidArguments") }

            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else { return Self.errorResult("unknownDoc") }
            let count = strokeIds.count + textIds.count + imageIds.count
            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("reorderElements"),
                    "strokeIds": .array(strokeIds.map(Value.string)),
                    "textIds": .array(textIds.map(Value.string)),
                    "imageIds": .array(imageIds.map(Value.string)),
                    "mode": .string(mode),
                ]))
            } catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec, capability: "reorderElements")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: bytes
            ) { seq in
                "moved \(count) element(s) to \(mode) in \(docId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `tag_elements` — set or clear a durable element name
    /// (spec 2026-07-27-element-names-design.md). Device-relayed because validating that an id
    /// EXISTS means enumerating stroke composite keys, and only PencilKit can decode a drawing.
    private func callTagElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ids = try Self.nonEmptyStringArrayArg(arguments, "ids")
            let name = try Self.optionalStringArg(arguments, "name")
            // A name belongs to ONE element: naming several at once has no meaning, and naming
            // only the first would be a trap. Clearing many is unambiguous, so it is allowed.
            if name != nil && ids.count != 1 { return Self.errorResult("invalidArguments") }

            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else { return Self.errorResult("unknownDoc") }
            var fields: [String: Value] = [
                "op": .string("tagElements"),
                "ids": .array(ids.map(Value.string)),
            ]
            if let name { fields["name"] = .string(name) }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(fields)) }
            catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec, capability: "tagElements")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // The device reports which element lost the name, if any — surfaced verbatim so the
            // agent can delete the displaced element if this was meant as a replacement.
            let displaced = out.meta
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["displaced"]
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: bytes
            ) { seq in
                guard let name else { return "cleared \(ids.count) name(s) in \(docId) at seq \(seq)" }
                guard let displaced else { return "named \(ids[0]) \"\(name)\" in \(docId) at seq \(seq)" }
                return "named \(ids[0]) \"\(name)\" in \(docId) at seq \(seq); the name moved from \(displaced), "
                     + "which is still on the canvas and now unnamed"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `find_elements` — resolve names to ids. Read-only: no submit, no seq, nothing to retry.
    private func callFindElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let names = try Self.nonEmptyStringArrayArg(arguments, "names")
            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else { return Self.errorResult("unknownDoc") }
            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("findElements"),
                    "names": .array(names.map(Value.string)),
                ]))
            } catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec, capability: "tagElements")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            guard let meta = out.meta, let text = String(data: meta, encoding: .utf8) else {
                return Self.errorResult("deviceFailed: no lookup result")
            }
            return Self.textResult(text)
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// M2c-3: the explicit counterpart to every content tool's transparent
    /// `currentBytesOrFetch` auto-fetch — this tool exists ONLY so an agent
    /// can distinguish and control the outcome the transparent tools don't
    /// report: resident-already / freshly-fetched-and-promoted /
    /// known-but-unreachable / genuinely unknown. Read-only (no write, no
    /// seq, nothing to retry).
    private func callFetchDoc(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            if let resident = await manager.currentBytes(docId: docId) {
                return Self.textResult("already available (\(resident.count) bytes): \(docId)")
            }
            if let bytes = await manager.currentBytesOrFetch(docId: docId) {
                return Self.textResult("fetched \(docId) (\(bytes.count) bytes)")
            }
            // Nothing resident and the fetch returned nil: known-but-unreachable vs truly unknown.
            if await manager.liveEntry(docId: docId) != nil {
                return Self.errorResult("contentUnavailable")
            }
            return Self.errorResult("unknownDoc")
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
    /// (stroke shape, unknown strokeIds, degenerate rect, pixel budget) is
    /// the device's job, surfaced verbatim as `deviceFailed: <reason>`.
    private func callRenderSketch(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
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
        "include", "strokeIds", "strokes", "rect", "padding", "background", "axes", "maxPixels",
    ]

    // MARK: - Stroke-editing tools (spec 2026-07-14):
    // get/transform/restyle/reshape_strokes, plus snap_points
    // (grid-snapping spec, 2026-07-14)
    //
    // Same shape as the Task 4 stroke-op tools above: compose a minimal
    // op-spec envelope containing ONLY the fields the caller actually
    // supplied (so the envelope's exact key set is deterministic and
    // pinned by strokeEditingSpecEnvelopesMatchTheCanonicalShape), relay it
    // plus the document's current bytes through `broker.requestStrokeOp`,
    // and — for the three writes — tail into `submitAndRespond` with
    // `expectedBytes: docBytes`, THE EXACT BYTES RELAYED TO THE DEVICE,
    // never a fresh re-read (Task 2, write CAS: a re-read would re-open the
    // very race the guard exists to close). `get_strokes` and `snap_points`
    // never write: no `submitAndRespond`, no seq bump, the device's reply
    // bytes decoded as UTF-8 and passed straight through, exactly like
    // `list_strokes`.

    /// Read-only, like `list_strokes`/`render_sketch`: the device's listing
    /// bytes are decoded as UTF-8 and passed straight through. No
    /// `submitAndRespond`, so no seq bump and no CAS — a read never writes.
    private func callGetStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ids = try Self.nonEmptyStringArrayArg(arguments, "ids")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("get"),
                "ids": .array(ids.map(Value.string)),
            ]
            // Relayed VERBATIM, like every other optional argument in this
            // file (transform/restyle's field loops, render_sketch's
            // renderSpecParameterNames) — NOT filtered through `.intValue`,
            // which returns nil for a `.double` (or a string) and would
            // silently DROP a non-integer maxPoints instead of letting the
            // app's `GetSpec.maxPoints: Int?` decode fail LOUDLY
            // (invalidSpec) on a bad type. Review fix; pinned by
            // getStrokesRelaysMaxPointsVerbatimWhenNotAnIntToken.
            if let value = arguments?["maxPoints"] {
                envelope["maxPoints"] = value
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

    /// Read-only, like `get_strokes`/`list_strokes`/`render_sketch`: the
    /// device's candidate-listing bytes are decoded as UTF-8 and passed
    /// straight through. No `submitAndRespond`, so no seq bump and no CAS —
    /// a snap query never writes, it only answers "where could this point
    /// go?" (see the tool's description for why grabbing candidates[0] is a
    /// trap, not a shortcut).
    private func callSnapPoints(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let points = try Self.nonEmptyValueArrayArg(arguments, "points")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("snap"),
                "points": .array(points),
            ]
            // Only the keys the caller actually supplied — deep validation
            // (unknown gridId, maxCandidates <= 0) is the device's job,
            // surfaced verbatim as `deviceFailed: <reason>`.
            for name in ["gridIds", "maxCandidates"] {
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
            let ids = try Self.nonEmptyStringArrayArg(arguments, "ids")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("transform"),
                "ids": .array(ids.map(Value.string)),
            ]
            // Only the keys the caller actually supplied — deep validation
            // (finite values, non-zero scale, at-least-one-op, unknown
            // gridId/familyIds on snapTo) is the device's job, surfaced
            // verbatim as `deviceFailed: <reason>`.
            for name in ["translate", "scale", "rotate", "anchor", "snapToGrid", "snapTo"] {
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
                "transformed \(ids.count) stroke(s) at seq \(seq)"
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
            let ids = try Self.nonEmptyStringArrayArg(arguments, "ids")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("restyle"),
                "ids": .array(ids.map(Value.string)),
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
                "restyled \(ids.count) stroke(s) at seq \(seq)"
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

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
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
            // The device counts vertices that WOULD have been sharp if these points had been read
            // as a polyline, for items that did not say which reading they meant. It is the
            // commonest way to get a surprising result out of this tool — the same point list that
            // draws a rectangle in draw_strokes reshapes into a rounded blob here — and until now
            // the only sign was the picture.
            let roundedCorners = out.meta
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] }?["roundedCorners"]
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var summary = "reshaped \(items.count) stroke(s) at seq \(seq)"
                if let roundedCorners, roundedCorners > 0 {
                    summary += "\nnote: \(roundedCorners) sharp corner(s) were ROUNDED. Points are "
                             + "spline knots here by default (the opposite of draw_strokes) so a "
                             + "stroke a human drew keeps its curve. Pass \"smooth\": false to read "
                             + "them as a polyline and keep the corners."
                }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    // MARK: - Selection-control tools (agent-selection-control spec)
    //
    // Same shape as every other stroke-op tool above: compose a minimal
    // op-spec envelope, relay it plus the document's current bytes through
    // `broker.requestStrokeOp`, but with `capability: "controlSelection"` —
    // a device only registers for these ops via the `controlSelection`
    // hello capability (WSAdapter's gate). UNLIKE the write tools
    // (draw/transform/restyle/reshape_strokes), none of these six calls
    // (get/transform_selection from M1, plus select_all/select_elements/
    // set_reference_point/clear_selection below) tail into
    // `submitAndRespond`: the device applies the op to its own live
    // selection in-session (the same undoable step a manual drag would
    // produce) and the doc mirror push syncs the server on its own schedule
    // — there is no document write for this tool to CAS-guard. There is
    // also no image: `out.bytes` is empty for every op, and the device's
    // JSON answer travels in `out.meta`, decoded straight through as the
    // tool's text result (falling back to "{}" for a missing/undecodable
    // meta, matching `render_sketch`'s degrade-don't-throw handling of the
    // same field).

    /// Read-only: reports the user's current live selection (or the
    /// device-side "no selection" error) without touching the document.
    private func callGetSelection(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("getSelection")]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            let text = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Relays a transform to the device's live selection — one undoable
    /// step on-device, exactly as a manual rect-select drag would produce.
    /// `expect`, when supplied, is relayed verbatim so the device can reject
    /// a stale caller with `selectionChanged`; deep validation of `ops`
    /// (shape, exactly-one-op, `noReferencePoint`) is the device's job,
    /// surfaced verbatim as `deviceFailed: <reason>`.
    private func callTransformSelection(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ops = try Self.nonEmptyValueArrayArg(arguments, "ops")
            let expect = try Self.optionalStringArg(arguments, "expect")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("transformSelection"),
                "ops": .array(ops),
            ]
            if let expect {
                envelope["expect"] = .string(expect)
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            let text = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Selects everything in the document on the device's live rect-select
    /// — a docId-only relay, same skeleton as `callGetSelection` above but
    /// a write op (`selectAll`) rather than a read.
    private func callSelectAll(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("selectAll")]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            let text = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Selects specific elements by id, replacing any existing selection.
    /// Each of `strokeIds`/`textIds`/`imageIds` rides into the envelope
    /// only when the caller actually supplied it — mirrors
    /// `callTransformSelection`'s conditional `expect`. Deep validation
    /// ("at least one id across the three arrays") is the device's job,
    /// surfaced verbatim as `deviceFailed: <reason>`.
    /// Both of these act on LIVE selection state, so — like every other selection op — there is no
    /// document CAS and no server-side submit: the device commits in its own authoritative session
    /// and the ordinary mirror push syncs the server.
    private func callGetTool(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            return await callSelectionOp(docId: docId, envelope: ["op": .string("getTool")])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callDrawSelection(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            guard let strokes = arguments?["strokes"], case .array(let items) = strokes, !items.isEmpty else {
                return Self.errorResult("invalidArgument: strokes")
            }
            var envelope: [String: Value] = ["op": .string("drawSelection"), "strokes": .array(items)]
            if let keep = arguments?["keepRect"] { envelope["keepRect"] = keep }
            return await callSelectionOp(docId: docId, envelope: envelope)
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callRestyleSelection(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            var envelope: [String: Value] = ["op": .string("restyleSelection")]
            if let c = arguments?["color"], case .string(let hex) = c { envelope["color"] = .string(hex) }
            if let w = arguments?["width"] { envelope["width"] = w }
            if let i = arguments?["inkType"], case .string(let ink) = i { envelope["inkType"] = .string(ink) }
            return await callSelectionOp(docId: docId, envelope: envelope)
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callDeleteSelection(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            return await callSelectionOp(docId: docId, envelope: ["op": .string("deleteSelection")])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Shared relay for the live-selection ops: encode the envelope, hand it to the device's
    /// `controlSelection` bridge, and pass its selection descriptor straight back.
    private func callSelectionOp(docId: String, envelope: [String: Value]) async -> CallTool.Result {
        guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
            return Self.errorResult("unknownDoc")
        }
        let spec: Data
        do {
            spec = try JSONEncoder().encode(Value.object(envelope))
        } catch {
            return Self.errorResult("invalidArguments")
        }
        do {
            let out = try await broker.requestStrokeOp(
                docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            let text = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "ok"
            return Self.textResult(text)
        } catch let error as DeviceCommandBroker.DeviceCommandError {
            return Self.strokeOpErrorResult(error)
        } catch {
            return Self.errorResult("deviceFailed")
        }
    }

    private func callSelectElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let strokeIds = try Self.optionalStringArrayArg(arguments, "strokeIds")
            let textIds = try Self.optionalStringArrayArg(arguments, "textIds")
            let imageIds = try Self.optionalStringArrayArg(arguments, "imageIds")
            let keepRect = try Self.optionalBoolArg(arguments, "keepRect")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("selectElements")]
            if let keepRect {
                envelope["keepRect"] = .bool(keepRect)
            }
            if let strokeIds {
                envelope["strokeIds"] = .array(strokeIds.map(Value.string))
            }
            if let textIds {
                envelope["textIds"] = .array(textIds.map(Value.string))
            }
            if let imageIds {
                envelope["imageIds"] = .array(imageIds.map(Value.string))
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            let text = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Places the reference point the user's live selection
    /// pivots/rotates/scales around, at the given CANVAS coordinates — no
    /// snapping (an agent that wants a lattice point calls `snap_points`
    /// first and passes one of its candidates). `x`/`y` are read as a pair:
    /// either both parse as numbers or the call fails with one combined
    /// message rather than surfacing which single field was bad, since a
    /// caller passing neither or garbling one typically garbled both.
    private func callSetReferencePoint(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            guard let x = try? Self.doubleArg(arguments, "x"),
                let y = try? Self.doubleArg(arguments, "y")
            else {
                return Self.errorResult("invalidArguments: x and y are required")
            }

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(
                    Value.object(["op": .string("setReferencePoint"), "x": .double(x), "y": .double(y)]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            let text = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Clears the user's live selection, returning it to idle — a
    /// docId-only relay, same skeleton as `callSelectAll` but `clearSelection`.
    private func callClearSelection(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(["op": .string("clearSelection")]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            let text = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Renders a proposed transform of the live selection WITHOUT committing
    /// anything — modeled EXACTLY on `callRenderSketch` (same two-content
    /// `.image` + `.text` result shape), but gated on `controlSelection`
    /// like every other selection tool. A pure relay: this tool does zero
    /// geometry itself — it collects args, builds the `previewSelection`
    /// op-spec envelope, and hands it to the device, which does the actual
    /// transform + render (`RectSelect_Ex_AgentSelection.previewSelectionForAgent`,
    /// app repo). Optional args (`include`/`rect`/`includePoints`/`duplicate`) ride into
    /// the envelope only when the caller actually supplied them — never as
    /// an explicit null — mirroring `callTransformSelection`'s conditional
    /// `expect` and `callRenderSketch`'s parameter loop. `duplicate` (Task 7,
    /// Milestone 3) previews a stamp: originals plus a transformed copy,
    /// rendered together — requires `ops`.
    private func callPreviewSelection(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ops = try Self.nonEmptyValueArrayArg(arguments, "ops")
            let include = try Self.optionalStringArg(arguments, "include")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("previewSelection"),
                "ops": .array(ops),
            ]
            if let include {
                envelope["include"] = .string(include)
            }
            for key in ["rect", "includePoints", "duplicate"] {
                if let value = arguments?[key], !value.isNull {
                    envelope[key] = value
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
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return CallTool.Result(content: [
                .image(data: out.bytes.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
                .text(text: out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "{}", annotations: nil, _meta: nil),
            ])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Duplicates the user's live selection on a connected device (Task 7,
    /// Milestone 3) — same relay skeleton as `callTransformSelection`, but
    /// `ops` is OPTIONAL here: omitted, the device makes a provisional
    /// in-place copy (toolbar-duplicate semantics); supplied, it clones then
    /// transforms as one "stamp" undo step. `expect`, when supplied, rides
    /// along verbatim so the device can reject a stale caller with
    /// `selectionChanged`, exactly like `transform_selection`. Deep
    /// validation (op-count 1–16, shape) is the device's job, surfaced
    /// verbatim as `deviceFailed: <reason>`.
    private func callDuplicateSelection(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ops = try Self.optionalValueArrayArg(arguments, "ops")
            let expect = try Self.optionalStringArg(arguments, "expect")

            guard let docBytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("duplicateSelection")]
            if let ops {
                envelope["ops"] = .array(ops)
            }
            if let expect {
                envelope["expect"] = .string(expect)
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: "controlSelection")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            let text = out.meta.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    // MARK: - merge_docs (agent-merge-docs spec, Task 1: server relay;
    // agent-merge-docs-into: optional `into` for a non-destructive merge)
    //
    // The server has no PencilKit, so an identity merge can't be computed
    // here — it ships BOTH docs' bytes to a connected device (`target`'s as
    // the relay's `docBytes`, `source`'s base64'd INSIDE the op-spec
    // envelope) and the device runs the merge, replying with the merged
    // bytes. The relay itself never changes with `into` — `target`'s bytes
    // are always what's sent as `docBytes`. Only the WRITE of the device's
    // reply branches: with no `into`, the server writes those bytes back to
    // `target` under the same byte-CAS every other write tool uses (`target`
    // changing during the device round-trip rejects docChangedDuringOp,
    // exactly like draw_strokes/delete_strokes above) and `source` is read
    // but NEVER written. With `into`, the reply is instead written to a NEW
    // document under `into`, guarded by the same expect-absent CAS
    // `create_doc` uses (Task 3) — so BOTH `source` and `target` are left
    // untouched.

    /// See the MARK above. `source == target` is rejected before either
    /// doc's bytes are read (an in-place "merge into itself" is never a
    /// meaningful request); likewise `into == source` / `into == target` (an
    /// optional `into` compares unequal to a concrete `source`/`target` when
    /// `into` is nil, so an absent `into` correctly passes this guard).
    /// `prefer` defaults to "target". This tool has no inherent "mine" — the
    /// server always sends a concrete `prefer` to the device rather than
    /// letting the device pick its own default.
    private func callMergeDocs(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let source = try Self.nonEmptyStringArg(arguments, "source")
            let target = try Self.nonEmptyStringArg(arguments, "target")
            let into = try Self.optionalStringArg(arguments, "into")
            guard source != target, into != source, into != target else {
                return Self.errorResult("invalidArguments")
            }
            let prefer = try Self.optionalStringArg(arguments, "prefer") ?? "target"

            guard let sourceBytes = await manager.currentBytesOrFetch(docId: source) else {
                return Self.errorResult("sourceNotFound")
            }
            guard let targetBytes = await manager.currentBytesOrFetch(docId: target) else {
                return Self.errorResult("targetNotFound")
            }
            if let into {
                if await manager.currentBytes(docId: into) != nil {
                    return Self.errorResult("docExists")
                }
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("mergeDocs"),
                    "prefer": .string(prefer),
                    "sourceBytes": .string(sourceBytes.base64EncodedString()),
                ]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: target, docBytes: targetBytes, spec: spec, capability: "mergeDocs")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // Two write shapes, branching on `into`:
            //  - `into` present: the union is a NEW document, guarded by the
            //    same expect-absent CAS `create_doc` uses (Task 3) — the
            //    fast-fail check above is a convenience only; this is the
            //    atomic guard against a racing create under the same `into`.
            //    `source`/`target` are never written in this branch.
            //  - `into` absent: unchanged — write in place into `target`
            //    under the byte-CAS every other write tool uses.
            if let into {
                return await submitAndRespond(
                    docId: into, createIfMissing: true, fullDoc: out.bytes, expectation: .absent
                ) { seq in
                    "merged \(source) and \(target) into \(into) at seq \(seq)"
                }
            } else {
                // expectedBytes is targetBytes — the exact bytes relayed to
                // the device — never a fresh re-read here, which would
                // re-open the very race window this guard exists to close
                // (Task 2, write CAS).
                return await submitAndRespond(
                    docId: target, createIfMissing: false, fullDoc: out.bytes, expectedBytes: targetBytes
                ) { seq in
                    "merged \(source) into \(target) at seq \(seq)"
                }
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    // MARK: - copy_elements (agent-copy-elements spec, Task 2: server relay)
    //
    // Parallel to merge_docs (MARK above), but a COPY not a merge: named
    // strokes/texts/images from `source` are cloned into `target` as FRESH
    // elements (fresh ids), never deduped by identity — copying
    // the same source element twice yields two distinct clones (the
    // contrast the app-side `CopyElements.perform`'s
    // `copyingSameStrokeTwiceMakesTwoDistinctClones` test pins). `source`'s
    // bytes ride base64'd INSIDE the op-spec envelope (never as the relay's
    // `docBytes`, which is always `target`'s); the device's cloned reply is
    // written back to `target` under the standard byte-CAS every other write
    // tool uses. `source` is read but never written.

    private func callCopyElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let source = try Self.nonEmptyStringArg(arguments, "source")
            let target = try Self.nonEmptyStringArg(arguments, "target")
            let strokeIds = try Self.optionalStringArrayArg(arguments, "strokeIds") ?? []
            let textIds = try Self.optionalStringArrayArg(arguments, "textIds") ?? []
            let imageIds = try Self.optionalStringArrayArg(arguments, "imageIds") ?? []
            guard source != target else { return Self.errorResult("invalidArguments") }
            guard !(strokeIds.isEmpty && textIds.isEmpty && imageIds.isEmpty) else { return Self.errorResult("invalidArguments") }

            guard let sourceBytes = await manager.currentBytesOrFetch(docId: source) else { return Self.errorResult("sourceNotFound") }
            guard let targetBytes = await manager.currentBytesOrFetch(docId: target) else { return Self.errorResult("targetNotFound") }

            let count = strokeIds.count + textIds.count + imageIds.count
            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("copyElements"),
                    "source": .string(sourceBytes.base64EncodedString()),
                    "strokeIds": .array(strokeIds.map(Value.string)),
                    "textIds": .array(textIds.map(Value.string)),
                    "imageIds": .array(imageIds.map(Value.string)),
                ]))
            } catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: target, docBytes: targetBytes, spec: spec, capability: "copyElements")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // expectedBytes is targetBytes — the exact bytes relayed to the
            // device — never a fresh re-read here, which would re-open the
            // very race window this guard exists to close (Task 2, write CAS).
            return await submitAndRespond(
                docId: target, createIfMissing: false, fullDoc: out.bytes, expectedBytes: targetBytes
            ) { seq in
                // `out.meta` carries the created elements' fresh keys/ids
                // (`CopyElements.perform`'s `{"createdStrokeKeys": […],
                // "createdTextIds": […], "createdImageIds": […]}`, app repo)
                // — surfaced here the same way draw_strokes surfaces `ids:`,
                // so the agent can act on exactly what was just copied
                // instead of re-finding it by bounding box. A missing/
                // undecodable meta degrades to just the seq line.
                var summary = "copied \(count) element(s) from \(source) into \(target) at seq \(seq)"
                if let meta = out.meta,
                   let decoded = try? JSONDecoder().decode([String: [String]].self, from: meta) {
                    if let keys = decoded["createdStrokeKeys"], !keys.isEmpty {
                        summary += "\nstrokeIds: \(keys.joined(separator: ", "))"
                    }
                    if let ids = decoded["createdTextIds"], !ids.isEmpty {
                        summary += "\ntextIds: \(ids.joined(separator: ", "))"
                    }
                    if let ids = decoded["createdImageIds"], !ids.isEmpty {
                        summary += "\nimageIds: \(ids.joined(separator: ", "))"
                    }
                }
                return summary
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
    /// 2026-07-14; snap_points since the grid-snapping spec, 2026-07-14;
    /// get/transform_selection and select_all/select_elements/
    /// set_reference_point/clear_selection since the agent-selection-control
    /// spec; merge_docs since the agent-merge-docs spec). UNLIKE `create_doc`
    /// (whose `.requestInFlight` publishes
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

    /// Shared submit tail for every write tool (add/edit/remove_text — plain
    /// AND styled, replace_doc, create_doc, draw/delete_strokes): opens a session on demand,
    /// writes the composed full-document bytes, and shapes the MCP result —
    /// success names the assigned seq (carried back by the write itself in
    /// `SubmitOutcome.accepted` — NEVER read back via a separate
    /// `liveInfo()` hop, which a racing concurrent write to the same doc
    /// could have bumped past this write's own seq before the read ran),
    /// `.rejected` becomes a tool error carrying the server's reason
    /// verbatim — this is also how a stale `expectedBytes` (Task 2, write
    /// CAS) or an expect-absent violation (Task 3, create CAS) surfaces:
    /// `docChangedDuringOp` / `docExists` flow through unchanged, no separate
    /// mapping needed.
    ///
    /// `expectedBytes` MUST be the exact bytes the caller already
    /// read/relayed for this write — never a fresh re-read taken here, which
    /// would just re-open the very race window this guard exists to close.
    /// `nil` means unconditional. As of Task 3, no call site actually passes
    /// `nil` here any more — `create_doc` and the missing-doc branch of
    /// `replace_doc` call the `expectation:` overload below directly with
    /// `.absent` instead, so `nil`/unconditional stays reachable through this
    /// overload only in principle, for any future caller that has a genuine
    /// reason to skip the guard.
    ///
    /// DELIBERATELY NOT DEFAULTED (Task 2 review, M1): a write tool added
    /// tomorrow that simply forgets the parameter would otherwise compile,
    /// ship, and write unconditionally — silently reopening this plan's data
    /// loss. Required means the compiler, not a test, is the guard; every
    /// call site must state its expectation, `nil` included.
    ///
    /// This `expectedBytes:` form is a convenience wrapper over the general
    /// `expectation:` form below (`nil` -> `.none`, `some` -> `.matchBytes`)
    /// kept so the existing write tools (draw_strokes/add_text/etc.) compile
    /// unchanged and stay behavior-identical. `create_doc`/`replace_doc` were
    /// flipped to call the `expectation:` overload directly with `.absent`
    /// (Task 3) — see `callCreateDoc`/`callReplaceDoc` above.
    private func submitAndRespond(
        docId: String, createIfMissing: Bool, fullDoc bytes: Data,
        expectedBytes: Data?, successText: (Int) -> String
    ) async -> CallTool.Result {
        await submitAndRespond(
            docId: docId, createIfMissing: createIfMissing, fullDoc: bytes,
            expectation: expectedBytes.map(WriteExpectation.matchBytes) ?? .none,
            successText: successText
        )
    }

    /// General form: any `WriteExpectation` (`.none` / `.matchBytes` /
    /// `.absent`). `.absent` is what lets a create-path tool assert "this
    /// document must not already exist" atomically (Task 2) instead of the
    /// read-then-check-then-write race a manual `docExists` pre-check leaves
    /// open — see `DocumentSession.submit`'s `.absent` branch for where the
    /// guard actually lives (same actor turn as `store.save`).
    /// `recordForUndo: false` is for the UNDO's own write. Recording it would make a second
    /// `undo_last_edit` reverse the FIRST UNDO rather than walk one edit further back — turning
    /// repeated undo into a ping-pong, which contradicts the one-undo-is-one-tool-call model.
    /// (Found by testing, not by design: the spec originally claimed recording it gave redo for
    /// free. It does, at the cost of the primary behaviour, so it does not.)
    private func submitAndRespond(
        docId: String, createIfMissing: Bool, fullDoc bytes: Data,
        expectation: WriteExpectation, recordForUndo: Bool = true, successText: (Int) -> String
    ) async -> CallTool.Result {
        let opId = "mcp-\(UUID().uuidString)"
        let payload = OpPayload(type: "fullDoc", data: bytes)
        switch await manager.submitOpeningSession(
            docId: docId, createIfMissing: createIfMissing, opId: opId, payload: payload,
            expectation: expectation
        ) {
        case .accepted(let seq):
            // Record what this tool call changed, so `undo_last_edit` can take it back. HERE and
            // not in `DocumentSession.submit`: that is shared with the app's own settle-push, and
            // recording those would let an undo revert the USER's drawing. `expectation` already
            // carries the pre-write bytes for the byte-CAS, so nothing extra is read or computed.
            if recordForUndo, case .matchBytes(let before) = expectation {
                await history.record(docId: docId, before: before, after: bytes)
            }
            return CallTool.Result(content: [.text(text: successText(seq), annotations: nil, _meta: nil)])
        case .rejected(let message):
            guard case .reject(_, _, let reason, _) = message else {
                return Self.errorResult("unexpectedServerResponse")
            }
            return Self.errorResult(reason)
        }
    }

    /// `undo_last_edit` — take back the agent's own last write (spec 2026-07-28-agent-undo-design).
    private func callUndoLastEdit(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let steps = try Self.optionalIntArg(arguments, "steps") ?? 1
            guard steps >= 1 else { return Self.errorResult("invalidArguments") }
            guard await manager.currentBytesOrFetch(docId: docId) != nil else {
                return Self.errorResult("unknownDoc")
            }

            var undone = 0
            var lastSeqText = ""
            for _ in 0..<steps {
                guard let entry = await history.mostRecent(docId: docId) else {
                    // Some steps may already have landed; say how far it got rather than
                    // pretending the whole call failed.
                    if undone > 0 { break }
                    return Self.errorResult("nothingToUndo: no recorded edit for \"\(docId)\"")
                }
                guard let current = await manager.currentBytesOrFetch(docId: docId) else {
                    return Self.errorResult("unknownDoc")
                }

                let restored: Data
                if current == entry.after {
                    // Nothing has changed since. A three-way merge with `mine == base` resolves to
                    // `theirs` for every element and every field — which is `before` exactly — so
                    // this IS the merge's own answer, computed without a device round trip. It is
                    // what keeps undo working with no device connected in the common case.
                    // Pinned by `AgentUndoMergeTests` in the app repo.
                    restored = entry.before
                } else {
                    // Genuinely contended: reverse the agent's change while keeping whatever
                    // happened since. Needs the app — `DocMergeEngine` is where PencilKit is.
                    switch await revertMerge(docId: docId, base: entry.after, mine: current,
                                             theirs: entry.before) {
                    case .merged(let merged): restored = merged
                    case .failed(let result): return result
                    }
                }

                let result = await submitAndRespond(
                    docId: docId, createIfMissing: false, fullDoc: restored,
                    expectation: .matchBytes(current), recordForUndo: false
                ) { seq in "seq \(seq)" }
                if result.isError == true { return result }
                // Consumed only once the undo has actually landed, so a rejected write or an
                // unreachable device leaves the history intact and the agent can try again.
                await history.consumeMostRecent(docId: docId)
                undone += 1
                for content in result.content {
                    if case .text(let text, _, _) = content { lastSeqText = text }
                }
            }
            return Self.textResult("undid \(undone) edit(s) in \(docId) at \(lastSeqText)")
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// The contended path: hand all three versions to the device and let `DocMergeEngine` reverse
    /// the agent's change without discarding what landed since.
    enum RevertOutcome {
        case merged(Data)
        /// The device could not be reached or refused — surfaced verbatim to the caller.
        case failed(CallTool.Result)
    }

    private func revertMerge(docId: String, base: Data, mine: Data, theirs: Data)
        async -> RevertOutcome
    {
        let spec: Data
        do {
            spec = try JSONEncoder().encode(Value.object([
                "op": .string("revertMerge"),
                "base": .string(base.base64EncodedString()),
                "theirs": .string(theirs.base64EncodedString()),
            ]))
        } catch { return .failed(Self.errorResult("invalidArguments")) }

        do {
            // `mine` rides as the request's docBytes, the shape every relayed op already uses.
            let out = try await broker.requestStrokeOp(docId: docId, docBytes: mine, spec: spec,
                                                       capability: "mergeDocs")
            return .merged(out.bytes)
        } catch let error as DeviceCommandBroker.DeviceCommandError {
            return .failed(Self.strokeOpErrorResult(error))
        } catch {
            return .failed(Self.errorResult("deviceFailed: \(error)"))
        }
    }

    private static func reason(for error: DocJSON.DocJSONError) -> String {
        switch error {
        case .invalidDocumentJSON: return "invalidDocumentJSON"
        case .textNotFound: return "textNotFound"
        case .imageNotFound: return "imageNotFound"
        case .elementNotFound: return "elementNotFound"
        case .invalidColor: return "invalidSpec"
        }
    }

    /// `list_open_docs` — the answer to "which document am I actually talking to?", which agents
    /// were guessing at from conversation (spec 2026-07-27-list-open-docs-design.md).
    ///
    /// Everything here is already in hand: `liveInfo()` for the sessions and the broker summary
    /// for the devices. No device round trip, so it stays cheap enough to call before anything
    /// else — which is the point, since the failure it prevents is aiming a whole batch of writes
    /// at a name no session answers to.
    ///
    /// OPEN means a session with at least one subscriber. A session with none exists whenever any
    /// server-side tool has touched a document, and listing those would answer the question with
    /// documents nobody has on screen — the opposite of useful.
    /// `transform_elements` — geometry for every element kind, on a document that need not be open
    /// (2026-07-28 usage-session finding 6). Relays the whole argument set verbatim; the device
    /// validates, exactly as `draw_strokes` does with its stroke specs.
    private func callTransformElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            guard let bytes = await manager.currentBytesOrFetch(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var envelope: [String: Value] = ["op": .string("transformElements")]
            for key in ["strokeIds", "textIds", "imageIds", "translate", "scale", "rotate", "anchor"] {
                if let value = arguments?[key], !value.isNull { envelope[key] = value }
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(envelope)) }
            catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec,
                                                       capability: "transformElements")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: bytes
            ) { seq in "transformed elements in \(docId) at seq \(seq)" }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `list_docs` — what documents exist at all (2026-07-28 usage-session finding 1).
    ///
    /// The information was already here, but only as the `infsketch://docs` RESOURCE, which is a
    /// separate mechanism a client may surface weakly or not at all. So every tool took a `docId`
    /// while no TOOL could tell you one, and the tool-shaped way to discover a document was to
    /// guess wrong and read `unknownDoc`'s listing. This is that listing, asked for on purpose.
    private func callListDocs() async -> CallTool.Result {
        let entries: [DocListEntry]
        do { entries = try await manager.listDocuments() }
        catch { return Self.errorResult("internalError: could not list documents") }

        // Which of them a device actually has on screen — the first thing you want to know after
        // "what is there", and free here (the same in-memory read `list_open_docs` does).
        let live = await manager.liveInfo()
        let payload = entries
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map { entry -> [String: Any] in
                [
                    "id": entry.id,
                    "sizeBytes": entry.sizeBytes,
                    "modifiedAt": ISO8601DateFormatter().string(from: entry.modifiedAt),
                    "hasContent": entry.hasContent,
                    "open": (live[entry.id]?.subscriberCount ?? 0) > 0,
                ]
            }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return Self.errorResult("internalError: could not encode the document listing")
        }
        return Self.textResult(text)
    }

    private func callListOpenDocs() async -> CallTool.Result {
        let (deviceCount, capabilities) = await broker.connectionSummary()
        let open = await manager.liveInfo()
            .filter { $0.value.subscriberCount > 0 }
            .map { (docId, info) in
                ["docId": docId, "seq": info.seq, "subscribers": info.subscriberCount] as [String: Any]
            }
            .sorted { ($0["docId"] as? String ?? "") < ($1["docId"] as? String ?? "") }

        let payload: [String: Any] = [
            "devices": ["count": deviceCount, "capabilities": capabilities.sorted()],
            "openDocs": open,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return Self.errorResult("internalError: could not encode the open-document listing")
        }
        return Self.textResult(text)
    }

    private static func errorResult(_ reason: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: reason, annotations: nil, _meta: nil)], isError: true)
    }

    /// A plain non-error text result. Every other success path in this file builds this shape
    /// inline (`CallTool.Result(content: [.text(text: ..., annotations: nil, _meta: nil)])`);
    /// `fetch_doc` is the first handler simple enough to want a named helper for it.
    private static func textResult(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
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

    /// An optional whole-number argument. Accepts an integer, or a double that IS one (a client
    /// that JSON-encodes `1` as `1.0` means 1); anything else is the caller's mistake.
    private static func optionalIntArg(_ arguments: [String: Value]?, _ key: String) throws -> Int? {
        guard let value = arguments?[key], !value.isNull else { return nil }
        if let int = value.intValue { return int }
        if let double = value.doubleValue, double.rounded() == double, double.magnitude < 1e9 {
            return Int(double)
        }
        throw ArgumentError.invalidType(key)
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

    /// A required Bool argument — mirrors `boolArg` but throws `.missing` when
    /// absent/null instead of returning a default (set_pinned's `pinned` has no
    /// sensible default).
    private static func requiredBoolArg(_ arguments: [String: Value]?, _ key: String) throws -> Bool {
        guard let value = arguments?[key], !value.isNull else { throw ArgumentError.missing(key) }
        guard let b = Bool(value) else { throw ArgumentError.invalidType(key) }
        return b
    }

    /// An optional Bool argument — `nil` when absent/null (so a caller can
    /// distinguish "not supplied" from an explicit `false`), `.invalidType` on a
    /// non-bool. (set_paper's `transparent` is present-only.)
    private static func optionalBoolArg(_ arguments: [String: Value]?, _ key: String) throws -> Bool? {
        guard let value = arguments?[key], !value.isNull else { return nil }
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

    /// An optional JSON array argument, returned as raw `Value`s — mirrors
    /// `nonEmptyValueArrayArg`, but `nil` when the key is absent/null rather
    /// than an error, and an empty array is not rejected. Used by
    /// `duplicate_selection`'s `ops`: omitted means a provisional in-place
    /// copy (device-side), so unlike `transform_selection`/`preview_selection`
    /// there is no required, non-empty `ops`.
    private static func optionalValueArrayArg(_ arguments: [String: Value]?, _ key: String) throws -> [Value]? {
        guard let value = arguments?[key], !value.isNull else { return nil }
        guard case .array(let items) = value else { throw ArgumentError.invalidType(key) }
        return items
    }

    /// A non-empty JSON array argument whose elements must all be strings
    /// (`delete_strokes`'s `ids`).
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

    /// An optional JSON array argument whose elements must all be strings,
    /// returning `nil` when the key is absent/null — mirrors
    /// `optionalStringArg`, but for arrays. Used by `select_elements`'s
    /// `strokeIds`/`textIds`/`imageIds`: each rides into the op-spec
    /// envelope only when the caller actually supplied it (unlike
    /// `nonEmptyStringArrayArg`, an empty array is not rejected here — the
    /// device enforces "at least one id across all three arrays").
    private static func optionalStringArrayArg(_ arguments: [String: Value]?, _ key: String) throws -> [String]? {
        guard let value = arguments?[key], !value.isNull else { return nil }
        guard case .array(let items) = value else { throw ArgumentError.invalidType(key) }
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
