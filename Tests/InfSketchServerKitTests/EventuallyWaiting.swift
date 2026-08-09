import Foundation

/// Waits for a state change that something else schedules on a TIMER, instead
/// of sleeping for a fixed multiple of that timer and asserting once.
///
/// THE BUG THIS EXISTS TO KILL, measured 2026-08-09: several tests observed
/// `SessionManager`'s grace-period teardown by sleeping 150–300 ms against a
/// 50 ms grace and then asserting the session was gone. That assertion is a
/// race against the MACHINE, not against the code — it held on a fast Mac and
/// lost on GitLab's 2-vCPU shared runner, which is where the `linux-test`
/// pipeline failures came from. Reproduced by running the suite under
/// `--platform linux/amd64 --cpus 2`: 9 of 10 runs failed, the worst offender
/// 9 times out of 10, while the same commit passed every time at full speed.
///
/// Polling asserts the same thing without pinning it to a machine speed: it
/// returns the instant the condition holds (so a fast machine pays ~nothing)
/// and waits patiently when the machine is starved. It deliberately does NOT
/// assert or record an issue — it returns, and the caller's own `#expect`
/// then fails at the caller's source location with the caller's own message,
/// exactly as it did before.
///
/// The budget is generous ON PURPOSE. It is not a deadline the code is
/// expected to approach — it is the point past which we would rather see a
/// clear test failure than hang the suite. Anything relying on the budget
/// being *tight* wants a different tool.
///
/// The mirror-image race — a test needing a session to SURVIVE its own work —
/// cannot be fixed by waiting, and is not fixed here: those tests were given
/// a grace period long enough that a scheduling stall cannot eat it. See
/// `MCPWritePathTests.makeStoreAndManager`.
func waitFor(
    timeout: Duration = .seconds(10),
    pollEvery: Duration = .milliseconds(10),
    _ condition: () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: pollEvery)
    }
}
