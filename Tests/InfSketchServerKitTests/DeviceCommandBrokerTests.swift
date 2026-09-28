import Foundation
import Crypto
import Testing
import InfSketchWire
@testable import InfSketchServerKit

/// Tiny test helper: captures ServerMessages handed to a `register(...)`
/// send closure (which itself is synchronous, so callers `Task { await
/// sent.set(msg) }` into it) and lets the test await the first one with a
/// bounded poll — mirrors the `for _ in 0..<50 { ...; try await
/// Task.sleep(for: .milliseconds(10)) }` idiom used throughout
/// WSAdapterTests for awaiting async effects.
private actor SentBox {
    private var messages: [ServerMessage] = []

    func set(_ message: ServerMessage) {
        messages.append(message)
    }

    func all() -> [ServerMessage] { messages }

    /// Returns the first captured message, polling briefly if none has
    /// landed yet. `nil` if nothing arrives within the budget.
    func awaitMessage() async -> ServerMessage? {
        for _ in 0..<50 {
            if let first = messages.first { return first }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return messages.first
    }
}

@Suite struct DeviceCommandBrokerTests {
    @Test func noConnectionThrowsNoDevice() async {
        let broker = DeviceCommandBroker()
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.noDeviceAvailable) {
            _ = try await broker.requestCreation(docId: "D")
        }
    }

    @Test func successRoundTrip() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        async let result = broker.requestCreation(docId: "D")
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await result == Data("T".utf8))
    }

    @Test func failureReplyThrowsDeviceFailed() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        // `#expect(throws:)`'s closure can't capture an `async let`, so run
        // the call on a plain Task (a Sendable value, capturable normally).
        let task = Task { try await broker.requestCreation(docId: "D") }
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: nil, failureReason: "boom")
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("boom")) {
            _ = try await task.value
        }
    }

    @Test func timeoutThrowsDeviceTimeout() async {
        let broker = DeviceCommandBroker(createTimeout: .milliseconds(50))
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { _ in }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestCreation(docId: "D")
        }
    }

    @Test func concurrentSameDocIdThrowsInProgress() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        async let first: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }

        // Second request for the same docId while the first is still in
        // flight must be rejected immediately, without waiting for a reply
        // or timeout.
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.requestInFlight) {
            _ = try await broker.requestCreation(docId: "D")
        }

        // Release the first request so the test doesn't leak a pending Task.
        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await first == Data("T".utf8))
    }

    @Test func lateReplyIsDropped() async {
        let broker = DeviceCommandBroker(createTimeout: .milliseconds(50))
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestCreation(docId: "D")
        }
        let request = await sent.awaitMessage()
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }

        // The request has already timed out (and its entry been cleaned
        // up); a late reply for the same requestId must be a harmless no-op
        // — no crash, and it must not resurrect/resume anything.
        await broker.handleReply(requestId: rid, bytes: Data("late".utf8), failureReason: nil)
    }

    @Test func unregisterFailsPendingImmediately() async {
        let broker = DeviceCommandBroker(createTimeout: .seconds(10))
        let connectionId = UUID()
        let sent = SentBox()
        await broker.register(connectionId: connectionId, capabilities: ["createDoc"]) { msg in
            Task { await sent.set(msg) }
        }
        let task = Task { try await broker.requestCreation(docId: "D") }
        // Wait for the REQUEST TO HAVE BEEN SENT rather than for 20 ms of wall
        // clock. `performRequest` registers the continuation BEFORE it sends
        // (deliberately — see its comment), so a sent message proves there is
        // a pending entry for `unregister` to fail. The fixed sleep did not
        // prove it: on a starved runner `requestCreation` had not yet run, so
        // `unregister` found nothing to fail and the request then threw
        // `noDeviceAvailable` instead of `deviceDisconnected` (a clean close is not a
        // timeout: v12 names it for what it is).
        _ = await sent.awaitMessage()
        await broker.unregister(connectionId: connectionId)
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceDisconnected) {
            _ = try await task.value
        }
    }

    @Test func mostRecentConnectionWins() async throws {
        let broker = DeviceCommandBroker()
        let sentA = SentBox()
        let sentB = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sentB.set(msg) } }
        async let result: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sentB.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }

        // A's box must never receive the request.
        #expect(await sentA.awaitMessage() == nil)

        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await result == Data("T".utf8))
    }

    // MARK: - Device choice by activity, and one failover (review finding 21)

    /// "Most recently CONNECTED" chose an iPad that connected later and then went to sleep over
    /// a Mac that was live all along; every agent call waited out the timeout. The device that
    /// last SPOKE is the better guess.
    @Test func theMostRecentlyActiveConnectionWins() async throws {
        let broker = DeviceCommandBroker()
        let sentA = SentBox()
        let sentB = SentBox()
        let a = UUID()
        await broker.register(connectionId: a, capabilities: ["createDoc"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sentB.set(msg) } }
        await broker.noteActivity(connectionId: a)
        async let result: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sentA.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        #expect(await sentB.awaitMessage() == nil)
        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await result == Data("T".utf8))
    }

    /// A pure bytes-in/bytes-out op that times out on one device is tried once on the next.
    @Test func aTimedOutOpIsRetriedOnceOnAnotherDevice() async throws {
        let broker = DeviceCommandBroker(strokeOpTimeout: .milliseconds(100))
        let sentA = SentBox()
        let sentB = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in Task { await sentB.set(msg) } }
        let task = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data()) }
        // B (newest) is asked first and never answers; A gets the retry.
        #expect(await sentB.awaitMessage() != nil)
        var retried: ServerMessage?
        for _ in 0..<100 where retried == nil {
            retried = await sentA.all().first
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .strokeOpRequest(let rid, "D", _, _, _, _)? = retried else {
            Issue.record("the op must be retried on the other device, got \(String(describing: retried))"); return
        }
        await broker.handleReply(requestId: rid, bytes: Data("ok".utf8), failureReason: nil)
        #expect(try await task.value.bytes == Data("ok".utf8))
    }

    /// Selection ops act on live state on the device: a device that was merely slow may still
    /// apply one, so a retry elsewhere could apply it twice. Never retried.
    @Test func aLiveSelectionOpIsNotRetried() async throws {
        let broker = DeviceCommandBroker(strokeOpTimeout: .milliseconds(100))
        let sentA = SentBox()
        let sentB = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["controlSelection"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: UUID(), capabilities: ["controlSelection"]) { msg in Task { await sentB.set(msg) } }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data(),
                                                 capability: "controlSelection")
        }
        #expect(await sentA.all().isEmpty, "a live-state op must not be sent to a second device")
    }

    // MARK: - Routing to the device with the document open (review finding 20)

    /// A live-state op goes to the device that has the document OPEN, even when another device
    /// spoke more recently: the selection exists only on the first.
    @Test func aLiveStateOpGoesToTheDeviceWithTheDocumentOpen() async throws {
        let broker = DeviceCommandBroker()
        let sentOpen = SentBox()
        let sentOther = SentBox()
        let open = UUID()
        await broker.register(connectionId: open, capabilities: ["controlSelection"]) { msg in Task { await sentOpen.set(msg) } }
        let other = UUID()
        await broker.register(connectionId: other, capabilities: ["controlSelection"]) { msg in Task { await sentOther.set(msg) } }
        await broker.noteActivity(connectionId: other)   // the other one is newest AND most active
        await broker.setSubscriberLookup { docId in docId == "D" ? [open] : [] }
        let task = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data(),
                                                           capability: "controlSelection") }
        guard case .strokeOpRequest(let rid, "D", _, _, _, _)? = await sentOpen.awaitMessage() else {
            Issue.record("the op must reach the device with the document open"); return
        }
        await broker.handleReply(requestId: rid, bytes: nil, meta: Data("{}".utf8), failureReason: nil)
        _ = try await task.value
        #expect(await sentOther.all().isEmpty)
    }

    /// No capable device has it open: a distinct error, and nothing is sent anywhere.
    @Test func aLiveStateOpWithTheDocumentOpenNowhereIsRefused() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["controlSelection"]) { msg in Task { await sent.set(msg) } }
        await broker.setSubscriberLookup { _ in [] }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.documentNotOpen) {
            _ = try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data(),
                                                 capability: "controlSelection")
        }
        #expect(await sent.all().isEmpty)
    }

    /// An op on bytes prefers the device with the document open — its pen is the one an omitted
    /// colour inherits, its viewport the one a render reports — and falls back to any device.
    @Test func anOpOnBytesPrefersTheOpenDeviceAndFallsBackToAny() async throws {
        let broker = DeviceCommandBroker()
        let sentOpen = SentBox()
        let sentOther = SentBox()
        let open = UUID()
        await broker.register(connectionId: open, capabilities: ["authorStrokes"]) { msg in Task { await sentOpen.set(msg) } }
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in Task { await sentOther.set(msg) } }
        await broker.setSubscriberLookup { docId in docId == "D" ? [open] : [] }

        let onOpen = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data()) }
        guard case .strokeOpRequest(let rid, "D", _, _, _, _)? = await sentOpen.awaitMessage() else {
            Issue.record("preferred the device with the document open"); return
        }
        await broker.handleReply(requestId: rid, bytes: Data("x".utf8), failureReason: nil)
        _ = try await onOpen.value

        let elsewhere = Task { try await broker.requestStrokeOp(docId: "E", docBytes: Data(), spec: Data()) }
        guard case .strokeOpRequest(let rid2, "E", _, _, _, _)? = await sentOther.awaitMessage() else {
            Issue.record("a document open nowhere still goes to a capable device (the newest)"); return
        }
        await broker.handleReply(requestId: rid2, bytes: Data("y".utf8), failureReason: nil)
        #expect(try await elsewhere.value.bytes == Data("y".utf8))
    }

    /// Every op request carries a deadline: its timeout plus the skew allowance, in Unix ms.
    @Test func anOpRequestCarriesItsDeadline() async throws {
        let broker = DeviceCommandBroker(strokeOpTimeout: .seconds(20))
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["controlSelection"]) { msg in Task { await sent.set(msg) } }
        let before = Int(Date().timeIntervalSince1970 * 1000)
        let task = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data(),
                                                           capability: "controlSelection") }
        guard case .strokeOpRequest(let rid, _, _, _, _, let notAfter)? = await sent.awaitMessage(),
              let notAfter else {
            Issue.record("the request must carry notAfter"); return
        }
        let after = Int(Date().timeIntervalSince1970 * 1000)
        // The allowance is 2 s: the device judges the deadline in the SERVER's clock
        // (`ServerClock`), so it only has to cover the hello's one-way latency, not clock skew.
        #expect(notAfter >= before + 22_000 && notAfter <= after + 22_000)
        await broker.handleReply(requestId: rid, bytes: nil, meta: Data("{}".utf8), failureReason: nil)
        _ = try await task.value
    }

    // MARK: - Several devices with the document open (round 6, item 3)

    /// Waits for the first strokeOpRequest a box receives.
    private static func awaitRequest(_ box: SentBox) async -> (UInt32, BulkPayload)? {
        for _ in 0..<100 {
            for message in await box.all() {
                if case .strokeOpRequest(let rid, _, let payload, _, _, _) = message { return (rid, payload) }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Two devices have the document open; the one asked first has nothing selected. The
    /// selection may be on the other, so it is asked too — a device without a selection refuses
    /// without changing anything, so asking the next is safe.
    @Test func aNothingSelectedAnswerIsCheckedOnTheOtherOpenDevice() async throws {
        let broker = DeviceCommandBroker()
        let sentA = SentBox(), sentB = SentBox()
        let a = UUID(), b = UUID()
        await broker.register(connectionId: a, capabilities: ["controlSelection"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: b, capabilities: ["controlSelection"]) { msg in Task { await sentB.set(msg) } }
        await broker.setSubscriberLookup { _ in [a, b] }
        let task = Task { try await broker.requestStrokeOp(
            docId: "D", docBytes: Data(), spec: Data(#"{"op":"transformSelection"}"#.utf8),
            capability: "controlSelection") }
        let first = try #require(await Self.awaitRequest(sentB))
        await broker.handleReply(requestId: first.0, bytes: nil, failureReason: "noSelectionActive")
        let second = try #require(await Self.awaitRequest(sentA), "the other open device must be asked")
        await broker.handleReply(requestId: second.0, bytes: nil, meta: Data("{}".utf8), failureReason: nil)
        #expect(try await task.value.meta == Data("{}".utf8))
    }

    /// Only when EVERY open device says nothing is selected is that the answer.
    @Test func nothingSelectedOnEveryOpenDeviceIsTheAnswer() async throws {
        let broker = DeviceCommandBroker()
        let sentA = SentBox(), sentB = SentBox()
        let a = UUID(), b = UUID()
        await broker.register(connectionId: a, capabilities: ["controlSelection"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: b, capabilities: ["controlSelection"]) { msg in Task { await sentB.set(msg) } }
        await broker.setSubscriberLookup { _ in [a, b] }
        let task = Task { try await broker.requestStrokeOp(
            docId: "D", docBytes: Data(), spec: Data(#"{"op":"deleteSelection"}"#.utf8),
            capability: "controlSelection") }
        let first = try #require(await Self.awaitRequest(sentB))
        await broker.handleReply(requestId: first.0, bytes: nil, failureReason: "noSelectionActive")
        let second = try #require(await Self.awaitRequest(sentA))
        await broker.handleReply(requestId: second.0, bytes: nil, failureReason: "noSelectionActive")
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("noSelectionActive")) {
            _ = try await task.value
        }
    }

    /// Any other refusal (a gesture in progress, a stale `expect`) is the device that HAS the
    /// selection speaking, so it is final.
    @Test func aUserBusyAnswerIsNotRetried() async throws {
        let broker = DeviceCommandBroker()
        let sentA = SentBox(), sentB = SentBox()
        let a = UUID(), b = UUID()
        await broker.register(connectionId: a, capabilities: ["controlSelection"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: b, capabilities: ["controlSelection"]) { msg in Task { await sentB.set(msg) } }
        await broker.setSubscriberLookup { _ in [a, b] }
        let task = Task { try await broker.requestStrokeOp(
            docId: "D", docBytes: Data(), spec: Data(#"{"op":"transformSelection"}"#.utf8),
            capability: "controlSelection") }
        let first = try #require(await Self.awaitRequest(sentB))
        await broker.handleReply(requestId: first.0, bytes: nil, failureReason: "userBusy")
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("userBusy")) {
            _ = try await task.value
        }
        #expect(await sentA.all().isEmpty)
    }

    /// `get_selection` answers "nothing selected" as a SUCCESS (`active: false`), so it is asked
    /// of the next open device too, and a device with a selection wins.
    @Test func getSelectionFindsTheSelectionOnTheOtherOpenDevice() async throws {
        let broker = DeviceCommandBroker()
        let sentA = SentBox(), sentB = SentBox()
        let a = UUID(), b = UUID()
        await broker.register(connectionId: a, capabilities: ["controlSelection"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: b, capabilities: ["controlSelection"]) { msg in Task { await sentB.set(msg) } }
        await broker.setSubscriberLookup { _ in [a, b] }
        let task = Task { try await broker.requestStrokeOp(
            docId: "D", docBytes: Data(), spec: Data(#"{"op":"getSelection"}"#.utf8),
            capability: "controlSelection") }
        let first = try #require(await Self.awaitRequest(sentB))
        await broker.handleReply(requestId: first.0, bytes: nil,
                                 meta: Data(#"{"active":false,"sessionActive":false}"#.utf8), failureReason: nil)
        let second = try #require(await Self.awaitRequest(sentA))
        await broker.handleReply(requestId: second.0, bytes: nil,
                                 meta: Data(#"{"active":true,"sessionActive":true}"#.utf8), failureReason: nil)
        #expect(try await task.value.meta == Data(#"{"active":true,"sessionActive":true}"#.utf8))
    }

    /// A select op is NOT read-only, so an `active: false` answer (`select_all` on an empty
    /// document) is final — asking the other device would change ITS selection too.
    @Test func aSelectOpsInactiveAnswerIsFinal() async throws {
        let broker = DeviceCommandBroker()
        let sentA = SentBox(), sentB = SentBox()
        let a = UUID(), b = UUID()
        await broker.register(connectionId: a, capabilities: ["controlSelection"]) { msg in Task { await sentA.set(msg) } }
        await broker.register(connectionId: b, capabilities: ["controlSelection"]) { msg in Task { await sentB.set(msg) } }
        await broker.setSubscriberLookup { _ in [a, b] }
        let task = Task { try await broker.requestStrokeOp(
            docId: "D", docBytes: Data(), spec: Data(#"{"op":"selectAll"}"#.utf8),
            capability: "controlSelection") }
        let first = try #require(await Self.awaitRequest(sentB))
        await broker.handleReply(requestId: first.0, bytes: nil,
                                 meta: Data(#"{"active":false}"#.utf8), failureReason: nil)
        _ = try await task.value
        #expect(await sentA.all().isEmpty)
    }

    /// A live-selection op never reads the request's document (the device acts on its own live
    /// selection), so none is sent: a large document's upload would only eat the op's deadline.
    @Test func aSelectionOpSendsNoDocument() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["controlSelection", "blobOmission"]) { msg in Task { await sent.set(msg) } }
        let task = Task { try await broker.requestStrokeOp(
            docId: "D", docBytes: Data(repeating: 7, count: 4096),
            spec: Data(#"{"op":"getSelection"}"#.utf8), capability: "controlSelection") }
        let request = try #require(await Self.awaitRequest(sent))
        guard case .inline(let bytes) = request.1 else { Issue.record("expected inline"); return }
        #expect(bytes.isEmpty)
        await broker.handleReply(requestId: request.0, bytes: nil, meta: Data("{}".utf8), failureReason: nil)
        _ = try await task.value
    }

    // MARK: - A sleeping open device (round 6, item 6)

    /// The open device has been quiet longer than the keepalive interval while another capable
    /// device is awake: an op on bytes goes to the awake one rather than wait out a timeout.
    @Test func anOpOnBytesSkipsASleepingOpenDevice() async throws {
        let broker = DeviceCommandBroker(quietAfter: .milliseconds(50))
        let sentOpen = SentBox(), sentAwake = SentBox()
        let open = UUID(), awake = UUID()
        await broker.register(connectionId: open, capabilities: ["authorStrokes"]) { msg in Task { await sentOpen.set(msg) } }
        await broker.register(connectionId: awake, capabilities: ["authorStrokes"]) { msg in Task { await sentAwake.set(msg) } }
        await broker.setSubscriberLookup { _ in [open] }
        try await Task.sleep(for: .milliseconds(120))
        await broker.noteActivity(connectionId: awake)
        let task = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data()) }
        let request = try #require(await Self.awaitRequest(sentAwake), "the awake device must be asked")
        await broker.handleReply(requestId: request.0, bytes: Data("x".utf8), failureReason: nil)
        _ = try await task.value
        #expect(await sentOpen.all().isEmpty)
    }

    /// When every device is quiet, the open one is still the better guess.
    @Test func anOpOnBytesStillPrefersTheOpenDeviceWhenAllAreQuiet() async throws {
        let broker = DeviceCommandBroker(quietAfter: .milliseconds(50))
        let sentOpen = SentBox(), sentOther = SentBox()
        let open = UUID(), other = UUID()
        await broker.register(connectionId: open, capabilities: ["authorStrokes"]) { msg in Task { await sentOpen.set(msg) } }
        await broker.register(connectionId: other, capabilities: ["authorStrokes"]) { msg in Task { await sentOther.set(msg) } }
        await broker.setSubscriberLookup { _ in [open] }
        try await Task.sleep(for: .milliseconds(120))
        let task = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data()) }
        let request = try #require(await Self.awaitRequest(sentOpen))
        await broker.handleReply(requestId: request.0, bytes: Data("x".utf8), failureReason: nil)
        _ = try await task.value
        #expect(await sentOther.all().isEmpty)
    }

    @Test func retryAfterCompletionWorks() async throws {
        let broker = DeviceCommandBroker(createTimeout: .milliseconds(50))
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent.set(msg) } }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestCreation(docId: "D")
        }

        // The per-docId guard must have been cleaned up by the timeout path
        // — a fresh request for the same docId must proceed (not throw
        // .requestInFlight) and get its own new requestId sent.
        let sent2 = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { msg in Task { await sent2.set(msg) } }
        async let result: Data = broker.requestCreation(docId: "D")
        let request = try #require(await sent2.awaitMessage())
        guard case .createDocRequest(let rid, "D") = request else { Issue.record("wrong msg"); return }
        await broker.handleReply(requestId: rid, bytes: Data("T2".utf8), failureReason: nil)
        #expect(try await result == Data("T2".utf8))
    }

    // MARK: - requestStrokeOp (generalization, Task 2)

    @Test func strokeOpSuccessRoundTrip() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        let docBytes = Data("doc-bytes".utf8)
        let spec = Data("spec-bytes".utf8)
        async let result = broker.requestStrokeOp(docId: "D", docBytes: docBytes, spec: spec)
        let request = try #require(await sent.awaitMessage())
        guard case .strokeOpRequest(let rid, "D", .inline(let sentBytes), let sentSpec, _, _) = request else {
            Issue.record("wrong msg: \(request)"); return
        }
        #expect(sentBytes == docBytes)
        #expect(sentSpec == spec)
        await broker.handleReply(requestId: rid, bytes: Data("result-bytes".utf8), failureReason: nil)
        #expect(try await result.bytes == Data("result-bytes".utf8))
        #expect(try await result.meta == nil)
    }

    // MARK: - Capability filtering

    @Test func createDocOnlyConnectionNotSelectedForStrokeOp() async {
        let broker = DeviceCommandBroker()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc"]) { _ in }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.noDeviceAvailable) {
            _ = try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data())
        }
    }

    @Test func strokeOpOnlyConnectionNotSelectedForCreateDoc() async {
        let broker = DeviceCommandBroker()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { _ in }
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.noDeviceAvailable) {
            _ = try await broker.requestCreation(docId: "D")
        }
    }

    @Test func bothCapabilitiesConnectionServesBothKinds() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }

        async let createResult: Data = broker.requestCreation(docId: "D1")
        let createRequest = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let createRid, "D1") = createRequest else {
            Issue.record("wrong msg: \(createRequest)"); return
        }
        await broker.handleReply(requestId: createRid, bytes: Data("create".utf8), failureReason: nil)
        #expect(try await createResult == Data("create".utf8))

        let sent2 = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent2.set(msg) }
        }
        async let strokeResult: DeviceCommandBroker.StrokeOpReply = broker.requestStrokeOp(docId: "D2", docBytes: Data(), spec: Data())
        let strokeRequest = try #require(await sent2.awaitMessage())
        guard case .strokeOpRequest(let strokeRid, "D2", _, _, _, _) = strokeRequest else {
            Issue.record("wrong msg: \(strokeRequest)"); return
        }
        await broker.handleReply(requestId: strokeRid, bytes: Data("stroke".utf8), failureReason: nil)
        #expect(try await strokeResult.bytes == Data("stroke".utf8))
    }

    // MARK: - Shared per-docId in-flight guard

    @Test func pendingCreateBlocksStrokeOpOnSameDocId() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        async let createResult: Data = broker.requestCreation(docId: "D")
        let createRequest = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let rid, "D") = createRequest else {
            Issue.record("wrong msg: \(createRequest)"); return
        }

        await #expect(throws: DeviceCommandBroker.DeviceCommandError.requestInFlight) {
            _ = try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data())
        }

        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await createResult == Data("T".utf8))
    }

    @Test func pendingStrokeOpBlocksCreateOnSameDocId() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        async let strokeResult: DeviceCommandBroker.StrokeOpReply = broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data())
        let strokeRequest = try #require(await sent.awaitMessage())
        guard case .strokeOpRequest(let rid, "D", _, _, _, _) = strokeRequest else {
            Issue.record("wrong msg: \(strokeRequest)"); return
        }

        await #expect(throws: DeviceCommandBroker.DeviceCommandError.requestInFlight) {
            _ = try await broker.requestCreation(docId: "D")
        }

        await broker.handleReply(requestId: rid, bytes: Data("T".utf8), failureReason: nil)
        #expect(try await strokeResult.bytes == Data("T".utf8))
    }

    // MARK: - The frame relay does not take the agents' per-document lock (review finding 22)

    /// Every accepted write to a watched, closed document starts a relay render. Holding the
    /// agents' lock made the agent's very next call on that document fail `opInProgress`. The
    /// relay only reads, and every agent write is compare-and-swap guarded, so it needs no lock.
    @Test func aRelayRenderDoesNotBlockAnAgentOpOnTheSameDocument() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["render", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        let relay = Task {
            try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data(),
                                             capability: "render", takesDocumentLock: false)
        }
        let relayRequest = try #require(await sent.awaitMessage())
        guard case .strokeOpRequest(let relayId, "D", _, _, _, _) = relayRequest else {
            Issue.record("wrong msg: \(relayRequest)"); return
        }
        // The agent's op on the same document is sent, not refused.
        let agent = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data()) }
        var agentId: UInt32?
        for _ in 0..<100 where agentId == nil {
            for message in await sent.all() {
                if case .strokeOpRequest(let id, "D", _, _, _, _) = message, id != relayId { agentId = id }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try #require(agentId, "the agent's op must be sent while the relay render is in flight")
        await broker.handleReply(requestId: id, bytes: Data("A".utf8), failureReason: nil)
        await broker.handleReply(requestId: relayId, bytes: Data("R".utf8), failureReason: nil)
        #expect(try await agent.value.bytes == Data("A".utf8))
        #expect(try await relay.value.bytes == Data("R".utf8))
    }

    /// …and the other way round: an agent op in flight does not refuse the relay.
    @Test func anAgentOpDoesNotBlockARelayRender() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["render", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        let agent = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data()) }
        let agentRequest = try #require(await sent.awaitMessage())
        guard case .strokeOpRequest(let agentId, "D", _, _, _, _) = agentRequest else {
            Issue.record("wrong msg: \(agentRequest)"); return
        }
        let relay = Task {
            try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data(),
                                             capability: "render", takesDocumentLock: false)
        }
        var relayId: UInt32?
        for _ in 0..<100 where relayId == nil {
            for message in await sent.all() {
                if case .strokeOpRequest(let id, "D", _, _, _, _) = message, id != agentId { relayId = id }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try #require(relayId)
        await broker.handleReply(requestId: id, bytes: Data("R".utf8), failureReason: nil)
        await broker.handleReply(requestId: agentId, bytes: Data("A".utf8), failureReason: nil)
        #expect(try await relay.value.bytes == Data("R".utf8))
        #expect(try await agent.value.bytes == Data("A".utf8))
    }

    // MARK: - Per-kind timeout

    @Test func strokeOpTimesOutIndependentlyOfCreateTimeout() async {
        // A short strokeOpTimeout with a long (untouched) createTimeout:
        // the stroke op must time out on its own schedule without waiting
        // for (or being affected by) the create timeout. The elapsed-time
        // bound is what makes a parameter swap (the stroke op accidentally
        // running on createTimeout) FAIL — 10 s > 5 s — instead of merely
        // making the test slow.
        //
        // The bound is 5 s rather than 1 s because it must separate 100 ms
        // from 10 s, and nothing finer: a 1 s bound was ALSO measuring how
        // promptly the runner gets round to a timer task, and a 2-vCPU CI
        // machine took 1.196 s to fire a 100 ms one. Tightening this back
        // down buys no extra defect detection and re-arms that flake.
        let broker = DeviceCommandBroker(createTimeout: .seconds(10), strokeOpTimeout: .milliseconds(100))
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { _ in }
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceTimeout) {
            _ = try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data())
        }
        #expect(clock.now - start < .seconds(5))
    }

    // MARK: - Kind-agnostic replies

    @Test func twoPendingRequestsOfDifferentKindsResolveIndependently() async throws {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }

        async let createResult: Data = broker.requestCreation(docId: "D1")
        let createRequest = try #require(await sent.awaitMessage())
        guard case .createDocRequest(let createRid, "D1") = createRequest else {
            Issue.record("wrong msg: \(createRequest)"); return
        }

        let sent2 = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["createDoc", "authorStrokes"]) { msg in
            Task { await sent2.set(msg) }
        }
        async let strokeResult: DeviceCommandBroker.StrokeOpReply = broker.requestStrokeOp(docId: "D2", docBytes: Data(), spec: Data())
        let strokeRequest = try #require(await sent2.awaitMessage())
        guard case .strokeOpRequest(let strokeRid, "D2", _, _, _, _) = strokeRequest else {
            Issue.record("wrong msg: \(strokeRequest)"); return
        }

        // Resolve the stroke op first, then the create — each must resolve
        // its own continuation, unaffected by ordering or by the other kind.
        await broker.handleReply(requestId: strokeRid, bytes: Data("stroke".utf8), failureReason: nil)
        await broker.handleReply(requestId: createRid, bytes: Data("create".utf8), failureReason: nil)

        #expect(try await strokeResult.bytes == Data("stroke".utf8))
        #expect(try await createResult == Data("create".utf8))
    }
}

