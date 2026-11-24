import Foundation
import FlyingFox
import FlyingSocks

public struct DocSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sizeBytes: Int
    public var modifiedAt: Date
    public var seq: Int?
    public var subscriberCount: Int?
    /// M2b: false = the server holds only metadata + thumbnail; the content lives on a
    /// connected device (M2c-1: any of its holders).
    public var hasContent: Bool
}

public final class InfSketchServer: Sendable {
    public let manager: SessionManager
    let agentWork: AgentWork
    private let store: any DocumentStore
    /// Where `render_sketch(writeToFile: true)` puts its PNGs, or nil when this server has no
    /// render directory. Held here as well as on the adapter because the HTTP route serves the same
    /// files the tool writes — that is what makes the feature reach a REMOTE agent, which cannot
    /// see the server's filesystem.
    private let renderFileStore: RenderFileStore?
    /// The HTTP server in use, and how to make another one. Replaced only by `run()`, before it
    /// has listened, when an AUTOMATIC port turned out to be taken (`HTTPBox`).
    private let httpBox: HTTPBox
    private var http: HTTPServer { httpBox.current.server }
    private let config: SessionConfig
    /// The port this server was CONSTRUCTED with. `listeningPort` is the truth and is what the
    /// pages use; this is the fallback for the window before the socket is up.
    private let requestedPort: UInt16
    /// An automatic port that turns out to be taken may be replaced by another (`run()`).
    private let canReplaceAutomaticPort: Bool
    /// One broker per process, shared by the WS layer (registers
    /// capability-tagged connections, routes replies) and the MCP layer
    /// (calls `requestCreation` from the `create_doc` tool; will call
    /// `requestStrokeOp` from the agent stroke-authoring tool, Task 4).
    /// internal (not private) for tests — mirrors `mcpAdapter` below: Task 3's
    /// real-socket outbound-chunking test drives `requestStrokeOp` directly
    /// against the same broker instance the running server's `WSAdapter` uses.
    let deviceCommandBroker: DeviceCommandBroker
    let mcpAdapter: MCPAdapter  // internal for tests (session-registry assertions)
    /// Set by `stop()` BEFORE the socket closes, so the accept failure that closing it produces
    /// ends `run()` instead of being retried as descriptor exhaustion.
    private let stopFlag = StopFlag()
    /// Listening and verified to own its port on the loopback addresses (`LoopbackPort`).
    private let readiness = Readiness()

    private actor StopFlag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    /// The HTTP server and the port it was made for. A FlyingFox server is made for one address,
    /// so taking another port means making another server; the routes are added to whichever one
    /// is current when `run()` starts it.
    private final class HTTPBox: @unchecked Sendable {
        typealias Entry = (server: HTTPServer, port: UInt16)
        private let lock = NSLock()
        private var entry: Entry
        private let make: @Sendable (UInt16) -> HTTPServer
        init(port: UInt16, make: @escaping @Sendable (UInt16) -> HTTPServer) {
            self.make = make
            entry = (make(port), port)
        }
        var current: Entry { lock.lock(); defer { lock.unlock() }; return entry }
        func replace(port: UInt16) {
            let server = make(port)
            lock.lock(); entry = (server, port); lock.unlock()
        }
    }

    /// The port an automatic-port server (`port: 0`) currently intends to listen on — picked, not
    /// yet proven: `listeningPort` is the truth once it listens. nil for a fixed port.
    var automaticPort: UInt16? {
        guard requestedPort == 0 else { return nil }
        let port = httpBox.current.port
        return port == 0 ? nil : port
    }

    /// Listening AND verified to own the loopback addresses — what `waitUntilListening` waits for.
    private actor Readiness {
        private(set) var verified = false
        private(set) var failure: (any Error)?
        func markVerified() { verified = true }
        func fail(_ error: any Error) { failure = error }
    }

