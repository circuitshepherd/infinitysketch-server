import FlyingSocks

/// Routes FlyingFox's own log lines through `ServerLog`, so the server is quiet by default on
/// EVERY platform.
///
/// WHY THIS EXISTS: `HTTPServer(port:)` defaults its `logger:` to `HTTPServer.defaultLogger()`,
/// which is
///
///     #if canImport(OSLog) → .oslog(category:)   // Apple: the unified log
///     #else                → .print(category:)   // Windows, Linux: stdout
///
/// so every diagnostic `ServerLog` was written to suppress was being printed anyway by the HTTP
/// layer -- but only where nobody developing this could see it. On macOS those lines go to OSLog
/// and never reach the terminal, which is why the whole "the console is QUIET by default" property
/// was accidentally Apple-only and survived the reviews, the Linux gate and the Windows
/// verification alike. Reported 2026-08-16 by a user double-clicking the v1.0.0 release exe.
///
/// It is not merely noise on Windows. That console is where `drawJoinCode` draws the join block by
/// erasing the lines it drew last time, so anything printed between two draws tears the QR code
/// apart -- the exact rule that put every one of OUR diagnostics behind `ServerLog`. A library's
/// logger obeys nothing we write in this repository, so it has to be handed one.
///
/// EVERY level is a diagnostic here, `logCritical` included, and that took three attempts to get
/// right because the level NAMES do not describe severity in this library.
///
/// - `logError` is PER CONNECTION and PER REQUEST: a client disconnecting mid-read, an unhandled
///   route (an ordinary 404), a handler that threw. Routing it to `ServerLog.error` put a line on
///   the console for every 404 -- the very noise this file exists to stop -- on every platform,
///   the Mac included. It also cost measurable TIME, because `ServerLog.error` writes to stderr
///   synchronously and unbuffered, once per event: on GitHub's 2-vCPU Windows runner that was
///   enough to fail two timing tests which had passed on the same runner one release earlier
///   (`disconnectFailsPendingStrokeOpFast`, 1.29 s against a 1 s bound). CI caught it because CI
///   is the slow machine.
/// - `logCritical` sounds like the exception, and is not: FlyingFox emits it for a failed bind AND
///   for ordinary shutdown, where closing the listening socket out from under the accept loop
///   yields `server error: SocketError. kqueue kevent(9): Bad file descriptor` -- once per stop,
///   which in the test suite is once per test.
///
/// Nothing is lost by silencing all of it, and that is the load-bearing part: the startup failure
/// a user must see does NOT come from this logger. `main.swift` catches the error `server.run()`
/// throws and reports it through `StartupFailure.describe`, which names the port and suggests
/// another -- a better message than the one being suppressed here, and one that cannot be lost by
/// a change to this file. If that ever stops being true, this mapping has to be revisited.
///
/// The autoclosure arguments are only evaluated when the line will actually be emitted, so a
/// suppressed line costs nothing but the call.
struct ServerLogHTTPLogging: Logging {
    func logDebug(_ debug: @autoclosure () -> String) {
        guard ServerLog.isVerbose else { return }
        ServerLog.verbose("[http] \(debug())")
    }

    func logInfo(_ info: @autoclosure () -> String) {
        guard ServerLog.isVerbose else { return }
        ServerLog.verbose("[http] \(info())")
    }

    func logWarning(_ warning: @autoclosure () -> String) {
        guard ServerLog.isVerbose else { return }
        ServerLog.verbose("[http] \(warning())")
    }

    /// A disconnect, a 404, a handler that threw — one per connection or request, and none of them
    /// something the operator has to be told about. Diagnostic, despite the name.
    func logError(_ error: @autoclosure () -> String) {
        guard ServerLog.isVerbose else { return }
        ServerLog.verbose("[http] \(error())")
    }

    /// "already started", a failed bind — and every ordinary shutdown. Diagnostic: the startup
    /// failure a user must see is reported by `main.swift` from the thrown error, not from here.
    func logCritical(_ critical: @autoclosure () -> String) {
        guard ServerLog.isVerbose else { return }
        ServerLog.verbose("[http] \(critical())")
    }
}
