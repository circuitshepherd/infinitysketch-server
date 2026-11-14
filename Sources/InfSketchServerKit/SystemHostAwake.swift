import Foundation
#if canImport(WinSDK)
import WinSDK
#endif

/// Keeps THIS machine from its idle standby while it is held (`AgentWork`), through the
/// platform's own request for it — the one a media player makes. It stops the IDLE timer only:
/// a closed lid, the power button and "Sleep" from the menu still put the machine to sleep, and
/// the display may still turn off.
///
/// - macOS: `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`; shown by
///   `pmset -g assertions` as PreventUserIdleSystemSleep under this process.
/// - Windows: a power request (`PowerCreateRequest` / `PowerSetRequest`), system-required and
///   execution-required (the second is what a Modern Standby machine honours); shown by
///   `powercfg /requests`. Handle-based on purpose: `SetThreadExecutionState` belongs to the
///   calling THREAD, and this is called from whichever thread the concurrency pool runs it on.
/// - Linux: nothing is held (`isSupported` is false). A headless Linux host rarely has an idle
///   standby; `docs/BACKLOG.md`.
///
/// Only `main.swift` creates one. The library's default is `NoHostAwake`, so a test that calls a
/// tool does not change the power state of the machine running the suite.
public final class SystemHostAwake: HostAwake, @unchecked Sendable {
    public static let reason = "infsketch-server: an agent is working on a drawing"

    private let lock = NSLock()
    #if canImport(Darwin)
    private var activity: (any NSObjectProtocol)?
    #elseif canImport(WinSDK)
    private var request: HANDLE?
    private var isSet = false
    /// The request's reason, as the system shows it. Kept for the life of the process: the
    /// request refers to it.
    nonisolated(unsafe) private static let reasonText: UnsafeMutablePointer<WCHAR> = {
        let units = Array(reason.utf16) + [0]
        let buffer = UnsafeMutablePointer<WCHAR>.allocate(capacity: units.count)
        buffer.initialize(from: units, count: units.count)
        return buffer
    }()
    #endif

    public init() {}

    public static var isSupported: Bool {
        #if canImport(Darwin) || canImport(WinSDK)
        return true
        #else
        return false
        #endif
    }

    public func hold() {
        lock.lock(); defer { lock.unlock() }
        #if canImport(Darwin)
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled, reason: Self.reason)
        ServerLog.timed("[power] this machine's idle standby is held off")
        #elseif canImport(WinSDK)
        guard !isSet else { return }
        if request == nil {
            var context = REASON_CONTEXT()
            context.Version = 0            // POWER_REQUEST_CONTEXT_VERSION
            context.Flags = 0x1            // POWER_REQUEST_CONTEXT_SIMPLE_STRING
            context.Reason.SimpleReasonString = Self.reasonText
            guard let handle = PowerCreateRequest(&context), handle != INVALID_HANDLE_VALUE else {
                ServerLog.timed("[power] could not create a power request (error \(GetLastError())); this machine may go to standby while an agent works")
                return
            }
            request = handle
        }
        _ = PowerSetRequest(request, PowerRequestSystemRequired)
        _ = PowerSetRequest(request, PowerRequestExecutionRequired)
        isSet = true
        ServerLog.timed("[power] this machine's idle standby is held off")
        #endif
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        #if canImport(Darwin)
        guard let held = activity else { return }
        ProcessInfo.processInfo.endActivity(held)
        activity = nil
        ServerLog.timed("[power] released")
        #elseif canImport(WinSDK)
        guard isSet else { return }
        _ = PowerClearRequest(request, PowerRequestSystemRequired)
        _ = PowerClearRequest(request, PowerRequestExecutionRequired)
        isSet = false
        ServerLog.timed("[power] released")
        #endif
    }
}
