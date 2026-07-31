import Foundation
import Testing
import Crypto
@testable import InfSketchServerKit
import InfSketchWire

/// The server half of blob omission: a stripped op is rebuilt at the top of `submit`, so everything
/// after it — the compare-and-swap, the store, the broadcast, every agent relay — sees a whole
/// document and none of them learns that anything was left out.
@Suite struct StrippedSubmitTests {

    private func makeStore() throws -> DirectoryDocumentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stripped-submit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DirectoryDocumentStore(directory: dir)
    }

    /// A document shaped like real encoder output: one large pasted image, base64 with `/` escaped.
    private func document(blobId: UUID, tail: String) -> Data {
        let payload = String(repeating: "ab\\/cd", count: 4000)
        return Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }

    private func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// The rebuilt document is what gets STORED — byte-identical to what the sender encoded.
    @Test func aStrippedOpIsRebuiltAndStored() async throws {
        let store = try makeStore()
        let id = UUID()
        let base = document(blobId: id, tail: "before")
        let updated = document(blobId: id, tail: "after")
        try store.save(docId: "d", bytes: base)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        let stripped = StrippedDocument.strip(document: updated, against: base,
                                              basedOn: sha256(base), originalSHA256: sha256(updated))
        // The point of the exercise: the payload is a fraction of the document.
        #expect(stripped.encoded().count < updated.count / 2)

        let outcome = await session.submit(
            opId: "1", payload: OpPayload(type: "strippedDoc", data: stripped.encoded()))

        #expect(outcome == .accepted(seq: 1))
        #expect(try store.load(docId: "d") == updated, "the stored document is not byte-identical")
    }

    /// A rebuild that does not match the sender's hash is REFUSED, and the document does not move.
    /// These bytes become the stored document, the sync lineage and the merge base, so a wrong
    /// rebuild has to be unable to reach them.
    @Test func aRebuildThatDoesNotMatchIsRefusedAndChangesNothing() async throws {
        let store = try makeStore()
        let id = UUID()
        let base = document(blobId: id, tail: "before")
        let updated = document(blobId: id, tail: "after")
        try store.save(docId: "d", bytes: base)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        var stripped = StrippedDocument.strip(document: updated, against: base,
                                              basedOn: sha256(base), originalSHA256: sha256(updated))
        stripped.originalSHA256 = Data(repeating: 0xFF, count: 32)

        let outcome = await session.submit(
            opId: "1", payload: OpPayload(type: "strippedDoc", data: stripped.encoded()))

        #expect(outcome.rejectMessage != nil)
        #expect(try store.load(docId: "d") == base, "the document moved despite a refused rebuild")
    }

    /// Stripped against a document the session no longer holds: named, not attempted. This is the
    /// ordinary race — the app strips against a base the server has since moved past.
    @Test func aStaleBaseIsRefusedByName() async throws {
        let store = try makeStore()
        let id = UUID()
        let base = document(blobId: id, tail: "before")
        let somethingElse = document(blobId: id, tail: "diverged")
        try store.save(docId: "d", bytes: somethingElse)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        let updated = document(blobId: id, tail: "after")
        let stripped = StrippedDocument.strip(document: updated, against: base,
                                              basedOn: sha256(base), originalSHA256: sha256(updated))

        let outcome = await session.submit(
            opId: "1", payload: OpPayload(type: "strippedDoc", data: stripped.encoded()))

        if case .rejected(let message) = outcome, case .reject(_, _, let reason, _) = message {
            #expect(reason == "cannotReconstruct")
        } else {
            Issue.record("expected a cannotReconstruct rejection, got \(outcome)")
        }
        #expect(try store.load(docId: "d") == somethingElse)
    }

    /// A whole document still works exactly as before — this is additive.
    @Test func aFullDocOpIsUnaffected() async throws {
        let store = try makeStore()
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        let outcome = await session.submit(
            opId: "1", payload: OpPayload(type: "fullDoc", data: Fixtures.docBytes))

        #expect(outcome == .accepted(seq: 1))
    }

    /// An unknown type is still refused rather than stored — which is what makes an older server
    /// meeting a newer app a safe failure rather than a corrupted document.
    @Test func anUnknownPayloadTypeIsStillRefused() async throws {
        let store = try makeStore()
        try store.save(docId: "d", bytes: Fixtures.docBytes)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        let outcome = await session.submit(
            opId: "1", payload: OpPayload(type: "somethingElse", data: Data([1, 2, 3])))

        if case .rejected(let message) = outcome, case .reject(_, _, let reason, _) = message {
            #expect(reason == "unsupportedPayloadType")
        } else {
            Issue.record("expected unsupportedPayloadType, got \(outcome)")
        }
    }
}
