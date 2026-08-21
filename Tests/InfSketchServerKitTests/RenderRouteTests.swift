import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import InfSketchServerKit

/// `render_sketch(writeToFile: true)` writes a PNG on the SERVER's machine, which serves an agent
/// that shares that filesystem and nobody else. Serving the same file at a URL is what makes the
/// feature work for a remote agent — and it keeps the render itself on MCP, so there is still
/// exactly one place that parses a render spec.
@Suite struct RenderRouteTests {

    private func startServer() async throws
        -> (InfSketchServer, UInt16, Task<Void, any Error>, RenderFileStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        let renders = RenderFileStore(
            directory: dir.appendingPathComponent(RenderFileStore.directoryName, isDirectory: true))

        let server = InfSketchServer(
            port: 0, store: store, config: SessionConfig(), renderFileStore: renders)
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        return (server, port, task, renders)
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @Test func aWrittenRenderIsServedAtTheUrlTheReplyAdvertises() async throws {
        let (server, port, task, renders) = try await startServer()
        defer { task.cancel() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
        let written = try renders.write(docId: "chart", png: png)

        // Exactly the string the tool reply carries — joined to the base the caller connected to,
        // which is what a remote agent does with it.
        let path = RenderFileStore.urlPath(forName: written.lastPathComponent)
        let (body, response) = try await get(URL(string: "http://127.0.0.1:\(port)\(path)")!)

        #expect(response.statusCode == 200)
        #expect(body == png)
        #expect(
            (response.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/png"))

        await server.stop()
    }

    /// Renders are scratch and the directory evicts on a byte budget, so a 404 here is an ORDINARY
    /// state — the tool's own description tells the caller to read the path soon.
    @Test func anEvictedOrUnknownRenderIs404() async throws {
        let (server, port, task, _) = try await startServer()
        defer { task.cancel() }

        let (_, response) = try await get(
            URL(string: "http://127.0.0.1:\(port)/api/renders/gone_2020-01-01_00-00-00-000_ffff.png")!)

        #expect(response.statusCode == 404)
        await server.stop()
    }

    /// The path segment is caller-chosen, so the route must not reach outside the render directory
    /// or serve anything that is not a render.
    @Test(arguments: [
        "/api/renders/..%2F..%2Fsecret.png",
        "/api/renders/notes.txt",
        "/api/renders/",
        "/api/renders/a/b.png",
    ])
    func aCallerChosenPathCannotReachPastTheRenderDirectory(path: String) async throws {
        let (server, port, task, renders) = try await startServer()
        defer { task.cancel() }
        _ = try renders.write(docId: "d", png: Data([1, 2, 3]))

        let (body, response) = try await get(URL(string: "http://127.0.0.1:\(port)\(path)")!)

        #expect(response.statusCode == 404, "\(path) should not be served")
        #expect(body.isEmpty || response.statusCode == 404)
        await server.stop()
    }

    /// A server with no render directory has nothing to serve, and must say so rather than
    /// answering 200 with an empty body.
    @Test func aServerWithNoRenderDirectoryAnswers404() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-route-none-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = InfSketchServer(port: 0, store: DirectoryDocumentStore(directory: dir))
        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)

        let (_, response) = try await get(
            URL(string: "http://127.0.0.1:\(port)/api/renders/anything.png")!)

        #expect(response.statusCode == 404)
        await server.stop()
    }
}
