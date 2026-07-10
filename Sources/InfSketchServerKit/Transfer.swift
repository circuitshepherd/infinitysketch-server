import Foundation

/// A frame on the WebSocket, direction-neutral. The adapter maps this to
/// FlyingFox's WSMessage; the demo client maps it to URLSessionWebSocketTask.Message.
public enum WireFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// Announces a chunked transfer; carried by the owning message in place of
/// its inline bulk bytes. See the 2026-07-10 WS chunked transfer design spec.
public struct TransferDescriptor: Codable, Equatable, Sendable {
    public var transferId: UInt32
    public var totalBytes: Int
    public var chunkSize: Int
    public var chunkCount: Int

    public init(transferId: UInt32, totalBytes: Int, chunkSize: Int) {
        precondition(totalBytes >= 0 && chunkSize > 0)
        self.transferId = transferId
        self.totalBytes = totalBytes
        self.chunkSize = chunkSize
        self.chunkCount = totalBytes == 0 ? 0 : (totalBytes + chunkSize - 1) / chunkSize
    }

    /// A decoded descriptor is attacker-controlled input; the reassembler
    /// only opens transfers whose fields are self-consistent.
    var isSelfConsistent: Bool {
        guard totalBytes >= 0, chunkSize > 0 else { return false }
        return chunkCount == (totalBytes == 0 ? 0 : (totalBytes + chunkSize - 1) / chunkSize)
    }

    /// Exact byte size chunk `index` must have.
    func expectedChunkSize(at index: Int) -> Int {
        index == chunkCount - 1 ? totalBytes - chunkSize * (chunkCount - 1) : chunkSize
    }
}

/// Transfer-state violations. Connection-fatal: the receiver sends
/// `error {reason}` and closes — positional stream state can't be trusted
/// once violated. (Malformed JSON stays per-message, as in v0.)
public enum TransferWireError: Error, Equatable {
    case unknownBinaryKind(UInt8)
    case truncatedChunkHeader
    case chunkWithoutTransfer
    case transferAlreadyInFlight
    case nonContiguousChunk(expected: UInt32, got: UInt32)
    case wrongChunkSize(expected: Int, got: Int)
    case unexpectedChunk
    case endBeforeComplete
    case wrongTransferId(expected: UInt32, got: UInt32)
    case controlWithoutTransfer
    case invalidDescriptor
}

/// Binary chunk message framing:
/// `[kind: UInt8 = 1][transferId: UInt32 BE][chunkIndex: UInt32 BE]` + payload bytes.
/// The leading kind byte future-proofs binary framing; only `1 = chunk` exists.
public enum ChunkFraming {
    public static let chunkKind: UInt8 = 1
    public static let headerSize = 9

    public static func encode(transferId: UInt32, index: UInt32, payload: Data) -> Data {
        var frame = Data(capacity: headerSize + payload.count)
        frame.append(chunkKind)
        withUnsafeBytes(of: transferId.bigEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: index.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Returned payload is a slice sharing the input's storage.
    public static func decode(_ frame: Data) throws -> (transferId: UInt32, index: UInt32, payload: Data) {
        guard let kind = frame.first else { throw TransferWireError.truncatedChunkHeader }
        guard kind == chunkKind else { throw TransferWireError.unknownBinaryKind(kind) }
        guard frame.count >= headerSize else { throw TransferWireError.truncatedChunkHeader }
        let header = [UInt8](frame.prefix(headerSize))
        let transferId = UInt32(header[1]) << 24 | UInt32(header[2]) << 16
            | UInt32(header[3]) << 8 | UInt32(header[4])
        let index = UInt32(header[5]) << 24 | UInt32(header[6]) << 16
            | UInt32(header[7]) << 8 | UInt32(header[8])
        return (transferId, index, frame.dropFirst(headerSize))
    }
}
