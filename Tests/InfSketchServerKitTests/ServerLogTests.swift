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

        ServerLog.isVerbose = false
        ServerLog.verbose("dropped")
        #expect(captured.lines.isEmpty)

        ServerLog.isVerbose = true
        ServerLog.verbose("kept")
        #expect(captured.lines == ["kept"])
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
        ServerLog.error("still here")
        #expect(captured.lines == ["still here"])
    }
}
