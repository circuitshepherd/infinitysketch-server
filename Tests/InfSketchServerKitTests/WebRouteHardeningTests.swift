import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InfSketchWire
@testable import InfSketchServerKit

/// Two browser-facing HTTP defects found 2026-07-25 during a deliberate pass over the web UI.
///
/// 1. Every route is registered `"GET,HEAD ..."`, but `headAware` dropped the body without
///    restating `Content-Length`, so the server recomputed it from the empty body: a HEAD
///    answered `Content-Length: 0` where the same GET answered the real size. That defeats the
///    main reason to send a HEAD (RFC 9110 §9.3.2).
/// 2. `/doc/<anything>` answered 200 with a working-looking viewer for documents that do not
///    exist, so a typo or a stale link rendered an empty page that sat at "stale (no live
///    client)" forever. The sibling `/api/docs/<id>/frame` route already 404s in that case.
@Suite struct WebRouteHardeningTests {

    private func startServer() async throws -> (InfSketchServer, UInt16, Task<Void, any Error>) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("webroutes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        try store.save(docId: "sample", bytes: Fixtures.docBytes)

        let server = InfSketchServer(port: 0, docsDirectory: dir, config: SessionConfig())
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        let port = try #require(await server.listeningPort)
        return (server, port, task)
    }

    private func head(_ url: URL) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        return try #require(response as? HTTPURLResponse)
    }

    /// The discriminator is GET's own length, read from the same running server — not a
    /// hardcoded number that would drift as the page or the doc list changes.
    @Test(arguments: ["/", "/api/docs", "/doc/sample"])
    func headReportsTheContentLengthAGetWouldHaveReturned(path: String) async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!

        let (body, getResponse) = try await URLSession.shared.data(from: url)
        #expect((getResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(!body.isEmpty, "precondition: this route returns a body for GET")

        let headResponse = try await head(url)
        #expect(headResponse.statusCode == 200)
        let reported = headResponse.value(forHTTPHeaderField: "Content-Length")
        #expect(reported == "\(body.count)",
                "HEAD \(path) reported \(reported ?? "nil"), GET returned \(body.count) bytes")
        await server.stop()
    }

    /// HEAD must still carry the route's own headers, not just the length.
    @Test func headKeepsTheRoutesOtherHeaders() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let response = try await head(URL(string: "http://127.0.0.1:\(port)/api/docs")!)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/json")
        await server.stop()
    }

    @Test func theViewerIs404ForADocumentThatDoesNotExist() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let url = URL(string: "http://127.0.0.1:\(port)/doc/no-such-document")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        await server.stop()
    }

    @Test func theViewerIsStillServedForAStoredDocument() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        let url = URL(string: "http://127.0.0.1:\(port)/doc/sample")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("const docId = \"sample\""))
        await server.stop()
    }

    /// A document that only exists as an OPEN SESSION — subscribed with `createIfMissing`, no
    /// submit yet, so nothing in the store — is live and rendering frames. The frame route serves
    /// it, so the viewer must too. Narrowing the check to stored bytes alone 404'd exactly this
    /// (caught by `IntegrationTests.percentNamedDocServesPageAndFrame`).
    @Test func theViewerIsServedForADocumentThatOnlyExistsAsAnOpenSession() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        _ = try await server.manager.subscribe(docId: "fresh", createIfMissing: true)
        let stored = (try? DirectoryDocumentStore(
            directory: FileManager.default.temporaryDirectory).exists(docId: "fresh")) ?? false
        #expect(!stored, "precondition: this document has no bytes in any store")

        let url = URL(string: "http://127.0.0.1:\(port)/doc/fresh")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        await server.stop()
    }

    /// A metadata-only document — advertised by a connected device, no bytes on the server — is
    /// legitimately viewable: `/api/docs/<id>/frame` serves the thumbnail its holder advertised.
    /// The existence check must consult the live index too, or M2c's whole doc class 404s.
    @Test func theViewerIsServedForAnAdvertisedMetadataOnlyDocument() async throws {
        let (server, port, task) = try await startServer()
        defer { task.cancel() }

        await server.manager.applyAdvertisements(
            [DocAdvertisement(docId: "advertised", modifiedAt: Date(timeIntervalSince1970: 0),
                              sizeBytes: 10, thumbnail: Data([1, 2, 3]))],
            connectionId: UUID(), deviceId: "device-1")

        let url = URL(string: "http://127.0.0.1:\(port)/doc/advertised")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        await server.stop()
    }
}
