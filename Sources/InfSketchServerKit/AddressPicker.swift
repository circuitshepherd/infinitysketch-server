import Foundation

/// Which of this machine's addresses the terminal is currently showing a code for.
///
/// Pure state and no I/O: the raw-mode key reading lives in `main.swift`, so the decisions can be
/// tested without a terminal. `handle` returns whether the selection actually CHANGED, so the
/// caller redraws only when there is something new to draw — redrawing on every keypress makes the
/// block flicker.
public struct AddressPicker: Sendable {
    public enum Key: Equatable, Sendable { case up, down, digit(Int), quit }

    public let candidates: [LocalAddress]
    public let port: UInt16
    public private(set) var selection = 0

    public init(candidates: [LocalAddress], port: UInt16) {
        self.candidates = candidates
        self.port = port
    }

    /// The url a scanned code carries: the `/join` page on this server.
    public static func joinURL(ip: String, port: UInt16) -> String {
        "http://\(ip):\(port)/join"
    }

    /// The url an AGENT is given: this server's MCP endpoint on the same address the code carries.
    ///
    /// An agent does not scan anything — it wants one string to put in a config file — so the
    /// terminal prints this beside the code rather than drawing a second one.
    public static func mcpURL(ip: String, port: UInt16) -> String {
        "http://\(ip):\(port)/mcp"
    }

    /// The overview page on this address — what the terminal's `o` key opens.
    ///
    /// Deliberately the address's OWN url rather than `localhost`: the page reads the `Host` header
    /// it was reached on and shows that address's code large, so switching in the terminal and
    /// pressing `o` needs no query parameter and no shared state.
    public static func overviewURL(ip: String, port: UInt16) -> String {
        "http://\(ip):\(port)/"
    }

    public var currentURL: String? {
        candidates.indices.contains(selection)
            ? Self.joinURL(ip: candidates[selection].ip, port: port)
            : nil
    }

    public var currentMCPURL: String? {
        candidates.indices.contains(selection)
            ? Self.mcpURL(ip: candidates[selection].ip, port: port)
            : nil
    }

    /// The MCP url for an agent on THIS machine.
    ///
    /// Printed beside the LAN one rather than instead of it: an agent on this machine needs no
    /// network address, and unlike the LAN address this one survives a Wi-Fi change — so it is the
    /// better string to put in a config file whenever the agent is local. It exists even with no
    /// candidates at all, which is what the no-address fallback prints.
    public var loopbackMCPURL: String {
        Self.mcpURL(ip: "127.0.0.1", port: port)
    }

    public var currentOverviewURL: String? {
        candidates.indices.contains(selection)
            ? Self.overviewURL(ip: candidates[selection].ip, port: port)
            : nil
    }

    /// Returns true when the selection moved — i.e. when the caller should redraw.
    public mutating func handle(_ key: Key) -> Bool {
        // With nothing to select, every key is a no-op. Without this, `.down` clamps to
        // `count - 1` = -1 and the selection walks off the front of an empty list — reachable on a
        // machine with no usable address, and on Windows, where the candidate list is always empty.
        guard !candidates.isEmpty else { return false }
        let previous = selection
        switch key {
        case .up:
            selection = max(0, selection - 1)
        case .down:
            selection = min(candidates.count - 1, selection + 1)
        case .digit(let n) where (1...candidates.count).contains(n):
            selection = n - 1
        case .digit, .quit:
            break
        }
        return selection != previous
    }
}
