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
