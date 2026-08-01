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

/// What OTHER subscribers receive. A stripped payload is a private arrangement between one client
/// and the server; forwarding it to everyone else hands them bytes they cannot read.
@Suite struct StrippedBroadcastTests {

    private func makeStore() throws -> DirectoryDocumentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stripped-broadcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DirectoryDocumentStore(directory: dir)
    }

    private func document(blobId: UUID, tail: String) -> Data {
        let payload = String(repeating: "ab\\/cd", count: 4000)
        return Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }

    /// Measured before the fix: a subscriber received `type = strippedDoc` and 210 bytes that are
    /// not JSON, took them for the document, and sat behind a permanent "Changed on the server"
    /// banner having never seen the change.
    @Test func aSubscriberReceivesTheWholeDocumentNotTheStrippedPayload() async throws {
        let store = try makeStore()
        let id = UUID()
        let base = document(blobId: id, tail: "before")
        let updated = document(blobId: id, tail: "after")
        try store.save(docId: "d", bytes: base)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        let subscription = await session.subscribe()
        let stripped = StrippedDocument.strip(document: updated, against: base,
                                              basedOn: Data(SHA256.hash(data: base)),
                                              originalSHA256: Data(SHA256.hash(data: updated)))
        _ = await session.submit(opId: "1",
                                 payload: OpPayload(type: "strippedDoc", data: stripped.encoded()))

        var seen: OpPayload?
        for await message in subscription.events {
            if case .event(_, _, _, _, let payload) = message { seen = payload; break }
        }
        let payload = try #require(seen)
        #expect(payload.type == "fullDoc")
        #expect(payload.bulk.inlineData == updated, "a subscriber was handed something else")
    }
}

/// M2 — the agent reply. The device may leave out the blobs the server just sent it; the broker
/// splices them back so every caller downstream sees a whole document exactly as before.
@Suite struct StrippedReplyTests {

    private func document(blobId: UUID, tail: String) -> Data {
        let payload = String(repeating: "ab\\/cd", count: 4000)
        return Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }

    /// The wire carries the kind explicitly rather than leaving the receiver to sniff what it got —
    /// and it survives the chunking swap, exactly as `meta` does.
    @Test func thePayloadKindRoundTripsAndSurvivesChunking() throws {
        let message = ClientMessage.strokeOpReply(requestId: 7, docId: "d",
                                                  payload: .inline(Data([1, 2, 3])), meta: nil,
                                                  failureReason: nil, payloadKind: "strippedDoc")
        #expect(try ClientMessage(jsonText: message.jsonText()) == message)

        let descriptor = TransferDescriptor(transferId: 1, totalBytes: 3, chunkSize: 2)
        if case .strokeOpReply(_, _, _, _, _, let kind) = message.replacingBulk(with: descriptor) {
            #expect(kind == "strippedDoc", "chunking changes how bytes travel, never what they are")
        } else {
            Issue.record("replacingBulk did not preserve the reply shape")
        }
        if case .strokeOpReply(_, _, _, _, _, let kind) = message.resolvingBulk(with: Data([9])) {
            #expect(kind == "strippedDoc")
        } else {
            Issue.record("resolvingBulk did not preserve the reply shape")
        }
    }

    /// An older peer sends no kind at all, and that must keep meaning "a whole document".
    @Test func anAbsentKindMeansAWholeDocument() throws {
        let json = #"{"type":"strokeOpReply","requestId":1,"docId":"d","data":"AQID"}"#
        if case .strokeOpReply(_, _, _, _, _, let kind) = try ClientMessage(jsonText: json) {
            #expect(kind == nil)
        } else {
            Issue.record("did not decode as a strokeOpReply")
        }
    }
}

/// M3 — the broadcast. Only a subscriber that said it understands a stripped document gets one;
/// everyone else keeps receiving whole documents, because `infsketch-demo` subscribes too.
@Suite struct StrippedBroadcastCapabilityTests {

