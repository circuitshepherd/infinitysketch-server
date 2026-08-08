import Foundation
import InfSketchServerKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WinSDK)
import WinSDK          // the C runtime, for `fflush` — the terminal handling below is POSIX-only
#endif

var port: UInt16 = 8080
var docsPath = "./docs"
var openBrowser = true

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--port":
        guard let value = arguments.next().flatMap({ UInt16($0) }) else {
            print("--port requires a number"); exit(1)
        }
        port = value
    case "--docs":
        guard let value = arguments.next() else {
            print("--docs requires a path"); exit(1)
        }
        docsPath = value
    case "--no-open":
        // For anything that starts a server without a person watching — `scripts/worktree-server`
        // above all, one per worktree and usually started by an agent.
        openBrowser = false
    default:
        print("usage: infsketch-server [--port N] [--docs DIR] [--no-open]")
        exit(argument == "--help" ? 0 : 1)
    }
}

let docsDirectory = URL(fileURLWithPath: docsPath, isDirectory: true)
do {
    try FileManager.default.createDirectory(at: docsDirectory, withIntermediateDirectories: true)
} catch {
    print("could not create docs directory at \(docsDirectory.path): \(error.localizedDescription)")
    exit(1)
}

let server = InfSketchServer(port: port, docsDirectory: docsDirectory)
print("infsketch-server \(ServerInfo.version) — http://localhost:\(port)  docs: \(docsDirectory.path)")

// MARK: - scan to join, and the agent address beside it

/// Saved so the terminal can be put back however this process ends. At file scope because `atexit`
/// and `signal` take C function pointers, which cannot capture context.
///
/// A terminal left in raw mode is a wrecked shell — no echo, no line editing — and the user's next
/// act after scanning is usually Ctrl-C, which unwinds nothing. So the restore is wired to every way
/// out: the reader's own `defer`, `atexit`, SIGINT, SIGTERM, and the do/catch around `server.run()`.
///
/// **That last one is the path that actually bites, and it is not exotic.** A second server on the
/// same port — routine here, one per worktree — makes `run()` throw, and an error thrown from
/// top-level code TRAPS rather than exits, so neither `atexit` nor the `defer` ever runs. Catching
/// it and calling `exit` is the whole difference between a tidy message and a broken shell.
#if !os(Windows)
nonisolated(unsafe) var savedTerminalSettings: termios?

func restoreTerminalSettings() {
    guard var settings = savedTerminalSettings else { return }
    tcsetattr(STDIN_FILENO, TCSANOW, &settings)
}
#endif

nonisolated(unsafe) var picker = AddressPicker(candidates: LocalAddresses.candidates(), port: port)
nonisolated(unsafe) var drawnLineCount = 0

/// The last thing the browser-open attempt had to say, drawn as part of the block below the code.
///
/// It lives INSIDE the redrawn region on purpose. `drawJoinCode` erases exactly the lines it drew
/// last time, so anything printed between two draws — the startup message, or the reply to the `o`
/// key — would leave the cursor somewhere the erase does not expect and tear the block apart.
nonisolated(unsafe) var openMessage: String?

/// Whether a keypress can reach this process at all. ONE predicate, read by both the hint below and
/// the reader further down, so the offer and the ability to honour it cannot drift apart: under
/// `scripts/worktree-server` stdin is /dev/null, and the log was telling its reader to press keys
/// that nothing would ever read. On Windows the terminal handling is not built at all.
/// A function rather than a computed `var`: a top-level variable in `main.swift` is implicitly
/// main-actor isolated, which `drawJoinCode` — an ordinary global function — cannot read.
///
/// It is deliberately NOT conditional on how many addresses there are. It was, and that made `q` —
/// the documented way to stop the server — present on a machine with two addresses and absent on
/// one with a single address, which is not a difference a user can be expected to know about.
func keyReadingIsPossible() -> Bool {
    #if os(Windows)
    return false
    #else
    return isatty(STDIN_FILENO) == 1
    #endif
}

/// Draws the code for the selected address, erasing whatever was drawn before it, so only ONE code
/// is ever on screen.
func drawJoinCode() {
    if drawnLineCount > 0 {
        print("\u{1B}[\(drawnLineCount)A\u{1B}[0J", terminator: "")
    }
    guard let url = picker.currentURL else {
        // No usable address, or Windows. Say why rather than printing nothing at all — and still
        // give the loopback MCP url, which is the one thing that DOES work here: an agent on this
        // machine needs no network address.
        var text = "no reachable network address found — scan to join is unavailable here\n"
        text += "Connect an AI agent on THIS machine (MCP):\n"
        text += "  \(AddressPicker.mcpURL(ip: "127.0.0.1", port: picker.port))\n"
        if keyReadingIsPossible() { text += "    \(picker.keyHint)\n" }
        if let openMessage { text += "\n\(openMessage)\n" }
        print(text, terminator: "")
        fflush(nil)
        drawnLineCount = text.components(separatedBy: "\n").count - 1
        return
    }
    var text = (try? TerminalQRCode.render(url)) ?? ""
    text += "\nScan to sync a device with this server:\n  \(url)\n"
    // Printed, not drawn as a second code: an agent reads a config file, it does not hold a camera.
    if let mcp = picker.currentMCPURL {
        text += "\nConnect an AI agent (MCP), on this machine or another:\n  \(mcp)\n"
    }
    if picker.candidates.count > 1 {
        for (index, candidate) in picker.candidates.enumerated() {
            let marker = index == picker.selection ? "▸" : " "
            text += "  \(marker) \(index + 1)) \(candidate.ip)  (\(candidate.interface))\n"
        }
    }
    // The wording is `AddressPicker`'s, beside the code that honours the keys, so the line can
    // never offer one the reader ignores.
    if keyReadingIsPossible() { text += "    \(picker.keyHint)\n" }
    if let openMessage { text += "\n\(openMessage)\n" }
    print(text, terminator: "")
    // Flushed by hand: stdout is block-buffered when it is not a terminal, so under
    // `scripts/worktree-server` — which redirects to a log — the code would sit in the buffer until
    // something else filled it, and be lost entirely if the server were killed first.
    fflush(nil)
    drawnLineCount = text.components(separatedBy: "\n").count - 1
}

