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
    }

    private struct CooldownKey: Hashable {
        let session: String
        let docId: String
    }

    private let manager: SessionManager
    private var debouncer = NotificationDebouncer()
    private var sessions: [String: Session] = [:]
    /// Per-(session, doc) cooldown timers. The adapter owns every one of
    /// these Tasks; a late fire after the pair has unsubscribed is harmless
    /// (the debouncer's own membership check makes `cooldownEnded` a no-op),
    /// but `endSession` cancels them proactively anyway to avoid needless work.
    private var cooldownTasks: [CooldownKey: Task<Void, Never>] = [:]
    private var pumpTask: Task<Void, Never>?
    private var statusToken: UUID?

    public init(manager: SessionManager) {
        self.manager = manager
    }

    /// Starts the notification pump on first use. (An actor can't spawn a
    /// `Task` capturing `self` from inside its own `init` — Swift 6 treats
    /// that as escaping a not-yet-fully-initialized `self` — so this is
    /// called lazily, from `handle(_:)`, instead. This is still eager
    /// enough for correctness: no session can `resources/subscribe` before
    /// at least one HTTP request has gone through `handle(_:)`, so the pump
    /// is always running by the time there's anyone to notify.)
    private func ensurePumpStarted() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            await self?.runNotificationPump()
        }
    }

    /// Tears down the notification pump, every live session's `Server`
    /// receive loop, and every outstanding cooldown timer. The adapter's
    /// session registry gave the spike's previously-unowned receive-loop
    /// Task a natural owner (see task-1-report.md, Concern 3) — this is
    /// where that owner discharges its duty. Called from
    /// `InfSketchServer.stop()`.
    public func shutdown() async {
        pumpTask?.cancel()
        pumpTask = nil
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
            capabilities: .init(resources: .init(subscribe: true, listChanged: nil))
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

        return server
    }

    // MARK: - HTTP entry point (called by MCPMount)

    /// Routes one bridged MCP HTTP request, mirroring the SDK's own
    /// `MCPConformance/Server/HTTPApp.swift` reference multi-session pattern
    /// ([SPIKE-PIN-1]): a request carrying a known `Mcp-Session-Id` forwards
    /// to that session's transport (and, on a successful DELETE, ends the
    /// session); an unrecognized session id 404s; anything else must be a
    /// bare `initialize` POST, which creates a fresh session — torn down
    /// immediately if the transport itself rejects it as not actually an
    /// initialize request.
    public func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        ensurePumpStarted()
        let headerSessionID = request.header(HTTPHeaderName.sessionID)

        if let headerSessionID {
            guard let session = sessions[headerSessionID] else {
                return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
            }
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                await endSession(headerSessionID)
            }
            return response
        }

        guard request.method.uppercased() == "POST" else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
        }

        let newSessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: newSessionID))
        let server = await makeServer()
        try? await server.start(transport: transport)
        sessions[newSessionID] = Session(server: server, transport: transport)

        let response = await transport.handleRequest(request)
        if case .error = response {
            // Not actually an initialize request (or it failed validation):
            // the transport rejected it, so the session never really lived.
            sessions.removeValue(forKey: newSessionID)
            await server.stop()
        }
        return response
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

    // MARK: - Notification pump

    /// One Task, for the adapter's whole lifetime, consuming
    /// `manager.subscribeStatus()`. Every `docUpdated` status event is fed
    /// to the (pure) debouncer; a `.notify` command pushes immediately and
    /// arms a per-(session, doc) cooldown.
    private func runNotificationPump() async {
        let (events, token) = await manager.subscribeStatus()
        statusToken = token
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
