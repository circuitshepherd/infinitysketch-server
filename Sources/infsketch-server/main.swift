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
    default:
        print("usage: infsketch-server [--port N] [--docs DIR]")
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

// MARK: - scan to join

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

/// Whether a keypress can reach this process at all. ONE predicate, read by both the hint below and
/// the reader further down, so the offer and the ability to honour it cannot drift apart: under
/// `scripts/worktree-server` stdin is /dev/null, and the log was telling its reader to press keys
/// that nothing would ever read. On Windows there are no candidates, so the hint never prints.
/// A function rather than a computed `var`: a top-level variable in `main.swift` is implicitly
/// main-actor isolated, which `drawJoinCode` — an ordinary global function — cannot read.
func addressSwitchingIsPossible() -> Bool {
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
        // No usable address, or Windows. Say why rather than printing nothing at all.
        let text = "no reachable network address found — scan to join is unavailable here\n"
        print(text, terminator: "")
        fflush(nil)
        drawnLineCount = text.components(separatedBy: "\n").count - 1
        return
    }
    var text = (try? TerminalQRCode.render(url)) ?? ""
    text += "\nScan to sync a device with this server:\n  \(url)\n"
    if picker.candidates.count > 1 {
        for (index, candidate) in picker.candidates.enumerated() {
            let marker = index == picker.selection ? "▸" : " "
            text += "  \(marker) \(index + 1)) \(candidate.ip)  (\(candidate.interface))\n"
        }
        if addressSwitchingIsPossible() {
            text += "    ↑/↓ or 1–\(min(9, picker.candidates.count)) to switch · q to stop showing\n"
        }
    }
    print(text, terminator: "")
    // Flushed by hand: stdout is block-buffered when it is not a terminal, so under
    // `scripts/worktree-server` — which redirects to a log — the code would sit in the buffer until
    // something else filled it, and be lost entirely if the server were killed first.
    fflush(nil)
    drawnLineCount = text.components(separatedBy: "\n").count - 1
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

// The picker needs a terminal. Under `scripts/worktree-server` stdin is /dev/null, so this never
// arms at all and the first code simply stays in the log with the server running.
if addressSwitchingIsPossible(), picker.candidates.count > 1 {
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
            var key: AddressPicker.Key?
            switch byte[0] {
            case 0x1B:                                    // Esc — an arrow arrives as Esc [ A / B
                guard readExactly(2, into: &sequence) else { return }
                guard sequence[0] == UInt8(ascii: "[") else { continue }
                key = sequence[1] == UInt8(ascii: "A") ? .up
                    : sequence[1] == UInt8(ascii: "B") ? .down : nil
            case UInt8(ascii: "q"), 0x03:                 // q, or Ctrl-C if it reaches us as a byte
                return
            case UInt8(ascii: "1")...UInt8(ascii: "9"):
                key = .digit(Int(byte[0] - UInt8(ascii: "0")))
            default:
                key = nil
            }
            // Redraw only when the selection actually moved, or the block flickers on every key.
            if let key, picker.handle(key) { drawJoinCode() }
        }
    }
}
#endif

// Caught rather than propagated: an error thrown out of top-level code is a TRAP, which runs neither
// `atexit` nor any `defer` — so a second server on the same port would leave the terminal in raw
// mode. `exit` runs them. The message is also better than a stack trace.
do {
    try await server.run()
} catch {
    print("infsketch-server stopped: \(error)")
    exit(1)
}
