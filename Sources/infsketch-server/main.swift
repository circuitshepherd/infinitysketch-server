import Foundation
import InfSketchServerKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
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
/// act after scanning is usually Ctrl-C, which unwinds nothing. So the restore is wired to three
/// exits: the reader's own `defer`, `atexit`, and SIGINT.
#if !os(Windows)
nonisolated(unsafe) var savedTerminalSettings: termios?

func restoreTerminalSettings() {
    guard var settings = savedTerminalSettings else { return }
    tcsetattr(STDIN_FILENO, TCSANOW, &settings)
}
#endif

nonisolated(unsafe) var picker = AddressPicker(candidates: LocalAddresses.candidates(), port: port)
nonisolated(unsafe) var drawnLineCount = 0

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
        fflush(stdout)
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
        text += "    ↑/↓ or 1–\(min(9, picker.candidates.count)) to switch · q to stop showing\n"
    }
    print(text, terminator: "")
    // Flushed by hand: stdout is block-buffered when it is not a terminal, so under
    // `scripts/worktree-server` — which redirects to a log — the code would sit in the buffer until
    // something else filled it, and be lost entirely if the server were killed first.
    fflush(stdout)
    drawnLineCount = text.components(separatedBy: "\n").count - 1
}

drawJoinCode()

#if !os(Windows)
// The picker needs a terminal. Under `scripts/worktree-server` stdin is /dev/null, so this task
// reaches EOF at once and exits, leaving the first code in the log and the server running.
if isatty(STDIN_FILENO) == 1, picker.candidates.count > 1 {
    Task.detached {
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        savedTerminalSettings = original
        atexit(restoreTerminalSettings)
        signal(SIGINT) { _ in restoreTerminalSettings(); exit(130) }
        defer { restoreTerminalSettings() }

        var raw = original
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)

        while true {
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { return }   // EOF: the terminal went away
            var key: AddressPicker.Key?
            switch byte {
            case 0x1B:                                    // Esc — an arrow arrives as Esc [ A / B
                var sequence = [UInt8](repeating: 0, count: 2)
                guard read(STDIN_FILENO, &sequence, 2) == 2,
                      sequence[0] == UInt8(ascii: "[") else { return }
                key = sequence[1] == UInt8(ascii: "A") ? .up
                    : sequence[1] == UInt8(ascii: "B") ? .down : nil
            case UInt8(ascii: "q"), 0x03:                 // q, or Ctrl-C if it reaches us as a byte
                return
            case UInt8(ascii: "1")...UInt8(ascii: "9"):
                key = .digit(Int(byte - UInt8(ascii: "0")))
            default:
                key = nil
            }
            // Redraw only when the selection actually moved, or the block flickers on every key.
            if let key, picker.handle(key) { drawJoinCode() }
        }
    }
}
#endif

try await server.run()
