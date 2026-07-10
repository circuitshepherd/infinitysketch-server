import Foundation
import Testing
@testable import InfSketchServerKit

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
    @Test func bulklessMessageStaysSingleTextFrame() throws {
        var sender = TransferSender<ServerMessage>(inlineLimit: 0, chunkSize: 8)
        let frames = try sender.frames(for: .helloAck(protocolVersion: 1))
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
    @Test func transferIdsIncrementPerTransfer() throws {
        var sender = TransferSender<ClientMessage>(inlineLimit: 0, chunkSize: 8)
        func announcedId(_ frames: [WireFrame]) throws -> UInt32? {
            guard case .text(let json) = frames.first,
                  case .op(_, _, let payload) = try ClientMessage(jsonText: json),
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
