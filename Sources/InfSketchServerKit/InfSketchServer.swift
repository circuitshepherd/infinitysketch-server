import Foundation
import FlyingFox

public struct DocSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sizeBytes: Int
    public var modifiedAt: Date
    public var seq: Int?
    public var subscriberCount: Int?
    /// M2b: false = the server holds only metadata + thumbnail; the content lives on a
    /// connected device (M2c-1: any of its holders).
    public var hasContent: Bool
}

public final class InfSketchServer: Sendable {
    public let manager: SessionManager
    private let store: any DocumentStore
    private let http: HTTPServer
    private let config: SessionConfig
    /// One broker per process, shared by the WS layer (registers
    /// capability-tagged connections, routes replies) and the MCP layer
    /// (calls `requestCreation` from the `create_doc` tool; will call
    /// `requestStrokeOp` from the agent stroke-authoring tool, Task 4).
    /// internal (not private) for tests — mirrors `mcpAdapter` below: Task 3's
    /// real-socket outbound-chunking test drives `requestStrokeOp` directly
    /// against the same broker instance the running server's `WSAdapter` uses.
    let deviceCommandBroker: DeviceCommandBroker
    let mcpAdapter: MCPAdapter  // internal for tests (session-registry assertions)

    public convenience init(
        port: UInt16, docsDirectory: URL, config: SessionConfig = SessionConfig()
    ) {
        self.init(port: port, store: DirectoryDocumentStore(directory: docsDirectory), config: config)
    }

    /// Store-injecting designated init — `internal`, for tests only (the
    /// public init above is the one real callers use, and it always builds a
    /// `DirectoryDocumentStore`). The write-CAS boundary tests need a store
    /// whose `load` can return different bytes on successive calls, so that a
    /// tool handler's read and the session-open behind its submit see
    /// DIFFERENT content with no timing involved at all — see
    /// `StaleReadStore` in MCPAdapterTests.
    init(port: UInt16, store: any DocumentStore, config: SessionConfig = SessionConfig()) {
        self.store = store
        let manager = SessionManager(store: store, config: config)
        self.manager = manager
        self.http = HTTPServer(port: port)
        self.config = config
        let deviceCommandBroker = DeviceCommandBroker(
            createTimeout: config.createDocTimeout, strokeOpTimeout: config.strokeOpTimeout)
        self.deviceCommandBroker = deviceCommandBroker
        self.mcpAdapter = MCPAdapter(
            manager: manager,
            idleTimeout: config.mcpSessionIdleTimeout,
            cleanupInterval: config.mcpSessionCleanupInterval,
            broker: deviceCommandBroker)
    }

    /// Configures routes and serves until stopped.
    public func run() async throws {
        await configureRoutes()
        try await http.run()
    }

    public func waitUntilListening() async throws {
        try await http.waitUntilListening()
    }

    public func stop() async {
        await http.stop(timeout: 1)
        await mcpAdapter.shutdown()
    }

    public var listeningPort: UInt16? {
        get async {
            switch await http.listeningAddress {
            case .ip4(_, let port), .ip6(_, let port):
                return port
            default:
                return nil
            }
        }
    }

    private func configureRoutes() async {
        let store = self.store
        let manager = self.manager

        // M2c-1: a subscribe to a doc we hold no bytes for pulls them from a connected holder.
        let broker = self.deviceCommandBroker
        await manager.setContentProvider { docId, deviceId in
            try await broker.requestProvideContent(docId: docId, deviceId: deviceId)
        }

        await http.appendRoute("GET,HEAD /api/docs") { request in
            let live = await manager.liveInfo()
            var summaries = (try store.list()).map { info in
                DocSummary(
                    id: info.docId, name: info.name, sizeBytes: info.sizeBytes,
                    modifiedAt: info.modifiedAt, seq: live[info.docId]?.seq,
                    subscriberCount: live[info.docId]?.subscriberCount, hasContent: true)
            }
            // M2c-1: metadata-only documents come from the LIVE index (connected devices'
            // advertisements). Content always beats metadata, so skip any docId with bytes.
            let contentIds = Set(summaries.map(\.id))
            for (docId, entry) in await manager.liveDocs() where !contentIds.contains(docId) {
                summaries.append(DocSummary(
                    id: docId, name: entry.name, sizeBytes: entry.sizeBytes,
                    modifiedAt: entry.modifiedAt, seq: nil, subscriberCount: nil,
                    hasContent: false))
            }
            summaries.sort { $0.id < $1.id }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return self.headAware(
                request, headers: [.contentType: "application/json"],
                body: try encoder.encode(summaries))
        }

        await http.appendRoute("GET,HEAD /api/docs/*") { request in
            // Path shape: /api/docs/<id>/frame
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "api", parts[1] == "docs", parts[3] == "frame" else {
                return HTTPResponse(statusCode: .notFound)
            }

            // FlyingFox hands the route an already-decoded path segment (it
            // decodes the request target once before routing); decoding it
            // again here would double-decode names containing a literal
            // "%" (e.g. "50%off" round-trips through the wire as
            // "50%25off" and arrives at `parts[2]` as "50%off" already).
            if let frame = await manager.latestFrame(docId: parts[2]) {
                return self.headAware(request, headers: [
                    .contentType: "image/png",
                    .cacheControl: "no-store",
                    HTTPHeader("X-Frame-Stale"): "false",
                    HTTPHeader("X-Frame-Seq"): "\(frame.seq)",
                ], body: frame.png)
            }

            if let bytes = try? store.load(docId: parts[2]),
               let png = ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: bytes) {
                return self.headAware(request, headers: [
                    .contentType: "image/png",
                    .cacheControl: "no-store",
                    HTTPHeader("X-Frame-Stale"): "true",
                ], body: png)
            }

            // M2c-1: a metadata-only doc has no bytes here — serve the thumbnail its holder
            // advertised, from the live index (same URL/content type, so the app's preview
            // cache is unaffected).
            guard let png = await manager.liveEntry(docId: parts[2])?.thumbnail else {
                return HTTPResponse(statusCode: .notFound)
            }
            return self.headAware(request, headers: [
                .contentType: "image/png",
                .cacheControl: "no-store",
                HTTPHeader("X-Frame-Stale"): "true",
            ], body: png)
        }

