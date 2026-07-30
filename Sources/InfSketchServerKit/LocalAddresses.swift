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
    /// `wl` covers `wlan` as well, so listing both would be one dead entry.
    private static let hardwarePrefixes = ["en", "eth", "wl"]

    /// Pure, so the ordering can be tested without a network.
    ///
    /// Only LOOPBACK is removed. Everything else stays in the list even when it is a poor guess,
    /// because the user can switch and the `/join` page checks the answer anyway — the ranking
    /// decides what is offered FIRST, not what is possible.
    public static func ranked(_ found: [LocalAddress]) -> [LocalAddress] {
        found
            .filter { !$0.ip.hasPrefix("127.") }     // loopback: a phone can never reach it
            .enumerated()
            .sorted { a, b in
                let ar = rank(a.element), br = rank(b.element)
                if ar != br { return ar < br }
                return a.offset < b.offset           // stable within a class
            }
            .map(\.element)
    }

    /// Lower sorts first. Link-local (`169.254.x`) is what an interface self-assigns when it got no
    /// address at all, so it sits on real hardware and would otherwise be offered first while being
    /// the one address least likely to work.
    private static func rank(_ address: LocalAddress) -> Int {
        let hardware = hardwarePrefixes.contains { address.interface.hasPrefix($0) }
        let linkLocal = address.ip.hasPrefix("169.254.")
        switch (hardware, linkLocal) {
        case (true, false): return 0
        case (false, false): return 1
        case (true, true): return 2
        case (false, true): return 3
        }
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
        guard getifaddrs(&head) == 0 else { return [] }
        // Installed BEFORE the nil check: a success that yields no list has still allocated, and
        // returning between the two would leak it.
        defer { freeifaddrs(head) }
        guard let first = head else { return [] }

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
