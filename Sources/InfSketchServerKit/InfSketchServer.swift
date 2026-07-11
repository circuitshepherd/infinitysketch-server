import Foundation
import FlyingFox

public struct DocSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sizeBytes: Int
    public var modifiedAt: Date
    public var seq: Int?
    public var subscriberCount: Int?
}

public final class InfSketchServer: Sendable {
    public let manager: SessionManager
    private let store: DirectoryDocumentStore
    private let http: HTTPServer
    private let config: SessionConfig
    private let mcpAdapter: MCPAdapter

    public init(port: UInt16, docsDirectory: URL, config: SessionConfig = SessionConfig()) {
        let store = DirectoryDocumentStore(directory: docsDirectory)
        self.store = store
        let manager = SessionManager(store: store, config: config)
        self.manager = manager
        self.http = HTTPServer(port: port)
        self.config = config
        self.mcpAdapter = MCPAdapter(manager: manager)
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
                        subscriberCount: live[info.docId]?.subscriberCount)
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

            guard let bytes = try? store.load(docId: parts[2]),
                  let png = ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: bytes)
            else {
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

        await http.appendRoute("GET /ws", to: .webSocket(WSAdapter(manager: manager, config: config)))

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
