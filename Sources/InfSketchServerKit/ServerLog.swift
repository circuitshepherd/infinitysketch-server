import Foundation

/// The one gate for the server's operational log lines.
///
/// Two levels are the whole design (spec 2026-08-14-server-log-verbosity): `verbose` is
/// diagnostics — OFF by default, on with the executable's `--verbose` flag, which
/// `scripts/worktree-server` always passes because the dev server's log is what the e2e gates
/// grep — and `error` is genuine failure, always visible. On an interactive terminal a diagnostic
/// line lands between two `drawJoinCode` redraws and tears the join block apart, which is why the
/// default is silence.
///
/// The console UI (join block, startup banner, lifecycle messages) does not go through here; it is
/// not log text.
///
/// The flush lives HERE and nowhere else: `print` is block-buffered whenever stdout is not a
/// terminal — exactly how the dev server runs — and an unflushed line's absence reads as "the code
/// never ran", a trap this repository has recorded more than once.
public enum ServerLog {
    /// Written ONCE at startup by the executable's argument parse, before any concurrency starts;
    /// the library never reads `CommandLine` itself. (`nonisolated(unsafe)` rests on that
    /// write-once discipline — and on `ServerLogTests` being `.serialized`.)
    nonisolated(unsafe) public static var isVerbose = false

    /// Injectable so the gating is testable without capturing process stdout. Defaults are the
    /// real writes.
    nonisolated(unsafe) public static var verboseSink: @Sendable (String) -> Void = { line in
        print(line)
        fflush(nil)
    }
    nonisolated(unsafe) public static var errorSink: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// A diagnostic: dropped entirely unless `--verbose`.
    public static func verbose(_ line: String) {
        guard isVerbose else { return }
        verboseSink(line)
    }

    /// A genuine failure: always visible, stderr.
    public static func error(_ line: String) {
        errorSink(line)
    }
}
