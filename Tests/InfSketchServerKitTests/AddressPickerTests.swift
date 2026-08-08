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
        #expect(atTop == false, "already at the top — nothing to redraw")
        let movedDown = p.handle(.down)
        #expect(movedDown)
        #expect(p.selection == 1)
        _ = p.handle(.down)
        let pastEnd = p.handle(.down)
        #expect(pastEnd == false, "clamped at the last candidate")
        #expect(p.selection == 2)
    }

    @Test func digitsJumpAndOutOfRangeDigitsAreIgnored() {
        var p = picker()
        let jumped = p.handle(.digit(3))
        #expect(jumped)
        #expect(p.selection == 2)
        let ninth = p.handle(.digit(9))
        #expect(ninth == false, "there is no ninth address")
        #expect(p.selection == 2)
    }

    /// Re-selecting the current address changes nothing, so the caller must not redraw — otherwise
    /// every keypress reprints the block and the terminal flickers.
    @Test func reselectingTheSameAddressIsNotAChange() {
        var p = picker()
        let again = p.handle(.digit(1))
        #expect(again == false)
    }

    /// With nothing to show there is no url, and the caller prints why instead of a code.
    @Test func noCandidatesMeansNoURL() {
        var empty = AddressPicker(candidates: [], port: 8080)
        #expect(empty.currentURL == nil)
        let moved = empty.handle(.down)
        #expect(moved == false)
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
        #expect(moved)
        #expect(p.currentOverviewURL == "http://10.0.0.5:18551/")
    }
}
