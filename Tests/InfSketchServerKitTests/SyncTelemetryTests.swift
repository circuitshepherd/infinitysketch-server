import Foundation
import Testing
@testable import InfSketchServerKit

/// Sync performance telemetry: the gate, the row, and the bounded file.
///
/// Serialized for the reason `ServerLogTests` is: the gate is process-global state, and other
/// suites' sessions write documents (and therefore rows) concurrently.
@Suite(.serialized) struct SyncTelemetryTests {

    /// The sink closures are `@Sendable`, so the capture must be too.
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }

        /// The rows for one document, parsed. Filtering by doc is what keeps another suite's
        /// writes — its sessions store documents too — out of the assertions.
        func rows(doc: String) -> [[String: Any]] {
            lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { $0["doc"] as? String == doc }
        }
    }

    /// Swap the gate and the sink, run, put both back.
    ///
    /// **Every test that touches these must live in THIS suite**, extensions included — `.serialized`
    /// orders one suite, so a second suite doing the same thing interleaves its `defer` into the
    /// middle of this one and silently turns the gate off mid-write. Measured: as two suites, one
    /// test of the six failed on two runs in three.
    func withCapture(enabled: Bool, _ body: (Capture) throws -> Void) rethrows {
        let originalFlag = SyncTelemetry.isEnabled
        let originalSink = SyncTelemetry.sink
        defer { SyncTelemetry.isEnabled = originalFlag; SyncTelemetry.sink = originalSink }
        let captured = Capture()
        SyncTelemetry.sink = { captured.append($0) }
        SyncTelemetry.isEnabled = enabled
        try body(captured)
    }

    /// The same, for the tests that drive a real `DocumentSession`.
    func withCapture(enabled: Bool, _ body: (Capture) async throws -> Void) async rethrows {
        let originalFlag = SyncTelemetry.isEnabled
        let originalSink = SyncTelemetry.sink
        defer { SyncTelemetry.isEnabled = originalFlag; SyncTelemetry.sink = originalSink }
        let captured = Capture()
        SyncTelemetry.sink = { captured.append($0) }
        SyncTelemetry.isEnabled = enabled
        try await body(captured)
    }

    private func sampleRow(doc: String) -> SyncTelemetry.WriteRow {
        SyncTelemetry.WriteRow(
            docId: doc, opId: "OP-1", payloadKind: "strippedDoc",
            payloadBytes: 400_123, documentBytes: 6_746_001,
            waitMs: 312.4, rebuildMs: 34.2, casMs: 2.9, saveMs: 3.4, stripMs: 29.1,
            totalMs: 72.8, outcome: "accepted", subscribers: 2, broadcastBytes: 400_139)
    }

    // MARK: - the gate

    /// Off by default is the whole point of a flag: a server nobody asked for telemetry from must
    /// write nothing at all.
    @Test func disabledWritesNothing() {
        withCapture(enabled: false) { captured in
            SyncTelemetry.record(sampleRow(doc: "telemetry-test-dropped"))
            #expect(!captured.lines.contains { $0.contains("telemetry-test-dropped") })
        }
    }

    @Test func enabledWritesOneLinePerRow() {
        withCapture(enabled: true) { captured in
            SyncTelemetry.record(sampleRow(doc: "telemetry-test-kept"))
            let mine = captured.lines.filter { $0.contains("telemetry-test-kept") }
            #expect(mine.count == 1)
            #expect(!(mine.first?.contains("\n") ?? true), "one row is one line, or the file is not JSON Lines")
        }
    }

    // MARK: - the row

    /// It is JSON Lines so a script can read it, not just a person. Every field the design names
    /// must survive a round trip through the encoder.
    @Test func aRowIsParseableJSONCarryingEveryField() throws {
        try withCapture(enabled: true) { captured in
            SyncTelemetry.record(sampleRow(doc: "telemetry-test-json"))
            let line = try #require(captured.lines.first { $0.contains("telemetry-test-json") })
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

            #expect(object["doc"] as? String == "telemetry-test-json")
            #expect(object["op"] as? String == "OP-1")
            #expect(object["kind"] as? String == "strippedDoc")
            #expect(object["inB"] as? Int == 400_123)
            #expect(object["docB"] as? Int == 6_746_001)
            #expect(object["waitMs"] as? Double == 312.4)
            #expect(object["rebuildMs"] as? Double == 34.2)
            #expect(object["casMs"] as? Double == 2.9)
            #expect(object["saveMs"] as? Double == 3.4)
            #expect(object["stripMs"] as? Double == 29.1)
            #expect(object["totalMs"] as? Double == 72.8)
            #expect(object["outcome"] as? String == "accepted")
            #expect(object["subs"] as? Int == 2)
            #expect(object["outB"] as? Int == 400_139)
            #expect((object["t"] as? String)?.isEmpty == false, "a row must say when it happened")
        }
    }

    /// The wait is the number this exists for, and "not measured" is a real state — an agent write
    /// that opens its own session has no socket receipt to measure from. Absent, not zero: a zero
    /// would read as "it was served instantly", which is a different claim.
    @Test func anUnmeasuredWaitIsAbsentRatherThanZero() throws {
        try withCapture(enabled: true) { captured in
            var row = sampleRow(doc: "telemetry-test-nowait")
            row.waitMs = nil
            SyncTelemetry.record(row)
            let line = try #require(captured.lines.first { $0.contains("telemetry-test-nowait") })
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object["waitMs"] == nil)
            #expect(object["totalMs"] as? Double == 72.8, "the rest of the row is unaffected")
        }
    }

    /// A rejected write is exactly as interesting as an accepted one — a CAS refusal under load is
    /// what a contention problem looks like from here.
    @Test func aRejectionRecordsItsReason() throws {
        try withCapture(enabled: true) { captured in
            var row = sampleRow(doc: "telemetry-test-reject")
            row.outcome = "docChangedDuringOp"
            row.saveMs = nil
            SyncTelemetry.record(row)
            let line = try #require(captured.lines.first { $0.contains("telemetry-test-reject") })
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object["outcome"] as? String == "docChangedDuringOp")
            #expect(object["saveMs"] == nil, "nothing was saved, so there is no save to time")
        }
    }

    // MARK: - the bounded file

    /// A dev server runs for days. Without a ceiling this is a disk leak that nobody notices until
    /// it matters; with one, the recent past survives and the total is predictable.
    @Test func theFileRotatesAtItsCapAndKeepsTheRecentPast() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("telemetry.jsonl")

        let writer = try #require(TelemetryFileWriter(url: url, capBytes: 300))
        for i in 0..<40 { writer.write(#"{"n":\#(i),"pad":"xxxxxxxxxxxxxxxxxxxx"}"#) }
        writer.flush()

        let rotated = url.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: rotated.path), "the cap must rotate, not truncate")

        let live = try String(contentsOf: url, encoding: .utf8)
        #expect(live.contains("\"n\":39"), "the NEWEST row must be in the live file")
        for file in [url, rotated] {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            #expect(size <= 400, "neither file may grow past the cap (\(file.lastPathComponent): \(size) B)")
        }
    }

    /// A path that cannot be opened is a misconfiguration the operator must see — and it must not
    /// take the server down with it.
    @Test func anUnusablePathIsRefusedRatherThanCrashing() {
        #expect(TelemetryFileWriter(url: URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/t.jsonl"),
                                    capBytes: 1024) == nil)
    }
}
