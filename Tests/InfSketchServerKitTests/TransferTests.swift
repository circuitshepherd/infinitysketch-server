import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire

@Suite struct TransferDescriptorTests {
    @Test func chunkCountExactMultiple() {
        let d = TransferDescriptor(transferId: 1, totalBytes: 1024, chunkSize: 256)
        #expect(d.chunkCount == 4)
    }
    @Test func chunkCountWithRemainder() {
        let d = TransferDescriptor(transferId: 1, totalBytes: 1025, chunkSize: 256)
        #expect(d.chunkCount == 5)
    }
    @Test func chunkCountEmpty() {
        let d = TransferDescriptor(transferId: 1, totalBytes: 0, chunkSize: 256)
        #expect(d.chunkCount == 0)
    }
    @Test func chunkCountSingleByte() {
        let d = TransferDescriptor(transferId: 1, totalBytes: 1, chunkSize: 256)
        #expect(d.chunkCount == 1)
    }
}

@Suite struct ChunkFramingTests {
    @Test func roundTrip() throws {
        let payload = Data((0..<300).map { UInt8($0 % 256) })
        let frame = ChunkFraming.encode(transferId: 0xDEADBEEF, index: 42, payload: payload)
        #expect(frame.count == ChunkFraming.headerSize + payload.count)
        #expect(frame.first == ChunkFraming.chunkKind)
        let decoded = try ChunkFraming.decode(frame)
        #expect(decoded.transferId == 0xDEADBEEF)
        #expect(decoded.index == 42)
        #expect(Data(decoded.payload) == payload)
    }
    @Test func emptyPayloadRoundTrip() throws {
        let frame = ChunkFraming.encode(transferId: 7, index: 0, payload: Data())
        let decoded = try ChunkFraming.decode(frame)
        #expect(decoded.transferId == 7)
        #expect(decoded.payload.isEmpty)
    }
    @Test func decodeFromNonZeroBasedSlice() throws {
        // Data slices keep their parent's indices — the decoder must not assume startIndex == 0.
        let padded = Data([0xFF, 0xFF]) + ChunkFraming.encode(transferId: 3, index: 1, payload: Data([9, 9]))
        let slice = padded.dropFirst(2)
        let decoded = try ChunkFraming.decode(slice)
        #expect(decoded.transferId == 3)
        #expect(decoded.index == 1)
        #expect(Data(decoded.payload) == Data([9, 9]))
    }
    @Test func unknownKindThrows() {
        let bad = Data([0x02]) + Data(count: 8)
        #expect(throws: TransferWireError.unknownBinaryKind(0x02)) {
            _ = try ChunkFraming.decode(bad)
        }
    }
    @Test func truncatedHeaderThrows() {
        #expect(throws: TransferWireError.truncatedChunkHeader) {
            _ = try ChunkFraming.decode(Data([ChunkFraming.chunkKind, 0, 0]))
        }
        #expect(throws: TransferWireError.truncatedChunkHeader) {
            _ = try ChunkFraming.decode(Data())
        }
    }
}

