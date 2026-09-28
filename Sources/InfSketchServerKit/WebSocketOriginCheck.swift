import Foundation
import FlyingFox
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WinSDK)
import WinSDK
#endif

/// Browsers apply no same-origin rule to a WebSocket handshake: any page open in a browser that
/// can reach this port — `localhost` included, which is where the startup tab lives — could
/// connect to `/ws`, list, read, overwrite and delete every document, or say hello as a device
/// and answer agent ops. That reaches the server from OUTSIDE the LAN through the browser, which
/// is more than the documented "no authentication on the LAN" stance accepts.
///
/// The browser does send `Origin`, and a page cannot forge it. So: an `Origin` naming a different
/// authority than the request's own `Host` is refused. The viewer pages are served by this server
/// (same origin, allowed); the app and scripts send no `Origin` at all (allowed).
///
/// **Same-origin alone does not stop DNS REBINDING** (round 5, item 5): a page on
/// `evil.example.com` whose name is re-pointed at this machine's address sends `Origin` and `Host`
/// that BOTH say `evil.example.com`, so they match. So a handshake that carries an `Origin` must
/// also name this server by a name no outside party controls: an IP literal, `localhost`, an mDNS
/// `*.local` name, this machine's own host name, or a name the operator allowed with
/// `--allow-host`. A request WITHOUT an `Origin` is not a browser page and is not affected.
///
/// **`X-Forwarded-Host` is NOT honoured** — any client can send it, so trusting it would reopen
/// exactly this hole. A reverse proxy in front of the server must PRESERVE `Host` (and the browser's
/// `Origin` then matches it); a proxy under a public name also needs `--allow-host <name>`.
enum WebSocketOriginPolicy {

    static func allows(origin: String?, host: String?, allowedHostNames: Set<String> = []) -> Bool {
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
            && isTrustedHostName(hostName, allowed: allowedHostNames)
    }

    /// A name that can only mean THIS server to the browser that sent it: see the type comment.
    static func isTrustedHostName(_ raw: String, allowed: Set<String> = [],
                                  machineNames: Set<String> = machineHostNames) -> Bool {
        var name = normalized(raw)
        if name.hasSuffix(".") { name.removeLast() }   // a fully qualified `localhost.` is the same name
        if isIPLiteral(name) || name == "localhost" || name.hasSuffix(".local") { return true }
        if machineNames.contains(name) { return true }
        return allowed.contains { normalized($0) == name }
    }

    /// A dotted IPv4 address, or an IPv6 one (brackets already stripped). A DNS name can hold
    /// neither a colon nor four all-numeric labels, so no registered name passes this.
    static func isIPLiteral(_ name: String) -> Bool {
        if name.contains(":") {
            // A zone (`fe80::1%en0`) names an interface, not a host: only the address is checked.
            let address = name.split(separator: "%", maxSplits: 1).first ?? ""
            return address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 3 && label.allSatisfy(\.isNumber) && (Int(label) ?? 256) <= 255
        }
    }

    /// This machine's host name, lower-cased, and its first label (`MacBook.lan` → also
    /// `macbook`). Read once, from `gethostname` rather than `ProcessInfo.hostName`, which can
    /// block on a DNS lookup.
    static let machineHostNames: Set<String> = {
        var names: Set<String> = []
        #if os(Windows)
        // The DNS host name, which is what a browser puts in `Host` — `COMPUTERNAME` is the
        // NetBIOS name, upper-cased and cut at 15 characters, so a longer machine name never
        // matched. Both are kept: a LAN resolving NetBIOS names reaches the machine by that one.
        var length: DWORD = 0
        _ = GetComputerNameExW(ComputerNameDnsHostname, nil, &length)
        if length > 0 {
            var buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
            var capacity = DWORD(buffer.count)
            if GetComputerNameExW(ComputerNameDnsHostname, &buffer, &capacity) {
                let name = String(decoding: buffer.prefix(Int(capacity)), as: UTF16.self)
                if !name.isEmpty { names.insert(name.lowercased()) }
            }
        }
        if let name = ProcessInfo.processInfo.environment["COMPUTERNAME"] { names.insert(name.lowercased()) }
        #else
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !name.isEmpty { names.insert(name.lowercased()) }
        }
        #endif
        for name in names {
            if let first = name.split(separator: ".").first { names.insert(String(first)) }
        }
        return names
    }()

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
    /// Names beyond the built-in trusted ones (`--allow-host`); see `WebSocketOriginPolicy`.
    var allowedHostNames: Set<String> = []

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard WebSocketOriginPolicy.allows(origin: request.headers[HTTPHeader("Origin")],
                                           host: request.headers[.host],
                                           allowedHostNames: allowedHostNames) else {
            ServerLog.verbose("[ws] refused upgrade from Origin \(request.headers[HTTPHeader("Origin")] ?? "-") for Host \(request.headers[.host] ?? "-")")
            return HTTPResponse(statusCode: .forbidden)
        }
        return try await inner.handleRequest(request)
    }
}
