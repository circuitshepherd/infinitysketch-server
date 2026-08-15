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
}
