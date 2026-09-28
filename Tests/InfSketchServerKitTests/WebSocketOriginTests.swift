import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import InfSketchServerKit

/// `/ws` refuses a handshake whose `Origin` names another site: browsers apply no same-origin
/// rule to WebSockets, so without this any page in a browser that can reach the port — the
/// startup tab's `localhost` included — could read, overwrite and delete every document.
@Suite struct WebSocketOriginTests {

    @Test(arguments: [
        ("http://localhost:8080", "localhost:8080"),
        ("http://LocalHost:8080", "localhost:8080"),
        ("http://192.168.1.42:18551", "192.168.1.42:18551"),
        ("http://[::1]:8080", "[::1]:8080"),
        ("http://MacBook.local:8080", "macbook.local:8080"),
        ("http://127.0.0.1:8080", "127.0.0.1:8080"),
    ])
    func sameOriginIsAllowed(origin: String, host: String) {
        #expect(WebSocketOriginPolicy.allows(origin: origin, host: host))
    }

    @Test(arguments: [
        ("http://evil.example.com", "localhost:8080"),
        ("http://localhost:9090", "localhost:8080"),
        ("http://localhost", "localhost:8080"),
        ("null", "localhost:8080"),
        ("file://", "localhost:8080"),
        ("http://localhost:8080", nil as String?),
    ])
    func crossOriginIsRefused(origin: String, host: String?) {
        #expect(!WebSocketOriginPolicy.allows(origin: origin, host: host))
    }

    /// DNS rebinding (round 5, item 5): a page on a public name re-pointed at this machine sends an
    /// Origin and a Host that BOTH name it, so same-origin passes. The Host must also be a name
    /// that can only mean this server.
    @Test(arguments: [
        ("http://evil.example.com:8080", "evil.example.com:8080"),
        ("http://example.com", "example.com:80"),
        ("https://example.com", "example.com"),
        ("http://1.2.3.4.evil.com:8080", "1.2.3.4.evil.com:8080"),
    ])
    func aRebindableNameIsRefusedEvenWhenSameOrigin(origin: String, host: String) {
        #expect(!WebSocketOriginPolicy.allows(origin: origin, host: host))
    }

    /// A name the operator allowed (`--allow-host`), and this machine's own name, are trusted.
    @Test func anAllowedNameAndTheMachinesOwnNameAreTrusted() {
        #expect(WebSocketOriginPolicy.allows(origin: "https://sketch.example.org",
                                             host: "sketch.example.org",
                                             allowedHostNames: ["Sketch.Example.org"]))
        #expect(WebSocketOriginPolicy.isTrustedHostName("studio", machineNames: ["studio"]))
        #expect(WebSocketOriginPolicy.isTrustedHostName("localhost."))
        #expect(WebSocketOriginPolicy.isTrustedHostName("fe80::1%en0"))
        #expect(!WebSocketOriginPolicy.isTrustedHostName("300.1.1.1"))
        #expect(!WebSocketOriginPolicy.isTrustedHostName("local"))
    }

    /// The route refuses a rebinding handshake too — through the real server.
    @Test func theRouteRefusesARebindingHandshake() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsorigin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = InfSketchServer(port: 0, docsDirectory: dir, config: SessionConfig())
        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ws")!)
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("dGhlIHNhbXBsZSBub25jZQ==", forHTTPHeaderField: "Sec-WebSocket-Key")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        request.setValue("evil.example.com:\(port)", forHTTPHeaderField: "Host")
        request.setValue("http://evil.example.com:\(port)", forHTTPHeaderField: "Origin")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        await server.stop()
    }

    /// The app and scripts send no Origin at all — that must keep working.
    @Test func noOriginIsAllowed() {
        #expect(WebSocketOriginPolicy.allows(origin: nil, host: "localhost:8080"))
        #expect(WebSocketOriginPolicy.allows(origin: nil, host: nil))
    }

    /// The route itself answers 403 before any upgrade happens.
    @Test func theRouteRefusesACrossOriginHandshake() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsorigin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = InfSketchServer(port: 0, docsDirectory: dir, config: SessionConfig())
        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ws")!)
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("dGhlIHNhbXBsZSBub25jZQ==", forHTTPHeaderField: "Sec-WebSocket-Key")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        request.setValue("http://evil.example.com", forHTTPHeaderField: "Origin")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        await server.stop()
    }
}

/// `/mcp` holds a request that carries an `Origin` to the `/ws` rule, so a web page cannot reach
/// the tool surface by DNS rebinding — while an agent, which sends no `Origin`, is unaffected even
/// from another machine (round 6, item 9).
@Suite struct MCPOriginTests {
    private func post(port: UInt16, host: String, origin: String?) async throws -> Int? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue(host, forHTTPHeaderField: "Host")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode
    }

    @Test func aRebindingPageIsRefusedAndAnAgentIsNot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcporigin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = InfSketchServer(port: 0, docsDirectory: dir, config: SessionConfig())
        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)

        // A page under a public name re-pointed here: Origin and Host agree, and are refused.
        #expect(try await post(port: port, host: "evil.example.com:\(port)",
                               origin: "http://evil.example.com:\(port)") == 403)
        // A cross-site page on a trusted host: refused too.
        #expect(try await post(port: port, host: "127.0.0.1:\(port)",
                               origin: "http://evil.example.com") == 403)
        // An agent on another machine: no Origin, a LAN Host — served.
        let agent = try await post(port: port, host: "192.168.1.50:\(port)", origin: nil)
        #expect(agent != 403 && agent != nil)
        #expect(agent == 200)
        await server.stop()
    }
}