        await http.appendRoute("GET,HEAD /doc/*") { request in
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count == 2, parts[0] == "doc" else {
                return HTTPResponse(statusCode: .notFound)
            }
            // See the /api/docs/* handler above: parts[1] is already decoded.
            let docId = parts[1]
            // Only serve a viewer for a document that actually exists somewhere. Without this,
            // any path under /doc/ answered 200 with a working-looking page for a document that
            // was never there, so a typo or a stale link rendered an empty viewer that would sit
            // at "stale (no live client)" forever. `/api/docs/<id>/frame` already 404s.
            //
            // "Exists" has THREE sources, and all three are load-bearing — this must be at least
            // as permissive as the frame route beside it, or a document whose frames that route
            // happily serves would have no page to show them on:
            //   - stored bytes;
            //   - an OPEN SESSION, which a doc has from the moment a client subscribes with
            //     `createIfMissing` — before any submit puts bytes in the store. Missing this
            //     404'd a document that was live and rendering frames (caught by
            //     `IntegrationTests.percentNamedDocServesPageAndFrame`);
            //   - a connected device's advertisement (M2c metadata-only: no bytes here at all,
            //     and the frame route serves the thumbnail its holder advertised).
            let hasSession = await manager.liveInfo()[docId] != nil
            let advertised = await manager.liveEntry(docId: docId) != nil
            let known = ((try? store.exists(docId: docId)) ?? false) || hasSession || advertised
            guard known else { return HTTPResponse(statusCode: .notFound) }
            return self.headAware(
                request, headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(WebUI.docHTML(docId: docId).utf8))
        }

        await http.appendRoute(
            "GET /ws",
            to: .webSocket(WSAdapter(manager: manager, config: config, broker: deviceCommandBroker)))

        // MCP endpoint (mcp_endpoint branch): mounts unconditionally, like
        // /ws. See Sources/InfSketchServerKit/MCP/MCPMount.swift for the
        // transport bridge and MCPAdapter.swift for the resource surface +
        // per-session registry (task-1-report.md has the SPIKE-PIN write-up
        // this was built from).
        await mountMCP(on: http, adapter: mcpAdapter)

        await http.appendRoute("GET,HEAD /") { request in
            self.headAware(
                request, headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(WebUI.indexHTML.utf8))
        }
    }

    // HTTP: HEAD gets identical headers, no body.
    //
    // It takes the body as a parameter rather than an already-built `HTTPResponse` because
    // `Content-Length` has to be carried across by hand and `HTTPResponse.bodyData` is async —
    // unreadable from here. Dropping the body without restating the length made the server
    // compute it from what was left, so a HEAD answered `Content-Length: 0` while the same GET
    // answered the real size, defeating the main reason to send a HEAD at all (RFC 9110 §9.3.2:
    // a HEAD response's header fields should be the ones a GET would have sent, and its
    // Content-Length describes the body the GET *would* have returned).
    private func headAware(
        _ request: HTTPRequest, statusCode: HTTPStatusCode = .ok,
        headers: [HTTPHeader: String], body: Data
    ) -> HTTPResponse {
        guard request.method == .HEAD else {
            return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
        }
        var headers = headers
        headers[.contentLength] = "\(body.count)"
        return HTTPResponse(statusCode: statusCode, headers: headers, body: Data())
    }
}
