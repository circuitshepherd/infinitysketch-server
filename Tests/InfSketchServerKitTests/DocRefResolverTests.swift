import Foundation
import Testing
@testable import InfSketchServerKit

@Suite struct DocRefResolverTests {
    private let docs = [
        DocRefCandidate(id: "AAA-1", name: "Chart", modifiedAt: Date(timeIntervalSince1970: 100)),
        DocRefCandidate(id: "BBB-2", name: "Chart", modifiedAt: Date(timeIntervalSince1970: 200)),
        DocRefCandidate(id: "CCC-3", name: "Plan", modifiedAt: Date(timeIntervalSince1970: 300)),
    ]

    @Test func anIdWins() { #expect(DocRefResolver.resolve("CCC-3", among: docs) == .id("CCC-3")) }
    @Test func anIdInAnotherCaseResolves() { #expect(DocRefResolver.resolve("ccc-3", among: docs) == .id("CCC-3")) }
    @Test func aUniqueNameResolves() { #expect(DocRefResolver.resolve("Plan", among: docs) == .id("CCC-3")) }
    @Test func aUniqueNameInAnotherCaseResolves() { #expect(DocRefResolver.resolve("plan", among: docs) == .id("CCC-3")) }
    @Test func aSharedNameIsAmbiguousNewestFirst() {
        #expect(DocRefResolver.resolve("Chart", among: docs) == .ambiguous([docs[1], docs[0]]))
    }
    @Test func anUnknownRefIsUnresolved() { #expect(DocRefResolver.resolve("Nope", among: docs) == .unresolved) }
    /// A document NAMED like another document's id is still found by the id first.
    @Test func anIdBeatsANameThatLooksLikeIt() {
        let tricky = docs + [DocRefCandidate(id: "DDD-4", name: "CCC-3", modifiedAt: .distantPast)]
        #expect(DocRefResolver.resolve("CCC-3", among: tricky) == .id("CCC-3"))
    }
}
