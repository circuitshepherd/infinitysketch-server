import Foundation
import Testing
import Crypto
@testable import InfSketchServerKit
import InfSketchWire

/// `WriteExpectation.matchHash` — the digest form of the byte CAS, added so the APP's ordinary
/// settle-push can carry a token at all: `.matchBytes` would ship a second copy of the document
/// on every push (spec 2026-07-27-app-push-write-expectation-design.md).
///
/// These mirror `SessionManagerTests`' `.matchBytes` pair deliberately: the two forms must agree
/// on accept, on reject, on the reason string, and on leaving nothing written behind.
struct WriteExpectationHashTests {

    private func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private func makeStoreAndManager(seed: Data) throws -> (DirectoryDocumentStore, SessionManager) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-cas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "D", bytes: seed)
        return (store, SessionManager(store: store, config: SessionConfig(gracePeriod: .seconds(60))))
    }

    @Test func aDigestOfTheCurrentContentIsAccepted() async throws {
        let original = Data("v1".utf8)
        let (_, manager) = try makeStoreAndManager(seed: original)
        _ = try await manager.subscribe(docId: "D")

        let outcome = await manager.submit(docId: "D", opId: "op1",
                                           payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)),
                                           expectation: .matchHash(sha256(original)))

        guard case .accepted = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(await manager.currentBytes(docId: "D") == Data("v2".utf8))
    }

    @Test func aStaleDigestIsRejectedAndNothingIsWritten() async throws {
        let stale = Data("v1".utf8)
        let (store, manager) = try makeStoreAndManager(seed: stale)
        _ = try await manager.subscribe(docId: "D")
        // Someone else lands first, moving the document past what our digest describes.
        _ = await manager.submit(docId: "D", opId: "other",
                                 payload: OpPayload(type: "fullDoc", data: Data("v2-other".utf8)))
        let seqBefore = await manager.liveInfo()["D"]?.seq
        #expect(seqBefore == 1)

        let outcome = await manager.submit(docId: "D", opId: "ours",
                                           payload: OpPayload(type: "fullDoc", data: Data("v2-ours".utf8)),
                                           expectation: .matchHash(sha256(stale)))

        guard case .rejected(let message) = outcome else { Issue.record("expected rejected, got \(outcome)"); return }
        guard case .reject(_, _, let reason, _) = message else { Issue.record("expected .reject, got \(message)"); return }
        #expect(reason == "docChangedDuringOp")               // same signal the byte form gives
        #expect(await manager.currentBytes(docId: "D") == Data("v2-other".utf8))
        #expect(await manager.liveInfo()["D"]?.seq == seqBefore)
        #expect(try store.load(docId: "D") == Data("v2-other".utf8))   // and nothing reached disk
    }

    /// The digest is of the CONTENT, not of anything the wire adds around it — a same-length but
    /// different document must not slip through.
    @Test func aDigestOfDifferentContentOfTheSameLengthIsRejected() async throws {
        let original = Data("v1".utf8)
        let (_, manager) = try makeStoreAndManager(seed: original)
        _ = try await manager.subscribe(docId: "D")

        let outcome = await manager.submit(docId: "D", opId: "op1",
                                           payload: OpPayload(type: "fullDoc", data: Data("v2".utf8)),
                                           expectation: .matchHash(sha256(Data("v9".utf8))))

        guard case .rejected = outcome else { Issue.record("expected rejected, got \(outcome)"); return }
        #expect(await manager.currentBytes(docId: "D") == original)
    }

    @Test func theExpectationRoundTripsOnTheWire() throws {
        let digest = sha256(Data("hello".utf8))
        let encoded = try JSONEncoder().encode(WriteExpectation.matchHash(digest))
        #expect(try JSONDecoder().decode(WriteExpectation.self, from: encoded) == .matchHash(digest))
        // …and stays distinguishable from the byte form carrying the same payload.
        let asBytes = try JSONEncoder().encode(WriteExpectation.matchBytes(digest))
        #expect(try JSONDecoder().decode(WriteExpectation.self, from: asBytes) == .matchBytes(digest))
        #expect(encoded != asBytes)
    }
}
