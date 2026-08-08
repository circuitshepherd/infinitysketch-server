import Foundation

/// Which of this machine's addresses the terminal is currently showing a code for.
///
/// Pure state and no I/O: the raw-mode key reading in `main.swift` reads BYTES and decides nothing.
/// What a byte names is `key(for:)`, what a key DOES is `handle`, and which keys are on offer is
/// `keyHint` — all three here, so the line the user reads cannot promise a key the picker ignores.
/// That is not hypothetical: `q` used to end the reader thread from inside the read loop, leaving
/// the block on screen still offering `↑/↓`, `o` and `q` to a program that had stopped listening.
public struct AddressPicker: Sendable {
    public enum Key: Equatable, Sendable { case up, down, digit(Int), openBrowser, quit }

    /// What the caller must do about a key. Anything the picker cannot do itself — drawing,
    /// opening a browser, stopping the server — is named here rather than performed.
    public enum Action: Equatable, Sendable {
        /// The key changed nothing. Redrawing anyway makes the block flicker on every keypress.
        case none
        /// The selection moved; draw the code again.
        case redraw
        /// Open `currentOverviewURL`, then redraw for the message it produces.
        case openBrowser
        /// Stop the server.
        case quit
    }

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

    public mutating func handle(_ key: Key) -> Action {
        switch key {
        case .quit:
            // Deliberately not conditional on having an address: a machine with no usable one
            // still draws a block — the loopback MCP url — and still needs a way out.
            return .quit
        case .openBrowser:
            return .openBrowser
        case .up:
            return move(to: selection - 1)
        case .down:
            return move(to: selection + 1)
        case .digit(let n):
            // The emptiness check comes FIRST: `1...candidates.count` is `1...0` on an empty list,
            // which is not a range but a crash.
            guard !candidates.isEmpty, (1...candidates.count).contains(n) else { return .none }
            return move(to: n - 1)
        }
    }

    /// Moves the selection, clamped, and reports whether anything actually changed.
    ///
    /// With nothing to select every move is a no-op. Without that guard, `.down` clamps to
    /// `count - 1` = -1 and the selection walks off the front of an empty list — reachable on a
    /// machine with no usable address, and on Windows, where the candidate list is always empty.
    private mutating func move(to index: Int) -> Action {
        guard !candidates.isEmpty else { return .none }
        let clamped = min(max(0, index), candidates.count - 1)
        guard clamped != selection else { return .none }
        selection = clamped
        return .redraw
    }

    /// The key an input byte names, or nil when it names nothing. Arrows are not here: they arrive
    /// as `Esc [ A` / `Esc [ B`, so the reader fetches the two bytes that follow and asks
    /// `arrowKey(for:)`.
    ///
    /// `0x03` is Ctrl-C, which normally never reaches a `read` at all: raw mode here clears
    /// `ICANON` and `ECHO` but leaves `ISIG` on, so the terminal turns it into SIGINT first
    /// (measured — exit 130 through the signal handler, with the picker running and after it).
    /// It is mapped anyway, and it maps to QUIT, which is what Ctrl-C has always meant.
    public static func key(for byte: UInt8) -> Key? {
        switch byte {
        case UInt8(ascii: "q"), 0x03: return .quit
        case UInt8(ascii: "o"): return .openBrowser
        case UInt8(ascii: "1")...UInt8(ascii: "9"): return .digit(Int(byte - UInt8(ascii: "0")))
        default: return nil
        }
    }

    /// The key named by the two bytes that follow an escape.
    public static func arrowKey(for sequence: [UInt8]) -> Key? {
        guard sequence.count == 2, sequence[0] == UInt8(ascii: "[") else { return nil }
        switch sequence[1] {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        default: return nil
        }
    }

    /// The one line naming the keys that are live, for the caller to print below the code — but
    /// only when a key can actually reach the process, which is the caller's to know.
    ///
    /// It is built here rather than at the print site so it cannot drift from `handle`: a key is
    /// named only when pressing it would do something. With one address there is nothing to switch
    /// between; with none there is no page to open.
    public var keyHint: String {
        var parts: [String] = []
        if candidates.count > 1 {
            parts.append("↑/↓ or 1–\(min(9, candidates.count)) to switch")
        }
        if currentOverviewURL != nil {
            parts.append("o to open in browser")
        }
        parts.append("q to quit")
        return parts.joined(separator: " · ")
    }
}
