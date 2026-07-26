import Foundation
import FlyingFox
import InfSketchWire

/// Bridges one WebSocket connection to the SessionManager.
/// FlyingFox calls makeMessages once per connection.
public struct WSAdapter: WSMessageHandler, Sendable {
    private let manager: SessionManager
    private let config: SessionConfig
    private let broker: DeviceCommandBroker

    public init(manager: SessionManager, config: SessionConfig = SessionConfig(), broker: DeviceCommandBroker) {
        self.manager = manager
        self.config = config
        self.broker = broker
    }

    public func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        // This output stream is unbounded, and bounding it would achieve nothing: FlyingFox's
        // `WSHandler.start` re-buffers our messages into a default-policy (unbounded)
        // `AsyncThrowingStream` before the socket writer, so the memory would simply move one
        // layer down, out of reach. Nor is there any write-completion signal to bound against.
        //
        // So the guard is `ConnectionHealth` instead: count bytes emitted since the peer last
        // spoke, ask it to prove it is reading when that passes `outboundByteBudget`, and drop
        // it if it will not answer within `keepalivePingGrace`. The same ping on an idle timer
        // is what reaps a half-open socket whose subscriptions would otherwise hold a document
        // session open forever. (`DocumentSession`'s own bounded buffer still covers a
        // different case — a `pump` task that is suspended rather than a socket that is slow.)
        let (output, outputCont) = AsyncStream<WSMessage>.makeStream()
        let connection = Connection(manager: manager, output: outputCont, config: config, broker: broker)
        let keepalive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: config.keepaliveTickInterval)
                if Task.isCancelled { return }
                await connection.tick()
            }
        }
        await connection.setKeepaliveTask(keepalive)
        Task {
            for await frame in client {
                await connection.handle(frame)
            }
            keepalive.cancel()
            await connection.close()
        }
        return output
    }
}

