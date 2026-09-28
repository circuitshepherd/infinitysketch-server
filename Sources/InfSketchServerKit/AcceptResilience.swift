import Foundation
import FlyingSocks
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Running out of file descriptors must not end the server.
///
/// FlyingFox's accept loop rethrows any `accept` failure, and `run()` then returns with it — so
/// under the macOS default soft limit of 256 open files, idle connections exhausted the
/// descriptors, `accept` failed with EMFILE and the process exited. Measured with a soft limit of
/// 256 and idle connections: `accept` failed at the 251st connection — the limit minus the
/// descriptors the server holds itself. Two defences, both here: raise the soft
/// descriptor limit at startup, and treat a shortage errno (`isTransient`) as transient — wait
/// briefly and listen again rather than stop.
///
/// **A known leak on Linux, documented rather than patched.** FlyingFox's `ePoll` queue creates
/// an eventfd "canary" in `open()` and `stop()` only writes to it and forgets it — `close()`
/// closes the epoll descriptor, never the canary (FlyingFox 0.27.0, `SocketPool+ePoll.swift`).
/// So every listen-again on Linux leaks ONE descriptor. The canary is not reachable from outside
/// FlyingSocks, and a listen-again drops every connection the failed loop held, which frees far
/// more than it leaks; kqueue (Darwin) closes its queue in `stop()` and leaks nothing. The fix
/// belongs upstream: close the canary in `ePoll.close()`.
public enum AcceptResilience {

    /// Raises the soft `RLIMIT_NOFILE` towards the hard limit. Returns the (old, new) soft limits,
    /// or nil where there is no such limit (Windows) or it could not be read.
    ///
    /// macOS refuses a soft limit above `OPEN_MAX` (10240) even when the hard limit says
    /// "unlimited", so that is tried as the fallback.
    @discardableResult
    public static func raiseFileDescriptorLimit(target: UInt64 = 65_536) -> (old: UInt64, new: UInt64)? {
        #if canImport(Glibc) || canImport(Darwin)
        #if canImport(Darwin)
        let resource = RLIMIT_NOFILE
        #else
        let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        #endif
        var limit = rlimit()
        guard getrlimit(resource, &limit) == 0 else { return nil }
        let old = UInt64(limit.rlim_cur)
        for candidate in [min(target, UInt64(limit.rlim_max)), min(10_240, UInt64(limit.rlim_max))]
        where candidate > UInt64(limit.rlim_cur) {
            var raised = limit
            raised.rlim_cur = rlim_t(candidate)
            if setrlimit(resource, &raised) == 0 { return (old, candidate) }
        }
        return (old, old)
        #else
        return nil
        #endif
    }

    /// Whether a failure out of the HTTP server's run loop is worth listening again after: an
    /// errno that says the MACHINE is short of something right now — descriptors (EMFILE/ENFILE),
    /// buffer space or memory (ENOBUFS/ENOMEM) — or that one connection went away before it was
    /// accepted (ECONNABORTED), whatever call reported it (`Accept`, or re-creating the socket or
    /// the poller). Nothing else: a bind failure (port in use) is a startup error the caller
    /// reports, and an `Accept` failure with any other errno — EBADF from a closed listening
    /// socket, EINVAL, a programming error — would be retried forever by a rule that trusted the
    /// call's NAME rather than its cause (round 5, item 4).
    static func isTransient(_ error: any Error) -> Bool {
        guard case let SocketError.failed(_, errno, _) = error else { return false }
        return transientErrnos.contains(errno)
    }

    /// Per platform, because the numbers are not portable: ENOBUFS is 55 on Darwin and 105 on
    /// Linux, ECONNABORTED 53 and 103. EMFILE (24), ENFILE (23) and ENOMEM (12) agree. Winsock's
    /// WSAEMFILE (10024), WSAENOBUFS (10055) and WSAECONNABORTED (10053) are listed everywhere:
    /// no POSIX errno reaches 10 000, so they cannot be misread.
    static var transientErrnos: Set<Int32> {
        var set: Set<Int32> = [24, 23, 12, 10024, 10055, 10053]
        #if canImport(Darwin)
        set.formUnion([55, 53])
        #elseif canImport(Glibc)
        set.formUnion([105, 103])
        #endif
        return set
    }

    /// Runs `operation` until it returns, or throws something that is not transient, or `shouldStop`
    /// says the caller asked for it to end. Between attempts it waits `delays[i]` (the last entry
    /// repeats), logging each restart through `ServerLog.error` — this is a genuine failure an
    /// operator must see.
    static func run(
        delays: [Duration],
        shouldStop: @Sendable () async -> Bool,
        _ operation: () async throws -> Void
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await operation()
                return
            } catch {
                guard isTransient(error), !(await shouldStop()), !Task.isCancelled else { throw error }
                let delay = delays.isEmpty ? .zero : delays[min(attempt, delays.count - 1)]
                ServerLog.error("[server] listening failed (\(error)); listening again in \(delay)")
                attempt += 1
                try await Task.sleep(for: delay)
            }
        }
    }
}