@Suite struct TransferSenderTests {
    @Test func smallPayloadStaysSingleTextFrame() throws {
        var sender = TransferSender<ServerMessage>(inlineLimit: 16, chunkSize: 8)
        let frames = try sender.frames(for: .subscribed(docId: "d", seq: 0, snapshot: .inline(Data(count: 16))))
        #expect(frames.count == 1)
        guard case .text(let json) = frames[0] else { Issue.record("expected text"); return }
        #expect(try ServerMessage(jsonText: json)
            == .subscribed(docId: "d", seq: 0, snapshot: .inline(Data(count: 16))))
    }
    /// A payload under the inline limit still chunks when the fields BESIDE it would make the
    /// text frame too big: a `strokeOpRequest` with a spec near its own 64 KiB limit and a payload
    /// near the inline limit was one ~175 KB frame (round 6, item 13).
    @Test func aFrameMadeBigByItsOtherFieldsChunksItsPayload() throws {
        var sender = TransferSender<ServerMessage>(inlineLimit: 64 * 1024, chunkSize: 64 * 1024)
        let spec = Data(repeating: 0x41, count: 60 * 1024)
        let payload = Data(repeating: 0x42, count: 60 * 1024)
        let frames = try sender.frames(for: .strokeOpRequest(
            requestId: 1, docId: "d", payload: .inline(payload), spec: spec))
        #expect(frames.count == 3, "announce + one chunk + end")
        for frame in frames {
            if case .text(let text) = frame {
                #expect(text.utf8.count <= TransferDefaults.maxInlineTextFrame)
            }
        }
        // The same payload with a small spec stays one frame.
        let small = try sender.frames(for: .strokeOpRequest(
            requestId: 2, docId: "d", payload: .inline(payload), spec: Data("{}".utf8)))
        #expect(small.count == 1)
    }
    @Test func bulklessMessageStaysSingleTextFrame() throws {
        var sender = TransferSender<ServerMessage>(inlineLimit: 0, chunkSize: 8)
        let frames = try sender.frames(for: .helloAck(protocolVersion: 1, serverId: "s"))
        #expect(frames.count == 1)
    }
    @Test func largePayloadExpandsToDescriptorChunksEnd() throws {
        let payload = Data((0..<20).map(UInt8.init))   // 20 bytes, chunkSize 8 → 3 chunks (8, 8, 4)
        var sender = TransferSender<ServerMessage>(inlineLimit: 16, chunkSize: 8)
        let frames = try sender.frames(for: .subscribed(docId: "d", seq: 5, snapshot: .inline(payload)))
        #expect(frames.count == 5)   // announce + 3 chunks + end

        guard case .text(let announceJSON) = frames[0],
              case .subscribed(_, 5, .transfer(let d)) = try ServerMessage(jsonText: announceJSON)
        else { Issue.record("expected descriptor announce"); return }
        #expect(d.totalBytes == 20)
        #expect(d.chunkSize == 8)
        #expect(d.chunkCount == 3)

        var reassembled = Data()
        for (offset, frame) in frames[1...3].enumerated() {
            guard case .binary(let chunkFrame) = frame else { Issue.record("expected binary"); return }
            let chunk = try ChunkFraming.decode(chunkFrame)
            #expect(chunk.transferId == d.transferId)
            #expect(chunk.index == UInt32(offset))
            reassembled.append(chunk.payload)
        }
        #expect(reassembled == payload)

        guard case .text(let endJSON) = frames[4] else { Issue.record("expected end"); return }
        #expect(try ServerMessage(jsonText: endJSON) == .transferEnd(transferId: d.transferId))
    }
    @Test func exactMultiplePayloadExpandsWithNoRemainderChunk() throws {
        let payload = Data((0..<24).map(UInt8.init))   // 24 bytes, chunkSize 8 → exactly 3 full chunks
        var sender = TransferSender<ServerMessage>(inlineLimit: 16, chunkSize: 8)
        let frames = try sender.frames(for: .subscribed(docId: "d", seq: 0, snapshot: .inline(payload)))
        #expect(frames.count == 5)   // announce + 3 chunks + end
        for frame in frames[1...3] {
            guard case .binary(let chunkFrame) = frame else { Issue.record("expected binary"); return }
            #expect(try ChunkFraming.decode(chunkFrame).payload.count == 8)
        }
    }
    @Test func transferIdsIncrementPerTransfer() throws {
        var sender = TransferSender<ClientMessage>(inlineLimit: 0, chunkSize: 8)
        func announcedId(_ frames: [WireFrame]) throws -> UInt32? {
            guard case .text(let json) = frames.first,
                  case .op(_, _, let payload, _) = try ClientMessage(jsonText: json),
                  case .transfer(let d) = payload.bulk else { return nil }
            return d.transferId
        }
        let first = try sender.frames(for: .op(
            docId: "d", opId: "o1", payload: OpPayload(type: "fullDoc", data: Data([1]))))
        let second = try sender.frames(for: .op(
            docId: "d", opId: "o2", payload: OpPayload(type: "fullDoc", data: Data([2]))))
        #expect(try announcedId(first) == 0)
        #expect(try announcedId(second) == 1)
    }
}

