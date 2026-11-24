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
    /// Where `render_sketch(writeToFile: true)` puts its PNGs, or nil when this server has no
    /// render directory (the store-injecting init used by tests). A render is still perfectly
    /// serviceable without one — it just comes back inline, which is the default anyway.
    private let renderFileStore: RenderFileStore?
    /// Told of every tool call (`AgentWork`); nil where a test builds the adapter alone.
    private let agentWork: AgentWork?
    /// What each agent tool call changed, so `undo_last_edit` can take one back. Deliberately NOT
    /// on `DocumentSession` — see the type's own doc comment for why agent scope has to hold by
    /// construction here rather than by a flag inside `submit`.
    private let history = AgentEditHistory()
    /// Where a NEW document's id comes from. Injectable only so a test can force a collision —
    /// the one way to see a create the store refuses (`AgentDocRefTests.aRejectedCreateLeavesNoLabel`).
    private var mintDocumentId: @Sendable () -> String = DocumentIdentity.newId
    /// Names a create is in the middle of claiming (`create_doc`, `replace_doc`'s create branch,
    /// `merge_docs into:`). The name check and the write are seconds apart across a device round
    /// trip, so without this two concurrent creates of one name would both pass the check.
    private var namesBeingCreated: Set<String> = []
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

    func setDocumentIdMinterForTesting(_ mint: @escaping @Sendable () -> String) {
        mintDocumentId = mint
    }

    public init(
        manager: SessionManager,
        idleTimeout: Duration = .seconds(3600),
        cleanupInterval: Duration = .seconds(60),
        broker: DeviceCommandBroker,
        renderFileStore: RenderFileStore? = nil,
        agentWork: AgentWork? = nil
    ) {
        self.manager = manager
        self.idleTimeout = idleTimeout
        self.cleanupInterval = cleanupInterval
        self.broker = broker
        self.renderFileStore = renderFileStore
        self.agentWork = agentWork
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

    // MARK: - Request validation

    /// The SDK's default pipeline with its `Host` check removed, so an agent on ANOTHER MACHINE
    /// can reach `/mcp` — the whole point of a server that already advertises itself on the LAN
    /// for devices.
    ///
    /// `StatefulHTTPServerTransport` defaults to `OriginValidator.localhost()`, which allows only
    /// `127.0.0.1`, `localhost` and `[::1]` in the `Host` header. That is DNS-rebinding protection:
    /// it stops a WEB PAGE the user visits from scripting a server bound to their own loopback.
    /// It is NOT access control, and it never was — a direct client simply sends the header it
    /// likes, which is how this was diagnosed (the same LAN request succeeded with `Host` set to
    /// `127.0.0.1`). So what it actually bought here was refusing honest remote agents while
    /// stopping no attacker who had already reached the port.
    ///
    /// **The four remaining validators are the SDK's own defaults, restated because passing a
    /// pipeline REPLACES the whole thing rather than amending it.** Dropping one by accident would
    /// not fail any MCP call — the transport would merely be more permissive — so
    /// `MCPHostAccessTests.theOtherDefaultValidatorsSurvive` asserts each still refuses what it is
    /// for. Re-check this list when the SDK is updated.
    ///
    /// This server has NO AUTHENTICATION, so anything that can reach the port now gets the full
    /// tool surface, `delete_doc` included. That is the same exposure the device sync port has
    /// always had, and it is a deliberate development-tool trade — do not add auth here without
    /// deciding what it means for the app's own connection too.
    static let validationPipeline = StandardValidationPipeline(validators: [
        AcceptHeaderValidator(mode: .sseRequired),
        ContentTypeValidator(),
        ProtocolVersionValidator(),
        SessionValidator(),
    ])

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
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: newSessionID),
            validationPipeline: Self.validationPipeline)
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
        case .guide:
            return ReadResource.Result(contents: [
                .text(AgentGuide.markdown, uri: uri, mimeType: "text/markdown")
            ])

        case .docsList:
            let entries = try await manager.listDocuments()
            return ReadResource.Result(contents: [
                .text(try Self.jsonString(entries), uri: uri, mimeType: "application/json")
            ])

        case .docSummary(let docId):
            guard let bytes = await documentBytes(docId: docId) else {
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
            guard let bytes = await documentBytes(docId: docId) else {
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
            guard let bytes = await documentBytes(docId: docId),
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
    private static let styleArgKeys = ["color", "fontSize", "bold", "italic", "family", "weight", "spans"]

    /// The capability a text write needs: `authorText`, joined with the newer parts the call
    /// actually uses — an older app decodes an unknown key by ignoring it and answers success.
    static func textWriteCapability(_ arguments: [String: Value]?) -> String {
        func has(_ key: String) -> Bool { arguments?[key].map { !$0.isNull } ?? false }
        var parts = ["authorText"]
        if has("wordWrap") || has("wrapWidth") { parts.append("textWrap") }
        if has("layer") { parts.append("objectLayerWrites") }
        if has("placeBy") { parts.append("placeBy") }
        // A `weight`, of the whole text or of a span: an app without it would set the text
        // Regular (or by `bold`) and answer success.
        let spanHasWeight: Bool = {
            guard case .array(let spans)? = arguments?["spans"] else { return false }
            return spans.contains { span in
                guard case .object(let fields) = span, let weight = fields["weight"] else { return false }
                return !weight.isNull
            }
        }()
        if has("weight") || spanHasWeight { parts.append("textWeight") }
        return parts.joined(separator: "+")
    }

    /// True iff any style/spans argument is present (and not an explicit
    /// JSON null) — the plain-vs-styled routing decision for
    /// `callAddText`/`callEditText`.
    ///
    /// `tags` and the anchor are in the list even though they are not styles: tags live in
    /// `elementTags` and an anchor realigns the paragraphs (UIKit attributes) and needs a newer
    /// document format, none of which the server-side `DocJSON` path writes — so a tagged or
    /// anchored call must take the device path or the argument would be silently dropped.
    private static func hasStyleArgs(_ arguments: [String: Value]?) -> Bool {
        (styleArgKeys + ["tags", "anchor", "anchorParagraphs", "wordWrap", "wrapWidth", "layer", "placeBy"]).contains { key in
            guard let value = arguments?[key] else { return false }
            return !value.isNull
        }
    }

    /// Formulas (document format 7). A key the SERVER writes on both paths — never in a device's
    /// op spec, never in `hasStyleArgs`, so it does not force a device (design decision B2).
    private static let inlineMathProperty: Value = .object(["type": "boolean", "description": """
        true: every $…$ in this text is shown as a typeset formula ($$…$$ for the large form, \\$ for \
        a dollar sign); false: $ is a normal character.
        """])

    /// Word wrap, the Text Format panel's Word Wrap card as arguments. Device-relayed under
    /// `authorText+textWrap`: an app without it would ignore the keys and answer success.
    private static let textWrapProperties: [String: Value] = [
        "wordWrap": .object(["type": "boolean", "description": """
            true: wrap lines at a fixed box width — `wrapWidth`, or the width the text has now; \
            false: no wrapping, the box grows to the longest line (the default for a new text). \
            Needs a connected device.
            """]),
        "wrapWidth": .object(["type": "number", "minimum": 24, "description": """
            Wrap at this box width (turns wordWrap on), in the text's own points before its \
            transform — the space fontSize is in, so canvas points for an unscaled text. At \
            least 24, rounded to a whole point. Needs a connected device.
            """]),
    ]

    /// `styleBase` — where the style fields a call leaves out come from (`add_arrow`,
    /// `add_formula`, an ephemeral arrow of `render_sketch`). Relayed under `…+styleBase`: an app
    /// without it would ignore the key and use the user's style with a success reply.
    private static let styleBaseProperty: Value = .object([
        "type": "string", "enum": .array(["user", "factory"].map(Value.string)),
        "description": """
            Where every style field you leave out comes from. user (default): the user's own \
            current style — right when you draw beside the user. factory: the app's built-in \
            style, the same on every device whatever the user has set — right for a script, which \
            otherwise draws differently after the user changed their tool. Needs a device with \
            the `styleBase` capability.
            """,
    ])

    /// A formula's `anchor` — the point of its box that stays put when its source or size changes
    /// later. Relayed under `…+formulaAnchor`: an app without it would ignore the key and answer
    /// success with the anchor unset.
    private static let formulaAnchorProperty: Value = .object([
        "description": .string("""
            The point of the formula's box that stays put when its source or size changes             LATER: {row: "top"|"middle"|"baseline"|"bottom", column: "left"|"center"|"right"}, or             "automatic" (the default: the left end of the baseline). {row: "baseline", column:             "center"} keeps a centered formula centered when its source grows; a right column             grows to the left. It moves nothing by itself and does not say where the formula is             placed — that is `placeBy`. list_formulas reports it. Needs a device with the \
            `formulaAnchor` capability.
            """),
        "anyOf": .array([
            .object(["type": "string", "enum": .array([.string("automatic")])]),
            .object([
                "type": "object",
                "properties": .object([
                    "row": .object(["type": "string", "enum": .array(["top", "middle", "baseline", "bottom"].map(Value.string))]),
                    "column": .object(["type": "string", "enum": .array(["left", "center", "right"].map(Value.string))]),
                ]),
                "required": .array(["row", "column"].map(Value.string)),
                "additionalProperties": .bool(false),
            ]),
        ]),
    ])

    /// `placeBy` — which point of the box `canvasX` / `canvasY` name (texts and formulas). Device
    /// work: only a device knows the box. Relayed under `…+placeBy`, since an app without it
    /// would ignore the key and place by the default point with a success reply.
    private static func placeByProperty(default defaultPoint: String) -> Value {
        .object([
            "type": "object",
            "description": """
                Which point of the box `canvasX` / `canvasY` name: {row: "top"|"middle"|"bottom"| \
                "baseline", column: "left"|"center"|"right"} — {row: "top", column: "center"} \
                centers the box under the point, {row: "middle", column: "right"} ends it there. \
                `baseline` is a point ON the first line's baseline (its left end, middle or \
                right end). Default: \(defaultPoint). The box is the one the listing reports as \
                `canvasBounds`. Needs a device with the `placeBy` capability.
                """,
            "properties": .object([
                "row": .object(["type": "string", "enum": .array(["top", "middle", "bottom", "baseline"].map(Value.string))]),
                "column": .object(["type": "string", "enum": .array(["left", "center", "right"].map(Value.string))]),
            ]),
            "required": .array(["row", "column"].map(Value.string)),
            "additionalProperties": .bool(false),
        ])
    }

    /// A text's anchor — the point of its box that stays put as it grows — and what picking
    /// one does to the paragraphs' alignment; the Properties panel's anchor grid, as arguments.
    private static let textAnchorProperties: [String: Value] = [
        "anchor": .object([
            "description": """
                The point of the text box that stays put when the text grows or shrinks:                 {row: "top"|"middle"|"bottom", column: "left"|"center"|"right"}, or                 "automatic" (the default: the first line's baseline keeps its place). A                 picked anchor does not move the text; it aligns its paragraphs to the                 anchor's column (see anchorParagraphs). list_texts reports it. Needs a                 connected device.
                """,
            "anyOf": .array([
                .object(["type": "string", "enum": .array([.string("automatic")])]),
                .object([
                    "type": "object",
                    "properties": .object([
                        "row": .object(["type": "string", "enum": .array(["top", "middle", "bottom"].map(Value.string))]),
                        "column": .object(["type": "string", "enum": .array(["left", "center", "right"].map(Value.string))]),
                    ]),
                    "required": .array(["row", "column"].map(Value.string)),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "anchorParagraphs": .object([
            "type": "string",
            "enum": .array(["all", "reference", "none"].map(Value.string)),
            "description": """
                Which paragraphs take a picked anchor's column: "all" (default),                 "reference" (only the first, or the last for the bottom row) or "none". A                 single paragraph always takes it. Only with a picked anchor.
                """,
        ]),
    ]

    /// Every colour hex on this surface is LIGHT-CANONICAL (the light-appearance value —
    /// what PencilKit stores; a dark canvas renders its conversion). This call-level
    /// declaration is the one door for dark-authored colours.
    private static let colorAppearanceProperty: Value = .object([
        "type": "string",
        "enum": .array(["light", "dark"].map(Value.string)),
        "description": "The appearance this call's colour hexes were authored in. Default \"light\" — the canonical space every colour on this surface speaks. Pass \"dark\" when you picked colours for how they look on the DARK canvas; the device converts them to the stored light-canonical form.",
    ])

    /// Shared style properties for add_text/edit_text (whole-field). Colours
    /// are #RRGGBB(AA). A whole-field style is the base a `spans` entry
    /// overrides.
    private static let textStyleProperties: [String: Value] = [
        "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA. Default: the document's automatic text colour. Light-canonical (the light-appearance value); see colorAppearance."]),
        "fontSize": .object(["type": "number", "description": "Point size, 1–512. A NEW text or span without one is 17 pt."]),
        "bold": .object(["type": "boolean", "description": "The shortcut for `weight`: true is 700, false is 400."]),
        "italic": .object(["type": "boolean"]),
        "weight": .object(["type": "integer", "enum": .array([100, 200, 300, 400, 500, 600, 700, 800, 900].map { Value.int($0) }),
                           "description": "How heavy the letters are: 100 Thin, 200 Extra Light, 300 Light, 400 Regular, 500 Medium, 600 Semibold, 700 Bold, 800 Extra Bold, 900 Black. For Inter, the app's own font (a text or span without a `family`), which has all nine; with another family it fails by name — use `bold` there. It wins over `bold`. Needs a device with the `textWeight` capability."]),
        "family": .object(["type": "string", "description": "A font family name from list_fonts, or `System` for the device's own system font. An unknown family fails with unknownFont. A NEW text or span without a family is in the app's own font, Inter (`Inter Variable`): the app bundles it, so the text is laid out the same on every device. The system font is not — a Mac sets it 4 to 5 % wider than an iPad or iPhone below 20 pt, with another line height."]),
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
                    "stampSize": .object([
                        "type": "array",
                        "description": """
                            [width, height] of the point's own STAMP, both > 0 — the ink it lays \
                            down, which a transform does NOT scale. Canvas coordinates are x/y.
                            """,
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


    /// `draw_strokes`'s item: the shared stroke item plus `tags`. A candidate stroke of
    /// `render_sketch` is never written, so it takes none. The device's `StrokeSpec` has decoded
    /// `tags` since tags exist (it is how `draw_dots` and `fill_region` tag what they make).
    private static let committedStrokeItemSchema: Value = {
        guard case .object(var schema) = strokeItemSchema, case .object(var properties)? = schema["properties"]
        else { return strokeItemSchema }
        properties["tags"] = .object([
            "type": "array",
            "items": .object(["type": "string"]),
            "description": "Durable tags for this stroke, so find_elements can reach it again later (see tag_elements).",
        ])
        schema["properties"] = .object(properties)
        return .object(schema)
    }()

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
            "canvasPoints": .object([
                "type": "array",
                "description": """
                    The stroke's polyline; at least 2 points. Each point is \
                    either an [x, y] pair or a rich point object.
                    """,
                "items": pointSchema,
            ]),
            "drawnWidth": .object([
                "type": "number",
                "description": """
                    How wide the stroke DRAWS, in canvas points — the ink you see, the \
                    Properties panel's Drawn width; 5 matches a 5 pt grid. Not scaled by a \
                    later transform (canvasInkBounds shows the extent on screen). OMIT IT to \
                    inherit the width of the tool the user currently has selected (see \
                    get_tool's toolWidth).
                    """,
            ]),
            "color": .object([
                "type": "string",
                "description": "Stroke colour as #RRGGBB or #RRGGBBAA hex. OMIT IT to inherit the colour of the tool the user currently has selected in the picker (see get_tool); falls back to a paper-contrasting default when no inking tool is selected. Light-canonical (the light-appearance value); see colorAppearance.",
            ]),
            "inkType": .object([
                "type": "string",
                "enum": .array(["pen", "pencil", "marker", "monoline", "fountainPen", "watercolor", "crayon"].map(Value.string)),
                "description": """
                    The ink to draw with. OMIT IT to inherit the ink the user currently has \
                    selected (see get_tool); pen when no inking tool is selected.

                    THEY DIFFER IN CHARACTER, not only in name, and you cannot see that from a \
                    listing: `pen` is opaque and even — reach for it for solid fills, flat \
                    colour, and anything you layer; `marker` is wide and TRANSLUCENT, so colours \
                    build where strokes overlap and whatever is underneath shows through \
                    (painting a solid area in marker leaves the paper visible between passes); \
                    `pencil` is textured; `fountainPen`, `watercolor` and `crayon` are \
                    expressive — try them and look. Each ink has a thinnest width it can draw \
                    (below it a stroke is effectively INVISIBLE), so a drawnWidth under it is \
                    raised and the reply says so.

                    A pen whose width is CONSTANT is a monoline, and lists as one — including \
                    every pen you author with a single `drawnWidth`. Monoline is not a different \
                    rendered ink but a tool behaviour ("hold the width constant whatever the \
                    pressure"), PencilKit's archive records it as pen, and the app derives the name \
                    back from the uniform sizes, so `pen` with one width and `monoline` are the \
                    same stroke and read back as `monoline`. A pen reads back as `pen` only when \
                    its per-point `stampSize` varies.
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
        "required": .array(["canvasPoints"].map(Value.string)),
    ])

    private static let tools: [Tool] = [
        Tool(
            name: "add_text",
            description: """
                Appends a placed-text entry to a document: a new id, the document's current \
                colour scheme, and an identity transform/opacity. (canvasX, canvasY) is the text \
                box's top-left corner. Give color/fontSize/bold/italic/family \
                to style the WHOLE label, or a `spans` array to style parts of it independently \
                (e.g. a subscript). A whole-field style is the base each span overrides. Styling \
                needs a connected device; plain text does not. Returns the new text's id so you \
                can edit it. Colours: #RRGGBB(AA), light-canonical (see colorAppearance to \
                author for the dark canvas). Font families come from list_fonts — call it \
                before setting a `family`; without one the text is in Inter, the font the app \
                bundles, at 17 pt unless `fontSize` says otherwise, and is the same on every \
                device. `anchor` picks the point of the box that stays put \
                as the text grows, as the app's anchor grid does (needs a device). `wordWrap` / \
                `wrapWidth` wrap it at a fixed width and `layer` puts it in front of or behind the \
                strokes (both need a device). Formulas: write the LaTeX between `$…$` and set \
                `inlineMath: true` (omitted, the new text takes the document's own default); the \
                write does not report whether a formula typesets — render_sketch shows it. \
                `placeBy` says which point of the box (canvasX, canvasY) names — its top center, \
                its right middle, its baseline — so a centered or right-aligned label is ONE call \
                (needs a device). `anchor` does NOT do that: it never moves the text.

                REPLY: a line "added … at seq N" and a line `id: <the new text's id>`; when a \
                device laid the text out (any call with a style, tags, an anchor, wrap, a layer \
                or `placeBy`), also `canvasBounds: [left, top, width, height]`, the box as drawn. \
                A plain call is written by the server alone, which cannot measure text: pass \
                `placeBy` (e.g. {row: "top", column: "left"}, which is where it goes anyway) \
                when you need the box. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(
                    [
                        "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                        "text": .object(["type": "string", "description": "The text to place. Give `text` OR `spans`, exactly one of them."]),
                        "canvasX": .object(["type": "number", "description": "Canvas-space x of the text box's top-left corner (or of the point `placeBy` names)."]),
                        "canvasY": .object(["type": "number", "description": "Canvas-space y of the text box's top-left corner (or of the point `placeBy` names)."]),
                        "colorAppearance": colorAppearanceProperty,
                        "tags": .object([
                            "type": "array", "items": .object(["type": "string"]),
                            "description": "Durable tags for this text, so find_elements can reach it later.",
                        ]),
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
                        "layer": .object(["type": "string", "enum": .array(["front", "back"].map(Value.string)),
                                          "description": "front (above the strokes; the default) or back (behind strokes and grids). Needs a connected device."]),
                        "inlineMath": inlineMathProperty,
                        "placeBy": placeByProperty(default: "the top-left corner"),
                    ].merging(textStyleProperties) { current, _ in current }
                     .merging(textAnchorProperties) { current, _ in current }
                     .merging(textWrapProperties) { current, _ in current }
                ),
                // `text` is NOT required: a call gives `text` OR `spans`. Listed as required, a
                // client that checks its arguments against the schema could not send `spans` at
                // all (the device refuses both together). The either-or is not written as a
                // top-level `oneOf`: several clients refuse a tool whose schema has one.
                "required": .array(["docId", "canvasX", "canvasY"].map(Value.string)),
            ])
        ),
        Tool(
            name: "edit_text",
            description: """
                Mutates an existing placed text by id: replace its string and/or move it, or \
                restyle it with color/fontSize/bold/italic/family (whole-field) or a `spans` \
                array (parts of it independently — a whole-field style is the base each span \
                overrides). New characters given as `text` KEEP THE STYLE OF THE TEXT'S FIRST \
                CHARACTER (font, size, color); a text of several styles becomes one run in \
                that style, and style fields given beside `text` are set on top of it. `spans` \
                say every run's style themselves. A STYLED edit (any of \
                color/fontSize/bold/italic/family/spans present) restyles the EXISTING \
                characters (or the new ones, if `text`/`spans` is given) and needs a connected \
                device — plain edits do not. Position-only edits (canvasX \
                and/or canvasY with no text/style) do not touch formatting. Colours: \
                #RRGGBB(AA), light-canonical (see colorAppearance to author for the dark \
                canvas). Font \
                families come from list_fonts. `anchor` sets or clears ("automatic") the point \
                of the box that stays put as the text grows (needs a device); an anchored text \
                keeps that point when its characters change. `wordWrap` / `wrapWidth` turn word \
                wrap on or off and set its width (needs a device). To move a text between layers \
                use set_layer. `inlineMath` switches formulas on or off; omitted, the text keeps \
                its setting. `canvasX` / `canvasY` say where the text is SHOWN — the top-left \
                corner of its `canvasBounds`, or the point `placeBy` names — whatever transform it \
                carries (a text the user dragged, turned or scaled in the app); either alone \
                moves it along that axis. A turned or scaled text needs a device to be placed.

                REPLY: a line "edited <id> at seq N"; when a device made the edit, also \
                `canvasBounds: [left, top, width, height]`, the box as drawn after it. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(
                    [
                        "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                        "canvasX": .object(["type": "number", "description": "New canvas-space x of the text box's top-left corner as shown (or of the point `placeBy` names)."]),
                        "canvasY": .object(["type": "number", "description": "New canvas-space y of the text box's top-left corner as shown (or of the point `placeBy` names)."]),
                        "colorAppearance": colorAppearanceProperty,
                        "spans": .object([
                            "type": "array",
                            "description": """
                                Replace the text with independently-styled parts instead of a \
                                single `text` string. Same shape as add_text's `spans`. \
                                Requires a connected device.
                                """,
                            "items": textSpanItemSchema,
                        ]),
                        "inlineMath": inlineMathProperty,
                        "placeBy": placeByProperty(default: "the top-left corner"),
                    ].merging(textStyleProperties) { current, _ in current }
                     .merging(textAnchorProperties) { current, _ in current }
                     .merging(textWrapProperties) { current, _ in current }
                ),
                "required": .array(["docId", "textId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "tag_elements",
            description: """
                Give elements durable TAGS, so you can find your own work again later — the \
                strokes that make up a roof, the series of markers on a plot, the text that \
                titles a chart. Tags live in the DOCUMENT, so they outlast this task, this \
                session and this agent, which the ids returned by draw_strokes do not.

                THE POINT: with a tag you can update your own work in place (find_elements -> \
                the tools that take ids) instead of deleting and redrawing, which is what \
                destroys the user's own annotations and hand-adjusted spacing.

                Many-to-many: an element carries any number of tags and a tag covers any number \
                of elements, so overlapping sets are fine — the strokes of "sky" can also be \
                "background". `mode` is add (default), remove, or replace; `replace` with an \
                empty `tags` clears. Tags are 1-128 characters, at most 32 per element; use \
                whatever reads well ("roof", "fft.axis.h", "Achse H"). Clones inherit their \
                tags, so a duplicated roof tile is still part of the roof. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "ids": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Element ids (stroke, text, image, arrow or formula id — a formula's needs a device with the `formulas` capability). Any number.",
                    ]),
                    "tags": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "The tags to add, remove, or replace with.",
                    ]),
                    "mode": .object([
                        "type": "string", "enum": .array([.string("add"), .string("remove"), .string("replace")]),
                        "description": "add (default) / remove / replace. replace with an empty tags clears.",
                    ]),
                ]),
                "required": .array(["docId", "ids"].map(Value.string)),
            ])
        ),
        Tool(
            name: "find_elements",
            description: """
                Resolve TAGS to element ids, so you can act on them with any tool that takes \
                ids. Read-only and cheap: no document payload comes back, just ids.

                Ids come back in DOCUMENT order — strokes in drawing order, then texts, then \
                images, then arrows, then formulas — so a tagged series is returned in a stable, \
                meaningful sequence.

                `match: "all"` keeps only the elements that carry EVERY tag you name — a section \
                is "everything tagged `sheet` and `loop`". `groupBy: "kind"` answers by kind, \
                under the argument names the tools that act on elements take, so the reply can be \
                handed on to transform_elements, select_elements or copy_elements as it is. \
                Either needs a device with the `tagQueries` capability.

                A tag whose elements no longer exist is simply ABSENT from the reply rather than \
                a dangling id, so an empty answer means "those elements are gone", not "the \
                lookup failed". Tags are set with tag_elements, or at creation time by \
                draw_strokes / add_text / add_image / add_arrow / add_formula / fill_region / \
                draw_dots. Use list_tags to see what a document already has.

                REPLY: by default an OBJECT mapping each tag you asked for to an ARRAY of element \
                ids, e.g. `{"roof": ["id1", "id2"]}`. A tag with no live elements is ABSENT from \
                the object rather than present-and-empty, so check for the key before indexing \
                it. With `groupBy: "kind"` the object is `{"strokeIds": [], "textIds": [], \
                "imageIds": [], "arrowIds": [], "formulaIds": []}` — every key present, each \
                holding the matching elements of that kind.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to query."]),
                    "tags": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "The tags to resolve.",
                    ]),
                    "match": .object([
                        "type": "string", "enum": .array([.string("any"), .string("all")]),
                        "description": "any (default): an element carrying at least one of `tags`. all: only elements carrying every one of them.",
                    ]),
                    "groupBy": .object([
                        "type": "string", "enum": .array([.string("tag"), .string("kind")]),
                        "description": "tag (default): `{tag: [ids]}`. kind: `{strokeIds, textIds, imageIds, arrowIds, formulaIds}`.",
                    ]),
                ]),
                "required": .array(["docId", "tags"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_tags",
            description: """
                Every tag in a document, with how many live things carry it, split by family. \
                Read-only.

                This is how you pick up work you did earlier: the ids you were handed are gone, \
                and guessing a tag is indistinguishable from the tag having been deleted. Start \
                here, then find_elements to turn a tag into ids.

                READ THE `grids` COUNT. Grids carry tags too, but find_elements returns ELEMENT \
                ids only and never a grid — so a tag with `grids` above zero has a lattice in it \
                that resolving the tag will not hand you. Read it back from list_grids, and \
                change it with update_grid.

                REPLY: an OBJECT mapping each tag to `{"elements": N, "grids": M}` — live \
                elements and grids carrying it, e.g. `{"roof": {"elements": 7, "grids": 0}, \
                "elevation": {"elements": 12, "grids": 1}}`. `{}` means nothing is tagged yet.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to query."]),
                ]),
                "required": .array([.string("docId")]),
            ])
        ),
        Tool(
            name: "transform_elements",
            description: """
                Move, scale or rotate named strokes, texts, images, arrows (`arrowIds`) AND formulas \
                (`formulaIds`) together — on ANY document, \
                open or not. This is how you reposition a placed image: transform_strokes takes \
                strokes only, and edit_text can move a text but not turn or resize it, so before \
                this an image could be named, pinned, reordered, copied and deleted but never \
                nudged without the document being open and a live selection running.

                Ops are named, never a raw matrix, and mean exactly what they mean on \
                transform_strokes: `scale` then `rotate`, both about `anchor`, then `translate`. \
                `anchor` defaults to the centre of the whole set's bounding box across all three \
                kinds. Identity survives — a stroke keeps its id and its width-edit history, texts \
                and images keep theirs; this is a MOVE, not a copy.

                An ARROW is baked: its points move; a `scale` changes its drawnWidth only when its \
                `keepsWidth` is false (list_arrows reports both afterwards — `drawnWidth` and \
                `unscaledWidth`); with keepsWidth true (the default) width, heads and dashes stay. \
                ATOMIC: every id must resolve or nothing moves, so a set can never end up sheared \
                half-way. Use transform_strokes when you want grid snapping (`snapToGrid` / \
                `snapTo`), which is stroke-lattice specific and stays there. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                    "arrowIds": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Arrow ids, as returned by list_arrows. An arrow's transform is baked into its points, so its heads never skew. A scale changes its WIDTH only when the arrow's `keepsWidth` is false (list_arrows reports it; true by default, so a scaled arrow keeps its width).",
                    ]),
                    "formulaIds": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Formula ids, as returned by list_formulas. Needs a device with the `formulas` capability.",
                    ]),
                    "canvasTranslate": .object([
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
                    "canvasAnchor": .object([
                        "type": "array", "items": .object(["type": "number"]),
                        "description": "[x, y]. Defaults to the centre of the whole set's bounding box.",
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "reset_element_transforms",
            description: """
                Put placed texts, images and formulas back to their ORIGINAL SIZE, unrotated and unskewed, \
                WHERE THEY ARE — the agent door onto the app's "Reset image transforms" and \
                "Reset text transforms" selection-menu items, and the same implementation, so the \
                two cannot disagree. An image keeps its CENTER where it is shown; a text keeps its \
                ANCHOR point (the `anchor` list_texts reports, or the automatic one on its first \
                baseline); a formula keeps the left end of its baseline (`formulaIds` need a \
                device with the `formulas` capability). Only the transform changes — content, style, anchor and wrap width stay. \
                Works on any document, open or not.

                ATOMIC: every id must resolve or nothing is reset. When every named element is \
                already untransformed (a plain move at most), NOTHING is written and the reply \
                says so. Strokes are not touched: to undo a stroke's scaled ink width use \
                restore_stroke_widths, and to move or turn anything use transform_elements. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "textIds": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Placed-text ids, as returned by list_texts.",
                    ]),
                    "imageIds": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Placed-image ids, as returned by list_images.",
                    ]),
                    "formulaIds": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Formula ids, as returned by list_formulas.",
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
                connected device; an unchanged document does not. There is no redo: calling this \
                again takes back the edit before that one, never the undo itself. History is \
                bounded and in memory, so a much older edit answers `nothingToUndo`. If a \
                multi-step undo fails part-way, the error says how many steps had already landed.

                A change made through the user's live selection (transform_selection, \
                duplicate_selection, delete_selection, draw_selection, restyle_selection) commits \
                in the app and cannot be taken back here: an undo that reaches one refuses with \
                `lastEditWasLiveSelection` rather than reverse an older write beneath it.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to undo an edit in."]),
                    "steps": .object([
                        "type": "integer",
                        "description": "How many of your own edits to take back, newest first. Default 1.",
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "draw_dots",
            description: """
                Draw solid round dots — junction dots on a schematic, plotted data points, \
                bullets, the centre of a pivot. Each dot is ONE stroke you can select, name, \
                move, restyle or delete as a single thing.

                `diameter` is what you would measure on the canvas, ink included, and defaults \
                to 8. It is honoured exactly for any dot bigger than the ink can draw as a line; \
                a smaller one is raised to that minimum and the reply says which.

                Do NOT fake a dot with a short wide stroke: round caps at each end of a segment \
                make a STADIUM (length + width) × width, which is visibly oval at the sizes a \
                dot is used at. Each dot's `color` is light-canonical; pass \
                colorAppearance: "dark" if you picked it for the dark canvas — the reply's \
                storedColors array (one entry per created dot, present only when the dark door \
                was used) reports what was actually stored. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "colorAppearance": colorAppearanceProperty,
                    "dots": .object([
                        "type": "array",
                        "description": "The dots to draw.",
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "canvasX": .object(["type": "number", "description": "Centre x, canvas coordinates."]),
                                "canvasY": .object(["type": "number", "description": "Centre y, canvas coordinates."]),
                                "diameter": .object([
                                    "type": "number",
                                    "description": "Outer diameter on the canvas, ink included. Default 8.",
                                ]),
                                "color": .object([
                                    "type": "string",
                                    "description": "#RRGGBB or #RRGGBBAA. Omit to inherit the user's pen. Light-canonical (the light-appearance value); see colorAppearance.",
                                ]),
                                "inkType": .object([
                                    "type": "string",
                                    "description": """
                                        Default pen, which is opaque and even. marker is \
                                        TRANSLUCENT, so a dot drawn with it shows a darker core \
                                        where the centre and the rim overlap.
                                        """,
                                ]),
                                "tags": .object([
                                    "type": "array", "items": .object(["type": "string"]),
                                    "description": "Durable tags, so find_elements can reach this again later.",
                                ]),
                            ]),
                            "required": .array([.string("canvasX"), .string("canvasY")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("docId"), .string("dots")]),
            ])
        ),
        .init(
            name: "fill_region",
            description: """
                Fill a closed path with a solid area — one call instead of the hundreds of \
                closely spaced strokes you would otherwise compute yourself. The strokes are \
                generated on the device and are ORDINARY strokes: the user can erase part of the \
                fill, select inside it, restyle it, and it ink-adapts on a dark/light flip, \
                exactly like anything they drew. Being strokes, a fill lies BELOW every arrow, \
                text and formula: for a face that must cover a line, or one flat color at any \
                size with an exact edge, place an object instead (add_shape, or add_arrow with \
                `closed` and `filled`).

                `canvasPoints` is the boundary in canvas coordinates, closed by repeating the \
                first point (an unclosed path is closed for you). Concave shapes fill correctly, \
                and a path that returns through itself leaves a hole rather than blocking it out.

                `inkType` defaults to **pen** on purpose: marker is TRANSLUCENT and builds up \
                where passes overlap, so a fill made from it shows the paper through. \
                `spacingRatio` at or below 1 makes a SOLID fill (default 0.4, which overlaps by \
                more than mere coverage so the fill stays even when the canvas is zoomed out or \
                exported small); above 1 you get visible hatching, the distance between hatch \
                lines being spacingRatio × drawnWidth, and `angleDeg` turns the hatch.

                A SOLID fill is ONE stroke: the passes are joined into a serpentine, so you can \
                select, name, restyle or move the filled area as a single thing. It also traces \
                its own boundary, centred, at the same `drawnWidth` — that border is what you see \
                at the edge. Pass `border: false` when part of your outline is construction rather \
                than a real edge (a silhouette closed along a base line does not want that line \
                drawn) — but note it is ALL OR NOTHING: with it off, EVERY edge shows the \
                scalloping the round pass-ends leave, not just the construction one. Measured: a \
                plain rectangle drawn with border:false has visibly wavy sides. If only one edge \
                is construction, keep the border and cover that edge, or draw the edges you want \
                yourself with draw_strokes.

                A THIN FILL SHOWS STRIPES IN A SMALL IMAGE. The passes are ink, and ink thinner \
                than about 3 points is not rendered flat below about 2 pixels per canvas point — \
                a zoomed-out canvas, an export of a whole sheet. Measured on a 140 × 120 fill: \
                `drawnWidth: 1` is ruled with stripes at 1.5 to 2 px/pt and a fifth too faint at 1 \
                px/pt, however dense its passes (`spacingRatio` does not help); `drawnWidth: 3` \
                is flat from 1.5 px/pt up, and at every scale looked at from 3 px/pt both are. So \
                fill a face with `drawnWidth` 3 or more — and count on the ink reaching HALF ITS \
                WIDTH past the outline you give, since the border is centred on it: draw the \
                outline that much smaller where the edge has to be exact. The reply says so when \
                a solid fill is thinner.

                TWO HONEST LIMITS. The document still carries every stroke, so a large fill is \
                genuinely large — the reply tells you how many were made, and past 4 000 passes \
                the call fails and names the spacing that would fit rather than handing back a \
                half-filled shape. And a fill does not RESHAPE: move, scale, rotate and restyle \
                all take the fill and its border together, because they are one stroke, but \
                changing the boundary to a different SHAPE does not re-fill it. You hold the \
                outline, so give the fill a `name` and reshape it by deleting it and filling the \
                new outline under that same name. `color` is light-canonical; pass \
                colorAppearance: "dark" if you picked it for the dark canvas — the reply's \
                storedColors array (one entry per pass/border stroke, present only when the \
                dark door was used) reports what was actually stored. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "colorAppearance": colorAppearanceProperty,
                    "canvasPoints": .object([
                        "type": "array",
                        "description": "The boundary, in canvas coordinates; at least 3 points.",
                        "items": .object([
                            "type": "array", "items": .object(["type": "number"]),
                            "minItems": 2, "maxItems": 2,
                        ]),
                    ]),
                    "tags": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": """
                            Durable tags for the filled area, so you can find it again with \
                            find_elements after this call's ids are gone — which is how you \
                            reshape a fill: delete it and fill the new outline under the same \
                            tag. A hatched fill gets them too: it is several strokes, and a tag \
                            is a set.
                            """,
                    ]),
                    "color": .object([
                        "type": "string",
                        "description": "#RRGGBB or #RRGGBBAA. Omit to inherit the user's pen. Light-canonical (the light-appearance value); see colorAppearance.",
                    ]),
                    "drawnWidth": .object([
                        "type": "number",
                        "description": "How wide each pass and the border DRAW, in canvas points (the Properties panel's Drawn width). Omit to inherit the user's pen. A hatch's spacing is spacingRatio × this.",
                    ]),
                    "inkType": .object([
                        "type": "string",
                        "enum": .array(["pen", "pencil", "marker", "monoline", "fountainPen", "watercolor", "crayon"].map(Value.string)),
                        "description": "Defaults to pen, which is opaque and even. A constant-width pen IS a monoline and lists as `monoline` (the app derives the name from the uniform sizes; PencilKit's archive records it as pen), so a fill lists as `monoline` whichever of the two you ask for.",
                    ]),
                    "spacingRatio": .object([
                        "type": "number",
                        "description": "At or below 1 a solid fill (default 0.4; lower is denser); above 1 hatching, lines spacingRatio × drawnWidth apart.",
                    ]),
                    "angleDeg": .object([
                        "type": "number",
                        "description": "Direction of the passes; 0 is horizontal.",
                    ]),
                    "edge": .object([
                        "type": "string", "enum": .array(["centered", "inside"].map(Value.string)),
                        "description": "Where the ink ends. \"centered\" (default): border and pass ends are centred on canvasPoints, so the ink reaches half a drawnWidth past it. \"inside\": the region is first shrunk by half a drawnWidth, so the ink ends ON canvasPoints — a face filled with wide passes (drawnWidth 3 or more renders flat at any scale) then stays inside its outline. Its OUTWARD corners come out rounded by half the width, since a round pen cannot reach into a corner (a sharp-cornered face is add_shape's). A region narrower than drawnWidth has nothing left inside and is refused.",
                    ]),
                    "border": .object([
                        "type": "boolean",
                        "description": """
                            Trace the boundary, centred on it, at drawnWidth. Default true — it \
                            covers the scalloped edge the round pass-ends leave. Set FALSE when \
                            part of your boundary is CONSTRUCTION rather than a real edge: a \
                            mountain silhouette closed along a base line does not want that base \
                            line drawn across the picture.
                            """,
                    ]),
                ]),
                "required": .array(["docId", "canvasPoints"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_docs",
            description: """
                Every document on the server: `{id, name, sizeBytes, modifiedAt, createdAt, \
                hasContent, open}`, newest-modified first. START HERE when you do not already have a docId — \
                every other tool takes one, and this is the tool that tells you what they are. \
                `id` is the document; `name` is its label, which two documents may share. Every \
                tool accepts the id, or the name when no other document has it.

                `open` means a device has it on screen right now, so your writes land live on the \
                user's canvas; use list_open_docs when you want the device and capability detail \
                as well. `hasContent: false` means the bytes live on a device rather than here — \
                every content tool fetches those for you automatically, or call fetch_doc to pull \
                one explicitly. An empty list means the server holds no documents at all. \
                `createdAt` is when this server first stored the document — its creation, for one \
                made through this server; it is ABSENT for a document the server held before it \
                kept that record, and for one whose bytes live on a device. `modifiedAt` moves \
                when a device merely opens the document (thumbnail, viewport): to learn whether \
                its content changed, use diff_docs.

                REPLY: an ARRAY of `{id, name, sizeBytes, modifiedAt, createdAt?, hasContent, \
                open}`, newest first.
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
                needed. Returns `{devices: {count, capabilities, kinds, preferredKind?}, openDocs: [{docId, name, \
                seq, subscribers, openOn}]}` — `docId` is the document's id, `name` its label. \
                `kinds` counts the connected devices by kind (`{"mac": 1, "ipad": 1}`; "unknown" \
                for an app that does not say) and `openOn` lists the kinds that have that \
                document open. The SERVER picks the device for a call — one that has the document \
                open is preferred, and `preferredKind`, present when the server was started with \
                `--prefer-device`, names the kind that is given the work first; only \
                render_sketch and export_sketch let you ask for a kind yourself (`device`). A \
                write's structured reply says which kind did it (`device`).

                CALL THIS INSTEAD OF GUESSING WHICH DOCUMENT THE USER MEANS. The name a human \
                says may be shared by several documents (a shared name is refused \
                ambiguousName), or may be an older name the document no longer carries. \
                `openDocs` is the truth: those are the documents on a user's screen, and their \
                `docId`s are what the selection tools, and every write to an open document, \
                will accept.

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
                unknownFont. `Inter Variable` is the font the app bundles and the default of a \
                new text. A named family is laid out the same on a Mac, an iPad and an \
                iPhone; the device's own system font (`family: "System"`, not in this list) is \
                not. REQUIRES a connected device — fails with noDeviceAvailable if none \
                is connected and deviceTimeout if it doesn't respond in time. Read-only: it \
                never writes to the document, so there is no seq assigned and nothing to retry.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(["docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to query."])]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "remove_text",
            description: "Removes a placed text entry from a document by id. \(writeToolCaveats)",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "textId": .object(["type": "string", "description": "The id of the text entry to remove."]),
                ]),
                "required": .array(["docId", "textId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "add_image",
            description: """
                Place an image into a document. `path` names an image FILE ON THE MACHINE THIS \
                SERVER RUNS ON — it must be absolute (a leading ~ is expanded), and the server \
                reads it itself, so no image data passes through your context. Write a generated \
                image to a file and pass its path; do not try to inline it. \
                (canvasX, canvasY) is the placement's TOP-LEFT corner. Optional \
                canvasWidth/canvasHeight (canvas points) resize it — OMIT BOTH FOR THE IMAGE'S \
                NATURAL PIXEL SIZE, which for a photo is thousands of points across; give one to \
                preserve aspect ratio, both for exact. Optional `opacity` (0..1, default 1). \
                Requires a connected device (the image is decoded there) — noDeviceAvailable \
                otherwise. The reply names the new image's id, the canvasBounds it actually \
                occupies, and the source's pixel size, so you can size it correctly in one \
                follow-up rather than by rendering and guessing. Errors name the file: \
                imagePathNotAbsolute, imageFileNotFound, imageFileUnreadable, imageFileEmpty, \
                imageTooLarge, imageCorrupt (a truncated or damaged PNG/JPEG/GIF — this is \
                checked because no image DECODER catches it: a truncated PNG decodes to the \
                right size and renders blank). unknownDoc if the document doesn't exist.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "path": .object([
                        "type": "string",
                        "description": """
                            Absolute path to a PNG/JPEG/GIF (or anything else the device can \
                            decode) on the server's own filesystem. A leading ~ is expanded; a \
                            relative path is refused rather than resolved against a working \
                            directory you cannot see.
                            """,
                    ]),
                    "canvasX": .object(["type": "number", "description": "Canvas-space x of the placement's top-left corner."]),
                    "canvasY": .object(["type": "number", "description": "Canvas-space y of the placement's top-left corner."]),
                    "canvasWidth": .object([
                        "type": "number",
                        "description": "Canvas-point width. Omit both for the image's natural pixel size; give one to preserve aspect ratio.",
                    ]),
                    "canvasHeight": .object([
                        "type": "number",
                        "description": "Canvas-point height. Omit both for the image's natural pixel size; give one to preserve aspect ratio.",
                    ]),
                    "tags": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Durable tags for this image, so find_elements can reach it later.",
                    ]),
                    "opacity": .object(["type": "number", "description": "0..1. Defaults to 1."]),
                    "layer": .object(["type": "string", "enum": .array(["front", "back"].map(Value.string)),
                                      "description": "back (behind strokes and grids; the default for images) or front (above the strokes). Move it later with set_layer."]),
                ]),
                "required": .array(["docId", "path", "canvasX", "canvasY"].map(Value.string)),
            ])
        ),
        Tool(
            name: "set_layer",
            description: """
                Moves placed texts, images, arrows and formulas into the front object layer (above \
                the strokes) or the back one (behind strokes and grids) — the app's Layer card. \
                Each one that changes layer lands on TOP of its new layer; one already there stays \
                where it is. `ids` may mix text, image, arrow and formula ids (a formula's needs a \
                device with the `formulas` capability). A pinned image paints in \
                the pinned-images layer whatever its layer, and returns to this one when \
                unpinned (set_pinned). Atomic: an unknown id fails with elementNotFound and \
                nothing moves. REQUIRES a connected device with the objectLayerWrites \
                capability. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "ids": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Text, image, arrow and/or formula ids — a non-empty list.",
                    ]),
                    "layer": .object(["type": "string", "enum": .array(["front", "back"].map(Value.string)),
                                      "description": "front or back."]),
                ]),
                "required": .array(["docId", "ids", "layer"].map(Value.string)),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to delete."]),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "imageId": .object(["type": "string", "description": "The id of the placed image to remove."]),
                ]),
                "required": .array(["docId", "imageId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "set_pinned",
            description: """
                Sets the `pinned` flag on the named placed texts, images, arrows and/or formulas of \
                a document. `ids` may mix their ids (as returned by \
                list_texts/list_images/list_arrows/list_formulas and the add_ tools). A pinned \
                element is protected from the user's touches (move, delete, transform). A pinned \
                IMAGE also paints in the pinned-images layer, beneath everything but the paper, \
                and returns to its own layer when unpinned; a pinned text, arrow or formula stays \
                where it paints. Server-side, no device needed. Atomic: if any id isn't a text, \
                image, arrow or formula in the document it fails with elementNotFound and nothing \
                changes. \
                unknownDoc if the document doesn't exist. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "ids": .object([
                        "type": "array",
                        "description": "Ids of the placed texts/images/arrows/formulas to (un)pin — a non-empty list.",
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
                Unlike the colorAppearance door elsewhere on this surface, `light` and `dark` \
                here are each the LITERAL value for that appearance — nothing is converted \
                between them. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                Replaces a document's raw bytes wholesale, keeping its id. When no document \
                has that id or name, creates a NEW document with that name and its own id, \
                replying with JSON {docId, name, seq} — except a reference shaped like an id, \
                which is a stale id and is refused unknownDoc; a replace replies "replaced <id> at seq \
                <n>". The bytes are opaque to the server — the agent owns their validity, \
                the same trust any other writer on the network has. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to write."]),
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
                is, deviceTimeout if it doesn't respond in time. The document gets a fresh id; \
                the name you give is its label. Replies with JSON {docId, name, seq}; docExists \
                if a document already has this name.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "name": .object([
                        "type": "string",
                        "description": "The new document's name (a label; its id is minted and returned).",
                    ]),
                ]),
                "required": .array(["name"].map(Value.string)),
            ])
        ),
        Tool(
            name: "draw_strokes",
            description: """
                Draws one or more freehand strokes into a document, authored by a connected \
                InfinitySketch device. Each stroke is a list of (x, y) points in canvas \
                coordinates — the same space as add_text's x/y — plus optional width, color, \
                inkType, smooth and tags fields (tags: so find_elements reaches your strokes later). Points are a POLYLINE by default (smooth: false, \
                the default): straight segments and sharp corners, which is almost certainly \
                what you mean. Set smooth: true to have them treated as spline knots and \
                smoothly interpolated instead — useful for a curve given as a few sparse \
                points; PencilKit splines THROUGH its control points, so a sparse polyline \
                misread as knots renders as a rounded blob, not the shape you asked for. \
                (reshape_strokes defaults smooth the OPPOSITE way — verbatim by default.) \
                Other defaults for any stroke that omits them: inkType "pen", width 4, and a \
                colour that FOLLOWS THE PAPER — white on a dark document, black on a light \
                one (never a hardcoded #000000, which renders invisible on dark paper). An \
                explicit color is always honoured exactly as given, and is LIGHT-CANONICAL — \
                pass colorAppearance: "dark" when you picked colours for how they look on the \
                dark canvas; the device converts them before storing, and the reply's \
                storedColors array (one entry per created stroke, present only when the dark \
                door was used) reports what was actually stored. The result names the seq \
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "colorAppearance": colorAppearanceProperty,
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
                        // ephemeral `strokes` array via strokeItemSchema; a committed
                        // stroke also takes `tags`.
                        "items": committedStrokeItemSchema,
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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

                TWO WIDTHS, the Properties panel's own, both in canvas points: `drawnWidth` is \
                how wide the stroke draws at its widest, pressure and all (the panel's Drawn); \
                `toolWidth` is how wide its tool setting draws at nominal pressure (the panel's \
                Tool, only ever a width the dial can set) — equal for a stroke drawn at even \
                pressure within the dial's range, which covers what you author. restyle_strokes SETS either, so one read and written back leaves the \
                stroke as it was. Neither includes a transform the stroke carries, while its \
                coordinates DO — a stroke scaled up by 3 reports tripled bounds and unchanged \
                widths, and draws three times wider. To match a new stroke to such a one, call \
                get_strokes for its `localToCanvasTransform` (width × its scale is what you see), \
                or restore_stroke_widths it first.

                This tool does not report grids — render_sketch's metadata does, \
                including each grid's id (what snap_points' gridIds and transform_strokes' \
                snapTo refer to). REQUIRES a connected device — fails with \
                noDeviceAvailable if none is connected and deviceTimeout if it doesn't \
                respond in time. Returns the device's listing verbatim as text; this call \
                never writes to the document. A stroke drawn by hand with an ink outside \
                pen/pencil/marker (fountain pen, watercolour, crayon…) lists under that \
                ink's name but cannot be re-drawn with draw_strokes, whose inkType enum \
                covers only the four names above. `inkType` is the ink the stroke IS: a pen \
                whose width is constant lists as `monoline` — every pen authored with one \
                drawnWidth, and every monoline the user drew — the same name the user's \
                Layers panel shows (PencilKit's archive records monoline as pen; the app \
                derives it back from the uniform sizes).

                REPLY: an ARRAY of `{id, canvasInkBounds, canvasPathBounds, color, inkType, \
                drawnWidth, toolWidth, pointCount, tags}`. `canvasInkBounds` is the INK's extent (cap and \
                antialias included) and `canvasPathBounds` is the control points' box — use the \
                latter to verify placement, the former for true on-screen size. `color` is the \
                stored LIGHT-CANONICAL hex; on a dark document what you SEE is its conversion, \
                not this value.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to list strokes from."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_texts",
            description: """
                Lists a document's placed texts, one per text — authored by a \
                connected InfinitySketch device. REQUIRES a connected device — fails with \
                noDeviceAvailable if none is connected and deviceTimeout if it doesn't \
                respond in time. Returns the device's listing verbatim as text; this call \
                never writes to the document. unknownDoc if the document doesn't exist.

                REPLY: an ARRAY of `{id, text, canvasBounds, pinned, opacity, tags, anchor, layer, \
                color, fontSize, family, bold, italic, weight?, spans, alignment, wordWrap, wrapWidth, \
                inlineMath}`. The box \
                is `canvasBounds` ([x, y, w, h], canvas space), NOT `bounds`. `anchor` is the text's \
                picked anchor — the point of its box that stays put as the text grows — as \
                {row: top|middle|bottom, column: left|center|right}; ABSENT means automatic (the \
                first line's baseline keeps its place). `layer` is `front` (in front of the strokes) \
                or `back` (behind strokes and grids); a document from before object layers has no \
                such key and lists every text as `front`. The STYLE is add_text's own vocabulary, so \
                it can be sent back: a text in one style has top-level `color`, `fontSize`, `family`, \
                `bold`, `italic`; a text whose parts differ has `spans` instead ({text, color, \
                fontSize, family, bold, italic, weight?} each) and no top-level style. `weight` \
                (100–900) is there only for a weight that is neither Regular nor Bold — those \
                two are what `bold` says. `color` is \
                light-canonical and ABSENT for the automatic color; `family` is `System` for the \
                device's system font (an app without its own font leaves it out). `alignment` is left / center / right / justified / natural, or mixed. \
                `wordWrap` is true when the text wraps at a fixed width, then `wrapWidth` gives it \
                (the text's own points, before its transform). `inlineMath` is true when every $…$ \
                in the text shows as a typeset formula (add_text / edit_text set it).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to list placed texts from."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_arrows",
            description: """
                Lists a document's arrows, one per arrow — authored by a connected InfinitySketch \
                device with the `arrows` capability (noDeviceAvailable if none). Never writes.

                REPLY: an ARRAY of `{id, canvasPoints, nodes, canvasBounds, startHead, endHead, startAnchor, \
                endAnchor, drawnWidth, unscaledWidth, keepsWidth, headLength, headAngle, endHeadLength, endHeadAngle, \
                headsLinked, dashPattern, \
                dashAlignment, dashCorners, dashAnchor, dashEndsOn, dashOffset, cornerJoin, cornerMiterLimit?, color, opacity, pinned, layer, tags, closed, filled}`. \
                `closed` true: the path runs on from its last node to its first — a rectangle, a \
                circle, a dot (add_shape makes them) — so it has NO ends: the two heads and anchors \
                are kept but not drawn, and every node, the first too, is a point the line turns at. \
                `filled` true: the inside is painted in the line's color. \
                `cornerJoin` (round / miter / bevel) is how the corners turn while they share one — else the \
                join a new corner gets — and each corner's own is `nodes[].join` (with `miterLimit` for a miter). \
                `dashAlignment` (fitGaps / fitPattern / exact) with `dashCorners`, `dashAnchor`, `dashEndsOn` and \
                `dashOffset` (widths) says how the dash pattern is laid along the shaft. `keepsWidth` true: a scale moves the points and \
                keeps `drawnWidth`; false: a scale changes `drawnWidth` too, and `unscaledWidth` is the \
                width before it (restore_stroke_widths goes back to it; equal to `drawnWidth` otherwise). `headLength` (widths) and `headAngle` (degrees) \
                shape the start head — and both while `headsLinked` — and `endHeadLength` / `endHeadAngle` are the end head's \
                as drawn; `dashPattern` is the shaft's dash / gap list in widths, [] = solid. `canvasPoints` are the arrow's NODE positions in canvas \
                space, start first (an arrow has no transform: moving one rewrites its nodes). `nodes` \
                gives each node as `{canvasX, canvasY, type, join?, miterLimit?, roundness?}`: type `corner` (a \
                sharp point), `smooth` (the curve passes through it smoothly, its tangent computed from \
                its neighbours; `roundness` scales that tangent, 0–2, reported only when not 1; an Edit arc writes these). `canvasBounds` covers the curve as drawn. \
                `drawnWidth` is the line's width in canvas points — what it draws. `color` is \
                light-canonical `#RRGGBBAA` (its alpha is `opacity`). `layer` is `front` or `back`.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to list arrows from."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_arrow_presets",
            description: """
                Lists the user's arrow style presets — app-wide on the connected device, in the order \
                the user keeps them (built-ins: Line, Dashed line, Arrow, Double arrow, Open chevron, \
                Dimension, each possibly renamed, edited or deleted). Pass a name as `preset` to \
                add_arrow or restyle_arrows. A PRESET HOLDS NO COLOR: it is the shape (ends, width, heads, \
                line type, corners, layer), and what it is applied to keeps its color and opacity. Needs a \
                device with the `arrows` capability; `docId` only routes the request. Never writes.

                Manage them with save_arrow_preset, rename_arrow_preset, delete_arrow_preset, \
                move_arrow_preset and restore_arrow_presets (capability `arrowPresetWrites`).

                REPLY: an ARRAY of `{id, index, name, startHead, endHead, startAnchor, endAnchor, drawnWidth, \
                headLength, headAngle, endHeadLength, endHeadAngle, headsLinked, dashPattern, dashAlignment, dashCorners, \
                dashAnchor, dashEndsOn, dashOffset, \
                layer, keepsWidth, duplicateName}` — the same \
                fields and units list_arrows reports, without `color` and `opacity`. Names may \
                repeat: `duplicateName` is true for every preset sharing its name (any letter case), \
                and `preset` then takes the FIRST of them.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "Any document (its id, or its name when no other document has that name); it only picks the device to ask."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "save_arrow_preset",
            description: """
                Saves an arrow style preset. NEW by default — from an arrow (`arrowId` in `docId`), from the user's \
                new-arrow style (`fromNewArrowStyle: true`, also the default source), with any style fields \
                overriding the source; `name` names it ("Preset N" when absent). With `replace: true` it OVERWRITES \
                the style of the preset `id` or `name` names, keeping its place (and its name — unless both `id` \
                and a new `name` are given). Every ArrowStyle field can be given, but a preset holds NO COLOR: \
                `color` (light-canonical) and `opacity` are accepted but not saved, whatever the source. These are the user's DEVICE settings (app-wide on the connected device, not part of any \
                document): no document is written and there is no undo step, and the user sees the change at once \
                in every open Presets row. Needs a device with the `arrowPresetWrites` capability; `docId` only routes. REPLY: `{changed: {id, index, name}?, presets: [...]}` — `presets` is the resulting list exactly as \
                list_arrow_presets reports it (`id`, `index`, `name`, `duplicateName` and every style field).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(MCPAdapter.mergeProperties([
                    "docId": .object(["type": "string", "description": "Any document (its id, or its name when no other document has that name); it only picks the device to ask (and holds `arrowId`)."]),
                    "id": .object(["type": "string", "description": "A preset id from list_arrow_presets."]),
                    "name": .object(["type": "string", "description": "A preset name (any letter case) — or, when saving, the new preset's name."]),
                    "replace": .object(["type": "boolean", "description": "Overwrite the named preset's style instead of adding one."]),
                    "arrowId": .object(["type": "string", "description": "Take the style of this arrow (list_arrows) in docId."]),
                    "fromNewArrowStyle": .object(["type": "boolean", "description": "Take the user's new-arrow style (the default source)."]),
                ], MCPAdapter.arrowStyleProperties)),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "rename_arrow_preset",
            description: """
                Renames an arrow style preset. Name the preset by `id` (from list_arrow_presets — stable across renames and moves) or by \
                `name` (any letter case); a name several presets share fails with ambiguousPreset and lists their ids. These are the user's DEVICE settings (app-wide on the connected device, not part of any \
                document): no document is written and there is no undo step, and the user sees the change at once \
                in every open Presets row. Needs a device with the `arrowPresetWrites` capability; `docId` only routes. REPLY: `{changed: {id, index, name}?, presets: [...]}` — `presets` is the resulting list exactly as \
                list_arrow_presets reports it (`id`, `index`, `name`, `duplicateName` and every style field).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(MCPAdapter.mergeProperties([
                    "docId": .object(["type": "string", "description": "Any document (its id, or its name when no other document has that name); it only picks the device to ask (and holds `arrowId`)."]),
                    "id": .object(["type": "string", "description": "A preset id from list_arrow_presets."]),
                    "name": .object(["type": "string", "description": "A preset name (any letter case) — or, when saving, the new preset's name."]),
                    "newName": .object(["type": "string", "description": "The new name."]),
                ], [:])),
                "required": .array(["docId", "newName"].map(Value.string)),
            ])
        ),
        Tool(
            name: "delete_arrow_preset",
            description: """
                Deletes an arrow style preset (a built-in comes back with restore_arrow_presets). Name the preset by `id` (from list_arrow_presets — stable across renames and moves) or by \
                `name` (any letter case); a name several presets share fails with ambiguousPreset and lists their ids. These are the user's DEVICE settings (app-wide on the connected device, not part of any \
                document): no document is written and there is no undo step, and the user sees the change at once \
                in every open Presets row. Needs a device with the `arrowPresetWrites` capability; `docId` only routes. REPLY: `{changed: {id, index, name}?, presets: [...]}` — `presets` is the resulting list exactly as \
                list_arrow_presets reports it (`id`, `index`, `name`, `duplicateName` and every style field).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(MCPAdapter.mergeProperties([
                    "docId": .object(["type": "string", "description": "Any document (its id, or its name when no other document has that name); it only picks the device to ask (and holds `arrowId`)."]),
                    "id": .object(["type": "string", "description": "A preset id from list_arrow_presets."]),
                    "name": .object(["type": "string", "description": "A preset name (any letter case) — or, when saving, the new preset's name."]),
                ], [:])),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "move_arrow_preset",
            description: """
                Moves an arrow style preset: to `toIndex` (0 = first), or `before` / `after` another preset (its id \
                or name). Exactly one of the three. Name the preset by `id` (from list_arrow_presets — stable across renames and moves) or by \
                `name` (any letter case); a name several presets share fails with ambiguousPreset and lists their ids. These are the user's DEVICE settings (app-wide on the connected device, not part of any \
                document): no document is written and there is no undo step, and the user sees the change at once \
                in every open Presets row. Needs a device with the `arrowPresetWrites` capability; `docId` only routes. REPLY: `{changed: {id, index, name}?, presets: [...]}` — `presets` is the resulting list exactly as \
                list_arrow_presets reports it (`id`, `index`, `name`, `duplicateName` and every style field).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(MCPAdapter.mergeProperties([
                    "docId": .object(["type": "string", "description": "Any document (its id, or its name when no other document has that name); it only picks the device to ask (and holds `arrowId`)."]),
                    "id": .object(["type": "string", "description": "A preset id from list_arrow_presets."]),
                    "name": .object(["type": "string", "description": "A preset name (any letter case) — or, when saving, the new preset's name."]),
                    "toIndex": .object(["type": "integer", "description": "The position to move to, 0-based."]),
                    "before": .object(["type": "string", "description": "Another preset (id or name): move just before it."]),
                    "after": .object(["type": "string", "description": "Another preset (id or name): move just after it."]),
                ], [:])),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "restore_arrow_presets",
            description: """
                Brings the built-in arrow presets back as they shipped (an edited one is reset where it stands, a \
                deleted one returns at the front); the user's own presets are kept — the app's "Restore built-in \
                presets". These are the user's DEVICE settings (app-wide on the connected device, not part of any \
                document): no document is written and there is no undo step, and the user sees the change at once \
                in every open Presets row. Needs a device with the `arrowPresetWrites` capability; `docId` only routes. REPLY: `{changed: {id, index, name}?, presets: [...]}` — `presets` is the resulting list exactly as \
                list_arrow_presets reports it (`id`, `index`, `name`, `duplicateName` and every style field).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(MCPAdapter.mergeProperties([
                    "docId": .object(["type": "string", "description": "Any document (its id, or its name when no other document has that name); it only picks the device to ask (and holds `arrowId`)."]),
                ], [:])),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "get_new_arrow_style",
            description: """
                Reads the user's NEW-ARROW STYLE — what their Arrow tool draws now, and what add_arrow's omitted \
                fields take. Never writes. Needs a device with the `arrowPresetWrites` capability; `docId` only routes. \
                REPLY: `{newArrowStyle: {…}}` with every style field, as list_arrow_presets reports a preset.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(MCPAdapter.mergeProperties([
                    "docId": .object(["type": "string", "description": "Any document (its id, or its name when no other document has that name); it only picks the device to ask (and holds `arrowId`)."]),
                ], [:])),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "set_new_arrow_style",
            description: """
                Sets the user's NEW-ARROW STYLE — what their Arrow tool draws next — to `preset` (id or name) \
                and/or the style fields given; what is not given stays — the color too with a `preset`, \
                which holds none (`color` is light-canonical, `colorAppearance: "dark"` for a dark-authored hex). Use it to prepare the Arrow tool for the user. \
                These are the user's DEVICE settings (app-wide on the connected device, not part of any \
                document): no document is written and there is no undo step, and the user sees the change at once \
                in the Arrow tool. Needs a device with the `arrowPresetWrites` capability; `docId` only routes. REPLY: `{newArrowStyle: {…}}`, the style now set.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object(MCPAdapter.mergeProperties([
                    "docId": .object(["type": "string", "description": "Any document (its id, or its name when no other document has that name); it only picks the device to ask (and holds `arrowId`)."]),
                    "preset": .object(["type": "string", "description": "A preset (id or name) whose whole style is the base; the style fields override it."]),
                ], MCPAdapter.arrowStyleProperties)),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "add_arrow",
            description: """
                Places an arrow — the same object the app's Arrow tool draws: a line through \
                `canvasPoints` (corners; two points = straight) or through `nodes` (corner and smooth \
                points — list_arrows' shape; a smooth point's curve is derived, there are no handles) with a shape at each end, on top of Front \
                objects (or `layer: "back"`). Give exactly one of `canvasPoints` and `nodes`. Every style field you omit takes the USER'S NEW-ARROW STYLE \
                (what their Arrow tool draws now: tips, placements, width, color, head, line type, layer) — \
                or, with `preset`, that preset's style; the fields you pass override either. \
                `styleBase: "factory"` takes the omitted fields from the app's built-in style \
                instead (round start, filled head, the middle width, black — white on dark \
                paper —, solid, front): \
                pass it from a script, so the same script draws the same arrow whatever the user \
                has set. `color` is light-canonical \
                (`colorAppearance: "dark"` for a dark-authored hex). REQUIRES a device with \
                the `arrows` capability. `keepsWidth` (default true, as for the user's own arrows) \
                decides whether a later scale changes the arrow's width. `closed: true` (three \
                points or more) joins the last point to the first with a real corner there — an \
                outline with no seam and no heads — and `filled: true` beside it paints the inside \
                in the line's color: a face that stacks with the other objects, which a fill_region \
                (strokes, always below every object) cannot. For a rectangle, an ellipse, a circle \
                or a dot use add_shape. REPLY: the seq and \
                `arrowId`. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "canvasPoints": .object([
                        "type": "array",
                        "description": "[[x, y], …] — at least two points, start first, in canvas points; each is a sharp corner. Or give `nodes`.",
                        "items": .object(["type": "array", "items": .object(["type": "number"])]),
                    ]),
                    "nodes": MCPAdapter.arrowNodesProperty,
                    "startHead": .object(["type": "string", "enum": .array(["roundEnd", "flatEnd", "openChevron", "openChevronRoundTip", "openChevronRoundWings", "openChevronRound", "filledTriangle", "filledTriangleRoundTip", "filledTriangleRoundWings", "filledTriangleRound"].map(Value.string)),
                                          "description": "The shape at the start."]),
                    "endHead": .object(["type": "string", "enum": .array(["roundEnd", "flatEnd", "openChevron", "openChevronRoundTip", "openChevronRoundWings", "openChevronRound", "filledTriangle", "filledTriangleRoundTip", "filledTriangleRoundWings", "filledTriangleRound"].map(Value.string)),
                                        "description": "The shape at the end — the head."]),
                    "startAnchor": .object(["type": "string", "enum": .array(["endsAtPoint", "centeredOnPoint"].map(Value.string)),
                                            "description": "Where the start's ink sits: endsAtPoint (stops on the point; default for a new arrow) or centeredOnPoint (half a width past it, like a stroke's cap)."]),
                    "endAnchor": .object(["type": "string", "enum": .array(["endsAtPoint", "centeredOnPoint"].map(Value.string)),
                                          "description": "Where the end's ink sits: endsAtPoint (stops on the point; default for a new arrow) or centeredOnPoint (half a width past it, like a stroke's cap)."]),
                    "drawnWidth": .object(["type": "number", "description": "Line width in canvas points (0.5–40)."]),
                    "headLength": .object(["type": "number", "description": "Head length in arrow widths, tip to base (2–10, default 4): the start head's, and both heads' while they are linked (the default)."]),
                    "headAngle": .object(["type": "number", "description": "Half the angle at each head's tip, in degrees (15–60, default 32): the start head's, and both heads' while they are linked."]),
                    "endHeadLength": .object(["type": "number", "description": "The END head's own length in widths (2–10). Giving it unlinks the heads; omitted, the end head follows headLength."]),
                    "endHeadAngle": .object(["type": "number", "description": "The END head's own tip half-angle in degrees (15–60). Giving it unlinks the heads."]),
                    "headsLinked": .object(["type": "boolean", "description": "true: one length and angle for both heads (relinking gives the end head the start head's values); false: the end head keeps its own."]),
                    "dashPattern": .object(["type": "array", "items": .object(["type": "number"]),
                                            "description": "The shaft's line type: dash, gap, dash, gap … in arrow widths (at most 8 numbers, each 0–50); a dash of 0 is a round dot. [] is solid (default); [3, 2] dashed, [0, 2] dotted, [4, 2, 0, 2] dash-dot. Heads stay solid; the gaps adjust so both ends finish on a dash."]),
                    "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA, light-canonical (see colorAppearance); the alpha is the opacity."]),
                    "colorAppearance": .object(["type": "string", "enum": .array(["light", "dark"].map(Value.string)),
                                                "description": "\"dark\" when `color` was chosen for a dark page. Default light."]),
                    "preset": .object(["type": "string", "description": "A preset name from list_arrow_presets (any letter case): its shape is applied first (a preset holds no color — the arrow has the new-arrow color unless `color` is given), the other fields override it. An unknown name fails with unknownPreset and lists the names there are."]),
                    "styleBase": styleBaseProperty,
                    "layer": .object(["type": "string", "enum": .array(["front", "back"].map(Value.string)),
                                      "description": "front (above the strokes) or back (behind strokes and grids). Default: the layer the user's own new arrows go to (the Arrow tool's Layer setting, normally front)."]),
                    "opacity": .object(["type": "number", "description": "0…1 — the color's alpha (overrides the alpha of `color`)."]),
                    "dashAlignment": .object(["type": "string", "enum": .array(["fitGaps", "fitPattern", "exact"].map(Value.string)),
                                              "description": "How a dashed shaft's pattern is laid: fitGaps (default — dashes exact, gaps adjusted, ends as dashEndsOn), fitPattern (dashes and gaps scaled together; dots stay dots), exact (unchanged from dashAnchor, cut where it lands). With the fit modes `dashCorners` (default true) fits each run between corners on its own. Ignored for a solid line."]),
                    "dashCorners": .object(["type": "boolean", "description": "Fit modes only (default true): each run between corner points fitted on its own with the chosen fit, a dash centered on every corner; the arrow's two ends still follow dashEndsOn. No effect with exact."]),
                    "dashAnchor": .object(["type": "string", "enum": .array(["start", "end", "center"].map(Value.string)),
                                           "description": "Where an `exact` pattern starts: start (default), end, or center (both ends cut alike)."]),
                    "dashEndsOn": .object(["type": "string", "enum": .array(["dash", "gap", "halfDash"].map(Value.string)),
                                           "description": "What both ends of a fitGaps / fitPattern shaft finish on: dash (default), gap, halfDash."]),
                    "dashOffset": .object(["type": "number", "minimum": -50, "maximum": 50, "description": "Shifts the pattern, in arrow widths (−50…50; default 0): a positive value starts the shaft that far into the pattern (SVG's dash offset); in the fit modes, within the fitted pattern."]),
                    "cornerJoin": .object(["type": "string", "enum": .array(["round", "miter", "bevel"].map(Value.string)),
                                           "description": "How EVERY interior corner point turns: round (default), miter (sharp, cut to a bevel past cornerMiterLimit) or bevel. Per point in `nodes[].join`."]),
                    "cornerMiterLimit": .object(["type": "number", "minimum": 1, "maximum": 20,
                                                 "description": "A sharp (miter) corner's limit in half line widths (1–20; default 10); alone it makes the corners sharp."]),
                    "tags": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Durable tags for the new arrow (see tag_elements); find it again later with find_elements.",
                    ]),
                    "keepsWidth": .object(["type": "boolean", "description": "Keep width when scaling: true (the default for new arrows and the built-in presets) keeps the arrow's drawnWidth — and so its heads and dashes, which are in widths — when it is scaled (transform_elements, a live selection's scale); false scales the width with the arrow, and restore_stroke_widths can take that back (list_arrows' `unscaledWidth`)."]),
                    "closed": closedPathProperty,
                    "filled": filledPathProperty,
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "add_shape",
            description: """
                Places a closed shape as ONE object: a `rectangle` or `ellipse` (`canvasRect`), a \
                `circle` (`canvasX`, `canvasY`, `radius`), a `polygon` (`canvasPoints`) or a solid \
                `dot` (`canvasX`, `canvasY`, `diameter`). It is an ARROW object with a closed path — \
                list_arrows shows it (`closed: true`), restyle_arrows, reshape_arrow, \
                transform_elements, set_layer, tag_elements and remove_arrow work on it, and it \
                stacks with the other objects (a later one lies on top; reorder_elements). That is \
                the difference to fill_region and draw_dots, which make STROKES: those always lie \
                below every arrow, text and formula. \
                The geometry is the LINE'S CENTER: a rectangle of `canvasRect` drawn 2 wide \
                reaches 1 past it on every side. `filled: true` paints the inside too, in the \
                line's color, once (a translucent shape is even); for a face without a visible \
                border give the line the face's color. A `dot` is always solid and exactly \
                `diameter` across, ink to ink — its line is `drawnWidth`, but at most half the \
                diameter. A closed path has no ends: there are no heads. \
                Every style field you omit takes the user's new-arrow style, or the app's own with \
                `styleBase: "factory"` — pass that from a script. `color` is light-canonical \
                (`colorAppearance: "dark"` for a dark-authored hex). REQUIRES a device with the \
                `arrows` and `closedPaths` capabilities (an app from before closed paths is told to \
                update). Many shapes in one edit: `batch`. \
                REPLY: the seq, `arrowId`, `canvasBounds: [left, top, width, height]` — the ink's \
                box — and `drawnWidth`. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "shape": .object(["type": "string", "enum": .array(["rectangle", "ellipse", "circle", "polygon", "dot"].map(Value.string)),
                                      "description": "What to place. Each shape takes its own geometry arguments and refuses the others by name."]),
                    "canvasRect": .object(["type": "array", "items": .object(["type": "number"]), "minItems": 4, "maxItems": 4,
                                           "description": "rectangle / ellipse: [x, y, width, height] of the line's center, in canvas points; width and height above 0. An ellipse is the one inscribed in it."]),
                    "canvasX": .object(["type": "number", "description": "circle / dot: the center's x, in canvas points."]),
                    "canvasY": .object(["type": "number", "description": "circle / dot: the center's y, in canvas points."]),
                    "radius": .object(["type": "number", "description": "circle: the radius of the line's center, in canvas points, above 0. The ink reaches half a drawnWidth past it."]),
                    "diameter": .object(["type": "number", "minimum": 1, "maximum": 2000,
                                         "description": "dot: how wide the solid dot is, ink to ink, in canvas points (1–2000)."]),
                    "canvasPoints": .object([
                        "type": "array",
                        "description": "polygon: [[x, y], …] — at least three corners in canvas points. The path closes from the last to the first; do not repeat the first.",
                        "items": .object(["type": "array", "items": .object(["type": "number"])]),
                    ]),
                    "filled": .object(["type": "boolean", "description": "Paint the inside too, in the line's color (default false). A dot is always filled."]),
                    "drawnWidth": .object(["type": "number", "description": "Line width in canvas points (0.5–40). For a dot: at most half its diameter is used."]),
                    "dashPattern": .object(["type": "array", "items": .object(["type": "number"]),
                                            "description": "The line type: dash, gap, dash, gap … in line widths (at most 8 numbers, each 0–50); a dash of 0 is a round dot. [] is solid. Round a closed path the pattern closes on itself: a whole number of periods, and with dashCorners a dash centered on every corner. Not for a dot."]),
                    "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA, light-canonical (see colorAppearance); the alpha is the opacity. The line's color, and the fill's."]),
                    "colorAppearance": .object(["type": "string", "enum": .array(["light", "dark"].map(Value.string)),
                                                "description": "\"dark\" when `color` was chosen for a dark page. Default light."]),
                    "opacity": .object(["type": "number", "description": "0…1 — the color's alpha (overrides the alpha of `color`)."]),
                    "preset": .object(["type": "string", "description": "A preset name from list_arrow_presets: its line width, line type and corners are applied first, the other fields override it."]),
                    "styleBase": styleBaseProperty,
                    "layer": .object(["type": "string", "enum": .array(["front", "back"].map(Value.string)),
                                      "description": "front (above the strokes) or back (behind strokes and grids). Default: the layer the user's own new arrows go to."]),
                    "dashAlignment": .object(["type": "string", "enum": .array(["fitGaps", "fitPattern", "exact"].map(Value.string)),
                                              "description": "How a dashed line's pattern is laid: fitGaps (default), fitPattern or exact — as add_arrow's."]),
                    "dashCorners": .object(["type": "boolean", "description": "Fit modes only (default true): each side between two corners fitted on its own, a dash centered on every corner."]),
                    "dashAnchor": .object(["type": "string", "enum": .array(["start", "end", "center"].map(Value.string)),
                                           "description": "Where an `exact` pattern starts."]),
                    "dashOffset": .object(["type": "number", "minimum": -50, "maximum": 50, "description": "Shifts the pattern, in line widths (−50…50; default 0)."]),
                    "cornerJoin": .object(["type": "string", "enum": .array(["round", "miter", "bevel"].map(Value.string)),
                                           "description": "How every corner of a rectangle or polygon turns: round (default), miter (sharp) or bevel."]),
                    "cornerMiterLimit": .object(["type": "number", "minimum": 1, "maximum": 20,
                                                 "description": "A sharp (miter) corner's limit in half line widths (1–20; default 10); alone it makes the corners sharp."]),
                    "keepsWidth": .object(["type": "boolean", "description": "true (default): a later scale moves the shape's points and keeps its line width; false: the width scales too."]),
                    "tags": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Durable tags for the new shape (see tag_elements); find it again later with find_elements.",
                    ]),
                ]),
                "required": .array(["docId", "shape"].map(Value.string)),
            ])
        ),
        Tool(
            name: "reshape_arrow",
            description: """
                Replaces one arrow's geometry — its `canvasPoints` (corners) or `nodes` (list_arrows' \
                shape: corner / smooth) — keeping its id, style, layer, tags \
                and place in the stacking order. Read the current nodes with list_arrows, change what \
                you need, send them back. A pinned arrow is reshaped too, as transform_elements moves \
                one (pinning protects it from the user's touches). `closed` / `filled` close or open \
                the path and fill it or not; with one of them the geometry may be left out, and the \
                points stay. REQUIRES a device with the `arrows` capability. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "arrowId": .object(["type": "string", "description": "The arrow (list_arrows' `id`)."]),
                    "canvasPoints": .object([
                        "type": "array",
                        "description": "[[x, y], …] — at least two points, start first, in canvas points; each a sharp corner. Or give `nodes`.",
                        "items": .object(["type": "array", "items": .object(["type": "number"])]),
                    ]),
                    "nodes": MCPAdapter.arrowNodesProperty,
                    "closed": closedPathProperty,
                    "filled": filledPathProperty,
                ]),
                "required": .array(["docId", "arrowId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "restyle_arrows",
            description: """
                Changes the style of named arrows — a `preset`, and/or any of `startHead`, `endHead`, `startAnchor`, \
                `endAnchor`, `drawnWidth`, `headLength`, `headAngle`, `endHeadLength`, `endHeadAngle`, \
                `headsLinked`, `dashPattern`, `dashAlignment`, \
                `dashCorners`, `dashAnchor`, `dashEndsOn`, `dashOffset`, \
                `color` (light-canonical, or `colorAppearance: "dark"`; its alpha sets the opacity \
                too), `opacity` and `keepsWidth`; what you omit stays. Turning `keepsWidth` on leaves \
                the current width as it is (restore_stroke_widths takes an earlier scale back). \
                ATOMIC: every id must resolve or nothing changes. Their points never change \
                (move them with transform_elements' `arrowIds`). REQUIRES a device with the \
                `arrows` capability. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "ids": .object(["type": "array", "items": .object(["type": "string"]),
                                    "description": "Arrow ids, from list_arrows."]),
                    "startHead": .object(["type": "string", "enum": .array(["roundEnd", "flatEnd", "openChevron", "openChevronRoundTip", "openChevronRoundWings", "openChevronRound", "filledTriangle", "filledTriangleRoundTip", "filledTriangleRoundWings", "filledTriangleRound"].map(Value.string)),
                                          "description": "The shape at the start."]),
                    "endHead": .object(["type": "string", "enum": .array(["roundEnd", "flatEnd", "openChevron", "openChevronRoundTip", "openChevronRoundWings", "openChevronRound", "filledTriangle", "filledTriangleRoundTip", "filledTriangleRoundWings", "filledTriangleRound"].map(Value.string)),
                                        "description": "The shape at the end — the head."]),
                    "startAnchor": .object(["type": "string", "enum": .array(["endsAtPoint", "centeredOnPoint"].map(Value.string)),
                                            "description": "Where the start's ink sits: endsAtPoint (stops on the point; default for a new arrow) or centeredOnPoint (half a width past it, like a stroke's cap)."]),
                    "endAnchor": .object(["type": "string", "enum": .array(["endsAtPoint", "centeredOnPoint"].map(Value.string)),
                                          "description": "Where the end's ink sits: endsAtPoint (stops on the point; default for a new arrow) or centeredOnPoint (half a width past it, like a stroke's cap)."]),
                    "drawnWidth": .object(["type": "number", "description": "Line width in canvas points (0.5–40)."]),
                    "headLength": .object(["type": "number", "description": "Head length in arrow widths, tip to base (2–10, default 4): the start head's, and both heads' while they are linked (the default)."]),
                    "headAngle": .object(["type": "number", "description": "Half the angle at each head's tip, in degrees (15–60, default 32): the start head's, and both heads' while they are linked."]),
                    "endHeadLength": .object(["type": "number", "description": "The END head's own length in widths (2–10). Giving it unlinks the heads; omitted, the end head follows headLength."]),
                    "endHeadAngle": .object(["type": "number", "description": "The END head's own tip half-angle in degrees (15–60). Giving it unlinks the heads."]),
                    "headsLinked": .object(["type": "boolean", "description": "true: one length and angle for both heads (relinking gives the end head the start head's values); false: the end head keeps its own."]),
                    "dashPattern": .object(["type": "array", "items": .object(["type": "number"]),
                                            "description": "The shaft's line type: dash, gap, dash, gap … in arrow widths (at most 8 numbers, each 0–50); a dash of 0 is a round dot. [] is solid (default); [3, 2] dashed, [0, 2] dotted, [4, 2, 0, 2] dash-dot. Heads stay solid; the gaps adjust so both ends finish on a dash."]),
                    "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA, light-canonical (see colorAppearance)."]),
                    "colorAppearance": .object(["type": "string", "enum": .array(["light", "dark"].map(Value.string)),
                                                "description": "\"dark\" when `color` was chosen for a dark page. Default light."]),
                    "opacity": .object(["type": "number", "description": "0…1."]),
                    "preset": .object(["type": "string", "description": "A preset name from list_arrow_presets (any letter case): its shape is applied first — each arrow keeps its own layer and its own color and opacity (a preset holds none) — and the other fields override it."]),
                    "dashAlignment": .object(["type": "string", "enum": .array(["fitGaps", "fitPattern", "exact"].map(Value.string)),
                                              "description": "How a dashed shaft's pattern is laid: fitGaps (default — dashes exact, gaps adjusted, ends as dashEndsOn), fitPattern (dashes and gaps scaled together; dots stay dots), exact (unchanged from dashAnchor, cut where it lands). With the fit modes `dashCorners` (default true) fits each run between corners on its own. Ignored for a solid line."]),
                    "dashCorners": .object(["type": "boolean", "description": "Fit modes only (default true): each run between corner points fitted on its own with the chosen fit, a dash centered on every corner; the arrow's two ends still follow dashEndsOn. No effect with exact."]),
                    "dashAnchor": .object(["type": "string", "enum": .array(["start", "end", "center"].map(Value.string)),
                                           "description": "Where an `exact` pattern starts: start (default), end, or center (both ends cut alike)."]),
                    "dashEndsOn": .object(["type": "string", "enum": .array(["dash", "gap", "halfDash"].map(Value.string)),
                                           "description": "What both ends of a fitGaps / fitPattern shaft finish on: dash (default), gap, halfDash."]),
                    "dashOffset": .object(["type": "number", "minimum": -50, "maximum": 50, "description": "Shifts the pattern, in arrow widths (−50…50; default 0): a positive value starts the shaft that far into the pattern (SVG's dash offset); in the fit modes, within the fitted pattern."]),
                    "cornerJoin": .object(["type": "string", "enum": .array(["round", "miter", "bevel"].map(Value.string)),
                                           "description": "How EVERY interior corner point turns: round (default), miter (sharp, cut to a bevel past cornerMiterLimit) or bevel. Per point in `nodes[].join`."]),
                    "cornerMiterLimit": .object(["type": "number", "minimum": 1, "maximum": 20,
                                                 "description": "A sharp (miter) corner's limit in half line widths (1–20; default 10); alone it makes the corners sharp."]),
                    "keepsWidth": .object(["type": "boolean", "description": "Keep width when scaling: true (the default for new arrows and the built-in presets) keeps the arrow's drawnWidth — and so its heads and dashes, which are in widths — when it is scaled (transform_elements, a live selection's scale); false scales the width with the arrow, and restore_stroke_widths can take that back (list_arrows' `unscaledWidth`)."]),
                ]),
                "required": .array(["docId", "ids"].map(Value.string)),
            ])
        ),
        Tool(
            name: "remove_arrow",
            description: """
                Removes an arrow from a document by id (from list_arrows). Done by the SERVER, so it \
                needs no connected device and works on a document nobody has open. arrowNotFound when \
                no arrow has that id. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "arrowId": .object(["type": "string", "description": "The id of the arrow to remove, from list_arrows."]),
                ]),
                "required": .array(["docId", "arrowId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "list_formulas",
            description: """
                Lists a document's formula objects, one per formula — measured by a connected \
                InfinitySketch device with the `formulas` capability, which typesets each one \
                (noDeviceAvailable if none). Never writes. A `$…$` formula inside a text is part \
                of that text (list_texts' `inlineMath`), not listed here.

                REPLY: an ARRAY of `{id, latex, typeset, message?, canvasBounds, canvasBaseline, \
                fontSize, color?, opacity, pinned, layer, tags, anchor?}`. `latex` is the source as stored. \
                `typeset` false means the engine cannot set it: the app shows the source as plain \
                text and `message` is the parser's reason — fix it with edit_formula. \
                `canvasBounds` is [left, top, width, height], the canvas-space bounding box of the \
                typeset box as drawn (rotation and scale included), and `canvasBaseline` the \
                canvas point at the left end of its baseline. `fontSize` is in points. `color` is light-canonical `#RRGGBBAA`, absent for Automatic (the \
                paper's label color). `layer` is `front` or `back`. `anchor` is the picked \
                `{row, column}` — the point of the box that stays put when the source or size \
                changes — absent for automatic (the left end of the baseline).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to read."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "add_formula",
            description: """
                Places a formula object: ONE LaTeX formula per object, typeset by the app — what \
                its Formula button makes. Write `latex` WITHOUT `$` markers: `\\frac{a}{b}`, \
                not `$\\frac{a}{b}$`. A formula inside a sentence is not this: it is a text with \
                `inlineMath: true` (add_text), with each formula between `$` signs. `canvasX` and \
                `canvasY` are the LEFT END OF THE BASELINE, so formulas placed at the same \
                `canvasY` sit on one line, as text does. `fontSize` is the point size it is \
                typeset at (1–2000); omitted, the user's text size, else 20. `placeBy` makes \
                the coordinates name another point of the box — its center, its right end — so a \
                centered formula is one call. `anchor` is the point that stays put when the \
                source or size changes LATER (automatic: the left end of the baseline). `color` is \
                light-canonical `#RRGGBB` or `#RRGGBBAA` (`colorAppearance: "dark"` for a \
                dark-authored hex); omitted, the user's text color, else Automatic — black on \
                light paper, white on dark. A source that does not typeset is STORED and \
                reported (`typeset: false` with the parser's `message`), shown as its source \
                text until you correct it with edit_formula. A blank source fails with \
                emptyFormula, one longer than 4000 UTF-16 code units (most characters count 1, an emoji 2) with formulaTooLong, a `fontSize` outside \
                1–2000 with invalidFontSize. Goes on top of Front \
                objects (or `layer: "back"`). REQUIRES a device with the `formulas` capability.

                REPLY: one JSON object `{id, typeset, message?, canvasBounds, canvasBaseline, seq}` \
                — `canvasBounds` is [left, top, width, height] of the typeset box as drawn and \
                `canvasBaseline` the point at the left end of its baseline, in canvas space. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "latex": .object(["type": "string", "description": "The LaTeX source of ONE formula, without `$` markers, at most 4000 UTF-16 code units (most characters count 1, an emoji 2)."]),
                    "canvasX": .object(["type": "number", "description": "Canvas x-coordinate of the left end of the baseline (or of the point `placeBy` names)."]),
                    "canvasY": .object(["type": "number", "description": "Canvas y-coordinate of the baseline (or of the point `placeBy` names)."]),
                    "placeBy": placeByProperty(default: "the left end of the baseline"),
                    "anchor": formulaAnchorProperty,
                    "styleBase": styleBaseProperty,
                    "fontSize": .object(["type": "number", "description": "Point size the formula is typeset at, 1–2000. Default: the user's text size, else 20."]),
                    "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA, light-canonical (see colorAppearance). Default: the user's text color, else Automatic."]),
                    "colorAppearance": .object(["type": "string", "enum": .array(["light", "dark"].map(Value.string)),
                                                "description": "\"dark\" when `color` (and the colors named in the source) were chosen for a dark page. Default light."]),
                    "layer": .object(["type": "string", "enum": .array(["front", "back"].map(Value.string)),
                                      "description": "front (above the strokes, the default) or back (behind strokes and grids)."]),
                    "tags": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Durable tags for the new formula (see tag_elements); find it again later with find_elements.",
                    ]),
                ]),
                "required": .array(["docId", "latex", "canvasX", "canvasY"].map(Value.string)),
            ])
        ),
        Tool(
            name: "edit_formula",
            description: """
                Changes one formula object (list_formulas' `id`): any of `latex` (WITHOUT `$` \
                markers), `fontSize` (points, 1–2000), `color` (light-canonical; \
                `colorAppearance` only together with `color`), `anchor` and a new place (`canvasX` and/or \
                `canvasY`, naming the left end of the baseline as shown or the point `placeBy` \
                says, whatever transform the formula carries) — give at least one. Without a new place the formula's ANCHOR \
                stays where it is on the canvas — automatic: the LEFT END OF THE BASELINE — also when the formula is rotated \
                or scaled, so a longer source grows along its baseline (to the right on an unrotated formula with the automatic anchor). \
                An `anchor` given in the same call is the one that stays put; alone it moves nothing. A source that does not typeset \
                is stored and reported as on add_formula. formulaNotFound for an unknown id, \
                invalidFontSize for a size outside 1–2000. An \
                edit that changes nothing writes nothing. REQUIRES a device with the `formulas` \
                capability.

                REPLY: `{id, typeset, message?, canvasBounds, canvasBaseline, seq}` as add_formula's; an edit \
                that changed nothing has `unchanged: true` and no `seq`. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "id": .object(["type": "string", "description": "The formula (list_formulas' or add_formula's `id`)."]),
                    "latex": .object(["type": "string", "description": "The new LaTeX source, without `$` markers, at most 4000 UTF-16 code units (most characters count 1, an emoji 2)."]),
                    "fontSize": .object(["type": "number", "description": "The new point size, 1–2000."]),
                    "canvasX": .object(["type": "number", "description": "A new canvas x-coordinate for the left end of the baseline as shown (or for the point `placeBy` names). Needs a device with the `placeBy` capability."]),
                    "canvasY": .object(["type": "number", "description": "A new canvas y-coordinate for the baseline as shown (or for the point `placeBy` names). Needs a device with the `placeBy` capability."]),
                    "placeBy": placeByProperty(default: "the left end of the baseline"),
                    "anchor": formulaAnchorProperty,
                    "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA, light-canonical (see colorAppearance)."]),
                    "colorAppearance": .object(["type": "string", "enum": .array(["light", "dark"].map(Value.string)),
                                                "description": "\"dark\" when `color` was chosen for a dark page. Default light. Only with `color`."]),
                ]),
                "required": .array(["docId", "id"].map(Value.string)),
            ])
        ),
        Tool(
            name: "remove_formula",
            description: """
                Removes a formula object from a document by id (from list_formulas or \
                add_formula). Done by the SERVER, so it needs no connected device and works on a \
                document nobody has open. formulaNotFound when no formula has that id. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "id": .object(["type": "string", "description": "The id of the formula to remove, from list_formulas."]),
                ]),
                "required": .array(["docId", "id"].map(Value.string)),
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

                REPLY: an ARRAY of `{id, canvasBounds, pinned, opacity, tags, layer}`. The box is \
                `canvasBounds`, NOT `bounds`. `layer` is `front` or `back` — where the image paints \
                when unpinned; a pinned image paints under everything but the paper. An empty array \
                means the document has no images.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to list placed images from."]),
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

                REPLY: an ARRAY of `{id, type, spacing, snap, rotation, offset, color, thickness, \
                visible, enabled, families, tags}` in DRAW order, where each family is \
                `{id, label, normal, lineAngleDeg, phase, drawSpacing, snapSpacing}` and `tags` \
                is the grid's durable tags (empty unless you set them with add_grid/update_grid).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to list grids from."]),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                    "color": .object(["type": "string", "description": "\"#RRGGBBAA\" or \"#RRGGBB\" hex. Defaults to a translucent blue. Literal: drawn identically in light and dark (grid colours never convert)."]),
                    "thickness": .object(["type": "number", "description": "Line thickness. Defaults to 1."]),
                    "visible": .object(["type": "boolean", "description": "Whether the grid is drawn. Defaults to true."]),
                    "enabled": .object(["type": "boolean", "description": "Whether strokes snap to the grid. Defaults to true."]),
                    "offset": .object([
                        "type": "array",
                        "description": "The lattice phase [x, y]. Defaults to [0, 0].",
                        "items": .object(["type": "number"]),
                    ]),
                    "tags": .object([
                        "type": "array",
                        "description": "Durable tags for this grid, so you can find it again in a later session — and group it with the strokes you draw against it. REPLACES the grid's tags; [] clears them. Grids do NOT appear in find_elements; read them back from list_grids. list_tags reports how many grids carry each tag.",
                        "items": .object(["type": "string"]),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                    "color": .object(["type": "string", "description": "\"#RRGGBBAA\" or \"#RRGGBB\" hex. Literal: drawn identically in light and dark (grid colours never convert)."]),
                    "thickness": .object(["type": "number", "description": "Line thickness."]),
                    "visible": .object(["type": "boolean", "description": "Whether the grid is drawn."]),
                    "enabled": .object(["type": "boolean", "description": "Whether strokes snap to the grid."]),
                    "offset": .object([
                        "type": "array",
                        "description": "The lattice phase [x, y].",
                        "items": .object(["type": "number"]),
                    ]),
                    "tags": .object([
                        "type": "array",
                        "description": "Durable tags for this grid, so you can find it again in a later session — and group it with the strokes you draw against it. REPLACES the grid's tags; [] clears them. Grids do NOT appear in find_elements; read them back from list_grids. list_tags reports how many grids carry each tag.",
                        "items": .object(["type": "string"]),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                through (canvasX, canvasY): the offset is recomputed so the grid stays \
                anchored there. \
                No snap — use snap_points first if you want a lattice point. Authored by a \
                connected InfinitySketch device. gridNotFound if no grid has that id; \
                unknownDoc if the document doesn't exist. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "id": .object(["type": "string", "description": "The id of the grid to set the origin of, as returned by add_grid/list_grids."]),
                    "canvasX": .object(["type": "number", "description": "Canvas-space x the lattice should pass through."]),
                    "canvasY": .object(["type": "number", "description": "Canvas-space y the lattice should pass through."]),
                ]),
                "required": .array(["docId", "id", "canvasX", "canvasY"].map(Value.string)),
            ])
        ),
        Tool(
            name: "render_sketch",
            description: """
                Renders a region of a document, specific strokes, and/or ephemeral \
                candidate strokes that are not written to the document — use it to \
                preview a stroke before committing it with draw_strokes, optionally \
                composited over the document's real content to judge fit and alignment. \
                Authored by a connected InfinitySketch device. Pass `appearance: "light"|"dark"` \
                to render as though the device were showing that appearance, regardless of what \
                it is actually showing — the default is the document's own (the last opener's \
                device); two connected devices can be viewing in different modes, so render both \
                to check your work in each. Returns a PNG plus \
                metadata: the covered rect, the scale actually used, the appearance actually \
                rendered, the canvas contentSize, and — per grid — its id, thickness, \
                and each drawn/snap line family's id, lineAngleDeg and label. These grid \
                and family ids are what snap_points' gridIds and transform_strokes' \
                snapTo refer to. Ephemeral `strokes`' `color` hexes are light-canonical like \
                everywhere else on this surface — pass colorAppearance: "dark" if you picked \
                them for the dark canvas. READ lineAngleDeg for a family's line direction, never \
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

                REPLY: a PNG image plus a metadata text block. With writeToFile: true there is \
                NO image — the reply is one JSON object of that same metadata plus `filePath` (an \
                absolute path on the machine the server runs on) and `renderUrl` (a path RELATIVE \
                to this server, e.g. /api/renders/<name>.png — join it to the address you reached \
                this server on and download it, which is what to do when you are NOT on the \
                server's machine). The metadata's `renderedBy` names the kind of device that made \
                the image ("mac", "ipad", "iphone"). A text in the SYSTEM font (list_texts: \
                `family: "System"` — every text made before the app had its own font) is \
                set differently on a Mac: 4 to 5 % wider below 20 pt and with another line \
                height, so a wrapped line can break at another word; an iPad and an iPhone set \
                it alike. A text in Inter (the default of a new text) or another named family, \
                and a formula, are the same on every device. So compare an image of system-font text only with one \
                from the same kind, or ask for one with `device`.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to render."]),
                    "include": .object([
                        "type": "string",
                        "enum": .array(["document", "strokes", "arrows", "formulas", "none"].map(Value.string)),
                        "description": """
                            What document content to render, alongside any ephemeral \
                            strokes and arrows below. "document" (default): every stroke, placed \
                            image, text, arrow and formula. "strokes": only the strokes named \
                            by strokeIds — no images or texts. "arrows": only the arrows named \
                            by arrowIds (and restyle.arrowIds) — a clean swatch. "formulas": only \
                            the formulas named by formulaIds (needs a device with the `formulas` \
                            capability). "none": nothing from the document.
                            """,
                    ]),
                    "arrowIds": .object([
                        "type": "array",
                        "description": "With include: \"arrows\", the arrow ids (list_arrows) to show.",
                        "items": .object(["type": "string"]),
                    ]),
                    "formulaIds": .object([
                        "type": "array",
                        "description": "With include: \"formulas\" (which requires it), the formula ids (list_formulas) to show.",
                        "items": .object(["type": "string"]),
                    ]),
                    "arrows": .object([
                        "type": "array",
                        "description": """
                            EPHEMERAL candidate arrows to render over the document — never written. \
                            Each takes EXACTLY add_arrow's fields (canvasPoints, preset, every style \
                            field, layer) and is built by the same code, so the preview is what \
                            add_arrow would place; omitted fields take the user's new-arrow style. \
                            Iterate: render → adjust → render → add_arrow. The reply's metadata \
                            `arrows` reports each one's `canvasBounds` and the `style` it resolved to \
                            (preset + overrides, clamps included).
                            """,
                        "items": .object(["type": "object"]),
                    ]),
                    "restyle": .object([
                        "type": "object",
                        "description": """
                            Render EXISTING arrows as if restyled — the document unchanged: \
                            `arrowIds` plus any of restyle_arrows' fields (preset, heads, widths, \
                            dash, color, opacity, keepsWidth …), applied by the same code \
                            restyle_arrows uses. Iterate: render → adjust → render → restyle_arrows. \
                            The metadata's `restyledArrows` reports each one's `canvasBounds` and \
                            resolved `style`. Combine with include: "arrows" for an isolated swatch.
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
                    "canvasRect": .object([
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
                    "scale": .object([
                        "type": "number",
                        "description": """
                            Pixels per canvas point, at most 16. THIS is the knob for how big the \
                            image comes back — and by default the image is returned INLINE, so its \
                            size is a cost you pay on every call (with writeToFile: true it is not, \
                            so a big scale is cheap there). Omit it and the renderer picks \
                            a scale that fits `maxPixels`.
                            """,
                    ]),
                    "maxPixels": .object([
                        "type": "number",
                        "description": """
                            Pixel budget. Defaults to 1000000, hard ceiling 4000000. An \
                            over-large request — a larger budget, or a `scale` whose image \
                            would pass the ceiling — is downscaled to the ceiling, not rejected: \
                            the metadata reports the `scale` actually used, and \
                            `requestedScale` when an explicit scale was reduced.
                            """,
                    ]),
                    "appearance": .object([
                        "type": "string",
                        "enum": .array(["light", "dark"].map(Value.string)),
                        "description": "Which appearance to render. Default: the document's own (the last opener's device). Two connected devices can be viewing in different modes — render both to check your work in each.",
                    ]),
                    "colorAppearance": colorAppearanceProperty,
                    "device": .object([
                        "type": "string", "enum": .array(["mac", "ipad", "iphone"].map(Value.string)),
                        "description": """
                            Render on a device of this kind, or fail with noDeviceAvailable when \
                            none is connected. Omitted, the server picks (a device that has the \
                            document open is preferred). Devices lay text out a little \
                            differently, so an image that must not change from one export to the \
                            next — one meant for publishing — should always name the same kind. \
                            list_open_docs shows the kinds connected.
                            """,
                    ]),
                    "writeToFile": .object([
                        "type": "boolean",
                        "description": """
                            Write the PNG to a file on the machine the server runs on and return \
                            its absolute path as `filePath`, INSTEAD of returning the image \
                            inline. Defaults to false. Use it when you want the pixels for \
                            something other than looking at them — compositing, diffing, handing \
                            to another program — or when you want a large render without paying \
                            for it in context: a file costs nothing to receive, so `scale` can go \
                            to 16 without the size penalty an inline image carries. The server \
                            names the file (there is deliberately no output-path argument) and \
                            keeps the directory bounded, evicting the oldest renders — so treat \
                            the path as scratch and read it soon, not as somewhere to archive \
                            anything. If you are not on the server's machine, use the reply's \
                            `renderUrl` instead of `filePath`: the same render is downloadable \
                            from this server, and an evicted one is a plain 404.
                            """,
                    ]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "export_sketch",
            description: """
                Renders a document for PUBLISHING and writes it to a file — a PNG, or with \
                `format: "pdf"` a PDF page: the paper \
                without the grid, in the appearance you name, the content with a narrow margin. \
                It is render_sketch with the defaults a posted image needs, so none of them can \
                be forgotten — render_sketch is for looking and aligning (the grid is on, the \
                appearance is whatever device opened the document last, the image is small). \
                Read-only. The image may be up to 16 megapixels, four times render_sketch's \
                ceiling, because it goes to a file and never into the reply; without `scale` or \
                `maxPixels` it is about 8 megapixels. \
                `appearance` is REQUIRED: an export must not depend on who opened the document \
                last. A text in the system font is laid out differently on a Mac than on an iPad \
                or iPhone (render_sketch's description), so name `device` when exports must \
                match from one day to the next. \
                REQUIRES a connected device with the `exportRender` capability. \
                REPLY: ONE JSON object — the render's metadata (`canvasRect`, `pixelSize`, \
                `scale`, `appearance`, `renderedBy`, …) with `filePath` (absolute, on the \
                server's machine) and `renderUrl` (relative to this server; download it when \
                you are not on that machine). The server names the file and keeps its render \
                directory bounded, oldest first: copy the file soon. \
                PDF (`format: "pdf"`, needs a device with `exportPdf`): ONE page of the same \
                area in canvas points, on which texts are text (selectable, sharp at any zoom), \
                arrows, shapes and formulas are vectors, and the strokes are one picture placed \
                between the back and the front objects — ink has no vector form. `scale` is then \
                the pixels per canvas point of that picture and of placed photos (default 4, from \
                0.25 to 16; lowered for a very large or very long sheet, the metadata's \
                `strokeScale` says what was used) and `maxPixels` is not taken. With `canvasRect` \
                the page holds only what reaches into that part. \
                the metadata is `format`, `canvasRect`, `pageSize` (PDF points; an area longer \
                than 14400 is scaled down to it), `strokeScale`, `appearance`, `paperColor`, \
                `renderedBy`.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to export."]),
                    "appearance": .object([
                        "type": "string", "enum": .array(["light", "dark"].map(Value.string)),
                        "description": "Which appearance to export: the light page or the dark one. Required.",
                    ]),
                    "format": .object([
                        "type": "string", "enum": .array(["png", "pdf"].map(Value.string)),
                        "description": "\"png\" (default): a picture. \"pdf\": one page with texts, arrows, shapes and formulas as vectors and the strokes as a picture.",
                    ]),
                    "canvasRect": .object([
                        "type": "array", "items": .object(["type": "number"]), "minItems": 4, "maxItems": 4,
                        "description": "[x, y, width, height] in canvas points: exactly this part. Omitted: everything in the document, with `padding` round it.",
                    ]),
                    "padding": .object([
                        "type": "number",
                        "description": "The margin round the content when `canvasRect` is omitted, in canvas points. Default 40.",
                    ]),
                    "background": .object([
                        "type": "string", "enum": .array(["paper", "transparent"].map(Value.string)),
                        "description": "\"paper\" (default): the document's paper color for `appearance`. \"transparent\": no paper. The grid is never exported — use render_sketch with \"paper+grid\" to see it.",
                    ]),
                    "scale": .object([
                        "type": "number",
                        "description": "Pixels per canvas point, at most 16. Reduced when the image would pass 16 megapixels or 8192 pixels on a side; the metadata then names `requestedScale`. Omitted: the scale that fits `maxPixels`. For a PDF: the strokes' and photos' pixels per canvas point, 0.25 to 16, default 4.",
                    ]),
                    "maxPixels": .object([
                        "type": "number",
                        "description": "Pixel budget when `scale` is omitted. Default 8000000, at most 16000000. Not taken for a PDF.",
                    ]),
                    "device": .object([
                        "type": "string", "enum": .array(["mac", "ipad", "iphone"].map(Value.string)),
                        "description": "Export on a device of this kind, or fail with noDeviceAvailable when none is connected. Omitted, the server picks.",
                    ]),
                ]),
                "required": .array(["docId", "appearance"].map(Value.string)),
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
                real total. Note: `inkType` is the ink the stroke IS — a pen whose width is \
                constant reports `monoline` (the same name the user's Layers panel shows), \
                whichever name it was drawn or authored under; PencilKit's archive records \
                monoline as pen and the app derives it back from the uniform sizes. \
                This tool does not report grids — render_sketch's metadata does, \
                including each grid's id (what snap_points' gridIds and \
                transform_strokes' snapTo refer to). Read-only.

                REPLY: an ARRAY of `{id, canvasPoints, canvasPathBounds, localToCanvasTransform, \
                color, inkType, drawnWidth, toolWidth, pointCount}`. NOTE there is no `canvasInkBounds` here \
                — only list_strokes reports it. `color` is the stored LIGHT-CANONICAL hex; on a \
                dark document what you SEE is its conversion, not this value.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to read strokes from."]),
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
                snap its y-coordinate and keep its x-coordinate) or an INTERSECTION of two \
                non-parallel \
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

                OBJECTS: pass objects: true to also get the points of the drawing itself \
                within objectRadius (canvas points, default 50) — stroke ends, midpoints, \
                crossings of two strokes, where a stroke crosses a grid line, the corners, \
                edge middles and center of images and texts, and text baselines. They come \
                back in a separate objectCandidates list, ordered by distance, each naming \
                the element(s) it belongs to by the same ids list_strokes, list_texts and \
                list_images report — so you can connect a new line to a SPECIFIC stroke's \
                end. Needs a device with the snapObjects capability (noDeviceAvailable \
                otherwise).

                REPLY: an ARRAY, one entry per point you asked about, each \
                `{canvasPoint, candidates}` where a candidate is \
                `{canvasPosition, distance, kind, parents}` — `kind` is the sort of snap (a grid \
                line, or an intersection of two families) and `parents` names the grid(s) and \
                families it came from. With objects: true each entry also carries \
                `objectCandidates`, each `{canvasPosition, distance, kind, elementIds}` plus \
                `gridId` and `familyId` for a stroke × grid-line crossing — `kind` is one of \
                endpoint, midpoint, strokeIntersection, gridIntersection, boxCorner, \
                boxEdgeMiddle, boxCenter, textBaseline, arrowPoint (an arrow's corner or smooth \
                point between its ends), segmentMiddle (the middle of one of an arrow's segments). \
                An arrow's ends and middle report as endpoint and midpoint. A formula's box \
                points report as boxCorner / boxEdgeMiddle / boxCenter and its baseline as \
                textBaseline, like a text's.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to query."]),
                    "canvasPoints": .object([
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
                            Consider only these grids (ids from render_sketch's metadata) — \
                            for the grid candidates and for objectCandidates' grid-line \
                            crossings. Default: all of them, including invisible and disabled ones.
                            """,
                        "items": .object(["type": "integer"]),
                    ]),
                    "maxCandidates": .object([
                        "type": "integer",
                        "description": "Per point; default 64. The cap drops the FARTHEST candidates (applies to each list).",
                    ]),
                    "objects": .object([
                        "type": "boolean",
                        "description": "Also return objectCandidates: the points of strokes, images and texts near each point. Default false.",
                    ]),
                    "objectRadius": .object([
                        "type": "number",
                        "description": "Canvas points around each point to look for objectCandidates in; default 50.",
                    ]),
                ]),
                "required": .array(["docId", "canvasPoints"].map(Value.string)),
            ])
        ),
        Tool(
            name: "transform_strokes",
            description: """
                Moves, scales and/or rotates strokes in place. The strokes keep their \
                identity (ids), their points and their z-order — only their placement \
                changes. canvasTranslate and canvasAnchor are CANVAS coordinates: the same \
                space get_strokes' points, list_strokes' bbox and render_sketch are quoted \
                in. Scale and rotate act about canvasAnchor, which defaults to the \
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
                wire's y-coordinate while its x-coordinate stays put) you actually mean; \
                with no enabled grid \
                (and no snapTo), snapToGrid is a no-op. A snap alone, with no translate/ \
                scale/rotate, is a legal request. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "ids": .object([
                        "type": "array",
                        "description": "Composite stroke ids, as returned by list_strokes or draw_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                    "canvasTranslate": .object([
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
                    "canvasAnchor": .object([
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
            name: "restore_stroke_widths",
            description: """
                Takes the SCALE back off the ink of strokes that were scaled, leaving \
                them exactly where they are on the canvas. Scaling a stroke (here or by \
                the user dragging a selection) scales its INK THICKNESS along with its \
                geometry, because the scale lives on the stroke's transform and \
                PencilKit scales stamp size with it — so a shape scaled up by 3 is drawn \
                with lines 3x fatter. This restores the drawn thickness while every \
                point stays put; it is the same operation as the app's "Restore original \
                stroke widths" menu item. Nothing else changes: ids, points, z-order, \
                colour and ink all survive, and the stroke's width-edit history is left \
                alone. AFTERWARDS the strokes' localToCanvasTransform (get_strokes) has \
                changed — its scale is now 1, or it is identity for a stroke that was \
                scaled unevenly — so re-read rather than reusing a cached one; \
                canvasPoints and canvasPathBounds are unaffected. A stroke that carries \
                no scale is LEFT ALONE and counted in the reply, not an error, and when \
                that is true of every id given, NOTHING IS WRITTEN AT ALL (the reply \
                says "no change" and quotes no seq). drawnWidth is not touched — to \
                change the drawn thickness itself, use restyle_strokes. ARROW ids work too: an arrow \
                whose `keepsWidth` is false was thickened or thinned by a scale, and this sets its \
                drawnWidth back to list_arrows' `unscaledWidth` (heads and dashes, in widths, \
                follow); an arrow never scaled is reported unchanged. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "ids": .object([
                        "type": "array",
                        "description": """
                            Composite stroke ids, as returned by list_strokes or \
                            draw_strokes, and/or arrow ids from list_arrows. Ids that \
                            carry no scale are accepted and reported back as unchanged.
                            """,
                        "items": .object(["type": "string"]),
                    ]),
                ]),
                "required": .array(["docId", "ids"].map(Value.string)),
            ])
        ),
        Tool(
            name: "restyle_strokes",
            description: """
                Changes strokes' colour, width and/or ink in place; identity and \
                geometry survive. At least one of color, drawnWidth, toolWidth or inkType \
                must be supplied. The two widths are the app's Properties panel's own, in \
                canvas points, and list_strokes/get_strokes report both: `drawnWidth` makes \
                each stroke DRAW exactly that wide at its widest (the panel's Drawn) — even \
                past what the drawing tool's slider can reach, within what the ink can draw; \
                `toolWidth` re-inks each stroke as if drawn with the tool setting that draws \
                that wide at nominal pressure, KEEPING its own pressure (the panel's Tool, and \
                what its palette presets do). Give at most one of the two. When a stroke does \
                not land on the width asked for (below the ink's thinnest, above its widest), \
                THE REPLY SAYS SO, naming what you asked for, what it became and the ink's \
                range. An ink-only restyle (no width) preserves the stroke's thickness. A colour-only restyle changes nothing \
                else. One user-visible cost, worth knowing before you restyle a stroke \
                the user has never width-edited: the app can afterwards restore that \
                stroke's original width only APPROXIMATELY, because the tool-slider \
                value the user drew with is not recorded anywhere and cannot be \
                recovered from the stroke (a colour-only restyle, and any stroke the \
                user HAS width-edited, are unaffected). An omitted `inkType` keeps the ink the \
                stroke IS: a constant-width pen is a monoline, so a width-only restyle of one \
                lands uniform rather than taking on its recorded pressure, and lists as `monoline` \
                afterwards (PencilKit's archive records monoline as pen; the app derives it back \
                from the uniform sizes). `color` is LIGHT-CANONICAL — \
                pass colorAppearance: "dark" if you picked it for the dark canvas; the device \
                converts it before storing, and the reply's storedColor reports what was \
                actually stored. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
                    "ids": .object([
                        "type": "array",
                        "description": "Composite stroke ids, as returned by list_strokes or draw_strokes.",
                        "items": .object(["type": "string"]),
                    ]),
                    "colorAppearance": colorAppearanceProperty,
                    "color": .object([
                        "type": "string",
                        "description": "#RRGGBB or #RRGGBBAA. Light-canonical (the light-appearance value); see colorAppearance.",
                    ]),
                    "drawnWidth": .object([
                        "type": "number",
                        "description": """
                            How wide each stroke should DRAW at its widest, in canvas points \
                            (> 0) — the Properties panel's Drawn width, as list_strokes reports \
                            it. Lands exactly, past the tool slider's range too, within what the \
                            ink can draw; outside that, the nearest end, reported.
                            """,
                    ]),
                    "toolWidth": .object([
                        "type": "number",
                        "description": """
                            The width of the TOOL SETTING to re-ink with, in canvas points (> 0): \
                            what that setting draws at nominal pressure — the Properties panel's \
                            Tool width, and get_tool's toolWidth. Each stroke keeps its own \
                            pressure, so a lightly drawn stroke stays lighter than one drawn hard.
                            """,
                    ]),
                    "inkType": .object([
                        "type": "string",
                        "enum": .array(["pen", "pencil", "marker", "monoline", "fountainPen", "watercolor", "crayon"].map(Value.string)),
                        "description": """
                            Note: a constant-width pen IS a monoline and lists as `monoline` — \
                            PencilKit's archive records monoline as pen, and the app derives \
                            the name back from the uniform sizes.
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                                "canvasPoints": .object([
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
                            "required": .array(["id", "canvasPoints"].map(Value.string)),
                        ]),
                    ]),
                ]),
                "required": .array(["docId", "strokes"].map(Value.string)),
            ])
        ),
        Tool(
            name: "get_selection",
            description: """
                Read the user's CURRENT live rect-select selection on a connected device. \
                REQUIRES a connected device with the document open.

                THE REPLY'S KEYS, because guessing them wastes a round trip and fails SILENTLY \
                (absent JSON keys read as nothing, not as an error):

                - `elements` — what is selected. NOT "strokes": each entry is \
                  `{kind: "stroke"|"text"|"image"|"arrow"|"formula", id, canvasBounds, pinned}`, \
                  so one list covers all five kinds (a formula's `canvasBounds` is its typeset box).
                - `canvasBounds` — the union of the selected elements. NOT "bounds".
                - `canvasRect` — the MARQUEE itself, which is a different thing: it is where the \
                  user dragged, and it can be non-empty while `elements` is empty. NOT "rect".
                - `canvasReferencePoint` — the pivot the user placed, absent if they have not.
                - `active` — something is selected. `sessionActive` — select mode is ON. These \
                  DIFFER: a user in select mode who has not swiped yet, or whose marquee \
                  touched nothing, gives `sessionActive: true` with `active: false`.
                - `uncommittedCopy` — a duplicate or paste that will be DELETED if you clear the \
                  selection rather than committing it.
                - `signature` — opaque; pass back as transform_selection's `expect`.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
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
                selection since (selectionChanged). Selected ARROWS scale their width with them only \
                when their `keepsWidth` is false (list_arrows); otherwise points move and width, heads \
                and dashes stay. REQUIRES a connected device with an active selection.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "get_tool",
            description: """
                Report the tool picker's CURRENT tool on the connected device — `isInkingTool`, \
                and when true `inkType`, `toolWidth`, `pickerDialWidth` and `color` (#RRGGBBAA). READ THIS BEFORE DRAWING and pass the values explicitly to \
                draw_strokes / draw_selection / render_sketch, so strokes you author match the \
                pen the user is holding unless they asked for something else. The values are \
                never applied implicitly: you hold them, so a preview and its commit are the same \
                numbers even if the user switches tools in between. `isInkingTool` is false for \
                the eraser, lasso, or Bring to Front — nothing sensible to inherit, so use your \
                own values. `color` is reported LIGHT-CANONICAL, whatever appearance the device \
                is currently showing — copy it into draw_strokes/restyle_strokes verbatim, no \
                colorAppearance needed.

                `toolWidth` is how wide this tool DRAWS at nominal pressure, in canvas points — \
                the Properties panel's Tool width — so it is what to pass as draw_strokes' \
                drawnWidth to match the user's pen (an omitted drawnWidth inherits it for you), \
                and restyle_strokes' toolWidth takes the same unit. `pickerDialWidth` is the \
                picker's raw dial, PencilKit's own number, reported for completeness; no tool \
                takes it. Needs no selection. \
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
                Stroke colours are light-canonical, same as draw_strokes — pass \
                colorAppearance: "dark" if you picked them for the dark canvas. \
                Requires an ACTIVE selection: noSelectionActive otherwise, userBusy mid-gesture. \
                REQUIRES a connected `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
                    "strokes": .object([
                        "type": "array",
                        "description": "Strokes to draw; same item shape as draw_strokes.",
                        "items": .object(["type": "object"]),
                    ]),
                    "colorAppearance": colorAppearanceProperty,
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
                (#RRGGBB/#RRGGBBAA), a width, and/or `inkType` (pen/pencil/marker/monoline), \
                exactly as the Properties panel does: `drawnWidth` makes every selected stroke \
                draw that wide (the panel's Drawn), `toolWidth` re-inks each with the tool setting \
                that draws that wide at nominal pressure, keeping its own pressure (the panel's \
                Tool) — at most one of the two, both in canvas points. At least one field is \
                required; an omitted field is left as each stroke has it. Unlike restyle_strokes (which edits document bytes and cannot refresh the \
                canvas while a selection is open) this drives the app's own reink path, so the \
                change appears immediately and lands as one undo step. `color` is light-canonical \
                — pass colorAppearance: "dark" if you picked it for the dark canvas. \
                noSelectionActive if \
                nothing is selected; userBusy mid-gesture. REQUIRES a connected \
                `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
                    "colorAppearance": colorAppearanceProperty,
                    "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA. Light-canonical (the light-appearance value); see colorAppearance."]),
                    "drawnWidth": .object(["type": "number", "description": "How wide every selected stroke should DRAW at its widest, in canvas points — the Properties panel's Drawn width."]),
                    "toolWidth": .object(["type": "number", "description": "The width of the tool setting to re-ink with, in canvas points: what it draws at nominal pressure — the Properties panel's Tool width. Each stroke keeps its own pressure."]),
                    "inkType": .object([
                        "type": "string",
                        "description": "pen, pencil, marker, or monoline.",
                        "enum": .array(["pen", "pencil", "marker", "monoline", "fountainPen", "watercolor", "crayon"].map(Value.string)),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
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
                `get_selection` or the document summary), and/or `arrowIds` (from `list_arrows`), \
                and/or `formulaIds` (from `list_formulas`; needs a device with the `formulas` capability) — \
                at least one id across the arrays is required (enforced device-side). By default the selection rectangle is resized \
                to hug the chosen elements; pass `keepRect: true` to leave the user's own marquee \
                exactly where they dragged it. REQUIRES a connected `controlSelection` device.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
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
                    "arrowIds": .object([
                        "type": "array",
                        "description": "Arrow ids to select, from list_arrows or get_selection.",
                        "items": .object(["type": "string"]),
                    ]),
                    "formulaIds": .object([
                        "type": "array",
                        "description": "Formula ids to select, from list_formulas or get_selection.",
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
                    "canvasX": .object(["type": "number", "description": "Canvas-space x. Not snapped."]),
                    "canvasY": .object(["type": "number", "description": "Canvas-space y. Not snapped."]),
                ]),
                "required": .array(["docId", "canvasX", "canvasY"].map(Value.string)),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
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
                committing it. Arrows preview as they will commit: a scale keeps an arrow's width \
                unless its `keepsWidth` is false. Selected formulas move too (`kind: "formula"`, their \
                typeset box as bounds). `include`: "withContext" (default) renders the grid and the \
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
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
                    "canvasRect": .object([
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
                point): clone + transform as one "stamp" undo step (a scale keeps an arrow's width \
                unless its `keepsWidth` is false). Returns the new elements' \
                keys/ids (formulas' as `createdFormulaIds`). Pass `expect` = a prior get_selection's `signature` to be rejected if \
                the user changed the selection since (selectionChanged). REQUIRES a connected \
                `controlSelection` device with an active selection.
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name)."]),
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
                With `into`, the union is written to a NEW document of that name (with its own \
                id) and both inputs are left untouched (docExists if a document already has \
                that name). \
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
                        "description": "Optional: write the union to a NEW document with this name (it gets its own id), leaving both source and target untouched. docExists if a document already has this name.",
                    ]),
                ]),
                "required": .array(["source", "target"].map(Value.string)),
            ])
        ),
        Tool(
            name: "diff_docs",
            description: """
                What differs between a document and a BASE copy of it, element by element — \
                read-only. THE way to learn what the user changed: keep a copy when you finish \
                (the bytes of the `infsketch://doc/<id>/raw` resource, saved to a file, or a \
                second document), and when the user says "I adjusted it", diff against that copy \
                before you touch anything, so their changes are taken over and not overwritten.

                It compares CONTENT, not bytes: a device that merely opens a document rewrites \
                its thumbnail, viewport and appearance, and re-archives its strokes, so the raw \
                bytes change when nobody edited anything. `equal: true` means the sync engine \
                sees no change. Give exactly one base: `baseDocId` (another document on this \
                server) or `basePath` (an ABSOLUTE path to a saved .infsketch copy on the machine \
                the server runs on). REQUIRES a device with the `diffDocs` capability; \
                baseNotFound for an unknown `baseDocId`, baseUndecodable when the base is not a \
                document.

                REPLY: one JSON object `{equal, bytesEqual, added, removed, changed, changes, \
                retagged, reordered, docFields}`. `added`, `removed` and `changed` are each \
                `{strokeIds, textIds, imageIds, arrowIds, formulaIds}` (every key present) — \
                ids of this document for added and changed, of the base for removed. `changes` \
                maps each changed id to what differs: "geometry" (where it is, its transform, an \
                arrow's points, a wrap width), "content" (a text's characters, a formula's \
                source, an image's pixels), "style" (everything else). `retagged` lists elements \
                whose tags differ, `reordered` is true when the stacking of what both have \
                differs, and `docFields` names the document's own fields that differ (grids, \
                paper, export settings).
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document as it is now (its id, or its name when no other document has that name)."]),
                    "baseDocId": .object(["type": "string", "description": "The base: another document on this server (id, or unambiguous name)."]),
                    "basePath": .object(["type": "string", "description": "The base: an absolute path to a .infsketch file on the machine the server runs on."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])
        ),
        Tool(
            name: "copy_elements",
            description: """
                Copies named strokes/texts/images/arrows/formulas from document `source` INTO document \
                `target`, as FRESH clones (fresh ids) — unlike \
                merge_docs, elements are never deduped by identity, so copying the same \
                source element twice yields two distinct clones. `source` is left \
                untouched; `target` gains the copies, texts, images, arrows and formulas keeping \
                the order they had among each other. `source` and `target` MAY BE THE SAME \
                document: the clones then lie exactly on their originals, so move them \
                (transform_elements) or change them next.

                PLACE THE CLONES IN THE SAME CALL: `scale`, `rotate` (both about `canvasAnchor`) \
                and `canvasTranslate` are transform_elements' operations, applied to the clones \
                only; `tags` names them; `scaleWidths: true` lets the arrows' line widths follow \
                the scale. To put a symbol's pin on a point P: `canvasAnchor` = the pin's place in \
                the source, `canvasTranslate` = P minus that place. These need a device with the \
                `copyTransform` capability.

                At least one of `strokeIds`/ \
                `textIds`/`imageIds`/`arrowIds`/`formulaIds` is required (`formulaIds` need a \
                device with the `formulas` capability). \
                REQUIRES a connected device with the copyElements capability — fails with \
                noDeviceAvailable if none is connected, sourceNotFound / targetNotFound if \
                either document is absent, and deviceFailed: elementNotFound if an id \
                isn't found in `source`. \(writeToolCaveats)

                REPLY: the clones' NEW ids, as `createdStrokeIds`, `createdTextIds`, \
                `createdImageIds`, `createdArrowIds` and `createdFormulaIds` — deliberately not \
                `strokeIds`/`textIds`/`imageIds`/`arrowIds`/`formulaIds`, which are this tool's \
                ARGUMENTS and name the elements in the SOURCE.
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
                    "arrowIds": .object([
                        "type": "array",
                        "description": "Arrow ids to clone, from list_arrows.",
                        "items": .object(["type": "string"]),
                    ]),
                    "formulaIds": .object([
                        "type": "array",
                        "description": "Formula ids to clone, from list_formulas.",
                        "items": .object(["type": "string"]),
                    ]),
                    "scale": .object([
                        "type": "array", "items": .object(["type": "number"]),
                        "description": "[sx, sy] applied to the CLONES about `canvasAnchor`; non-zero. A negative factor mirrors.",
                    ]),
                    "rotate": .object([
                        "type": "number",
                        "description": "Degrees the clones are turned about `canvasAnchor`, after the scale; positive = clockwise on screen.",
                    ]),
                    "canvasAnchor": .object([
                        "type": "array", "items": .object(["type": "number"]),
                        "description": "[x, y], the fixed point of `scale` and `rotate`, in the SOURCE's coordinates (where the clones lie before they move). Defaults to the centre of the clones' bounding box.",
                    ]),
                    "canvasTranslate": .object([
                        "type": "array", "items": .object(["type": "number"]),
                        "description": "[dx, dy] the clones are moved by, last. Without it they lie at their sources' coordinates.",
                    ]),
                    "scaleWidths": .object([
                        "type": "boolean",
                        "description": "true: the cloned arrows' line widths follow `scale` (heads and dashes are in widths and follow too), whatever their keepsWidth — which is left as it was. Default false: each arrow follows its own keepsWidth. A stroke's ink always scales with it.",
                    ]),
                    "tags": .object([
                        "type": "array", "items": .object(["type": "string"]),
                        "description": "Tags every clone gets, on top of the ones it inherits from its source.",
                    ]),
                ]),
                "required": .array(["source", "target"].map(Value.string)),
            ])
        ),
        Tool(
            name: "reorder_elements",
            description: """
                Sets the z-order (draw order) of named strokes/texts/images/arrows/formulas within \
                ONE document — bring-to-front or send-to-back, authored by a connected \
                InfinitySketch device. At least one of `strokeIds`/`textIds`/`imageIds`/`arrowIds`/ \
                `formulaIds` is required (`formulaIds` need a device with the `formulas` capability). `mode` selects the direction: "front" moves the named \
                elements to the top of the draw order, "back" to the bottom. A stroke moves \
                among the strokes. A text, image, arrow or formula moves to the top (or bottom) of \
                the LAYER it paints in, above (or below) every object of that layer WHATEVER ITS \
                KIND — texts, images, arrows and formulas share one order. The document paints in \
                LAYERS, bottom to top: pinned images, back objects (texts/images/arrows/formulas \
                whose `layer` is "back"), the grid, strokes, front objects — this tool never moves \
                anything between layers. list_texts/list_images/list_arrows/list_formulas report each \
                object's `layer`; set_layer changes it, and set_pinned moves an image into or \
                out of the pinned-images layer. \
                REQUIRES a connected device with the reorderElements capability — fails \
                with noDeviceAvailable if none is connected, deviceTimeout if it doesn't \
                respond in time, unknownDoc if the document doesn't exist, and \
                deviceFailed: <reason> (e.g. elementNotFound) for an unknown id. \
                \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to modify."]),
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
                    "arrowIds": .object([
                        "type": "array",
                        "description": "Arrow ids to reorder, from list_arrows.",
                        "items": .object(["type": "string"]),
                    ]),
                    "formulaIds": .object([
                        "type": "array",
                        "description": "Formula ids to reorder, from list_formulas.",
                        "items": .object(["type": "string"]),
                    ]),
                    "mode": .object([
                        "type": "string",
                        "enum": .array(["front", "back"].map(Value.string)),
                        "description": "\"front\" moves the named elements to the top of the draw order, \"back\" to the bottom — strokes among the strokes, each text, image, arrow or formula within the layer it paints in.",
                    ]),
                ]),
                "required": .array(["docId", "mode"].map(Value.string)),
            ])
        ),
        Tool(
            name: "batch",
            description: """
                Several writes to ONE document as ONE edit: each op is an ordinary tool call \
                (`{tool, arguments}`), run in order on a working copy of the document, and the \
                result is written once. The user's canvas changes once, the user gets ONE undo \
                step for the lot (as does undo_last_edit), and there is one `seq`. Use it for \
                anything made of many elements — a chart, a circuit, clearing a section and \
                drawing it again — instead of hundreds of single calls.

                ATOMIC: if any op fails, NOTHING is written and the error names the op. An op \
                sees what the ops before it did, so you can add a text and list_texts after it, or \
                tag what an earlier op created (by an id you gave it a tag for; replies arrive \
                only at the end). Each op's `arguments` are the tool's own; leave `docId` out (it \
                is this batch's document; `target` for copy_elements, whose `source` may be any \
                document). Tools a batch takes: \(batchableTools.sorted().joined(separator: ", ")). \
                Not the live-selection tools, not render_sketch, and nothing that creates, \
                replaces or deletes a document.

                A batch is ONE request: it has to finish within your client's timeout. An op that \
                needs a device costs a round trip (roughly a tenth of a second), so keep a batch \
                to a few hundred ops at most (limit \(maxBatchOps)). If the document changes \
                while the batch runs — the user draws — the batch is run once more on the new \
                document by itself; if it changes again, the batch's result is merged into the \
                document as it then is and written, as long as the user and the batch did not \
                change the same element. Only then — or when the document changes a third time — \
                the answer is docChangedDuringOp with nothing written: send the batch again. \
                A batch you cancel stops at its next op and writes nothing.

                REPLY: one JSON object `{seq, results}` — `results` holds one entry per op, in \
                order. A WRITE's entry is an object: `message` (its reply's first line), `seq`, \
                and the fields its reply names — `id` for the element it made (always `id`, also \
                for an arrow), `canvasBounds`, `ids`, `createdArrowIds` and so on, `notes` for \
                anything it has to tell you. A read's entry is its listing. A batch whose ops \
                changed nothing has `unchanged: true` and no `seq`. \(writeToolCaveats)
                """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) every op works on."]),
                    "ops": .object([
                        "type": "array",
                        "description": "The tool calls, in the order they are applied.",
                        "minItems": 1,
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "tool": .object(["type": "string", "description": "A tool name, e.g. add_arrow."]),
                                "arguments": .object(["type": "object", "description": "That tool's arguments, without docId."]),
                            ]),
                            "required": .array(["tool"].map(Value.string)),
                            "additionalProperties": .bool(false),
                        ]),
                    ]),
                ]),
                "required": .array(["docId", "ops"].map(Value.string)),
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
                    "docId": .object(["type": "string", "description": "The document (its id, or its name when no other document has that name) to fetch."]),
                ]),
                "required": .array(["docId"].map(Value.string)),
            ])),
    ]

    /// The tool list exactly as `tools/list` serves it, strict schemas applied. Internal so schema
    /// invariants can be asserted WITHOUT standing up a client — which is what keeps those checks
    /// running on Linux and Windows, where the SDK has no SSE client transport and so
    /// `MCPAdapterTests` is compiled out wholesale (`MCP_SSE_CLIENT`).
    static var toolDefinitions: [Tool] { tools.map(strict) }

    private func handleListTools() async throws -> ListTools.Result {
        ListTools.Result(tools: Self.toolDefinitions)
    }

    /// Declare `additionalProperties: false` on a tool's input schema.
    ///
    /// The STANDARD way to say "these are the arguments and nothing else", and the reason to say
    /// it in the SCHEMA rather than only checking at call time: the constraint becomes visible to
    /// the caller in `tools/list`, so a client-side validator can catch a misspelling before the
    /// request is ever sent. `enforceKnownArguments` below is the same rule at the other end, for
    /// callers that do not validate.
    ///
    /// This is a server decision and is not negotiable per call. Offering an opt-out would defeat
    /// the point: the mistake being caught is one the caller does not know it is making, so a
    /// caller free to disable the check would disable it exactly when most confused. If a field
    /// is ever genuinely needed, NAME IT in the schema.
    ///
    /// The known cost, recorded because it is why the ecosystem has not simply standardised on
    /// strict: a protocol that sends envelope metadata ALONGSIDE tool arguments has its calls
    /// rejected at validation (modelcontextprotocol/go-sdk#892). No caller here does that — these
    /// tools are invoked directly by agents — so the trade is clearly worth it.
    static func strict(_ tool: Tool) -> Tool {
        guard case .object(var schema) = tool.inputSchema else { return tool }
        schema["additionalProperties"] = .bool(false)
        return Tool(name: tool.name, description: tool.description, inputSchema: .object(schema),
                    annotations: tool.annotations)
    }

    /// The argument names a tool declares, for the call-time half of the same rule.
    static func declaredArguments(of tool: Tool) -> Set<String> {
        guard case .object(let schema) = tool.inputSchema,
              case .object(let properties)? = schema["properties"] else { return [] }
        return Set(properties.keys)
    }

    /// Every tool call, with one post-processing step: an error that names only a SYMPTOM gets
    /// the context that makes it actionable (`enrichedError`).
    private func handleCallTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        // Every call counts as agent work, a refused one included: the host stays awake and the
        // devices keep their screens on for a while from it (`AgentWork`).
        await agentWork?.noteToolCall()
        if let refusal = Self.enforceKnownArguments(name: name, arguments: arguments) { return refusal }
        let (resolved, unresolved, refusal) = await resolvingDocRefs(arguments)
        if let refusal { return refusal }
        let arguments = resolved
        // Which kind of device the call's work was given to (`DeviceCommandBroker.servedBy`).
        let served = DeviceCommandBroker.ServedBy()
        var result = try await DeviceCommandBroker.$servedBy.withValue(served) {
            try await dispatchCallTool(name: name, arguments: arguments, unresolvedKeys: unresolved)
        }
        result = Self.naming(device: served.kind, in: result)
        if Self.liveSelectionWriteTools.contains(name), Self.mayHaveChangedTheDocument(result),
           let docId = arguments?["docId"]?.stringValue {
            await history.recordLiveSelectionChange(docId: docId)
        }
        return await enrichedError(result, tool: name, arguments: arguments)
    }

    /// A write's structured reply with the KIND of device that did its work as `device`
    /// (improvement note D2: no reply said which device had worked, and a device's kind decides
    /// how it lays text out — a `placeBy` center is where THAT device measured it). Only the
    /// structured form: a write's text stays as it is, and a read's reply is its listing. A
    /// render's metadata says `renderedBy` already. No device, an error or no structured form:
    /// unchanged.
    static func naming(device kind: String?, in result: CallTool.Result) -> CallTool.Result {
        guard let kind, result.isError != true, case .object(var fields)? = result.structuredContent,
              fields["device"] == nil else { return result }
        fields["device"] = .string(kind)
        return CallTool.Result(content: result.content, structuredContent: .object(fields), isError: result.isError)
    }

    /// Whether a live-selection write may have landed on the device. A success did; so may an op
    /// whose device went quiet or away with it (`deviceTimeout` / `deviceDisconnected`) — the
    /// device can still apply it until the request's `notAfter`. Recording a barrier for an op
    /// that did NOT land only makes the next undo refuse; not recording one for an op that did
    /// makes it reverse the older write beneath it.
    static func mayHaveChangedTheDocument(_ result: CallTool.Result) -> Bool {
        guard result.isError == true else { return true }
        guard case .text(let text, _, _)? = result.content.first else { return false }
        return text.hasPrefix("deviceTimeout") || text.hasPrefix("deviceDisconnected")
    }

    /// Tools that change the document through the user's LIVE selection. They commit in the
    /// device's own session and reach the server as its ordinary push, so no agent write is
    /// recorded for them — and without a record, an `undo_last_edit` after `draw_strokes` +
    /// `transform_selection` reversed the DRAW (review finding 23). Each leaves a barrier in the
    /// history instead, so that undo refuses and says why.
    static let liveSelectionWriteTools: Set<String> = [
        "transform_selection", "duplicate_selection", "delete_selection", "draw_selection",
        "restyle_selection",
    ]

    /// Every argument that names an EXISTING document. (`merge_docs`' `into` is not one: it names
    /// a document that does not exist yet, so it is a name and nothing resolves it.)
    static let docIdArgumentNames = ["docId", "source", "target", "baseDocId"]

    /// Every argument that names a document, resolved to the document's id — an id, or a name no
    /// other document carries (spec 2026-09-28 §4). Done once HERE so no tool can miss it.
    ///
    /// Resolution also yields the ONE spelling the server keys a document by: the store folds
    /// case, but the sessions, the live index and `AgentEditHistory` do not, and an agent writing
    /// in another case used to open a second session on the same file, unseen by the app's, whose
    /// next push overwrote the write it had just been told succeeded.
    ///
    /// A name two documents share is refused `ambiguousName`, never guessed. An unresolved
    /// reference is left as the caller wrote it (case-canonicalised): each tool answers
    /// `unknownDoc` for it, or — `replace_doc` — creates a document with that name.
    ///
    /// `unresolved` names the argument keys nothing carried, so a tool that acts on that
    /// (`replace_doc` creates) reads THIS resolution rather than resolving a second time.
    private func resolvingDocRefs(_ arguments: [String: Value]?) async
        -> (arguments: [String: Value]?, unresolved: Set<String>, refusal: CallTool.Result?) {
        guard var arguments else { return (nil, [], nil) }
        var unresolved: Set<String> = []
        for key in Self.docIdArgumentNames {
            guard case .string(let given)? = arguments[key] else { continue }
            switch await manager.resolveDocRef(given) {
            case .id(let id):
                arguments[key] = .string(id)
            case .ambiguous(let candidates):
                return (nil, [], Self.ambiguousNameResult(given, candidates))
            case .unresolved:
                arguments[key] = .string(await manager.canonicalDocId(given))
                unresolved.insert(key)
            }
        }
        return (arguments, unresolved, nil)
    }

    static func ambiguousNameResult(_ ref: String, _ candidates: [DocRefCandidate]) -> CallTool.Result {
        let formatter = ISO8601DateFormatter()
        let listed = candidates.map {
            "\($0.id) (\"\($0.name)\", modified \(formatter.string(from: $0.modifiedAt)))"
        }
        return errorResult("ambiguousName: \"\(ref)\" names \(candidates.count) documents — pass one of these ids: "
                           + listed.joined(separator: ", "))
    }

    /// The ids of every document already called exactly `name` — what the three create doors
    /// (`create_doc`, `replace_doc` of a new name, `merge_docs into:`) refuse, because a second
    /// document of that name would make every later reference to it ambiguous. Devices may still
    /// create same-named documents; this is the agent door only.
    private func documentIds(named name: String) async -> [String] {
        ((try? await manager.listDocuments()) ?? [])
            .filter { $0.name == name }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map(\.id)
    }

    /// `docExists: "<name>" is document <id>` (or `is documents <id>, <id>` for a shared name).
    static func nameTakenResult(_ name: String, ids: [String]) -> CallTool.Result {
        let noun = ids.count == 1 ? "document" : "documents"
        return errorResult("docExists: \"\(name)\" is \(noun) \(ids.joined(separator: ", "))")
    }

    /// The ONE normalisation every create door applies to a new document's name before claiming
    /// it: surrounding whitespace trimmed (the label store trims too, so an untrimmed check would
    /// pass `" Chart"` and then label a second "Chart"), and a blank name refused.
    /// Nil for a blank name; the caller answers `blankNameResult`.
    static func newDocumentName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func blankNameResult(_ argument: String) -> CallTool.Result {
        errorResult("invalidArguments: \(argument) is blank")
    }

    /// Claim a NORMALISED `name` (`newDocumentName`) for a create: refused `creationInProgress`
    /// when another create is claiming it right now, and `docExists` whenever the name already
    /// REACHES a document — its name, its name in another case, or its id in any case. The last is
    /// not pedantry: an id wins over a name in resolution, so a new document named after another's
    /// id could never be reached by its name — every reference would silently address the other
    /// document. Nil means the caller holds the claim and must `releaseName` it.
    private func claimNameForCreate(_ name: String) async -> CallTool.Result? {
        // Inserted before the first await, so two concurrent claims cannot both pass.
        guard namesBeingCreated.insert(name).inserted else { return Self.errorResult("creationInProgress") }
        let taken: [String]
        switch await manager.resolveDocRef(name) {
        case .unresolved: taken = await documentIds(named: name)   // belt and braces; normally empty
        case .id(let id): taken = [id]
        case .ambiguous(let candidates): taken = candidates.map(\.id)
        }
        if !taken.isEmpty {
            namesBeingCreated.remove(name)
            return Self.nameTakenResult(name, ids: taken)
        }
        return nil
    }

    private func releaseName(_ name: String) { namesBeingCreated.remove(name) }

    /// Write a NEW document under a fresh id and, only once the store has ACCEPTED it, give it its
    /// name: a refused create must leave no label behind (a label with no document would name a
    /// document that does not exist, and could relabel one the minted id collided with).
    /// `renameDoc` rather than a bare label so every device hears the name — the create's own
    /// `docUpdated` went out before the label existed.
    private func createNamedDocument(newId: String, name: String, bytes: Data,
                                     reply: @escaping (String, Int) -> String) async -> CallTool.Result {
        let result = await submitAndRespond(
            docId: newId, createIfMissing: true,
            fullDoc: DocumentIdentity.settingDocumentId(in: bytes, to: newId), expectation: .absent
        ) { seq in reply(newId, seq) }
        guard result.isError != true else { return result }
        // The name was validated by `newDocumentName` before the claim, so a failure here is a
        // real fault (the label file could not be written) — said, never swallowed: the document
        // exists, and the agent must not believe it can reach it by this name.
        do {
            try await manager.renameDoc(docId: newId, name: name)
        } catch {
            return Self.errorResult("internalError: created document \(newId) but could not name it "
                                    + "\"\(name)\" (\(error)); address it by its id")
        }
        return result
    }

    static func jsonText(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Refuse an argument the named tool does not declare.
    ///
    /// The call-time half of `strict` above. It exists because dropping an unknown argument is
    /// SILENT and produces a plausible wrong answer: `render_sketch` had no `scale` argument for
    /// months, and one passed by a caller was discarded — every render came back at a size nobody
    /// chose, with nothing in the reply to say so. A misspelling behaves identically.
    ///
    /// Names what was wrong AND what the tool takes, so the caller can fix it in one step rather
    /// than by bisecting its own arguments.
    static func enforceKnownArguments(name: String, arguments: [String: Value]?) -> CallTool.Result? {
        guard let arguments, !arguments.isEmpty,
              let tool = tools.first(where: { $0.name == name }) else { return nil }
        let declared = declaredArguments(of: tool)
        guard !declared.isEmpty else { return nil }   // a tool that declares none takes anything
        guard let unknown = arguments.keys.sorted().first(where: { !declared.contains($0) }) else {
            return nil
        }
        return errorResult("invalidArgument: \(unknown) — \(name) takes "
                           + declared.sorted().joined(separator: ", "))
    }

    /// Turn a dead-end error into a self-correcting one.
    ///
    /// The failure this exists for: an agent aiming at a name that is not the live mirror `docId`
    /// (a filename stem) misses the live session and is told `noSelectionActive` — with no way to
    /// learn that `grok2 test` and `Untitled 16 1 1` are the same open document. The server knows
    /// both. Saying so costs nothing and removes the guesswork.
    ///
    /// The original trigger was a document renamed WHILE OPEN, which kept the id it was registered
    /// under. The app now re-keys its mirror entry at the rename, so that particular divergence is
    /// closed at the source; an id quoted from earlier in a conversation still produces it.
    ///
    /// Applied at THIS seam rather than at the ~57 `errorResult("unknownDoc")` call sites: one
    /// place to keep correct, and it also catches the device-relayed `deviceFailed:
    /// noSelectionActive` string, which no call-site edit could reach. Anything else — every
    /// other error, and every success — passes through untouched.
    private func enrichedError(_ result: CallTool.Result, tool: String,
                               arguments: [String: Value]?) async -> CallTool.Result {
        guard result.isError == true,
              let first = result.content.first,
              case .text(let text, _, _) = first
        else { return result }

        if text == "deviceTimeout" || text == "deviceDisconnected" {
            return Self.errorResult("\(text) — \(Self.deviceLostClause(tool: tool))")
        }

        if text == "unknownDoc" {
            // A content tool says `unknownDoc` when `currentBytesOrFetch` comes back empty, which
            // also happens for a document a device ADVERTISES but cannot hand over right now. Said
            // as "no document named X. Documents: X", the reply contradicted itself; say what
            // `fetch_doc` says for the same state.
            if let docId = arguments?["docId"]?.stringValue,
               await manager.liveEntry(docId: docId) != nil {
                return Self.errorResult(
                    "contentUnavailable: \"\(docId)\" exists, but no device holding it answered; "
                    + "try again when it is online (fetch_doc reports the same)")
            }
            let named = (arguments?["docId"]?.stringValue).map { " named \"\($0)\"" } ?? ""
            let listed = ((try? await manager.listDocuments()) ?? [])
                .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
                .map { "\"\($0.name)\" (\($0.id))" }
            return Self.errorResult("unknownDoc: no document\(named). \(Self.documentsClause(listed))")
        }

        if text == "noDeviceAvailable" {
            // Two different problems wear this one word: nothing connected at all, or something
            // connected that cannot do this particular job.
            let (count, capabilities) = await broker.connectionSummary()
            guard count == 0 else {
                return Self.errorResult("\(text) — \(count) device(s) connected, none offering the capability "
                    + "this tool needs (offered: \(capabilities.sorted().joined(separator: ", ")))")
            }
            // Nothing connected. Say what the caller cannot know: that this call already waited,
            // and how long the last device has been gone — "it left 20 s ago" and "it left two
            // hours ago" are different situations with the same word.
            let waited = await broker.configuredDeviceWait
            var clause = "no device is connected to this server"
            if let gone = await broker.lastDeviceLeftAgo {
                clause += ": the last one disconnected \(DeviceCommandBroker.worded(gone)) ago"
                    + (waited > .zero ? ", and none came back in the \(DeviceCommandBroker.worded(waited)) this call waited" : "")
                    + ". A phone or tablet disconnects when its screen locks; unlock it with the app "
                    + "in front (mirror enabled) and call again"
            } else {
                clause += (waited > .zero ? " (this call waited \(DeviceCommandBroker.worded(waited)) for one)" : "")
                    + ". Open the app with the mirror enabled"
            }
            return Self.errorResult("\(text) — \(clause)")
        }

        if text == Self.documentNotOpenReason {
            // The broker found no capable device with this document open, so no device was
            // asked. Name what IS open: the usual cause is an id that is not the live one.
            let live = await manager.liveInfo()
                .filter { $0.value.subscriberCount > 0 }
                .keys.sorted()
            let clause = live.isEmpty
                ? "no document is open on any connected device"
                : "open on a connected device: " + live.map { "\"\($0)\"" }.joined(separator: ", ")
            return Self.errorResult("\(text) — \(clause)")
        }

        if text == "noSelectionActive" || text.hasSuffix("noSelectionActive") {
            // A device ANSWERED `noSelectionActive`. Live-state ops are routed only to a device
            // that has the named document open (the broker's `.requireOpen`), so the device that
            // answered is the one the user is looking at, and it is authoritative: the document
            // is open and nothing is selected. It used to be whichever device spoke last, and this
            // branch then assured the agent "it IS open" on the strength of ANOTHER device's
            // subscription (review finding 20).
            //
            // The one case left to explain is an op that names no open document at all — the
            // device answered for an id it does not have (a race with a close, or a document
            // opened under another spelling).
            let live = await manager.liveInfo()
                .filter { $0.value.subscriberCount > 0 }
                .keys.sorted()
            if let named = arguments?["docId"]?.stringValue, live.contains(named) {
                return result          // it is open there: `noSelectionActive` means what it says
            }
            let clause = live.isEmpty
                ? "no document is open on any connected device"
                : "open on a connected device: " + live.map { "\"\($0)\"" }.joined(separator: ", ")
            return Self.errorResult("\(text) — \(clause)")
        }

        return result
    }

    /// What a call whose device went quiet or away has, and has not, done — the one thing the
    /// caller needs before deciding to send it again, and could not know: a drawing script lost
    /// its device in the middle of an `add_formula` and the bare `deviceDisconnected` did not
    /// say whether the formula was in the document (2026-11-21).
    ///
    /// For every tool that works on a document's BYTES the answer is certain: the device only
    /// computes, and the server writes after it has answered — no answer, no write. The tools
    /// that act on the device's own state are the exception: the request may still be carried
    /// out there until it expires.
    static func deviceLostClause(tool: String) -> String {
        if liveSelectionWriteTools.contains(tool) || liveSelectionStateTools.contains(tool) {
            return "the device may still apply this to its live selection (a request expires a few seconds "
                + "after its timeout): read the state with get_selection before sending it again"
        }
        if deviceSettingWriteTools.contains(tool) {
            return "the device may still have changed this setting: read it back before sending the call again"
        }
        return "NOTHING WAS WRITTEN by this call: a document is written only after the device has answered, "
            + "so sending it again cannot apply it twice"
    }

    /// Tools that change the device's selection state without writing the document.
    static let liveSelectionStateTools: Set<String> = [
        "select_all", "select_elements", "set_reference_point", "clear_selection",
    ]

    /// Tools that write a DEVICE setting (the arrow presets, the new-arrow style), on its main
    /// actor, through the store its own UI uses.
    static let deviceSettingWriteTools: Set<String> = [
        "save_arrow_preset", "rename_arrow_preset", "delete_arrow_preset", "move_arrow_preset",
        "restore_arrow_presets", "set_new_arrow_style",
    ]

    /// "Documents: "a" (id), "b" (id)" — capped, because a store with dozens of documents should
    /// not answer a mistyped name with a wall of text. `listed` is already rendered.
    private static func documentsClause(_ listed: [String], limit: Int = 12) -> String {
        guard !listed.isEmpty else { return "This server holds no documents." }
        let shown = listed.prefix(limit).joined(separator: ", ")
        let more = listed.count > limit ? " (+\(listed.count - limit) more)" : ""
        return "Documents: \(shown)\(more)"
    }

    private func dispatchCallTool(name: String, arguments: [String: Value]?,
                                  unresolvedKeys: Set<String>) async throws -> CallTool.Result {
        switch name {
        case "transform_elements": return await callTransformElements(arguments)
        case "undo_last_edit": return await callUndoLastEdit(arguments)
        case "draw_dots": return await callDrawDots(arguments)
        case "fill_region": return await callFillRegion(arguments)
        case "list_docs": return await callListDocs()
        case "list_open_docs": return await callListOpenDocs()
        case "tag_elements": return await callTagElements(arguments)
        case "find_elements": return await callFindElements(arguments)
        case "list_tags": return await callListTags(arguments)
        case "add_text": return await callAddText(arguments)
        case "add_image": return await callAddImage(arguments)
        case "edit_text": return await callEditText(arguments)
        case "remove_text": return await callRemoveText(arguments)
        case "remove_arrow": return await callRemoveArrow(arguments)
        case "add_formula": return await callAddFormula(arguments)
        case "edit_formula": return await callEditFormula(arguments)
        case "list_formulas": return await callListFormulas(arguments)
        case "remove_formula": return await callRemoveFormula(arguments)
        case "delete_doc": return await callDeleteDoc(arguments)
        case "remove_image": return await callRemoveImage(arguments)
        case "set_pinned": return await callSetPinned(arguments)
        case "set_paper": return await callSetPaper(arguments)
        case "replace_doc": return await callReplaceDoc(arguments, docIdResolved: !unresolvedKeys.contains("docId"))
        case "create_doc": return await callCreateDoc(arguments)
        case "draw_strokes": return await callDrawStrokes(arguments)
        case "delete_strokes": return await callDeleteStrokes(arguments)
        case "list_strokes": return await callListStrokes(arguments)
        case "list_texts": return await callListTexts(arguments)
        case "list_arrows": return await callListArrows(arguments, op: "listArrows")
        case "list_arrow_presets": return await callListArrows(arguments, op: "listArrowPresets")
        case "save_arrow_preset": return await callArrowPresetOp(arguments, op: "saveArrowPreset")
        case "rename_arrow_preset": return await callArrowPresetOp(arguments, op: "renameArrowPreset")
        case "delete_arrow_preset": return await callArrowPresetOp(arguments, op: "deleteArrowPreset")
        case "move_arrow_preset": return await callArrowPresetOp(arguments, op: "moveArrowPreset")
        case "restore_arrow_presets": return await callArrowPresetOp(arguments, op: "restoreArrowPresets")
        case "get_new_arrow_style": return await callArrowPresetOp(arguments, op: "getNewArrowStyle")
        case "set_new_arrow_style": return await callArrowPresetOp(arguments, op: "setNewArrowStyle")
        case "add_arrow": return await callArrowWrite(arguments, op: "addArrow")
        case "add_shape": return await callArrowWrite(arguments, op: "addShape")
        case "restyle_arrows": return await callArrowWrite(arguments, op: "restyleArrows")
        case "reshape_arrow": return await callArrowWrite(arguments, op: "reshapeArrow")
        case "list_images": return await callListImages(arguments)
        case "list_grids": return await callListGrids(arguments)
        case "add_grid": return await callAddGrid(arguments)
        case "update_grid": return await callUpdateGrid(arguments)
        case "remove_grid": return await callRemoveGrid(arguments)
        case "set_grid_origin": return await callSetGridOrigin(arguments)
        case "reorder_grids": return await callReorderGrids(arguments)
        case "render_sketch": return await callRenderSketch(arguments)
        case "export_sketch": return await callExportSketch(arguments)
        case "get_strokes": return await callGetStrokes(arguments)
        case "snap_points": return await callSnapPoints(arguments)
        case "transform_strokes": return await callTransformStrokes(arguments)
        case "restore_stroke_widths": return await callRestoreStrokeWidths(arguments)
        case "reset_element_transforms": return await callResetElementTransforms(arguments)
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
        case "diff_docs": return await callDiffDocs(arguments, unresolvedKeys: unresolvedKeys)
        case "reorder_elements": return await callReorderElements(arguments)
        case "set_layer": return await callSetLayer(arguments)
        case "fetch_doc": return await callFetchDoc(arguments)
        case "batch": return await callBatch(arguments)
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
            guard arguments?["text"] != nil else {
                return Self.errorResult("missingArgument: text — add_text takes `text` or `spans`")
            }
            let text = try Self.stringArg(arguments, "text")
            let x = try Self.doubleArg(arguments, "canvasX")
            let y = try Self.doubleArg(arguments, "canvasY")
            let pinned = try Self.boolArg(arguments, "pinned", default: false)
            let inlineMath = try Self.optionalBoolArg(arguments, "inlineMath")

            guard let bytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let newId = UUID()
            let out: Data
            do {
                out = try DocJSON.addText(to: bytes, id: newId, text: text, x: x, y: y, pinned: pinned, inlineMath: inlineMath)
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
            let inlineMath = try Self.optionalBoolArg(arguments, "inlineMath")

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("addText")]
            for key in ["text", "canvasX", "canvasY", "pinned", "color", "fontSize", "bold", "italic", "family", "weight", "spans", "tags", "colorAppearance", "anchor", "anchorParagraphs", "wordWrap", "wrapWidth", "layer", "placeBy"] {
                if let value = arguments?[key], !value.isNull {
                    envelope[key] = value
                }
            }
            // Beside `placeBy` the device is told a said `inlineMath` too, so that it places the
            // box the text will be SHOWN with (see `callEditTextStyled`).
            if envelope["placeBy"] != nil, let inlineMath { envelope["inlineMath"] = .bool(inlineMath) }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: Self.textWriteCapability(arguments))
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            let meta = out.meta.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            let newId = meta?["id"]
            // A said `inlineMath` is written by the server on the device's bytes (B2); an omitted
            // one is the device's: it gives a new text the document's default itself.
            var fullDoc = out.bytes
            if let inlineMath {
                guard let newId else { return Self.errorResult("deviceFailed: the reply names no text id") }
                do {
                    fullDoc = try DocJSON.setInlineMath(in: out.bytes, textId: newId, to: inlineMath)
                } catch let error as DocJSON.DocJSONError {
                    return Self.errorResult(Self.reason(for: error))
                }
            }

            // The box the device measured — unless the server then switched formulas on or off,
            // which gives the text another box than the one that was measured.
            let bounds = fullDoc == out.bytes ? meta?["canvasBounds"] : nil
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: fullDoc, expectedBytes: docBytes
            ) { seq in
                var summary = "added styled text at seq \(seq)"
                if let newId {
                    summary += "\nid: \(newId)"
                }
                // The box the device laid out (`TextAuthoring.replyMeta`), as add_image reports its own.
                if let bounds { summary += "\ncanvasBounds: [\(bounds)]" }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Reads the file `add_image`'s `path` names and returns its bytes, or the tool error that
    /// says why it could not (spec `2026-08-11-agent-add-image-path-design.md`).
    ///
    /// `path` REPLACED a base64 `bytes` argument. The bytes made a round trip through the calling
    /// agent's context — an agent reported that a 19 KB PNG became 25 000 characters it had to
    /// transcribe by hand, and that its transcription is what corrupted the image. The server sits
    /// next to the file; it can just read it.
    ///
    /// A RELATIVE path is refused rather than resolved against the server's working directory: the
    /// caller cannot see that directory, so resolving would give a wrong answer that looks right.
    enum ImageFileRead: Equatable {
        case bytes(Data)
        /// A tool-error reason, ready for `errorResult`.
        case refusal(String)
    }

    static func readImageFile(at rawPath: String) -> ImageFileRead {
        let path = NSString(string: rawPath).expandingTildeInPath
        guard isAbsolutePath(path) else { return .refusal("imagePathNotAbsolute: \(rawPath)") }
        let url = URL(fileURLWithPath: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .refusal("imageFileNotFound: \(path)")
        }
        guard !isDirectory.boolValue else { return .refusal("imageFileUnreadable: \(path) is a directory") }

        // Check the size BEFORE reading, so a mistyped path at something enormous refuses instead
        // of being loaded into memory to find out.
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
           size > maxImageFileBytes {
            return .refusal(
                "imageTooLarge: \(path) is \(size / 1_000_000) MB, limit \(maxImageFileBytes / 1_000_000) MB")
        }

        guard let data = try? Data(contentsOf: url) else {
            return .refusal("imageFileUnreadable: \(path)")
        }
        guard !data.isEmpty else { return .refusal("imageFileEmpty: \(path)") }
        guard data.count <= maxImageFileBytes else {
            return .refusal(
                "imageTooLarge: \(path) is \(data.count / 1_000_000) MB, limit \(maxImageFileBytes / 1_000_000) MB")
        }

        // Structural check, no decoding — see ImageContainer for why a decoder cannot do this.
        if case .broken(let why) = ImageContainer.inspect(data) {
            return .refusal("imageCorrupt: \(path) (\(why))")
        }
        return .bytes(data)
    }

    static let maxImageFileBytes = 64 * 1_000_000

    /// This server runs on macOS, Linux AND Windows, so "absolute" is not just a leading slash:
    /// a Windows path is `C:\…` or a `\\server\share` UNC.
    static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\") { return true }
        let chars = Array(path)
        return chars.count >= 3 && chars[0].isLetter && chars[1] == ":"
            && (chars[2] == "\\" || chars[2] == "/")
    }

    /// `add_image` (Task 2): relays an `addImage` device op — `{op, imageBytes
    /// (base64), canvasX, canvasY, canvasWidth?, canvasHeight?, opacity?}`, present-only
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
            let path = try Self.stringArg(arguments, "path")
            let imageBytes: Data
            switch Self.readImageFile(at: path) {
            case .bytes(let data): imageBytes = data
            case .refusal(let reason): return Self.errorResult(reason)
            }
            let x = try Self.doubleArg(arguments, "canvasX")
            let y = try Self.doubleArg(arguments, "canvasY")
            let width = try Self.optionalDoubleArg(arguments, "canvasWidth")
            let height = try Self.optionalDoubleArg(arguments, "canvasHeight")
            let opacity = try Self.optionalDoubleArg(arguments, "opacity")

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            // `imageBytes` is a whole FILE and travels as a bundle part — the spec is not chunked,
            // so a photograph in it made a frame the device refuses (see `OpSpecBundle`).
            var envelope: [String: Value] = [
                "op": .string("addImage"),
                "canvasX": .double(x), "canvasY": .double(y),
            ]
            if let width { envelope["canvasWidth"] = .double(width) }
            if let height { envelope["canvasHeight"] = .double(height) }
            if let opacity { envelope["opacity"] = .double(opacity) }
            if let tags = try Self.optionalStringArrayArg(arguments, "tags") { envelope["tags"] = .array(tags.map(Value.string)) }
            let layer = try Self.optionalStringArg(arguments, "layer")
            if let layer {
                guard layer == "front" || layer == "back" else { return Self.errorResult("invalidArguments: layer must be front or back") }
                envelope["layer"] = .string(layer)
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                // An app without `objectLayerWrites` would place it in back and answer success.
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec,
                    capability: layer == nil ? "authorImage" : "authorImage+objectLayerWrites",
                    specParts: [.imageBytes: imageBytes])
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var summary = "added image to \(docId) at seq \(seq)"
                // The device reports what it actually placed. `pixelWidth`/`pixelHeight` are the
                // SOURCE image's own dimensions, which no other tool can give: list_images
                // reports canvasBounds and never the pixels behind it, so without this an agent
                // has no way to learn the aspect ratio and must render, look, and guess.
                //
                // Every value is a STRING, keeping `meta` a [String: String] on both sides of the
                // wire — a new device against an old server still decodes, and a new server
                // against an old device simply omits these lines. A typed struct would make a
                // reply-only improvement force the two repos to deploy together.
                if let meta = out.meta,
                   let decoded = try? JSONDecoder().decode([String: String].self, from: meta) {
                    if let id = decoded["id"] { summary += "\nid: \(id)" }
                    if let bounds = decoded["canvasBounds"] { summary += "\ncanvasBounds: [\(bounds)]" }
                    if let w = decoded["pixelWidth"] { summary += "\npixelWidth: \(w)" }
                    if let h = decoded["pixelHeight"] { summary += "\npixelHeight: \(h)" }
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
        // New characters on an ANCHORED text: the device re-lays it so the anchor point stays
        // put, which the server-side path cannot (it has no text layout).
        // The one read is handed to the server-side path, so its CAS token is the bytes this
        // decision was made on.
        //
        // A new POSITION for a text that is turned or scaled: where its corner is shown depends
        // on its laid-out size, so the device places it too (`DocJSON.textPlacementNeedsDevice`;
        // a text that was only dragged is placed here, its translation taken off).
        var prefetched: Data?
        func given(_ key: String) -> Bool { arguments?[key].map { !$0.isNull } ?? false }
        let replacesText = given("text"), moves = given("canvasX") || given("canvasY")
        if replacesText || moves,
           case .string(let docId)? = arguments?["docId"], case .string(let textId)? = arguments?["textId"],
           let bytes = await documentBytes(docId: docId) {
            if replacesText, DocJSON.textHasAnchor(in: bytes, textId: textId) {
                return await callEditTextStyled(arguments)
            }
            if moves, DocJSON.textPlacementNeedsDevice(in: bytes, textId: textId) {
                return await callEditTextStyled(arguments)
            }
            prefetched = bytes
        }
        return await callEditTextServerSide(arguments, prefetched: prefetched)
    }

    /// The pre-styled_text `edit_text` body, extracted verbatim — same
    /// behaviour, same tests (see plainEditTextStillUsesTheServerSidePathAndDoesNotRelay).
    private func callEditTextServerSide(_ arguments: [String: Value]?, prefetched: Data? = nil) async -> CallTool.Result {
        do {
            let docId = try Self.stringArg(arguments, "docId")
            let textId = try Self.stringArg(arguments, "textId")
            let newText = try Self.optionalStringArg(arguments, "text")
            let x = try Self.optionalDoubleArg(arguments, "canvasX")
            let y = try Self.optionalDoubleArg(arguments, "canvasY")
            let inlineMath = try Self.optionalBoolArg(arguments, "inlineMath")

            var read = prefetched
            if read == nil { read = await documentBytes(docId: docId) }
            guard let bytes = read else {
                return Self.errorResult("unknownDoc")
            }
            let out: Data
            do {
                out = try DocJSON.editText(in: bytes, textId: textId, newText: newText, x: x, y: y, inlineMath: inlineMath)
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
            let inlineMath = try Self.optionalBoolArg(arguments, "inlineMath")

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("editText"), "textId": .string(textId)]
            for key in ["text", "canvasX", "canvasY", "color", "fontSize", "bold", "italic", "family", "weight", "spans", "colorAppearance", "anchor", "anchorParagraphs", "wordWrap", "wrapWidth", "placeBy"] {
                if let value = arguments?[key], !value.isNull {
                    envelope[key] = value
                }
            }
            // A position for a text that carries a transform means "where it is SHOWN" only to an
            // app that has `placeBy`; an older one writes the origin under the transform and
            // answers success. So such an edit asks for that app, whether or not it names a point.
            let moves = envelope["canvasX"] != nil || envelope["canvasY"] != nil
            var capability = Self.textWriteCapability(arguments)
            if moves, envelope["placeBy"] == nil, DocJSON.textIsTransformed(in: docBytes, textId: textId) {
                capability += "+placeBy"
            }
            // Beside `placeBy` the device is told a said `inlineMath` too, so that it places the
            // box the text will be SHOWN with (an app with `placeBy` reads the key; no other is
            // ever sent it).
            if envelope["placeBy"] != nil, let inlineMath { envelope["inlineMath"] = .bool(inlineMath) }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: docBytes, spec: spec, capability: capability)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // A said `inlineMath` is written by the server on the device's bytes (B2).
            var fullDoc = out.bytes
            if let inlineMath {
                do {
                    fullDoc = try DocJSON.setInlineMath(in: out.bytes, textId: textId, to: inlineMath)
                } catch let error as DocJSON.DocJSONError {
                    return Self.errorResult(Self.reason(for: error))
                }
            }

            // The box the device measured — unless the server then switched formulas on or off,
            // which gives the text another box than the one that was measured.
            let bounds = fullDoc == out.bytes
                ? out.meta.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["canvasBounds"] : nil
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: fullDoc, expectedBytes: docBytes
            ) { seq in
                "edited \(textId) at seq \(seq)" + (bounds.map { "\ncanvasBounds: [\($0)]" } ?? "")
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

            guard let docBytes = await documentBytes(docId: docId) else {
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

            guard let bytes = await documentBytes(docId: docId) else {
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

    /// `remove_arrow` — server-side, like remove_text: no device, works on a closed document.
    private func callRemoveArrow(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let arrowId = try Self.nonEmptyStringArg(arguments, "arrowId")
            guard let bytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let out: Data
            do {
                out = try DocJSON.removeArrow(from: bytes, arrowId: arrowId)
            } catch let error as DocJSON.DocJSONError {
                return Self.errorResult(Self.reason(for: error))
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out, expectedBytes: bytes
            ) { seq in
                "removed arrow \(arrowId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    // MARK: - Formula objects (format 7)
    //
    // `add_formula` / `edit_formula` / `list_formulas` go to a device that says `formulas`: only a
    // device can typeset, and the reply carries what it measured. `remove_formula` is the
    // server's own JSON edit, like `remove_arrow`. The server refuses before any device is asked
    // only what it can judge without typesetting — a blank source and one that is too long
    // (`formulaSourceRefusal`), by the device's own names; everything else is the device's, and
    // its refusal is forwarded by name.

    /// `add_formula` — the arguments given are relayed verbatim (the device validates), the result
    /// written back under the byte CAS.
    private func callAddFormula(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let latex = try Self.stringArg(arguments, "latex")
            _ = try Self.doubleArg(arguments, "canvasX")
            _ = try Self.doubleArg(arguments, "canvasY")
            if let refusal = Self.formulaSourceRefusal(latex) { return Self.errorResult(refusal) }
            guard let bytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var envelope: [String: Value] = ["op": .string("addFormula")]
            for key in ["latex", "canvasX", "canvasY", "fontSize", "color", "colorAppearance", "layer", "tags", "placeBy", "styleBase", "anchor"] {
                if let value = arguments?[key], !value.isNull { envelope[key] = value }
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(envelope)) }
            catch { return Self.errorResult("invalidArguments") }
            // An app without `placeBy` would ignore the key and place by the baseline; one
            // without `styleBase` would take the user's text style; one without `formulaAnchor`
            // would store no anchor.
            return await relayFormulaWrite(docId: docId, bytes: bytes, spec: spec,
                                           capability: "formulas" + (envelope["placeBy"] == nil ? "" : "+placeBy")
                                               + (envelope["styleBase"] == nil ? "" : "+styleBase")
                                               + (envelope["anchor"] == nil ? "" : "+formulaAnchor"))
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `edit_formula` — like `add_formula`; the device refuses an edit that names none of
    /// `latex` / `fontSize` / `color` / a place / `anchor`, and `colorAppearance` without `color`.
    private func callEditFormula(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            _ = try Self.nonEmptyStringArg(arguments, "id")
            if let latex = try Self.optionalStringArg(arguments, "latex"),
               let refusal = Self.formulaSourceRefusal(latex) {
                return Self.errorResult(refusal)
            }
            guard let bytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var envelope: [String: Value] = ["op": .string("editFormula")]
            for key in ["id", "latex", "fontSize", "color", "colorAppearance", "canvasX", "canvasY", "placeBy", "anchor"] {
                if let value = arguments?[key], !value.isNull { envelope[key] = value }
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(envelope)) }
            catch { return Self.errorResult("invalidArguments") }
            // A position is new with `placeBy`: an app without it would ignore all three keys
            // and answer an edit that moved nothing. The same for `anchor` and `formulaAnchor`.
            let places = ["canvasX", "canvasY", "placeBy"].contains { envelope[$0] != nil }
            return await relayFormulaWrite(docId: docId, bytes: bytes, spec: spec,
                                           capability: "formulas" + (places ? "+placeBy" : "")
                                               + (envelope["anchor"] == nil ? "" : "+formulaAnchor"))
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// The shared tail of `add_formula` / `edit_formula`: ask a `formulas` device, write what it
    /// returned under the byte CAS, and answer with what it MEASURED (`{id, typeset, message?,
    /// canvasBounds, canvasBaseline}`, its reply `meta`) plus the `seq`. The device answers an edit that changes
    /// nothing with the request's own bytes: then nothing is written (a pointless write bumps
    /// `seq` for every subscriber and spends the agent's one `undo_last_edit`) and the reply says
    /// `unchanged: true`, without a `seq`.
    private func relayFormulaWrite(docId: String, bytes: Data, spec: Data,
                                   capability: String = "formulas") async -> CallTool.Result {
        let out: DeviceCommandBroker.StrokeOpReply
        do {
            out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec, capability: capability)
        } catch let error as DeviceCommandBroker.DeviceCommandError {
            return Self.strokeOpErrorResult(error)
        } catch {
            return Self.errorResult("deviceFailed: \(error)")
        }
        // An absent or undecodable meta still writes (the bytes are the device's own, CAS-guarded);
        // the reply then carries only what is known.
        let measured = out.meta.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if out.bytes == bytes {
            var reply = measured
            reply["unchanged"] = true
            return Self.textResult(Self.jsonText(reply))
        }
        return await submitAndRespond(
            docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: bytes
        ) { seq in
            var reply = measured
            reply["seq"] = seq
            return Self.jsonText(reply)
        }
    }

    /// `list_formulas` — read-only, relayed to a `formulas` device (an older app has none and is
    /// never asked); its bare JSON array is passed straight through.
    private func callListFormulas(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(["op": .string("listFormulas")])) }
            catch { return Self.errorResult("invalidArguments") }
            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec, capability: "formulas")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return Self.textResult(String(data: out.bytes, encoding: .utf8) ?? "")
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `remove_formula` — server-side, like remove_arrow: no device, works on a closed document.
    private func callRemoveFormula(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let formulaId = try Self.nonEmptyStringArg(arguments, "id")
            guard let bytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let out: Data
            do {
                out = try DocJSON.removeFormula(from: bytes, formulaId: formulaId)
            } catch let error as DocJSON.DocJSONError {
                return Self.errorResult(Self.reason(for: error))
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out, expectedBytes: bytes
            ) { seq in
                "removed formula \(formulaId) at seq \(seq)"
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
    /// Registered with `SessionManager` so EVERY delete — an in-app delete, a rename (the WS
    /// `deleteDoc` the app sends for the old name), `delete_doc` — forgets the document's agent
    /// history. Only `delete_doc` did, so a recycled name inherited the old document's edits and
    /// the next undo merged old content into the new document (review finding 23).
    func forgetHistory(docId: String) async {
        await history.forget(docId: docId)
    }

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

            guard let bytes = await documentBytes(docId: docId) else {
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

            guard let bytes = await documentBytes(docId: docId) else {
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
            guard let bytes = await documentBytes(docId: docId) else {
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
    private func callReplaceDoc(_ arguments: [String: Value]?, docIdResolved: Bool) async -> CallTool.Result {
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
            // A reference no document carries (by id or by name): a NEW document named by it, with
            // its own fresh id — the reference was never an id the agent could choose.
            if !docIdResolved {
                guard let name = Self.newDocumentName(docId) else { return Self.blankNameResult("docId") }
                // …unless it is shaped like an id: that is a stale id (a deleted document, another
                // server's), and a document labelled with a UUID is not what the agent asked for.
                if UUID(uuidString: name) != nil { return Self.errorResult("unknownDoc") }
                if let refusal = await claimNameForCreate(name) { return refusal }
                defer { releaseName(name) }
                return await createNamedDocument(newId: mintDocumentId(), name: name, bytes: bytes) { id, seq in
                    Self.jsonText(["docId": id, "name": name, "seq": seq])
                }
            }
            let currentBytes = await manager.currentBytes(docId: docId)
            // …but a metadata-only doc EXISTS: a connected device holds it. Creating it here from
            // the agent's bytes meant the user's own copy was unioned with them when opened — or,
            // with a stale base on the device, deleted (review finding 23). Reading it first
            // (`fetch_doc`) makes it resident, and then this is an ordinary replace.
            if currentBytes == nil, await manager.liveEntry(docId: docId) != nil {
                return Self.errorResult(
                    "docExists: a connected device holds \"\(docId)\"; read it with fetch_doc before replacing it")
            }
            // The identity belongs to the DOCUMENT, not to the bytes (`DocumentIdentity`): a
            // replace keeps the current document's id, a create gets a fresh one — the agent's
            // bytes are often another document's raw read, and must not bring its id along.
            // The store keys a document by its id, so a legacy stored document with no `documentId`
            // in its bytes gains its key as one here.
            let identity = currentBytes.flatMap(DocumentIdentity.documentId(of:)) ?? docId
            let stored = DocumentIdentity.settingDocumentId(in: bytes, to: identity)
            return await submitAndRespond(
                docId: docId, createIfMissing: true, fullDoc: stored,
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
            guard let name = Self.newDocumentName(try Self.stringArg(arguments, "name")) else {
                return Self.blankNameResult("name")
            }
            // A name any document already has — one document or several — is refused BEFORE a
            // device is woken: a second document of that name would make every later reference to
            // it ambiguous (controller ruling F13).
            if let refusal = await claimNameForCreate(name) { return refusal }
            defer { releaseName(name) }

            let newId = mintDocumentId()
            let bytes: Data
            do {
                // The device authors the empty template for the new id (it only echoes the id).
                bytes = try await broker.requestCreation(docId: newId)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                switch error {
                case .noDeviceAvailable: return Self.errorResult("noDeviceAvailable")
                // Published string stays "creationInProgress" (pinned by
                // MCPAdapterTests.createDocInFlightErrorPublishesCreationInProgress)
                // even though the case itself is now the kind-agnostic
                // `.requestInFlight`.
                case .requestInFlight: return Self.errorResult("creationInProgress")
                case .deviceTimeout: return Self.errorResult("deviceTimeout")
                case .deviceDisconnected: return Self.errorResult("deviceDisconnected")
                case .documentNotOpen: return Self.errorResult("noDeviceAvailable")   // creation routes to any device
                case .capabilityMissing: return Self.strokeOpErrorResult(error)
                case .deviceFailed(let why): return Self.errorResult("deviceFailed: \(why)")
                }
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }

            // The template carries no identity of its own: the server gives the new document one,
            // and the `.absent` expectation inside `createNamedDocument` is the atomic guard.
            return await createNamedDocument(newId: newId, name: name, bytes: bytes) { id, seq in
                Self.jsonText(["docId": id, "name": name, "seq": seq])
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

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("draw"), "strokes": .array(strokes)]
            if let value = arguments?["colorAppearance"], !value.isNull { envelope["colorAppearance"] = value }

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
                    struct Tool: Decodable {
                        let inkType: String
                        let width: Double
                        let color: String
                        /// Which of the three the strokes inherited ("inkType", "drawnWidth",
                        /// "color"), from a newer device; nil from an older one, which then reads
                        /// as all three — the reply it always printed.
                        let inherited: [String]?
                        enum CodingKeys: String, CodingKey {
                            case inkType
                            case width = "drawnWidth"
                            case color
                            case inherited
                        }
                    }
                    let keys: [String]?
                    let resolvedTool: Tool?
                    let clampedWidths: [Double]?
                    /// What was actually STORED (light-canonical), one entry per created stroke,
                    /// in order — present only when this call went through the dark door
                    /// (colorAppearance: "dark"). Absent (not merely empty) for an ordinary
                    /// light-space call, so an unrelated draw's reply stays unchanged.
                    let storedColors: [String]?
                }
                if let meta = out.meta,
                   let decoded = try? JSONDecoder().decode(DrawMeta.self, from: meta) {
                    if let keys = decoded.keys, !keys.isEmpty {
                        summary += "\nids: \(keys.joined(separator: ", "))"
                    }
                    // What an omitted colour/width/inkType actually inherited from the user's
                    // picker. Pass these back explicitly if you previewed first: the picker is
                    // live, so omitting the fields twice reads it twice.
                    //
                    // The DEVICE decides whether to send this — it is absent when the caller
                    // supplied all three fields on every stroke, because there was then nothing
                    // to inherit and reporting the picker told the caller its stroke was a width
                    // and colour it is not (measured: a stroke drawn at width 4 / #112233FF was
                    // reported back as the picker's width and color #000000FF).
                    if let tool = decoded.resolvedTool {
                        // Only what was inherited: a stroke given its width and color but no ink
                        // inherited the ink alone (final review F6).
                        let named = tool.inherited.map(Set.init) ?? ["inkType", "drawnWidth", "color"]
                        let parts = [("inkType", "inkType \(tool.inkType)"),
                                     ("drawnWidth", "drawnWidth \(Self.trimmed(tool.width))"),
                                     ("color", "color \(tool.color)")]
                            .filter { named.contains($0.0) }.map(\.1)
                        if !parts.isEmpty {
                            summary += "\ninherited from the user's tool: \(parts.joined(separator: ", "))"
                        }
                    }
                    // A width below the ink's floor renders as almost nothing, so it is raised
                    // rather than silently drawn invisible (art-session finding 12).
                    if let clamped = decoded.clampedWidths, !clamped.isEmpty {
                        summary += "\nnote: \(clamped.count) stroke(s) asked for a width "
                                 + "(\(clamped.map { String(format: "%.1f", $0) }.joined(separator: ", "))) "
                                 + "outside what that ink can draw, and were drawn at the nearest end — "
                                 + "the ink's thinnest (below it a stroke is effectively invisible) or widest. "
                                 + "list_strokes reports the drawnWidth each stroke got."
                    }
                    // Only present when colorAppearance: "dark" converted at least one colour —
                    // what actually landed on disk, light-canonical, one entry per created stroke.
                    if let stored = decoded.storedColors, !stored.isEmpty {
                        summary += "\nstoredColors: \(stored.joined(separator: ", "))"
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

            guard let docBytes = await documentBytes(docId: docId) else {
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

            guard let docBytes = await documentBytes(docId: docId) else {
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
    // MARK: - arrows (the parity list, 2026-10-14)

    /// `list_arrows` — read-only, relayed to a device with the `arrows` capability (an older app
    /// has none and is never asked).
    /// `list_arrow_presets` the same way (`op: "listArrowPresets"`): the presets are app-wide on the
    /// device, the `docId` only routes the request, as for `list_fonts`.
    private func callListArrows(_ arguments: [String: Value]?, op: String) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(["op": .string(op)])) }
            catch { return Self.errorResult("invalidArguments") }
            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec, capability: "arrows")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return CallTool.Result(content: [
                .text(text: String(data: out.bytes, encoding: .utf8) ?? "", annotations: nil, _meta: nil)
            ])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// The arrow preset writes and the new-arrow style (`arrowPresetWrites`): every argument but
    /// `docId` relayed verbatim (the device validates), the device's JSON reply passed through.
    /// Nothing is written to any document.
    private func callArrowPresetOp(_ arguments: [String: Value]?, op: String) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var envelope: [String: Value] = ["op": .string(op)]
            for key in Self.arrowPresetOpKeys {
                if let value = arguments?[key], !value.isNull { envelope[key] = value }
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(envelope)) }
            catch { return Self.errorResult("invalidArguments") }
            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                                       capability: "arrowPresetWrites")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return CallTool.Result(content: [
                .text(text: String(data: out.bytes, encoding: .utf8) ?? "", annotations: nil, _meta: nil)
            ])
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Every key the preset ops relay — the preset addressing and the style fields.
    static let arrowPresetOpKeys = ["id", "name", "newName", "replace", "arrowId", "fromNewArrowStyle",
                                    "toIndex", "before", "after", "preset"] + arrowStyleKeys

    /// The style fields an agent can name, flat as on add_arrow — `ArrowAuthoring.StyleArgs` on the device.
    static let arrowStyleKeys = ["startHead", "endHead", "startAnchor", "endAnchor", "drawnWidth", "headLength",
                                 "headAngle", "endHeadLength", "endHeadAngle", "headsLinked",
                                 "dashPattern", "dashAlignment", "dashCorners", "dashAnchor", "dashEndsOn", "dashOffset",
                                 "color", "colorAppearance", "opacity", "layer", "keepsWidth", "cornerJoin", "cornerMiterLimit"]

    static func mergeProperties(_ a: [String: Value], _ b: [String: Value]) -> [String: Value] {
        a.merging(b) { first, _ in first }
    }

    /// The schema of every style field (`arrowStyleKeys`), shared by the preset tools.
    static var arrowStyleProperties: [String: Value] {
        let heads = Value.array(["roundEnd", "flatEnd", "openChevron", "openChevronRoundTip", "openChevronRoundWings", "openChevronRound", "filledTriangle", "filledTriangleRoundTip", "filledTriangleRoundWings", "filledTriangleRound"].map(Value.string))
        let anchors = Value.array(["endsAtPoint", "centeredOnPoint"].map(Value.string))
        return [
            "startHead": .object(["type": "string", "enum": heads, "description": "The shape at the start."]),
            "endHead": .object(["type": "string", "enum": heads, "description": "The shape at the end — the head."]),
            "startAnchor": .object(["type": "string", "enum": anchors, "description": "Where the start's ink sits on its point."]),
            "endAnchor": .object(["type": "string", "enum": anchors, "description": "Where the end's ink sits on its point."]),
            "drawnWidth": .object(["type": "number", "description": "Line width in canvas points (0.5–40)."]),
            "headLength": .object(["type": "number", "description": "Head length in arrow widths (2–10)."]),
            "headAngle": .object(["type": "number", "description": "Half the angle at each head's tip, in degrees (15–60)."]),
            "endHeadLength": .object(["type": "number", "description": "The end head's own length in widths (2–10); unlinks the heads."]),
            "endHeadAngle": .object(["type": "number", "description": "The end head's own tip half-angle in degrees (15–60); unlinks the heads."]),
            "headsLinked": .object(["type": "boolean", "description": "Link (both heads take the start head's values) or unlink the heads."]),
            "dashPattern": .object(["type": "array", "items": .object(["type": "number"]), "description": "Dash, gap … in widths; [] is solid."]),
            "dashAlignment": .object(["type": "string", "enum": .array(["fitGaps", "fitPattern", "exact"].map(Value.string)), "description": "How the dash pattern is laid along the shaft (see add_arrow)."]),
            "dashCorners": .object(["type": "boolean", "description": "The fit modes' Corners switch (see add_arrow)."]),
            "dashAnchor": .object(["type": "string", "enum": .array(["start", "end", "center"].map(Value.string)), "description": "Where an exact pattern starts."]),
            "dashEndsOn": .object(["type": "string", "enum": .array(["dash", "gap", "halfDash"].map(Value.string)), "description": "What a fitted shaft's ends finish on."]),
            "dashOffset": .object(["type": "number", "minimum": -50, "maximum": 50, "description": "The pattern's offset in widths (−50…50)."]),
            "color": .object(["type": "string", "description": "#RRGGBB or #RRGGBBAA, light-canonical (see colorAppearance)."]),
            "colorAppearance": .object(["type": "string", "enum": .array(["light", "dark"].map(Value.string)), "description": "\"dark\" when `color` was chosen for a dark page."]),
            "opacity": .object(["type": "number", "description": "0…1."]),
            "layer": .object(["type": "string", "enum": .array(["front", "back"].map(Value.string)), "description": "Where an arrow in this style goes: front or back."]),
            "keepsWidth": .object(["type": "boolean", "description": "Keep width when scaling (default true)."]),
            "cornerJoin": .object(["type": "string", "enum": .array(["round", "miter", "bevel"].map(Value.string)), "description": "How corners turn: round (default), miter (sharp) or bevel."]),
            "cornerMiterLimit": .object(["type": "number", "minimum": 1, "maximum": 20, "description": "A sharp corner's limit in half widths (1–20)."]),
        ]
    }

    /// An arrow's nodes, as add_arrow and reshape_arrow take them and list_arrows reports them.
    static var arrowNodesProperty: Value {
        .object([
            "type": "array",
            "description": "At least two nodes, start first: {canvasX, canvasY, type?, join?, miterLimit?, roundness?}. type corner (default; a sharp point), smooth (the curve passes through smoothly — centripetal Catmull-Rom from the neighbours; roundness 0–2 scales its tangent, 1 the default). Instead of canvasPoints.",
            "items": .object([
                "type": "object",
                "properties": .object([
                    "canvasX": .object(["type": "number"]),
                    "canvasY": .object(["type": "number"]),
                    "type": .object(["type": "string", "enum": .array(["corner", "smooth"].map(Value.string)),
                                     "description": "corner (default) or smooth."]),
                    "join": .object(["type": "string", "enum": .array(["round", "miter", "bevel"].map(Value.string)),
                                     "description": "An interior corner's join (default: the arrow's cornerJoin). Not for an end or a smooth node."]),
                    "miterLimit": .object(["type": "number", "minimum": 1, "maximum": 20, "description": "A miter corner's limit in half widths (1–20)."]),
                    "roundness": .object(["type": "number", "minimum": 0, "maximum": 2,
                                          "description": "A smooth node's roundness: how wide the bend runs through it, as a factor on its tangent — 1 the usual curve (default), 0 nearly a corner, 2 the widest. Not for a corner."]),
                ]),
                "required": .array(["canvasX", "canvasY"].map(Value.string)),
                "additionalProperties": .bool(false),
            ]),
        ])
    }

    /// `closed` on add_arrow / reshape_arrow (format 8).
    static var closedPathProperty: Value {
        .object(["type": "boolean",
                 "description": "true: a CLOSED path — the line runs on from the last point to the first and turns there like at every corner, so there is no seam, no ends and no heads. Needs three points. false: open it again (its heads return). Omitted: an open path for add_arrow, unchanged for reshape_arrow."])
    }

    /// `filled` on add_arrow / reshape_arrow.
    static var filledPathProperty: Value {
        .object(["type": "boolean",
                 "description": "true: the area a closed path encloses is painted too, in the line's color and together with the line (a translucent shape is even). Needs a closed path; opening a filled path takes `filled: false` beside `closed: false`."])
    }

    /// `add_arrow` / `restyle_arrows` — the arguments are relayed verbatim (the device validates,
    /// as for `transform_elements`), the result written back under the byte CAS.
    private func callArrowWrite(_ arguments: [String: Value]?, op: String) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            guard let bytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var envelope: [String: Value] = ["op": .string(op)]
            let keys = op == "reshapeArrow" ? ["arrowId", "canvasPoints", "nodes", "closed", "filled"]
                : op == "addShape"
                ? ["shape", "canvasRect", "canvasX", "canvasY", "radius", "diameter", "canvasPoints", "filled",
                   "drawnWidth", "dashPattern", "color", "colorAppearance", "layer", "preset", "keepsWidth", "opacity",
                   "dashAlignment", "dashCorners", "dashAnchor", "dashOffset", "cornerJoin", "cornerMiterLimit", "tags",
                   "styleBase"]
                : op == "addArrow"
                ? ["canvasPoints", "nodes", "startHead", "endHead", "startAnchor", "endAnchor", "drawnWidth",
                   "headLength", "headAngle", "endHeadLength", "endHeadAngle", "headsLinked",
                   "dashPattern", "color", "colorAppearance", "layer", "preset", "keepsWidth", "opacity",
                   "dashAlignment", "dashCorners", "dashAnchor", "dashEndsOn", "dashOffset", "cornerJoin", "cornerMiterLimit", "tags",
                   "styleBase", "closed", "filled"]
                : ["ids", "startHead", "endHead", "startAnchor", "endAnchor", "drawnWidth",
                   "headLength", "headAngle", "endHeadLength", "endHeadAngle", "headsLinked",
                   "dashPattern", "color", "colorAppearance", "opacity", "preset", "keepsWidth",
                   "dashAlignment", "dashCorners", "dashAnchor", "dashEndsOn", "dashOffset", "cornerJoin", "cornerMiterLimit"]
            for key in keys {
                if let value = arguments?[key], !value.isNull { envelope[key] = value }
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(envelope)) }
            catch { return Self.errorResult("invalidArguments") }
            let out: DeviceCommandBroker.StrokeOpReply
            do {
                // An app without `arrowTags` decodes `tags` by IGNORING it and answers success, so a
                // call that names tags goes only to a device that writes them.
                let tagged: Bool = { if case .array(let t)? = envelope["tags"] { return !t.isEmpty }; return false }()
                // The same for `styleBase`: ignored, the arrow would take the user's style.
                // And for a closed path: an app from before format 8 would ignore `closed` and
                // `filled` and answer success with an open arrow; `addShape` it does not know at all.
                let closes = op == "addShape" || envelope["closed"] != nil || envelope["filled"] != nil
                out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec,
                                                       capability: (tagged ? "arrows+arrowTags" : "arrows")
                                                           + (envelope["styleBase"] == nil ? "" : "+styleBase")
                                                           + (closes ? "+closedPaths" : ""))
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: bytes
            ) { seq in
                var summary = op == "addArrow" ? "added arrow to \(docId) at seq \(seq)"
                    : op == "addShape" ? "added shape to \(docId) at seq \(seq)"
                    : op == "reshapeArrow" ? "reshaped arrow in \(docId) at seq \(seq)"
                    : "restyled arrows in \(docId) at seq \(seq)"
                if let meta = out.meta,
                   let decoded = try? JSONDecoder().decode([String: String].self, from: meta) {
                    if let id = decoded["arrowId"] { summary += "\narrowId: \(id)" }
                    // A shape's ink box and the line width it was given (a dot's may be less
                    // than the one asked for).
                    if let bounds = decoded["canvasBounds"] { summary += "\ncanvasBounds: [\(bounds)]" }
                    if let width = decoded["drawnWidth"] { summary += "\ndrawnWidth: \(width)" }
                }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    private func callListTexts(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")

            guard let docBytes = await documentBytes(docId: docId) else {
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

            guard let docBytes = await documentBytes(docId: docId) else {
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

            guard let docBytes = await documentBytes(docId: docId) else {
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

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("addGrid")]
            for key in ["type", "spacing", "snap", "rotation", "color", "thickness", "visible", "enabled", "offset", "tags"] {
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

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = ["op": .string("updateGrid"), "id": .string(id)]
            for key in ["type", "spacing", "snap", "rotation", "color", "thickness", "visible", "enabled", "offset", "tags"] {
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

            guard let docBytes = await documentBytes(docId: docId) else {
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
            let x = try Self.doubleArg(arguments, "canvasX")
            let y = try Self.doubleArg(arguments, "canvasY")

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("setGridOrigin"), "id": .string(id), "canvasX": .double(x), "canvasY": .double(y),
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

            guard let docBytes = await documentBytes(docId: docId) else {
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
            let arrowIds = try Self.optionalStringArrayArg(arguments, "arrowIds") ?? []
            let formulaIds = try Self.optionalStringArrayArg(arguments, "formulaIds") ?? []
            let mode = try Self.stringArg(arguments, "mode")
            guard mode == "front" || mode == "back" else { return Self.errorResult("invalidArguments") }
            guard !(strokeIds.isEmpty && textIds.isEmpty && imageIds.isEmpty && arrowIds.isEmpty && formulaIds.isEmpty) else { return Self.errorResult("invalidArguments") }

            guard let bytes = await documentBytes(docId: docId) else { return Self.errorResult("unknownDoc") }
            let count = strokeIds.count + textIds.count + imageIds.count + arrowIds.count + formulaIds.count
            var reorderEnvelope: [String: Value] = [
                "op": .string("reorderElements"),
                "strokeIds": .array(strokeIds.map(Value.string)),
                "textIds": .array(textIds.map(Value.string)),
                "imageIds": .array(imageIds.map(Value.string)),
                "mode": .string(mode),
            ]
            if !arrowIds.isEmpty { reorderEnvelope["arrowIds"] = .array(arrowIds.map(Value.string)) }
            if !formulaIds.isEmpty { reorderEnvelope["formulaIds"] = .array(formulaIds.map(Value.string)) }
            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(reorderEnvelope))
            } catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                // Objects move within their LAYER only on an `objectLayerWrites` app; an older one
                // moves them within their kind and still answers success.
                var parts = ["reorderElements"]
                if !arrowIds.isEmpty { parts.append("arrows") }
                if !(textIds.isEmpty && imageIds.isEmpty && arrowIds.isEmpty && formulaIds.isEmpty) { parts.append("objectLayerWrites") }
                out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec,
                                                       capability: Self.joiningFormulas(parts.joined(separator: "+"),
                                                                                        if: !formulaIds.isEmpty))
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

    /// `set_layer`: texts, images and arrows into the front or back object layer, each landing on
    /// top of it — the Properties panel's Layer card, through the same device function.
    private func callSetLayer(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ids = try Self.optionalStringArrayArg(arguments, "ids") ?? []
            let layer = try Self.stringArg(arguments, "layer")
            guard !ids.isEmpty else { return Self.errorResult("invalidArguments: ids must name at least one element") }
            guard layer == "front" || layer == "back" else { return Self.errorResult("invalidArguments: layer must be front or back") }
            guard let bytes = await documentBytes(docId: docId) else { return Self.errorResult("unknownDoc") }
            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("setLayer"), "ids": .array(ids.map(Value.string)), "layer": .string(layer)]))
            } catch { return Self.errorResult("invalidArguments") }
            let out: DeviceCommandBroker.StrokeOpReply
            do {
                // `ids` mix kinds: a formula's id among them joins `formulas` (`idsNameAFormula`).
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: bytes, spec: spec,
                    capability: Self.joiningFormulas("reorderElements+objectLayerWrites",
                                                     if: Self.idsNameAFormula(ids, in: bytes)))
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            // The device says which ids actually changed layer. None: nothing is written (a
            // pointless write bumps `seq` for every subscriber and spends the agent's one
            // `undo_last_edit` on an edit that changed nothing). An absent or undecodable meta
            // means WRITE IT — the bytes are the device's own and the write is CAS-guarded.
            struct SetLayerMeta: Decodable {
                let movedIds: [String]
                let unchangedIds: [String]
            }
            let meta = out.meta.flatMap { try? JSONDecoder().decode(SetLayerMeta.self, from: $0) }
            if let meta, meta.movedIds.isEmpty {
                return CallTool.Result(content: [.text(
                    text: "no change: \(ids.count == 1 ? "the element is" : "all \(ids.count) elements are") "
                        + "already in the \(layer) layer — nothing was written",
                    annotations: nil, _meta: nil)])
            }
            let movedCount = meta?.movedIds.count ?? ids.count
            let unchangedCount = meta?.unchangedIds.count ?? 0
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: bytes
            ) { seq in
                var summary = "moved \(movedCount) element(s) to the \(layer) layer in \(docId) at seq \(seq)"
                if unchangedCount > 0 { summary += "; \(unchangedCount) already there" }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `tag_elements` — add, remove or replace durable element tags
    /// (spec 2026-07-28-element-tags-design.md). Device-relayed because validating that an id
    /// EXISTS means enumerating stroke composite keys, and only PencilKit can decode a drawing.
    private func callTagElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ids = try Self.nonEmptyStringArrayArg(arguments, "ids")
            let mode = try Self.optionalStringArg(arguments, "mode") ?? "add"
            guard ["add", "remove", "replace"].contains(mode) else {
                return Self.errorResult("invalidArgument: mode")
            }
            let tags = try Self.optionalStringArrayArg(arguments, "tags") ?? []
            // Only `replace` means anything with no tags — it clears. add/remove of nothing is a
            // caller mistake worth naming rather than a silent no-op.
            if tags.isEmpty && mode != "replace" { return Self.errorResult("invalidArgument: tags") }

            guard let bytes = await documentBytes(docId: docId) else { return Self.errorResult("unknownDoc") }
            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("tagElements"),
                    "ids": .array(ids.map(Value.string)),
                    "tags": .array(tags.map(Value.string)),
                    "mode": .string(mode),
                ]))
            } catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                // `ids` mix kinds: a formula's id among them joins `formulas` (`idsNameAFormula`).
                out = try await broker.requestStrokeOp(
                    docId: docId, docBytes: bytes, spec: spec,
                    capability: Self.joiningFormulas("tagElements", if: Self.idsNameAFormula(ids, in: bytes)))
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: bytes
            ) { seq in
                let verb = ["add": "added", "remove": "removed", "replace": "replaced"][mode] ?? mode
                let what = tags.isEmpty ? "cleared the tags of" : "\(verb) \(tags.count) tag(s) on"
                return "\(what) \(ids.count) element(s) in \(docId) at seq \(seq)"
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `find_elements` — resolve tags to ids. Read-only: no submit, no seq, nothing to retry.
    private func callFindElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            // `match` / `groupBy` go only to a device that knows them (`tagQueries`): an older app
            // decodes the spec ignoring both and would answer the default lookup as if it were
            // the one asked for. A call without them still reaches an older app.
            var extra: [String: Value] = [:]
            if let match = try Self.optionalStringArg(arguments, "match") {
                guard ["any", "all"].contains(match) else { return Self.errorResult("invalidArguments: match must be any or all") }
                extra["match"] = .string(match)
            }
            if let groupBy = try Self.optionalStringArg(arguments, "groupBy") {
                guard ["tag", "kind"].contains(groupBy) else { return Self.errorResult("invalidArguments: groupBy must be tag or kind") }
                extra["groupBy"] = .string(groupBy)
            }
            return await relayTagRead(arguments, op: "findElements", listKey: "tags", extra: extra,
                                      capability: extra.isEmpty ? "tagElements" : "tagElements+tagQueries")
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `list_tags` — what tags this document has, and how many elements carry each. Read-only.
    private func callListTags(_ arguments: [String: Value]?) async -> CallTool.Result {
        await relayTagRead(arguments, op: "listTags", listKey: nil)
    }

    /// The shared body of the two read-only tag relays: the device answers in `meta`, which is
    /// passed straight through as the tool's text.
    private func relayTagRead(_ arguments: [String: Value]?, op: String,
                              listKey: String?, extra: [String: Value] = [:],
                              capability: String = "tagElements") async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            var fields: [String: Value] = ["op": .string(op)]
            fields.merge(extra) { current, _ in current }
            if let listKey {
                fields[listKey] = .array(try Self.nonEmptyStringArrayArg(arguments, listKey).map(Value.string))
            }
            guard let bytes = await documentBytes(docId: docId) else { return Self.errorResult("unknownDoc") }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(fields)) }
            catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec, capability: capability)
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

    // MARK: - batch
    //
    // Several tool calls on ONE working copy, written once (improvement note S1, 2026-11-22: a
    // sheet was hundreds of single calls, each its own undo step and its own change on the canvas
    // the user was watching). It reuses every tool's own handler: a handler reads the document
    // through `documentBytes` and writes through `submitAndRespond`, and while `activeBatch` is
    // set both go to the batch's working copy instead of the session. No device op and no wire
    // message knows about batches.
    //
    // (Placed here, between two handlers that relay nothing after it: `scripts/audit-tool-arguments`
    // reads every `Self.<list>` that follows an op's envelope as keys that op sends.)

    /// The document a running `batch` is building. Read and written only by the batch's own task
    /// (`@TaskLocal`), on this actor.
    final class BatchContext: @unchecked Sendable {
        let docId: String
        /// The working copy: the document as the ops so far have left it.
        var bytes: Data
        /// The reply of the op that just ran, waiting for the batch's seq; nil when it wrote nothing.
        var pendingReply: ((Int) -> String)?
        var wrote = false

        init(docId: String, bytes: Data) {
            self.docId = docId
            self.bytes = bytes
        }

        func take(docId: String, bytes: Data, expectation: WriteExpectation,
                  successText: @escaping (Int) -> String) -> CallTool.Result {
            guard docId == self.docId else {
                return MCPAdapter.errorResult("invalidArguments: a batch writes only its own document (\(self.docId)), not \(docId)")
            }
            // Every batchable tool guards its write by the bytes it read, and it read this copy.
            guard case .matchBytes(let expected) = expectation, expected == self.bytes else {
                return MCPAdapter.errorResult("internalError: a batched op did not write the copy it read")
            }
            self.bytes = bytes
            pendingReply = successText
            wrote = true
            return MCPAdapter.textResult("")
        }
    }

    @TaskLocal private static var activeBatch: BatchContext?

    /// The bytes a tool works on: the document's current ones — or, inside a `batch` on that
    /// document, the batch's working copy. EVERY tool handler reads through here.
    private func documentBytes(docId: String) async -> Data? {
        if let batch = Self.activeBatch, batch.docId == docId { return batch.bytes }
        return await manager.currentBytesOrFetch(docId: docId)
    }

    static let maxBatchOps = 400

    /// What may run inside a batch: the tools that work on a document's BYTES — every write of
    /// that kind, and the reads an op sequence needs between them. A tool is batchable only if it
    /// reads through `documentBytes` and writes through `submitAndRespond`, which every tool
    /// below does; the live-selection tools act on a device's own session instead, and the
    /// document-level tools (create, replace, delete, merge, undo) are not edits of one copy.
    static let batchableTools: Set<String> = [
        "add_text", "edit_text", "remove_text", "add_image", "remove_image",
        "add_arrow", "add_shape", "reshape_arrow", "restyle_arrows", "remove_arrow",
        "add_formula", "edit_formula", "remove_formula",
        "draw_strokes", "draw_dots", "fill_region", "delete_strokes",
        "transform_strokes", "restyle_strokes", "reshape_strokes", "restore_stroke_widths",
        "transform_elements", "reset_element_transforms", "reorder_elements", "set_layer", "set_pinned",
        "tag_elements", "copy_elements",
        "add_grid", "update_grid", "remove_grid", "reorder_grids", "set_grid_origin", "set_paper",
        // reads
        "list_strokes", "get_strokes", "list_texts", "list_images", "list_arrows", "list_formulas",
        "list_grids", "find_elements", "list_tags", "snap_points",
    ]

    /// A batch's `result` (made from `base`) merged into the document as it is NOW and written,
    /// for a batch whose own write was refused twice. The device merges (`mergeEdit`: base, the
    /// document now, the result) and says how many conflicts it met; the merge is written only
    /// with NONE — a conflict is an element both the user and the batch changed, where the merge
    /// keeps the user's, so the batch would not be wholly in what is written and the agent must
    /// not be told it is. Written under the bytes the merge was made from; nil for a conflict, a
    /// device that cannot merge, or a document that changed yet again — the caller then answers
    /// as it always did ("send it again"). ONE undo entry, from the document as the user had it.
    private func writingMerged(docId: String, base: Data, result: Data) async -> Int? {
        // `base` and the result are whole documents and travel as bundle parts, as `revertMerge`'s do.
        let envelope: [String: Value] = ["op": .string("mergeEdit")]
        guard let current = await manager.currentBytesOrFetch(docId: docId), current != base else { return nil }
        struct MergeMeta: Decodable { let conflicts: Int }
        do {
            let spec = try JSONEncoder().encode(Value.object(envelope))
            let out = try await broker.requestStrokeOp(
                docId: docId, docBytes: current, spec: spec, capability: "mergeDocs+mergeEdit",
                specParts: [.base: base, .theirs: result])
            guard let meta = out.meta.flatMap({ try? JSONDecoder().decode(MergeMeta.self, from: $0) }),
                  meta.conflicts == 0 else { return nil }
            // A batch the caller gave up on while the device merged writes nothing, as everywhere
            // else in a batch (the caller then gets its refusal, which it no longer reads).
            if Task.isCancelled { return nil }
            guard case .accepted(let seq) = await manager.submitOpeningSession(
                docId: docId, createIfMissing: false, opId: "mcp-\(UUID().uuidString)",
                payload: OpPayload(type: "fullDoc", data: out.bytes), expectation: .matchBytes(current)) else { return nil }
            await history.record(docId: docId, before: current, after: out.bytes)
            return seq
        } catch {
            return nil
        }
    }

    private struct BatchOp {
        let tool: String
        var arguments: [String: Value]
    }

    private func callBatch(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            guard let rawOps = arguments?["ops"] else { throw ArgumentError.missing("ops") }
            guard case .array(let items) = rawOps, !items.isEmpty else {
                return Self.errorResult("invalidArgument: ops must be a non-empty array of {tool, arguments}")
            }
            guard items.count <= Self.maxBatchOps else {
                return Self.errorResult("invalidArgument: ops has \(items.count) entries, a batch takes at most \(Self.maxBatchOps) — split it")
            }

            // Every op's SHAPE is checked before any runs: a misspelt argument in op 180 should
            // not cost 179 device round trips.
            var ops: [BatchOp] = []
            for (index, item) in items.enumerated() {
                guard case .object(let fields) = item, case .string(let tool)? = fields["tool"] else {
                    return Self.errorResult("invalidArgument: ops[\(index)] must be {tool, arguments}")
                }
                if let extra = fields.keys.sorted().first(where: { $0 != "tool" && $0 != "arguments" }) {
                    return Self.errorResult("invalidArgument: ops[\(index)].\(extra) — an op is {tool, arguments}")
                }
                guard Self.batchableTools.contains(tool) else {
                    return Self.errorResult("invalidArgument: ops[\(index)].tool \"\(tool)\" cannot run in a batch — a batch takes "
                                            + Self.batchableTools.sorted().joined(separator: ", "))
                }
                var opArguments: [String: Value] = [:]
                switch fields["arguments"] {
                case nil, .null?: break
                case .object(let given)?: opArguments = given
                default: return Self.errorResult("invalidArgument: ops[\(index)].arguments must be an object")
                }
                // The document is the batch's. One an op names itself must be the same one.
                let documentKey = tool == "copy_elements" ? "target" : "docId"
                if case .string(let given)? = opArguments[documentKey] {
                    guard case .id(docId) = await manager.resolveDocRef(given) else {
                        return Self.errorResult("invalidArgument: ops[\(index)].\(documentKey) names another document — "
                                                + "every op of a batch works on the batch's docId; leave it out")
                    }
                }
                opArguments[documentKey] = .string(docId)
                if let refusal = Self.enforceKnownArguments(name: tool, arguments: opArguments) {
                    return Self.errorResult("ops[\(index)]: " + Self.text(of: refusal))
                }
                ops.append(BatchOp(tool: tool, arguments: opArguments))
            }

            // Run, write once. A document that changed meanwhile (the user drew) refuses the
            // write; the ops are then run ONCE more on the new document — they are functions of
            // the bytes they are given, and nothing of the first run was written or reported.
            for attempt in 0..<2 {
                guard let original = await manager.currentBytesOrFetch(docId: docId) else {
                    return Self.errorResult("unknownDoc")
                }
                let context = BatchContext(docId: docId, bytes: original)
                var replies: [(text: String, pending: ((Int) -> String)?)] = []
                for (index, op) in ops.enumerated() {
                    // The caller gave up (its timeout, a cancel): stop here. A device op does not
                    // notice a cancel by itself, and a batch that ran on and wrote would be drawn
                    // a second time by the caller that was told nothing.
                    if Task.isCancelled { return Self.errorResult("cancelled — the batch wrote NOTHING") }
                    let (resolved, unresolved, refusal) = await resolvingDocRefs(op.arguments)
                    if let refusal { return Self.batchFailure(index, op.tool, refusal) }
                    context.pendingReply = nil
                    let result = try await Self.$activeBatch.withValue(context) {
                        try await dispatchCallTool(name: op.tool, arguments: resolved, unresolvedKeys: unresolved)
                    }
                    if result.isError == true {
                        let explained = await enrichedError(result, tool: op.tool, arguments: resolved)
                        return Self.batchFailure(index, op.tool, explained)
                    }
                    replies.append((Self.text(of: result), context.pendingReply))
                }

                func reply(seq: Int?) -> CallTool.Result {
                    var object: [String: Value] = ["results": .array(replies.map { entry -> Value in
                        if let pending = entry.pending {
                            // A WRITE: its structured reply, the shape a call of its own returns
                            // beside its text (`structuredReply`). In a batch that as a whole
                            // changed nothing (an add and its removal) there is no seq to quote.
                            let text = seq.map(pending) ?? "applied — the batch as a whole changed nothing"
                            return Self.structuredReply(text, seq: seq) ?? .string(text)
                        }
                        // A read: a tool that answers in JSON is embedded as JSON, not as a string.
                        if let data = entry.text.data(using: .utf8),
                           let json = try? JSONDecoder().decode(Value.self, from: data),
                           json.objectValue != nil || json.arrayValue != nil { return json }
                        return .string(entry.text)
                    })]
                    if let seq { object["seq"] = .int(seq) } else { object["unchanged"] = .bool(true) }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let text = (try? encoder.encode(Value.object(object)))
                        .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)],
                                           structuredContent: .object(object))
                }

                guard context.wrote, context.bytes != original else {
                    return reply(seq: nil)
                }
                if Task.isCancelled { return Self.errorResult("cancelled — the batch wrote NOTHING") }
                let payload = OpPayload(type: "fullDoc", data: context.bytes)
                switch await manager.submitOpeningSession(
                    docId: docId, createIfMissing: false, opId: "mcp-\(UUID().uuidString)", payload: payload,
                    expectation: .matchBytes(original)
                ) {
                case .accepted(let seq):
                    // ONE entry: `undo_last_edit` takes the whole batch back, as the user's undo does.
                    await history.record(docId: docId, before: original, after: context.bytes)
                    return reply(seq: seq)
                case .rejected(let message):
                    guard case .reject(_, _, let reason, _) = message else {
                        return Self.errorResult("unexpectedServerResponse")
                    }
                    if reason == "docChangedDuringOp", attempt == 0 { continue }
                    // Twice: the user keeps drawing. Running the ops a third time would only
                    // lose the race again, so the result is MERGED into the document as it is
                    // now — when that takes nothing from either side.
                    if reason == "docChangedDuringOp",
                       let seq = await writingMerged(docId: docId, base: original, result: context.bytes) {
                        return reply(seq: seq)
                    }
                    return Self.errorResult("\(reason) — the batch wrote NOTHING"
                                            + (reason == "docChangedDuringOp" ? " (the document changed twice while it ran); send it again" : ""))
                }
            }
            return Self.errorResult("docChangedDuringOp — the batch wrote NOTHING; send it again")
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    static let maxFillIdsReported = 16

    /// What a SOLID fill thinner than 3 points is told in its reply: such ink is not rendered
    /// flat in a small image, whatever the pass spacing. Measured 2026-11-22 on a 140 × 120 pen
    /// fill (row brightness, of 255, mean ± half the spread): `drawnWidth: 1` 68.3 ± 3.5 at 1.5
    /// px/pt, 72.6 ± 4.2 at 1.9, 59.7 at 1.0 (of 76 when flat) — unchanged at three times the
    /// passes; `drawnWidth: 2` 74.8 ± 2.5 at 1.5; `drawnWidth: 3` 76.0 ± 0 from 1.5 up. An agent
    /// filled the faces of a 3D body with 1 pt passes for a clean edge and got ruled faces in the
    /// export. Nil for a hatch (a ratio above 1) and when the width is the user's pen's.
    static func thinFillNote(drawnWidth: Double?, spacingRatio: Double?) -> String? {
        guard let drawnWidth, drawnWidth < 3, (spacingRatio ?? 0.4) <= 1 else { return nil }
        return "a solid fill this thin shows stripes in a small image (below about 2 pixels per canvas point), "
            + "whatever its spacingRatio; drawnWidth 3 or more renders flat, and reaches half its width past the outline"
            + " unless edge is \"inside\" — or place the face as an object (add_shape, filled), which is flat at any size"
    }

    /// The first text of a result — a tool's reply or its error reason.
    private static func text(of result: CallTool.Result) -> String {
        for content in result.content {
            if case .text(let text, _, _) = content { return text }
        }
        return ""
    }

    /// A batch that stopped at op `index`: which op, its own reason, and that nothing was written.
    private static func batchFailure(_ index: Int, _ tool: String, _ result: CallTool.Result) -> CallTool.Result {
        errorResult("batchFailed: ops[\(index)] (\(tool)) — \(text(of: result)) — the batch wrote NOTHING")
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
            if let bytes = await documentBytes(docId: docId) {
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
        await renderSketch(arguments, export: false)
    }

    /// The pixel budget of an export without `scale` or `maxPixels`, and its ceiling (the
    /// device's, `SketchRenderer.filePixelCeiling` — said here for the tool's text and tests).
    static let exportDefaultMaxPixels = 8_000_000
    static let exportPixelCeiling = 16_000_000
    /// An export's margin round the content, in canvas points.
    static let exportDefaultPadding = 40

    /// `export_sketch` (improvement note D3): a render with the defaults a published image
    /// needs — no grid, a stated appearance, a narrow margin, written to a file, a larger pixel
    /// ceiling — so that none of the four can be forgotten. ONE render path: it is
    /// `renderSketch` with `export: true`, which sets what the caller left out.
    private func callExportSketch(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard case .string(let appearance)? = arguments?["appearance"], ["light", "dark"].contains(appearance) else {
            return Self.errorResult(arguments?["appearance"] == nil
                ? "missingArgument: appearance — \"light\" or \"dark\": an export states which page it is, it never takes the last opener's"
                : "invalidArgument: appearance must be \"light\" or \"dark\"")
        }
        if let background = arguments?["background"], background != .string("paper"), background != .string("transparent") {
            return Self.errorResult("invalidArgument: background must be \"paper\" or \"transparent\" — an export never shows the grid (render_sketch does)")
        }
        if let format = arguments?["format"] {
            guard format == .string("png") || format == .string("pdf") else {
                return Self.errorResult("invalidArgument: format must be \"png\" or \"pdf\"")
            }
            if format == .string("pdf"), arguments?["maxPixels"] != nil {
                return Self.errorResult("invalidArgument: maxPixels — a PDF page has no pixel budget; `scale` sets its strokes' pixels per canvas point")
            }
        }
        return await renderSketch(arguments, export: true)
    }

    private func renderSketch(_ arguments: [String: Value]?, export: Bool) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            // An export is always a file: it may be four times the size an inline image may be.
            let writeToFile = try export || Self.boolArg(arguments, "writeToFile", default: false)

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            // A preview takes EXACTLY what the commit takes: an ephemeral arrow add_arrow's fields,
            // a restyle restyle_arrows' — so nothing previews that add_arrow / restyle_arrows refuse.
            if let refusal = Self.arrowPreviewKeyRefusal(arguments) { return Self.errorResult(refusal) }
            var specFields: [String: Value] = ["op": .string("render")]
            for key in Self.renderSpecParameterNames {
                if let value = arguments?[key] {
                    specFields[key] = value
                }
            }
            // `format` is export_sketch's alone (render_sketch answers with a picture in its
            // reply): it is relayed here, never through `renderSpecParameterNames`.
            let pdf = export && arguments?["format"] == .string("pdf")
            if export {
                // What a published image needs and the caller did not say. `forFile` raises the
                // device's pixel ceiling: the image goes to a file, never into a reply.
                specFields["forFile"] = .bool(true)
                if specFields["background"] == nil { specFields["background"] = .string("paper") }
                if specFields["padding"] == nil { specFields["padding"] = .int(Self.exportDefaultPadding) }
                if pdf {
                    specFields["format"] = .string("pdf")
                } else if specFields["scale"] == nil, specFields["maxPixels"] == nil {
                    specFields["maxPixels"] = .int(Self.exportDefaultMaxPixels)
                }
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(specFields))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            // `device` is read HERE and never relayed (it says WHICH device, not what to render):
            // a kind is a hello word, so asking for one is one more part a device has to offer.
            // Outside the relay's `do`: a wrong type must answer as an argument error, not as a
            // device failure.
            var kind = ""
            if let device = try Self.optionalStringArg(arguments, "device") {
                guard ["mac", "ipad", "iphone"].contains(device) else {
                    return Self.errorResult("invalidArguments: device must be mac, ipad or iphone")
                }
                kind = "+" + DeviceCommandBroker.kindPrefix + device
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                // A render that names arrows goes only to a device that can build them: an older
                // app would ignore the keys and answer a render WITHOUT them (`authorStrokes+arrows`).
                let wantsArrows = arguments?["arrows"] != nil || arguments?["restyle"] != nil
                    || arguments?["arrowIds"] != nil || arguments?["include"] == .string("arrows")
                // The same for formulas: an older app would ignore `formulaIds` (or refuse the
                // include by name), so a render naming them goes only to a `formulas` device.
                let wantsFormulas: Bool = {
                    if arguments?["include"] == .string("formulas") { return true }
                    if case .array(let ids)? = arguments?["formulaIds"] { return !ids.isEmpty }
                    return false
                }()
                // An ephemeral arrow that names its `styleBase`: an older app would ignore it and
                // preview the arrow in the user's style.
                let namesStyleBase: Bool = {
                    guard case .array(let items)? = arguments?["arrows"] else { return false }
                    return items.contains { if case .object(let fields) = $0 { return fields["styleBase"] != nil }; return false }
                }()
                // An ephemeral arrow that is a closed or filled path: an app from before format 8
                // would ignore the two keys and preview an open arrow.
                let closesAPath: Bool = {
                    guard case .array(let items)? = arguments?["arrows"] else { return false }
                    return items.contains {
                        if case .object(let fields) = $0 { return fields["closed"] != nil || fields["filled"] != nil }
                        return false
                    }
                }()
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                                       capability: Self.joiningFormulas(
                                                           wantsArrows ? "authorStrokes+arrows" : "authorStrokes",
                                                           if: wantsFormulas) + (namesStyleBase ? "+styleBase" : "")
                                                           + (closesAPath ? "+closedPaths" : "")
                                                           // An app without it would ignore `forFile` and
                                                           // hand back an image a quarter the size.
                                                           + (export ? "+exportRender" : "")
                                                           // An app without it would ignore `format`
                                                           // and hand back a PNG named .pdf.
                                                           + (pdf ? "+exportPdf" : "") + kind)
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

            // `writeToFile` is read HERE and nowhere else — it is a server-side instruction about
            // where the bytes go, not a render parameter, so it is deliberately absent from
            // `renderSpecParameterNames` and the device never learns of it. That is what keeps this
            // feature server-only: no op-spec change, no wire change, no version bump (the same
            // shape as merge_docs' `into:` and add_image's path).
            if writeToFile {
                guard let renderFileStore else {
                    return Self.errorResult(
                        "renderFileUnavailable: this server has no render directory configured")
                }
                let url: URL
                do {
                    url = try renderFileStore.write(docId: docId, bytes: out.bytes, fileExtension: pdf ? "pdf" : "png")
                } catch {
                    return Self.errorResult("renderFileWriteFailed: \(error)")
                }
                return CallTool.Result(content: [
                    .text(
                        text: Self.renderFileReplyJSON(
                            filePath: url.path,
                            renderUrl: RenderFileStore.urlPath(forName: url.lastPathComponent),
                            metadataText: metadataText),
                        annotations: nil, _meta: nil)
                ])
            }

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

    /// The `writeToFile` reply: the device's own RenderMetadata with `filePath` merged in, so the
    /// answer stays ONE named-key JSON object rather than two text blocks a caller has to tell
    /// apart. An absent or undecodable metadata degrades to `filePath` alone — the path is the part
    /// the caller cannot do without, and a malformed device reply must not cost them the file that
    /// was successfully written.
    static func renderFileReplyJSON(
        filePath: String, renderUrl: String, metadataText: String
    ) -> String {
        var object = (try? JSONSerialization.jsonObject(with: Data(metadataText.utf8)))
            as? [String: Any] ?? [:]
        object["filePath"] = filePath
        object["renderUrl"] = renderUrl
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            // JSONSerialization refuses non-finite numbers, and the metadata is the device's, not
            // ours. Losing the metadata is survivable; losing the two ways to reach the render is
            // not.
            return #"{"filePath":"\#(filePath)","renderUrl":"\#(renderUrl)"}"#
        }
        return text
    }

    /// The Global-Constraints parameter names `render_sketch` relays
    /// verbatim into the op-spec envelope alongside `"op": "render"` — every
    /// one of them optional; see `callRenderSketch`.
    /// The first key of an ephemeral `arrows` item or of `restyle` that add_arrow / restyle_arrows
    /// would not take, as an `invalidArgument` reason; nil when every key is one of theirs.
    static func arrowPreviewKeyRefusal(_ arguments: [String: Value]?) -> String? {
        func declared(_ tool: String) -> Set<String> {
            guard let t = toolDefinitions.first(where: { $0.name == tool }) else { return [] }
            return declaredArguments(of: t).subtracting(["docId"])
        }
        if case .array(let items)? = arguments?["arrows"] {
            // A preview is never stored, so it has nothing to tag.
            let allowed = declared("add_arrow").subtracting(["tags"])
            for (index, item) in items.enumerated() {
                guard case .object(let fields) = item else { return "invalidArgument: arrows[\(index)] must be an object" }
                if let bad = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
                    return "invalidArgument: arrows[\(index)].\(bad) — an ephemeral arrow takes add_arrow's fields: \(allowed.sorted().joined(separator: ", "))"
                }
            }
        }
        if let restyle = arguments?["restyle"] {
            guard case .object(let fields) = restyle else { return "invalidArgument: restyle must be an object" }
            let allowed = declared("restyle_arrows").subtracting(["ids"]).union(["arrowIds"])
            if let bad = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
                return "invalidArgument: restyle.\(bad) — restyle takes arrowIds and restyle_arrows' fields: \(allowed.sorted().joined(separator: ", "))"
            }
        }
        return nil
    }

    /// The fields of one `ops[]` item of transform_selection, duplicate_selection and
    /// preview_selection — the device's `SelectionOpSpec`, read off transform_selection's item
    /// schema so the two cannot drift.
    static let selectionOpKeys: Set<String> = {
        guard let t = toolDefinitions.first(where: { $0.name == "transform_selection" }),
              case .object(let schema) = t.inputSchema,
              case .object(let properties)? = schema["properties"],
              case .object(let ops)? = properties["ops"],
              case .object(let items)? = ops["items"],
              case .object(let fields)? = items["properties"] else { return [] }
        return Set(fields.keys)
    }()

    /// The first key of an `ops[]` item outside `selectionOpKeys`, as an `invalidArgument` reason;
    /// nil when every item takes only those. The device's decoder IGNORES an unknown key, so
    /// without this `{op: "rotate", canvasAnchor: …}` turned about the reference point while
    /// the agent believed otherwise (final review F7).
    static func selectionOpKeyRefusal(_ ops: Value?) -> String? {
        guard case .array(let items)? = ops else { return nil }
        for (index, item) in items.enumerated() {
            guard case .object(let fields) = item else { return "invalidArgument: ops[\(index)] must be an object" }
            if let bad = fields.keys.sorted().first(where: { !selectionOpKeys.contains($0) }) {
                return "invalidArgument: ops[\(index)].\(bad) — an op takes only: \(selectionOpKeys.sorted().joined(separator: ", "))"
            }
        }
        return nil
    }

    private static let renderSpecParameterNames = [
        "include", "strokeIds", "strokes", "canvasRect", "padding", "background", "axes", "maxPixels",
        "scale", "appearance", "colorAppearance", "arrowIds", "arrows", "restyle", "formulaIds",
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

            guard let docBytes = await documentBytes(docId: docId) else {
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
            let points = try Self.nonEmptyValueArrayArg(arguments, "canvasPoints")

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("snap"),
                "canvasPoints": .array(points),
            ]
            // Only the keys the caller actually supplied — deep validation
            // (unknown gridId, maxCandidates <= 0) is the device's job,
            // surfaced verbatim as `deviceFailed: <reason>`.
            for name in ["gridIds", "maxCandidates", "objects", "objectRadius"] {
                if let value = arguments?[name] {
                    envelope[name] = value
                }
            }
            // Object candidates need a device that knows them: an older app would drop the keys
            // and answer with grid candidates alone, silently. Routing by capability turns that
            // into noDeviceAvailable instead, with no wire-version bump.
            let wantsObjects: Bool
            if case .bool(true)? = arguments?["objects"] { wantsObjects = true } else { wantsObjects = false }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                                       capability: wantsObjects ? "snapObjects" : "authorStrokes")
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

            guard let docBytes = await documentBytes(docId: docId) else {
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
            for name in ["canvasTranslate", "scale", "rotate", "canvasAnchor", "snapToGrid", "snapTo"] {
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

    /// The agent door onto the app's "Restore original stroke widths" menu item: factor
    /// the scale out of the named strokes' transforms so their ink returns to the width
    /// it was drawn at, with the canvas geometry unmoved.
    ///
    /// **A whole-set no-op writes NOTHING.** The device reports which ids it actually
    /// changed (`restoredIds`), and when that is empty the returned bytes are discarded:
    /// a write here would bump `seq` for every subscriber and spend the agent's one
    /// `undo_last_edit` slot on an edit that changed nothing — and the app's own answer
    /// to this state is a disabled menu item, not a document write. The counts are also
    /// what makes the reply honest for a MIXED set, which is the common case when an
    /// agent restores a whole shape and only some of it was ever scaled.
    ///
    /// An ABSENT or undecodable `meta` is treated as "everything was restored" and
    /// written: the bytes are the device's own product, the write is CAS-guarded, and
    /// silently dropping a real edit is far worse than a redundant one.
    /// What `restore_stroke_widths` was given, by name: an arrow id is a UUID, a stroke id the
    /// composite key — "2 strokes and 1 arrow", "1 arrow" (whole-branch review #5).
    /// A formula's id is a UUID too, so `formulaIds` — the document's, `DocJSON.elementIds` — are
    /// counted as formulas, never as arrows: "1 arrow and 1 formula" (formula plan, place 258).
    static func restoreTargetsNoun(_ ids: [String], formulaIds: Set<String>) -> String {
        let formulas = ids.filter(formulaIds.contains).count
        let arrows = ids.filter { !formulaIds.contains($0) && UUID(uuidString: $0) != nil }.count
        let strokes = ids.count - arrows - formulas
        func n(_ c: Int, _ word: String) -> String { "\(c) \(word)\(c == 1 ? "" : "s")" }
        let kinds = [(strokes, "stroke"), (arrows, "arrow"), (formulas, "formula")].filter { $0.0 > 0 }
        if kinds.count <= 1 {
            let (count, word) = kinds.first ?? (strokes, "stroke")
            return count == 1 ? word : word + "s"
        }
        let parts = kinds.map { n($0.0, $0.1) }
        return "elements (\(parts.dropLast().joined(separator: ", ")) and \(parts.last!))"
    }

    /// The capability rule for a tool whose `ids` may MIX kinds (`set_layer`, `tag_elements`):
    /// does any of them name a formula in THIS document? The server cannot tell a formula's id
    /// from an arrow's or a text's without the document, so it reads the document's JSON — but
    /// only when an id is UUID-shaped, since a formula's always is and a stroke's never is.
    static func idsNameAFormula(_ ids: [String], in bytes: Data) -> Bool {
        let candidates = ids.filter { UUID(uuidString: $0) != nil }
        guard !candidates.isEmpty else { return false }
        return !DocJSON.elementIds(.formula, in: bytes).isDisjoint(with: candidates)
    }

    /// `formulas` joined onto a capability when the call names a formula (`+arrows`' rule): an
    /// app that does not know formulas decodes `formulaIds` by IGNORING it and would answer success
    /// with the formulas left out, so it must never receive such a call — and every call without
    /// one still reaches it, on exactly the capability it had before.
    static func joiningFormulas(_ capability: String, if namesFormulas: Bool) -> String {
        namesFormulas ? capability + "+formulas" : capability
    }

    /// What the SERVER refuses of a formula source before any device is asked, by the device's
    /// own names: blank after trimming (`emptyFormula`) or more than 4000 UTF-16 units — the
    /// editor's limit — (`formulaTooLong`). A source that does not typeset is NOT refused: the
    /// device stores it and reports the parser's message.
    static func formulaSourceRefusal(_ latex: String) -> String? {
        if latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "emptyFormula" }
        if latex.utf16.count > maxFormulaSourceLength { return "formulaTooLong" }
        return nil
    }

    /// The app's `PlacedFormulaGeometry.maxSourceLength`.
    static let maxFormulaSourceLength = 4000

    private func callRestoreStrokeWidths(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ids = try Self.nonEmptyStringArrayArg(arguments, "ids")

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("restoreStrokeWidths"),
                    "ids": .array(ids.map(Value.string)),
                ]))
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

            struct RestoreMeta: Decodable {
                let restoredIds: [String]
                let unchangedIds: [String]
            }
            // A formula's id is a UUID like an arrow's: the noun asks the document which is which.
            let formulaIds = DocJSON.elementIds(.formula, in: docBytes)
            let meta = out.meta.flatMap { try? JSONDecoder().decode(RestoreMeta.self, from: $0) }
            let restoredCount = meta?.restoredIds.count ?? ids.count
            let unchangedCount = meta?.unchangedIds.count ?? 0

            guard restoredCount > 0 else {
                return CallTool.Result(content: [.text(
                    text: "no change: \(ids.count == 1 ? "the" : "all \(ids.count)") \(Self.restoreTargetsNoun(ids, formulaIds: formulaIds)) "
                        + "already \(ids.count == 1 ? "has" : "have") the width "
                        + "they were drawn with (none had a scale to factor out) — nothing was written",
                    annotations: nil, _meta: nil)])
            }

            // expectedBytes is docBytes — the exact bytes relayed to the device, never a
            // fresh re-read here, which would re-open the very window this guard closes.
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var summary = "restored \(restoredCount) of \(ids.count) \(Self.restoreTargetsNoun(ids, formulaIds: formulaIds)) at seq \(seq)"
                if unchangedCount > 0 {
                    summary += "; \(unchangedCount) had no scale to factor out"
                }
                return summary
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

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("restyle"),
                "ids": .array(ids.map(Value.string)),
            ]
            for name in ["color", "drawnWidth", "toolWidth", "inkType", "colorAppearance"] {
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
            // A width the target ink cannot express is CLAMPED, which is correct and documented —
            // but `draw_strokes` announces exactly this while restyle used to stay silent, so an
            // agent asking for 1.1 on a pen got 2.5 and could only find out by calling
            // `list_strokes` afterwards.
            struct WidthNote: Decodable {
                /// In the unit asked for — drawnWidth or toolWidth, canvas points.
                let requested: Double
                let actual: Double
                /// What the ink can reach in that unit: its thinnest and widest.
                let lowest: Double?
                let highest: Double?
                /// 1 when the target ink COULD have reached the requested width. Asserting the
                /// wrong cause is worse than saying nothing: an agent that asked for 5 and got
                /// 8.33 was once told "pen tops out near 6".
                let inkCanExpress: Double
            }
            struct RestyleMeta: Decodable {
                let widthNotes: [WidthNote]?
                /// What was actually STORED (light-canonical) — present only when this call went
                /// through the dark door (colorAppearance: "dark") on an explicit `color`.
                let storedColor: String?
            }
            let restyleMeta = out.meta.flatMap { try? JSONDecoder().decode(RestyleMeta.self, from: $0) }
            let notes = restyleMeta?.widthNotes ?? []
            let storedColor = restyleMeta?.storedColor

            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var summary = "restyled \(ids.count) stroke(s) at seq \(seq)"
                // Say only what was checked. Both causes can hold at once, so the sentence is
                // assembled from the ones that actually apply rather than picking one — an
                // earlier version asserted "the nearest end was used" for a result that was
                // neither the request nor a range end.
                if let first = notes.first {
                    let asked = Self.trimmed(first.requested), got = Self.trimmed(first.actual)
                    // "e.g." once there is more than one: the numbers are the FIRST stroke's, and
                    // stating them bare for N reads as a claim about all N. A cause clause is
                    // emitted only when every note agrees on it, for the same reason — the strokes
                    // can have different peaks and so different causes.
                    let example = notes.count == 1 ? "" : "e.g. "
                    summary += "\nnote: \(notes.count) stroke(s) did not land on the width asked "
                        + "for (\(example)\(asked) became \(got))."
                    if notes.allSatisfy({ $0.inkCanExpress == 0 }) {
                        if let lo = first.lowest, let hi = first.highest {
                            summary += " \(asked) is outside what the ink reaches "
                                + "(\(Self.trimmed(lo)) to \(Self.trimmed(hi))), so the nearest end was used."
                        } else {
                            summary += " \(asked) is outside what the ink reaches, so the nearest end was used."
                        }
                    }
                    summary += " list_strokes reports what each stroke actually got."
                }
                if let storedColor {
                    summary += "\nstoredColor: \(storedColor)"
                }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// A number for a human-facing reply: no trailing `.0`, at most two decimals.
    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func callReshapeStrokes(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let items = try Self.nonEmptyValueArrayArg(arguments, "strokes")

            guard let docBytes = await documentBytes(docId: docId) else {
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

            guard let docBytes = await documentBytes(docId: docId) else {
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
            if let refusal = Self.selectionOpKeyRefusal(arguments?["ops"]) { return Self.errorResult(refusal) }
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ops = try Self.nonEmptyValueArrayArg(arguments, "ops")
            let expect = try Self.optionalStringArg(arguments, "expect")

            guard let docBytes = await documentBytes(docId: docId) else {
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

            guard let docBytes = await documentBytes(docId: docId) else {
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
            if let ca = arguments?["colorAppearance"] { envelope["colorAppearance"] = ca }
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
            if let w = arguments?["drawnWidth"] { envelope["drawnWidth"] = w }
            if let w = arguments?["toolWidth"] { envelope["toolWidth"] = w }
            if let i = arguments?["inkType"], case .string(let ink) = i { envelope["inkType"] = .string(ink) }
            if let ca = arguments?["colorAppearance"], case .string(let appearance) = ca {
                envelope["colorAppearance"] = .string(appearance)
            }
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
        guard let docBytes = await documentBytes(docId: docId) else {
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
            let arrowIds = try Self.optionalStringArrayArg(arguments, "arrowIds")
            let formulaIds = try Self.optionalStringArrayArg(arguments, "formulaIds")
            let keepRect = try Self.optionalBoolArg(arguments, "keepRect")

            guard let docBytes = await documentBytes(docId: docId) else {
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
            if let arrowIds, !arrowIds.isEmpty {
                envelope["arrowIds"] = .array(arrowIds.map(Value.string))
            }
            if let formulaIds, !formulaIds.isEmpty {
                envelope["formulaIds"] = .array(formulaIds.map(Value.string))
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
                    docId: docId, docBytes: docBytes, spec: spec,
                    capability: Self.joiningFormulas(
                        (arrowIds?.isEmpty ?? true) ? "controlSelection" : "controlSelection+arrows",
                        if: !(formulaIds?.isEmpty ?? true)))
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
            guard let x = try? Self.doubleArg(arguments, "canvasX"),
                let y = try? Self.doubleArg(arguments, "canvasY")
            else {
                return Self.errorResult("invalidArguments: x and y are required")
            }

            guard let docBytes = await documentBytes(docId: docId) else {
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

            guard let docBytes = await documentBytes(docId: docId) else {
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
            if let refusal = Self.selectionOpKeyRefusal(arguments?["ops"]) { return Self.errorResult(refusal) }
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ops = try Self.nonEmptyValueArrayArg(arguments, "ops")
            let include = try Self.optionalStringArg(arguments, "include")

            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }

            var envelope: [String: Value] = [
                "op": .string("previewSelection"),
                "ops": .array(ops),
            ]
            if let include {
                envelope["include"] = .string(include)
            }
            for key in ["canvasRect", "includePoints", "duplicate"] {
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
            if let refusal = Self.selectionOpKeyRefusal(arguments?["ops"]) { return Self.errorResult(refusal) }
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let ops = try Self.optionalValueArrayArg(arguments, "ops")
            let expect = try Self.optionalStringArg(arguments, "expect")

            guard let docBytes = await documentBytes(docId: docId) else {
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
            var into = try Self.optionalStringArg(arguments, "into")
            if let raw = into {
                guard let normalised = Self.newDocumentName(raw) else { return Self.blankNameResult("into") }
                into = normalised
            }
            // `source`/`target` are ids by now (`resolvingDocRefs`); `into` is a new document's
            // NAME, refused below when a document already carries it.
            guard source != target else {
                return Self.errorResult("invalidArguments")
            }
            let prefer = try Self.optionalStringArg(arguments, "prefer") ?? "target"

            guard let sourceBytes = await documentBytes(docId: source) else {
                return Self.errorResult("sourceNotFound")
            }
            guard let targetBytes = await documentBytes(docId: target) else {
                return Self.errorResult("targetNotFound")
            }
            if let into {
                if let refusal = await claimNameForCreate(into) { return refusal }
            }
            defer { if let into { releaseName(into) } }

            let spec: Data
            do {
                // `sourceBytes` is a WHOLE DOCUMENT and travels as a bundle part — the spec is not
                // chunked (see `OpSpecBundle`).
                spec = try JSONEncoder().encode(Value.object([
                    "op": .string("mergeDocs"),
                    "prefer": .string(prefer),
                ]))
            } catch {
                return Self.errorResult("invalidArguments")
            }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: target, docBytes: targetBytes, spec: spec, capability: "mergeDocs",
                    specParts: [.sourceBytes: sourceBytes])
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
                // A NEW document with its own id: the union carries `target`'s identity, which
                // must not be shared with `target` itself (`DocumentIdentity`).
                return await createNamedDocument(newId: mintDocumentId(), name: into, bytes: out.bytes) { id, seq in
                    "merged \(source) and \(target) into \(into) (\(id)) at seq \(seq)"
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

    // MARK: - diff_docs
    //
    // Read-only: the device compares the document (`docBytes`) with a base copy carried as a
    // bundle part, by content (`DocDiff`, app repo). No submit, no seq, nothing to retry.

    private func callDiffDocs(_ arguments: [String: Value]?, unresolvedKeys: Set<String>) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let baseDocId = try Self.optionalStringArg(arguments, "baseDocId")
            let basePath = try Self.optionalStringArg(arguments, "basePath")
            guard (baseDocId == nil) != (basePath == nil) else {
                return Self.errorResult("invalidArguments: give exactly one of baseDocId and basePath")
            }
            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            let baseBytes: Data
            if let baseDocId {
                guard !unresolvedKeys.contains("baseDocId"),
                      let bytes = await documentBytes(docId: baseDocId) else {
                    return Self.errorResult("baseNotFound: no document \"\(baseDocId)\"")
                }
                baseBytes = bytes
            } else {
                switch Self.readDocumentFile(at: basePath ?? "") {
                case .bytes(let data): baseBytes = data
                case .refusal(let reason): return Self.errorResult(reason)
                }
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(["op": .string("diffDocs")])) }
            catch { return Self.errorResult("invalidArguments") }
            let out: DeviceCommandBroker.StrokeOpReply
            do {
                // The base is a WHOLE DOCUMENT and travels as a bundle part (see `OpSpecBundle`).
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                                       capability: "diffDocs", specParts: [.base: baseBytes])
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            return Self.textResult(String(decoding: out.bytes, as: UTF8.self))
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// Reads the file `diff_docs`' `basePath` names. A relative path is refused, as
    /// `add_image`'s is: the caller cannot see the server's working directory.
    static func readDocumentFile(at rawPath: String) -> ImageFileRead {
        let path = NSString(string: rawPath).expandingTildeInPath
        guard isAbsolutePath(path) else { return .refusal("basePathNotAbsolute: \(rawPath)") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .refusal("baseFileNotFound: \(path)")
        }
        guard !isDirectory.boolValue else { return .refusal("baseFileUnreadable: \(path) is a directory") }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
           size > maxDocumentFileBytes {
            return .refusal("baseTooLarge: \(path) is \(size / 1_000_000) MB, limit \(maxDocumentFileBytes / 1_000_000) MB")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .refusal("baseFileUnreadable: \(path)")
        }
        guard !data.isEmpty else { return .refusal("baseUndecodable: \(path) is empty") }
        return .bytes(data)
    }

    /// As large as a document a device may push (`SessionConfig.maxTransferBytes`).
    static let maxDocumentFileBytes = 512 * 1_000_000

    /// `copy_elements`' arguments that act on the clones (the device's `CopyElements.Spec`).
    static let copyPlacementKeys = ["scale", "rotate", "canvasAnchor", "canvasTranslate", "scaleWidths", "tags"]

    private func callCopyElements(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let source = try Self.nonEmptyStringArg(arguments, "source")
            let target = try Self.nonEmptyStringArg(arguments, "target")
            let strokeIds = try Self.optionalStringArrayArg(arguments, "strokeIds") ?? []
            let textIds = try Self.optionalStringArrayArg(arguments, "textIds") ?? []
            let imageIds = try Self.optionalStringArrayArg(arguments, "imageIds") ?? []
            let arrowIds = try Self.optionalStringArrayArg(arguments, "arrowIds") ?? []
            let formulaIds = try Self.optionalStringArrayArg(arguments, "formulaIds") ?? []
            // `source` may BE `target`: the clones then land in the document they came from, on
            // top of their originals — how a variant of an element starts. (It was refused with a
            // bare `invalidArguments` until 2026-11-22; the device's op never needed the refusal.)
            guard !(strokeIds.isEmpty && textIds.isEmpty && imageIds.isEmpty && arrowIds.isEmpty && formulaIds.isEmpty) else {
                return Self.errorResult("invalidArguments: name at least one of strokeIds, textIds, imageIds, arrowIds, formulaIds")
            }

            guard let sourceBytes = await documentBytes(docId: source) else { return Self.errorResult("sourceNotFound") }
            guard let targetBytes = await documentBytes(docId: target) else { return Self.errorResult("targetNotFound") }

            let count = strokeIds.count + textIds.count + imageIds.count + arrowIds.count + formulaIds.count
            var copyEnvelope: [String: Value] = [
                "op": .string("copyElements"),
                "strokeIds": .array(strokeIds.map(Value.string)),
                "textIds": .array(textIds.map(Value.string)),
                "imageIds": .array(imageIds.map(Value.string)),
            ]
            if !arrowIds.isEmpty { copyEnvelope["arrowIds"] = .array(arrowIds.map(Value.string)) }
            if !formulaIds.isEmpty { copyEnvelope["formulaIds"] = .array(formulaIds.map(Value.string)) }
            // What is done to the clones in the same call. An app without `copyTransform` would
            // ignore these keys and answer a copy that was neither moved nor tagged.
            var placesClones = false
            for key in Self.copyPlacementKeys {
                if let value = arguments?[key], !value.isNull { copyEnvelope[key] = value; placesClones = true }
            }
            let spec: Data
            do {
                // `source` is a WHOLE DOCUMENT and travels as a bundle part — the spec is not
                // chunked (see `OpSpecBundle`).
                spec = try JSONEncoder().encode(Value.object(copyEnvelope))
            } catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(
                    docId: target, docBytes: targetBytes, spec: spec,
                    capability: Self.joiningFormulas(arrowIds.isEmpty ? "copyElements" : "copyElements+arrows",
                                                     if: !formulaIds.isEmpty) + (placesClones ? "+copyTransform" : ""),
                    specParts: [.source: sourceBytes])
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
                    // `created…`, NOT `strokeIds`/`textIds`/`imageIds`: those are this tool's
                    // ARGUMENTS, naming the elements to copy FROM the source. Labelling the new
                    // clones with the same words made one call use each word for two things, and
                    // a reply that looks like an echo of what was sent.
                    if let keys = decoded["createdStrokeKeys"], !keys.isEmpty {
                        summary += "\ncreatedStrokeIds: \(keys.joined(separator: ", "))"
                    }
                    if let ids = decoded["createdTextIds"], !ids.isEmpty {
                        summary += "\ncreatedTextIds: \(ids.joined(separator: ", "))"
                    }
                    if let ids = decoded["createdImageIds"], !ids.isEmpty {
                        summary += "\ncreatedImageIds: \(ids.joined(separator: ", "))"
                    }
                    if let ids = decoded["createdArrowIds"], !ids.isEmpty {
                        summary += "\ncreatedArrowIds: \(ids.joined(separator: ", "))"
                    }
                    if let ids = decoded["createdFormulaIds"], !ids.isEmpty {
                        summary += "\ncreatedFormulaIds: \(ids.joined(separator: ", "))"
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
        case .deviceDisconnected: return Self.errorResult("deviceDisconnected")
        case .documentNotOpen: return Self.errorResult(Self.documentNotOpenReason)
        case .capabilityMissing(let needs, let missing, let devices):
            return Self.errorResult(Self.capabilityMissingReason(needs: needs, missing: missing, devices: devices))
        case .deviceFailed(let why): return Self.errorResult("deviceFailed: \(why)")
        }
    }

    /// `noDeviceAvailable` when devices ARE connected: the token stays the prefix, and the rest
    /// names what is missing and the cure. Before, it read "1 device(s) connected, none offering
    /// the capability this tool needs (offered: …)" without naming the capability — with an older
    /// app connected that looked like a contradiction, since the device plainly was there.
    static func capabilityMissingReason(needs: [String], missing: [String], devices: Int) -> String {
        // A KIND that is not connected is not an old app: say which kind was asked for.
        if let kind = missing.first(where: { $0.hasPrefix(DeviceCommandBroker.kindPrefix) }) {
            return "noDeviceAvailable — \(devices) device(s) connected, none of them a "
                + "\(kind.dropFirst(DeviceCommandBroker.kindPrefix.count)) that can do this (asked for with `device`). "
                + "list_open_docs shows the kinds connected; an app older than 2.6 does not say its kind."
        }
        let all = needs.map { "`\($0)`" }.joined(separator: " + ")
        let lacking = missing.isEmpty
            ? "no single one offers all of \(all)"
            : "none offers \(missing.map { "`\($0)`" }.joined(separator: ", "))"
        let needed = missing == needs || missing.isEmpty ? "" : " (this call needs \(all))"
        return "noDeviceAvailable — \(devices) device(s) connected, \(lacking)\(needed). "
            + "The InfinitySketch app there is older than this server: update it."
    }

    /// A live-state op with no capable device that has the document open. The token stays
    /// `noSelectionActive` — nothing can be selected in a document nobody has open — and the rest
    /// says why, which `enrichedError` completes with what IS open.
    static let documentNotOpenReason = "noSelectionActive: no connected device has this document open"


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
        expectedBytes: Data?, successText: @escaping (Int) -> String
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
        expectation: WriteExpectation, recordForUndo: Bool = true, successText: @escaping (Int) -> String
    ) async -> CallTool.Result {
        // Inside a `batch` nothing is written here: the op's result becomes the batch's working
        // copy, and its reply is made when the batch's ONE write has its seq.
        if let batch = Self.activeBatch {
            return batch.take(docId: docId, bytes: bytes, expectation: expectation, successText: successText)
        }
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
            return Self.writeResult(successText(seq), seq: seq)
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
            guard await documentBytes(docId: docId) != nil else {
                return Self.errorResult("unknownDoc")
            }

            var undone = 0
            var lastSeqText = ""
            // A failure after some steps have LANDED must say so: the document has already moved,
            // and a bare error reads as "nothing happened". The reason token stays first.
            func failed(_ result: CallTool.Result) -> CallTool.Result {
                guard undone > 0 else { return result }
                let reason = result.content.compactMap { content -> String? in
                    if case .text(let text, _, _) = content { return text }
                    return nil
                }.joined(separator: " ")
                return Self.errorResult("\(reason) — \(undone) of \(steps) edit(s) were undone before this "
                                        + "(document now at \(lastSeqText))")
            }
            for _ in 0..<steps {
                guard let entry = await history.mostRecent(docId: docId) else {
                    // Some steps may already have landed; say how far it got rather than
                    // pretending the whole call failed.
                    if undone > 0 { break }
                    return Self.errorResult("nothingToUndo: no recorded edit for \"\(docId)\"")
                }
                guard !entry.isLiveSelectionChange else {
                    return failed(Self.errorResult(Self.lastEditWasLiveSelectionReason))
                }
                guard let current = await documentBytes(docId: docId) else {
                    return failed(Self.errorResult("unknownDoc"))
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
                    case .failed(let result): return failed(result)
                    }
                }

                let result = await submitAndRespond(
                    docId: docId, createIfMissing: false, fullDoc: restored,
                    expectation: .matchBytes(current), recordForUndo: false
                ) { seq in "seq \(seq)" }
                if result.isError == true { return failed(result) }
                // Consumed only once the undo has actually landed, so a rejected write or an
                // unreachable device leaves the history intact and the agent can try again.
                await history.consume(docId: docId, id: entry.id)
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

    static let lastEditWasLiveSelectionReason = "lastEditWasLiveSelection: the last edit was a "
        + "live-selection change (transform/duplicate/delete/draw/restyle_selection), which "
        + "undo_last_edit cannot take back — use the user's Undo in the app, or make the inverse "
        + "change yourself"

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
            // `base` and `theirs` are WHOLE DOCUMENTS and travel as bundle parts, not in the spec:
            // the spec is not chunked, so two documents in it made one WebSocket frame the device
            // refuses outright (see `OpSpecBundle`). The device splices them back before this op's
            // handler decodes it, so `MergeDocs.revert` sees exactly the spec it always saw.
            spec = try JSONEncoder().encode(Value.object(["op": .string("revertMerge")]))
        } catch { return .failed(Self.errorResult("invalidArguments")) }

        do {
            // `mine` rides as the request's docBytes, the shape every relayed op already uses.
            let out = try await broker.requestStrokeOp(docId: docId, docBytes: mine, spec: spec,
                                                       capability: "mergeDocs",
                                                       specParts: [.base: base, .theirs: theirs])
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
        case .arrowNotFound: return "arrowNotFound"
        case .formulaNotFound: return "formulaNotFound"
        case .textNeedsDeviceToPlace: return "invalidSpec: this text is turned or scaled; only a connected device can place it"
        case .documentFormatNewer(let file):
            // The app's own token for the same state, so an agent handles both alike.
            return "\(DeviceCommandBroker.formatRefusalPrefix): file \(file), this server edits up to \(DocJSON.knownFormatVersion) — "
                + "update infsketch-server"
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
            guard let bytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var envelope: [String: Value] = ["op": .string("transformElements")]
            for key in ["strokeIds", "textIds", "imageIds", "arrowIds", "formulaIds", "canvasTranslate", "scale", "rotate", "canvasAnchor"] {
                if let value = arguments?[key], !value.isNull { envelope[key] = value }
            }
            // Names arrows only with a NON-EMPTY list: `arrowIds: []` must not exclude an older
            // app (review M4, 2026-10-14).
            let namesArrows: Bool = {
                if case .array(let ids)? = envelope["arrowIds"] { return !ids.isEmpty }
                return false
            }()
            let namesFormulas: Bool = {
                if case .array(let ids)? = envelope["formulaIds"] { return !ids.isEmpty }
                return false
            }()
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(envelope)) }
            catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: bytes, spec: spec,
                                                       capability: Self.joiningFormulas(
                                                           namesArrows ? "transformElements+arrows" : "transformElements",
                                                           if: namesFormulas))
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

    /// `reset_element_transforms` — the agent door onto the app's "Reset image/text transforms"
    /// menu items; the device runs the SAME functions the menu does (`ElementTransform.
    /// resetTransforms`, pinned against the menu in the app's `ResetElementTransformsOpTests`). A
    /// whole-set no-op writes nothing — the `restore_stroke_widths` rule: a pointless write bumps
    /// seq for every subscriber and spends the agent's one undo on nothing. An absent or
    /// undecodable meta means WRITE (fail open: the bytes are the device's own, CAS-guarded).
    private func callResetElementTransforms(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let textIds = try Self.optionalStringArrayArg(arguments, "textIds") ?? []
            let imageIds = try Self.optionalStringArrayArg(arguments, "imageIds") ?? []
            let formulaIds = try Self.optionalStringArrayArg(arguments, "formulaIds") ?? []
            guard !textIds.isEmpty || !imageIds.isEmpty || !formulaIds.isEmpty else { return Self.errorResult("missingArgument") }
            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var resetEnvelope: [String: Value] = [
                "op": .string("resetElementTransforms"),
                "textIds": .array(textIds.map(Value.string)),
                "imageIds": .array(imageIds.map(Value.string)),
            ]
            if !formulaIds.isEmpty { resetEnvelope["formulaIds"] = .array(formulaIds.map(Value.string)) }
            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(resetEnvelope))
            } catch {
                return Self.errorResult("invalidArguments")
            }
            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                                       capability: Self.joiningFormulas("transformElements",
                                                                                        if: !formulaIds.isEmpty))
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            struct ResetMeta: Decodable {
                let resetIds: [String]
                let unchangedIds: [String]
            }
            let meta = out.meta.flatMap { try? JSONDecoder().decode(ResetMeta.self, from: $0) }
            let total = textIds.count + imageIds.count + formulaIds.count
            let resetCount = meta?.resetIds.count ?? total
            guard resetCount > 0 else {
                return CallTool.Result(content: [.text(
                    text: "no change: all \(total) element(s) already have no size, rotation or skew "
                        + "to reset — nothing was written",
                    annotations: nil, _meta: nil)])
            }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var summary = "reset \(resetCount) of \(total) element(s) at seq \(seq)"
                if let unchanged = meta?.unchangedIds.count, unchanged > 0 {
                    summary += "; \(unchanged) had nothing to reset"
                }
                return summary
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `draw_dots` — a solid round dot as ONE stroke, generated on the device
    /// (spec 2026-07-28-draw-dots-design.md). Relays verbatim like `fill_region`; the dot's
    /// geometry is the device's business because only it knows each ink's minimum width.
    private func callDrawDots(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let dots = try Self.nonEmptyValueArrayArg(arguments, "dots")
            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var envelope: [String: Value] = ["op": .string("drawDots"), "dots": .array(dots)]
            if let value = arguments?["colorAppearance"], !value.isNull { envelope["colorAppearance"] = value }
            let spec: Data
            do {
                spec = try JSONEncoder().encode(Value.object(envelope))
            } catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec)
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            // `draw`'s meta, plus the diameters the ink could not draw that small. Reported for
            // the same reason `draw_strokes` reports clamped widths: a caller that asked for a
            // 2 pt dot and silently got a 3 pt one would never find out.
            struct DotMeta: Decodable {
                let keys: [String]?
                let clampedDiameters: [Double]?
                /// What was actually STORED (light-canonical), one entry per created dot, in
                /// order — present only when this call went through the dark door
                /// (colorAppearance: "dark"). Reused verbatim from the underlying `draw` op's
                /// meta, which `DotAuthoring.annotated` merges `clampedDiameters` onto without
                /// disturbing.
                let storedColors: [String]?
            }
            let meta = out.meta.flatMap { try? JSONDecoder().decode(DotMeta.self, from: $0) }
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var reply = "drew \(meta?.keys?.count ?? dots.count) dot(s) in \(docId) at seq \(seq)"
                if let clamped = meta?.clampedDiameters, !clamped.isEmpty {
                    reply += "\nraised to the smallest this ink can draw: "
                        + clamped.map { String(format: "%g", $0) }.joined(separator: ", ")
                }
                if let keys = meta?.keys { reply += "\nids: " + keys.joined(separator: ", ") }
                if let stored = meta?.storedColors, !stored.isEmpty {
                    reply += "\nstoredColors: " + stored.joined(separator: ", ")
                }
                return reply
            }
        } catch let error as ArgumentError {
            return Self.errorResult(error.reason)
        } catch {
            return Self.errorResult("invalidArguments")
        }
    }

    /// `fill_region` — the device generates the strokes that fill a closed path
    /// (spec 2026-07-28-fill-region-design.md). Relays the arguments verbatim and writes back what
    /// comes home, exactly like `draw_strokes`, whose reply shape it shares.
    private func callFillRegion(_ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            let docId = try Self.nonEmptyStringArg(arguments, "docId")
            let points = try Self.nonEmptyValueArrayArg(arguments, "canvasPoints")
            guard let docBytes = await documentBytes(docId: docId) else {
                return Self.errorResult("unknownDoc")
            }
            var envelope: [String: Value] = [
                "op": .string("fillRegion"),
                "canvasPoints": .array(points),
            ]
            for key in ["color", "drawnWidth", "inkType", "spacingRatio", "angleDeg", "border", "tags", "colorAppearance", "edge"] {
                if let value = arguments?[key], !value.isNull { envelope[key] = value }
            }
            let spec: Data
            do { spec = try JSONEncoder().encode(Value.object(envelope)) }
            catch { return Self.errorResult("invalidArguments") }

            let out: DeviceCommandBroker.StrokeOpReply
            do {
                // An app without `fillEdge` would ignore `edge` and let the ink reach past the
                // outline, with a success reply.
                out = try await broker.requestStrokeOp(docId: docId, docBytes: docBytes, spec: spec,
                                                       capability: envelope["edge"] == nil ? "authorStrokes" : "authorStrokes+fillEdge")
            } catch let error as DeviceCommandBroker.DeviceCommandError {
                return Self.strokeOpErrorResult(error)
            } catch {
                return Self.errorResult("deviceFailed: \(error)")
            }
            // The device answers with `draw`'s meta, so the count comes from the keys it made —
            // and the caller should see it, since those strokes are the cost it just took on.
            struct FillMeta: Decodable {
                let keys: [String]?
                /// What was actually STORED (light-canonical), one entry per pass/border stroke,
                /// in order — present only when this call went through the dark door
                /// (colorAppearance: "dark"). `RegionFill.fillRegion` returns
                /// `StrokeAuthoring.perform`'s meta wholesale, so this is the same field
                /// `draw_strokes` reports, unmodified.
                let storedColors: [String]?
            }
            let fillMeta = out.meta.flatMap { try? JSONDecoder().decode(FillMeta.self, from: $0) }
            let created = fillMeta?.keys?.count
            let thinFillNote = Self.thinFillNote(drawnWidth: try Self.optionalDoubleArg(arguments, "drawnWidth"),
                                                 spacingRatio: try Self.optionalDoubleArg(arguments, "spacingRatio"))
            return await submitAndRespond(
                docId: docId, createIfMissing: false, fullDoc: out.bytes, expectedBytes: docBytes
            ) { seq in
                var reply = created.map { "filled the region in \(docId) with \($0) stroke(s) at seq \(seq)" }
                    ?? "filled the region in \(docId) at seq \(seq)"
                // The strokes it made, so the fill can be removed or restyled without a listing —
                // while they are few: a solid fill is one stroke (a few for a concave shape), a
                // hatch is one per line, up to thousands, and is found by its tags instead.
                if let keys = fillMeta?.keys, !keys.isEmpty, keys.count <= Self.maxFillIdsReported {
                    reply += "\nids: " + keys.joined(separator: ", ")
                }
                if let stored = fillMeta?.storedColors, !stored.isEmpty {
                    reply += "\nstoredColors: " + stored.joined(separator: ", ")
                }
                if let note = thinFillNote { reply += "\nnote: " + note }
                return reply
            }
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
        let created = await manager.creationDates()
        let formatter = ISO8601DateFormatter()
        let payload = entries
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map { entry -> [String: Any] in
                var row: [String: Any] = [
                    "id": entry.id,
                    "name": entry.name,
                    "sizeBytes": entry.sizeBytes,
                    "modifiedAt": formatter.string(from: entry.modifiedAt),
                    "hasContent": entry.hasContent,
                    "open": (live[entry.id]?.subscriberCount ?? 0) > 0,
                ]
                // Absent when unknown — a document held since before the record was kept.
                if let date = created[entry.id] { row["createdAt"] = formatter.string(from: date) }
                return row
            }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return Self.errorResult("internalError: could not encode the document listing")
        }
        return Self.textResult(text)
    }

    private func callListOpenDocs() async -> CallTool.Result {
        let (deviceCount, allWords) = await broker.connectionSummary()
        // A device's KIND is a hello word too, but not an ability: listed apart.
        let capabilities = allWords.filter { !$0.hasPrefix(DeviceCommandBroker.kindPrefix) }
        let kindOf = await broker.deviceKinds()
        var kinds: [String: Int] = [:]
        for kind in kindOf.values { kinds[kind, default: 0] += 1 }
        let names = Dictionary(((try? await manager.listDocuments()) ?? []).map { ($0.id, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        var open: [[String: Any]] = []
        for (docId, info) in await manager.liveInfo() where info.subscriberCount > 0 {
            // Which kinds of device have it open — the browser's viewer page subscribes too and is
            // no device, so this can be shorter than `subscribers`.
            let openOn = await manager.subscribedConnections(docId: docId).compactMap { kindOf[$0] }.sorted()
            open.append(["docId": docId, "name": names[docId] ?? docId, "seq": info.seq,
                         "subscribers": info.subscriberCount, "openOn": openOn])
        }
        open.sort { ($0["docId"] as? String ?? "") < ($1["docId"] as? String ?? "") }

        var devices: [String: Any] = ["count": deviceCount, "capabilities": capabilities.sorted(), "kinds": kinds]
        // The kind the server gives work to first, when it was started with one (`--prefer-device`).
        if let preferred = broker.preferredKind { devices["preferredKind"] = preferred }
        let payload: [String: Any] = [
            "devices": devices,
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

    /// A WRITE's result: its text, as always, and the same facts as `structuredContent` — ONE
    /// shape for every write (improvement note S3, 2026-11-22: `add_formula` answered in JSON,
    /// `add_arrow` with a sentence and a line `arrowId: …`, `add_text` with a line `id: …`,
    /// `copy_elements` with lines of comma-separated ids, and a script needed a pattern per
    /// tool). The text is unchanged, so nothing that reads it breaks; a script reads the object.
    static func writeResult(_ text: String, seq: Int?) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)],
                        structuredContent: structuredReply(text, seq: seq))
    }

    /// The structured form of a write's reply text. A reply that IS a JSON object (the formula
    /// tools') is that object. Otherwise: `message` (the first line), `seq`, and one field per
    /// `key: value` line under the line's own key — a `[…]` value as the array it is, an id list
    /// (`ids`, `created…Ids`, `storedColors`) as an array of strings, a number as a number — with
    /// every other line, and every `note:`, in `notes`. The new element's id is ALWAYS also `id`
    /// (`add_arrow` says `arrowId`), so one key finds it whatever the tool.
    static func structuredReply(_ text: String, seq: Int?) -> Value? {
        if let data = text.data(using: .utf8),
           let object = try? JSONDecoder().decode([String: Value].self, from: data) {
            return .object(object)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }
        var fields: [String: Value] = ["message": .string(lines.removeFirst())]
        if let seq { fields["seq"] = .int(seq) }
        var notes: [Value] = []
        for line in lines {
            guard let colon = line.range(of: ": "),
                  !line[..<colon.lowerBound].isEmpty,
                  line[..<colon.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber }) else {
                notes.append(.string(line)); continue
            }
            let key = String(line[..<colon.lowerBound]), raw = String(line[colon.upperBound...])
            if key == "note" { notes.append(.string(raw)); continue }
            fields[key] = structuredValue(key: key, raw: raw)
        }
        if !notes.isEmpty { fields["notes"] = .array(notes) }
        if fields["id"] == nil, let arrow = fields["arrowId"] { fields["id"] = arrow }
        // A reply that names its element only in its sentence ("added <id> at seq 3", "edited
        // <id> …", "removed arrow <id> …"): the TEXT stays as it is — a caller may be taking its
        // last word for the seq, as this repo's own tests did — and the id is read out of it.
        // ONLY right after one of these verbs: a document's id is a UUID too, and most replies
        // name the document ("set paper on <doc>", "added arrow to <doc>", "copied … from <doc>").
        if fields["id"] == nil, case .string(let message)? = fields["message"],
           let verb = Self.elementNamingVerbs.first(where: { message.hasPrefix($0) }),
           let word = message.dropFirst(verb.count).split(separator: " ").first,
           UUID(uuidString: String(word)) != nil {
            fields["id"] = .string(String(word))
        }
        return .object(fields)
    }

    /// How a reply's sentence begins when the word after it is the ELEMENT it made or touched
    /// (longest first: "removed arrow " before "removed ").
    static let elementNamingVerbs = [
        "removed arrow ", "removed formula ", "removed grid ", "updated grid ", "set origin of grid ",
        "added ", "edited ", "removed ",
    ]

    private static func structuredValue(key: String, raw: String) -> Value {
        if raw.hasPrefix("["), let data = raw.data(using: .utf8),
           let array = try? JSONDecoder().decode([Value].self, from: data) {
            return .array(array)
        }
        if key == "ids" || key.hasSuffix("Ids") || key.hasSuffix("Colors") {
            return .array(raw.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        }
        if let int = Int(raw) { return .int(int) }
        if let double = Double(raw) { return .double(double) }
        return .string(raw)
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
    case guide
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
        case ["guide"]:
            self = .guide
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
        case .guide: return "\(Self.scheme)guide"
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
            // First, deliberately: it is the one an agent should read before picking a tool.
            Resource(
                name: "guide", uri: "\(scheme)guide",
                description: "READ FIRST — where to place work so the user can see it, how "
                    + "coordinates and ink behave, and the traps that cost previous agents an hour",
                mimeType: "text/markdown"),
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
