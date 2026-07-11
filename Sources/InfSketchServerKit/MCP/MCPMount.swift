import Foundation
import FlyingFox
import FlyingSocks
import MCP

// MARK: - SPIKE (mcp_endpoint branch)
//
// Proves the official MCP swift-sdk composes with our FlyingFox server, on
// both macOS and Linux, before any real MCP endpoint work begins. See
// docs/superpowers/... task-1-report.md for the full write-up (the three
// SPIKE-PINs, SDK version, test results). Summary of the discovery below.
//
// [SPIKE-PIN-1] `MCP.StatefulHTTPServerTransport` is framework-agnostic: it
// does NOT own a socket listener. It exposes
//     func handleRequest(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse
// a plain request handler we call once per incoming FlyingFox request. So
// mounting it is a matter of:
//   1. Converting FlyingFox's `HTTPRequest` (method/headers/bodyData) into
//      `MCP.HTTPRequest` (method: String, headers: [String: String], body: Data?).
//   2. Calling `transport.handleRequest(_:)`.
//   3. Converting the returned `MCP.HTTPResponse` back to a FlyingFox
//      `HTTPResponse`. Every case except `.stream` maps to a plain
//      `HTTPBodySequence(data:)` body. `.stream(let stream, _)` carries an SDK
//      `AsyncThrowingStream<Data, Error>` (the SSE body for a POST response or
//      the standalone GET stream) — bridged into a FlyingFox
//      `HTTPBodySequence` via `SSEByteSequence`, a small
//      `AsyncBufferedSequence<UInt8>` adapter (FlyingFox's body type wants a
//      *buffered byte* sequence, not a bare `AsyncSequence<Data>`). Passing it
//      through `HTTPBodySequence(from:suggestedBufferSize:)` (the no-`count`
//      overload) makes FlyingFox treat the body as HTTP/1.1 chunked-transfer
//      and add the `Transfer-Encoding: chunked` header itself — exactly the
//      shape an indeterminate-length SSE stream needs. The connection (and
//      the SSE stream) stays open for exactly as long as the underlying
//      `AsyncThrowingStream` keeps yielding; FlyingFox's per-chunk write loop
//      is what keeps it alive on the wire.
//
// [SPIKE-PIN-2] `resources/subscribe` / `resources/unsubscribe` are
// `MCP.ResourceSubscribe` / `MCP.ResourceUnsubscribe` (both conform `Method`,
// names "resources/subscribe" / "resources/unsubscribe", `Parameters { uri:
// String }`). A handler registered via
// `server.withMethodHandler(ResourceSubscribe.self) { params in ... }` reads
// the current session's identity via the task-local
// `Server.currentHandlerContext?.httpContext` (an `MCP.HTTPRequest?`) — e.g.
// `Server.currentHandlerContext?.httpContext?.header(HTTPHeaderName.sessionID)`
// for the `Mcp-Session-Id` header. This requires one `MCP.Server` +
// `StatefulHTTPServerTransport` PER SESSION (see the SDK's own
// `MCPConformance/Server/HTTPApp.swift` for the reference multi-session
// pattern) — a single `Server` actor's `connection` is last-transport-wins,
// so it cannot correctly serve two concurrent sessions itself.
//
// [SPIKE-PIN-3] Pushing `notifications/resources/updated` to one specific
// session is `Server.notify<N: Notification>(_ notification: Message<N>)
// async throws`, called on THAT session's own `Server` instance — e.g.
// `try await session.server.notify(ResourceUpdatedNotification.message(.init(uri: uri)))`.
// `StatefulHTTPServerTransport.send(_:)` classifies the outgoing JSON-RPC data
// and, for a notification (no `id`), routes it to that transport's standalone
// GET `/mcp` SSE stream. There is no "broadcast to session X" call on a
// shared object — addressing a session is purely "which Server/Transport pair
// do I call `.notify` on", which is why per-session Server instances (PIN-2)
// are required for Tasks 6-7, not just convenient.

/// Builds the spike's hello-world MCP server: one `ping` tool, resources +
/// tools capabilities declared (so `Client.listTools()` — which asserts a
/// non-nil `tools` capability — and a future `resources/subscribe` handler
/// both have somewhere to attach).
public func makeSpikeMCPServer() async -> MCP.Server {
    let server = MCP.Server(
        name: "infsketch",
        version: ServerInfo.version,
        capabilities: .init(
            resources: .init(subscribe: true, listChanged: nil),
            tools: .init(listChanged: nil)
        )
    )

    let pingTool = Tool(
        name: "ping",
        description: "Spike hello-world tool: always available, takes no arguments.",
        inputSchema: .object(["type": "object", "properties": .object([:])])
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [pingTool])
    }

    return server
}

