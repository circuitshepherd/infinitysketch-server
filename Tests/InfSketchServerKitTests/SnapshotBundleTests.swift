import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct SnapshotBundleTests {
    private func digest(_ d: Data) -> Data { VersionHash.digest(hex: VersionDigest.hex(of: d))! }

    @Test func aBundleSurvivesItsEncoding() throws {
        let bundle = SnapshotBundle(snapshot: Data("snap".utf8), baseHash: String(repeating: "a", count: 64),
                                    base: Data("base".utf8), baseIsStripped: false)
        #expect(try SnapshotBundle(encoded: bundle.encoded()) == bundle)
    }

    @Test func aTruncatedBundleIsRejected() {
        let encoded = SnapshotBundle(snapshot: Data("s".utf8), baseHash: String(repeating: "a", count: 64),
                                     base: Data("b".utf8), baseIsStripped: false).encoded()
        #expect(throws: (any Error).self) { try SnapshotBundle(encoded: encoded.dropLast(3)) }
    }

    /// An image both versions share crosses the wire once.
    @Test func aSharedImageTravelsOnce() throws {
        let image = (UUID(), VersionFixtures.image(seed: 50, count: 40_000))
        let snapshot = VersionFixtures.document(marker: "now", images: [image])
        let base = VersionFixtures.document(marker: "then", images: [image])
        let bundle = SnapshotBundle.make(snapshot: snapshot, base: base, baseHash: VersionDigest.hex(of: base),
                                         snapshotDigest: digest(snapshot), baseDigest: digest(base))
        #expect(bundle.baseIsStripped)
        #expect(bundle.encoded().count < snapshot.count + base.count / 4)
        #expect(try bundle.resolvedBase() == base)
    }

    /// Review focus 1: the base has an image the snapshot no longer has — it travels inline and the
    /// base still rebuilds exactly against the snapshot.
    @Test func aBaseWithAnImageTheSnapshotLacksRebuilds() throws {
        let kept = (UUID(), VersionFixtures.image(seed: 51))
        let dropped = (UUID(), VersionFixtures.image(seed: 52))
        let snapshot = VersionFixtures.document(marker: "now", images: [kept])
        let base = VersionFixtures.document(marker: "then", images: [kept, dropped])
        let bundle = SnapshotBundle.make(snapshot: snapshot, base: base, baseHash: VersionDigest.hex(of: base),
                                         snapshotDigest: digest(snapshot), baseDigest: digest(base))
        #expect(try bundle.resolvedBase() == base)
    }
}