/// M2 — a device may answer with the image blobs left out, because the server just sent them. The
/// broker splices them back so every tool downstream receives a whole document exactly as before.
///
/// These matter more than most: the app's tests fake the server and the server's fake the device, so
/// a one-sided change to this envelope passes both suites and fails only on real hardware.
@Suite struct StrippedAgentReplyTests {
    private func document(blobId: UUID, tail: String) -> Data {
        let payload = String(repeating: "ab\\/cd", count: 4000)
        return Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }
    private func sha(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

    private func requestAndReply(
        sentBytes: Data,
        makeReply: (UInt32) -> (bytes: Data?, kind: String?)
    ) async throws -> Result<Data, any Error> {
        let broker = DeviceCommandBroker()
        let sent = SentBox()
        await broker.register(connectionId: UUID(), capabilities: ["authorStrokes"]) { msg in
            Task { await sent.set(msg) }
        }
        let task = Task {
            try await broker.requestStrokeOp(docId: "D", docBytes: sentBytes, spec: Data("{}".utf8))
        }
        let request = try #require(await sent.awaitMessage())
        guard case .strokeOpRequest(let rid, _, _, _, _, _) = request else {
            Issue.record("wrong message"); return .failure(DeviceCommandBroker.DeviceCommandError.deviceTimeout)
        }
        let reply = makeReply(rid)
        await broker.handleReply(requestId: rid, bytes: reply.bytes, meta: nil,
                                 failureReason: nil, payloadKind: reply.kind)
        do { return .success(try await task.value.bytes) } catch { return .failure(error) }
    }

    /// The document every tool downstream sees is byte-identical to what the device produced.
    @Test func aStrippedReplyIsRebuiltFromWhatWasSent() async throws {
        let id = UUID()
        let sent = document(blobId: id, tail: "before")
        let produced = document(blobId: id, tail: "after")
        let stripped = StrippedDocument.strip(document: produced, against: sent,
                                              basedOn: sha(sent), originalSHA256: sha(produced))
        #expect(stripped.encoded().count < produced.count / 2, "nothing was omitted")

        let result = try await requestAndReply(sentBytes: sent) { _ in
            (bytes: stripped.encoded(), kind: "strippedDoc")
        }
        #expect(try result.get() == produced)
    }

    /// Stripped against something other than what we sent: named, never guessed at.
    @Test func aReplyStrippedAgainstSomethingElseFails() async throws {
        let id = UUID()
        let sent = document(blobId: id, tail: "before")
        let elsewhere = document(blobId: UUID(), tail: "elsewhere")
        let produced = document(blobId: id, tail: "after")
        let stripped = StrippedDocument.strip(document: produced, against: elsewhere,
                                              basedOn: sha(elsewhere), originalSHA256: sha(produced))

        let result = try await requestAndReply(sentBytes: sent) { _ in
            (bytes: stripped.encoded(), kind: "strippedDoc")
        }
        #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("cannotReconstruct")) {
            _ = try result.get()
        }
    }

