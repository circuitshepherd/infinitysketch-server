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
/// under the macOS default of 256 open files, ~250 idle connections made `accept` fail with EMFILE
/// and the process exited (measured). Two defences, both here: raise the soft descriptor limit at
/// startup, and treat a descriptor-exhaustion or `accept` failure as transient — wait briefly and
/// listen again rather than stop.
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

    /// Whether a failure out of the HTTP server's run loop is worth listening again after: any
    /// `accept` failure (EMFILE/ENFILE, ECONNABORTED, …) and any descriptor exhaustion while
    /// re-creating the socket or poller. A bind failure (port in use) is NOT — that is a startup
    /// error the caller reports.
    static func isTransient(_ error: any Error) -> Bool {
        guard case let SocketError.failed(type, errno, _) = error else { return false }
        return type == "Accept" || exhaustionErrnos.contains(errno)
    }

    /// EMFILE / ENFILE, plus Winsock's WSAEMFILE (10024).
    private static let exhaustionErrnos: Set<Int32> = [24, 23, 10024]

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
