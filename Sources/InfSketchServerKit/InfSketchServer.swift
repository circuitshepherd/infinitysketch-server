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

    public init(port: UInt16, docsDirectory: URL, config: SessionConfig = SessionConfig()) {
        let store = DirectoryDocumentStore(directory: docsDirectory)
        self.store = store
        self.manager = SessionManager(store: store, config: config)
        self.http = HTTPServer(port: port)
        self.config = config
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

        await http.appendRoute("GET /api/docs") { _ in
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
            return HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "application/json"],
                body: try encoder.encode(summaries))
        }

        await http.appendRoute("GET /api/docs/*") { request in
            // Path shape: /api/docs/<id>/frame
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "api", parts[1] == "docs", parts[3] == "frame",
                  let bytes = try? store.load(docId: parts[2]),
                  let png = ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: bytes)
            else {
                return HTTPResponse(statusCode: .notFound)
            }
            return HTTPResponse(
                statusCode: .ok,
                headers: [
                    .contentType: "image/png",
                    HTTPHeader("X-Frame-Stale"): "true",
                ],
                body: png)
        }

        await http.appendRoute("GET /ws", to: .webSocket(WSAdapter(manager: manager, config: config)))

        await http.appendRoute("GET /") { _ in
            HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(WebUI.indexHTML.utf8))
        }
    }
}
