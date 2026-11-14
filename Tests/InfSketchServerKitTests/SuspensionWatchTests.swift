import Foundation
import Testing
@testable import InfSketchServerKit

/// The server notices that it did not run for a while — the host's standby — from the gap
/// between two ticks of its own, and says so in the log.
struct SuspensionWatchTests {
    @Test func ordinaryTicksReportNothing() {
        let t0 = ContinuousClock.now
        var watch = SuspensionWatch(interval: .seconds(5), now: t0)
        #expect(watch.tick(now: t0.advanced(by: .seconds(5))) == nil)
        #expect(watch.tick(now: t0.advanced(by: .seconds(11))) == nil, "a late tick is not a standby")
    }

    @Test func aGapFarBeyondTheIntervalIsReportedWithItsLength() {
        let t0 = ContinuousClock.now
        var watch = SuspensionWatch(interval: .seconds(5), now: t0)
        _ = watch.tick(now: t0.advanced(by: .seconds(5)))
        #expect(watch.tick(now: t0.advanced(by: .seconds(305))) == .seconds(300))
        #expect(watch.tick(now: t0.advanced(by: .seconds(310))) == nil, "reported once")
    }
}