@Suite struct TransferReassemblerTests {
    /// Sender output fed straight into a reassembler must reproduce the message.
    @Test func roundTripThroughSenderServerDirection() throws {
        let payload = Data((0..<100).map(UInt8.init))
        var sender = TransferSender<ServerMessage>(inlineLimit: 16, chunkSize: 8)
        var reassembler = TransferReassembler<ServerMessage>()
        var results: [ServerMessage] = []
        for frame in try sender.frames(for: .subscribed(docId: "d", seq: 3, snapshot: .inline(payload))) {
            if let message = try reassembler.consume(frame) { results.append(message) }
        }
        #expect(results == [.subscribed(docId: "d", seq: 3, snapshot: .inline(payload))])
    }
    @Test func roundTripThroughSenderClientDirection() throws {
        let payload = Data(repeating: 7, count: 33)
        var sender = TransferSender<ClientMessage>(inlineLimit: 8, chunkSize: 16)
        var reassembler = TransferReassembler<ClientMessage>()
        var results: [ClientMessage] = []
        let op = ClientMessage.op(docId: "d", opId: "o1", payload: OpPayload(type: "fullDoc", data: payload))
        for frame in try sender.frames(for: op) {
            if let message = try reassembler.consume(frame) { results.append(message) }
        }
        #expect(results == [op])
    }
    /// The chunked path for `.advertiseDocs` — the only `TransferCarrying` case with no
    /// dedicated chunked round-trip test (M2b Task 1 review finding). A batch of
    /// `DocAdvertisement`s with multi-KB thumbnails, forced through a tiny `inlineLimit`,
    /// must genuinely open a `.transfer` descriptor (not silently stay inline) and reassemble
    /// back to the exact original array.
    @Test func advertiseDocsRoundTripsThroughChunkedTransfer() throws {
        let ads = (0..<5).map { i in
            DocAdvertisement(docId: "doc-\(i)", modifiedAt: Date(timeIntervalSince1970: Double(i)),
                              sizeBytes: 1000 + i, thumbnail: Data(repeating: UInt8(i), count: 4096))
        }
        let json = try JSONEncoder().encode(ads)
        var sender = TransferSender<ClientMessage>(inlineLimit: 64, chunkSize: 512)
        var reassembler = TransferReassembler<ClientMessage>()
        let frames = try sender.frames(for: .advertiseDocs(payload: .inline(json)))

        // Verify this genuinely chunked: the announce frame must carry a `.transfer`
        // descriptor (not `.inline`), and there must be more than one chunk — proving it
        // didn't just squeak through as a single inline frame.
        guard case .text(let announceJSON) = frames[0],
              case .advertiseDocs(.transfer(let descriptor)) = try ClientMessage(jsonText: announceJSON)
        else { Issue.record("expected a chunked transfer descriptor announce, not inline"); return }
        #expect(json.count > 64)
        #expect(descriptor.totalBytes == json.count)
        #expect(descriptor.chunkCount > 1)
        #expect(frames.count == descriptor.chunkCount + 2)   // announce + N chunks + end

        var results: [ClientMessage] = []
        for frame in frames {
            if let message = try reassembler.consume(frame) { results.append(message) }
        }
        #expect(results.count == 1)
        guard case .advertiseDocs(let payload) = results.first, case .inline(let reassembled) = payload
        else { Issue.record("expected reassembled advertiseDocs with inline payload"); return }
        #expect(try JSONDecoder().decode([DocAdvertisement].self, from: reassembled) == ads)
    }

    @Test func ordinaryMessagePassesThrough() throws {
        var reassembler = TransferReassembler<ClientMessage>()
        let message = try reassembler.consume(.text(try ClientMessage.subscribeStatus.jsonText()))
        #expect(message == .subscribeStatus)
    }
    @Test func interleavedTextPassesThroughMidTransfer() throws {
        let payload = Data(repeating: 1, count: 20)
        var sender = TransferSender<ServerMessage>(inlineLimit: 4, chunkSize: 8)
        var reassembler = TransferReassembler<ServerMessage>()
        let frames = try sender.frames(for: .subscribed(docId: "d", seq: 0, snapshot: .inline(payload)))
        _ = try reassembler.consume(frames[0])   // announce
        _ = try reassembler.consume(frames[1])   // chunk 0
        // A status event interleaves mid-transfer and must emerge immediately.
        let status = ServerMessage.statusEvent(payload: StatusPayload(
            docId: "x", kind: "docUpdated", seq: 1, subscriberCount: 1))
        #expect(try reassembler.consume(.text(try status.jsonText())) == status)
        _ = try reassembler.consume(frames[2])   // chunk 1
        _ = try reassembler.consume(frames[3])   // chunk 2
        let done = try reassembler.consume(frames[4])   // end
        #expect(done == .subscribed(docId: "d", seq: 0, snapshot: .inline(payload)))
    }
    @Test func zeroByteTransferCompletes() throws {
        var reassembler = TransferReassembler<ServerMessage>()
        let d = TransferDescriptor(transferId: 0, totalBytes: 0, chunkSize: 8)
        _ = try reassembler.consume(.text(try ServerMessage.subscribed(docId: "d", seq: 0, snapshot: .transfer(d)).jsonText()))
        let done = try reassembler.consume(.text(try ServerMessage.transferEnd(transferId: 0).jsonText()))
        #expect(done == .subscribed(docId: "d", seq: 0, snapshot: .inline(Data())))
    }

