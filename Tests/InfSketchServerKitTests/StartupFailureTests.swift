import Testing
@testable import InfSketchServerKit

/// The failure a first-time user is most likely to meet, and the one the socket layer describes
/// worst. See `StartupFailure` for the measurement these are written from.
@Suite struct StartupFailureTests {

    /// The verbatim string FlyingSocks produced on Windows when port 18300 was already bound,
    /// captured 2026-08-10. Kept exactly as measured: the whole point of this type is that the
    /// useful fact is the number and NOT the message, so a paraphrase would test the wrong thing.
    static let windowsBindInUse =
        #"failed(type: "Bind", errno: 10048, message: "Unknown error")"#

    @Test func theWindowsAddressInUseErrorNamesThePortAndNotTheErrno() {
        let message = StartupFailure.describe(Self.windowsBindInUse, port: 8080)
        #expect(message.contains("port 8080 is already in use"))
        // The raw form must not survive: "Unknown error" is precisely the text that sent a user
        // looking in the wrong place.
        #expect(!message.contains("Unknown error"))
        #expect(!message.contains("10048"))
    }

    @Test func itSuggestsAPortTheUserCanActuallyTry() {
        #expect(StartupFailure.describe(Self.windowsBindInUse, port: 8080).contains("--port 8081"))
    }

    /// `port + 1` overflows at the top of the range, which would trap rather than print a message —
    /// a crash in the code whose entire job is to explain a failure clearly.
    @Test func theSuggestionDoesNotOverflowAtTheTopOfThePortRange() {
        let message = StartupFailure.describe(Self.windowsBindInUse, port: UInt16.max)
        #expect(message.contains("port 65535 is already in use"))
        #expect(message.contains("--port 8080"))
    }

    /// Darwin and Linux number `EADDRINUSE` differently from each other AND from Windows, so all
    /// three have to be recognised — a server developed on one and deployed on another otherwise
    /// loses the good message exactly where nobody is watching.
    @Test(arguments: [48, 98, 10048])
    func everyPlatformsAddressInUseIsRecognised(code: Int) {
        let raw = #"failed(type: "Bind", errno: \#(code), message: "Address already in use")"#
        #expect(StartupFailure.describe(raw, port: 8080).contains("already in use"))
        #expect(StartupFailure.describe(raw, port: 8080).contains("--port 8081"))
    }

    /// Anything unrecognised must pass the real error through. Guessing would replace a true
    /// message with a confident wrong one, which is worse than the raw form it started as.
    @Test func anUnrelatedFailureIsReportedVerbatim() {
        let raw = #"failed(type: "Listen", errno: 13, message: "Permission denied")"#
        let message = StartupFailure.describe(raw, port: 80)
        #expect(message.contains(raw))
        #expect(!message.contains("already in use"))
    }

    @Test func anErrorWithNoErrnoFieldIsReportedVerbatim() {
        let message = StartupFailure.describe("some other failure entirely", port: 8080)
        #expect(message.contains("some other failure entirely"))
        #expect(!message.contains("already in use"))
    }

    /// The errno is read from its OWN label, not by hunting for digits: a description carrying an
    /// address-in-use-shaped number somewhere else must not be diagnosed as one.
    @Test func aNumberElsewhereInTheMessageIsNotMistakenForTheErrno() {
        let raw = #"failed(type: "Bind", errno: 13, message: "wrote 10048 bytes to 48 handles")"#
        #expect(!StartupFailure.describe(raw, port: 8080).contains("already in use"))
    }

    @Test func theErrnoIsParsedFromItsLabel() {
        #expect(StartupFailure.errnoValue(in: #"errno: 10048, message: "x""#) == 10048)
        #expect(StartupFailure.errnoValue(in: "errno: 48") == 48)
        #expect(StartupFailure.errnoValue(in: "no errno here") == nil)
        #expect(StartupFailure.errnoValue(in: "errno: ") == nil)
    }
}
