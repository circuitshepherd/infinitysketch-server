import Foundation
import FlyingSocks

/// The server must OWN its port on the loopback addresses (2026-10-11).
///
/// FlyingFox listens with SO_REUSEADDR, and on Darwin a dual-stack IPv6-wildcard listener with that
/// option BINDS a port another program already holds on 127.0.0.1 only — measured with a Python
/// probe on the development Mac, both SO_REUSEADDR and SO_REUSEPORT. A connection to
/// 127.0.0.1:<port> then reaches the OTHER program. GitKraken and OrbStack hold such ports; server
/// tests that landed on one were answered "Authentication required" by GitKraken and failed a
/// landing at random, and a real server started there would hand the Mac's own app to the other
/// program with no "port in use" anywhere. Two defences, one per way a port is chosen:
///   - an AUTOMATIC port (0) is picked here, by a bind WITHOUT SO_REUSEADDR, which the kernel
///     refuses for a port held on either family — so it can never be one of those ports;
///   - EVERY port is then checked once listening (`foreignOwner`): when another program holds it on
///     127.0.0.1 or ::1, the server stops as "port in use" (`LoopbackPortTaken`).
/// The bind-without-reuse is NOT used for a fixed port: it is also refused while old connections
/// sit in TIME_WAIT, which would stop a server restarted on its usual port for a minute.
enum LoopbackPort {
    /// A port free on BOTH loopback families. Throws only when no socket can be made at all.
    static func pickFree() throws -> UInt16 {
        #if canImport(WinSDK)
        let socket = try Socket(domain: AF_INET)
        try socket.bind(to: sockaddr_in.inet(port: 0))
        #else
        let socket = try Socket(domain: AF_INET6)
        try socket.bind(to: sockaddr_in6.inet6(port: 0))
        #endif
        defer { try? socket.close() }
        switch try socket.sockname() {
        case .ip4(_, let port), .ip6(_, let port): return port
        default: throw SocketError.disconnected
        }
    }

    /// The loopback address ANOTHER program holds `port` on, or nil. Asked by BINDING, never by
    /// talking to it: a program that accepts and never answers (the test's stand-in, and some
    /// local servers) cannot be told from a slow one by a request. On Darwin a bind with
    /// SO_REUSEADDR to 127.0.0.1:<port> SUCCEEDS beside our own wildcard listener and FAILS with
    /// EADDRINUSE when another socket holds exactly that address — measured with and without
    /// reuse on the other side. Linux refuses the overlapping wildcard bind in the first place
    /// (the server's own bind then fails as "in use"), and Windows binds exclusively, so neither
    /// needs — or may run — this probe: on Linux it would refuse beside our own listener.
    static func foreignOwner(port: UInt16) -> String? {
        #if canImport(Darwin)
        func heldElsewhere(_ make: () throws -> Socket, _ address: () throws -> any SocketAddress) -> Bool {
            guard let socket = try? make() else { return false }
            defer { try? socket.close() }
            try? socket.setValue(true, for: .localAddressReuse)
            do {
                try socket.bind(to: try address())
                return false
            } catch let SocketError.failed(_, errno, _) {
                return errno == EADDRINUSE
            } catch {
                return false
            }
        }
        if heldElsewhere({ try Socket(domain: AF_INET) }, { try sockaddr_in.inet(ip4: "127.0.0.1", port: port) }) {
            return "127.0.0.1"
        }
        if heldElsewhere({ try Socket(domain: AF_INET6) }, { try sockaddr_in6.inet6(ip6: "::1", port: port) }) {
            return "::1"
        }
        #endif
        return nil
    }
}

/// Another program owns the port on a loopback address. Its description carries the platform's
/// address-in-use errno, so `StartupFailure.describe` says "port N is already in use".
struct LoopbackPortTaken: Error, CustomStringConvertible {
    let port: UInt16
    let address: String
    var description: String {
        #if canImport(WinSDK)
        let code = 10048
        #elseif os(Linux)
        let code = 98
        #else
        let code = 48
        #endif
        return "another program answers on \(address):\(port) (errno: \(code), address already in use)"
    }
}