    public convenience init(
        port: UInt16, docsDirectory: URL, config: SessionConfig = SessionConfig(),
        hostAwake: any HostAwake = NoHostAwake()
    ) {
        // The document store FIRST, in its own statement: its init runs the identity migration,
        // which renames document files to their ids — and the version store's start-up cleanup
        // removes the version folder of any id with no document file, so it must see the files
        // under their final names.
        let store = DirectoryDocumentStore(directory: docsDirectory)
        self.init(
            port: port,
            store: store,
            config: config,
            // `.versions/` and `.blobs/` beside the documents — dot-directories, so `list()` never
            // sees them (the `.trash` reasoning below).
            versions: DirectoryVersionStore(directory: docsDirectory),
            // A dot-directory beside the documents, for the same reason `.trash` is one: `list()`
            // enumerates non-recursively and filters on the `.infsketch` extension, so a render can
            // never surface as a document.
            renderFileStore: RenderFileStore(
                directory: docsDirectory.appendingPathComponent(
                    RenderFileStore.directoryName, isDirectory: true)),
            hostAwake: hostAwake)
    }

    /// Store-injecting designated init — `internal`, for tests only (the
    /// public init above is the one real callers use, and it always builds a
    /// `DirectoryDocumentStore`). The write-CAS boundary tests need a store
    /// whose `load` can return different bytes on successive calls, so that a
    /// tool handler's read and the session-open behind its submit see
    /// DIFFERENT content with no timing involved at all — see
    /// `StaleReadStore` in MCPAdapterTests.
    ///
    /// `socketPool` replaces FlyingFox's default event pool (still wrapped in
    /// `WriteStallTimeoutPool`) — for the test that makes `accept` fail on a real server.
    init(
        port: UInt16, store: any DocumentStore, config: SessionConfig = SessionConfig(),
        versions: (any VersionStore)? = nil,
        renderFileStore: RenderFileStore? = nil, socketPool: (any AsyncSocketPool)? = nil,
        hostAwake: any HostAwake = NoHostAwake()
    ) {
        self.store = store
        self.renderFileStore = renderFileStore
        let manager = SessionManager(store: store, config: config, versions: versions)
        self.manager = manager
        // The logger is passed EXPLICITLY, never defaulted: FlyingFox's default prints to stdout on
        // every non-Apple platform, which made the quiet console Apple-only by accident. See
        // `ServerLogHTTPLogging`.
        //
        // The pool is wrapped so a peer that stops reading loses its SOCKET, not only its
        // subscriptions — see `WriteStallTimeoutPool`. The address mirrors FlyingFox's own
        // `init(port:)`, which cannot take a pool.
        // An automatic port is picked so it cannot be one another program holds on 127.0.0.1
        // (`LoopbackPort`); a fixed one is used as asked and verified once listening.
        let bindPort = port == 0 ? ((try? LoopbackPort.pickFree()) ?? 0) : port
        let writeStallTimeout = config.writeStallTimeout
        self.httpBox = HTTPBox(port: bindPort) { port in
            #if canImport(WinSDK)
            let address = sockaddr_in.inet(port: port)
            #else
            let address = sockaddr_in6.inet6(port: port)
            #endif
            let pool = WriteStallTimeoutPool(inner: socketPool ?? HTTPServer.defaultPool(),
                                             timeout: writeStallTimeout)
            return HTTPServer(config: HTTPServer.Configuration(
                address: address,
                pool: pool,
                logger: ServerLogHTTPLogging()))
        }
        // A pool handed in (a test's) belongs to the one server it was made for.
        self.canReplaceAutomaticPort = port == 0 && socketPool == nil
        self.config = config
        self.requestedPort = port
        let deviceCommandBroker = DeviceCommandBroker(
            createTimeout: config.createDocTimeout, strokeOpTimeout: config.strokeOpTimeout,
            quietAfter: config.keepaliveIdleInterval, deviceWait: config.deviceWait,
            resubscribeWait: config.resubscribeWait,
            preferredKind: config.preferredDeviceKind)
        self.deviceCommandBroker = deviceCommandBroker
        // "An agent is at work": every tool call feeds it, the host is kept awake for it and the
        // status subscribers are told (`AgentWork`). `hostAwake` holds nothing unless `main.swift`
        // passes the real one.
        let agentWork = AgentWork(hostAwake: hostAwake) { [manager] in await manager.announceAgentWork() }
        self.agentWork = agentWork
        self.mcpAdapter = MCPAdapter(
            manager: manager,
            idleTimeout: config.mcpSessionIdleTimeout,
            cleanupInterval: config.mcpSessionCleanupInterval,
            broker: deviceCommandBroker,
            renderFileStore: renderFileStore,
            agentWork: agentWork)
    }

