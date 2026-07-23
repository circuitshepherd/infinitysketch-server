import Foundation
import FlyingFox

public struct DocSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sizeBytes: Int
    public var modifiedAt: Date
    public var seq: Int?
    public var subscriberCount: Int?
    /// M2b: false = the server holds only metadata + thumbnail; content lives on `originDeviceId`.
    public var hasContent: Bool
    public var originDeviceId: String?
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

        await http.appendRoute("GET,HEAD /api/docs") { request in
            let live = await manager.liveInfo()
            let summaries = (try store.list())
                .sorted { $0.docId < $1.docId }
                .map { info in
                    DocSummary(
                        id: info.docId,
                        name: info.name,
                        sizeBytes: info.sizeBytes,
                        modifiedAt: info.modifiedAt,
                        seq: live[info.docId]?.seq,
                        subscriberCount: live[info.docId]?.subscriberCount,
                        hasContent: info.hasContent,
                        originDeviceId: info.originDeviceId)
                }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return self.headAware(request, HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "application/json"],
                body: try encoder.encode(summaries)))
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
                return self.headAware(request, HTTPResponse(
                    statusCode: .ok,
                    headers: [
                        .contentType: "image/png",
                        .cacheControl: "no-store",
                        HTTPHeader("X-Frame-Stale"): "false",
                        HTTPHeader("X-Frame-Seq"): "\(frame.seq)",
                    ],
                    body: frame.png))
            }

            if let bytes = try? store.load(docId: parts[2]),
               let png = ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: bytes) {
                return self.headAware(request, HTTPResponse(
                    statusCode: .ok,
                    headers: [
                        .contentType: "image/png",
                        .cacheControl: "no-store",
                        HTTPHeader("X-Frame-Stale"): "true",
                    ],
                    body: png))
            }

            // M2b: a metadata-only doc has no bytes here — serve the thumbnail its origin device
            // advertised, so it previews exactly like any other document (same URL, same content
            // type, so the app's RemotePreviewCache needs no change).
            guard let png = ((try? store.loadMetadata(docId: parts[2])) ?? nil)?.thumbnail else {
                return HTTPResponse(statusCode: .notFound)
            }
            return self.headAware(request, HTTPResponse(
                statusCode: .ok,
                headers: [
                    .contentType: "image/png",
                    .cacheControl: "no-store",
                    HTTPHeader("X-Frame-Stale"): "true",
                ],
                body: png))
        }

        await http.appendRoute("GET,HEAD /doc/*") { request in
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count == 2, parts[0] == "doc" else {
                return HTTPResponse(statusCode: .notFound)
            }
            // See the /api/docs/* handler above: parts[1] is already decoded.
            let docId = parts[1]
            return self.headAware(request, HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(WebUI.docHTML(docId: docId).utf8)))
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
            self.headAware(request, HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(WebUI.indexHTML.utf8)))
        }
    }

    // HTTP: HEAD gets identical headers, no body.
    private func headAware(_ request: HTTPRequest, _ response: HTTPResponse) -> HTTPResponse {
        guard request.method == .HEAD else { return response }
        return HTTPResponse(statusCode: response.statusCode, headers: response.headers, body: Data())
    }
}
