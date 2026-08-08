import Testing
@testable import InfSketchServerKit

/// Opening a browser is one `Process` call, and everything that can go wrong about it is decided
/// BEFORE the spawn: which command this platform uses, whether the opener exists, whether there is
/// a graphical session at all. That decision is what is pinned here — nothing in this suite spawns
/// anything, because a test that opens a browser opens it on the machine running the suite.
@Suite struct BrowserLauncherTests {

    private let url = "http://localhost:8080/"

    @Test func macOSUsesTheAbsoluteOpenBinary() {
        let plan = BrowserLauncher.launch(
            url: url, platform: .macOS, environment: [:], isExecutable: { $0 == "/usr/bin/open" })
        #expect(plan == .run(executable: "/usr/bin/open", arguments: [url]))
    }

    /// The url is ONE argument. Passing it through a shell would make a url containing `&` or `;`
    /// into two commands.
    @Test func theUrlIsASingleArgument() {
        let plan = BrowserLauncher.launch(
            url: "http://h/?a=1&b=2", platform: .macOS, environment: [:], isExecutable: { _ in true })
        guard case .run(_, let arguments) = plan else {
            #expect(Bool(false), "expected .run")
            return
        }
        #expect(arguments == ["http://h/?a=1&b=2"])
    }

    /// Linux without a graphical session: `xdg-open` can hand the url to a TERMINAL browser, which
    /// then fights the server for the terminal it is printing the join code to.
    @Test func linuxWithoutADisplayDoesNotAttempt() {
        let plan = BrowserLauncher.launch(
            url: url, platform: .linux, environment: [:], isExecutable: { _ in true })
        #expect(plan == .skip(.notAttempted("no DISPLAY or WAYLAND_DISPLAY")))
    }

    @Test(arguments: ["DISPLAY", "WAYLAND_DISPLAY"])
    func linuxAcceptsEitherDisplayVariable(variable: String) {
        let plan = BrowserLauncher.launch(
            url: url, platform: .linux,
            environment: [variable: ":0", "PATH": "/bin"],
            isExecutable: { $0 == "/bin/xdg-open" })
        #expect(plan == .run(executable: "/bin/xdg-open", arguments: [url]))
    }

    /// An EMPTY `DISPLAY` is not a display. Testing only for the key's presence would attempt an
    /// open on every headless box that exports the variable unset.
    @Test func anEmptyDisplayIsNotAGraphicalSession() {
        let plan = BrowserLauncher.launch(
            url: url, platform: .linux, environment: ["DISPLAY": "", "PATH": "/bin"],
            isExecutable: { _ in true })
        #expect(plan == .skip(.notAttempted("no DISPLAY or WAYLAND_DISPLAY")))
    }

    /// PATH is searched here rather than delegated to `env`, because `env` turns a missing opener
    /// into an exit code — and nothing waits for the child, so that would read as success.
    @Test func linuxSearchesPathInOrder() {
        let plan = BrowserLauncher.launch(
            url: url, platform: .linux,
            environment: ["DISPLAY": ":0", "PATH": "/first:/second"],
            isExecutable: { $0 == "/second/xdg-open" })
        #expect(plan == .run(executable: "/second/xdg-open", arguments: [url]))
    }

    @Test func linuxWithNoOpenerOnPathReportsIt() {
        let plan = BrowserLauncher.launch(
            url: url, platform: .linux,
            environment: ["DISPLAY": ":0", "PATH": "/first:/second"],
            isExecutable: { _ in false })
        #expect(plan == .skip(.noOpenerFound("xdg-open")))
    }

    /// `start` takes its first quoted argument as the WINDOW TITLE, so the empty string is not
    /// filler — without it the url becomes the title and nothing opens.
    @Test func windowsPassesAnEmptyTitleBeforeTheUrl() {
        let comspec = "C:\\Windows\\System32\\cmd.exe"
        let plan = BrowserLauncher.launch(
            url: url, platform: .windows, environment: ["ComSpec": comspec],
            isExecutable: { _ in true })
        #expect(plan == .run(executable: comspec, arguments: ["/c", "start", "", url]))
    }

    @Test func windowsFallsBackToTheStandardShellPath() {
        let plan = BrowserLauncher.launch(
            url: url, platform: .windows, environment: [:], isExecutable: { _ in true })
        #expect(plan == .run(executable: "C:\\Windows\\System32\\cmd.exe",
                             arguments: ["/c", "start", "", url]))
    }

    /// Every outcome names the url, because the point of the failure line is that the user can open
    /// the page by hand.
    @Test(arguments: [
        BrowserLauncher.Outcome.opened("/usr/bin/open http://localhost:8080/"),
        BrowserLauncher.Outcome.noOpenerFound("xdg-open"),
        BrowserLauncher.Outcome.failed("permission denied"),
        BrowserLauncher.Outcome.notAttempted("no DISPLAY or WAYLAND_DISPLAY"),
    ])
    func everyMessageNamesTheUrl(outcome: BrowserLauncher.Outcome) {
        #expect(BrowserLauncher.message(for: outcome, url: "http://localhost:8080/")
            .contains("http://localhost:8080/"))
    }

    @Test func aFailureSaysWhyAndTellsTheUserToOpenItThemselves() {
        let line = BrowserLauncher.message(
            for: .noOpenerFound("xdg-open"), url: "http://localhost:8080/")
        #expect(line.contains("xdg-open"))
        #expect(line.lowercased().contains("could not open"))
    }
}
