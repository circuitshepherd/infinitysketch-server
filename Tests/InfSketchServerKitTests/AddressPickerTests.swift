import Testing
@testable import InfSketchServerKit

/// The picker's decisions, without a terminal. The raw-mode reading in main.swift turns bytes into
/// these keys and does nothing else, so this is where the behaviour lives.
///
/// Every `handle` result goes into a local first: `#expect` captures its expression for the failure
/// message, and a mutating call cannot be made on that capture.
@Suite struct AddressPickerTests {
    private func picker() -> AddressPicker {
        AddressPicker(candidates: [
            LocalAddress(interface: "en0", ip: "192.168.1.42"),
            LocalAddress(interface: "en1", ip: "10.0.0.5"),
            LocalAddress(interface: "utun3", ip: "10.8.0.2"),
        ], port: 18551)
    }

    @Test func theURLIsTheJoinPageOnThisPort() {
        #expect(AddressPicker.joinURL(ip: "192.168.1.42", port: 18551)
                == "http://192.168.1.42:18551/join")
        #expect(picker().currentURL == "http://192.168.1.42:18551/join")
    }

    @Test func arrowsMoveTheSelectionAndClampAtTheEnds() {
        var p = picker()
        #expect(p.selection == 0)
        let atTop = p.handle(.up)
        #expect(atTop == .none, "already at the top — nothing to redraw")
        let movedDown = p.handle(.down)
        #expect(movedDown == .redraw)
        #expect(p.selection == 1)
        _ = p.handle(.down)
        let pastEnd = p.handle(.down)
        #expect(pastEnd == .none, "clamped at the last candidate")
        #expect(p.selection == 2)
    }

    @Test func digitsJumpAndOutOfRangeDigitsAreIgnored() {
        var p = picker()
        let jumped = p.handle(.digit(3))
        #expect(jumped == .redraw)
        #expect(p.selection == 2)
        let ninth = p.handle(.digit(9))
        #expect(ninth == .none, "there is no ninth address")
        #expect(p.selection == 2)
    }

    /// Re-selecting the current address changes nothing, so the caller must not redraw — otherwise
    /// every keypress reprints the block and the terminal flickers.
    @Test func reselectingTheSameAddressIsNotAChange() {
        var p = picker()
        let again = p.handle(.digit(1))
        #expect(again == .none)
    }

    /// With nothing to show there is no url, and the caller prints why instead of a code.
    @Test func noCandidatesMeansNoURL() {
        var empty = AddressPicker(candidates: [], port: 8080)
        #expect(empty.currentURL == nil)
        let moved = empty.handle(.down)
        #expect(moved == .none)
        let digit = empty.handle(.digit(1))
        #expect(digit == .none, "a digit must not index an empty list")
    }

    /// The url the `o` key opens: the overview page on the SELECTED address, so the page's own
    /// Host header selects that address's code. Every url shape this feature has lives on
    /// `AddressPicker`, so the terminal and the web page can never disagree about one.
    @Test func theOverviewUrlIsTheRootOfTheSelectedAddress() {
        #expect(AddressPicker.overviewURL(ip: "192.168.1.42", port: 18551)
                == "http://192.168.1.42:18551/")
        #expect(picker().currentOverviewURL == "http://192.168.1.42:18551/")
    }

    @Test func withNoCandidatesThereIsNoOverviewUrl() {
        #expect(AddressPicker(candidates: [], port: 18551).currentOverviewURL == nil)
    }

    @Test func theOverviewUrlFollowsTheSelection() {
        var p = picker()
        let moved = p.handle(.down)
        #expect(moved == .redraw)
        #expect(p.currentOverviewURL == "http://10.0.0.5:18551/")
    }

    // MARK: - quit

    /// `q` STOPS THE SERVER. It used to end the key reader and nothing else, which left the block
    /// on screen still advertising four keys that no longer did anything — measured: pressing them
    /// afterwards echoed `1^[[Bo` under a hint line promising they worked.
    @Test func qStopsTheServer() {
        var p = picker()
        let action = p.handle(.quit)
        #expect(action == .quit)
    }

    /// Quitting must not depend on having an address to show: a machine with no usable address
    /// still draws a block (the loopback MCP url) and still needs a way out.
    @Test func quittingWorksWithNoCandidates() {
        var empty = AddressPicker(candidates: [], port: 8080)
        let action = empty.handle(.quit)
        #expect(action == .quit)
    }

    @Test func quittingDoesNotMoveTheSelection() {
        var p = picker()
        _ = p.handle(.down)
        _ = p.handle(.quit)
        #expect(p.selection == 1)
    }

    // MARK: - bytes to keys

    /// The reader in `main.swift` reads bytes and decides nothing; what a byte MEANS is here, so a
    /// test can check it without a terminal.
    @Test func theBytesThatMeanSomething() {
        #expect(AddressPicker.key(for: UInt8(ascii: "q")) == .quit)
        #expect(AddressPicker.key(for: UInt8(ascii: "o")) == .openBrowser)
        #expect(AddressPicker.key(for: UInt8(ascii: "1")) == .digit(1))
        #expect(AddressPicker.key(for: UInt8(ascii: "9")) == .digit(9))
    }

    /// Ctrl-C normally never arrives as a byte — raw mode here clears `ICANON` and `ECHO` but
    /// leaves `ISIG` on, so the terminal turns it into SIGINT first (measured: exit 130 through the
    /// signal handler). If it ever does arrive it means QUIT, which is what it always meant; the
    /// old reader mapped it to the same branch as `q`, back when `q` merely stopped listening.
    @Test func ctrlCAsAByteMeansQuit() {
        #expect(AddressPicker.key(for: 0x03) == .quit)
    }

    @Test func everyOtherByteMeansNothing() {
        for byte in [UInt8(ascii: "Q"), UInt8(ascii: "x"), UInt8(ascii: "0"),
                     UInt8(ascii: " "), 0x1B, 0x04] {
            #expect(AddressPicker.key(for: byte) == nil, "byte \(byte) should mean nothing")
        }
    }

    /// An arrow arrives as `Esc [ A` / `Esc [ B`; the reader fetches the two bytes after the escape
    /// and asks what they name.
    @Test func arrowSequences() {
        #expect(AddressPicker.arrowKey(for: [UInt8(ascii: "["), UInt8(ascii: "A")]) == .up)
        #expect(AddressPicker.arrowKey(for: [UInt8(ascii: "["), UInt8(ascii: "B")]) == .down)
        #expect(AddressPicker.arrowKey(for: [UInt8(ascii: "["), UInt8(ascii: "C")]) == nil,
                "right arrow selects nothing here")
        #expect(AddressPicker.arrowKey(for: [UInt8(ascii: "O"), UInt8(ascii: "A")]) == nil,
                "application-cursor mode is not what this terminal is in")
        #expect(AddressPicker.arrowKey(for: [UInt8(ascii: "[")]) == nil, "short sequence")
    }

    // MARK: - the hint line

    /// The hint is built HERE, beside the code that honours the keys, so the line cannot promise a
    /// key the picker ignores — which is exactly what it did after `q`: the block stayed on screen
    /// offering `↑/↓`, `o` and `q` to a program that had stopped reading the keyboard.
    @Test func theHintOffersEveryKeyThatWorks() {
        #expect(picker().keyHint == "↑/↓ or 1–3 to switch · o to open in browser · q to quit")
    }

    /// One address: nothing to switch BETWEEN, but opening it in a browser and quitting both still
    /// work. The keys used to be offered only when there were two or more addresses, so a single
    /// address machine had no `o` and — once `q` became the way out — no way to quit either.
    @Test func withOneAddressThereIsNothingToSwitchBetween() {
        let one = AddressPicker(candidates: [LocalAddress(interface: "en0", ip: "192.168.1.42")],
                                port: 18551)
        #expect(one.keyHint == "o to open in browser · q to quit")
    }

    /// No address means no page to open, so `o` is not offered — and pressing it does nothing,
    /// which is the pairing this test exists to hold together.
    @Test func withNoAddressOnlyQuitIsOffered() {
        let none = AddressPicker(candidates: [], port: 18551)
        #expect(none.keyHint == "q to quit")
        #expect(none.currentOverviewURL == nil)
    }

    /// Only nine addresses can be reached by digit, however many there are.
    @Test func theHintPromisesAtMostNineDigits() {
        let many = AddressPicker(
            candidates: (1...12).map { LocalAddress(interface: "en\($0)", ip: "10.0.0.\($0)") },
            port: 18551)
        #expect(many.keyHint == "↑/↓ or 1–9 to switch · o to open in browser · q to quit")
    }
}