    /// Configures routes and serves until stopped.
    ///
    /// An `accept` failure — EMFILE when descriptors run out — is not the end of the server: it
    /// waits briefly and listens again (see `AcceptResilience`). Listening again drops the
    /// connections the failed loop held, which is also what frees the descriptors.
    ///
    /// Once listening, it checks that it OWNS its port on 127.0.0.1 and ::1 (`LoopbackPort`): when
    /// another program answers there, it stops and `run()` throws `LoopbackPortTaken` — reported as
    /// "port in use" — instead of serving while the Mac's own connections go elsewhere.
    public func run() async throws {
        let stopFlag = self.stopFlag
        let readiness = self.readiness
        // Says in the log that the process did not run for a while (the host's standby) — what a
        // report of devices not coming back has to be read against. Not one of the group's tasks:
        // `run()` must return the moment the server stops, not at this loop's next tick.
        let suspensionLog = Task {
            let interval = Duration.seconds(5)
            var watch = SuspensionWatch(interval: interval, now: .now)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if let gap = watch.tick(now: .now), !Task.isCancelled {
                    ServerLog.timed("[server] running again after about \(gap.components.seconds) s without running (the host was in standby, or the process was stopped)")
                }
            }
        }
        defer { suspensionLog.cancel() }
        var replacements = 0
        while true {
            let http = self.http
            await configureRoutes(on: http)
            do {
                try await serve(http)
                return
            } catch {
                // Whatever ended it, nothing of this server may stay open (a listener that was up
                // when the loopback check refused it). A no-op when it never listened.
                await http.stop(timeout: 0)
                // An AUTOMATIC port was only picked when the server was made; another program may
                // have taken it since (`LoopbackPort.pickFree` closes its probe). Nobody asked for
                // that port, so the server takes another instead of failing as "port in use" —
                // which a suite of servers started side by side did about one run in three in the
                // Linux container (2026-11-15). A FIXED port is the caller's choice and fails.
                if canReplaceAutomaticPort, replacements < Self.automaticPortReplacements,
                   StartupFailure.isAddressInUse("\(error)"), !(await stopFlag.isSet), !Task.isCancelled,
                   let next = try? LoopbackPort.pickFree() {
                    replacements += 1
                    httpBox.replace(port: next)
                    continue
                }
                await readiness.fail(error)
                throw error
            }
        }
    }

    /// How often an automatic port that turned out taken is replaced before the server gives up.
    static let automaticPortReplacements = 8

    /// Serves on `http` until it is stopped (returns) or fails (throws) — and ends AT ONCE either
    /// way. The second task proves the server listens and owns its port; it is ended with the
    /// accept loop rather than waited out. It used to be FlyingFox's own
    /// `waitUntilListening(timeout: 30)` inside a `waitForAll()`, which is not ended by the other
    /// task's failure: a port in use was reported 30 s after the bind had failed (measured with
    /// the real binary, 2026-11-15 — the start screen and join code were drawn meanwhile), and a
    /// server stopped before it listened kept `run()` for those 30 s too.
    private func serve(_ http: HTTPServer) async throws {
        enum Part { case accepting, ownership }
        let stopFlag = self.stopFlag
        let readiness = self.readiness
        try await withThrowingTaskGroup(of: Part.self) { group in
            group.addTask {
                // Stopped before it began: do not start listening now.
                guard !(await stopFlag.isSet) else { return .accepting }
                try await AcceptResilience.run(
                    delays: [.milliseconds(250), .seconds(1), .seconds(2), .seconds(5)],
                    shouldStop: { await stopFlag.isSet }
                ) {
                    try await http.run()
                }
                return .accepting
            }
            group.addTask { [self] in
                // Polled, so it ends when the group is cancelled (`Task.sleep` throws then).
                let deadline = ContinuousClock.now + .seconds(30)
                while await http.listeningAddress == nil {
                    guard ContinuousClock.now < deadline else { throw SocketError.disconnected }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let port = await self.listeningPort ?? self.requestedPort
                if let foreign = LoopbackPort.foreignOwner(port: port) {
                    // Thrown from HERE, so it is what `run()` reports: ending the group closes the
                    // listener, and the accept loop's own error for that is discarded with it.
                    throw LoopbackPortTaken(port: port, address: foreign)
                }
                await readiness.markVerified()
                return .ownership
            }
            while let part = try await group.next() {
                // The accept loop returned: the server was stopped. Nothing is left to wait for;
                // the ownership check, if still polling, ends with the group.
                if part == .accepting { group.cancelAll(); break }
            }
        }
    }

    /// Throws if the server is not listening — and verified to own its loopback addresses — within
    /// `timeout`, or as soon as `run()` has failed.
    ///
    /// The default is a bound for a server that never comes up at all, NOT a statement about how
    /// fast one does: a failure ends this wait at once (`run()` records it), so a long bound
    /// costs nothing, and a short one is a guess about the machine — it was 5 s, and a server
    /// starting beside 850 tests in a container can need longer than a guess allows.
    ///
    /// The caller that passes a SHORTER one is the startup path: it is deciding whether to open a
    /// browser, and the failure it is really waiting out — a port already in use — has already
    /// surfaced through `run()` by then.
    public func waitUntilListening(timeout: TimeInterval = 30) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while true {
            if await readiness.verified { return }
            if let failure = await readiness.failure { throw failure }
            if ContinuousClock.now >= deadline { throw SocketError.disconnected }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `timeout: 0` is deliberate, and it does NOT make the shutdown abrupt.
    ///
    /// `HTTPServer.stop(timeout:)` closes the listening socket and then `await`s
    /// `connection.complete()` for every live connection — the graceful part — BEFORE the
    /// timeout applies at all. What the timeout actually bounds is how long to wait for the
    /// accept-loop task to notice it is finished before cancelling it, and cancelling it at once
    /// costs nothing: there is nothing left for it to accept.
    ///
    /// It was `1`, which is a second of dead wait per server instance. Production never notices
    /// (one instance, at process exit), but the test suite creates one server per test and pays
    /// it 164 times: the MCP suite alone took **185.8 s**, of which ~164 s was this. At `0` the
    /// same suite takes **11.7 s** and the full suite went from ~190 s to ~12 s, with all 427
    /// tests still passing. A sixteen-fold difference in the edit-test loop, for a second nobody
    /// was using.
    public func stop() async {
        await stopFlag.set()
        await http.stop(timeout: 0)
        await mcpAdapter.shutdown()
    }

    public var listeningPort: UInt16? {
        get async {
            switch await http.listeningAddress {
            case .ip4(_, let port), .ip6(_, let port):
                return port
            default:
                return nil
            }
        }
    }

    private func configureRoutes(on http: HTTPServer) async {
        let store = self.store
        let manager = self.manager

        // M2c-1: a subscribe to a doc we hold no bytes for pulls them from a connected holder.
        let broker = self.deviceCommandBroker
        await manager.setContentProvider { docId, deviceId in
            try await broker.requestProvideContent(docId: docId, deviceId: deviceId)
        }
        // A document with watchers and no subscriber gets its frame from any connected device
        // that can render — the relay `render_sketch` walks, so the picture is the one an agent
        // gets and the deployed app already serves it (spec 2026-08-29-watcher-frames-...).
        // Every delete, however it arrives, forgets the agent's edit history for that document.
        // Live-state ops go to the device with the document open (review finding 20).
        await broker.setSubscriberLookup { docId in
            await manager.subscribedConnections(docId: docId)
        }
        let mcpAdapter = self.mcpAdapter
        await manager.setDocumentDeletedHandler { docId in
            await mcpAdapter.forgetHistory(docId: docId)
        }
        await manager.setFrameProvider { docId, bytes, px in
            let reply = try await broker.requestStrokeOp(
                docId: docId, docBytes: bytes, spec: WatcherFrame.renderSpec(longSidePx: px),
                capability: "render", takesDocumentLock: false)
            return (png: reply.bytes, canvasRect: WatcherFrame.canvasRect(fromMetadata: reply.meta))
        }

        await http.appendRoute("GET,HEAD /api/docs") { request in
            let live = await manager.liveInfo()
            var summaries = (try store.list()).map { info in
                DocSummary(
                    id: info.docId, name: info.name, sizeBytes: info.sizeBytes,
                    modifiedAt: info.modifiedAt, seq: live[info.docId]?.seq,
                    subscriberCount: live[info.docId]?.subscriberCount, hasContent: true)
            }
            // M2c-1: metadata-only documents come from the LIVE index (connected devices'
            // advertisements). Content always beats metadata, so skip any docId with bytes.
            // Case-insensitively, as `SessionManager.listDocuments` does: an advertised
            // `rainfall` IS the stored `Rainfall`.
            let contentIds = Set(summaries.map { $0.id.lowercased() })
            for (docId, entry) in await manager.liveDocs() where !contentIds.contains(docId.lowercased()) {
                summaries.append(DocSummary(
                    id: docId, name: entry.name, sizeBytes: entry.sizeBytes,
                    modifiedAt: entry.modifiedAt, seq: nil, subscriberCount: nil,
                    hasContent: false))
            }
            summaries.sort { $0.id < $1.id }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return self.headAware(
                request, headers: [.contentType: "application/json"],
                body: try encoder.encode(summaries))
        }

        await http.appendRoute("GET,HEAD /api/docs/*") { request in
            // Path shape: /api/docs/<ref>/frame
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "api", parts[1] == "docs", parts[3] == "frame" else {
                return HTTPResponse(statusCode: .notFound)
            }

            // FlyingFox hands the route an already-decoded path segment (it
            // decodes the request target once before routing); decoding it
            // again here would double-decode names containing a literal
            // "%" (e.g. "50%off" round-trips through the wire as
            // "50%25off" and arrives at `parts[2]` as "50%off" already).
            let ref = parts[2]
            let docId: String
            switch await manager.resolveDocRef(ref) {
            case .id(let id): docId = id
            case .unresolved: docId = ref
            case .ambiguous(let candidates):
                return self.ambiguousRefResponse(ref, candidates)
            }

            if let frame = await manager.latestFrame(docId: docId) {
                var headers: [HTTPHeader: String] = [
                    .contentType: "image/png",
                    .cacheControl: "no-store",
                    HTTPHeader("X-Frame-Stale"): "false",
                    HTTPHeader("X-Frame-Seq"): "\(frame.seq)",
                ]
                // Travels with the bytes it describes, never on the frameAvailable
                // nudge: the page fetches the LATEST frame, so a rect carried by the
                // nudge would pair with a newer PNG whenever two frames land inside one
                // fetch — a wrong compensation that looks exactly like no compensation.
                // Omitted rather than emptied when unknown; the viewer reads absence.
                if let rect = frame.canvasRect {
                    headers[HTTPHeader("X-Frame-Canvas-Rect")] =
                        rect.map { "\($0)" }.joined(separator: ",")
                }
                return self.headAware(request, headers: headers, body: frame.png)
            }

            if let bytes = try? store.load(docId: docId),
               let png = ThumbnailExtractor.thumbnailPNG(fromDocumentBytes: bytes) {
                return self.headAware(request, headers: [
                    .contentType: "image/png",
                    .cacheControl: "no-store",
                    HTTPHeader("X-Frame-Stale"): "true",
                ], body: png)
            }

            // M2c-1: a metadata-only doc has no bytes here — serve the thumbnail its holder
            // advertised, from the live index (same URL/content type, so the app's preview
            // cache is unaffected).
            guard let png = await manager.liveEntry(docId: docId)?.thumbnail else {
                return HTTPResponse(statusCode: .notFound)
            }
            return self.headAware(request, headers: [
                .contentType: "image/png",
                .cacheControl: "no-store",
                HTTPHeader("X-Frame-Stale"): "true",
            ], body: png)
        }

        // Serves what `render_sketch(writeToFile: true)` wrote. The tool reply advertises this
        // exact path via `RenderFileStore.urlPath(forName:)`, so the two are one definition.
        //
        // No document lookup and no session: a render is a standalone file, already produced. The
        // NAME is caller-chosen, which is why every containment rule lives in
        // `RenderFileStore.read` rather than being re-implemented here.
        await http.appendRoute(HTTPRoute("GET,HEAD \(RenderFileStore.routePrefix)/*")) { request in
            let prefixParts = RenderFileStore.routePrefix.split(separator: "/").count
            let parts = request.path.split(separator: "/").map(String.init)
            // Exactly one segment past the prefix — "/api/renders/a/b.png" is not a render.
            guard parts.count == prefixParts + 1 else {
                return HTTPResponse(statusCode: .notFound)
            }
            guard let renders = self.renderFileStore,
                  let contentType = RenderFileStore.contentType(forName: parts[prefixParts]),
                  let png = renders.read(name: parts[prefixParts])
            else {
                return HTTPResponse(statusCode: .notFound)
            }
            return self.headAware(request, headers: [
                // A picture, or an export's PDF page: by the name, from the store's own list.
                .contentType: contentType,
                // A render's name carries a millisecond stamp and a random token, so the bytes at
                // a given URL never change — but the file is evicted on a byte budget, so a cached
                // 200 would outlive the resource. no-store keeps "gone" honest.
                .cacheControl: "no-store",
            ], body: png)
        }

        await http.appendRoute("GET,HEAD /doc/*") { request in
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count == 2, parts[0] == "doc" else {
                return HTTPResponse(statusCode: .notFound)
            }
            // See the /api/docs/* handler above: parts[1] is already decoded.
            let ref = parts[1]
            let docId: String
            switch await manager.resolveDocRef(ref) {
            case .id(let id): docId = id
            case .unresolved: docId = ref
            case .ambiguous(let candidates):
                return self.ambiguousRefResponse(ref, candidates)
            }
            // Only serve a viewer for a document that actually exists somewhere. Without this,
            // any path under /doc/ answered 200 with a working-looking page for a document that
            // was never there, so a typo or a stale link rendered an empty viewer that would sit
            // at "stale (no live client)" forever. `/api/docs/<id>/frame` already 404s.
            //
            // "Exists" has THREE sources, and all three are load-bearing — this must be at least
            // as permissive as the frame route beside it, or a document whose frames that route
            // happily serves would have no page to show them on:
            //   - stored bytes;
            //   - an OPEN SESSION, which a doc has from the moment a client subscribes with
            //     `createIfMissing` — before any submit puts bytes in the store. Missing this
            //     404'd a document that was live and rendering frames (caught by
            //     `IntegrationTests.percentNamedDocServesPageAndFrame`);
            //   - a connected device's advertisement (M2c metadata-only: no bytes here at all,
            //     and the frame route serves the thumbnail its holder advertised).
            let hasSession = await manager.liveInfo()[manager.canonicalDocId(docId)] != nil
            let liveEntry = await manager.liveEntry(docId: docId)
            let known = ((try? store.exists(docId: docId)) ?? false) || hasSession || (liveEntry != nil)
            guard known else { return HTTPResponse(statusCode: .notFound) }
            let name = store.name(of: docId) ?? liveEntry?.name ?? docId
            return self.headAware(
                request, headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(WebUI.docHTML(docId: docId, name: name).utf8))
        }

        await http.appendRoute(
            "GET /ws",
            to: OriginCheckedHTTPHandler(
                inner: .webSocket(WSAdapter(manager: manager, config: config, broker: deviceCommandBroker,
                                            agentWork: agentWork)),
                allowedHostNames: Set(config.allowedHostNames)))

        // MCP endpoint (mcp_endpoint branch): mounts unconditionally, like
        // /ws. See Sources/InfSketchServerKit/MCP/MCPMount.swift for the
        // transport bridge and MCPAdapter.swift for the resource surface +
        // per-session registry (task-1-report.md has the SPIKE-PIN write-up
        // this was built from).
        await mountMCP(on: http, adapter: mcpAdapter,
                       allowedHostNames: Set(config.allowedHostNames))

        // Where a scanned QR code lands. The address comes from the request's own Host header —
        // whatever the DEVICE used to reach us, which is by definition an address that works from
        // the device. See `JoinPage` for why the code carries an http url rather than the app's
        // custom scheme.
        await http.appendRoute("GET,HEAD /join") { request in
            self.headAware(
                request, headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(JoinPage.html(host: request.headers[.host] ?? "localhost").utf8))
        }

        await http.appendRoute("GET,HEAD /") { request in
            // Per request, not per launch: `candidates()` walks the machine's interfaces, so a
            // network that changed since startup shows up on a reload. The port comes from the
            // LISTENING socket
            // — a server constructed with port 0 (every test, and any caller letting the OS pick)
            // would otherwise print `:0` into every url on the page.
            let port = await self.listeningPort ?? self.requestedPort
            let connect = ConnectPanel.html(
                candidates: LocalAddresses.candidates(), port: port,
                host: request.headers[.host])
            return self.headAware(
                request, headers: [.contentType: "text/html; charset=utf-8"],
                body: Data(WebUI.indexHTML(connectSection: connect).utf8))
        }
    }

    // HTTP: HEAD gets identical headers, no body.
    //
    // It takes the body as a parameter rather than an already-built `HTTPResponse` because
    // `Content-Length` has to be carried across by hand and `HTTPResponse.bodyData` is async —
    // unreadable from here. Dropping the body without restating the length made the server
    // compute it from what was left, so a HEAD answered `Content-Length: 0` while the same GET
    // answered the real size, defeating the main reason to send a HEAD at all (RFC 9110 §9.3.2:
    // a HEAD response's header fields should be the ones a GET would have sent, and its
    // Content-Length describes the body the GET *would* have returned).
    private func headAware(
        _ request: HTTPRequest, statusCode: HTTPStatusCode = .ok,
        headers: [HTTPHeader: String], body: Data
    ) -> HTTPResponse {
        guard request.method == .HEAD else {
            return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
        }
        var headers = headers
        headers[.contentLength] = "\(body.count)"
        return HTTPResponse(statusCode: statusCode, headers: headers, body: Data())
    }

    /// `/doc/<ref>` and `/api/docs/<ref>/frame` share this: a `ref` that names SEVERAL documents
    /// (an ambiguous name — `SessionManager.resolveDocRef`) is a 409, never a guess at which one
    /// was meant. Listed `id (name)` per line, newest-modified first (the order `resolveDocRef`
    /// already sorted its candidates in).
    private func ambiguousRefResponse(_ ref: String, _ candidates: [DocRefCandidate]) -> HTTPResponse {
        let body = candidates.map { "\($0.id) (\($0.name))" }.joined(separator: "\n")
        return HTTPResponse(
            statusCode: .conflict, headers: [.contentType: "text/plain; charset=utf-8"],
            body: Data(("\"\(ref)\" names several documents:\n" + body).utf8))
    }
}
