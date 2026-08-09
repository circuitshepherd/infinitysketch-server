import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WinSDK)
import WinSDK
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
    ///
    /// Matched case-INSENSITIVELY, and the last two entries are Windows': there an interface is
    /// named for a person to read (`Ethernet`, `Wi-Fi`) rather than `en0`/`wlan0`. Without them
    /// every Windows adapter fell into the same class and a Hyper-V or WSL bridge could be offered
    /// ahead of the Wi-Fi the phone is actually on — the exact miss this ranking exists to avoid.
    /// `vEthernet (WSL)` and `VMware Network Adapter …` do not match any prefix, which is right.
    private static let hardwarePrefixes = ["en", "eth", "wl", "wi-fi", "wireless"]

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
        let name = address.interface.lowercased()
        let hardware = hardwarePrefixes.contains { name.hasPrefix($0) }
        let linkLocal = address.ip.hasPrefix("169.254.")
        switch (hardware, linkLocal) {
        case (true, false): return 0
        case (false, false): return 1
        case (true, true): return 2
        case (false, true): return 3
        }
    }

    /// This machine's usable IPv4 addresses.
    public static func candidates() -> [LocalAddress] {
        #if os(Windows)
        return ranked(windowsAdapters())
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

    #if os(Windows)
    /// This machine's IPv4 addresses, from the Windows IP Helper API.
    ///
    /// `getifaddrs` does not exist on Windows; `GetAdaptersAddresses` is the supported equivalent.
    /// It also carries something POSIX does not: `Ipv4Metric`, the cost Windows itself assigns to
    /// routing over that interface. The list is pre-sorted by it, ASCENDING, so the interface
    /// Windows would actually route over is offered first — and because `ranked` sorts by class
    /// with a stable tie-break, that order survives as the ordering WITHIN each class.
    ///
    /// Filtering mirrors the POSIX branch rather than inventing its own: up-only (`IfOperStatusUp`,
    /// the counterpart of `IFF_UP`) and no loopback (by interface TYPE here, which is exact, where
    /// POSIX has to match the `127.` prefix in `ranked`).
    private static func windowsAdapters() -> [LocalAddress] {
        // The SDK spells these as C `#define`s, which do not reliably survive the importer. Four
        // documented numbers cost less than a build that breaks on a missing constant.
        let errorSuccess: UInt32 = 0
        let errorBufferOverflow: UInt32 = 111
        let ifTypeSoftwareLoopback: UInt32 = 24
        // GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER — none of
        // which this function reads, and each of which costs time and buffer to collect.
        let flags: UInt32 = 0x0002 | 0x0004 | 0x0008

        // MSDN's own recommended starting size. A short buffer is not a failure: the call reports
        // the size it needs, so the retry is the documented protocol rather than a guess. Bounded
        // because the answer can legitimately change between calls (an adapter appearing), and a
        // `while true` here would spin forever on a machine whose adapters keep churning.
        var size: UInt32 = 15 * 1024
        for _ in 0..<4 {
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size),
                alignment: MemoryLayout<IP_ADAPTER_ADDRESSES_LH>.alignment)
            defer { buffer.deallocate() }
            let list = buffer.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES_LH.self)

            let result = GetAdaptersAddresses(UInt32(AF_INET), flags, nil, list, &size)
            if result == errorBufferOverflow { continue }   // `size` now holds what it needs
            guard result == errorSuccess else { return [] }

            var found: [(metric: UInt32, address: LocalAddress)] = []
            for adapter in sequence(first: list, next: { $0.pointee.Next }) {
                let entry = adapter.pointee
                guard entry.OperStatus == IfOperStatusUp,
                      entry.IfType != ifTypeSoftwareLoopback,
                      let nameBuffer = entry.FriendlyName
                else { continue }
                // A person-readable name — `Ethernet`, `Wi-Fi`, `vEthernet (WSL)` — which is what
                // `hardwarePrefixes` matches on and what the terminal prints beside the address.
                let name = String(decodingCString: nameBuffer, as: UTF16.self)

                guard let firstAddress = entry.FirstUnicastAddress else { continue }
                for unicast in sequence(first: firstAddress, next: { $0.pointee.Next }) {
                    guard let socketAddress = unicast.pointee.Address.lpSockaddr,
                          socketAddress.pointee.sa_family == UInt16(AF_INET)
                    else { continue }
                    let ip = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        var octets = $0.pointee.sin_addr
                        // Read the four bytes rather than the `UInt32`: the field is in NETWORK
                        // order, so interpreting it as an integer would need a byte swap that is
                        // correct only on a little-endian host. The bytes are the address.
                        return withUnsafeBytes(of: &octets) {
                            $0.prefix(4).map(String.init).joined(separator: ".")
                        }
                    }
                    found.append((entry.Ipv4Metric, LocalAddress(interface: name, ip: ip)))
                }
            }
            // Sorted with the original position as the tie-break, because Swift's `sort` is NOT
            // stable — two adapters sharing a metric would otherwise be offered in an order that
            // could change between runs, and the terminal's `1`–`9` keys name positions.
            return found.enumerated()
                .sorted { a, b in
                    a.element.metric == b.element.metric
                        ? a.offset < b.offset
                        : a.element.metric < b.element.metric
                }
                .map(\.element.address)
        }
        return []
    }
    #endif
}
