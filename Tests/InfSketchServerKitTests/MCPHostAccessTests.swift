import Foundation
import Testing
import MCP
@testable import InfSketchServerKit

/// An agent on ANOTHER MACHINE could not reach `/mcp` at all, and the reason was invisible from
/// the outside: the socket accepted the connection and the server answered, so it looked like a
/// working endpoint that simply refused you.
///
/// `StatefulHTTPServerTransport` defaults its validation pipeline to `OriginValidator.localhost()`
/// — DNS-rebinding protection, which allows only `127.0.0.1`, `localhost` and `[::1]` in the
/// `Host` header. `MCPAdapter` passed only a session-id generator, so it inherited that default.
/// Measured before the change, over the LAN address of a real server: the request was answered
/// `-32600 Misdirected Request: Host header not allowed`, while the SAME request over the SAME
/// connection succeeded with `Host: 127.0.0.1` spoofed — proving the block was the header alone.
///
/// These tests pin OUR pipeline rather than the SDK's validators: the defect was which validators
/// are installed, so that is what is asserted. Running a request through the real pipeline (not
/// re-implementing its rules) is what keeps them honest.
@Suite struct MCPHostAccessTests {

    /// A minimal well-formed `initialize` POST, so only the Host under test can fail it.
    private func initializeRequest(host: String) -> MCP.HTTPRequest {
        MCP.HTTPRequest(
            method: "POST",
            headers: [
                "Host": host,
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
            ],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8),
            path: "/mcp")
    }

    private func context() -> HTTPValidationContext {
        HTTPValidationContext(httpMethod: "POST", sessionID: nil, isInitializationRequest: true)
    }

    /// The change itself: a LAN address is no longer refused.
    @Test(arguments: [
        "172.20.10.10:18816",       // a hotspot address — the one this was found on
        "192.168.1.50:8080",        // an ordinary home LAN
        "macbook.local:18816",      // the hostname form, which is what people actually type
        "[fe80::1]:18816",          // IPv6, brackets and all
    ])
    func anAgentOnAnotherMachineIsNotRefusedByItsHostHeader(host: String) throws {
        let rejection = MCPAdapter.validationPipeline.validate(initializeRequest(host: host),
                                                              context: context())
        #expect(rejection == nil, "Host \(host) was refused: \(String(describing: rejection))")
    }

    /// Loopback must keep working — every agent on this machine, and every existing registration,
    /// uses it.
    @Test(arguments: ["127.0.0.1:18816", "localhost:18816", "[::1]:18816"])
    func loopbackStillWorks(host: String) throws {
        #expect(MCPAdapter.validationPipeline.validate(initializeRequest(host: host),
                                                       context: context()) == nil)
    }

    /// The Host check was ONE of five validators the SDK installs by default. Replacing the
    /// pipeline wholesale is what makes it possible to drop the other four by accident — nothing
    /// about a passing MCP call would reveal it, because the transport would simply be more
    /// permissive. So each surviving check gets a request that it, and only it, should refuse.
    @Test func theOtherDefaultValidatorsSurvive() throws {
        // Accept: the transport streams SSE, so an `initialize` POST must accept it.
        let badAccept = MCP.HTTPRequest(
            method: "POST",
            headers: ["Host": "127.0.0.1:18816", "Accept": "text/plain",
                      "Content-Type": "application/json"],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8),
            path: "/mcp")
        #expect(MCPAdapter.validationPipeline.validate(badAccept, context: context()) != nil,
                "the Accept validator was dropped")

        // Content-Type: a POST body must be declared JSON.
        let badContentType = MCP.HTTPRequest(
            method: "POST",
            headers: ["Host": "127.0.0.1:18816",
                      "Accept": "application/json, text/event-stream",
                      "Content-Type": "text/plain"],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8),
            path: "/mcp")
        #expect(MCPAdapter.validationPipeline.validate(badContentType, context: context()) != nil,
                "the Content-Type validator was dropped")
    }
}
