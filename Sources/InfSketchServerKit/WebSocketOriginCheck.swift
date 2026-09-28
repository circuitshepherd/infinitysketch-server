import Foundation
import FlyingFox

/// Browsers apply no same-origin rule to a WebSocket handshake: any page open in a browser that
/// can reach this port — `localhost` included, which is where the startup tab lives — could
/// connect to `/ws`, list, read, overwrite and delete every document, or say hello as a device
/// and answer agent ops. That reaches the server from OUTSIDE the LAN through the browser, which
/// is more than the documented "no authentication on the LAN" stance accepts.
///
/// The browser does send `Origin`, and a page cannot forge it. So: an `Origin` naming a different
/// authority than the request's own `Host` is refused. The viewer pages are served by this server
/// (same origin, allowed); the app and scripts send no `Origin` at all (allowed).
enum WebSocketOriginPolicy {

    static func allows(origin: String?, host: String?) -> Bool {
        guard let origin else { return true }
        guard let host,
              let components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(),
              let originHost = components.host, !originHost.isEmpty
        else { return false }   // "null" (sandboxed frame, file://) and garbage are cross-origin
        let defaultPort: Int
        switch scheme {
        case "http": defaultPort = 80
        case "https": defaultPort = 443
        default: return false
        }
        guard let (hostName, hostPort) = splitHostHeader(host) else { return false }
        return normalized(originHost) == normalized(hostName)
            && (components.port ?? defaultPort) == (hostPort ?? defaultPort)
    }

    /// `name[:port]`, with IPv6 in brackets (`[::1]:8080`).
    private static func splitHostHeader(_ host: String) -> (String, Int?)? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return (name, nil) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (name, port)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (trimmed, nil)
        case 2:
            guard let port = Int(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default: return nil
        }
    }

    /// Host names compare case-insensitively; `URLComponents.host` strips IPv6 brackets already.
    private static func normalized(_ name: String) -> String {
        var name = name.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        return name
    }
}

/// Checks the policy before handing the request to the real upgrade handler, so a refused
/// handshake never reaches `WSAdapter` at all.
struct OriginCheckedHTTPHandler<Inner: HTTPHandler>: HTTPHandler {
    let inner: Inner

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard WebSocketOriginPolicy.allows(origin: request.headers[HTTPHeader("Origin")],
                                           host: request.headers[.host]) else {
            ServerLog.verbose("[ws] refused upgrade from Origin \(request.headers[HTTPHeader("Origin")] ?? "-") for Host \(request.headers[.host] ?? "-")")
            return HTTPResponse(statusCode: .forbidden)
        }
        return try await inner.handleRequest(request)
    }
}
