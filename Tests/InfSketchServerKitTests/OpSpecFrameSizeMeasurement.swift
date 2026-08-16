import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire
import MCP

/// MEASUREMENT (not a gate): how big the single WebSocket TEXT frame gets when an op-spec carries
/// whole documents, as `undo_last_edit`'s `revertMerge` does.
///
/// `TransferSender` chunks exactly ONE field — `bulkBytes`, which for `strokeOpRequest` is the
/// `payload` and nothing else. The `spec` rides inline in the descriptor's JSON text frame however
/// large it is, and `revertMerge` puts TWO whole documents in it (base64 inside the spec, then
/// base64 AGAIN when `JSONEncoder` encodes `spec: Data` into the message).
///
/// The receiving end is `URLSessionWebSocketTask`, whose `maximumMessageSize` defaults to 1 MiB and
/// which `MirrorTransport` never raises.
@Suite struct OpSpecFrameSizeMeasurement {

    /// The exact spec `MCPAdapter.revertMerge` builds.
    private func revertMergeSpec(base: Data, theirs: Data) throws -> Data {
        try JSONEncoder().encode(Value.object([
            "op": .string("revertMerge"),
            "base": .string(base.base64EncodedString()),
            "theirs": .string(theirs.base64EncodedString()),
        ]))
    }

    /// The frames the server would actually put on the socket for that request.
    private func frames(specSize spec: Data, docBytes: Data) throws -> [WireFrame] {
        var sender = TransferSender<ServerMessage>(inlineLimit: 256 * 1024, chunkSize: 512 * 1024)
        return try sender.frames(for: .strokeOpRequest(
            requestId: 1, docId: "Untitled 22", payload: .inline(docBytes), spec: spec,
            payloadKind: nil))
    }

    private func largestTextFrame(_ frames: [WireFrame]) -> Int {
        frames.reduce(0) { best, frame in
            if case .text(let s) = frame { return Swift.max(best, s.utf8.count) }
            return best
        }
    }

    @Test func revertMergeSpecOverflowsTheClientsOneMebibyteMessageLimit() throws {
        let limit = 1024 * 1024   // URLSessionWebSocketTask.maximumMessageSize default, measured.

        // The size of the document this was reported on (`Untitled 22`, 1_176_673 B on disk).
        for docSize in [64 * 1024, 256 * 1024, 512 * 1024, 1_176_673] {
            let doc = Data(repeating: 0x41, count: docSize)
            let spec = try revertMergeSpec(base: doc, theirs: doc)
            let produced = try frames(specSize: spec, docBytes: doc)
            let biggest = largestTextFrame(produced)
            print("doc \(docSize) B -> spec \(spec.count) B -> largest text frame \(biggest) B "
                  + "(\(String(format: "%.2f", Double(biggest) / Double(limit)))x the 1 MiB limit), "
                  + "\(produced.count) frame(s)")
        }

        // The reported document, at the size it actually is.
        let doc = Data(repeating: 0x41, count: 1_176_673)
        let spec = try revertMergeSpec(base: doc, theirs: doc)
        let biggest = largestTextFrame(try frames(specSize: spec, docBytes: doc))
        #expect(biggest > limit,
                "the spec text frame must exceed the client's 1 MiB receive limit for this to be the bug")
    }

    /// The payload IS chunked — so the request's own document is not the problem, only the spec is.
    @Test func thePayloadIsChunkedButTheSpecIsNot() throws {
        let doc = Data(repeating: 0x41, count: 1_176_673)
        let tinySpec = try JSONEncoder().encode(Value.object(["op": .string("delete")]))
        let produced = try frames(specSize: tinySpec, docBytes: doc)
        let biggest = largestTextFrame(produced)
        print("same document as PAYLOAD with a tiny spec -> largest text frame \(biggest) B, "
              + "\(produced.count) frames")
        #expect(biggest < 1024 * 1024)
    }
}
