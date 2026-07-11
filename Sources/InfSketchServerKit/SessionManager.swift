import Foundation
import InfSketchWire

public struct LiveDocInfo: Sendable, Equatable, Codable {
    public var seq: Int
    public var subscriberCount: Int
    public init(seq: Int, subscriberCount: Int) {
        self.seq = seq
        self.subscriberCount = subscriberCount
    }
}

/// Registry of live DocumentSessions. Sole entry point for subscribe /
/// unsubscribe / submit, so subscriber counting and grace teardown are
/// serialized on one actor. Also fans out server-status events.
public actor SessionManager {
    private let store: any DocumentStore
    private let config: SessionConfig
    private var sessions: [String: DocumentSession] = [:]
    private var tokenDocs: [UUID: String] = [:]
    private var counts: [String: Int] = [:]
    private var tokenWatchDocs: [UUID: String] = [:]
    private var watcherCounts: [String: Int] = [:]
    private var graceTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var statusSubscribers: [UUID: AsyncStream<ServerMessage>.Continuation] = [:]

    public init(store: any DocumentStore, config: SessionConfig = SessionConfig()) {
        self.store = store
        self.config = config
    }

    public func subscribe(docId: String, createIfMissing: Bool = false) async throws -> SubscribeResult {
        graceTasks.removeValue(forKey: docId)?.task.cancel()
        let session: DocumentSession
        if let existing = sessions[docId] {
            session = existing
        } else {
            do {
                session = try DocumentSession(docId: docId, store: store, bufferLimit: config.outboundBufferLimit)
            } catch DocumentStoreError.notFound where createIfMissing {
                // Mirror clients push docs the server has never seen: open an
                // in-memory empty session; the first op persists real bytes.
                session = DocumentSession(docId: docId, store: store,
                                          bufferLimit: config.outboundBufferLimit, bytes: Data())
            }
            sessions[docId] = session
            emitStatus(docId: docId, kind: "sessionOpened", seq: 0, count: 0)
        }
        let result = await session.subscribe()
        tokenDocs[result.token] = docId
        let newCount = counts[docId, default: 0] + 1
        counts[docId] = newCount
        if case .subscribed(_, let seq, _) = result.snapshot {
            emitStatus(docId: docId, kind: "subscriberCount", seq: seq, count: newCount)
        }
        return result
    }

    public func unsubscribe(docId: String, token: UUID) async {
        guard tokenDocs.removeValue(forKey: token) == docId,
              let session = sessions[docId] else { return }
        await session.unsubscribe(token)
        counts[docId] = max(0, (counts[docId] ?? 1) - 1)
        let remaining = counts[docId] ?? 0
        emitStatus(docId: docId, kind: "subscriberCount", seq: await session.seq, count: remaining)
        if remaining == 0 && (watcherCounts[docId] ?? 0) == 0 {
            scheduleGraceTeardown(docId: docId)
        }
    }

    /// Register a viewer. Opens the session from the store if needed (no
    /// createIfMissing analog — you can't watch a doc that doesn't exist).
    public func watch(docId: String) async throws -> WatchResult {
        graceTasks.removeValue(forKey: docId)?.task.cancel()
        let session: DocumentSession
        if let existing = sessions[docId] {
            session = existing
        } else {
            session = try DocumentSession(docId: docId, store: store, bufferLimit: config.outboundBufferLimit)
            sessions[docId] = session
            emitStatus(docId: docId, kind: "sessionOpened", seq: 0, count: 0)
        }
        let result = await session.watch()
        tokenWatchDocs[result.token] = docId
        watcherCounts[docId, default: 0] += 1
        return result
    }

    public func unwatch(docId: String, token: UUID) async {
        guard tokenWatchDocs.removeValue(forKey: token) == docId,
              let session = sessions[docId] else { return }
        await session.unwatch(token)
        watcherCounts[docId] = max(0, (watcherCounts[docId] ?? 1) - 1)
        if (watcherCounts[docId] ?? 0) == 0 && (counts[docId] ?? 0) == 0 {
            scheduleGraceTeardown(docId: docId)
        }
    }

    /// Returns false when the doc has no live session (frame dropped).
    public func submitFrame(docId: String, bytes: Data) async -> Bool {
        guard let session = sessions[docId] else { return false }
        await session.submitFrame(bytes: bytes)
        return true
    }

    public func latestFrame(docId: String) async -> (png: Data, seq: Int, receivedAt: Date)? {
        guard let session = sessions[docId] else { return nil }
        return await session.latestFrame
    }

    public func submit(docId: String, opId: String, payload: OpPayload) async -> ServerMessage? {
        guard let session = sessions[docId] else {
            return .reject(docId: docId, opId: opId, reason: "notSubscribed", seq: 0)
        }
        let result = await session.submit(opId: opId, payload: payload)
        if result == nil {
            emitStatus(docId: docId, kind: "docUpdated", seq: await session.seq, count: counts[docId] ?? 0)
        }
        return result
    }

    public func subscribeStatus() -> (events: AsyncStream<ServerMessage>, token: UUID) {
        let token = UUID()
        let (stream, continuation) = AsyncStream<ServerMessage>.makeStream(
            bufferingPolicy: .bufferingOldest(config.outboundBufferLimit))
        statusSubscribers[token] = continuation
        return (stream, token)
    }

    public func unsubscribeStatus(_ token: UUID) {
        statusSubscribers.removeValue(forKey: token)?.finish()
    }

    public func liveInfo() async -> [String: LiveDocInfo] {
        var info: [String: LiveDocInfo] = [:]
        for (docId, session) in sessions {
            info[docId] = LiveDocInfo(seq: await session.seq, subscriberCount: counts[docId] ?? 0)
        }
        return info
    }

    /// The WS twin of the REST listing: store contents + live session info.
    public func listDocuments() async throws -> [DocListEntry] {
        let live = await liveInfo()
        return try store.list()
            .sorted { $0.docId < $1.docId }
            .map { info in
                DocListEntry(
                    id: info.docId,
                    sizeBytes: info.sizeBytes,
                    modifiedAt: info.modifiedAt,
                    seq: live[info.docId]?.seq,
                    subscriberCount: live[info.docId]?.subscriberCount)
            }
    }

    private func scheduleGraceTeardown(docId: String) {
        graceTasks[docId]?.task.cancel()
        let graceId = UUID()
        let task = Task { [gracePeriod = config.gracePeriod] in
            try? await Task.sleep(for: gracePeriod)
            guard !Task.isCancelled else { return }
            await self.tearDownIfIdle(docId: docId, graceId: graceId)
        }
        graceTasks[docId] = (graceId, task)
    }

    /// Tears down only if this invocation belongs to the CURRENTLY registered
    /// grace task. A resubscribe removes the registration on the actor, so a
    /// stale task that already passed its cancellation check fails this guard.
    /// The guard and the teardown run in one actor turn (no suspension), so
    /// no subscribe can interleave between check and mutation.
    private func tearDownIfIdle(docId: String, graceId: UUID) {
        guard graceTasks[docId]?.id == graceId else { return }
        guard (counts[docId] ?? 0) == 0, (watcherCounts[docId] ?? 0) == 0 else {
            graceTasks.removeValue(forKey: docId)
            return
        }
        sessions.removeValue(forKey: docId)
        counts.removeValue(forKey: docId)
        watcherCounts.removeValue(forKey: docId)
        graceTasks.removeValue(forKey: docId)
        emitStatus(docId: docId, kind: "sessionClosed", seq: nil, count: 0)
    }

    private func emitStatus(docId: String, kind: String, seq: Int?, count: Int?) {
        let message = ServerMessage.statusEvent(
            payload: StatusPayload(docId: docId, kind: kind, seq: seq, subscriberCount: count))
        for (token, continuation) in statusSubscribers {
            switch continuation.yield(message) {
            case .dropped, .terminated:
                statusSubscribers.removeValue(forKey: token)?.finish()
            default:
                break
            }
        }
    }
}