    // MARK: fatal violations

    private func opened(_ d: TransferDescriptor) throws -> TransferReassembler<ServerMessage> {
        var r = TransferReassembler<ServerMessage>()
        _ = try r.consume(.text(try ServerMessage.subscribed(docId: "d", seq: 0, snapshot: .transfer(d)).jsonText()))
        return r
    }

    @Test func chunkWithoutTransferIsFatal() throws {
        var r = TransferReassembler<ServerMessage>()
        #expect(throws: TransferWireError.chunkWithoutTransfer) {
            _ = try r.consume(.binary(ChunkFraming.encode(transferId: 0, index: 0, payload: Data([1]))))
        }
    }
    @Test func secondAnnounceWhileInFlightIsFatal() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 8, chunkSize: 8)
        var r = try opened(d)
        let second = ServerMessage.subscribed(docId: "e", seq: 0,
            snapshot: .transfer(TransferDescriptor(transferId: 1, totalBytes: 8, chunkSize: 8)))
        #expect(throws: TransferWireError.transferAlreadyInFlight) {
            _ = try r.consume(.text(try second.jsonText()))
        }
    }
    @Test func nonContiguousChunkIsFatal() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 20, chunkSize: 8)
        var r = try opened(d)
        #expect(throws: TransferWireError.nonContiguousChunk(expected: 0, got: 1)) {
            _ = try r.consume(.binary(ChunkFraming.encode(transferId: 0, index: 1, payload: Data(count: 8))))
        }
    }
    @Test func wrongChunkSizeIsFatal() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 20, chunkSize: 8)
        var r = try opened(d)
        #expect(throws: TransferWireError.wrongChunkSize(expected: 8, got: 3)) {
            _ = try r.consume(.binary(ChunkFraming.encode(transferId: 0, index: 0, payload: Data(count: 3))))
        }
    }
    @Test func chunkAfterCompleteIsFatal() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 8, chunkSize: 8)
        var r = try opened(d)
        _ = try r.consume(.binary(ChunkFraming.encode(transferId: 0, index: 0, payload: Data(count: 8))))
        #expect(throws: TransferWireError.unexpectedChunk) {
            _ = try r.consume(.binary(ChunkFraming.encode(transferId: 0, index: 1, payload: Data(count: 8))))
        }
    }
    @Test func endBeforeCompleteIsFatal() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 20, chunkSize: 8)
        var r = try opened(d)
        #expect(throws: TransferWireError.endBeforeComplete) {
            _ = try r.consume(.text(try ServerMessage.transferEnd(transferId: 0).jsonText()))
        }
    }
    @Test func wrongTransferIdOnChunkAndEndIsFatal() throws {
        let d = TransferDescriptor(transferId: 5, totalBytes: 8, chunkSize: 8)
        var r = try opened(d)
        #expect(throws: TransferWireError.wrongTransferId(expected: 5, got: 6)) {
            _ = try r.consume(.binary(ChunkFraming.encode(transferId: 6, index: 0, payload: Data(count: 8))))
        }
        var r2 = try opened(d)
        _ = try r2.consume(.binary(ChunkFraming.encode(transferId: 5, index: 0, payload: Data(count: 8))))
        #expect(throws: TransferWireError.wrongTransferId(expected: 5, got: 9)) {
            _ = try r2.consume(.text(try ServerMessage.transferEnd(transferId: 9).jsonText()))
        }
    }
    @Test func controlWithoutTransferIsFatal() throws {
        var r = TransferReassembler<ServerMessage>()
        #expect(throws: TransferWireError.controlWithoutTransfer) {
            _ = try r.consume(.text(try ServerMessage.transferEnd(transferId: 0).jsonText()))
        }
    }
    @Test func forgedInconsistentDescriptorIsFatal() throws {
        // chunkCount lies about totalBytes/chunkSize — hand-built JSON, not the safe init.
        let json = #"{"type":"subscribed","docId":"d","seq":0,"transfer":{"transferId":0,"totalBytes":100,"chunkSize":8,"chunkCount":1}}"#
        var r = TransferReassembler<ServerMessage>()
        #expect(throws: TransferWireError.invalidDescriptor) {
            _ = try r.consume(.text(json))
        }
    }
    @Test func duplicateChunkIsFatal() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 20, chunkSize: 8)
        var r = try opened(d)
        _ = try r.consume(.binary(ChunkFraming.encode(transferId: 0, index: 0, payload: Data(count: 8))))
        #expect(throws: TransferWireError.nonContiguousChunk(expected: 1, got: 0)) {
            _ = try r.consume(.binary(ChunkFraming.encode(transferId: 0, index: 0, payload: Data(count: 8))))
        }
    }
    @Test func malformedJSONThrowsDecodingErrorNotTransferError() throws {
        var r = TransferReassembler<ServerMessage>()
        do {
            _ = try r.consume(.text("{nope"))
            Issue.record("expected throw")
        } catch is TransferWireError {
            Issue.record("malformed JSON must not be a TransferWireError")
        } catch {
            // any DecodingError-ish error is correct (per-message severity)
        }
    }
    @Test func forgedIntMaxDescriptorIsRejectedNotTrapped() throws {
        // chunkCount inconsistent with Int.max totalBytes — the ceil math must not overflow-trap.
        let json = #"{"type":"subscribed","docId":"d","seq":0,"transfer":{"transferId":0,"totalBytes":9223372036854775807,"chunkSize":8,"chunkCount":1}}"#
        var r = TransferReassembler<ServerMessage>()
        #expect(throws: TransferWireError.invalidDescriptor) {
            _ = try r.consume(.text(json))
        }
    }
    @Test func selfConsistentHugeDescriptorOpensWithoutTrapping() throws {
        // A consistent but absurd totalBytes must not trap on reserveCapacity;
        // it simply opens a transfer that will never complete.
        // (An uncapped reassembler: the size cap would refuse this before reserveCapacity.)
        let d = TransferDescriptor(transferId: 0, totalBytes: Int.max - 7, chunkSize: 8)
        var r = TransferReassembler<ServerMessage>(maxTotalBytes: .max)
        let opened = try r.consume(.text(try ServerMessage.subscribed(docId: "d", seq: 0, snapshot: .transfer(d)).jsonText()))
        #expect(opened == nil)
    }

    // MARK: bounds (review finding 17)

    /// One peer declaring a huge transfer grew the server by hundreds of MB before anything cut
    /// it. The declared size is known up front, so it is refused up front.
    @Test func aDescriptorOverTheCapIsFatal() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 1025, chunkSize: 512)
        var r = TransferReassembler<ServerMessage>(maxTotalBytes: 1024)
        #expect(throws: TransferWireError.transferTooLarge(totalBytes: 1025, limit: 1024)) {
            _ = try r.consume(.text(try ServerMessage.subscribed(docId: "d", seq: 0, snapshot: .transfer(d)).jsonText()))
        }
    }

    @Test func aDescriptorAtTheCapOpens() throws {
        let d = TransferDescriptor(transferId: 0, totalBytes: 1024, chunkSize: 512)
        var r = TransferReassembler<ServerMessage>(maxTotalBytes: 1024)
        #expect(try r.consume(.text(try ServerMessage.subscribed(docId: "d", seq: 0, snapshot: .transfer(d)).jsonText())) == nil)
    }

    @Test func theDefaultCapIs512MB() {
        #expect(TransferReassembler<ServerMessage>.defaultMaxTotalBytes == 512 * 1024 * 1024)
    }

    /// While transfers are not accepted (the server, before hello) neither a descriptor nor a chunk
    /// may open or feed one; an ordinary message still passes.
    @Test func transfersAreRefusedUntilAccepted() throws {
        var r = TransferReassembler<ServerMessage>()
        r.acceptsTransfers = false
        #expect(try r.consume(.text(try ServerMessage.helloAck(protocolVersion: 1, serverId: "s").jsonText())) == .helloAck(protocolVersion: 1, serverId: "s"))
        let d = TransferDescriptor(transferId: 0, totalBytes: 8, chunkSize: 8)
        #expect(throws: TransferWireError.transferBeforeHandshake) {
            _ = try r.consume(.text(try ServerMessage.subscribed(docId: "d", seq: 0, snapshot: .transfer(d)).jsonText()))
        }
        var r2 = TransferReassembler<ServerMessage>()
        r2.acceptsTransfers = false
        #expect(throws: TransferWireError.transferBeforeHandshake) {
            _ = try r2.consume(.binary(ChunkFraming.encode(transferId: 0, index: 0, payload: Data([1]))))
        }
    }
}

