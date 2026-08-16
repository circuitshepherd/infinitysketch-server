#if URLSESSION_WEBSOCKET
// `URLSessionWebSocketTask` exists only on Apple platforms (see `Package.swift`). The whole point
// of this suite is a client configured EXACTLY as `MirrorTransport` configures its socket, so
// there is nothing to substitute on Linux — the arithmetic half lives in
// `OpSpecFrameSizeMeasurement`, which is platform-free and runs everywhere.
import Foundation
import Testing
@testable import InfSketchServerKit
import InfSketchWire
import MCP

/// REPRODUCTION of the `undo_last_edit` hang (`deviceTimeout` on every attempt against a document
/// of any real size).
///
/// The device end of the wire is a `URLSessionWebSocketTask` whose `maximumMessageSize` defaults to
/// 1 MiB and which `MirrorTransport` never raises. The client here is configured EXACTLY as
/// `MirrorTransport.init` configures its socket, so what it does is what the app does.
///
/// `revertMerge` puts TWO whole documents in the op-SPEC, and `TransferSender` chunks only
/// `bulkBytes` (the request's `payload`) — never the spec. So the spec rides as one text frame of
/// ~3.56x the document size, and above a ~288 KiB document the device cannot receive it at all.
/// `.serialized` because each test here stands up a REAL server and a REAL socket, and Swift
/// Testing would otherwise run all four at once. Measured: with them parallel, the full suite
/// failed 2 runs in 7 on `subscribedSessionReceivesUpdateNotificationOnWrite` — an SSE-timing test
/// that this file does not touch and that passes 6/6 alone; serialized, and with this suite
/// removed entirely, the full suite passed 4/4 both ways. The load was the variable.
@Suite(.serialized) struct LargeOpSpecFrameRepro {

