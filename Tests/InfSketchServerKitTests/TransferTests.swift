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