    /// A request that carried NO document — `provideContent` sends empty bytes — cannot have
    /// anything spliced back into it, and must fail rather than return a half-document.
    @Test func aStrippedReplyToARequestThatSentNothingFails() async throws {
        let id = UUID()
        let produced = document(blobId: id, tail: "after")
        let stripped = StrippedDocument.strip(document: produced, against: produced,
                                              basedOn: sha(produced), originalSHA256: sha(produced))

        let result = try await requestAndReply(sentBytes: Data()) { _ in
            (bytes: stripped.encoded(), kind: "strippedDoc")
        }
        #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("cannotReconstruct")) {
            _ = try result.get()
        }
    }

    /// The case the DIGEST checks exist for, and the only one that reaches them.
    ///
    /// The two tests above are refused earlier, by `restore` failing to find the blob at all — I
    /// wrote them believing they pinned the digests, and removing BOTH digest checks left them
    /// green. Here the same blob id names DIFFERENT bytes on the two sides, so the splice succeeds
    /// structurally and yields a document that is not the one the device produced. Only a digest
    /// can tell.
    ///
    /// It should be unreachable — a blob id names immutable bytes — which is exactly why the check
    /// has to be here rather than trusted away.
    ///
    /// Mutation-verified as a pair: removing BOTH digest checks fails this test, removing either
    /// alone does not. They are redundant for this case by design — `basedOn` is the cheap early
    /// answer and `originalSHA256` the definitive one — so what is pinned here is the OUTCOME, that
    /// a rebuild which is not the device's document is refused, not one particular guard.
    @Test func aRebuildThatSucceedsButProducesTheWrongBytesIsRefused() async throws {
        // The SAME blob id on both sides, naming different bytes.
        let id = UUID()
        func doc(payload: String, tail: String) -> Data {
            Data("""
            {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(id.uuidString)",\
            "thumbnailData":"AA=="}]}
            """.utf8)
        }
        let mine = doc(payload: String(repeating: "ab\\/cd", count: 4000), tail: "before")
        let theirs = doc(payload: String(repeating: "zy\\/xw", count: 4000), tail: "before")
        let produced = doc(payload: String(repeating: "zy\\/xw", count: 4000), tail: "after")

        let stripped = StrippedDocument.strip(document: produced, against: theirs,
                                              basedOn: sha(theirs), originalSHA256: sha(produced))
        let result = try await requestAndReply(sentBytes: mine) { _ in
            (bytes: stripped.encoded(), kind: "strippedDoc")
        }
        #expect(throws: DeviceCommandBroker.DeviceCommandError.deviceFailed("cannotReconstruct")) {
            _ = try result.get()
        }
    }

    /// A whole reply is untouched — the ordinary case, and every render or selection reply.
    @Test func aReplyWithoutAKindIsPassedThroughUnchanged() async throws {
        let produced = document(blobId: UUID(), tail: "after")
        let result = try await requestAndReply(sentBytes: Data("{}".utf8)) { _ in
            (bytes: produced, kind: nil)
        }
        #expect(try result.get() == produced)
    }
}