    private func startServer() async throws -> (InfSketchServer, UInt16, Task<Void, any Error>) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-spec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = InfSketchServer(port: 0, docsDirectory: dir, config: SessionConfig())
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        return (server, port, task)
    }

    /// What the device did with the request, as seen from the device side.
    private enum DeviceOutcome: Sendable, Equatable {
        case received(specBytes: Int)
        /// The payload was an `OpSpecBundle`; the spec is what it restores to.
        case receivedBundle(restoredSpecBytes: Int, partNames: [String], primaryBytes: Int)
        case receiveFailed(String)
    }

    /// A stand-in device: the same socket type and the same default limits as `MirrorTransport`.
    private func runFakeDevice(port: UInt16, maximumMessageSize: Int? = nil,
                              ready: @escaping @Sendable () -> Void)
        async throws -> DeviceOutcome
    {
        let ws = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        // Deliberately NOT setting `maximumMessageSize` by default — MirrorTransport does not
        // either, and the default is what this test is about.
        #expect(ws.maximumMessageSize == 1024 * 1024)
        if let maximumMessageSize { ws.maximumMessageSize = maximumMessageSize }
        ws.resume()
        defer { ws.cancel() }

        try await ws.send(.string(ClientMessage.hello(
            protocolVersion: WireProtocol.version,
            capabilities: ["mergeDocs"], deviceId: "fake-device").jsonText()))
        _ = try await ws.receive()   // helloAck
        ready()

        // The real client's reassembler, so a chunked payload arrives resolved to inline bytes
        // exactly as MirrorTransport sees it.
        var reassembler = TransferReassembler<ServerMessage>()
        while true {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await ws.receive()
            } catch {
                return .receiveFailed("\(error)")
            }
            let wireFrame: WireFrame
            switch frame {
            case .string(let text): wireFrame = .text(text)
            case .data(let data): wireFrame = .binary(data)
            @unknown default: continue
            }
            guard let message = (try? reassembler.consume(wireFrame)) ?? nil else { continue }
            if case .strokeOpRequest(_, _, let payload, let spec, let kind) = message {
                guard kind == OpSpecBundleWire.kind, let bytes = payload.inlineData,
                      let bundle = try? OpSpecBundle(encoded: bytes) else {
                    return .received(specBytes: spec.count)
                }
                let restored = (try? bundle.specRestoringParts(into: spec)) ?? Data()
                return .receivedBundle(
                    restoredSpecBytes: restored.count,
                    partNames: bundle.parts.keys.map(\.rawValue).sorted(),
                    primaryBytes: bundle.primary.count)
            }
        }
    }

    /// Drives one relayed op of a chosen spec size and reports what the device end saw.
    private func relay(specPayloadBytes: Int, deviceMaximumMessageSize: Int? = nil)
        async throws -> DeviceOutcome
    {
        let (server, port, serverTask) = try await startServer()
        defer { serverTask.cancel() }

        let gate = Gate()
        let device = Task {
            try await runFakeDevice(port: port, maximumMessageSize: deviceMaximumMessageSize,
                                    ready: { gate.open() })
        }
        await gate.wait()
        // The hello has to be registered with the broker before the request is made.
        try await Task.sleep(for: .milliseconds(200))

        let doc = Data(repeating: 0x41, count: specPayloadBytes / 2)
        let spec = try JSONEncoder().encode(Value.object([
            "op": .string("revertMerge"),
            "base": .string(doc.base64EncodedString()),
            "theirs": .string(doc.base64EncodedString()),
        ]))
        // Fire and forget: the point is what the DEVICE sees, and the broker's own 20 s
        // `deviceTimeout` is the symptom being explained, not something to wait out here.
        Task {
            _ = try? await server.deviceCommandBroker.requestStrokeOp(
                docId: "probe", docBytes: Data(repeating: 0x42, count: 1024), spec: spec,
                capability: "mergeDocs")
        }
        return try await device.value
    }

    /// A small op-spec arrives, so the relay path itself is sound.
    @Test func aSmallOpSpecReachesTheDevice() async throws {
        let outcome = try await relay(specPayloadBytes: 64 * 1024)
        print("small spec -> \(outcome)")
        guard case .received = outcome else {
            Issue.record("a small spec must reach the device, got \(outcome)")
            return
        }
    }

    /// The reported case: `Untitled 22` is 1_176_673 B on disk, and `revertMerge` sends two copies
    /// of it in the spec. The device's receive FAILS — so no reply is ever sent, and the broker
    /// answers `deviceTimeout` with nothing wrong at either end but the frame size.
    @Test func aDocumentSizedOpSpecKillsTheDeviceConnection() async throws {
        let outcome = try await relay(specPayloadBytes: 2 * 1_176_673)
        print("document-sized spec -> \(outcome)")
        guard case .receiveFailed(let reason) = outcome else {
            Issue.record("expected the device receive to fail, got \(outcome)")
            return
        }
        print("device receive failed with: \(reason)")
    }

    /// CONTROL: the same request, to a device that raised its own receive limit. Nothing else
    /// changes — so this pins that the frame size really was the whole story.
    @Test func raisingTheDevicesReceiveLimitDeliversTheSameRequest() async throws {
        let outcome = try await relay(specPayloadBytes: 2 * 1_176_673,
                                      deviceMaximumMessageSize: 64 * 1024 * 1024)
        print("document-sized spec, 64 MiB device limit -> \(outcome)")
        guard case .received = outcome else {
            Issue.record("expected the request to arrive once the limit was raised, got \(outcome)")
            return
        }
    }

    /// THE FIX, through the real `requestStrokeOp` path: the two documents ride the payload, so
    /// every frame stays under the chunk size and the device — at its ORDINARY 1 MiB limit —
    /// receives the request and restores the identical spec.
    @Test func specPartsDeliverTwoWholeDocumentsAtTheDefaultLimit() async throws {
        let (server, port, serverTask) = try await startServer()
        defer { serverTask.cancel() }

        let gate = Gate()
        let device = Task { try await runFakeDevice(port: port, ready: { gate.open() }) }
        await gate.wait()
        try await Task.sleep(for: .milliseconds(200))

        let base = Data(repeating: 0x41, count: 1_176_673)
        let theirs = Data(repeating: 0x42, count: 1_176_673)
        let spec = try JSONEncoder().encode(Value.object(["op": .string("revertMerge")]))
        Task {
            _ = try? await server.deviceCommandBroker.requestStrokeOp(
                docId: "probe", docBytes: Data(repeating: 0x43, count: 4096), spec: spec,
                capability: "mergeDocs", specParts: [.base: base, .theirs: theirs])
        }

        let outcome = try await device.value
        print("revertMerge via specParts, default 1 MiB device limit -> \(outcome)")
        guard case .receivedBundle(let restoredSpecBytes, let partNames, _) = outcome else {
            Issue.record("expected a bundle to arrive at the default limit, got \(outcome)")
            return
        }
        #expect(partNames == ["base", "theirs"])
        // The restored spec is the pre-fix spec: op + two base64 documents.
        #expect(restoredSpecBytes > 3_100_000)
    }
}

/// One-shot readiness signal (the fake device has finished its handshake).
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { self.semaphore.wait(); c.resume() }
        }
    }
}

#endif   // URLSESSION_WEBSOCKET — keep this the LAST line of the file
