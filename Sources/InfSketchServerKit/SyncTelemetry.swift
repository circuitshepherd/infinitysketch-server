import Foundation
import Dispatch

/// Sync performance telemetry: one row per write, to a file, only when asked for.
///
/// **What it is for.** A document carrying a large image made every write expensive in CPU rather
/// than in bandwidth, and the only way that was found was by writing measurement tests that time
/// each step in isolation. Those cannot see the two things that actually turn a slow write into
/// felt lag: how long a write WAITED for its document's session actor, and how often writes arrive.
/// Both are properties of a running server under real contention — two devices and an agent — and
/// this is where they become visible.
///
/// **Shaped like `ServerLog`, deliberately:** a gate plus an injectable sink, so the rows are
/// testable without touching the filesystem, and so the console is never involved. It is NOT
/// `ServerLog` because the destinations differ in kind — diagnostics go to a terminal a person is
/// reading, and these go to a file a script will parse.
///
/// **JSON Lines**, because both are wanted: `grep` for a document's name, and a parser for the
/// distribution. One row is one line.
///
/// **Nothing here may run on the session actor.** The whole point is to not perturb what it
/// measures, so the file sink hands the line to its own serial queue and returns. Formatting is
/// cheap enough to do at the call site; a `write` syscall on the actor every document write is not.
public enum SyncTelemetry {

    /// Written ONCE at startup by the executable's argument parse, before any concurrency starts;
    /// the library never reads `CommandLine` itself. (`nonisolated(unsafe)` rests on that
    /// write-once discipline — and on `SyncTelemetryTests` being `.serialized`, the same terms
    /// `ServerLog` states.)
    nonisolated(unsafe) public static var isEnabled = false

    /// Injectable so a test can assert the rows themselves. The default discards: a sink is
    /// installed by `enableFileLogging` when the flag names a path.
    nonisolated(unsafe) public static var sink: @Sendable (String) -> Void = { _ in }

    /// One write, as it happened. Every duration is milliseconds; a nil one means NOT MEASURED,
    /// which is a different claim from zero — an agent write that opens its own session has no
    /// socket receipt to measure a wait from, and a rejected write never reaches the store.
    public struct WriteRow: Sendable {
        public var docId: String
        public var opId: String
        public var payloadKind: String
        public var payloadBytes: Int
        public var documentBytes: Int
        /// Time between the write arriving at the server and its document's session actor starting
        /// it — the QUEUE. The number this whole file exists for.
        public var waitMs: Double?
        public var rebuildMs: Double?
        public var casMs: Double?
        public var saveMs: Double?
        public var stripMs: Double?
        public var totalMs: Double
        /// `accepted`, or the rejection reason the submitter was given.
        public var outcome: String
        public var subscribers: Int
        public var broadcastBytes: Int?

        public init(docId: String, opId: String, payloadKind: String, payloadBytes: Int,
                    documentBytes: Int, waitMs: Double? = nil, rebuildMs: Double? = nil,
                    casMs: Double? = nil, saveMs: Double? = nil, stripMs: Double? = nil,
                    totalMs: Double, outcome: String, subscribers: Int,
                    broadcastBytes: Int? = nil) {
            self.docId = docId
            self.opId = opId
            self.payloadKind = payloadKind
            self.payloadBytes = payloadBytes
            self.documentBytes = documentBytes
            self.waitMs = waitMs
            self.rebuildMs = rebuildMs
            self.casMs = casMs
            self.saveMs = saveMs
            self.stripMs = stripMs
            self.totalMs = totalMs
            self.outcome = outcome
            self.subscribers = subscribers
            self.broadcastBytes = broadcastBytes
        }
    }

    public static func record(_ row: WriteRow) {
        guard isEnabled else { return }
        sink(row.jsonLine())
    }

    /// Point the telemetry at a file. Returns false when the path cannot be opened, which the
    /// caller reports — a misconfigured path must be visible, and must not take the server down.
    @discardableResult
    public static func enableFileLogging(at url: URL, capBytes: Int = defaultCapBytes) -> Bool {
        guard let writer = TelemetryFileWriter(url: url, capBytes: capBytes) else { return false }
        sink = { writer.write($0) }
        isEnabled = true
        return true
    }

    /// 64 MB, then one rotation — about 300 000 rows live plus as many again in `.1`. Big enough
    /// that a day of drawing does not lose the morning, bounded enough that a dev server left
    /// running for a week is not a disk leak nobody notices.
    public static let defaultCapBytes = 64 * 1024 * 1024
}