/// Set by the server task when `run()` throws, which is how a port already in use arrives — routine
/// here, one server per worktree.
nonisolated(unsafe) var serverFailure: (any Error)?

let serverTask = Task {
    do { try await server.run() } catch { serverFailure = error }
}

// Nothing invites the user to act before the socket is up: a browser tab that lands on a refused
// connection, or a join code for a server that never bound, are both worse than a few milliseconds
// of waiting. A FAILED bind — a second server on the same port, routine here, one per worktree —
// costs this whole timeout before the message appears, which is why it is 2 seconds rather than
// FlyingFox's 5: `serverFailure` already holds the real reason by then, and it is what decides.
let listening = (try? await server.waitUntilListening(timeout: 2)) != nil
if let failure = serverFailure {
    print("infsketch-server stopped: \(failure)")
    exit(1)
}

let localURL = "http://localhost:\(port)/"
if openBrowser, listening {
    openMessage = BrowserLauncher.message(for: BrowserLauncher.open(localURL), url: localURL)
}

drawJoinCode()

#if !os(Windows)
/// Read exactly `count` bytes, or report that the stream ended.
///
/// A single `read` is allowed to return SHORT, and an arrow key is three bytes: over ssh, or after a
/// paste, `Esc [ B` can arrive split. Demanding all of it in one call made the picker mistake that
/// for the terminal going away and quit silently for the rest of the session.
func readExactly(_ count: Int, into buffer: inout [UInt8]) -> Bool {
    var filled = 0
    while filled < count {
        let got = buffer.withUnsafeMutableBufferPointer {
            read(STDIN_FILENO, $0.baseAddress! + filled, count - filled)
        }
        guard got > 0 else { return false }          // 0 = EOF, -1 = error
        filled += got
    }
    return true
}

/// Stops the server, from the reader thread, in answer to `q`.
///
/// The terminal is put back by the `atexit` handler the reader registers: `exit` does not unwind
/// this thread, so its `defer` never runs. `exit` rather than `_exit` for exactly that reason —
/// this is not a signal handler and there is nothing here that has to be async-signal-safe.
///
/// In-flight connections are dropped, which is what Ctrl-C has always done. A submit that reached
/// `DocumentSession` has already been written by then, so nothing durable is lost.
func quitFromKeyboard() -> Never {
    // Below the drawn block rather than inside it: nothing will redraw over this.
    print("\ninfsketch-server stopped.")
    fflush(nil)
    exit(0)
}

// The reader needs a terminal. Under `scripts/worktree-server` stdin is /dev/null, so this never
// arms at all and the first code simply stays in the log with the server running.
if keyReadingIsPossible() {
    // A REAL THREAD, not `Task.detached`. `read` BLOCKS until a key arrives — which is to say, for
    // the whole life of the process — and a detached Task holds a cooperative-pool thread while it
    // does. The pool is sized to the core count, so on a single-core host that is the ONE thread the
    // accept loop and every connection need. Same rule the app already follows for PencilKit's
    // blocking rasterizer, and the same deadlock if it is broken.
    Thread.detachNewThread {
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        savedTerminalSettings = original
        atexit(restoreTerminalSettings)
        // `_exit`, not `exit`: only async-signal-safe calls are allowed here, and `exit` would also
        // run the `atexit` handler a second time. The restore has already happened by then.
        signal(SIGINT) { _ in restoreTerminalSettings(); _exit(130) }
        signal(SIGTERM) { _ in restoreTerminalSettings(); _exit(143) }
        defer { restoreTerminalSettings() }

        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)

        var byte = [UInt8](repeating: 0, count: 1)
        var sequence = [UInt8](repeating: 0, count: 2)
        while true {
            guard readExactly(1, into: &byte) else { return }   // EOF: the terminal went away
            let key: AddressPicker.Key?
            if byte[0] == 0x1B {                          // Esc — an arrow arrives as Esc [ A / B
                guard readExactly(2, into: &sequence) else { return }
                key = AddressPicker.arrowKey(for: sequence)
            } else {
                key = AddressPicker.key(for: byte[0])
            }
            guard let key else { continue }
            // What each key MEANS is the picker's, so this loop only carries out the answer. The
            // `.none` case is why: redrawing on a key that changed nothing makes the block flicker.
            switch picker.handle(key) {
            case .none:
                continue
            case .redraw:
                drawJoinCode()
            case .openBrowser:
                // Opens the SELECTED address's own page, so that page's `Host` header shows that
                // address's code large — no query parameter, no shared state. The selection does
                // not move, so this redraws for the message rather than for the block.
                if let url = picker.currentOverviewURL {
                    openMessage = BrowserLauncher.message(for: BrowserLauncher.open(url), url: url)
                    drawJoinCode()
                }
            case .quit:
                quitFromKeyboard()
            }
        }
    }
}
#endif

// The server is already running (started above). Awaiting the task here keeps the process alive and
// keeps the failure out of a `throw` from top-level code, which is a TRAP: it runs neither `atexit`
// nor any `defer`, so a second server on the same port would leave the terminal in raw mode. `exit`
// runs them, and the message is better than a stack trace.
await serverTask.value
if let failure = serverFailure {
    print("infsketch-server stopped: \(failure)")
    exit(1)
}