/// Round 5, item 3: every WebSocket message either end sends by default stays small enough to
/// arrive inside the app's 60 s silence window on a slow link. At 512 KB chunks a link below
/// ~8.7 KB/s never delivered one; the defaults are 64 KB now, inline included.
@Suite struct TransferDefaultsTests {
    @Test func noDefaultMessageIsLargerThanAboutNinetyKilobytes() throws {
        #expect(TransferDefaults.chunkSize == 64 * 1024)
        #expect(TransferDefaults.inlineLimit == 64 * 1024)
        #expect(SessionConfig().chunkSize == TransferDefaults.chunkSize)
        #expect(SessionConfig().inlineLimit == TransferDefaults.inlineLimit)
        var sender = TransferSender<ServerMessage>(inlineLimit: TransferDefaults.inlineLimit,
                                                   chunkSize: TransferDefaults.chunkSize)
        for size in [TransferDefaults.inlineLimit, TransferDefaults.inlineLimit + 1, 5_000_000] {
            let frames = try sender.frames(for: .subscribed(docId: "d", seq: 1,
                                                            snapshot: .inline(Data(repeating: 0x41, count: size))))
            let largest = frames.map { frame -> Int in
                switch frame { case .text(let t): t.utf8.count; case .binary(let d): d.count }
            }.max() ?? 0
            // Inline base64 is 4/3 of the payload; a chunk is the payload plus a 9-byte header.
            #expect(largest <= 90 * 1024, "a \(size)-byte payload produced a \(largest)-byte message")
        }
        // …and a receiver still accepts any self-consistent chunk size a peer chooses.
        var old = TransferSender<ServerMessage>(inlineLimit: 256 * 1024, chunkSize: 512 * 1024)
        var receiver = TransferReassembler<ServerMessage>()
        let big = Data(repeating: 0x42, count: 1_300_000)
        var out: ServerMessage?
        for frame in try old.frames(for: .subscribed(docId: "d", seq: 1, snapshot: .inline(big))) {
            if let message = try receiver.consume(frame) { out = message }
        }
        #expect(out == .subscribed(docId: "d", seq: 1, snapshot: .inline(big)))
    }
}


/// `docList` is never chunked (it has no bulk field) and reaches a `URLSessionWebSocketTask` whose
/// receive limit is 1 MiB, which it answers by DROPPING the connection. Pinned at a realistic
/// store: 500 documents with long names make ~70 KB, so the limit is ~7000 documents away
/// (round 6, item 13 — measured, and deliberately not chunked).
@Suite struct DocListFrameSizeTests {
    @Test func fiveHundredDocumentsStayFarUnderTheReceiveLimit() throws {
        let docs = (0..<500).map { i in
            DocListEntry(id: "A fairly long document name number \(i)", sizeBytes: 5_812_345,
                         modifiedAt: Date(), seq: 123, subscriberCount: 2, hasContent: true)
        }
        var sender = TransferSender<ServerMessage>(inlineLimit: TransferDefaults.inlineLimit,
                                                   chunkSize: TransferDefaults.chunkSize)
        let frames = try sender.frames(for: .docList(docs: docs))
        guard case .text(let text)? = frames.first, frames.count == 1 else {
            Issue.record("docList is one text frame"); return
        }
        print("[measure] docList of 500 documents: \(text.utf8.count) B")
        #expect(text.utf8.count < 128 * 1024)
    }
}
