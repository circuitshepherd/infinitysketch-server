import Foundation

/// Opens a url in whatever browser this machine considers default.
///
/// Best-effort in the strict sense: the server's behaviour does not depend on any of it. Every way
/// this can fail — no opener installed, no graphical session, a spawn that throws — resolves to one
/// line of text and nothing else.
///
/// The DECISION is a pure function with the environment and the executable probe injected, so every
/// platform's branch is testable from any host. `open` is the only impure part, and no test calls
/// it: a test that opens a browser opens it on the machine running the suite.
public enum BrowserLauncher {

    public enum Platform: Sendable, Equatable { case macOS, linux, windows }

    public enum Outcome: Sendable, Equatable {
        /// The command that was run — named, so the log says what actually happened.
        case opened(String)
        /// Nothing could open a url. The name that was looked for.
        case noOpenerFound(String)
        /// The spawn itself threw. The reason.
        case failed(String)
        /// Deliberately not tried, and why.
        case notAttempted(String)
    }

    public enum Launch: Sendable, Equatable {
        case run(executable: String, arguments: [String])
        case skip(Outcome)
    }

    public static var currentPlatform: Platform {
        #if os(macOS)
        return .macOS
        #elseif os(Windows)
        return .windows
        #else
        return .linux
        #endif
    }

    /// What to spawn, or why not to. Pure.
    ///
    /// - Parameter isExecutable: the file probe (`FileManager.isExecutableFile` in production).
    public static func launch(
        url: String, platform: Platform,
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> Launch {
        switch platform {
        case .macOS:
            // An absolute path: no PATH lookup, no shell, and it has been at this location for the
            // whole life of the OS.
            let opener = "/usr/bin/open"
            guard isExecutable(opener) else { return .skip(.noOpenerFound(opener)) }
            return .run(executable: opener, arguments: [url])

        case .linux:
            // A server box has no browser to open, and `xdg-open` there can launch a TERMINAL
            // browser into the very terminal the join code is being drawn in. An EMPTY variable is
            // not a display — a headless box that exports one unset is the ordinary case.
            let display = ["DISPLAY", "WAYLAND_DISPLAY"].contains {
                environment[$0]?.isEmpty == false
            }
            guard display else { return .skip(.notAttempted("no DISPLAY or WAYLAND_DISPLAY")) }
            // PATH is searched HERE rather than delegated to `/usr/bin/env`, which would turn a
            // missing opener into an exit code — and nothing waits for the child, so that would
            // read as success.
            guard let resolved = resolve("xdg-open", searchPath: environment["PATH"] ?? "",
                                         separator: ":", isExecutable: isExecutable) else {
                return .skip(.noOpenerFound("xdg-open"))
            }
            return .run(executable: resolved, arguments: [url])

        case .windows:
            // `start` is a shell builtin, so the shell is the executable. `ComSpec` is where Windows
            // says its shell is; the literal is the same path on every installation that has ever
            // shipped, and is only reached when the variable is missing.
            let shell = environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe"
            // The empty argument is the WINDOW TITLE. Without it `start` takes the url for the
            // title and opens nothing.
            return .run(executable: shell, arguments: ["/c", "start", "", url])
        }
    }

    /// First directory on `searchPath` holding an executable `name`. Pure.
    static func resolve(
        _ name: String, searchPath: String, separator: Character,
        isExecutable: (String) -> Bool
    ) -> String? {
        for directory in searchPath.split(separator: separator, omittingEmptySubsequences: true) {
            let path = directory.hasSuffix("/") ? "\(directory)\(name)" : "\(directory)/\(name)"
            if isExecutable(path) { return path }
        }
        return nil
    }

    /// Spawns the browser. Never throws, and never waits for the child.
    ///
    /// **Not waiting is deliberate.** `xdg-open` routinely execs the browser and lives as long as
    /// it does, so an exit status collected later would produce a message minutes afterwards about
    /// the user CLOSING their browser. Everything worth reporting is decided at or before the
    /// spawn.
    public static func open(_ url: String) -> Outcome {
        let plan = launch(
            url: url, platform: currentPlatform,
            environment: ProcessInfo.processInfo.environment,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })

        switch plan {
        case .skip(let outcome):
            return outcome
        case .run(let executable, let arguments):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // The child gets no handles of ours: a terminal browser must not read the keystrokes
            // the address picker is reading, nor write over the code it has drawn.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                return .opened(([executable] + arguments).joined(separator: " "))
            } catch {
                return .failed("\(error)")
            }
        }
    }

    /// The one line the terminal prints about it.
    public static func message(for outcome: Outcome, url: String) -> String {
        switch outcome {
        case .opened:
            return "opened \(url) in your browser"
        case .noOpenerFound(let name):
            return "could not open a browser (no \(name)) — open \(url) yourself"
        case .notAttempted(let reason):
            return "could not open a browser (\(reason)) — open \(url) yourself"
        case .failed(let reason):
            return "could not open a browser (\(reason)) — open \(url) yourself"
        }
    }
}
