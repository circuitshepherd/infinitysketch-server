import Foundation
import FlyingSocks
import FlyingFox

/// A socket pool that gives up on a WRITE that has made no progress for `timeout`.
///
/// **Why.** A WebSocket peer that stops reading is dropped logically by `ConnectionHealth`, but
/// nothing below us could close its socket: FlyingFox writes each outbound frame with
/// `socket.write`, which waits on the pool for writability, and the close frame the drop sends
/// is queued BEHIND the whole backlog. So a non-reader's socket and ~150 MB of queued broadcasts
/// stayed alive for minutes, until the peer itself went away (measured). Nothing in FlyingFox
/// hands us the socket or the writer task, but the pool is injectable and every blocked write
/// passes through it.
///
/// A peer that is reading at all makes its socket writable again as its kernel buffer drains, so
/// each individual wait is short however slow the link. A wait that sees NO drain for `timeout`
/// is a peer that is not reading; the write then throws, FlyingFox's connection loop ends and
/// closes the socket, and our `Connection` sees its input end and releases everything. The
/// timeout is shorter than the keepalive's own verdict (30 s idle + 10 s grace), which is fine:
/// a peer that has read nothing for that long would fail the ping anyway.
///
/// **Writes only.** On Linux `Socket.Events.connection` IS `.read`, so a read timeout would
/// reach the listening socket's accept wait and end the server after a quiet spell.
struct WriteStallTimeoutPool: AsyncSocketPool {
    let inner: any AsyncSocketPool
    let timeout: Duration

    func prepare() async throws { try await inner.prepare() }

    func run() async throws { try await inner.run() }

    func suspendSocket(_ socket: Socket, untilReadyFor events: Socket.Events) async throws {
        guard events == .write else {
            return try await inner.suspendSocket(socket, untilReadyFor: events)
        }
        let inner = self.inner
        let timeout = self.timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await inner.suspendSocket(socket, untilReadyFor: events) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SocketError.timeout(message: "write stalled for \(timeout)")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
