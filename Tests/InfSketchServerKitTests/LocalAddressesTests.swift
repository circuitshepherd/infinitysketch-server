import Testing
@testable import InfSketchServerKit

/// Which address the QR code should carry. The ranking is the whole unit: enumeration is a syscall,
/// but choosing badly among what it returns is what would actually waste the user's time.
@Suite struct LocalAddressesTests {

    /// Hardware before virtual. A VPN tunnel or a container bridge is almost never the address a
    /// phone on the same Wi-Fi can reach, and it is routinely the one that sorts first by name.
    @Test func hardwareInterfacesRankAboveVirtualOnes() {
        let ranked = LocalAddresses.ranked([
            LocalAddress(interface: "utun3", ip: "10.8.0.2"),
            LocalAddress(interface: "docker0", ip: "172.17.0.1"),
            LocalAddress(interface: "en0", ip: "192.168.1.42"),
        ])
        #expect(ranked.first == LocalAddress(interface: "en0", ip: "192.168.1.42"))
        #expect(ranked.count == 3, "the others stay in the list — the user can switch to them")
    }

    /// Loopback is not a candidate at all: it is the one address guaranteed to fail from a phone.
    @Test func loopbackIsExcludedEntirely() {
        let ranked = LocalAddresses.ranked([
            LocalAddress(interface: "lo0", ip: "127.0.0.1"),
            LocalAddress(interface: "en0", ip: "192.168.1.42"),
        ])
        #expect(ranked == [LocalAddress(interface: "en0", ip: "192.168.1.42")])
    }

    /// Ties keep their discovered order, so two Ethernet ports do not swap places between runs and
    /// the code on screen stays put.
    @Test func rankingIsStableWithinAClass() {
        let ranked = LocalAddresses.ranked([
            LocalAddress(interface: "en1", ip: "192.168.1.9"),
            LocalAddress(interface: "en0", ip: "192.168.1.42"),
        ])
        #expect(ranked.map(\.interface) == ["en1", "en0"])
    }

    /// A link-local address is what an interface gives itself when it got none — so it sits on real
    /// HARDWARE and would otherwise be offered first while being the one address least likely to
    /// work. It stays in the list (the user can still pick it); it just stops being the default.
    @Test func linkLocalSinksBelowARealHardwareAddress() {
        let ranked = LocalAddresses.ranked([
            LocalAddress(interface: "en0", ip: "169.254.11.7"),
            LocalAddress(interface: "en1", ip: "192.168.1.42"),
        ])
        #expect(ranked.map(\.ip) == ["192.168.1.42", "169.254.11.7"])
    }

    @Test func noCandidatesIsAnEmptyListNotACrash() {
        #expect(LocalAddresses.ranked([]).isEmpty)
    }

    /// The real enumeration, on whatever machine this runs on. It cannot assert a specific address,
    /// but it can assert the invariants: no loopback survives, and nothing is malformed.
    @Test func theRealMachineYieldsUsableAddresses() {
        for candidate in LocalAddresses.candidates() {
            #expect(!candidate.ip.hasPrefix("127."), "loopback reached the candidate list")
            #expect(!candidate.interface.isEmpty)
            #expect(candidate.ip.split(separator: ".").count == 4, "not an IPv4 address: \(candidate.ip)")
        }
    }
}