extension SyncTelemetry.WriteRow {

    /// Hand-built rather than `JSONEncoder`-built, for two reasons: a nil duration must be ABSENT
    /// rather than `null` (absent reads as "not measured"; `null` invites a reader to treat it as
    /// zero), and this runs once per document write, where an encoder per row is a needless
    /// allocation on a path whose cost is the thing being measured.
    func jsonLine(now: Date = Date()) -> String {
        var fields: [String] = [
            "\"t\":\(quoted(SyncTelemetryTime.iso8601(now)))",
            "\"doc\":\(quoted(docId))",
            "\"op\":\(quoted(opId))",
            "\"kind\":\(quoted(payloadKind))",
            "\"inB\":\(payloadBytes)",
            "\"docB\":\(documentBytes)",
        ]
        appendMillis(&fields, "waitMs", waitMs)
        appendMillis(&fields, "rebuildMs", rebuildMs)
        appendMillis(&fields, "casMs", casMs)
        appendMillis(&fields, "saveMs", saveMs)
        appendMillis(&fields, "stripMs", stripMs)
        appendMillis(&fields, "totalMs", totalMs)
        fields.append("\"outcome\":\(quoted(outcome))")
        fields.append("\"subs\":\(subscribers)")
        if let broadcastBytes { fields.append("\"outB\":\(broadcastBytes)") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func appendMillis(_ fields: inout [String], _ key: String, _ value: Double?) {
        guard let value, value.isFinite else { return }
        fields.append("\"\(key)\":\(String(format: "%.1f", value))")
    }

    /// A docId is a filename stem and an opId is a UUID, so neither can contain a control
    /// character — but they arrive over a socket, and one row per line only holds if a quote or a
    /// newline in either cannot break out of the string.
    private func quoted(_ value: String) -> String {
        var out = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}

/// Wall-clock stamps for the rows. Durations are NOT measured with this — they use
/// `ContinuousClock`, which cannot run backwards when the wall clock is adjusted — but a row still
/// has to say when it happened, so it can be lined up against an app log or a person's memory.
enum SyncTelemetryTime {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func iso8601(_ date: Date) -> String { formatter.string(from: date) }
}

/// The file behind the sink: appends lines on its own serial queue, and keeps the file bounded.
///
/// `nonisolated`/`Sendable` because the sink closure is `@Sendable` and every call lands on the
/// queue; nothing here is touched from two places at once.
final class TelemetryFileWriter: @unchecked Sendable {
    private let url: URL
    private let capBytes: Int
    private let queue = DispatchQueue(label: "com.circuitshepherd.infsketch.telemetry")
    private var handle: FileHandle
    private var written: Int

    /// Returns nil when the path cannot be opened — a directory that does not exist, or one that
    /// cannot be written to. The caller reports it; the server carries on without telemetry, which
    /// is the state it would have been in anyway.
    init?(url: URL, capBytes: Int) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.capBytes = capBytes
        self.handle = handle
        self.written = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) ?? 0
        _ = try? handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func write(_ line: String) {
        let bytes = Data((line + "\n").utf8)
        queue.async { [self] in
            if written + bytes.count > capBytes { rotate() }
            try? handle.write(contentsOf: bytes)
            written += bytes.count
        }
    }

    /// Rotate rather than truncate: what a person wants when they come to read this is the RECENT
    /// past, and truncation throws away the newest rows along with the oldest. One generation, so
    /// the total on disk is bounded at twice the cap and there is nothing to prune.
    private func rotate() {
        let manager = FileManager.default
        let rotated = url.appendingPathExtension("1")
        try? handle.close()
        try? manager.removeItem(at: rotated)
        try? manager.moveItem(at: url, to: rotated)
        guard manager.createFile(atPath: url.path, contents: nil),
              let fresh = try? FileHandle(forWritingTo: url) else {
            // The directory went away underneath us. Keep the old handle closed and stop writing
            // rather than throwing on every row for the rest of the process's life.
            written = Int.max
            return
        }
        handle = fresh
        written = 0
    }

    /// Return once every row handed over so far has reached the file.
    ///
    /// NOT a test-only seam, though a test asserting on the file is what needs it most: the queue is
    /// asynchronous by design, so "I wrote a row" and "the row is in the file" are different facts,
    /// and anything that reads the file — a person, a script, a shutdown — wants the second one.
    /// (It was `#if DEBUG` for one commit, which compiled fine and then failed `swift test -c
    /// release`, since the test target builds in release too.)
    func flush() { queue.sync { } }
}
