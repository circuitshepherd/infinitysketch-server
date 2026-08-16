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
    /// The port this server was CONSTRUCTED with. `listeningPort` is the truth and is what the
    /// pages use; this is the fallback for the window before the socket is up.
    private let requestedPort: UInt16
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
        // The logger is passed EXPLICITLY, never defaulted: FlyingFox's default prints to stdout on
        // every non-Apple platform, which made the quiet console Apple-only by accident. See
        // `ServerLogHTTPLogging`.
        self.http = HTTPServer(port: port, logger: ServerLogHTTPLogging())
        self.config = config
        self.requestedPort = port
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

    /// Throws if the socket is not accepting within `timeout`. The default matches FlyingFox's own.
    ///
    /// The caller that passes a SHORTER one is the startup path: it is deciding whether to open a
    /// browser, and the failure it is really waiting out — a port already in use — has already
    /// surfaced through `run()` by then.
    public func waitUntilListening(timeout: TimeInterval = 5) async throws {
        try await http.waitUntilListening(timeout: timeout)
    }

    /// `timeout: 0` is deliberate, and it does NOT make the shutdown abrupt.
    ///
    /// `HTTPServer.stop(timeout:)` closes the listening socket and then `await`s
    /// `connection.complete()` for every live connection — the graceful part — BEFORE the
    /// timeout applies at all. What the timeout actually bounds is how long to wait for the
    /// accept-loop task to notice it is finished before cancelling it, and cancelling it at once
    /// costs nothing: there is nothing left for it to accept.
    ///
    /// It was `1`, which is a second of dead wait per server instance. Production never notices
    /// (one instance, at process exit), but the test suite creates one server per test and pays
    /// it 164 times: the MCP suite alone took **185.8 s**, of which ~164 s was this. At `0` the
    /// same suite takes **11.7 s** and the full suite went from ~190 s to ~12 s, with all 427
    /// tests still passing. A sixteen-fold difference in the edit-test loop, for a second nobody
    /// was using.
    public func stop() async {
        await http.stop(timeout: 0)
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
                var headers: [HTTPHeader: String] = [
                    .contentType: "image/png",
                    .cacheControl: "no-store",
                    HTTPHeader("X-Frame-Stale"): "false",
                    HTTPHeader("X-Frame-Seq"): "\(frame.seq)",
                ]
                // Travels with the bytes it describes, never on the frameAvailable
                // nudge: the page fetches the LATEST frame, so a rect carried by the
                // nudge would pair with a newer PNG whenever two frames land inside one
                // fetch — a wrong compensation that looks exactly like no compensation.
                // Omitted rather than emptied when unknown; the viewer reads absence.
                if let rect = frame.canvasRect {
                    headers[HTTPHeader("X-Frame-Canvas-Rect")] =
                        rect.map { "\($0)" }.joined(separator: ",")
                }
                return self.headAware(request, headers: headers, body: frame.png)
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

        // Where a scanned QR code lands. The address comes from the request's own Host header —
        // whatever the DEVICE used to reach us, which is by definition an address that works from
        // the device. See `JoinPage` for why the code carries an http url rather than the app's
        // custom scheme.
        await http.appendRoute("GET,HEAD /join") { request in
            self.headAware(
                request, headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(JoinPage.html(host: request.headers[.host] ?? "localhost").utf8))
        }

        await http.appendRoute("GET,HEAD /") { request in
            // Per request, not per launch: `candidates()` walks the machine's interfaces, so a
            // network that changed since startup shows up on a reload. The port comes from the
            // LISTENING socket
            // — a server constructed with port 0 (every test, and any caller letting the OS pick)
            // would otherwise print `:0` into every url on the page.
            let port = await self.listeningPort ?? self.requestedPort
            let connect = ConnectPanel.html(
                candidates: LocalAddresses.candidates(), port: port,
                host: request.headers[.host])
            return self.headAware(
                request, headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(WebUI.indexHTML(connectSection: connect).utf8))
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
