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
/// Levels map to the two `ServerLog` has, and the mapping is deliberately not one-to-one:
/// debug/info/warning are diagnostics (silent unless `--verbose`), while error and critical are
/// genuine failures and always visible on stderr. FlyingFox reports a failed bind as `logCritical`,
/// and that message must never be swallowed -- it is the one a first-time user most needs.
///
/// The autoclosure arguments are only evaluated when the line will actually be emitted, so a
/// suppressed debug line costs nothing but the call.
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

    func logError(_ error: @autoclosure () -> String) {
        ServerLog.error("[http] \(error())")
    }

    func logCritical(_ critical: @autoclosure () -> String) {
        ServerLog.error("[http] \(critical())")
    }
}
