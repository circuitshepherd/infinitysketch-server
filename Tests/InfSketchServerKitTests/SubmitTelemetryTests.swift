import Foundation
import Testing
import Crypto
@testable import InfSketchServerKit
import InfSketchWire

/// A row per write, from the real `DocumentSession.submit`.
///
/// `SyncTelemetryTests` covers the gate, the row's shape and the file. This covers what those
/// cannot: that a write actually EMITS one, with the phases filled in from work that happened
/// rather than from a fixture.
///
/// An EXTENSION of that suite rather than a suite of its own, and that is load-bearing: the gate is
/// process-global, `.serialized` orders only one suite, and as two suites these tests turned each
/// other's telemetry off mid-write (one failure in six tests, on two runs in three).
extension SyncTelemetryTests {

    private func makeStore() throws -> DirectoryDocumentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("submit-telemetry-\(UUID().uuidString)", isDirectory: true)
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

    private func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    @Test func anAcceptedWriteEmitsOneRowWithItsPhases() async throws {
        try await withCapture(enabled: true) { captured in
            let store = try makeStore()
            let doc = "telemetry-accepted"
            try store.save(docId: doc, bytes: Data("{}".utf8))
            let session = try DocumentSession(docId: doc, store: store, bufferLimit: 16)

            let outcome = await session.submit(
                opId: "OP-A", payload: OpPayload(type: "fullDoc", data: Data("{\"a\":1}".utf8)))
            #expect(outcome == .accepted(seq: 1))

            let rows = captured.rows(doc: doc)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row["op"] as? String == "OP-A")
            #expect(row["kind"] as? String == "fullDoc")
            #expect(row["outcome"] as? String == "accepted")
            #expect(row["docB"] as? Int == 7)
            #expect(row["saveMs"] != nil, "an accepted write reached the store, so the save is timed")
            #expect(row["totalMs"] != nil)
        }
    }

    /// A refused write is as interesting as an accepted one — a CAS refusal under load IS what
    /// contention looks like from here — and it must be visibly distinct from a slow success.
    @Test func aRejectedWriteEmitsItsReasonAndNoSave() async throws {
        try await withCapture(enabled: true) { captured in
            let store = try makeStore()
            let doc = "telemetry-rejected"
            try store.save(docId: doc, bytes: Data("{}".utf8))
            let session = try DocumentSession(docId: doc, store: store, bufferLimit: 16)

            let outcome = await session.submit(
                opId: "OP-R", payload: OpPayload(type: "fullDoc", data: Data("{\"a\":1}".utf8)),
                expectation: .matchBytes(Data("something else".utf8)))
            guard case .rejected = outcome else {
                Issue.record("the fixture must be refused, or this measures the wrong path")
                return
            }

            let row = try #require(captured.rows(doc: doc).first)
            #expect(row["outcome"] as? String == "docChangedDuringOp")
            #expect(row["saveMs"] == nil, "nothing was stored, so there is no save to time")
        }
    }

    /// The rebuild is the expensive half of a stripped push, so it gets its own number — otherwise
    /// a slow rebuild is indistinguishable from a slow save inside one total.
    @Test func aStrippedWriteTimesItsRebuildSeparately() async throws {
        try await withCapture(enabled: true) { captured in
            let store = try makeStore()
            let doc = "telemetry-stripped"
            let id = UUID()
            let base = document(blobId: id, tail: "before")
            let updated = document(blobId: id, tail: "after")
            try store.save(docId: doc, bytes: base)
            let session = try DocumentSession(docId: doc, store: store, bufferLimit: 16)

            let stripped = StrippedDocument.strip(document: updated, against: base,
                                                  basedOn: sha256(base),
                                                  originalSHA256: sha256(updated))
            let payload = stripped.encoded()
            let outcome = await session.submit(
                opId: "OP-S", payload: OpPayload(type: "strippedDoc", data: payload))
            #expect(outcome == .accepted(seq: 1))

            let row = try #require(captured.rows(doc: doc).first)
            #expect(row["kind"] as? String == "strippedDoc")
            #expect(row["rebuildMs"] != nil, "a stripped payload was rebuilt, so the rebuild is timed")
            #expect(row["inB"] as? Int == payload.count)
            #expect(row["docB"] as? Int == updated.count,
                    "the row reports the DOCUMENT's size, not the payload's — that is the point")
        }
    }

    /// The wait is the number the feature exists for, and it is only knowable from OUTSIDE the
    /// actor. A caller that supplies its arrival instant gets it; one that cannot leaves it absent.
    @Test func theActorWaitIsReportedWhenTheCallerStampedItsArrival() async throws {
        try await withCapture(enabled: true) { captured in
            let store = try makeStore()
            let doc = "telemetry-wait"
            try store.save(docId: doc, bytes: Data("{}".utf8))
            let session = try DocumentSession(docId: doc, store: store, bufferLimit: 16)

            let arrived = ContinuousClock.now
            _ = await session.submit(opId: "OP-W",
                                     payload: OpPayload(type: "fullDoc", data: Data("{\"a\":1}".utf8)),
                                     receivedAt: arrived)
            let withStamp = try #require(captured.rows(doc: doc).first)
            #expect(withStamp["waitMs"] != nil)

            _ = await session.submit(opId: "OP-N",
                                     payload: OpPayload(type: "fullDoc", data: Data("{\"a\":2}".utf8)))
            let withoutStamp = try #require(captured.rows(doc: doc).last)
            #expect(withoutStamp["op"] as? String == "OP-N")
            #expect(withoutStamp["waitMs"] == nil,
                    "no arrival instant means the wait is UNKNOWN — absent, never zero")
        }
    }

    /// Off, the write path must not so much as format a row.
    @Test func aServerWithoutTheFlagEmitsNothing() async throws {
        let originalFlag = SyncTelemetry.isEnabled
        let originalSink = SyncTelemetry.sink
        defer { SyncTelemetry.isEnabled = originalFlag; SyncTelemetry.sink = originalSink }
        let captured = Capture()
        SyncTelemetry.sink = { captured.append($0) }
        SyncTelemetry.isEnabled = false

        let store = try makeStore()
        let doc = "telemetry-disabled"
        try store.save(docId: doc, bytes: Data("{}".utf8))
        let session = try DocumentSession(docId: doc, store: store, bufferLimit: 16)
        _ = await session.submit(opId: "OP-D",
                                 payload: OpPayload(type: "fullDoc", data: Data("{\"a\":1}".utf8)))

        #expect(captured.rows(doc: doc).isEmpty)
    }
}
