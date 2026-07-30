import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One IPv4 address this machine can be reached at.
public struct LocalAddress: Sendable, Equatable {
    public let interface: String
    public let ip: String

    public init(interface: String, ip: String) {
        self.interface = interface
        self.ip = ip
    }
}

/// The addresses a device on the same network might reach this server at, best guess first.
///
/// Ranking exists because the first address a machine reports is routinely the wrong one: a VPN
/// tunnel, a container bridge or a virtual-machine host adapter, none of which a phone on the Wi-Fi
/// can talk to. Guessing wrong is not fatal — the `/join` page reads back the address the device
/// actually connected to — but it costs the user a step, so the guess is worth making well.
public enum LocalAddresses {
    /// Interface name prefixes that are real hardware on the platforms this runs on.
    private static let hardwarePrefixes = ["en", "eth", "wlan", "wl"]

    /// Pure, so the ordering can be tested without a network.
    public static func ranked(_ found: [LocalAddress]) -> [LocalAddress] {
        found
            .filter { !$0.ip.hasPrefix("127.") }     // loopback: a phone can never reach it
            .enumerated()
            .sorted { a, b in
                let ah = isHardware(a.element.interface), bh = isHardware(b.element.interface)
                if ah != bh { return ah }
                return a.offset < b.offset           // stable within a class
            }
            .map(\.element)
    }

    private static func isHardware(_ interface: String) -> Bool {
        hardwarePrefixes.contains { interface.hasPrefix($0) }
    }

    /// This machine's usable IPv4 addresses.
    ///
    /// **Windows returns an empty list in v1**: `getifaddrs` does not exist there and
    /// `GetAdaptersAddresses` is a separate piece of work against an API this project has never
    /// touched. The server runs normally; it just prints no code.
    public static func candidates() -> [LocalAddress] {
        #if os(Windows)
        return []
        #else
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [LocalAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            // `sa_len` is a BSD field and does not exist on Glibc; the length of an IPv4 sockaddr is
            // fixed either way, so take it from the type rather than from the struct.
            let length = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(addr, length, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append(LocalAddress(interface: String(cString: interface.ifa_name),
                                      ip: String(cString: host)))
        }
        return ranked(found)
        #endif
    }
}
