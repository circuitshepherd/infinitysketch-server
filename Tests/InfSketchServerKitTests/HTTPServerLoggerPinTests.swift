import Foundation
import Testing
@testable import InfSketchServerKit

/// Pins the one thing about the HTTP logger that no behaviour test can observe: that we PASS one.
///
/// `HTTPServer`'s `logger` is private, so a call that drops the argument compiles, runs, passes
/// every test in this suite and every gate in `scripts/e2e-all` — and prints FlyingFox's
/// diagnostics to the console on Windows and Linux, where the join block is being drawn. The
/// failure is invisible on macOS specifically, because there the default logger writes to OSLog
/// instead of stdout, so the machine everyone develops on is the one machine that cannot show it.
/// That is how it reached a public release.
///
/// A source check is the honest instrument here: the defect is a missing argument at a call site,
/// which is a fact about the source and not about any value the process can be asked for.
@Suite struct HTTPServerLoggerPinTests {

    /// `Sources/`, derived from this file rather than a working directory, so it does not depend on
    /// where the suite was launched from.
    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/InfSketchServerKitTests/<this>.swift
            .deletingLastPathComponent()          // …/Tests/InfSketchServerKitTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/  (package root)
            .appendingPathComponent("Sources")
    }

    @Test func everyHttpServerConstructionPassesAnExplicitLogger() throws {
        let root = Self.sourcesDirectory
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))

        var offenders: [String] = []
        var constructions = 0

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments are prose about the call, not the call.
                guard !trimmed.hasPrefix("//"), line.contains("HTTPServer(") else { continue }
                constructions += 1
                // The argument list may wrap; look at the call and the lines it can span.
                let window = lines[index..<min(index + 4, lines.count)].joined()
                // Present is not enough: `.print` IS a logger, and passing it explicitly would
                // reproduce the exact defect this pins. The value has to be ours, so the lines go
                // through `ServerLog` and obey `--verbose`.
                let routesThroughServerLog = window.contains("ServerLogHTTPLogging")
                if !window.contains("logger:") || !routesThroughServerLog {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }

        // Guards the guard: if the call is ever renamed or moved, finding nothing must not read as
        // success. This is the same trap as a pixel test on a blank image.
        #expect(constructions > 0, "found no HTTPServer construction to check — has it moved?")
        #expect(offenders.isEmpty, """
            HTTPServer built without an explicit logger at: \(offenders.joined(separator: ", ")).
            FlyingFox's default logger prints to stdout on Windows and Linux, which tears apart the \
            join block drawn there. Pass ServerLogHTTPLogging().
            """)
    }
}
