import Foundation
import FlyingFox
import FlyingSocks
import MCP

// MARK: - MCP mount (Task 6, mcp_endpoint branch)
//
// A thin, stateless FlyingFox <-> MCP.HTTPRequest/Response converter. All
// MCP-domain state — the per-session registry, resource handlers, and
// subscribe/notify bookkeeping — lives in `MCPAdapter` (see
// `MCPAdapter.swift`); this file only knows how to translate one FlyingFox
// request into `MCP.HTTPRequest`, hand it to `adapter.handle(_:)`, and
// translate the `MCP.HTTPResponse` back. Task 1's spike (task-1-report.md)
// proved this conversion; the three SPIKE-PINs it established:
//
// [SPIKE-PIN-1] `MCP.StatefulHTTPServerTransport` is framework-agnostic: it
// does NOT own a socket listener. It exposes
//     func handleRequest(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse
// a plain request handler. Converting the returned `MCP.HTTPResponse` back
// to a FlyingFox `HTTPResponse`: every case except `.stream` maps to a plain
// `HTTPBodySequence(data:)` body. `.stream(let stream, _)` carries an SDK
// `AsyncThrowingStream<Data, Error>` (the SSE body for a POST response or
// the standalone GET stream) — bridged into a FlyingFox `HTTPBodySequence`
// via `SSEByteSequence`, a small `AsyncBufferedSequence<UInt8>` adapter
// (FlyingFox's body type wants a *buffered byte* sequence, not a bare
// `AsyncSequence<Data>`). Passing it through
// `HTTPBodySequence(from:suggestedBufferSize:)` (the no-`count` overload)
// makes FlyingFox treat the body as HTTP/1.1 chunked-transfer and add the
// `Transfer-Encoding: chunked` header itself — exactly the shape an
// indeterminate-length SSE stream needs. The connection (and the SSE
// stream) stays open for exactly as long as the underlying
// `AsyncThrowingStream` keeps yielding; FlyingFox's per-chunk write loop is
// what keeps it alive on the wire.
//
// Multi-session support (this task): `StatefulHTTPServerTransport` only
// supports one `initialize` per instance, and one `MCP.Server` actor can
// only usefully back one live transport — see `MCPAdapter.handle(_:)` for
// the per-session `[sessionID: (Server, Transport)]` registry this mount
// now delegates to (the same pattern as the SDK's own
// `MCPConformance/Server/HTTPApp.swift` reference, adapted for FlyingFox).
//
// [SPIKE-PIN-2]/[SPIKE-PIN-3] (session identity + server-initiated push) are
// entirely `MCPAdapter`'s concern now; see that file's header comment.

/// Mounts the MCP endpoint behind FlyingFox's `POST /mcp`, `GET /mcp`,
/// `DELETE /mcp` routes. Every request is bridged to `MCP.HTTPRequest` and
/// handed to `adapter.handle(_:)`, which owns all session routing.
public func mountMCP(on http: HTTPServer, adapter: MCPAdapter) async {
    let handler: @Sendable (FlyingFox.HTTPRequest) async throws -> FlyingFox.HTTPResponse = { request in
        await mcpBridgeResponse(for: request, through: adapter)
    }

    await http.appendRoute("POST /mcp", handler: handler)
    await http.appendRoute("GET /mcp", handler: handler)
    await http.appendRoute("DELETE /mcp", handler: handler)
}

/// Converts a FlyingFox request into `MCP.HTTPRequest`, calls the adapter,
/// and converts the `MCP.HTTPResponse` back — including the `.stream` (SSE)
/// case.
private func mcpBridgeResponse(
    for request: FlyingFox.HTTPRequest,
    through adapter: MCPAdapter
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

    let mcpResponse = await adapter.handle(mcpRequest)
    return flyingFoxResponse(from: mcpResponse)
}

private func flyingFoxResponse(from mcpResponse: MCP.HTTPResponse) -> FlyingFox.HTTPResponse {
    var responseHeaders = FlyingFox.HTTPHeaders()
    for (key, value) in mcpResponse.headers {
        responseHeaders[FlyingFox.HTTPHeader(key)] = value
    }

    switch mcpResponse {
    case .stream(let stream, _):
        return FlyingFox.HTTPResponse(
            statusCode: flyingFoxStatusCode(mcpResponse.statusCode),
            headers: responseHeaders,
            body: HTTPBodySequence(from: SSEByteSequence(stream: stream)))
    default:
        return FlyingFox.HTTPResponse(
            statusCode: flyingFoxStatusCode(mcpResponse.statusCode),
            headers: responseHeaders,
            body: mcpResponse.bodyData ?? Data())
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
