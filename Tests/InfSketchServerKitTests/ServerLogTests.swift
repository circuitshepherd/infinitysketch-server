import Foundation
import Testing
@testable import InfSketchServerKit

/// The one gate for operational log lines. Serialized: the gate is process-global state, and other
/// suites' sessions may log concurrently.
@Suite(.serialized) struct ServerLogTests {

    /// A tiny locked box: the sink closures are `@Sendable`, so the capture must be too.
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test func verboseIsSilentByDefaultAndSpeaksWhenEnabled() {
        let originalFlag = ServerLog.isVerbose
        let originalSink = ServerLog.verboseSink
        defer { ServerLog.isVerbose = originalFlag; ServerLog.verboseSink = originalSink }

        let captured = Capture()
        ServerLog.verboseSink = { captured.append($0) }

        // contains-based, not equality: `.serialized` orders only THIS suite, and while the flag
        // is up a parallel suite's own diagnostics land in the swapped sink too.
        ServerLog.isVerbose = false
        ServerLog.verbose("serverlog-test-dropped")
        #expect(!captured.lines.contains("serverlog-test-dropped"))

        ServerLog.isVerbose = true
        ServerLog.verbose("serverlog-test-kept")
        #expect(captured.lines.contains("serverlog-test-kept"))
    }

    /// A document failing to reach disk must never be silent (Josef, 2026-08-14): `error` ignores
    /// the flag entirely.
    @Test func errorIgnoresTheVerboseFlag() {
        let originalFlag = ServerLog.isVerbose
        let originalSink = ServerLog.errorSink
        defer { ServerLog.isVerbose = originalFlag; ServerLog.errorSink = originalSink }

        let captured = Capture()
        ServerLog.errorSink = { captured.append($0) }

        ServerLog.isVerbose = false
        ServerLog.error("serverlog-test-still-here")
        #expect(captured.lines.contains("serverlog-test-still-here"))
    }

    /// `report` is the `[blob-omission]` funnel the e2e gates grep — it must route through the
    /// gate (silent by default), keeping its prefix byte-for-byte.
    @Test func theBlobOmissionFunnelRoutesThroughTheGate() {
        let originalFlag = ServerLog.isVerbose
        let originalSink = ServerLog.verboseSink
        defer { ServerLog.isVerbose = originalFlag; ServerLog.verboseSink = originalSink }

        let captured = Capture()
        ServerLog.verboseSink = { captured.append($0) }

        ServerLog.isVerbose = false
        DocumentSession.report("ServerLogTestsDoc: quiet")
        #expect(!captured.lines.contains("[blob-omission] ServerLogTestsDoc: quiet"))

        ServerLog.isVerbose = true
        DocumentSession.report("ServerLogTestsDoc: loud")
        #expect(captured.lines.contains("[blob-omission] ServerLogTestsDoc: loud"))
    }

    /// FlyingFox's own lines obey the same gate. Its default logger prints to stdout on every
    /// non-Apple platform, so before this the quiet console was Apple-only — invisible to everyone
    /// developing on a Mac, and reported by the first user to double-click the Windows release.
    @Test func theHttpLayersDiagnosticsObeyTheVerboseGate() {
        let originalFlag = ServerLog.isVerbose
        let originalSink = ServerLog.verboseSink
        defer { ServerLog.isVerbose = originalFlag; ServerLog.verboseSink = originalSink }

        let captured = Capture()
        ServerLog.verboseSink = { captured.append($0) }
        let logging = ServerLogHTTPLogging()

        ServerLog.isVerbose = false
        logging.logDebug("http-test-debug-dropped")
        logging.logInfo("http-test-info-dropped")
        logging.logWarning("http-test-warning-dropped")
        // logError too: in FlyingFox that level is per-connection and per-request — a disconnect,
        // a 404 — so it is a diagnostic despite the name. Routing it to stderr put a line on the
        // console for every 404 and cost enough synchronous writes to fail timing tests on CI.
        logging.logError("http-test-error-dropped")
        #expect(!captured.lines.contains { $0.contains("http-test-debug-dropped") })
        #expect(!captured.lines.contains { $0.contains("http-test-info-dropped") })
        #expect(!captured.lines.contains { $0.contains("http-test-warning-dropped") })
        #expect(!captured.lines.contains { $0.contains("http-test-error-dropped") })

        ServerLog.isVerbose = true
        logging.logDebug("http-test-debug-kept")
        #expect(captured.lines.contains { $0.contains("http-test-debug-kept") })
    }

    /// NOTHING from the HTTP layer reaches stderr, `logCritical` included — it fires on every
    /// ordinary shutdown, and the startup failure a user must see comes from `main.swift`'s own
    /// `StartupFailure.describe`, not from this logger.
    @Test func theHttpLayerNeverWritesToStderr() {
        let originalFlag = ServerLog.isVerbose
        let originalSink = ServerLog.errorSink
        let originalVerbose = ServerLog.verboseSink
        defer {
            ServerLog.isVerbose = originalFlag
            ServerLog.errorSink = originalSink
            ServerLog.verboseSink = originalVerbose
        }

        let captured = Capture()
        ServerLog.errorSink = { captured.append($0) }
        // Swallowed rather than printed: with the gate up these lines are correctly diagnostics,
        // and letting them reach the real sink puts `[http]` noise in the suite's own output.
        ServerLog.verboseSink = { _ in }
        let logging = ServerLogHTTPLogging()

        // Both with the gate down and with it up: stderr is for OUR failures, not the library's.
        for verbose in [false, true] {
            ServerLog.isVerbose = verbose
            logging.logError("http-test-error-not-on-stderr-\(verbose)")
            logging.logCritical("http-test-critical-not-on-stderr-\(verbose)")
            #expect(!captured.lines.contains { $0.contains("not-on-stderr-\(verbose)") })
        }
    }
}