/// Per-connection state machine: hello gate, doc subscriptions, status subscription.
actor Connection {
    private let manager: SessionManager
    private let output: AsyncStream<WSMessage>.Continuation
    private var sender: TransferSender<ServerMessage>
    private var reassembler = TransferReassembler<ClientMessage>()
    private var helloed = false
    /// The advertising device's identity, from `hello`. M2c-1: recorded as a HOLDER on every
    /// document this connection advertises, so a content fetch can be routed to it — and pruned
    /// from the live index when the connection closes. All holders are equal; there is no origin.
    private var deviceId: String?
    private var closed = false
    /// Stall/liveness policy. See `ConnectionHealth` — the short version is that nothing below
    /// us reports a completed socket write, so bytes emitted since the peer last spoke is the
    /// only signal available.
    private var health: ConnectionHealth
    /// Cancelled by `close()`, so a server-initiated drop stops its own timer instead of leaving
    /// it ticking against a closed connection until the client's stream happens to end.
    private var keepaliveTask: Task<Void, Never>?
    private var docSubscriptions: [String: (token: UUID, pump: Task<Void, Never>)] = [:]
    private var watchSubscriptions: [String: (token: UUID, pump: Task<Void, Never>)] = [:]
    private var statusSubscription: (token: UUID, pump: Task<Void, Never>)?
    private let broker: DeviceCommandBroker
    private let connectionId = UUID()
    private var registeredWithBroker = false

    init(
        manager: SessionManager, output: AsyncStream<WSMessage>.Continuation, config: SessionConfig,
        broker: DeviceCommandBroker
    ) {
        self.manager = manager
        self.output = output
        self.sender = TransferSender(inlineLimit: config.inlineLimit, chunkSize: config.chunkSize)
        self.broker = broker
        self.health = ConnectionHealth(
            byteBudget: config.outboundByteBudget,
            idleInterval: config.keepaliveIdleInterval,
            pingGrace: config.keepalivePingGrace,
            assumedMinimumDrainRate: config.assumedMinimumDrainRate,
            now: ContinuousClock.now)
    }

    func handle(_ frame: WSMessage) async {
        // Before every other gate, including hello: a peer that is talking is alive, whatever it
        // is saying and whether or not the message is even well-formed.
        act(on: health.noteInbound(now: ContinuousClock.now))
        guard !closed else { return }
        let wire: WireFrame
        switch frame {
        case .close:
            await close()
            return
        case .text(let text):
            wire = .text(text)
        case .data(let data):
            wire = .binary(data)
        }
        let message: ClientMessage?
        // TODO(hardening): frames reach the reassembler before the hello gate —
        // when auth lands, gate or bound pre-hello transfer bytes.
        do {
            message = try reassembler.consume(wire)
        } catch let error as TransferWireError {
            // Transfer state is positional — once violated the stream can't
            // be trusted. Connection-fatal per the chunked-transfer spec.
            FileHandle.standardError.write(Data("transfer violation on connection: \(error)\n".utf8))
            emit(.error(reason: "transferViolation"))
            await close()
            return
        } catch {
            emit(.error(reason: "malformedMessage"))
            return
        }
        guard let message else { return }   // chunk consumed / transfer opened / aborted
        await dispatch(message)
    }

    private func dispatch(_ message: ClientMessage) async {
        switch message {
        case .hello(let version, let capabilities, let deviceId):
            guard version == WireProtocol.version else {
                emit(.error(reason: "unsupportedVersion"))
                await close()
                return
            }
            helloed = true
            self.deviceId = deviceId
            // Register with the broker whenever the connection advertises
            // any capability the broker brokers requests for — the broker
            // itself filters per-request by capability (see
            // DeviceCommandBroker.performRequest), so this gate only needs to
            // recognize "some device command capability", not which one.
            // "authorText" (styled_text branch) joined "createDoc"/
            // "authorStrokes" here — a device that advertises only
            // "authorText" must still be registered, or requestStrokeOp's
            // capability: "authorText" calls would always see noDeviceAvailable.
            // "controlSelection" (agent-selection-control spec) joined the
            // same way, for get_selection/transform_selection's
            // capability: "controlSelection" relay.
            // "mergeDocs" (agent-merge-docs spec) joined the same way, for
            // merge_docs's capability: "mergeDocs" relay.
            // "authorImage" (add_image, Task 2) joined the same way, for
            // add_image's capability: "authorImage" relay.
            // "authorGrids" (agent-grid-authoring spec, Task 3) joined the same
            // way, for list_grids/add_grid/update_grid/remove_grid/
            // set_grid_origin's capability: "authorGrids" relay.
            // "copyElements" (agent-copy-elements spec, Task 2) joined the
            // same way, for copy_elements's capability: "copyElements" relay.
            // "reorderElements" (agent-element-zorder spec, Task 2) joined
            // the same way, for reorder_elements's capability:
            // "reorderElements" relay.
            // "provideContent" (M2c-1, Task 4) joined the same way, for
            // requestProvideContent's capability: "provideContent" relay — a
            // device advertising only content-provisioning must still register.
            let caps = Set(capabilities)
            if !caps.isDisjoint(with: [
                "createDoc", "authorStrokes", "authorText", "controlSelection",
                "mergeDocs", "authorImage", "authorGrids", "copyElements", "reorderElements",
                "provideContent",
            ]) {
                registeredWithBroker = true
                await broker.register(connectionId: connectionId, deviceId: deviceId, capabilities: caps) { [weak self] message in
                    Task { await self?.emitFromBroker(message) }
                }
            }
            emit(.helloAck(protocolVersion: WireProtocol.version))

        case .pong:
            // The liveness credit was already taken in `handle` — any inbound frame counts, so
            // there is nothing further to do here. This case exists so a pong is not answered
            // with `helloRequired`, which would leave an alive-but-unauthenticated peer unable
            // to prove itself.
            break

        case _ where !helloed:
            emit(.error(reason: "helloRequired"))

        case .subscribe(let docId, _, let createIfMissing):
            // v0: fromSeq ignored — always a full snapshot.
            guard docSubscriptions[docId] == nil else {
                return emit(.error(reason: "alreadySubscribed"))
            }
            do {
                let result = try await manager.subscribe(docId: docId, createIfMissing: createIfMissing)
                emit(result.snapshot)
                docSubscriptions[docId] = (result.token, pump(result.events, docId: docId, token: result.token))
            } catch {
                // M2c-3 (F3): a DOCID-CARRYING failure, not a bare `.error`. The app's transport
                // fails all pending subscribes on a docId-less `.error`, so a failed download
                // (a subscribe that found no holder) used to collaterally kill an unrelated open
                // document's subscribe. `subscribeFailed` lets the app fail only THIS doc's.
                emit(.subscribeFailed(docId: docId, reason: "unknownDoc"))
            }

        case .unsubscribe(let docId):
            if let sub = docSubscriptions.removeValue(forKey: docId) {
                sub.pump.cancel()
                await manager.unsubscribe(docId: docId, token: sub.token)
            }

        case .deleteDoc(let docId):
            // Drop our own subscription first, so tearing the session down does not race the
            // pump task that is still draining it.
            if let sub = docSubscriptions.removeValue(forKey: docId) {
                sub.pump.cancel()
                await manager.unsubscribe(docId: docId, token: sub.token)
            }
            do {
                try await manager.deleteDoc(docId: docId)
                emit(.docDeleted(docId: docId))
            } catch {
                emit(.error(reason: "unknownDoc"))
            }

        case .op(let docId, let opId, let payload, let expectation):
            guard docSubscriptions[docId] != nil else {
                return emit(.error(reason: "notSubscribed"))
            }
            // WS submitters take their ack from the broadcast echo (which
            // carries the assigned seq), so only a rejection needs
            // forwarding here.
            if let reject = await manager.submit(
                docId: docId, opId: opId, payload: payload, expectation: expectation ?? .none
            ).rejectMessage {
                emit(reject)
            }

        case .subscribeStatus:
            guard statusSubscription == nil else { return }
            let (events, token) = await manager.subscribeStatus()
            statusSubscription = (token, pump(events, docId: nil, token: token))

        case .unsubscribeStatus:
            if let sub = statusSubscription {
                statusSubscription = nil
                sub.pump.cancel()
                await manager.unsubscribeStatus(sub.token)
            }

        case .listDocs:
            do {
                emit(.docList(docs: try await manager.listDocuments()))
            } catch {
                emit(.error(reason: "listFailed"))
            }

        case .transferEnd, .transferAbort:
            // Unreachable: the reassembler consumes these or throws.
            emit(.error(reason: "transferViolation"))
            await close()

        case .watchDoc(let docId):
            guard watchSubscriptions[docId] == nil else {
                return emit(.error(reason: "alreadyWatching"))
            }
            do {
                let result = try await manager.watch(docId: docId)
                watchSubscriptions[docId] = (result.token, pumpWatch(result.events, docId: docId, token: result.token))
            } catch {
                emit(.error(reason: "unknownDoc"))
            }

        case .unwatchDoc(let docId):
            if let watch = watchSubscriptions.removeValue(forKey: docId) {
                watch.pump.cancel()
                await manager.unwatch(docId: docId, token: watch.token)
            }

        case .frame(let docId, let payload):
            guard docSubscriptions[docId] != nil else {
                return emit(.error(reason: "notSubscribed"))
            }
            guard case .inline(let bytes) = payload else {
                return emit(.error(reason: "unresolvedTransfer"))
            }
            if await manager.submitFrame(docId: docId, bytes: bytes) == false {
                emit(.error(reason: "unknownDoc"))
            }

        case .createDocReply(let requestId, _, let payload, let failureReason):
            // The wire type can't enforce exactly-one-of payload/failureReason,
            // so routing applies an explicit precedence: an inline payload
            // always wins as a success (even if a failureReason is also
            // present — a spec-violating combination); with neither present,
            // substitute a failureReason rather than ever calling
            // handleReply(bytes: nil, failureReason: nil) — the broker
            // defaults THAT combination to a success with empty Data, which
            // must stay unreachable from here.
            guard case .inline(let bytes)? = payload else {
                if payload == nil {
                    await broker.handleReply(
                        requestId: requestId, bytes: nil, failureReason: failureReason ?? "unspecified")
                } else {
                    // Unreachable in practice: the reassembler resolves
                    // .transfer payloads to .inline before dispatch ever
                    // sees this message (mirrors the `frame` case's guard).
                    emit(.error(reason: "unresolvedTransfer"))
                }
                return
            }
            await broker.handleReply(requestId: requestId, bytes: bytes, failureReason: nil)

        case .strokeOpReply(let requestId, _, let payload, let meta, let failureReason):
            // Same precedence as createDocReply above (kept in exact lockstep
            // on purpose — one broker, one reply-routing contract): an inline
            // payload always wins as a success (even alongside a
            // spec-violating failureReason); with neither present, substitute
            // a failureReason rather than ever calling handleReply(bytes:
            // nil, failureReason: nil) — the broker defaults THAT combination
            // to a success with empty Data, which must stay unreachable here.
            // `meta` (render-op metadata JSON) rides along on the success
            // path regardless of which precedence branch resolves it.
            guard case .inline(let bytes)? = payload else {
                if payload == nil {
                    // A no-bytes reply is a SUCCESS when it carries `meta` — the selection ops
                    // (get_selection / transform_selection / select_*) return their descriptor JSON
                    // in `meta` with nil bytes. Only a reply with nothing at all (no bytes, no meta,
                    // no failureReason) is malformed and gets the "unspecified" substitution; a
                    // meta-only, no-failure reply passes through as a success (nil failureReason).
                    let resolvedFailure = (failureReason == nil && meta == nil) ? "unspecified" : failureReason
                    await broker.handleReply(
                        requestId: requestId, bytes: nil, meta: meta, failureReason: resolvedFailure)
                } else {
                    // Unreachable in practice: the reassembler resolves
                    // .transfer payloads to .inline before dispatch ever sees
                    // this message (mirrors the `createDocReply` case's guard).
                    emit(.error(reason: "unresolvedTransfer"))
                }
                return
            }
            await broker.handleReply(requestId: requestId, bytes: bytes, meta: meta, failureReason: nil)

        case .advertiseDocs(let payload):
            // M2c-1: a device advertising the docs it owns — metadata + thumbnail, no content.
            // Folded into the in-memory live index, keyed by THIS connection's deviceId (any
            // holder may later serve a fetch). Never touches content: the live index is separate
            // from the store, and `listDocuments()` lets content win.
            guard case .inline(let bytes) = payload else {
                return emit(.error(reason: "unresolvedTransfer"))
            }
            guard let ads = try? JSONDecoder().decode([DocAdvertisement].self, from: bytes) else {
                return emit(.error(reason: "malformedMessage"))
            }
            await manager.applyAdvertisements(ads, connectionId: connectionId, deviceId: deviceId)
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        for (docId, sub) in docSubscriptions {
            sub.pump.cancel()
            await manager.unsubscribe(docId: docId, token: sub.token)
        }
        docSubscriptions.removeAll()
        for (docId, watch) in watchSubscriptions {
            watch.pump.cancel()
            await manager.unwatch(docId: docId, token: watch.token)
        }
        watchSubscriptions.removeAll()
        if let sub = statusSubscription {
            statusSubscription = nil
            sub.pump.cancel()
            await manager.unsubscribeStatus(sub.token)
        }
        if registeredWithBroker {
            registeredWithBroker = false
            await broker.unregister(connectionId: connectionId)
        }
        if let deviceId {
            await manager.removeConnection(connectionId: connectionId, deviceId: deviceId)
        }
        output.finish()
    }

    /// Called by a pump on natural (server-initiated) stream completion:
    /// clears connection-local bookkeeping and releases the manager-side
    /// subscription so a later client re-subscribe works.
    private func releaseDocSubscription(docId: String, token: UUID) async {
        if let sub = docSubscriptions[docId], sub.token == token {
            docSubscriptions.removeValue(forKey: docId)
        }
        await manager.unsubscribe(docId: docId, token: token)
    }

    private func releaseStatusSubscription(token: UUID) async {
        if let sub = statusSubscription, sub.token == token {
            statusSubscription = nil
        }
        await manager.unsubscribeStatus(token)
    }

    private func releaseWatchSubscription(docId: String, token: UUID) async {
        if let watch = watchSubscriptions[docId], watch.token == token {
            watchSubscriptions.removeValue(forKey: docId)
        }
        await manager.unwatch(docId: docId, token: token)
    }

    /// Forwards frameAvailable nudges to the browser. On server-side stream
    /// finish (watcher dropped), releases the registration.
    private func pumpWatch(
        _ events: AsyncStream<ServerMessage>, docId: String, token: UUID
    ) -> Task<Void, Never> {
        Task {
            for await event in events {
                self.emit(event)
            }
            guard !Task.isCancelled else { return }
            await self.releaseWatchSubscription(docId: docId, token: token)
        }
    }

    /// Forwards session events out through emit(_:). When the stream
    /// finishes server-side (e.g. buffer-overflow disconnect), releases the
    /// subscription so SessionManager's count stays accurate.
    private func pump(
        _ events: AsyncStream<ServerMessage>, docId: String?, token: UUID
    ) -> Task<Void, Never> {
        Task {
            // This unstructured Task inherits Connection's actor isolation,
            // so emit is a same-actor synchronous call — no await. If a
            // future Swift changed that inheritance, this would fail to
            // compile (cross-actor isolated calls require await) instead of
            // silently losing the serialized-output guarantee.
            for await event in events {
                self.emit(event)
            }
            guard !Task.isCancelled else { return }
            if let docId {
                await self.releaseDocSubscription(docId: docId, token: token)
            } else {
                await self.releaseStatusSubscription(token: token)
            }
        }
    }

    /// Target of the broker's send closure (registered at hello). The
    /// closure itself is `@Sendable` and fires from the broker actor via an
    /// unstructured `Task { await self?.emitFromBroker(message) }` — the
    /// `await` there is what hops back onto this actor before touching
    /// connection state; this method must never be called except through
    /// that hop.
    private func emitFromBroker(_ message: ServerMessage) {
        guard !closed else { return }
        emit(message)
    }

    /// Single serialized exit point for every outgoing message. Expands
    /// oversized bulk payloads into descriptor + chunks + end; actor
    /// isolation (and no suspension inside) keeps each expansion's frames
    /// contiguous on the socket — the one-in-flight-per-direction rule
    /// holds by construction.
    private func emit(_ message: ServerMessage) {
        guard let frames = try? sender.frames(for: message) else { return }
        var emittedBytes = 0
        for frame in frames {
            switch frame {
            case .text(let json):
                output.yield(.text(json))
                emittedBytes += json.utf8.count
            case .binary(let data):
                output.yield(.data(data))
                emittedBytes += data.count
            }
        }
        // The ping's own bytes are not counted: the accrual must never be fed by the question it
        // asks, or a silent peer would ping itself into a drop on the byte path rather than on
        // the grace deadline that is supposed to decide it.
        if case .ping = message { return }
        act(on: health.noteEmitted(bytes: emittedBytes, now: ContinuousClock.now))
    }

    /// Carries out `ConnectionHealth`'s verdict. Kept separate so all three inputs
    /// (emit / inbound / tick) act identically on the same decision.
    private func act(on action: ConnectionHealth.Action) {
        switch action {
        case .none:
            break
        case .ping:
            emit(.ping)
        case .drop:
            // A close code first, so the client learns why rather than seeing a bare EOF;
            // close() then releases every subscription, watcher, broker registration and
            // live-index holder entry, which is what lets the grace teardown finally fire.
            output.yield(.close(.policyViolation))
            Task { await self.close() }
        }
    }

    /// Driven by the per-connection keepalive timer in `WSAdapter.makeMessages`.
    func tick() {
        guard !closed else { return }
        act(on: health.tick(now: ContinuousClock.now))
    }

    func setKeepaliveTask(_ task: Task<Void, Never>) {
        guard !closed else { return task.cancel() }
        keepaliveTask = task
    }
}
