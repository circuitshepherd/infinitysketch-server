import Foundation

/// Turns the error that killed startup into something a person can act on.
///
/// WHY THIS EXISTS: failing to bind is overwhelmingly the common way this server fails to start —
/// port 8080 is contended, and one server per worktree is the normal shape of development here —
/// and the error that arrives names the cause only as a number. On Windows FlyingSocks renders it
///
///     failed(type: "Bind", errno: 10048, message: "Unknown error")
///
/// where 10048 is `WSAEADDRINUSE`: the single fact the user needs is the one word missing, because
/// the socket layer maps errno text for POSIX and Windows uses a disjoint numbering. Measured
/// 2026-08-10 by double-clicking the packaged executable with the port already taken — the case a
/// first-time Windows user is most likely to hit.
///
/// Classification is on the ERRNO, not the message text, deliberately: the number is what the
/// platform reports reliably and the text is the part it got wrong. Pure `String` in, `String` out,
/// so it is testable without opening a socket.
public enum StartupFailure {
    /// Address-in-use, per platform. Windows numbers its socket errors in a separate range and does
    /// NOT reuse the POSIX value, so all three have to be listed; a missing one degrades to the raw
    /// error rather than to a wrong message.
    static let addressInUseErrnos: Set<Int> = [
        10048,  // WSAEADDRINUSE — Windows
        48,     // EADDRINUSE    — Darwin
        98,     // EADDRINUSE    — Linux
    ]

    /// The `errno: N` field FlyingSocks puts in its description, or nil when there is not one.
    ///
    /// Anchored on the `errno: ` label rather than scanning for any number in the string: a port,
    /// a byte count or a path can all contain digits, and matching one of those would produce a
    /// confidently wrong diagnosis instead of an honest fallback.
    static func errnoValue(in description: String) -> Int? {
        guard let label = description.range(of: "errno: ") else { return nil }
        let digits = description[label.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// A message to print when the server could not start. Falls back to the raw error, which is
    /// still better than nothing, for anything not recognised.
    public static func describe(_ errorDescription: String, port: UInt16) -> String {
        guard let code = errnoValue(in: errorDescription),
              addressInUseErrnos.contains(code)
        else {
            return "infsketch-server stopped: \(errorDescription)"
        }

        let suggestion = port < UInt16.max ? port + 1 : 8080
        return """
            infsketch-server stopped: port \(port) is already in use.

            Something else is listening there — often another copy of this server. Either stop that
            one, or start this with a different port:

                infsketch-server --port \(suggestion)
            """
    }
}