    private func makeStore() throws -> DirectoryDocumentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stripped-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DirectoryDocumentStore(directory: dir)
    }

    private func document(blobId: UUID, tail: String) -> Data {
        let payload = String(repeating: "ab\\/cd", count: 4000)
        return Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }

    private func firstEvent(_ result: SubscribeResult) async -> OpPayload? {
        for await message in result.events {
            if case .event(_, _, _, _, let payload) = message { return payload }
        }
        return nil
    }

    /// Two subscribers on one document, one capable and one not: each gets the form it can read,
    /// and both end up with the same document.
    @Test func eachSubscriberGetsTheFormItCanRead() async throws {
        let store = try makeStore()
        let id = UUID()
        let base = document(blobId: id, tail: "before")
        let updated = document(blobId: id, tail: "after")
        try store.save(docId: "d", bytes: base)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)

        let capable = await session.subscribe(acceptsStrippedDocuments: true)
        let plain = await session.subscribe()

        _ = await session.submit(opId: "1", payload: OpPayload(type: "fullDoc", data: updated))

        let toCapable = try #require(await firstEvent(capable))
        let toPlain = try #require(await firstEvent(plain))

        #expect(toCapable.type == "strippedDoc")
        #expect(toPlain.type == "fullDoc")
        #expect(toPlain.bulk.inlineData == updated)

        // …and the capable one rebuilds to exactly what the other was handed.
        let payload = try #require(toCapable.bulk.inlineData)
        #expect(payload.count < updated.count / 2, "nothing was actually omitted")
        let rebuilt = try StrippedDocument(encoded: payload).restore(using: base)
        #expect(rebuilt == updated)
    }

    /// With nobody capable, the stripping is not even attempted — no parse of the previous document,
    /// no second payload built.
    @Test func withNoCapableSubscriberTheDocumentGoesWhole() async throws {
        let store = try makeStore()
        let id = UUID()
        let base = document(blobId: id, tail: "before")
        try store.save(docId: "d", bytes: base)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)
        let plain = await session.subscribe()

        let updated = document(blobId: id, tail: "after")
        _ = await session.submit(opId: "1", payload: OpPayload(type: "fullDoc", data: updated))

        let payload = try #require(await firstEvent(plain))
        #expect(payload.type == "fullDoc")
        #expect(payload.bulk.inlineData == updated)
    }
}

/// The writer is not an audience. It matches its own echo by `opId` and never reads the payload, so
/// building a stripped one for it is tens of milliseconds of parsing on this actor, thrown away.
@Suite struct StrippedBroadcastAudienceTests {

    private func makeStore() throws -> DirectoryDocumentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stripped-audience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DirectoryDocumentStore(directory: dir)
    }

    private func document(blobId: UUID, tail: String) -> Data {
        let payload = String(repeating: "ab\\/cd", count: 4000)
        return Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }

    private func firstEvent(_ result: SubscribeResult) async -> OpPayload? {
        for await message in result.events {
            if case .event(_, _, _, _, let payload) = message { return payload }
        }
        return nil
    }

    /// The single-device case, which is the common one: the only capable subscriber IS the writer,
    /// so nothing is stripped.
    @Test func aLoneWriterIsNotStrippedFor() async throws {
        let store = try makeStore()
        let id = UUID()
        let base = document(blobId: id, tail: "before")
        try store.save(docId: "d", bytes: base)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)
        let writer = await session.subscribe(acceptsStrippedDocuments: true)

        let updated = document(blobId: id, tail: "after")
        _ = await session.submit(opId: "1", payload: OpPayload(type: "fullDoc", data: updated),
                                 submitter: writer.token)

        let payload = try #require(await firstEvent(writer))
        #expect(payload.type == "fullDoc", "a strip was built for the one peer that ignores it")
    }

    /// …but a second capable device is a real audience, and then it is worth it — including for the
    /// writer's own echo, which rides along on the same stripped message.
    @Test func aSecondCapableDeviceIsWorthStrippingFor() async throws {
        let store = try makeStore()
        let id = UUID()
        let base = document(blobId: id, tail: "before")
        try store.save(docId: "d", bytes: base)
        let session = try DocumentSession(docId: "d", store: store, bufferLimit: 16)
        let writer = await session.subscribe(acceptsStrippedDocuments: true)
        let other = await session.subscribe(acceptsStrippedDocuments: true)

        let updated = document(blobId: id, tail: "after")
        _ = await session.submit(opId: "1", payload: OpPayload(type: "fullDoc", data: updated),
                                 submitter: writer.token)

        let toOther = try #require(await firstEvent(other))
        #expect(toOther.type == "strippedDoc")
        let rebuilt = try StrippedDocument(encoded: try #require(toOther.bulk.inlineData))
            .restore(using: base)
        #expect(rebuilt == updated)
    }
}
