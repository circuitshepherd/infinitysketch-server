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
        self.chunkCount = totalBytes == 0 ? 0 : (totalBytes - 1) / chunkSize + 1
    }

    /// A decoded descriptor is attacker-controlled input; the reassembler
    /// only opens transfers whose fields are self-consistent.
    var isSelfConsistent: Bool {
        guard totalBytes >= 0, chunkSize > 0 else { return false }
        return chunkCount == (totalBytes == 0 ? 0 : (totalBytes - 1) / chunkSize + 1)
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

/// end/abort control extracted from a wire message.
public enum TransferControl: Equatable, Sendable {
    case end(UInt32)
    case abort(UInt32, reason: String)
}

/// A wire message that can carry one bulk byte field. Adopted by both
/// ClientMessage and ServerMessage so the sender/reassembler work for
/// either direction of the socket.
public protocol TransferCarrying: Sendable {
    /// Inline bulk bytes the sender may externalize into a chunked transfer;
    /// nil when the message has no bulk field (or it is already a descriptor).
    var bulkBytes: Data? { get }
    func replacingBulk(with descriptor: TransferDescriptor) -> Self
    /// Descriptor when this received message announces a transfer.
    var openingDescriptor: TransferDescriptor? { get }
    func resolvingBulk(with bytes: Data) -> Self
    var transferControl: TransferControl? { get }
    static func makeTransferEnd(transferId: UInt32) -> Self
    init(jsonText: String) throws
    func jsonText() throws -> String
}

/// Sender-side expansion: one semantic message → one or more wire frames.
/// Owned by a single serialized writer (an actor); not thread-safe on its own.
public struct TransferSender<Message: TransferCarrying>: Sendable {
    public let inlineLimit: Int
    public let chunkSize: Int
    private var nextTransferId: UInt32 = 0

    public init(inlineLimit: Int, chunkSize: Int) {
        self.inlineLimit = inlineLimit
        self.chunkSize = chunkSize
    }

    public mutating func frames(for message: Message) throws -> [WireFrame] {
        guard let bytes = message.bulkBytes, bytes.count > inlineLimit else {
            return [.text(try message.jsonText())]
        }
        let descriptor = TransferDescriptor(
            transferId: nextTransferId, totalBytes: bytes.count, chunkSize: chunkSize)
        nextTransferId &+= 1
        var frames: [WireFrame] = []
        frames.reserveCapacity(descriptor.chunkCount + 2)
        frames.append(.text(try message.replacingBulk(with: descriptor).jsonText()))
        for index in 0..<descriptor.chunkCount {
            let start = bytes.startIndex + index * chunkSize
            let end = Swift.min(start + chunkSize, bytes.endIndex)
            frames.append(.binary(ChunkFraming.encode(
                transferId: descriptor.transferId, index: UInt32(index), payload: bytes[start..<end])))
        }
        frames.append(.text(try Message.makeTransferEnd(transferId: descriptor.transferId).jsonText()))
        return frames
    }
}

/// Receiver-side state machine. Feed every incoming frame; complete semantic
/// messages come out (bulk resolved to inline bytes). Throws TransferWireError
/// for connection-fatal violations; rethrows DecodingError for malformed JSON
/// (per-message severity — the connection survives).
public struct TransferReassembler<Message: TransferCarrying>: Sendable {
    private struct Pending {
        let descriptor: TransferDescriptor
        let owner: Message
        var buffer: Data
        var nextIndex: UInt32 = 0
        var isComplete: Bool { Int(nextIndex) == descriptor.chunkCount }
    }
    private var pending: Pending?

    public init() {}

    public mutating func consume(_ frame: WireFrame) throws -> Message? {
        switch frame {
        case .text(let text): return try consumeText(text)
        case .binary(let data): return try consumeBinary(data)
        }
    }

    private mutating func consumeText(_ text: String) throws -> Message? {
        let message = try Message(jsonText: text)
        if let control = message.transferControl {
            guard let current = pending else { throw TransferWireError.controlWithoutTransfer }
            switch control {
            case .end(let id):
                guard id == current.descriptor.transferId else {
                    throw TransferWireError.wrongTransferId(expected: current.descriptor.transferId, got: id)
                }
                guard current.isComplete else { throw TransferWireError.endBeforeComplete }
                pending = nil
                return current.owner.resolvingBulk(with: current.buffer)
            case .abort(let id, _):
                guard id == current.descriptor.transferId else {
                    throw TransferWireError.wrongTransferId(expected: current.descriptor.transferId, got: id)
                }
                pending = nil   // owner voided
                return nil
            }
        }
        if let descriptor = message.openingDescriptor {
            guard pending == nil else { throw TransferWireError.transferAlreadyInFlight }
            guard descriptor.isSelfConsistent else { throw TransferWireError.invalidDescriptor }
            var buffer = Data()
            // Pre-size is only an optimization hint; Data grows amortized
            // beyond this clamp, so a self-consistent but absurd totalBytes
            // (e.g. Int.max) can't trap the allocator. Actual memory use is
            // bounded by the bytes genuinely received via consumeBinary.
            buffer.reserveCapacity(min(descriptor.totalBytes, 16 * 1024 * 1024))
            pending = Pending(descriptor: descriptor, owner: message, buffer: buffer)
            return nil
        }
        return message   // ordinary / interleaved message passes straight through
    }

    private mutating func consumeBinary(_ data: Data) throws -> Message? {
        let chunk = try ChunkFraming.decode(data)
        // Read only the cheap value fields through the optional — never bind a
        // second copy of `pending` (which owns the accumulated `Data` buffer).
        // Holding a second copy across the mutation below defeats Data's
        // uniqueness check and forces a full-buffer memcpy on every chunk.
        guard let descriptor = pending?.descriptor, let nextIndex = pending?.nextIndex else {
            throw TransferWireError.chunkWithoutTransfer
        }
        guard chunk.transferId == descriptor.transferId else {
            throw TransferWireError.wrongTransferId(expected: descriptor.transferId, got: chunk.transferId)
        }
        guard Int(nextIndex) < descriptor.chunkCount else { throw TransferWireError.unexpectedChunk }
        guard chunk.index == nextIndex else {
            throw TransferWireError.nonContiguousChunk(expected: nextIndex, got: chunk.index)
        }
        let expected = descriptor.expectedChunkSize(at: Int(chunk.index))
        guard chunk.payload.count == expected else {
            throw TransferWireError.wrongChunkSize(expected: expected, got: chunk.payload.count)
        }
        pending!.buffer.append(chunk.payload)   // in-place: single live reference, no CoW copy
        pending!.nextIndex += 1
        return nil
    }
}
