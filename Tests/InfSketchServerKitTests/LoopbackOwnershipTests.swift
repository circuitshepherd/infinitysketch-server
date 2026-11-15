import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import FlyingSocks
@testable import InfSketchServerKit

/// The server must OWN its port on the loopback addresses (2026-10-11).
///
/// Measured on a Mac: the server listens on the IPv6 wildcard with SO_REUSEADDR (FlyingFox sets
/// it), and on Darwin that bind SUCCEEDS on a port another program already holds on 127.0.0.1 only
/// — after which a connection to 127.0.0.1:<port> reaches THAT program. GitKraken and OrbStack hold
/// such ports; server tests that landed on one got "Authentication required" from GitKraken and
/// failed a landing, and a real server started on such a port would hand the Mac's own app to the
/// other program with no "port in use" anywhere.
@Suite(.serialized)
struct LoopbackOwnershipTests {

    /// Another program's listener on 127.0.0.1 ONLY, the way GitKraken holds its ports.
    private func holdLoopbackOnly() throws -> (Socket, UInt16) {
        let socket = try Socket(domain: AF_INET)
        try socket.bind(to: sockaddr_in.inet(ip4: "127.0.0.1", port: 0))
        try socket.listen()
        guard case .ip4(_, let port) = try socket.sockname() else { throw SocketError.disconnected }
        return (socket, port)
    }

    private func tempStore() throws -> DirectoryDocumentStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DirectoryDocumentStore(directory: dir)
    }

    @Test func aFixedPortHeldOnLoopbackByAnotherProgramRefusesToStart() async throws {
        let (held, port) = try holdLoopbackOnly()
        defer { try? held.close() }
        let server = InfSketchServer(port: port, store: try tempStore())
        let task = Task { try await server.run() }
        let listening = (try? await server.waitUntilListening(timeout: 5)) != nil
        // Stop BEFORE waiting on run(): a server that wrongly took the port would serve forever.
        await server.stop()
        let failure: (any Error)? = await { do { try await task.value; return nil } catch { return error } }()
        #expect(!listening, "the server claimed a port another program answers on 127.0.0.1")
        let message = StartupFailure.describe("\(failure.map { "\($0)" } ?? "none")", port: port)
        #expect(message.contains("already in use"), "\(message)")
    }

    private func thrown(_ work: () async throws -> Void) async -> (any Error)? {
        do { try await work(); return nil } catch { return error }
    }

    /// A port another server is LISTENING on: the second server says so AT ONCE. It used to say
    /// so 30 s later (measured with the real binary, 2026-11-15: "port … is already in use" after
    /// 31 s, with the whole start screen and join code drawn meanwhile): the bind failed at once,
    /// but `run()` then waited out a 30 s wait for a listening that could no longer come, and
    /// only afterwards recorded the failure — so a caller waiting for the server (5 s in the
    /// tests) saw its own wait end first, as an unexplained `disconnected`.
    @Test func aPortAnotherServerListensOnIsRefusedAtOnce() async throws {
        let first = InfSketchServer(port: 0, store: try tempStore())
        let firstTask = Task { try await first.run() }
        defer { firstTask.cancel() }
        try await first.waitUntilListening()
        let port = try #require(await first.listeningPort)

        let second = InfSketchServer(port: port, store: try tempStore())
        let started = ContinuousClock.now
        let task = Task { try await second.run() }
        // 20 s: far above anything a refusal needs, below the 30 s the fault took. What is
        // asserted is WHICH error ends the wait: the server's own, not the wait's deadline.
        let waited = await thrown { try await second.waitUntilListening(timeout: 20) }
        if waited == nil { await second.stop() }   // it wrongly listens: do not hang on run()
        let failure = await thrown { try await task.value }
        let took = ContinuousClock.now - started

        let waitMessage = StartupFailure.describe("\(waited.map { "\($0)" } ?? "none")", port: port)
        #expect(waitMessage.contains("already in use"), "the wait ended with: \(waitMessage)")
        let message = StartupFailure.describe("\(failure.map { "\($0)" } ?? "none")", port: port)
        #expect(message.contains("already in use"), "\(message)")
        #expect(took < .seconds(25), "refused after \(took); the fault took 30 s")
    }

    /// An AUTOMATIC port is picked when the server is made and bound when it runs. Another
    /// program can take it in between — in this suite another test's listener did, about one
    /// run in three in the Linux container, and the server failed as "port in use" on a port
    /// nobody had asked for. The server then takes another port.
    @Test func anAutomaticPortTakenBeforeTheServerRunsIsReplaced() async throws {
        let server = InfSketchServer(port: 0, store: try tempStore())
        let picked = try #require(server.automaticPort, "port 0 picks a port when the server is made")
        // Another program takes exactly that port before this server runs.
        let other = try Socket(domain: AF_INET)
        defer { try? other.close() }
        try other.bind(to: sockaddr_in.inet(ip4: "127.0.0.1", port: picked))
        try other.listen()

        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        #expect(port != picked, "the server listens on \(port), the port the other program holds")
        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/api/docs")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "the server answers on its new port")
        await server.stop()
    }

    @Test func anAutomaticPortIsNeverOneHeldOnLoopback() throws {
        var held: [Socket] = []
        var heldPorts: Set<UInt16> = []
        defer { held.forEach { try? $0.close() } }
        for _ in 0 ..< 200 {
            let (s, p) = try holdLoopbackOnly()
            held.append(s); heldPorts.insert(p)
        }
        for _ in 0 ..< 200 {
            let picked = try LoopbackPort.pickFree()
            #expect(!heldPorts.contains(picked), "picked \(picked), which another program holds on 127.0.0.1")
        }
    }

    @Test func anAutomaticPortServerAnswersItsOwnLoopbackAddresses() async throws {
        let server = InfSketchServer(port: 0, store: try tempStore())
        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        #expect(LoopbackPort.foreignOwner(port: port) == nil)
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/docs")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((try? JSONSerialization.jsonObject(with: data)) is [Any], "127.0.0.1 reached this server's /api/docs")
        await server.stop()
    }
}