/// M4: the REQUEST direction leaves out the blobs this connection was already sent
/// (spec 2026-08-03-request-blob-stripping-design.md). Agent ops come in bursts against one
/// document, and each request is itself the base the next one is stripped against — the first op
/// pays full price, every later one ships the delta. A device that lost its copy answers
/// `cannotReconstructRequest`, and the broker retries the SAME op once, whole: a cache problem
/// must never surface as a tool error.
@Suite struct StrippedRequestTests {
    private func document(blobId: UUID, tail: String) -> Data {
        let payload = String(repeating: "ab\\/cd", count: 4000)
        return Data("""
        {"a":"\(tail)","pastedImagesData":[{"data":"\(payload)","id":"\(blobId.uuidString)",\
        "thumbnailData":"AA=="}]}
        """.utf8)
    }

    private actor Outbox {
        private var messages: [ServerMessage] = []
        func append(_ m: ServerMessage) { messages.append(m) }
        func message(at index: Int) async -> ServerMessage? {
            for _ in 0..<100 {
                if messages.count > index { return messages[index] }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }
    }

    private func makeBrokerAndOutbox(capabilities: Set<String>) async -> (DeviceCommandBroker, Outbox) {
        let broker = DeviceCommandBroker()
        let outbox = Outbox()
        await broker.register(connectionId: UUID(), capabilities: capabilities) { msg in
            Task { await outbox.append(msg) }
        }
        return (broker, outbox)
    }

    private func completeRequest(_ broker: DeviceCommandBroker, _ message: ServerMessage?) async -> UInt32? {
        guard case .strokeOpRequest(let rid, _, _, _, _, _) = message else { return nil }
        await broker.handleReply(requestId: rid, bytes: Data("ok".utf8), meta: nil,
                                 failureReason: nil, payloadKind: nil)
        return rid
    }

    /// The heart of it: first request whole, second stripped — and the stripped payload restores
    /// against the FIRST request's bytes to exactly the second document.
    @Test func theSecondRequestIsStrippedAgainstTheFirst() async throws {
        let id = UUID()
        let doc1 = document(blobId: id, tail: "one")
        let doc2 = document(blobId: id, tail: "two")
        let (broker, outbox) = await makeBrokerAndOutbox(
            capabilities: ["authorStrokes", "blobOmission"])

        let t1 = Task { try await broker.requestStrokeOp(docId: "D", docBytes: doc1, spec: Data("{}".utf8)) }
        let first = await outbox.message(at: 0)
        guard case .strokeOpRequest(_, _, .inline(let bytes1), _, let kind1, _) = first else {
            Issue.record("no first request"); return
        }
        #expect(kind1 == nil, "the first request has no shared base and must be whole")
        #expect(bytes1 == doc1)
        _ = await completeRequest(broker, first)
        _ = try await t1.value

        let t2 = Task { try await broker.requestStrokeOp(docId: "D", docBytes: doc2, spec: Data("{}".utf8)) }
        let second = await outbox.message(at: 1)
        guard case .strokeOpRequest(_, _, .inline(let bytes2), _, let kind2, _) = second else {
            Issue.record("no second request"); return
        }
        _ = await completeRequest(broker, second)
        _ = try await t2.value

        #expect(kind2 == "strippedDoc")
        #expect(bytes2.count < doc2.count / 2, "the blob must actually be off the wire")
        let restored = try StrippedDocument(encoded: bytes2).restore(using: doc1)
        #expect(restored == doc2, "the device must be able to rebuild the exact document")
    }

    /// A peer that never said `blobOmission` gets whole documents forever — `infsketch-demo`
    /// subscribes to this wire without knowing what a StrippedDocument is.
    @Test func aConnectionWithoutTheCapabilityAlwaysGetsWhole() async throws {
        let id = UUID()
        let (broker, outbox) = await makeBrokerAndOutbox(capabilities: ["authorStrokes"])

        for (i, tail) in ["one", "two"].enumerated() {
            let doc = document(blobId: id, tail: tail)
            let t = Task { try await broker.requestStrokeOp(docId: "D", docBytes: doc, spec: Data("{}".utf8)) }
            let msg = await outbox.message(at: i)
            guard case .strokeOpRequest(_, _, .inline(let bytes), _, let kind, _) = msg else {
                Issue.record("no request \(i)"); return
            }
            #expect(kind == nil)
            #expect(bytes == doc)
            _ = await completeRequest(broker, msg)
            _ = try await t.value
        }
    }

    /// The device lost its copy: `cannotReconstructRequest` triggers exactly ONE whole retry of
    /// the same op, transparent to the agent — and the ledger resets, so the retry re-seeds it.
    @Test func aCannotReconstructReplyRetriesOnceWhole() async throws {
        let id = UUID()
        let doc1 = document(blobId: id, tail: "one")
        let doc2 = document(blobId: id, tail: "two")
        let (broker, outbox) = await makeBrokerAndOutbox(
            capabilities: ["authorStrokes", "blobOmission"])

        let t1 = Task { try await broker.requestStrokeOp(docId: "D", docBytes: doc1, spec: Data("{}".utf8)) }
        _ = await completeRequest(broker, await outbox.message(at: 0))
        _ = try await t1.value

        let t2 = Task { try await broker.requestStrokeOp(docId: "D", docBytes: doc2, spec: Data("{}".utf8)) }
        let strippedReq = await outbox.message(at: 1)
        guard case .strokeOpRequest(let rid2, _, _, _, "strippedDoc", _) = strippedReq else {
            Issue.record("second request was not stripped"); return
        }
        // The device cannot rebuild — relaunched, cache gone.
        await broker.handleReply(requestId: rid2, bytes: nil, meta: nil,
                                 failureReason: "cannotReconstructRequest: no retained copy",
                                 payloadKind: nil)
        // The broker must retry the SAME op, whole, without surfacing anything.
        let retry = await outbox.message(at: 2)
        guard case .strokeOpRequest(_, _, .inline(let retryBytes), _, let retryKind, _) = retry else {
            Issue.record("no whole retry was sent"); return
        }
        #expect(retryKind == nil, "the retry must be whole")
        #expect(retryBytes == doc2)
        _ = await completeRequest(broker, retry)
        let reply = try await t2.value
        #expect(reply.bytes == Data("ok".utf8), "the agent sees ONE successful op")
    }

    /// `provideContent` sends EMPTY docBytes — never stripped, and never allowed to poison the
    /// ledger: a stripping-eligible request after it must still strip against the last REAL doc.
    @Test func emptyRequestBytesNeitherStripNorPoisonTheLedger() async throws {
        let id = UUID()
        let doc1 = document(blobId: id, tail: "one")
        let doc3 = document(blobId: id, tail: "three")
        let (broker, outbox) = await makeBrokerAndOutbox(
            capabilities: ["authorStrokes", "blobOmission"])

        let t1 = Task { try await broker.requestStrokeOp(docId: "D", docBytes: doc1, spec: Data("{}".utf8)) }
        _ = await completeRequest(broker, await outbox.message(at: 0))
        _ = try await t1.value

        let t2 = Task { try await broker.requestStrokeOp(docId: "D", docBytes: Data(), spec: Data("{}".utf8)) }
        let empty = await outbox.message(at: 1)
        guard case .strokeOpRequest(_, _, .inline(let emptyBytes), _, let emptyKind, _) = empty else {
            Issue.record("no empty request"); return
        }
        #expect(emptyBytes.isEmpty)
        #expect(emptyKind == nil)
        _ = await completeRequest(broker, empty)
        _ = try await t2.value

        let t3 = Task { try await broker.requestStrokeOp(docId: "D", docBytes: doc3, spec: Data("{}".utf8)) }
        let third = await outbox.message(at: 2)
        guard case .strokeOpRequest(_, _, .inline(let bytes3), _, let kind3, _) = third else {
            Issue.record("no third request"); return
        }
        _ = await completeRequest(broker, third)
        _ = try await t3.value

        #expect(kind3 == "strippedDoc", "the empty request must not have clobbered the base")
        let restored = try StrippedDocument(encoded: bytes3).restore(using: doc1)
        #expect(restored == doc3)
    }
}