/// [SPIKE-PIN-1] Mounts one `MCP.Server` behind FlyingFox's `POST /mcp`,
/// `GET /mcp`, `DELETE /mcp` routes via a single `StatefulHTTPServerTransport`.
///
/// This is a single-session bridge (matching the spike's one-client proof in
/// `MCPSpikeTests`): the transport itself only supports one `initialize` per
/// instance (a second `initialize` is rejected with 400 "Session already
/// initialized"), and one `MCP.Server` actor can only usefully back one live
/// transport (see PIN-2/PIN-3 above). Multi-session support for Tasks 6-7
/// means keying a `[sessionID: (server, transport)]` map by the
/// `Mcp-Session-Id` header and creating a fresh pair per `initialize`, exactly
/// as the SDK's own `MCPConformance/Server/HTTPApp.swift` reference does for
/// its NIO transport.
public func mountMCP(on http: HTTPServer, server: MCP.Server) async {
    let transport = StatefulHTTPServerTransport()
    try? await server.start(transport: transport)

    let handler: @Sendable (FlyingFox.HTTPRequest) async throws -> FlyingFox.HTTPResponse = { request in
        await mcpBridgeResponse(for: request, through: transport)
    }

    await http.appendRoute("POST /mcp", handler: handler)
    await http.appendRoute("GET /mcp", handler: handler)
    await http.appendRoute("DELETE /mcp", handler: handler)
}

/// Converts a FlyingFox request into `MCP.HTTPRequest`, calls the transport,
/// and converts the `MCP.HTTPResponse` back — including the `.stream` (SSE)
/// case.
private func mcpBridgeResponse(
    for request: FlyingFox.HTTPRequest,
    through transport: StatefulHTTPServerTransport
) async -> FlyingFox.HTTPResponse {
    var headers: [String: String] = [:]
    for (key, value) in request.headers {
        headers[key.rawValue] = value
    }
    let bodyData = try? await request.bodyData

    let mcpRequest = MCP.HTTPRequest(
        method: request.method.rawValue,
        headers: headers,
        body: (bodyData?.isEmpty ?? true) ? nil : bodyData,
        path: request.path
    )

    let mcpResponse = await transport.handleRequest(mcpRequest)

    var responseHeaders = FlyingFox.HTTPHeaders()
    for (key, value) in mcpResponse.headers {
        responseHeaders[FlyingFox.HTTPHeader(key)] = value
    }

    switch mcpResponse {
    case .stream(let stream, _):
        return FlyingFox.HTTPResponse(
            statusCode: flyingFoxStatusCode(mcpResponse.statusCode),
            headers: responseHeaders,
            body: HTTPBodySequence(from: SSEByteSequence(stream: stream))
        )
    default:
        return FlyingFox.HTTPResponse(
            statusCode: flyingFoxStatusCode(mcpResponse.statusCode),
            headers: responseHeaders,
            body: mcpResponse.bodyData ?? Data()
        )
    }
}

/// `MCP.HTTPResponse` only carries a raw `Int` status code; FlyingFox's
/// `HTTPStatusCode` pairs the code with its reason phrase. Covers every code
/// the SDK's HTTP server transports currently emit (see
/// `StatefulHTTPServerTransport`/`HTTPServerTypes.swift`), with a generic
/// fallback for anything else.
private func flyingFoxStatusCode(_ code: Int) -> FlyingFox.HTTPStatusCode {
    switch code {
    case 200: return .ok
    case 202: return .accepted
    case 400: return .badRequest
    case 401: return .unauthorized
    case 403: return .forbidden
    case 404: return .notFound
    case 405: return .methodNotAllowed
    case 408: return .requestTimeout
    case 409: return .conflict
    case 429: return .tooManyRequests
    case 500: return .internalServerError
    default: return FlyingFox.HTTPStatusCode(code, phrase: "")
    }
}

/// [SPIKE-PIN-1] Bridges the SDK's `AsyncThrowingStream<Data, Error>` SSE body
/// into FlyingFox's `AsyncBufferedSequence<UInt8>` body currency. Each `Data`
/// chunk yielded by the SDK (one SSE-formatted event, already framed with
/// `data: ...\n\n` etc. by `StatefulHTTPServerTransport`) becomes exactly one
/// HTTP chunk-transfer frame — `HTTPChunkedTransferEncoder` (internal to
/// FlyingFox) only ever calls `nextBuffer(suggested:)`, never `next()`, on the
/// wrapped sequence, so byte-level splitting is unnecessary here.
struct SSEByteSequence: AsyncBufferedSequence {
    typealias Element = UInt8

    let stream: AsyncThrowingStream<Data, Swift.Error>

    func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator())
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        typealias Element = UInt8
        typealias Buffer = Data

        var base: AsyncThrowingStream<Data, Swift.Error>.AsyncIterator
        private var pending = Data()

        init(base: AsyncThrowingStream<Data, Swift.Error>.AsyncIterator) {
            self.base = base
        }

        mutating func next() async throws -> UInt8? {
            while pending.isEmpty {
                guard let chunk = try await base.next() else { return nil }
                pending = chunk
            }
            return pending.removeFirst()
        }

        mutating func nextBuffer(suggested count: Int) async throws -> Data? {
            try await base.next()
        }
    }
}
